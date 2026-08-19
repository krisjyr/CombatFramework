--!strict
--[[
	CombatEvents.lua

	One Signal per event type, declared centrally (Ch 17.5 convention) so the event
	catalogue is data-inspectable, same spirit as the Status catalogue (Ch 8.5).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Packages.namedsignal)

local CombatEvents = {
	-- Fired on the CLIENT after local prediction changes stance, and again on the
	-- SERVER after validation confirms it. Listeners should check which side fired it.
	StanceChanged = Signal.new<<(player: Player, newStance: string, oldStance: string) -> ()>>(),

	-- Fired whenever a MovementProfile changes (zone entry/exit, ability, equipment).
	MovementProfileChanged = Signal.new<<(player: Player, newProfile: string, oldProfile: string, sourceId: string) -> ()>>(),

	-- Fired whenever the character's effective gravity vector changes for any reason.
	GravityChanged = Signal.new<<(player: Player, newGravity: Vector3, sourceId: string) -> ()>>(),

	-- Fired when Surface Adhesion (Ch 2.4) attaches/detaches the character to/from a surface.
	SurfaceAttached = Signal.new<<(player: Player, surfaceNormal: Vector3?) -> ()>>(),

	-- Fired by FallService.lua the instant a character lands/enters water, whether or not
	-- damage was dealt. Clients use this for landing camera shake / sound / animation.
	FallImpact = Signal.new<<(player: Player, peakFallSpeed: number, damageApplied: number, landingMaterial: Enum.Material) -> ()>>(),

	-- Fired by FallService.lua the moment a falling character's downward speed crosses
	-- FallTuning.FastFallVelocity (once per fall), and again when that fall ends (landed,
	-- entered water, or otherwise stopped falling). Purely a feedback trigger -- client uses
	-- this to start/stop an air-rush sound and an ambient screenshake while plummeting.
	FastFallBegan = Signal.new<<(player: Player, downwardSpeed: number) -> ()>>(),
	FastFallEnded = Signal.new<<(player: Player) -> ()>>(),

	-- Fired on the CLIENT after local prediction changes lean, and again on the SERVER
	-- after validation confirms it (same client/server pattern as StanceChanged).
	LeanChanged = Signal.new<<(player: Player, direction: string) -> ()>>(),

	Ragdolled = Signal.new<<(character: Model, reason: string) -> ()>>(),
	RagdollEnded = Signal.new<<(character: Model, reason: string) -> ()>>(),

	MovementInputReleased = Signal.new<<(player: Player, speedAtRelease: number) -> ()>>(),
	FootPlanted = Signal.new<<(side: FootSide, worldPosition: Vector3, stance: string?, planarSpeed: number) -> ()>>(),

	-- Fired whenever a character's breath tier changes (Calm/Medium/Heavy/Wounded),
	-- server-authoritative (BreathController), relayed to clients via BreathSync same as
	-- FallImpact/FastFallBegan (see BreathFeedbackRelay.client.lua for why this relay step
	-- is mandatory -- CombatEvents does NOT cross the server/client boundary on its own).
	BreathStateChanged = Signal.new<<(player: Player, newState: string, oldState: string) -> ()>>(),

	-- Fired whenever oxygen changes meaningfully (throttled server-side, not every tick) --
	-- primarily for a future screen-vignette UI hook, but also useful for HUD/AI awareness.
	OxygenChanged = Signal.new<<(player: Player, oxygenFraction: number) -> ()>>(),

	BreathHoldStarted = Signal.new<<(player: Player) -> ()>>(),
	-- wasForced = true when release was involuntary (MaxHoldDuration or oxygen depletion),
	-- false when the player released the key themselves -- audio uses this to pick a calm
	-- exhale vs. a panicked gasp.
	BreathHoldReleased = Signal.new<<(player: Player, wasForced: boolean) -> ()>>(),

	-- Fired when oxygen hits 0 while unresolved. Ch7 Consciousness System (Ch 7.7) is the
	-- eventual real owner of what "unconscious" means -- until then, BreathController
	-- applies a placeholder impairment and self-recovers (see its file header).
	Asphyxiated = Signal.new<<(player: Player) -> ()>>(),
	Recovered = Signal.new<<(player: Player) -> ()>>(), -- placeholder wake-up, see above

	CoughTriggered = Signal.new<<(player: Player) -> ()>>(),
}

return CombatEvents
