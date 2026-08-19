--!strict
--[[
	BreathController.lua  (Ch 2.8 Breathing, server-authoritative)

	Owns one Oxygen resource (0-100) per character, mirroring FallService's per-character
	tracking table shape. Server-authoritative because oxygen depletion leads to
	unconsciousness -- the same authority boundary as fall damage (Ch 1.3).

	PLUGGABLE DRAIN (this is the "must work with a system of stamina or zones" requirement):
	drain sources register through the SAME ModifierStack pattern GravityZoneHandler already
	uses for gravity overrides -- a low-oxygen zone or a chemical-gas zone just calls
	SetDrainModifier(player, sourceId, rate, coughChancePerSecond) on enter and
	ClearDrainModifier(player, sourceId) on exit. BreathController never needs to know what
	kind of zone/hazard/ability is driving the drain, exactly like CharacterController never
	needs to know what's driving a Gravity override.

	STAMINA HOOK: no Stamina system exists yet, so SetStaminaFraction defaults to 1
	(unlimited) for everyone. A future StaminaService just calls
	BreathController.SetStaminaFraction(player, currentStamina / maxStamina) whenever it
	changes -- BreathController takes min(oxygenFraction, staminaFraction) as the "how much
	air do I have" signal driving breath tier, without ever depending on Stamina's module.

	PLACEHOLDER ASPHYXIATION: reaching 0 oxygen fires CombatEvents.Asphyxiated and applies a
	temporary movement-impairment modifier directly onto the existing
	CharacterController.Modifiers stack (via ControllerRegistry) with a timed self-recovery.
	This is explicitly a stand-in for Ch 7's real Consciousness System (Normal -> Dazed ->
	Unconscious -> Critical -> Dead) -- when that ships, replace the block in
	_applyAsphyxiation/_recoverFromAsphyxiation wholesale rather than extending it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local BreathTuning = require(CombatFramework.Shared.Config.BreathTuning)
local ModifierStack = require(CombatFramework.Shared.ModifierStack)

local ControllerRegistry = require(script.Parent.ControllerRegistry)
local RagdollService = require(script.Parent.RagdollService)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local BreathHoldRequest = Remotes:WaitForChild("BreathHoldRequest") :: RemoteEvent
local BreathSync = Remotes:WaitForChild("BreathSync") :: RemoteEvent

type Entry = {
	Player: Player,
	Character: Model,
	Modifiers: ModifierStack.ModifierStackInstance, -- drain-rate / cough-chance sources only
	Oxygen: number,
	StaminaFraction: number,
	Holding: boolean,
	HoldElapsed: number,
	Asphyxiated: boolean,
	BreathState: string,
	OxygenChangeAccumulator: number, -- throttles OxygenChanged firing
}

local BreathController = {}

local entries: { [Player]: Entry } = {}

local OXYGEN_CHANGE_FIRE_THRESHOLD = 2 -- only fire OxygenChanged after this much real change

local function tierFor(fraction: number): string
	if fraction >= BreathTuning.CalmThreshold then
		return "Calm"
	elseif fraction >= BreathTuning.MediumThreshold then
		return "Medium"
	end
	return "Heavy"
end

local function fireBreathState(entry: Entry, newState: string, oldState: string)
	CombatEvents.BreathStateChanged:Fire(entry.Player, newState, oldState)
	BreathSync:FireAllClients("BreathStateChanged", entry.Player, newState, oldState)
end

local function applyAsphyxiation(entry: Entry)
	entry.Asphyxiated = true
	entry.Holding = false
	CombatEvents.Asphyxiated:Fire(entry.Player)
	BreathSync:FireAllClients("Asphyxiated", entry.Player)

	local moveEntry = ControllerRegistry.Get(entry.Player)
	if moveEntry then
		moveEntry.Character.Modifiers:Add({ sourceId = "Asphyxiation", key = "CanSprint", modifierType = "Boolean", value = false })
		moveEntry.Character.Modifiers:Add({ sourceId = "Asphyxiation", key = "CanFire", modifierType = "Boolean", value = false })
		moveEntry.Character.Modifiers:Add({
			sourceId = "Asphyxiation",
			key = "SpeedMultiplier",
			modifierType = "Numeric",
			op = "Multiply",
			value = BreathTuning.AsphyxiationSpeedMultiplier,
			stackBehavior = "Replace",
		})
	end

    RagdollService.Enter(entry.Player.Character, { Reason = "Asphyxiation" })

	task.delay(BreathTuning.AsphyxiationRecoverTime, function()
		if not entries[entry.Player] or entries[entry.Player] ~= entry then
			return
		end
		entry.Asphyxiated = false
		-- max(), not a flat assignment: with recovery now frozen during the blackout
		-- (see Heartbeat change above), entry.Oxygen will typically already BE at
		-- whatever it was when asphyxiation started (or lower, if a hazard zone kept
		-- draining it) -- this just guarantees AT LEAST the wake fraction, so you don't
		-- immediately pass out again if a zone held you at 0, without ever dragging an
		-- already-higher value back down.
		entry.Oxygen = math.max(entry.Oxygen, BreathTuning.MaxOxygen * BreathTuning.AsphyxiationWakeOxygenFraction)

		local recoverEntry = ControllerRegistry.Get(entry.Player)
		if recoverEntry then
			recoverEntry.Character.Modifiers:RemoveAllFromSource("Asphyxiation")
		end

        RagdollService.Exit(entry.Player.Character, { WakeStance = "Prone" })

		CombatEvents.Recovered:Fire(entry.Player)
		BreathSync:FireAllClients("Recovered", entry.Player)
	end)
end

-- === Public API: drain modifiers (zones, hazards, future abilities) ====================

function BreathController.SetDrainModifier(player: Player, sourceId: string, ratePerSecond: number, coughChancePerSecond: number?)
	local entry = entries[player]
	if not entry then
		return
	end
	entry.Modifiers:Add({ sourceId = sourceId, key = "OxygenDrainRate", modifierType = "Numeric", op = "Add", value = ratePerSecond })
	if coughChancePerSecond then
		entry.Modifiers:Add({ sourceId = sourceId, key = "CoughChancePerSecond", modifierType = "Numeric", op = "Add", value = coughChancePerSecond })
	end
end

function BreathController.ClearDrainModifier(player: Player, sourceId: string)
	local entry = entries[player]
	if not entry then
		return
	end
	entry.Modifiers:RemoveAllFromSource(sourceId)
end

-- === Public API: future Stamina hook ====================================================

function BreathController.SetStaminaFraction(player: Player, fraction: number)
	local entry = entries[player]
	if entry then
		entry.StaminaFraction = math.clamp(fraction, 0, 1)
	end
end

-- === Public API: hold breath =============================================================

function BreathController.TryStartHold(player: Player): boolean
	local entry = entries[player]
	if not entry or entry.Asphyxiated or entry.Holding then
		return false
	end
	entry.Holding = true
	entry.HoldElapsed = 0
	CombatEvents.BreathHoldStarted:Fire(player)
	BreathSync:FireAllClients("BreathHoldStarted", player)
	return true
end

function BreathController.TryReleaseHold(player: Player, wasForced: boolean?)
	local entry = entries[player]
	if not entry or not entry.Holding then
		return
	end
	entry.Holding = false
	entry.HoldElapsed = 0
	CombatEvents.BreathHoldReleased:Fire(player, wasForced == true)
	BreathSync:FireAllClients("BreathHoldReleased", player, wasForced == true)
end

BreathHoldRequest.OnServerEvent:Connect(function(player: Player, wantsToHold: unknown)
	if typeof(wantsToHold) ~= "boolean" then
		return
	end
	if wantsToHold then
		BreathController.TryStartHold(player)
	else
		BreathController.TryReleaseHold(player, false)
	end
end)

-- === Lifecycle ============================================================================

local function onCharacterAdded(player: Player, character: Model)
	entries[player] = {
		Player = player,
		Character = character,
		Modifiers = ModifierStack.new(),
		Oxygen = BreathTuning.MaxOxygen,
		StaminaFraction = 1,
		Holding = false,
		HoldElapsed = 0,
		Asphyxiated = false,
		BreathState = "Calm",
		OxygenChangeAccumulator = 0,
	}
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	entries[player] = nil
end)

