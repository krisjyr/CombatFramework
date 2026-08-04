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
	MinDistance = 10, -- studs
	LethalDistance = 65, -- studs of equivalent fall distance (see FallService for how this converts from velocity)
	DamageMultiplier = 1,
	Curve = 2.2,

	-- === Fall feedback (air sound + screenshake) ===
	FastFallVelocity = 60, -- studs/s downward; crossing this starts the air-rush sound + ambient shake
	NotableLandingVelocity = 40, -- studs/s downward; landings faster than this get an impact camera shake
	MaxImpactShakeMagnitude = 6,
	MaxImpactShakeDuration = 0.5,
	MaxAmbientShakeMagnitude = 1.5,
}
