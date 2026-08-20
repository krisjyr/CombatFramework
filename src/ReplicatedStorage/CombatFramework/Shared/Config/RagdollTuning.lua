--!strict
--[[
	RagdollTuning.lua

	Shared constants so RagdollController (Enter/Exit), RagdollServer (death/impulse
	triggers), and CorpseHandler (settle/anchor/lifetime) are calibrated to the same numbers.
]]

return {
	-- Joint friction (AngularVelocity constraint MaxTorque) used when a joint's config in
	-- RagdollJoints.lua doesn't specify its own FrictionTorque.
	DefaultFrictionTorque = 400,

	-- How long a non-lethal ("Impulse"/"Manual") ragdoll lasts before auto-waking, unless
	-- something else calls RagdollAPI:Unragdoll first.
	ImpulseRagdollDuration = 4,

	-- How far above the resting position to lift the character on wake-up, to avoid
	-- clipping into the floor when the rig re-enables Motor6Ds.
	WakeUpLiftStuds = 1.5,

	-- Corpse settle/anchor (CorpseHandler.lua).
	CorpseSettleTime = 3, -- seconds of low velocity required before a corpse anchors
	CorpseSettleVelocityThreshold = 1.0, -- studs/s; below this counts as "settled"

	-- How long a corpse sticks around (from the moment it's created) before being cleaned
	-- up entirely. math.huge = never auto-clean.
	CorpseLifetime = 120,

	-- Fraction of a hit's impulse applied to the directly-hit part vs. spread across the
	-- rest of the ragdoll's parts (mass-weighted) so a shot still visibly staggers the
	-- whole body, not just the one limb.
	ImpulseFocusFraction = 0.6,

	-- Dedicated PhysicsService CollisionGroup ragdolled parts are moved into for the
	-- duration of the ragdoll (see RagdollRig.lua) so their collision isn't at the mercy of
	-- whatever group normal locomotion parts are in (commonly self/other-player collision
	-- disabled for gameplay reasons, which would otherwise make ragdolls pass through
	-- everything). New PhysicsService groups collide with everything by default; if your
	-- project needs different pairwise rules for this group (e.g. ragdolls ignoring each
	-- other), configure that once via PhysicsService:CollisionGroupSetCollidable wherever
	-- your other collision groups are set up.
	RagdollCollisionGroup = "CombatFrameworkRagdoll",
}