-- === Per-frame tick =========================================================================

RunService.Heartbeat:Connect(function(dt: number)
	for player, entry in pairs(entries) do
        local zoneDrainRate = entry.Modifiers:ResolveNumeric("OxygenDrainRate", 0)
		local totalDrainRate = zoneDrainRate + (if entry.Holding then BreathTuning.HoldDrainRate else 0)

		local oxygenBefore = entry.Oxygen
		if entry.Asphyxiated then
			-- Frozen while unconscious -- no passive recovery during a blackout. A hazard
			-- zone (toxic gas, vacuum) can still drain further even while passed out
			-- (you don't stop suffocating just because you're unconscious), but ordinary
			-- NormalRecoveryRate does NOT apply here -- that's what was causing oxygen to
			-- visibly climb during the blackout in the previous version.
			if zoneDrainRate > 0 then
				entry.Oxygen = math.max(0, entry.Oxygen - zoneDrainRate * dt)
			end
		elseif totalDrainRate > 0 then
			entry.Oxygen = math.max(0, entry.Oxygen - totalDrainRate * dt)
		else
			entry.Oxygen = math.min(BreathTuning.MaxOxygen, entry.Oxygen + BreathTuning.NormalRecoveryRate * dt)
		end

        entry.OxygenChangeAccumulator += math.abs(entry.Oxygen - oxygenBefore)
		if entry.OxygenChangeAccumulator >= OXYGEN_CHANGE_FIRE_THRESHOLD then
			entry.OxygenChangeAccumulator = 0
			CombatEvents.OxygenChanged:Fire(player, entry.Oxygen / BreathTuning.MaxOxygen)

            print("Current oxygen: " .. entry.Oxygen .. " for player: " .. player.Name)
			BreathSync:FireClient(player, "OxygenChanged", player, entry.Oxygen / BreathTuning.MaxOxygen) -- ADD (private, not FireAllClients -- only the owning player's UI needs this)
		end

		if entry.Holding then
			entry.HoldElapsed += dt
			if entry.HoldElapsed >= BreathTuning.MaxHoldDuration then
				BreathController.TryReleaseHold(player, true)
			end
		end

		if entry.Oxygen <= 0 and not entry.Asphyxiated then
			applyAsphyxiation(entry)
		end

		if not entry.Asphyxiated then
			local staminaFraction = entry.StaminaFraction
			local oxygenFraction = entry.Oxygen / BreathTuning.MaxOxygen
			local airFraction = math.min(oxygenFraction, staminaFraction)
			local newState = tierFor(airFraction)
			if newState ~= entry.BreathState then
				local old = entry.BreathState
				entry.BreathState = newState
				fireBreathState(entry, newState, old)
			end
		end

		-- Coughing: independent per-frame roll, sourced from the same Modifiers stack a
		-- toxic/smoke zone already pushed a CoughChancePerSecond into.
		local coughChancePerSecond = entry.Modifiers:ResolveNumeric("CoughChancePerSecond", 0)
		if coughChancePerSecond > 0 and math.random() < coughChancePerSecond * dt then
			CombatEvents.CoughTriggered:Fire(player)
			BreathSync:FireAllClients("CoughTriggered", player)
		end
	end
end)

return BreathController