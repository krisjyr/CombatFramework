--!strict
--[[
	RagdollRig.lua

	Pure rig plumbing: disables the ragdoll-relevant Motor6Ds (handing control to the
	pre-existing IK constraints DOGU15 already has for most joints — see RagdollJoints.lua's
	header for why that's safe/correct), builds temporary constraints for the two joints
	that don't have a pre-built one (Waist, Root), moves every body part into a dedicated
	collision group so CanCollide actually takes effect regardless of whatever locomotion
	collision rules the character's parts normally live under, and reverses all of it on
	Teardown.

	Knows nothing about damage, death, corpses, or the rest of the framework —
	RagdollController owns that.

	UNIVERSAL BY DESIGN: everything here operates on BasePart (Motor6D.Part0/Part1,
	Attachment, Constraint, CanCollide, CollisionGroup) — none of it cares whether the parts
	are Part or MeshPart, so it works on DOGU15 or any other similarly-built R15 rig without
	changes, PROVIDED that rig either has the same `<Name>Constraint`/`NeckBallSocket`
	siblings for its limb Motor6Ds, or you extend RagdollJoints.Existing/Fallback to match.
]]

local PhysicsService = game:GetService("PhysicsService")

local RagdollJoints = require(script.Parent.Parent.Shared.Config.RagdollJoints)
local RagdollTuning = require(script.Parent.Parent.Shared.Config.RagdollTuning)

local ExistingJoints = RagdollJoints.Existing
local FallbackJoints = RagdollJoints.Fallback

local RagdollRig = {}

export type BuiltRig = {
	Motor6Ds: { Motor6D }, -- disabled, restored on Teardown
	ReusedConstraints: { Constraint }, -- pre-existing rig constraints we just verified/left running
	CreatedConstraints: { Constraint }, -- Waist/Root — built by us, destroyed on Teardown
	CreatedAttachments: { Attachment }, -- Waist/Root's own attachments — destroyed on Teardown
	Frictions: { AngularVelocity }, -- one per joint (both reused and created), destroyed on Teardown
	Parts: { BasePart }, -- every collidable body part, collision/group restored on Teardown
	PreviousCanCollide: { [BasePart]: boolean },
	PreviousCollisionGroup: { [BasePart]: string },
}

-- Registering an already-registered group errors, so this is guarded and only ever run
-- once per server (module-level, not per-Build call).
do
	local ok, err = pcall(function()
		PhysicsService:RegisterCollisionGroup(RagdollTuning.RagdollCollisionGroup)
	end)
	if not ok and not tostring(err):find("already exists") then
		warn(`RagdollRig: failed to register collision group "{RagdollTuning.RagdollCollisionGroup}": {err}`)
	end
end

local function findJointMotors(character: Model): { Motor6D }
	local motors = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Motor6D") and (ExistingJoints[descendant.Name] or FallbackJoints[descendant.Name]) then
			table.insert(motors, descendant)
		end
	end
	return motors
end

local function collectBodyParts(character: Model): { BasePart }
	local parts = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			-- Skip the framework's own zero-mass helper parts (e.g. CollisionPart is a
			-- deliberate separate hitbox, not a limb) and the *NoCollision spacer parts
			-- the stock rig uses to prevent adjacent-limb self-collision.
			if not descendant.Name:match("NoCollision$") then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

local function addFriction(rig: BuiltRig, jointName: string, attachment0: Attachment, frictionTorque: number?)
	local friction = Instance.new("AngularVelocity")
	friction.Name = "RagdollFriction_" .. jointName
	friction.Attachment0 = attachment0
	friction.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	friction.AngularVelocity = Vector3.zero
	friction.MaxTorque = frictionTorque or RagdollTuning.DefaultFrictionTorque
	friction.Enabled = true
	friction.Parent = attachment0.Parent
	table.insert(rig.Frictions, friction)
end

