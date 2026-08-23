--!strict
--[[
	RagdollTuning.lua

	Shared constants so RagdollController (Enter/Exit), RagdollServer (death/impulse
	triggers), and CorpseHandler (settle/anchor/lifetime) are calibrated to the same numbers.
]]

return {
	-- Joint friction (AngularVelocity constraint MaxTorque) used when a joint's config in
	-- RagdollJoints.lua doesn't specify its own FrictionTorque.
	DefaultFrictionTorque = 25,

	-- How long a non-lethal ("Impulse"/"Manual") ragdoll lasts before auto-waking, unless
	-- something else calls RagdollAPI:Unragdoll first.
	ImpulseRagdollDuration = 4,

	-- How far above the resting position to lift the character on wake-up, to avoid
	-- clipping into the floor when the rig re-enables Motor6Ds.
	WakeUpLiftStuds = 1.5,

	-- Corpse settle/anchor (CorpseHandler.lua).
	CorpseSettleTime = math.huge, -- seconds of low velocity required before a corpse anchors
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

	-- Roblox suppresses collision on an ALIVE Humanoid's own limbs based on HumanoidState —
	-- CanCollide/CollisionGroup alone aren't enough, RagdollController also forces
	-- HumanoidStateType.Physics for the live-ragdoll case. This is the equivalent setting
	-- for a corpse clone (CorpseHandler.lua): try Dead first; if limbs still don't collide
	-- on corpses, switch this to Enum.HumanoidStateType.Physics instead.
	CorpseHumanoidState = Enum.HumanoidStateType.Physics,

    -- RagdollSounds.lua: how hard a limb has to decelerate (studs/s, one-frame delta) to
    -- count as a landing worth a sound at all, the delta at which it's classified "Medium"
    -- rather than "Soft", and the delta at/above which it's "Hard"/full intensity.
    SoundImpactMinSpeed = 5,
    SoundImpactMediumSpeed = 9,
    SoundImpactHardSpeed = 16,
    -- Minimum time between impact sounds on the same ragdoll — a single landing usually
    -- decelerates several limbs within a frame or two of each other; without this you'd
    -- get a burst of near-simultaneous impact sounds instead of one.
    SoundImpactCooldown = 0.35,

    -- RagdollSounds.lua: horizontal root speed (studs/s) needed to start/keep a scrape
    -- loop, and the speed at which it reaches full volume.
    SoundScrapeMinSpeed = 3,
    SoundScrapeMaxSpeed = 40,

	-- RagdollSounds.lua: how far (studs) straight down from the root a raycast has to hit
    -- a surface to count as "grounded" for scrape purposes. Small on purpose -- this is
    -- checking "is the ragdoll riding along this surface right now", not doing a general
    -- floor-find (contrast with RagdollServer's wake-up raycast, which casts 50 studs to
    -- find A floor to stand on, not to gate a per-frame condition).
    SoundScrapeGroundDistance = 3,

	SoundScrapeSafetyTTL = 1.5,

    -- Whether "Death" ragdolls (not just Impulse/Manual) get impact/scrape sounds. Off
    -- would mean corpses fall silently; on (default) means a corpse hitting the ground or
    -- sliding down a slope still sounds physical.
    PlaySoundsOnDeath = true,
}