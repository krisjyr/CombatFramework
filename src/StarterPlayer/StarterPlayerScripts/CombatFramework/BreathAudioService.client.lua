--!strict
--[[
	BreathAudioService.client.lua  (Ch 10 Audio Framework)

	REDESIGNED: breathing is a CYCLIC ONE-SHOT player, not a continuous loop. The previous
	PlayContinuous-based version had two bugs baked into that choice:
	  1. PlayContinuous only picks a variant ONCE, when the loop starts, then keeps looping
	     that same instance's SoundId forever -- with 10+ breath variants per tier, only
	     ever ONE of them would ever be heard, identical to the Clothing.Run/Gear.* bug
	     fixed earlier. Cycling through SoundService.Play() every breath re-rolls a random
	     no-immediate-repeat variant EVERY time (see pickVariant in SoundService.lua),
	     giving real per-breath variation.
	  2. A continuous loop only starts once BreathStateChanged fires -- but that event only
	     fires on a TIER CHANGE (Ch: BreathController's `if newState ~= entry.BreathState`).
	     A character that spawns and stays Calm the whole session never gets a single event,
	     so breathing never started at all. Fixed by scheduling the first breath
	     immediately on IKControllerRegistry.Added, independent of any server event.

	HOLD = SILENCE: while Holding is true, the scheduler simply skips playing entirely (no
	ducking, no quiet loop underneath) -- this is the actual "no breathing while holding"
	behavior, not a volume trick.

	Owns zero oxygen/stamina logic -- purely reacts to BreathController's relayed events
	(tier, hold state, asphyxiation) and Humanoid presence for every character.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local SoundService = require(CombatFramework.Shared.SoundService)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local IKControllerRegistry = require(script.Parent.IKControllerRegistry)

-- Cadence per tier: how often a breath cycle plays, with random variance so it doesn't
-- sound metronomic. Heavier tiers breathe faster AND louder.
local BREATH_CADENCE: { [string]: { Base: number, Variance: number, Volume: number } } = {
	Calm    = { Base = 3.4, Variance = 0.5, Volume = 0.3 },
	Medium  = { Base = 2.1, Variance = 0.35, Volume = 0.45 },
	Heavy   = { Base = 1.15, Variance = 0.2, Volume = 0.6 },
	Wounded = { Base = 1.35, Variance = 0.25, Volume = 0.6 },
}

local INITIAL_START_DELAY_MAX = 1.2 -- stagger multiple characters so they don't all breathe in sync

type Entry = {
	RootPart: BasePart,
	Tier: string,
	Holding: boolean,
	Suspended: boolean, -- true while asphyxiated -- no breathing at all until Recovered
	NextPlayTime: number,
}

local entries: { [Model]: Entry } = {}

local function cadenceFor(tier: string): { Base: number, Variance: number, Volume: number }
	return BREATH_CADENCE[tier] or BREATH_CADENCE.Calm
end

local function scheduleNext(entry: Entry, delayOverride: number?)
	local cadence = cadenceFor(entry.Tier)
	local interval = delayOverride or (cadence.Base + (math.random() * 2 - 1) * cadence.Variance)
	entry.NextPlayTime = os.clock() + math.max(interval, 0.3)
end

-- === Character registration (mirrors FootstepService's IKControllerRegistry hookup) ====

IKControllerRegistry.Added:Connect(function(character: Model, _controller)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end

	local entry: Entry = {
		RootPart = rootPart,
		Tier = "Calm", -- matches BreathController's own default -- see file header point 2
		Holding = false,
		Suspended = false,
		NextPlayTime = 0,
	}
	entries[character] = entry
	scheduleNext(entry, math.random() * INITIAL_START_DELAY_MAX) -- starts breathing almost immediately, staggered
end)

IKControllerRegistry.Removed:Connect(function(character: Model)
	entries[character] = nil
end)

-- === Server-relayed state (tier changes, hold, asphyxiation) ===========================

local function entryForPlayer(player: Player): Entry?
	local character = player.Character
	return character and entries[character]
end

CombatEvents.BreathStateChanged:Connect(function(player: Player, newState: string, _oldState: string)
	local entry = entryForPlayer(player)
	if entry then
		entry.Tier = newState
	end
end)

CombatEvents.BreathHoldStarted:Connect(function(player: Player)
	local entry = entryForPlayer(player)
	if not entry then
		return
	end
	entry.Holding = true -- scheduler below simply skips playing while this is true -- true silence

	if entry.RootPart.Parent then
		SoundService.Play("Breathing.Hold", { Parent = entry.RootPart })
	end
end)

CombatEvents.BreathHoldReleased:Connect(function(player: Player, wasForced: boolean)
	local entry = entryForPlayer(player)
	if not entry then
		return
	end
	entry.Holding = false

	if entry.RootPart.Parent then
		SoundService.Play("Breathing.Release", {
			Parent = entry.RootPart,
			Volume = if wasForced then 0.75 else 0.5,
			PlaybackSpeed = if wasForced then 1.1 else 1,
		})
	end

	-- Resume the cycle shortly after the release gasp rather than instantly stacking a
	-- second breath sound on top of it.
	scheduleNext(entry, 0.6)
end)

CombatEvents.Asphyxiated:Connect(function(player: Player)
	local entry = entryForPlayer(player)
	if entry then
		entry.Suspended = true
		CombatEvents.BreathHoldReleased:Fire(player, true)
	end
end)

CombatEvents.Recovered:Connect(function(player: Player)
	local entry = entryForPlayer(player)
	if entry then
		entry.Suspended = false
		scheduleNext(entry, 0.8) -- a beat of silence coming out of unconsciousness before breathing resumes
	end
end)

CombatEvents.CoughTriggered:Connect(function(player: Player)
	local entry = entryForPlayer(player)
	if entry and entry.RootPart.Parent then
		SoundService.Play("Breathing.Cough", { Parent = entry.RootPart })
	end
end)

-- === Cycle scheduler =====================================================================

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for character, entry in pairs(entries) do
		if not entry.RootPart.Parent then
			entries[character] = nil
			continue
		end

		if entry.Holding or entry.Suspended then
			continue -- genuinely silent -- no sound played, no timer advanced
		end

		if now >= entry.NextPlayTime then
			local cadence = cadenceFor(entry.Tier)
			SoundService.Play(`Breathing.{entry.Tier}`, {
				Parent = entry.RootPart,
				Volume = cadence.Volume,
			})
			scheduleNext(entry)
		end
	end
end)