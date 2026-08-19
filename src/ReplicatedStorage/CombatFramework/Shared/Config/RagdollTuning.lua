--!strict
--[[
	RagdollTuning.lua

	DOGU15 / custom R15 ragdoll tuning.

	This system assumes the rig ALREADY contains its ragdoll constraints and their
	attachments. The service does not manufacture a second skeleton of constraints.

	The important architecture is:

	ALIVE
		Motor6Ds enabled
		Preset ragdoll constraints disabled
		DOGU CollisionPart handles normal character collision

	RAGDOLLED
		Motor6Ds disabled
		Preset ragdoll constraints enabled
		DOGU CollisionPart disabled
		Actual body parts become the physical collision body

	DEATH
		The original character ragdolls first.
		After DeathCorpseCloneDelay, its CURRENT ragdoll pose and velocity are cloned
		into Workspace.Ragdolls.

	This means the corpse is not a fresh upright clone appearing the instant the
	player dies. It is a snapshot of the body after it has already started falling.
]]

export type RagdollReason =
	"Death"
	| "Asphyxiation"
	| "Stun"
	| "Impact"
	| "Debug"

return {
	MinDuration = {
		Death = math.huge,
		Asphyxiation = 6,
		Stun = 1.5,
		Impact = 1.0,
		Debug = 0,
	} :: { [string]: number },

	-- =========================================================================
	-- DEATH / CORPSES
	-- =========================================================================

	-- The original player character is ragdolled immediately.
	-- The persistent corpse is cloned only after this delay.
	DeathCorpseCloneDelay = 0.35,

	-- How long a corpse remains after being cloned.
	CorpseDespawnTime = 180,

	-- Corpse becomes anchored only after being genuinely still for this long.
	IdleAnchorDelay = 5,

	IdleLinearVelocityThreshold = 0.35,
	IdleAngularVelocityThreshold = 0.35,

	-- =========================================================================
	-- IMPACT
	-- =========================================================================

	-- Safety ceiling. This is an impulse magnitude, not a velocity.
	MaxImpulseMagnitude = 4500,

	-- If an impact has no specified limb.
	DefaultImpulsePart = "UpperTorso",

	-- A small amount of an impact is shared with the torso/root so the entire
	-- body reacts, while the struck limb still receives the majority.
	ImpulseToRootFraction = 0.2,

	-- =========================================================================
	-- COLLISION
	-- =========================================================================

	CollisionPartName = "CollisionPart",

	-- HumanoidRootPart is deliberately not used as a physical collision body.
	-- It remains a utility/control part.
	AlwaysNonCollidable = {
		"HumanoidRootPart",
	},

	-- Every actual visible/physical limb that should collide with the world.
	-- Hands are included because future grabbing/dragging and corpse interaction
	-- should use the actual body.
	CollidableBodyParts = {
		"Head",

		"UpperTorso",
		"LowerTorso",

		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",

		"RightUpperArm",
		"RightLowerArm",
		"RightHand",

		"LeftUpperLeg",
		"LeftLowerLeg",
		"LeftFoot",

		"RightUpperLeg",
		"RightLowerLeg",
		"RightFoot",
	},

	-- =========================================================================
	-- PRESET CONSTRAINT DISCOVERY
	-- =========================================================================

	-- A constraint is considered a ragdoll constraint if:
	--
	-- 1. It or one of its ancestors has RagdollConstraint = true
	-- 2. It is inside one of these folders
	-- 3. It is explicitly named with one of these prefixes
	--
	-- This avoids blindly enabling unrelated constraints in the DOGU rig.
	ConstraintFolderNames = {
		"RagdollConstraints",
		"Ragdoll",
		"Constraints",
		"PhysicsConstraints",
	},

	ConstraintNamePrefixes = {
		"Ragdoll_",
		"Ragdoll",
	},

	-- =========================================================================
	-- RECOVERY
	-- =========================================================================

	ProneFloorOffset = 1.1,

	-- How long to wait after Motor6Ds are restored before procedural systems
	-- are allowed to take ownership again.
	RecoveryPhysicsSettleTime = 0.05,

	-- =========================================================================
	-- FUTURE PHYSICS GRAB / DRAG
	-- =========================================================================

	DragMaxForce = 25000,
	DragMaxVelocity = 18,
	DragResponsiveness = 25,

	-- Future callers can pass ANY actual body part, rather than only the root.
	-- This is what makes grabbing a hand, foot, arm, torso, etc. possible.
}