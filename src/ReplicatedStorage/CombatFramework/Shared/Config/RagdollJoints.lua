--!strict
--[[
	RagdollJoints.lua

	DOGU15's rig already ships a full constraint skeleton for IK — a HingeConstraint or
	BallSocketConstraint sitting alongside every limb Motor6D, sharing its Attachment0/1,
	always Enabled = true. While the Motor6D is enabled it drives the part kinematically
	every frame, so the constraint just sits there mechanically satisfied and does nothing;
	the INSTANT the Motor6D is disabled, that constraint is what actually holds the limb
	together within its authored limits. So for every joint the rig already covers, ragdoll
	does NOT create anything new — it just disables the Motor6D and lets the existing
	constraint take over, then re-enables the Motor6D to undo it.

	Two joints are genuinely Motor6D-only with no pre-built counterpart: Waist and Root
	(HumanoidRootPart<->LowerTorso). Without breaking those too the torso stays rigidly
	frozen in its last animated pose while limbs flop around it, so RagdollRig.lua builds a
	temporary BallSocketConstraint for exactly those two (and only those two), using the
	FallbackLimits below, and tears it back down on unragdoll.

	ConstraintName is looked up as `motor.Parent:FindFirstChild(ConstraintName)` — every
	constraint here is parented to the same part as its Motor6D counterpart (confirmed
	against the DOGU15 hierarchy: e.g. RightUpperLeg has both "RightHip" and
	"RightHipConstraint").
]]

export type ExistingJoint = {
	ConstraintName: string,
	ConstraintClass: "BallSocketConstraint" | "HingeConstraint",
	FrictionTorque: number?,
}

export type FallbackJoint = {
	-- No pre-built constraint exists; RagdollRig builds one on the fly using these limits.
	UpperAngle: number,
	TwistLower: number,
	TwistUpper: number,
	FrictionTorque: number?,
}

-- Joints the rig already has IK constraints for (reuse, don't duplicate).
local ExistingJoints: { [string]: ExistingJoint } = {
	Neck = { ConstraintName = "NeckBallSocket", ConstraintClass = "BallSocketConstraint" },

	RightHip = { ConstraintName = "RightHipConstraint", ConstraintClass = "BallSocketConstraint" },
	LeftHip = { ConstraintName = "LeftHipConstraint", ConstraintClass = "BallSocketConstraint" },

	RightShoulder = { ConstraintName = "RightShoulderConstraint", ConstraintClass = "BallSocketConstraint" },
	LeftShoulder = { ConstraintName = "LeftShoulderConstraint", ConstraintClass = "BallSocketConstraint" },

	RightWrist = { ConstraintName = "RightWristConstraint", ConstraintClass = "BallSocketConstraint" },
	LeftWrist = { ConstraintName = "LeftWristConstraint", ConstraintClass = "BallSocketConstraint" },

	RightAnkle = { ConstraintName = "RightAnkleConstraint", ConstraintClass = "BallSocketConstraint" },
	LeftAnkle = { ConstraintName = "LeftAnkleConstraint", ConstraintClass = "BallSocketConstraint" },

	RightKnee = { ConstraintName = "RightKneeConstraint", ConstraintClass = "HingeConstraint" },
	LeftKnee = { ConstraintName = "LeftKneeConstraint", ConstraintClass = "HingeConstraint" },

	RightElbow = { ConstraintName = "RightElbowConstraint", ConstraintClass = "HingeConstraint" },
	LeftElbow = { ConstraintName = "LeftElbowConstraint", ConstraintClass = "HingeConstraint" },
}

-- Joints with no pre-built constraint — RagdollRig creates+destroys these itself.
-- Placeholder numbers (not part of the user's spec); tune in Studio. Root is left almost
-- fully unconstrained rotation-wise since nobody ever looks at HumanoidRootPart's
-- orientation directly, it only needs to stay positionally tethered to LowerTorso.
local FallbackJoints: { [string]: FallbackJoint } = {
	Waist = { UpperAngle = 20, TwistLower = -20, TwistUpper = 20 },
	Root = { UpperAngle = 180, TwistLower = -180, TwistUpper = 180, FrictionTorque = 150 },
}

return {
	Existing = ExistingJoints,
	Fallback = FallbackJoints,
}