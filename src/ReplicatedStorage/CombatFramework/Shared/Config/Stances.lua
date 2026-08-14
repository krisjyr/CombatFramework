--!strict
--[[
	Stances.lua  (Ch 2.2 Stances)

	A stance is a bundled set of modifiers pushed through the SAME ModifierStack that
	Statuses and Attachments use. `CanLean` is new: leaning (Ch 2.9-adjacent peek mechanic)
	is allowed from any stance where it makes tactical sense (Standing, TacticalWalk,
	Crouching, Prone) and disallowed where it doesn't (mid-sprint, mid-jump, Mounted,
	Climbing, Swimming).

	`AllowedTransitions`: Standing can now go directly to Prone (a fast "drop prone"), but
	Prone can still only stand back up THROUGH Crouching — dropping is fast, getting up is
	deliberately gradual, matching most tactical shooters.
]]

export type StanceAnimationEntry = {
	Id: string,
	Speed: number?,
}
 
export type StanceAnimations = {
	Idle: StanceAnimationEntry,
	Move: StanceAnimationEntry,
}


export type StanceModifiers = {
	SpeedMultiplier: number,
	VisibilityMultiplier: number,
	RecoilMultiplier: number,
	StabilityBonus: number,
	NoiseMultiplier: number,
	Height: number,
	CanSprint: boolean,
	CanAim: boolean,
	CanFire: boolean,
	CanLean: boolean,
	TransitionTime: number,
	CameraControlMultiplier: number,
}

export type StanceDefinition = StanceModifiers & {
	AllowedTransitions: { string },
	-- Both optional; omit either/both to use AnimationController's DEFAULT_ANIMATIONS.
	AnimationsEnabled: boolean?,
	Animations: StanceAnimations?,
}

export type StanceIKIdlePose = {
	FootPitchDegrees: number,   -- ankle tilt while planted+idle (+ = toe up)
	HandPitchDegrees: number,   -- wrist/forearm tilt while idle-hanging
	SurfaceFollow: number,      -- 0 = ignore ground/surface normal, 1 = fully match it (feet)
}

-- Small helper so every stance below doesn't have to repeat Speed=1, JointMask={}
-- boilerplate for the common case of "just a normal, full-body animation."
local function anim(id: string, speed: number?): StanceAnimationEntry
	return { Id = id, Speed = speed or 1 }
end

