--!strict
--[[
	MovementProfiles.lua  (Ch 2.1 Movement, Ch 2.3 Gravity Profiles)

	Each profile is pure data: gravity direction, acceleration/deceleration, top speed,
	jump strength, friction, and surface interaction rules.

	JumpPower deliberately kept modest (35 baseline, down from 50) — leaves headroom so a
	future Vaulting/Climbing system (Ch 2.6) reads as the "big" traversal tool and jump
	stays a small hop, rather than jump alone already covering vault-height gaps.

	Acceleration/Deceleration (studs/s^2) drive the inertia system in CharacterController.
	IMPORTANT (Ch 2.3): Gravity here only ever affects the CHARACTER, never projectiles.
]]

export type SurfaceInteraction = "Ground" | "Wall" | "Ceiling" | "Fluid" | "None"

export type MovementProfile = {
	Gravity: Vector3,
	WalkSpeed: number,
	SprintSpeedMultiplier: number,
	Acceleration: number,
	BrakingDeceleration : number,
	JumpPower: number,
	Friction: number,
	SurfaceInteraction: SurfaceInteraction,
	AllowsJump: boolean,
	AllowsSprint: boolean,
}

local DEFAULT_GRAVITY = Vector3.new(0, -196.2, 0)

local MovementProfiles: { [string]: MovementProfile } = {
	StandardHuman = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 8, SprintSpeedMultiplier = 1.6,
		Acceleration = 30, BrakingDeceleration = 35, TurnCutStrength = 0.65,
		JumpPower = 35, SurfaceInteraction = "Ground", AllowsJump = true, AllowsSprint = true,
	},
	LowGravity = {
		Gravity = DEFAULT_GRAVITY * 0.35, WalkSpeed = 8, SprintSpeedMultiplier = 1.6,
		Acceleration = 30, BrakingDeceleration = 40, TurnCutStrength = 0.3, -- floaty, less grip
		JumpPower = 49, SurfaceInteraction = "Ground", AllowsJump = true, AllowsSprint = true,
	},
	HighGravity = {
		Gravity = DEFAULT_GRAVITY * 1.8, WalkSpeed = 6, SprintSpeedMultiplier = 1.3,
		Acceleration = 26, BrakingDeceleration = 50, TurnCutStrength = 0.8, -- weight punishes bad turns
		JumpPower = 21, SurfaceInteraction = "Ground", AllowsJump = true, AllowsSprint = true,
	},
	ZeroGravity = {
		Gravity = Vector3.zero, WalkSpeed = 5, SprintSpeedMultiplier = 1.2,
		Acceleration = 14, BrakingDeceleration = 6, TurnCutStrength = 0.05, -- momentum just carries
		JumpPower = 0, SurfaceInteraction = "None", AllowsJump = false, AllowsSprint = true,
	},
	WallWalking = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 6, SprintSpeedMultiplier = 1.3,
		Acceleration = 24, BrakingDeceleration = 34, TurnCutStrength = 0.5,
		JumpPower = 0, SurfaceInteraction = "Wall", AllowsJump = false, AllowsSprint = false,
	},
	CeilingWalking = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 5, SprintSpeedMultiplier = 1.2,
		Acceleration = 20, BrakingDeceleration = 30, TurnCutStrength = 0.5,
		JumpPower = 0, SurfaceInteraction = "Ceiling", AllowsJump = false, AllowsSprint = false,
	},
	Flying = {
		Gravity = Vector3.zero, WalkSpeed = 12, SprintSpeedMultiplier = 1.8,
		Acceleration = 18, BrakingDeceleration = 10, TurnCutStrength = 0.1, -- banks, doesn't plant
		JumpPower = 0, SurfaceInteraction = "None", AllowsJump = false, AllowsSprint = true,
	},
	Swimming = {
		Gravity = DEFAULT_GRAVITY * 0.1, WalkSpeed = 6, SprintSpeedMultiplier = 1.4,
		Acceleration = 16, BrakingDeceleration = 20, TurnCutStrength = 0.35,
		JumpPower = 14, SurfaceInteraction = "Fluid", AllowsJump = true, AllowsSprint = true,
	},
	MagneticAdhesion = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 5, SprintSpeedMultiplier = 1.1,
		Acceleration = 22, BrakingDeceleration = 32, TurnCutStrength = 0.55,
		JumpPower = 0, SurfaceInteraction = "Wall", AllowsJump = false, AllowsSprint = false,
	},
	AnomalyMovement = {
		Gravity = DEFAULT_GRAVITY * 0.5, WalkSpeed = 7, SprintSpeedMultiplier = 1.5,
		Acceleration = 24, BrakingDeceleration = 34, TurnCutStrength = 0.4,
		JumpPower = 38, SurfaceInteraction = "None", AllowsJump = true, AllowsSprint = true,
	},
	HeavyArmor = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 6, SprintSpeedMultiplier = 1.25,
		Acceleration = 20, BrakingDeceleration = 30, TurnCutStrength = 0.75, -- mass fights redirection
		JumpPower = 24, SurfaceInteraction = "Ground", AllowsJump = true, AllowsSprint = true,
	},
	PoweredExo = {
		Gravity = DEFAULT_GRAVITY, WalkSpeed = 9, SprintSpeedMultiplier = 1.7,
		Acceleration = 48, BrakingDeceleration = 60, TurnCutStrength = 0.5, -- servos offset the mass
		JumpPower = 42, SurfaceInteraction = "Ground", AllowsJump = true, AllowsSprint = true,
	},
}

return MovementProfiles
