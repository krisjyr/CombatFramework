--!strict
--[[
	CameraEffects.lua  (client-only, Ch 2.9 Camera)

	Per-effect on/off toggle, independently for first-person and third-person. Read by
	CameraMotion.lua every frame — no restart required to change these while testing.

	MOVEMENT INERTIA (a.k.a. "strafe lean" — the lateral/positional camera offset that
	reacts to strafing) defaults OFF in third person: in first person the camera IS the
	head, so a strafe-reactive offset reads as body lean/weight shift. In third person the
	camera is already trailing the character at a fixed offset behind an independently-
	leaning body — stacking a second, camera-local strafe reaction on top of that reads as
	the camera itself sliding/swimming rather than any physical lean, which is what looked
	wrong. Head bob / turn lean / sprint lean / landing spring are comparatively harmless
	in third person (they read as camera-follow personality) so they default on there too,
	but every effect is independently toggleable per mode below.
]]

export type EffectToggles = {
	HeadBob: boolean,
	MovementInertia: boolean, -- the lateral/positional "strafe lean" offset
	TurnLean: boolean,        -- roll while turning
	SprintLean: boolean,      -- forward pitch while sprinting
	LandingSpring: boolean,   -- landing jounce dip
}

local CameraEffects = {
	FirstPerson = {
		HeadBob = true,
		MovementInertia = true,
		TurnLean = true,
		SprintLean = true,
		LandingSpring = true,
	} :: EffectToggles,

	ThirdPerson = {
		HeadBob = true,
		MovementInertia = false, -- OFF by default -- see file header
		TurnLean = true,
		SprintLean = true,
		LandingSpring = true,
	} :: EffectToggles,
}

return CameraEffects