--- Disables every ragdoll-relevant Motor6D, enables collision on every real body part, and
--- moves those parts into the dedicated ragdoll collision group. For joints DOGU15 already
--- has a constraint for, that constraint is left exactly as authored (just confirmed
--- Enabled) — nothing new is built there. Only Waist/Root get a constraint built on the
--- fly. Returns a BuiltRig handle to pass to Teardown().
function RagdollRig.Build(character: Model): BuiltRig
	local rig: BuiltRig = {
		Motor6Ds = {},
		ReusedConstraints = {},
		CreatedConstraints = {},
		CreatedAttachments = {},
		Frictions = {},
		Parts = {},
		PreviousCanCollide = {},
		PreviousCollisionGroup = {},
	}

	for _, motor in ipairs(findJointMotors(character)) do
		local part0 = motor.Part0
		local part1 = motor.Part1
		if not (part0 and part1) then
			continue
		end

		motor.Enabled = false
		table.insert(rig.Motor6Ds, motor)

		local existing = ExistingJoints[motor.Name]
		if existing then
			local constraint = motor.Parent and motor.Parent:FindFirstChild(existing.ConstraintName)
			if constraint and constraint:IsA(existing.ConstraintClass) then
				(constraint :: any).Enabled = true
				table.insert(rig.ReusedConstraints, constraint)

				local attachment0 = (constraint :: any).Attachment0 :: Attachment?
				if attachment0 then
					addFriction(rig, motor.Name, attachment0, existing.FrictionTorque)
				end
			else
				warn(`RagdollRig: expected {existing.ConstraintName} ({existing.ConstraintClass}) next to {motor.Name} but it's missing/wrong class — that joint will be limp (no limits, no collision-driven correction) until this is fixed.`)
			end
			continue
		end

		-- Fallback path: Waist / Root, no pre-built constraint exists.
		local fallback = FallbackJoints[motor.Name]
		if not fallback then
			continue
		end

		local attachment0 = Instance.new("Attachment")
		attachment0.Name = "Ragdoll_" .. motor.Name .. "_A0"
		attachment0.CFrame = motor.C0
		attachment0.Parent = part0

		local attachment1 = Instance.new("Attachment")
		attachment1.Name = "Ragdoll_" .. motor.Name .. "_A1"
		attachment1.CFrame = motor.C1
		attachment1.Parent = part1

		table.insert(rig.CreatedAttachments, attachment0)
		table.insert(rig.CreatedAttachments, attachment1)

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "Ragdoll_" .. motor.Name
		socket.Attachment0 = attachment0
		socket.Attachment1 = attachment1
		socket.LimitsEnabled = true
		socket.UpperAngle = fallback.UpperAngle
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = fallback.TwistLower
		socket.TwistUpperAngle = fallback.TwistUpper
		socket.Enabled = true
		socket.Parent = part0
		table.insert(rig.CreatedConstraints, socket)

		addFriction(rig, motor.Name, attachment0, fallback.FrictionTorque)
	end

	for _, part in ipairs(collectBodyParts(character)) do
		rig.PreviousCanCollide[part] = part.CanCollide
		rig.PreviousCollisionGroup[part] = part.CollisionGroup
		part.CanCollide = true
		part.CanQuery = true
		part.CollisionGroup = RagdollTuning.RagdollCollisionGroup
		table.insert(rig.Parts, part)
	end

	return rig
end

--- Destroys everything Build() created (friction + Waist/Root constraint/attachments),
--- leaves the rig's own pre-built constraints exactly as they were (still Enabled = true,
--- same as before ragdoll — they're inert again once their Motor6D is re-enabled), and
--- re-enables the Motor6Ds. Restores CanCollide and CollisionGroup to whatever they were
--- before Build() ran.
function RagdollRig.Teardown(rig: BuiltRig)
	for _, friction in ipairs(rig.Frictions) do
		friction:Destroy()
	end
	for _, constraint in ipairs(rig.CreatedConstraints) do
		constraint:Destroy()
	end
	for _, attachment in ipairs(rig.CreatedAttachments) do
		attachment:Destroy()
	end
	for _, motor in ipairs(rig.Motor6Ds) do
		if motor.Parent then
			motor.Enabled = true
		end
	end
	for _, part in ipairs(rig.Parts) do
		if part.Parent then
			part.CanCollide = rig.PreviousCanCollide[part]
			part.CollisionGroup = rig.PreviousCollisionGroup[part]
		end
	end
end

return RagdollRig