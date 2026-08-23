--!strict
--[[
	RagdollJoints.lua

	DOGU15's rig already ships a full constraint skeleton for IK — a HingeConstraint or
	BallSocketConstraint sitting alongside every limb Motor6D, sharing its Attachment0/1.
	This module only says WHERE to find (or, for Waist/Root, how to BUILD) each joint's
	constraint — the actual angle/friction NUMBERS applied while ragdolled live in
	RagdollConstraintLimits.lua, keyed by the same joint names used here.

	ConstraintName is looked up as `motor.Parent:FindFirstChild(ConstraintName)` — every
	existing constraint is parented to the same part as its Motor6D counterpart (confirmed
	against the DOGU15 hierarchy: e.g. RightUpperLeg has both "RightHip" and
	"RightHipConstraint").

	Waist and Root (HumanoidRootPart<->LowerTorso) have no pre-built constraint — without
	breaking those too the torso stays rigidly frozen in its last animated pose while limbs
	flop around it, so RagdollRig.lua builds a temporary BallSocketConstraint for exactly
	those two (using RagdollConstraintLimits.Waist/Root), and tears it back down on
	unragdoll.
]]

export type ExistingJoint = {
	ConstraintName: string,
	ConstraintClass: "BallSocketConstraint" | "HingeConstraint",
}


export type SocketLimits = {
	MaxFrictionTorque: number,
	UpperAngle: number,
	TwistLowerAngle: number,
	TwistUpperAngle: number,
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
 
-- Joints with no pre-built constraint — RagdollRig creates+destroys a BallSocketConstraint
-- for these itself (between the two HITBOX parts, see RagdollRig.lua), using
-- RagdollConstraintLimits[name] for its numbers. Just a set (the value doesn't matter) so
-- RagdollRig can tell "does this Motor6D need ragdoll handling at all" without hardcoding
-- these names in two places. Root is NOT here — HumanoidRootPart isn't cloned into the
-- hitbox skeleton at all, it's just rigidly Welded straight to hitbox-LowerTorso (see
-- RagdollRig.lua) since it only ever needs to track roughly where the torso is, never
-- load-bearing content.
local FallbackJoints: { [string]: true } = {
	Waist = true,
	Root = true,
}


local NECK_LIMITS: SocketLimits = { MaxFrictionTorque = 55, UpperAngle = 35, TwistLowerAngle = -55, TwistUpperAngle = 55 }
local WAIST_LIMITS: SocketLimits = { MaxFrictionTorque = 25, UpperAngle = 40, TwistLowerAngle = -45, TwistUpperAngle = 40 }
local SHOULDER_LIMITS: SocketLimits = { MaxFrictionTorque = 25, UpperAngle = 100, TwistLowerAngle = -55, TwistUpperAngle = 55 }
local ELBOW_LIMITS: SocketLimits = { MaxFrictionTorque = 25, Restitution = 0.2, TwistLowerAngle = 0, TwistUpperAngle = 100 }
local HIP_LIMITS: SocketLimits = { MaxFrictionTorque = 25, UpperAngle = 75, TwistLowerAngle = -45, TwistUpperAngle = 45 }
local KNEE_LIMITS: SocketLimits = { MaxFrictionTorque = 25, Restitution = 0.2, TwistLowerAngle = -110, TwistUpperAngle = 0 }
local WRIST_LIMITS: SocketLimits = { MaxFrictionTorque = 25, UpperAngle = 20, TwistLowerAngle = -70, TwistUpperAngle = 40 }
local ANKLE_LIMITS: SocketLimits = { MaxFrictionTorque = 25, UpperAngle = 10, TwistLowerAngle = -45, TwistUpperAngle = 25 }
local ROOT_LIMITS: SocketLimits = { MaxFrictionTorque = 30, UpperAngle = 15, TwistLowerAngle = -20, TwistUpperAngle = 20 }
 
local RagdollConstraintLimits: { [string]: SocketLimits } = {
	Neck = NECK_LIMITS,
	Waist = WAIST_LIMITS,
	Root = ROOT_LIMITS,
 
	RightShoulder = SHOULDER_LIMITS,
	LeftShoulder = SHOULDER_LIMITS,
 
	RightElbow = ELBOW_LIMITS,
	LeftElbow = ELBOW_LIMITS,
 
	RightHip = HIP_LIMITS,
	LeftHip = HIP_LIMITS,
 
	RightKnee = KNEE_LIMITS,
	LeftKnee = KNEE_LIMITS,
 
	RightWrist = WRIST_LIMITS,
	LeftWrist = WRIST_LIMITS,
 
	RightAnkle = ANKLE_LIMITS,
	LeftAnkle = ANKLE_LIMITS,
}


return {
	Existing = ExistingJoints,
	Fallback = FallbackJoints,
	ConstraintLimits = RagdollConstraintLimits,
}