local Stances: { [string]: StanceDefinition } = {
	Standing = {
		SpeedMultiplier = 1.0,
		VisibilityMultiplier = 1.0,
		RecoilMultiplier = 1.0,
		StabilityBonus = 0.0,
		NoiseMultiplier = 1.0,
		Height = 1.0,
		CanSprint = true,
		CanAim = true,
		CanFire = true,
		CanLean = true,
		TransitionTime = 0.15,
		CameraControlMultiplier = 1.0,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "TacticalWalk", "Crouching", "Prone", "TacticalSprint", "Jumping", "Mounted", "Climbing", "Swimming" },
		Animations = { Idle = anim("rbxassetid://2510197257") },
	},

	TacticalWalk = {
		SpeedMultiplier = 0.6,
		VisibilityMultiplier = 0.85,
		RecoilMultiplier = 0.9,
		StabilityBonus = 0.15,
		NoiseMultiplier = 0.5,
		Height = 0.955,
		CanSprint = true,
		CanAim = true,
		CanFire = true,
		CanLean = true,
		TransitionTime = 0.1,
		CameraControlMultiplier = 1.1,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing", "Crouching", "Prone", "TacticalSprint", "Mounted", "Climbing", "Swimming" },
		Animations = { Idle = anim("rbxassetid://2510197257") },
	},

	Crouching = {
		SpeedMultiplier = 0.5,
		VisibilityMultiplier = 0.55,
		RecoilMultiplier = 0.75,
		StabilityBonus = 0.35,
		NoiseMultiplier = 0.4,
		Height = 0.6,
		CanSprint = false,
		CanAim = true,
		CanFire = true,
		CanLean = true,
		TransitionTime = 0.25,
		CameraControlMultiplier = 1.2,
		IKIdlePose = { FootPitchDegrees = -16, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing", "TacticalWalk", "Prone", "Jumping", "Mounted", "Climbing", "Swimming" },
		AnimationsEnabled = true,
	},

	Prone = {
		SpeedMultiplier = 0.2,
		VisibilityMultiplier = 0.15,
		RecoilMultiplier = 0.5,
		StabilityBonus = 0.6,
		NoiseMultiplier = 0.15,
		Height = 0.15,
		CanSprint = false,
		CanAim = true,
		CanFire = true,
		CanLean = true,
		TransitionTime = 0.6,
		CameraControlMultiplier = 1.3,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Crouching" },
		Animations = { Idle = anim("rbxassetid://0"), Move = anim("rbxassetid://0") },
	},

	TacticalSprint = {
		SpeedMultiplier = 1.6,
		VisibilityMultiplier = 1.3,
		RecoilMultiplier = 1.0,
		StabilityBonus = -0.5,
		NoiseMultiplier = 1.6,
		Height = 0.97,
		CanSprint = true,
		CanAim = false,
		CanFire = false,
		CanLean = false,
		TransitionTime = 0.2,
		CameraControlMultiplier = 0.55,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing", "TacticalWalk", "Jumping", "Mounted", "Climbing", "Swimming" },
		Animations = { Idle = anim("rbxassetid://2510197257"), Move = anim("rbxassetid://2510198475") },
	},

	Jumping = {
		SpeedMultiplier = 1.0,
		VisibilityMultiplier = 1.1,
		RecoilMultiplier = 1.3,
		StabilityBonus = -0.3,
		NoiseMultiplier = 1.0,
		Height = 1.0,
		CanSprint = false,
		CanAim = true,
		CanFire = true,
		CanLean = false,
		TransitionTime = 0.05,
		CameraControlMultiplier = 0.8,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing", "TacticalWalk", "Crouching" },
		Animations = { Idle = anim("rbxassetid://2510197257"), Move = anim("rbxassetid://99503269381915") },
	},

	Mounted = {
		SpeedMultiplier = 0.0,
		VisibilityMultiplier = 1.0,
		RecoilMultiplier = 0.6,
		StabilityBonus = 0.4,
		NoiseMultiplier = 1.0,
		Height = 1.0,
		CanSprint = false,
		CanAim = true,
		CanFire = true,
		CanLean = false,
		TransitionTime = 0.3,
		CameraControlMultiplier = 1.4,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing" },
		Animations = { Idle = anim("rbxassetid://0"), Move = anim("rbxassetid://0") },
	},

	Climbing = {
		SpeedMultiplier = 0.7,
		VisibilityMultiplier = 0.9,
		RecoilMultiplier = 1.0,
		StabilityBonus = -0.2,
		NoiseMultiplier = 0.7,
		Height = 1.0,
		CanSprint = false,
		CanAim = false,
		CanFire = false,
		CanLean = false,
		TransitionTime = 0.2,
		CameraControlMultiplier = 0.6,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing", "Crouching" },
		Animations = { Idle = anim("rbxassetid://0"), Move = anim("rbxassetid://88464673273226") },
	},

	Swimming = {
		SpeedMultiplier = 0.7,
		VisibilityMultiplier = 0.7,
		RecoilMultiplier = 1.2,
		StabilityBonus = -0.4,
		NoiseMultiplier = 0.3,
		Height = 0.8,
		CanSprint = false,
		CanAim = false,
		CanFire = false,
		CanLean = false,
		TransitionTime = 0.2,
		CameraControlMultiplier = 0.6,
		IKIdlePose = { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = 0.55 },
		AllowedTransitions = { "Standing" },
		Animations = { Idle = anim("rbxassetid://0"), Move = anim("rbxassetid://0") },
	},
}

return Stances
