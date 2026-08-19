--!strict
--[[
	AsphyxiationEffectTuning.lua

	All visual/audio intensity mapped from a single 0-1 "criticality" value `t`:
	  t = 0  -> oxygen at/above BreathTuning.CriticalOxygenFraction, no effect at all
	  t = 1  -> oxygen at 0 (the instant Asphyxiated fires)
	Every UI/lighting/audio/camera property below is just a Lerp(low, high, t) -- one knob
	driving everything in sync, rather than each effect tracking oxygen independently.
]]

return {
	-- Local smoothing: OxygenChanged only arrives every ~2 oxygen points (throttled
	-- server-side), so the displayed value is smoothed toward the latest sample rather
	-- than snapping, to avoid a visibly stepped vignette.
	SmoothingRate = 4,
    EffectTweenTime = 0.9,      -- default smoothing duration for routine OxygenChanged updates
	AsphyxiationSnapTime = 0.35, -- faster tween specifically for the Asphyxiated/Recovered transition

	-- Main frame (tunnel vision aperture)
	MainSizeScaleAtFull = 25, -- t = 0
	MainSizeScaleAtCritical = 1, -- t = 1, smallest the hole gets

	-- Static overlay
	StaticTransparencyAtFull = 1,
	StaticTransparencyAtCritical = 0.8,
	StaticTileSizeAtFull = 0.05,
	StaticTileSizeAtCritical = 2,
	StaticJitterInterval = 0.06, -- seconds between random offset shifts, on top of tile growth

	-- Vignette / Darkness overlay(s)
	VignetteTransparencyAtFull = 1,
	VignetteTransparencyAtCritical = 0.1,
	DarknessTransparencyAtFull = 1,
	DarknessTransparencyAtCritical = 0,

	-- Lighting.CombatframeworkAsphyxiation (ColorCorrectionEffect)
	SaturationAtFull = 0,
	SaturationAtCritical = -1,
	TintAtFull = Color3.new(1, 1, 1),
	TintAtCritical = Color3.new(0, 0, 0),

	-- Blur (created at runtime -- no manually-authored instance for this one)
	BlurSizeAtFull = 0,
	BlurSizeAtCritical = 10,

	-- Camera shake (weakness tremor)
	CameraShakeMagnitudeAtCritical = 2.5,

	-- Audio muffle (progressive "going deaf")
	AudioHighGainAtCritical = -22,
	AudioMidGainAtCritical = -10,

	-- Recovery: on Recovered, snap the local smoothed value to correspond to this
	-- oxygen fraction so the effect visibly clears fast instead of crawling back down.
	RecoveryOxygenFractionSnap = 1,
}