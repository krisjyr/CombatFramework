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
	Deceleration: number,
	JumpPower: number,
	Friction: number,
	SurfaceInteraction: SurfaceInteraction,
	AllowsJump: boolean,
	AllowsSprint: boolean,
}

local DEFAULT_GRAVITY = Vector3.new(0, -196.2, 0)

local MovementProfiles: { [string]: MovementProfile } = {
	StandardHuman = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 8,
		SprintSpeedMultiplier = 1.6,
		Acceleration = 32,
		Deceleration = 48,
		JumpPower = 35,
		Friction = 0.3,
		SurfaceInteraction = "Ground",
		AllowsJump = true,
		AllowsSprint = true,
	},

	LowGravity = {
		Gravity = DEFAULT_GRAVITY * 0.35,
		WalkSpeed = 8,
		SprintSpeedMultiplier = 1.6,
		Acceleration = 24,
		Deceleration = 32,
		JumpPower = 49,
		Friction = 0.15,
		SurfaceInteraction = "Ground",
		AllowsJump = true,
		AllowsSprint = true,
	},

	HighGravity = {
		Gravity = DEFAULT_GRAVITY * 1.8,
		WalkSpeed = 6,
		SprintSpeedMultiplier = 1.3,
		Acceleration = 36,
		Deceleration = 56,
		JumpPower = 21,
		Friction = 0.45,
		SurfaceInteraction = "Ground",
		AllowsJump = true,
		AllowsSprint = true,
	},

	ZeroGravity = {
		Gravity = Vector3.zero,
		WalkSpeed = 5,
		SprintSpeedMultiplier = 1.2,
		Acceleration = 10,
		Deceleration = 8,
		JumpPower = 0,
		Friction = 0.02,
		SurfaceInteraction = "None",
		AllowsJump = false,
		AllowsSprint = true,
	},

	WallWalking = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 6,
		SprintSpeedMultiplier = 1.3,
		Acceleration = 20,
		Deceleration = 30,
		JumpPower = 0,
		Friction = 0.3,
		SurfaceInteraction = "Wall",
		AllowsJump = false,
		AllowsSprint = false,
	},

	CeilingWalking = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 5,
		SprintSpeedMultiplier = 1.2,
		Acceleration = 18,
		Deceleration = 28,
		JumpPower = 0,
		Friction = 0.3,
		SurfaceInteraction = "Ceiling",
		AllowsJump = false,
		AllowsSprint = false,
	},

	Flying = {
		Gravity = Vector3.zero,
		WalkSpeed = 12,
		SprintSpeedMultiplier = 1.8,
		Acceleration = 16,
		Deceleration = 14,
		JumpPower = 0,
		Friction = 0.05,
		SurfaceInteraction = "None",
		AllowsJump = false,
		AllowsSprint = true,
	},

	Swimming = {
		Gravity = DEFAULT_GRAVITY * 0.1,
		WalkSpeed = 6,
		SprintSpeedMultiplier = 1.4,
		Acceleration = 14,
		Deceleration = 18,
		JumpPower = 14,
		Friction = 0.2,
		SurfaceInteraction = "Fluid",
		AllowsJump = true,
		AllowsSprint = true,
	},

	MagneticAdhesion = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 5,
		SprintSpeedMultiplier = 1.1,
		Acceleration = 18,
		Deceleration = 30,
		JumpPower = 0,
		Friction = 0.4,
		SurfaceInteraction = "Wall",
		AllowsJump = false,
		AllowsSprint = false,
	},

	AnomalyMovement = {
		Gravity = DEFAULT_GRAVITY * 0.5,
		WalkSpeed = 7,
		SprintSpeedMultiplier = 1.5,
		Acceleration = 26,
		Deceleration = 40,
		JumpPower = 38,
		Friction = 0.25,
		SurfaceInteraction = "None",
		AllowsJump = true,
		AllowsSprint = true,
	},

	HeavyArmor = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 6,
		SprintSpeedMultiplier = 1.25,
		Acceleration = 22,
		Deceleration = 40,
		JumpPower = 24,
		Friction = 0.5,
		SurfaceInteraction = "Ground",
		AllowsJump = true,
		AllowsSprint = true,
	},

	PoweredExo = {
		Gravity = DEFAULT_GRAVITY,
		WalkSpeed = 9,
		SprintSpeedMultiplier = 1.7,
		Acceleration = 40,
		Deceleration = 52,
		JumpPower = 42,
		Friction = 0.35,
		SurfaceInteraction = "Ground",
		AllowsJump = true,
		AllowsSprint = true,
	},
}

return MovementProfiles
