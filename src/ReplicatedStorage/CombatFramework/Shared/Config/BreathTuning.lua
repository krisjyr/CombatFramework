--!strict
--[[
	BreathTuning.lua  (Ch 2.8 Stamina/Breathing extension)

	Shared constants for the Oxygen/Breath system. Kept separate from FallTuning.lua --
	different subsystem, different owner (BreathController vs FallService), same
	"one tuning file per subsystem, everything else reads it" convention.
]]

return {
	MaxOxygen = 100,
	NormalRecoveryRate = 4,     -- oxygen/sec regained while NOT holding and NOT in a drain zone
	HoldDrainRate = 10,          -- additional oxygen/sec consumed while voluntarily holding breath
	MaxHoldDuration = 30,       -- seconds; hard cap regardless of remaining oxygen, forces release

	-- Breath tier thresholds, evaluated against min(oxygenFraction, staminaFraction) --
	-- "how much air do I have" from whichever source is currently worse.
	CalmThreshold = 0.7,
	MediumThreshold = 0.45,     -- below CalmThreshold and >= this = Medium; below this = Heavy

	CriticalOxygenFraction = 0.5, -- future UI hook: vignette should start appearing at/below this

	-- Placeholder incapacitation (Ch7 Consciousness System will replace this block wholesale)
	AsphyxiationSpeedMultiplier = 0,
	AsphyxiationRecoverTime = 10, -- seconds before a placeholder "wakes back up"
	AsphyxiationWakeOxygenFraction = 0.1, -- oxygen level restored on waking, not a full refill
}