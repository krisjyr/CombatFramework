--!strict
--[[
	ZoneHandler.server.lua  (Ch 8.4, 15.4-15.5, 16.6 -- unified zone effect system)

	Replaces GravityZoneHandler.lua + BreathZoneHandler.lua + their two *Bootstrap.server
	.lua files. Single CollectionService tag ("CombatZone"); a zone applies WHICHEVER
	effects it has Attributes for -- a pure gravity zone sets GravityX/Y/Z, a pure oxygen
	hazard sets DrainRate, and a zone that's BOTH (a toxic zero-G chamber) sets both sets
	of Attributes on the SAME part. This is the same "everything is data, zero hardcoded
	gameplay logic" principle (Ch 1.1) already applied to weapons/statuses, now applied to
	zones themselves.

	Adding a new effect type (Temperature, Radiation, Corruption -- Ch 8.5/16.6) means
	adding one entry to EFFECT_MODULES below. Nothing else -- not the tag, not the
	Zone/Observer plumbing, not a new bootstrap loop -- needs to change.

	This file is a Script (not a ModuleScript) and fully self-bootstraps on its own, same
	as the old *Bootstrap.server.lua files did -- nothing requires() this.

	MIGRATION: existing parts tagged "GravityZone" or "OxygenHazardZone" in Studio need to
	be retagged to "CombatZone" -- their Attributes (GravityX/Y/Z, MovementProfile,
	Priority, DrainRate, CoughChancePerSecond) are read by NAME, not by which old tag they
	came from, so nothing else about how you set them up changes.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuickZone = require(ReplicatedStorage.Packages.quickzone)
local Zone, Observer = QuickZone.Zone, QuickZone.Observer

local ZonePlayersGroup = require(script.Parent.ZonePlayersGroup)
local ControllerRegistry = require(script.Parent.ControllerRegistry)
local BreathController = require(script.Parent.BreathController)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local GravitySync = Remotes:WaitForChild("GravitySync") :: RemoteEvent

local ZONE_TAG = "CombatZone"

-- === Effect modules ========================================================
-- Detect(instance) -> config?  -- reads Attributes, nil if this effect doesn't apply here
-- Enter(player, config, sourceId) / Exit(player, config, sourceId)

type EffectModule = {
	Detect: (instance: Instance) -> any?,
	Enter: (player: Player, config: any, sourceId: string) -> (),
	Exit: (player: Player, config: any, sourceId: string) -> (),
}

local EFFECT_MODULES: { [string]: EffectModule } = {}

-- --- Gravity + Movement Profile (Ch 2.1, 2.3) ------------------------------
EFFECT_MODULES.Gravity = {
	Detect = function(instance)
		local gx = instance:GetAttribute("GravityX")
		local gy = instance:GetAttribute("GravityY")
		local gz = instance:GetAttribute("GravityZ")
		if typeof(gx) ~= "number" or typeof(gy) ~= "number" or typeof(gz) ~= "number" then
			return nil
		end
		return {
			Gravity = Vector3.new(gx, gy, gz),
			MovementProfile = instance:GetAttribute("MovementProfile"),
			Priority = instance:GetAttribute("Priority") or 0,
		}
	end,
	Enter = function(player, config, sourceId)
		local entry = ControllerRegistry.Get(player)
		if not entry then
			return
		end
		entry.Character:SetGravityOverride(config.Gravity, sourceId, config.Priority)
		if config.MovementProfile then
			entry.Character:SetMovementProfile(config.MovementProfile, sourceId)
		end
		-- IMPORTANT: MovementProfile is now included in this fire -- see the
		-- MovementClient.client.lua fix below for why this was the actual reason zone-
		-- driven profile switches never took physical effect.
		GravitySync:FireClient(player, "Set", config.Gravity, sourceId, config.Priority, config.MovementProfile)
	end,
	Exit = function(player, config, sourceId)
		local entry = ControllerRegistry.Get(player)
		if not entry then
			return
		end
		entry.Character:ClearGravityOverride(sourceId)
		if config.MovementProfile then
			entry.Character:ClearMovementProfileOverride(sourceId)
		end
		GravitySync:FireClient(player, "Clear", nil, sourceId, nil, config.MovementProfile)
	end,
}

-- --- Oxygen / Breath hazard (Ch 2.8) --------------------------------------
EFFECT_MODULES.Oxygen = {
	Detect = function(instance)
		local drainRate = instance:GetAttribute("DrainRate")
		if typeof(drainRate) ~= "number" then
			return nil
		end
		return {
			DrainRate = drainRate,
			CoughChancePerSecond = instance:GetAttribute("CoughChancePerSecond"),
		}
	end,
	Enter = function(player, config, sourceId)
		BreathController.SetDrainModifier(player, sourceId, config.DrainRate, config.CoughChancePerSecond)
	end,
	Exit = function(player, config, sourceId)
		BreathController.ClearDrainModifier(player, sourceId)
	end,
}

-- Future effects (Temperature, Radiation, Corruption, etc. -- Ch 8.5, 16.6) go here.

-- === Zone construction ======================================================

local function setupZoneInstance(instance: Instance)
	local activeEffects: { { Module: EffectModule, Config: any, Name: string } } = {}
	for name, moduleDef in pairs(EFFECT_MODULES) do
		local config = moduleDef.Detect(instance)
		if config then
			table.insert(activeEffects, { Module = moduleDef, Config = config, Name = name })
		end
	end

	if #activeEffects == 0 then
		warn(`ZoneHandler: {instance:GetFullName()} is tagged "{ZONE_TAG}" but has no recognized effect attributes -- ignoring`)
		return
	end

	local zoneCollection = Zone.fromParts({ instance }, {})
	local sourceIdBase = `Zone:{instance:GetFullName()}`

	-- Highest Priority among any active effect that has one (only Gravity uses this
	-- today) -- fold any future priority-sensitive effect into this same max() rather
	-- than spinning up a second Observer per zone.
	local priority = 0
	for _, active in ipairs(activeEffects) do
		if typeof(active.Config) == "table" and typeof(active.Config.Priority) == "number" then
			priority = math.max(priority, active.Config.Priority)
		end
	end

	local observer = Observer.new({ priority = priority })
	observer:subscribe(ZonePlayersGroup)
	observer:attach(zoneCollection)

	observer:onPlayerEnter(function(player: Player, _zone)
		for _, active in ipairs(activeEffects) do
			active.Module.Enter(player, active.Config, `{sourceIdBase}:{active.Name}`)
		end
	end)

	observer:onPlayerExit(function(player: Player, _zone)
		for _, active in ipairs(activeEffects) do
			active.Module.Exit(player, active.Config, `{sourceIdBase}:{active.Name}`)
		end
	end)
end

for _, instance in ipairs(CollectionService:GetTagged(ZONE_TAG)) do
	setupZoneInstance(instance)
end

CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(setupZoneInstance)