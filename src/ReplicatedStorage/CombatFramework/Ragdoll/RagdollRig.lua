--!strict
--[[
	RagdollRig.lua

	Pure rig plumbing: disables the ragdoll-relevant Motor6Ds (handing control to the
	pre-existing IK constraints DOGU15 already has for most joints), builds temporary
	constraints for the two joints that don't have a pre-built one (Waist, Root), applies
	RagdollConstraintLimits' angle/friction numbers to every joint's constraint (restoring
	whatever it had before on Teardown), and moves every body part into a dedicated
	collision group so CanCollide actually takes effect regardless of whatever locomotion
	collision rules the character's parts normally live under.

	Knows nothing about damage, death, corpses, or the rest of the framework —
	RagdollController owns that (including forcing HumanoidStateType.Physics, which is what
	actually stops Roblox's own alive-Humanoid collision suppression on limbs — CanCollide/
	CollisionGroup alone weren't enough for that case).

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
local RagdollConstraintLimits = RagdollJoints.ConstraintLimits

local RagdollRig = {}

type SavedBallSocketLimits = {
	Kind: "BallSocket",
	UpperAngle: number,
	TwistLowerAngle: number,
	TwistUpperAngle: number,
	LimitsEnabled: boolean,
	TwistLimitsEnabled: boolean,
}

type SavedHingeLimits = {
	Kind: "Hinge",
	LowerAngle: number,
	UpperAngle: number,
	Restitution: number,
	LimitsEnabled: boolean,
}

type SavedLimits = SavedBallSocketLimits | SavedHingeLimits

export type BuiltRig = {
	Motor6Ds: { Motor6D }, -- disabled, restored on Teardown
	ReusedConstraints: { Constraint }, -- pre-existing rig constraints; limits restored, left running
	CreatedConstraints: { Constraint }, -- Waist/Root — built by us, destroyed on Teardown
	CreatedAttachments: { Attachment }, -- Waist/Root's own attachments — destroyed on Teardown
	Frictions: { AngularVelocity }, -- one per joint, destroyed on Teardown
	PreviousLimits: { [Constraint]: SavedLimits }, -- ReusedConstraints only
	Parts: { BasePart }, -- every collidable body part, collision/group restored on Teardown
	PreviousCanCollide: { [BasePart]: boolean },
	PreviousCollisionGroup: { [BasePart]: string },
}

do
	local ok, err = pcall(function()
		PhysicsService:RegisterCollisionGroup(RagdollTuning.RagdollCollisionGroup)
	end)
	if not ok and not tostring(err):find("already exists") then
		warn(`RagdollRig: failed to register collision group "{RagdollTuning.RagdollCollisionGroup}": {err}`)
	end
	-- Defensive: a fresh group defaults to colliding with everything, but if this project
	-- has project-wide setup elsewhere that disables cross-group collision broadly, force
	-- the pairing that actually matters (ragdolls hitting the floor) back on explicitly.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(RagdollTuning.RagdollCollisionGroup, "Default", true)
	end)
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
			if not descendant.Name:match("NoCollision$") then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

local function addFriction(rig: BuiltRig, jointName: string, attachment0: Attachment, frictionTorque: number?)
	print(`RagdollRig: adding friction for {jointName} (Attachment0={attachment0:GetFullName()})`)
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

--- Applies RagdollConstraintLimits[jointName] to an already-Enabled reused constraint,
--- saving whatever it had beforehand into rig.PreviousLimits for Teardown to restore.
local function applyLimitsToReusedConstraint(rig: BuiltRig, jointName: string, constraint: Constraint)
	local limits = RagdollConstraintLimits[jointName]
	if not limits then
		warn(`RagdollRig: no RagdollConstraintLimits entry for "{jointName}" — leaving its constraint's limits untouched.`)
		return
	end

	if constraint:IsA("BallSocketConstraint") then
		rig.PreviousLimits[constraint] = {
			Kind = "BallSocket",
			UpperAngle = constraint.UpperAngle,
			TwistLowerAngle = constraint.TwistLowerAngle,
			TwistUpperAngle = constraint.TwistUpperAngle,
			LimitsEnabled = constraint.LimitsEnabled,
			TwistLimitsEnabled = constraint.TwistLimitsEnabled,
		}
		constraint.LimitsEnabled = true
		constraint.UpperAngle = limits.UpperAngle
		constraint.TwistLimitsEnabled = true
		constraint.TwistLowerAngle = limits.TwistLowerAngle
		constraint.TwistUpperAngle = limits.TwistUpperAngle
	elseif constraint:IsA("HingeConstraint") then
		-- Hinge has no separate cone angle — only the Twist* pair applies, mapped onto
		-- Hinge's own LowerAngle/UpperAngle. limits.UpperAngle is unused for Hinge joints.
		rig.PreviousLimits[constraint] = {
			Kind = "Hinge",
			LowerAngle = constraint.LowerAngle,
			UpperAngle = constraint.UpperAngle,
			Restitution = constraint.Restitution,
			LimitsEnabled = constraint.LimitsEnabled,
		}
		constraint.LimitsEnabled = true
		constraint.LowerAngle = limits.TwistLowerAngle
		constraint.UpperAngle = limits.TwistUpperAngle
		constraint.Restitution = limits.Restitution or 0
	end
end

local function restoreReusedConstraintLimits(rig: BuiltRig, constraint: Constraint)
	local saved = rig.PreviousLimits[constraint]
	if not saved or not constraint.Parent then
		return
	end
	if saved.Kind == "BallSocket" and constraint:IsA("BallSocketConstraint") then
		constraint.UpperAngle = saved.UpperAngle
		constraint.TwistLowerAngle = saved.TwistLowerAngle
		constraint.TwistUpperAngle = saved.TwistUpperAngle
		constraint.LimitsEnabled = saved.LimitsEnabled
		constraint.TwistLimitsEnabled = saved.TwistLimitsEnabled
	elseif saved.Kind == "Hinge" and constraint:IsA("HingeConstraint") then
		constraint.LowerAngle = saved.LowerAngle
		constraint.UpperAngle = saved.UpperAngle
		constraint.Restitution = saved.Restitution
		constraint.LimitsEnabled = saved.LimitsEnabled
	end
end

--- Disables every ragdoll-relevant Motor6D, applies RagdollConstraintLimits to every
--- joint's constraint (reused or newly-built), and enables collision (CanCollide +
--- dedicated CollisionGroup) on every real body part. Returns a BuiltRig handle to pass to
--- Teardown().
function RagdollRig.Build(character: Model): BuiltRig
	local rig: BuiltRig = {
		Motor6Ds = {},
		ReusedConstraints = {},
		CreatedConstraints = {},
		CreatedAttachments = {},
		Frictions = {},
		PreviousLimits = {},
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
				applyLimitsToReusedConstraint(rig, motor.Name, constraint :: Constraint)

				local attachment0 = (constraint :: any).Attachment0 :: Attachment?
				local limits = RagdollConstraintLimits[motor.Name]
				if attachment0 then
					addFriction(rig, motor.Name, attachment0, limits and limits.MaxFrictionTorque)
				end
			else
				warn(`RagdollRig: expected {existing.ConstraintName} ({existing.ConstraintClass}) next to {motor.Name} but it's missing/wrong class — that joint will be limp (no limits, no collision-driven correction) until this is fixed.`)
			end
			continue
		end

		-- Fallback path: Waist / Root, no pre-built constraint exists.
		if not FallbackJoints[motor.Name] then
			continue
		end
		local limits = RagdollConstraintLimits[motor.Name]
		if not limits then
			warn(`RagdollRig: no RagdollConstraintLimits entry for fallback joint "{motor.Name}" — skipping, it will be limp.`)
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
		socket.UpperAngle = limits.UpperAngle
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = limits.TwistLowerAngle
		socket.TwistUpperAngle = limits.TwistUpperAngle
		socket.Enabled = true
		socket.Parent = part0
		table.insert(rig.CreatedConstraints, socket)

		addFriction(rig, motor.Name, attachment0, limits.MaxFrictionTorque)
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
--- restores every reused constraint's original limits, re-enables the Motor6Ds, and
--- restores CanCollide/CollisionGroup.
function RagdollRig.Teardown(rig: BuiltRig)
	for _, friction in ipairs(rig.Frictions) do
		friction:Destroy()
	end
	for _, constraint in ipairs(rig.ReusedConstraints) do
		restoreReusedConstraintLimits(rig, constraint)
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