--!strict
--[[
	RagdollService.lua  (Ch 7.7 Consciousness, Ch 7.10 Rescue, Ch 8 Status -- placeholder)

	Server-authoritative IK ragdoll for R15, adapted from the community IK-ragdoll pattern
	(rope-constrained limb targets solved with IKControl) into this framework's
	conventions. Kept server-side deliberately: unlike foot-ground IK (IKLegController.lua,
	fully client-cosmetic), ragdoll involves REAL unanchored-part physics that other
	systems (hit detection, future dragging/rescue) must be able to trust, so it follows
	the same "Movement validation" server-authority rule as everything else in Ch 1.3.

	This is a PLACEHOLDER ahead of the full Status Effect Framework (Ch 8) -- today
	entering/exiting ragdoll is just this service's own Enter/Exit calls, driven by
	whatever calls this (e.g. an Unconscious/Critical consciousness transition once Ch 7 is
	built, or a debug command). Once Ch 8 exists, wire a real "Ragdolled" Status whose
	Removal condition calls RagdollService:Exit, instead of calling Exit directly.

	REPLICATION: Humanoid:ChangeState(Ragdoll) and the constraint/attachment physics
	created below replicate to every client through the normal character-physics
	replication path (these are real, unanchored, server-created physics objects on a
	replicated Model) -- no custom remote is required for other players to SEE the
	ragdoll. IKVisualsBootstrap.client.lua only needs the "Ragdolled" Attribute (set below)
	to know to back off its own foot-ground IK while this is active.

	FUTURE DRAGGING (Ch 7.10 Rescue): AttachDragHandle/ReleaseDragHandle below are stubs a
	future Interaction (Ch 12) can call once a "drag downed teammate" interaction exists --
	they are not wired to any input yet.
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)

local RAGDOLL_COLLISION_GROUP = "IgnoreHitbox"

local LIMB_LIST = {
	"Head", "UpperTorso", "LowerTorso",
	"LeftFoot", "LeftLowerLeg", "LeftUpperLeg",
	"RightFoot", "RightLowerLeg", "RightUpperLeg",
	"LeftHand", "LeftLowerArm", "LeftUpperArm",
	"RightHand", "RightLowerArm", "RightUpperArm",
	"HumanoidRootPart",
}

local ROPE_TARGETS = {
	{ Name = "RH", ChainRootName = "RightUpperArm", EndEffectorName = "RightHand", JointParent = "UpperTorso", JointName = "RightShoulderRigAttachment" },
	{ Name = "LH", ChainRootName = "LeftUpperArm", EndEffectorName = "LeftHand", JointParent = "UpperTorso", JointName = "LeftShoulderRigAttachment" },
	{ Name = "RF", ChainRootName = "RightUpperLeg", EndEffectorName = "RightFoot", JointParent = "LowerTorso", JointName = "RightHipRigAttachment" },
	{ Name = "LF", ChainRootName = "LeftUpperLeg", EndEffectorName = "LeftFoot", JointParent = "LowerTorso", JointName = "LeftHipRigAttachment" },
}

local ROPE_LENGTH = 6

local RagdollService = {}

local ragdolledCharacters: { [Model]: { Instance } } = {}
local dragHandles: { [Model]: { Instance } } = {}
-- Per-limb CollisionGroup restore data, keyed by character. Kept in a plain Lua table
-- (not an Attribute) since Attributes can't store arbitrary key/value maps.
local restoreGroupRegistry: { [Model]: { [string]: string } } = {}

do
	local ok = pcall(function()
		PhysicsService:RegisterCollisionGroup(RAGDOLL_COLLISION_GROUP)
	end)
	-- ok == false just means it's already registered (e.g. hot-reload in Studio); safe to ignore.
	PhysicsService:CollisionGroupSetCollidable(RAGDOLL_COLLISION_GROUP, RAGDOLL_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(RAGDOLL_COLLISION_GROUP, "Default", false)
end

local function setLimbCollisionGroups(character: Model, groupName: string): { [string]: string }
	local restore: { [string]: string } = {}
	for _, limbName in ipairs(LIMB_LIST) do
		local limb = character:FindFirstChild(limbName)
		if limb and limb:IsA("BasePart") then
			restore[limbName] = limb.CollisionGroup
			limb.CollisionGroup = groupName
		end
	end
	return restore
end

local function buildHitbox(character: Model): Model
	local hitbox = Instance.new("Model")
	hitbox.Name = "RagdollHitbox"
	hitbox.Parent = character
	for _, limbName in ipairs(LIMB_LIST) do
		local limb = character:FindFirstChild(limbName)
		if limb and limb:IsA("BasePart") then
			local proxy = Instance.new("Part")
			proxy.Name = limb.Name
			proxy.CanCollide = true
			proxy.Size = limb.Size
			proxy.Transparency = 1
			proxy.CFrame = limb.CFrame
			proxy.Parent = hitbox
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = limb
			weld.Part1 = proxy
			weld.Parent = proxy
		end
	end
	return hitbox
end

local function createRopeTarget(character: Model, humanoid: Humanoid, spec: { [string]: string }, spawned: { Instance })
	local chainRoot = character:FindFirstChild(spec.ChainRootName)
	local endEffector = character:FindFirstChild(spec.EndEffectorName)
	local jointParent = character:FindFirstChild(spec.JointParent)
	local joint = jointParent and jointParent:FindFirstChild(spec.JointName)
	if not (chainRoot and endEffector and joint) then
		return
	end

	local part = Instance.new("Part")
	part.Name = `RagdollIKTarget_{spec.Name}`
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.CFrame = (endEffector :: BasePart).CFrame
	part.Parent = character

	local attachment = Instance.new("Attachment")
	attachment.Visible = false
	attachment.Parent = part

	local rope = Instance.new("RopeConstraint")
	rope.Length = ROPE_LENGTH
	rope.Visible = false
	rope.Attachment0 = joint :: Attachment
	rope.Attachment1 = attachment
	rope.Parent = part

	local ik = Instance.new("IKControl")
	ik.Name = `RagdollIK_{spec.Name}`
	ik.Type = Enum.IKControlType.Position
	ik.ChainRoot = chainRoot
	ik.EndEffector = endEffector
	ik.Target = part
	ik.Parent = humanoid

	table.insert(spawned, part)
	table.insert(spawned, attachment)
	table.insert(spawned, rope)
	table.insert(spawned, ik)
end

--- Enters ragdoll. Idempotent -- calling this on an already-ragdolled character is a no-op.
function RagdollService.Enter(character: Model)
	if ragdolledCharacters[character] then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart then
		return
	end

	local spawned: { Instance } = {}
	local restoreGroups = setLimbCollisionGroups(character, RAGDOLL_COLLISION_GROUP)
	local hitbox = buildHitbox(character)
	table.insert(spawned, hitbox)

	rootPart.Massless = true

	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		local lowerTorso = character:FindFirstChild("LowerTorso")
		local rootMotor = lowerTorso and lowerTorso:FindFirstChild("Root")
		if rootMotor and rootMotor:IsA("Motor6D") then
			rootMotor.Enabled = false
		end
	end

	if humanoid.Health > 0 then
		humanoid:ChangeState(Enum.HumanoidStateType.Ragdoll)
	end

	for _, spec in ipairs(ROPE_TARGETS) do
		createRopeTarget(character, humanoid, spec, spawned)
	end

	ragdolledCharacters[character] = spawned
	restoreGroupRegistry[character] = restoreGroups
	character:SetAttribute("Ragdolled", true)
	character:SetAttribute("RagdollPreWalkSpeed", humanoid.WalkSpeed)
	character:SetAttribute("RagdollPreJumpPower", humanoid.JumpPower)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	CombatEvents.Ragdolled:Fire(character)
end

function RagdollService.Exit(character: Model)
	local spawned = ragdolledCharacters[character]
	if not spawned then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	for _, inst in ipairs(spawned) do
		if inst.Parent then
			inst:Destroy()
		end
	end
	ragdolledCharacters[character] = nil

	local restoreGroups = restoreGroupRegistry[character]
	if restoreGroups then
		for limbName, groupName in pairs(restoreGroups) do
			local limb = character:FindFirstChild(limbName)
			if limb and limb:IsA("BasePart") then
				limb.CollisionGroup = groupName
			end
		end
		restoreGroupRegistry[character] = nil
	end

	if humanoid and rootPart then
		if humanoid.RigType == Enum.HumanoidRigType.R15 then
			local lowerTorso = character:FindFirstChild("LowerTorso")
			local rootMotor = lowerTorso and lowerTorso:FindFirstChild("Root")
			if rootMotor and rootMotor:IsA("Motor6D") then
				rootMotor.Enabled = true
			end
		end

		humanoid.PlatformStand = false
		rootPart.Massless = false

		local restoreCFrame = CFrame.new(rootPart.Position) * CFrame.new(0, character:GetExtentsSize().Y / 2, 0)
		rootPart.Anchored = true
		rootPart.CFrame = restoreCFrame
		rootPart.Anchored = false

		humanoid.WalkSpeed = character:GetAttribute("RagdollPreWalkSpeed") or humanoid.WalkSpeed
		humanoid.JumpPower = character:GetAttribute("RagdollPreJumpPower") or humanoid.JumpPower

		if humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end

	character:SetAttribute("Ragdolled", false)
	CombatEvents.RagdollEnded:Fire(character)
end

function RagdollService.IsRagdolled(character: Model): boolean
	return ragdolledCharacters[character] ~= nil
end

-- === Future Rescue / Dragging (Ch 7.10) =================================

--- Attaches a drag handle so a rescuing player can carry/drag a ragdolled teammate.
--- Not wired to any Interaction (Ch 12) yet -- a future "Drag Teammate" Hold interaction
--- should call this on start and ReleaseDragHandle on interrupt/completion.
function RagdollService.AttachDragHandle(character: Model, dragFromAttachment: Attachment): boolean
	if not ragdolledCharacters[character] then
		return false
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return false
	end

	local anchor = Instance.new("Attachment")
	anchor.Parent = rootPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = anchor
	alignPosition.Attachment1 = dragFromAttachment
	alignPosition.MaxForce = 15000
	alignPosition.MaxVelocity = 12
	alignPosition.Responsiveness = 15
	alignPosition.Parent = anchor

	dragHandles[character] = { anchor, alignPosition }
	return true
end

function RagdollService.ReleaseDragHandle(character: Model)
	local handle = dragHandles[character]
	if not handle then
		return
	end
	for _, inst in ipairs(handle) do
		inst:Destroy()
	end
	dragHandles[character] = nil
end

return RagdollService
