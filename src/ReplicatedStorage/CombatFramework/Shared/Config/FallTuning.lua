--!strict
--[[
	FallTuning.lua

	Shared constants for fall damage AND fall feedback (air sound, screenshake), so the
	server's damage curve and the client's cosmetic thresholds are always calibrated to
	the same numbers instead of two separately-hardcoded copies drifting apart.
]]

return {
	-- === Fall damage curve (FallService.lua) ===
	-- Below MinDistance: always safe. At/above LethalDistance: guaranteed death (100 dmg,
	-- scaled by a group/custom DamageMultiplier). Curve > 1 means a fall just past
	-- MinDistance barely hurts, and damage ramps sharply only as you approach LethalDistance
	-- — i.e. low falls stay forgiving, but you need real height to actually die.
	MinDistance = 6, -- studs
	LethalDistance = 38, -- studs of equivalent fall distance (see FallService for how this converts from velocity)
	DamageMultiplier = 1,
	Curve = 2.2,

	-- === Fall feedback (air sound + screenshake) ===
	FastFallVelocity = 60, -- studs/s downward; crossing this starts the air-rush sound + ambient shake
	NotableLandingVelocity = 60, -- studs/s downward; landings faster than this get an impact camera shake
	MaxImpactShakeMagnitude = 6,
	MaxImpactShakeDuration = 0.5,
	MaxAmbientShakeMagnitude = 1.5,

	-- FallService.lua ragdoll-slide tracking: speed (studs/s) while ragdolled needed to
    -- trigger the same FastFall camera-shake/feedback a vertical plummet gets. Falls back
    -- to FastFallVelocity if unset.
    RagdollSlideFastFallVelocity = 20,

    -- Peak slide speed must have reached at least this before a stop counts as damage-
    -- worthy at all -- keeps a minor stumble-to-a-stop from ever being lethal.
    RagdollSlideMinPeakSpeed = 14,

    -- One-frame speed drop (studs/s) that counts as "came to a sudden stop" while
    -- ragdoll-sliding -- same "diff this frame vs last frame" technique
    -- RagdollSounds.lua's impact detection already uses, just on overall root speed
    -- instead of per-limb.
    RagdollSlideStopDeceleration = 20,

    -- Minimum seconds between ragdoll-slide-stop damage events per character.
    RagdollSlideImpactCooldown = 1,

	RagdollOnLandingDuration = 3, -- seconds to ragdoll on landing (if alive) before auto-wake, math.huge = never auto-wake
}
