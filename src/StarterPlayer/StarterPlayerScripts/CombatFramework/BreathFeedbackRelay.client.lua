--!strict
--[[
	BreathFeedbackRelay.client.lua

	Bridges BreathSync (RemoteEvent) back into this client's LOCAL CombatEvents signals --
	same mandatory relay pattern as FallFeedbackRelay.client.lua, for the same reason
	(CombatEvents is a ModuleScript; server and client each run their own separate copy).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local BreathSync = Remotes:WaitForChild("BreathSync") :: RemoteEvent

BreathSync.OnClientEvent:Connect(function(eventType: string, player: Player, ...)
	if eventType == "BreathStateChanged" then
		local newState, oldState = ...
		CombatEvents.BreathStateChanged:Fire(player, newState, oldState)
	elseif eventType == "BreathHoldStarted" then
		CombatEvents.BreathHoldStarted:Fire(player)
	elseif eventType == "BreathHoldReleased" then
		local wasForced = ...
		CombatEvents.BreathHoldReleased:Fire(player, wasForced)
	elseif eventType == "Asphyxiated" then
		CombatEvents.Asphyxiated:Fire(player)
	elseif eventType == "Recovered" then
		CombatEvents.Recovered:Fire(player)
	elseif eventType == "CoughTriggered" then
		CombatEvents.CoughTriggered:Fire(player)
	elseif eventType == "OxygenChanged" then
		local oxygenFraction = ...
		CombatEvents.OxygenChanged:Fire(player, oxygenFraction)
	end
end)