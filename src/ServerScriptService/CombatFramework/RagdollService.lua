--!strict
--[[
	RagdollService.lua

	FULL REWRITE

	DOGU15 preset-constraint ragdoll architecture.

	KEY DESIGN DECISIONS
	====================

	1. THE RIG'S EXISTING CONSTRAINTS ARE THE RAGDOLL
	   We do not create BallSockets on the fly.

	2. MOTOR6Ds AND RAGDOLL CONSTRAINTS ARE NEVER BOTH ACTIVE
	   This avoids the "slush", collapsing ball, and spring-fighting behaviour.

	3. COLLISIONPART IS DISABLED WHILE RAGDOLLED
	   The actual body becomes the collision body.

	4. IK IS NOT PART OF THE RAGDOLL
	   Ragdolled=true is set before the physical transition. The existing
	   IKVisualsBootstrap sees that and stops procedural body control.

	5. DEATH DOES NOT IMMEDIATELY SPAWN A PERFECT FRESH CORPSE
	   The actual character ragdolls first. A persistent corpse is cloned later
	   from the character's CURRENT physical pose.

	6. FUTURE DRAGGING IS PART-BASED
	   AttachDragHandle can target a specific limb, not just HumanoidRootPart.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")

local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local RagdollTuning = require(CombatFramework.Shared.Config.RagdollTuning)

export type RagdollReason = RagdollTuning.RagdollReason

export type RagdollOptions = {
	Reason: RagdollReason?,
	Impulse: Vector3?,
	ImpulsePart: string?,
}

export type ExitOptions = {
	Force: boolean?,
	WakeStance: string?,
}

export type DragOptions = {
	Part: MeshPart | BasePart | string?,
	TargetAttachment: Attachment,
}

type PartState = {
	CanCollide: boolean,
	CanTouch: boolean,
	CanQuery: boolean,
	CollisionGroup: string,
	Massless: boolean,
}

type ConstraintState = {
	Constraint: Constraint,
	Enabled: boolean,
}

type MotorState = {
	Motor: Motor6D,
	Enabled: boolean,
}

type Meta = {
	Reason: RagdollReason,
	EnterTime: number,

	WakeStance: string?,
	ExitScheduled: boolean,

	Parts: { (MeshPart or BasePart) },

	PartStates: { [(MeshPart || BasePart)]: PartState },

	Motors: { MotorState },
	Constraints: { ConstraintState },

	CollisionPart: (MeshPart || BasePart) ?,
	CollisionPartState: PartState?,

	HumanoidAutoRotate: boolean,
	HumanoidPlatformStand: boolean,
	HumanoidWalkSpeed: number,
	HumanoidJumpPower: number,

	RootPart: BasePart,
	IsCorpse: boolean,
}

type CorpseEntry = {
	Parts: { (MeshPart || BasePart) },
	LastMotionTime: number,
	Anchored: boolean,
}

type DragHandle = {
	Part: (MeshPart || BasePart),
	Attachment: Attachment,
	AlignPosition: AlignPosition,
}

local RagdollService = {}

local ragdollMeta: { [Model]: Meta } = {}

local pendingImpact: {
	[Model]: {
		Impulse: Vector3,
		ImpulsePart: string?,
	}
} = {}

local corpses: { [Model]: CorpseEntry } = {}

local dragHandles: {
	[Model]: DragHandle
} = {}

local ragdollsFolder: Folder? = nil

local RAGDOLL_COLLISION_GROUP = "Ragdoll"

local BODY_PART_NAMES: { [string]: boolean } = {
	Head = true,

	UpperTorso = true,
	LowerTorso = true,

	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,

	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,

	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,

	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,

	HumanoidRootPart = true,
}

local COLLIDABLE_LOOKUP: { [string]: boolean } = {}

for _, name in ipairs(RagdollTuning.CollidableBodyParts) do
	COLLIDABLE_LOOKUP[name] = true
end

local ALWAYS_NON_COLLIDABLE_LOOKUP: { [string]: boolean } = {}

for _, name in ipairs(RagdollTuning.AlwaysNonCollidable) do
	ALWAYS_NON_COLLIDABLE_LOOKUP[name] = true
end

-- ============================================================================
-- COLLISION GROUP INITIALIZATION
-- ============================================================================

pcall(function()
	PhysicsService:RegisterCollisionGroup(RAGDOLL_COLLISION_GROUP)
end)

PhysicsService:CollisionGroupSetCollidable(
	RAGDOLL_COLLISION_GROUP,
	RAGDOLL_COLLISION_GROUP,
	false
)

PhysicsService:CollisionGroupSetCollidable(
	RAGDOLL_COLLISION_GROUP,
	"Default",
	true
)

-- ============================================================================
-- GENERAL HELPERS
-- ============================================================================

local function getRagdollsFolder(): Folder
	if ragdollsFolder and ragdollsFolder.Parent then
		return ragdollsFolder
	end

	local existing = Workspace:FindFirstChild("Ragdolls")

	if existing and existing:IsA("Folder") then
		ragdollsFolder = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "Ragdolls"
	folder.Parent = Workspace

	ragdollsFolder = folder

	return folder
end

local function findPart(
	model: Model,
	name: string
): (MeshPart || BasePart)?
	local found = model:FindFirstChild(name, true)

	if found and (found:IsA("MeshPart") or found:IsA("BasePart")) then
		return found
	end

	return nil
end

local function getBodyParts(
	model: Model
): { (MeshPart || BasePart) }
	local result: { (MeshPart || BasePart) } = {}
	local seen: { [(MeshPart || BasePart)]: boolean } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if (descendant:IsA("MeshPart") or descendant:IsA("BasePart"))
			and BODY_PART_NAMES[descendant.Name]
			and not seen[descendant] then

			seen[descendant] = true
			table.insert(result, descendant)
		end
	end

	return result
end

local function capturePartState(
	part: (MeshPart || BasePart)
): PartState
	return {
		CanCollide = part.CanCollide,
		CanTouch = part.CanTouch,
		CanQuery = part.CanQuery,
		CollisionGroup = part.CollisionGroup,
		Massless = part.Massless,
	}
end

local function restorePartState(
	part: (MeshPart || BasePart),
	state: PartState
)
	part.CanCollide = state.CanCollide
	part.CanTouch = state.CanTouch
	part.CanQuery = state.CanQuery
	part.CollisionGroup = state.CollisionGroup
	part.Massless = state.Massless
end

local function getCollisionPart(
	character: Model
): BasePart?
	local found = character:FindFirstChild(
		RagdollTuning.CollisionPartName,
		true
	)

	if found and found:IsA("BasePart") then
		return found
	end

	return nil
end

local function isRagdollConstraint(
	character: Model,
	constraint: Constraint
): boolean
	if constraint:GetAttribute("RagdollConstraint") == true then
		return true
	end

	local current: Instance? = constraint.Parent

	while current and current ~= character do
		if current:GetAttribute("RagdollConstraint") == true then
			return true
		end

		for _, folderName in ipairs(
			RagdollTuning.ConstraintFolderNames
		) do
			if current.Name == folderName then
				return true
			end
		end

		current = current.Parent
	end

	for _, prefix in ipairs(
		RagdollTuning.ConstraintNamePrefixes
	) do
		if string.sub(
			constraint.Name,
			1,
			#prefix
		) == prefix then
			return true
		end
	end

	return false
end

local function getPresetConstraints(
	character: Model
): { ConstraintState }
	local result: { ConstraintState } = {}

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Constraint")
			--[[ and isRagdollConstraint(
				character,
				descendant
			) ]]--
			 then

			table.insert(result, {
				Constraint = descendant,
				Enabled = descendant.Enabled,
			})
		end
	end

	return result
end

local function getMotors(
	character: Model
): { MotorState }
	local result: { MotorState } = {}

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			table.insert(result, {
				Motor = descendant,
				Enabled = descendant.Enabled,
			})
		end
	end

	return result
end

local function setServerNetworkOwnership(
	parts: { (MeshPart || BasePart) }
)
	for _, part in ipairs(parts) do
		if part.Parent then
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
		end
	end
end

local function restoreAutomaticNetworkOwnership(
	parts: { (MeshPart || BasePart) }
)
	for _, part in ipairs(parts) do
		if part.Parent then
			pcall(function()
				part:SetNetworkOwnershipAuto()
			end)
		end
	end
end

-- ============================================================================
-- COLLISION TRANSITION
-- ============================================================================

local function enterRagdollCollision(
	character: Model,
	parts: { (MeshPart || BasePart) }
): (
	{ [(MeshPart || BasePart)]: PartState },
	(MeshPart || BasePart)?,
	PartState?
)
	local states: { [(MeshPart || BasePart)]: PartState } = {}

	for _, part in ipairs(parts) do
		states[part] = capturePartState(part)

		part.CollisionGroup = RAGDOLL_COLLISION_GROUP
		part.CanTouch = true
		part.CanQuery = true
		part.Massless = false

		if ALWAYS_NON_COLLIDABLE_LOOKUP[part.Name] then
			part.CanCollide = false

		elseif COLLIDABLE_LOOKUP[part.Name] then
			print("Set cancollide true on", part.Name)
			part.CanCollide = true

		else
			part.CanCollide = false
		end
	end

	local collisionPart = getCollisionPart(character)
	local collisionPartState: PartState? = nil

	if collisionPart then
		collisionPartState = capturePartState(collisionPart)

		collisionPart.CanCollide = false
		collisionPart.CanTouch = false
		collisionPart.CanQuery = false
	end

	return states, collisionPart, collisionPartState
end

local function restoreNormalCollision(
	meta: Meta
)
	for part, state in pairs(meta.PartStates) do
		if part.Parent then
			restorePartState(part, state)
		end
	end

	if meta.CollisionPart
		and meta.CollisionPart.Parent
		and meta.CollisionPartState then

		restorePartState(
			meta.CollisionPart,
			meta.CollisionPartState
		)
	end
end

-- ============================================================================
-- RAGDOLL TRANSITION
-- ============================================================================

local function disableMotors(
	motors: { MotorState }
)
	for _, state in ipairs(motors) do
		if state.Motor.Parent then
			state.Motor.Enabled = false
		end
	end
end

local function restoreMotors(
	motors: { MotorState }
)
	for _, state in ipairs(motors) do
		if state.Motor.Parent then
			state.Motor.Enabled = state.Enabled
		end
	end
end

local function enableConstraints(
	constraints: { ConstraintState }
)
	for _, state in ipairs(constraints) do
		if state.Constraint.Parent then
			state.Constraint.Enabled = true
		end
	end
end

local function restoreConstraints(
	constraints: { ConstraintState }
)
	for _, state in ipairs(constraints) do
		if state.Constraint.Parent then
			state.Constraint.Enabled = state.Enabled
		end
	end
end

-- ============================================================================
-- IMPACT
-- ============================================================================

local function applyImpact(
	character: Model,
	meta: Meta,
	options: RagdollOptions
)
	local impulse = options.Impulse

	if not impulse or impulse.Magnitude <= 0 then
		return
	end

	local magnitude = math.min(
		impulse.Magnitude,
		RagdollTuning.MaxImpulseMagnitude
	)

	local finalImpulse =
		impulse.Unit * magnitude

	local partName =
		options.ImpulsePart
		or RagdollTuning.DefaultImpulsePart

	task.defer(function()
		if ragdollMeta[character] ~= meta then
			return
		end

		local hitPart =
			findPart(character, partName)

		local root =
			meta.RootPart

		local rootFraction =
			RagdollTuning.ImpulseToRootFraction

		if hitPart and hitPart.Parent then
			hitPart:ApplyImpulse(
				finalImpulse * (1 - rootFraction)
			)
		end

		if root and root.Parent then
			root:ApplyImpulse(
				finalImpulse * rootFraction
			)
		end
	end)
end

-- ============================================================================
-- ENTER
-- ============================================================================

function RagdollService.Enter(
	character: Model,
	options: RagdollOptions?
)
	if ragdollMeta[character] then
		return
	end

	local humanoid =
		character:FindFirstChildOfClass("Humanoid")

	local root =
		findPart(character, "HumanoidRootPart")

	if not humanoid or not root then
		return
	end

	local opts = options or {}

	local reason: RagdollReason =
		opts.Reason or "Debug"

	local parts = getBodyParts(character)

	local motors = getMotors(character)
	local constraints = getPresetConstraints(character)

	-- The most important sanity check in this whole system:
	-- no preset constraints means we refuse to destroy the Motor6D skeleton.
	if #constraints == 0 then
		warn(
			("[RagdollService] %s has no discovered ragdoll constraints. " ..
			"Refusing to enter ragdoll because disabling motors would detach " ..
			"the DOGU body. Mark the constraint folder or constraints with " ..
			"RagdollConstraint=true."):format(character:GetFullName())
		)

		return
	end

	-- Signal cosmetic systems FIRST.
	character:SetAttribute("Ragdolled", true)
	character:SetAttribute("RagdollReason", reason)

	-- Stop procedural Humanoid control.
	local originalAutoRotate =
		humanoid.AutoRotate

	local originalPlatformStand =
		humanoid.PlatformStand

	local originalWalkSpeed =
		humanoid.WalkSpeed

	local originalJumpPower =
		humanoid.JumpPower

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	local partStates,
		collisionPart,
		collisionPartState =
		enterRagdollCollision(
			character,
			parts
		)

	local meta: Meta = {
		Reason = reason,
		EnterTime = os.clock(),

		WakeStance = nil,
		ExitScheduled = false,

		Parts = parts,

		PartStates = partStates,

		Motors = motors,
		Constraints = constraints,

		CollisionPart = collisionPart,
		CollisionPartState = collisionPartState,

		HumanoidAutoRotate = originalAutoRotate,
		HumanoidPlatformStand = originalPlatformStand,
		HumanoidWalkSpeed = originalWalkSpeed,
		HumanoidJumpPower = originalJumpPower,

		RootPart = root,

		IsCorpse =
			character:GetAttribute("IsCorpse") == true,
	}

	ragdollMeta[character] = meta

	-- Physics ownership belongs to the server while the body is loose.
	setServerNetworkOwnership(parts)

	-- Transition order matters.
	--
	-- First enable the passive physical skeleton.
	enableConstraints(constraints)

	-- Then remove the animation skeleton.
	disableMotors(motors)

	if humanoid.Health > 0 then
		humanoid:ChangeState(
			Enum.HumanoidStateType.Physics
		)
	end

	applyImpact(
		character,
		meta,
		opts
	)

	CombatEvents.Ragdolled:Fire(
		character,
		reason
	)
end

-- ============================================================================
-- RECOVERY
-- ============================================================================

local function findWakePosition(
	character: Model,
	root: BasePart
): CFrame
	local extents =
		character:GetExtentsSize()

	local origin =
		root.Position
		+ Vector3.new(0, 5, 0)

	local result = Workspace:Raycast(
		origin,
		Vector3.new(0, -50, 0)
	)

	local _, yaw, _ =
		root.CFrame:ToOrientation()

	local floorY =
		if result
			then result.Position.Y
			else root.Position.Y

	return CFrame.new(
		root.Position.X,
		floorY + extents.Y * 0.5,
		root.Position.Z
	) * CFrame.Angles(0, yaw, 0)
end

function RagdollService.Exit(
	character: Model,
	options: ExitOptions?
)
	local meta =
		ragdollMeta[character]

	if not meta then
		return
	end

	if meta.IsCorpse then
		return
	end

	local opts = options or {}

	local minimum =
		RagdollTuning.MinDuration[meta.Reason] or 0

	local elapsed =
		os.clock() - meta.EnterTime

	if opts.Force ~= true
		and elapsed < minimum then

		if minimum == math.huge then
			return
		end

		if opts.WakeStance then
			meta.WakeStance =
				opts.WakeStance
		end

		if not meta.ExitScheduled then
			meta.ExitScheduled = true

			task.delay(
				minimum - elapsed,
				function()
					if ragdollMeta[character] == meta then
						RagdollService.Exit(
							character,
							{
								Force = true,
								WakeStance = meta.WakeStance,
							}
						)
					end
				end
			)
		end

		return
	end

	local wakeStance =
		opts.WakeStance
		or meta.WakeStance

	local humanoid =
		character:FindFirstChildOfClass("Humanoid")

	local root =
		meta.RootPart

	-- Stop future dragging before restoring the skeleton.
	RagdollService.ReleaseDragHandle(character)

	-- Disable passive skeleton.
	restoreConstraints(meta.Constraints)

	-- Restore Motor6D skeleton.
	restoreMotors(meta.Motors)

	-- Restore normal DOGU collision.
	restoreNormalCollision(meta)

	if humanoid and humanoid.Parent then
		humanoid.AutoRotate =
			meta.HumanoidAutoRotate

		humanoid.PlatformStand =
			meta.HumanoidPlatformStand

		humanoid.WalkSpeed =
			meta.HumanoidWalkSpeed

		humanoid.JumpPower =
			meta.HumanoidJumpPower
	end

	if root and root.Parent then
		root.AssemblyLinearVelocity =
			Vector3.zero

		root.AssemblyAngularVelocity =
			Vector3.zero

		root.CFrame =
			findWakePosition(
				character,
				root
			)
	end

	-- Remove ragdoll state BEFORE IK is allowed to wake up.
	ragdollMeta[character] = nil

	character:SetAttribute(
		"Ragdolled",
		false
	)

	character:SetAttribute(
		"RagdollReason",
		nil
	)

	if humanoid
		and humanoid.Parent
		and humanoid.Health > 0 then

		humanoid:ChangeState(
			Enum.HumanoidStateType.GettingUp
		)
	end

	-- Network ownership and procedural controllers resume only after the
	-- restored Motor6D body has had a moment to settle.
	task.delay(
		RagdollTuning.RecoveryPhysicsSettleTime,
		function()
			if not character.Parent then
				return
			end

			if character:GetAttribute("Ragdolled") == true then
				return
			end

			restoreAutomaticNetworkOwnership(
				meta.Parts
			)
		end
	)

	CombatEvents.RagdollEnded:Fire(
		character,
		meta.Reason
	)

	-- Wake stance is intentionally left as a very small hook rather than
	-- rewriting MovementServer or CharacterController.
	if wakeStance then
		character:SetAttribute(
			"RagdollWakeStance",
			wakeStance
		)
	end
end

-- ============================================================================
-- STATE
-- ============================================================================

function RagdollService.IsRagdolled(
	character: Model
): boolean
	return ragdollMeta[character] ~= nil
end

function RagdollService.GetReason(
	character: Model
): RagdollReason?
	local meta =
		ragdollMeta[character]

	if meta then
		return meta.Reason
	end

	return nil
end

-- ============================================================================
-- DEATH CORPSE SNAPSHOT
-- ============================================================================

local function copyPhysicsState(
	source: Model,
	corpse: Model
)
	for _, sourcePart in ipairs(
		getBodyParts(source)
	) do
		local corpsePart =
			findPart(
				corpse,
				sourcePart.Name
			)

		if corpsePart then
			corpsePart.CFrame =
				sourcePart.CFrame

			corpsePart.AssemblyLinearVelocity =
				sourcePart.AssemblyLinearVelocity

			corpsePart.AssemblyAngularVelocity =
				sourcePart.AssemblyAngularVelocity
		end
	end
end

local function stripCorpseRuntimeControllers(
	corpse: Model
)
	for _, descendant in ipairs(
		corpse:GetDescendants()
	) do
		-- The corpse should not run live IK.
		if descendant:IsA("IKControl") then
			descendant:Destroy()
		end

		-- Scripts inside the character clone must never become a second
		-- character controller.
		if descendant:IsA("LocalScript")
			or descendant:IsA("Script") then

			descendant.Disabled = true
		end
	end
end

function RagdollService.CreateDeathCorpse(
	sourceCharacter: Model,
	options: RagdollOptions?
): Model?
	if sourceCharacter:GetAttribute("DeathCorpseCreated") == true then
		return nil
	end

	local sourceMeta =
		ragdollMeta[sourceCharacter]

	if not sourceMeta then
		return nil
	end

	sourceCharacter:SetAttribute(
		"DeathCorpseCreated",
		true
	)

	local oldArchivable =
		sourceCharacter.Archivable

	sourceCharacter.Archivable = true

	local corpse =
		sourceCharacter:Clone()

	sourceCharacter.Archivable =
		oldArchivable

	corpse.Name =
		sourceCharacter.Name .. "_Corpse"

	corpse:SetAttribute(
		"IsCorpse",
		true
	)

	corpse:SetAttribute(
		"DeathCorpseCreated",
		true
	)

	stripCorpseRuntimeControllers(corpse)

	-- Parent before physics setup so the clone is a real Workspace object.
	corpse.Parent =
		getRagdollsFolder()

	-- Important:
	-- The clone inherits the current physical pose, but we explicitly copy
	-- all body CFrames and velocities to guarantee that the corpse snapshot
	-- matches the falling body at this moment.
	copyPhysicsState(
		sourceCharacter,
		corpse
	)

	-- The cloned character may inherit Ragdolled=true and disabled motors
	-- already. Clear the attribute so Enter performs a clean registration.
	corpse:SetAttribute(
		"Ragdolled",
		false
	)

	corpse:SetAttribute(
		"RagdollReason",
		nil
	)

	local corpseHumanoid =
		corpse:FindFirstChildOfClass("Humanoid")

	if corpseHumanoid then
		corpseHumanoid.BreakJointsOnDeath =
			false

		corpseHumanoid.DisplayDistanceType =
			Enum.HumanoidDisplayDistanceType.None

		corpseHumanoid.AutoRotate =
			false

		corpseHumanoid.PlatformStand =
			true

		corpseHumanoid.WalkSpeed = 0
		corpseHumanoid.JumpPower = 0
	end

	local opts = options or {}

	RagdollService.Enter(
		corpse,
		{
			Reason = "Death",
			Impulse = opts.Impulse,
			ImpulsePart = opts.ImpulsePart,
		}
	)

	local corpseParts =
		getBodyParts(corpse)

	corpses[corpse] = {
		Parts = corpseParts,
		LastMotionTime = os.clock(),
		Anchored = false,
	}

	corpse.Destroying:Connect(function()
		RagdollService.ReleaseDragHandle(corpse)

		corpses[corpse] = nil
		ragdollMeta[corpse] = nil
	end)

	local despawnTime =
		RagdollTuning.CorpseDespawnTime

	if despawnTime
		and despawnTime < math.huge then

		task.delay(
			despawnTime,
			function()
				if corpse.Parent then
					corpse:Destroy()
				end
			end
		)
	end

	return corpse
end

-- ============================================================================
-- CORPSE SLEEP / WAKE
-- ============================================================================

function RagdollService.WakeCorpse(
	corpse: Model
)
	local entry =
		corpses[corpse]

	if not entry then
		return
	end

	if entry.Anchored then
		for _, part in ipairs(entry.Parts) do
			if part.Parent then
				part.Anchored = false
			end
		end

		setServerNetworkOwnership(
			entry.Parts
		)

		entry.Anchored = false
	end

	entry.LastMotionTime =
		os.clock()
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()

	for corpse, entry in pairs(corpses) do
		if not corpse.Parent then
			corpses[corpse] = nil
			continue
		end

		if entry.Anchored then
			continue
		end

		local moving = false

		for _, part in ipairs(entry.Parts) do
			if part.Parent then
				if part.AssemblyLinearVelocity.Magnitude
					> RagdollTuning.IdleLinearVelocityThreshold

					or part.AssemblyAngularVelocity.Magnitude
						> RagdollTuning.IdleAngularVelocityThreshold then

					moving = true
					break
				end
			end
		end

		if moving then
			entry.LastMotionTime = now

		elseif now - entry.LastMotionTime
			>= RagdollTuning.IdleAnchorDelay then

			-- Do not anchor while someone is actively dragging it.
			if not dragHandles[corpse] then
				for _, part in ipairs(entry.Parts) do
					if part.Parent then
						part.Anchored = true
					end
				end

				entry.Anchored = true
			end
		end
	end
end)

-- ============================================================================
-- FUTURE PART-BASED DRAGGING
-- ============================================================================

function RagdollService.AttachDragHandle(
	character: Model,
	options: DragOptions
): boolean
	local meta =
		ragdollMeta[character]

	if not meta then
		return false
	end

	local targetPart: (MeshPart || BasePart)? = nil

	if typeof(options.Part) == "string" then
		targetPart =
			findPart(
				character,
				options.Part
			)

	elseif typeof(options.Part) == "Instance"
		and (options.Part:IsA("MeshPart") or options.Part:IsA("BasePart")) then

		targetPart =
			options.Part
	end

	if not targetPart then
		targetPart =
			meta.RootPart
	end

	if not targetPart.Parent then
		return false
	end

	RagdollService.ReleaseDragHandle(character)

	if corpses[character] then
		RagdollService.WakeCorpse(character)
	end

	local attachment =
		Instance.new("Attachment")

	attachment.Name =
		"RagdollDragAttachment"

	attachment.Parent =
		targetPart

	local alignPosition =
		Instance.new("AlignPosition")

	alignPosition.Name =
		"RagdollDragAlignPosition"

	alignPosition.Attachment0 =
		attachment

	alignPosition.Attachment1 =
		options.TargetAttachment

	alignPosition.ApplyAtCenterOfMass =
		false

	alignPosition.MaxForce =
		RagdollTuning.DragMaxForce

	alignPosition.MaxVelocity =
		RagdollTuning.DragMaxVelocity

	alignPosition.Responsiveness =
		RagdollTuning.DragResponsiveness

	alignPosition.Parent =
		attachment

	dragHandles[character] = {
		Part = targetPart,
		Attachment = attachment,
		AlignPosition = alignPosition,
	}

	return true
end

function RagdollService.ReleaseDragHandle(
	character: Model
)
	local handle =
		dragHandles[character]

	if not handle then
		return
	end

	if handle.AlignPosition.Parent then
		handle.AlignPosition:Destroy()
	end

	if handle.Attachment.Parent then
		handle.Attachment:Destroy()
	end

	dragHandles[character] = nil
end

-- ============================================================================
-- IMPACT HAND-OFF
-- ============================================================================

function RagdollService.RegisterPendingImpact(
	character: Model,
	impulse: Vector3,
	impulsePartName: string?
)
	pendingImpact[character] = {
		Impulse = impulse,
		ImpulsePart = impulsePartName,
	}
end

function RagdollService.ConsumePendingImpact(
	character: Model
): (Vector3?, string?)
	local data =
		pendingImpact[character]

	pendingImpact[character] = nil

	if not data then
		return nil, nil
	end

	return data.Impulse,
		data.ImpulsePart
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function RagdollService.Cleanup(
	character: Model
)
	RagdollService.ReleaseDragHandle(character)

	ragdollMeta[character] = nil
	pendingImpact[character] = nil

	-- Only remove corpse bookkeeping when the corpse itself is destroyed.
	-- Calling Cleanup on the original player character during respawn must NOT
	-- touch a separately cloned corpse.
	if corpses[character] then
		corpses[character] = nil
	end
end

return RagdollService