--!strict
--[[
	FallFeedbackRelay.client.lua

	Bridges FallFeedbackSync (RemoteEvent, server -> client) back into this client's LOCAL
	CombatEvents signals. Necessary because CombatEvents is a ModuleScript: the server's
	execution of it and this client's execution of it are separate Lua VMs with entirely
	separate Signal objects (Signal.new() run twice, independently) -- firing
	CombatEvents.FallImpact on the server does NOT reach a client's CombatEvents.FallImpact,
	no matter how many things Connect to it. This relay is what makes that connection real,
	the same way GravitySync already does manually for gravity zone changes.

	Everything downstream (MovementClient.client.lua's wind/shake, FootstepService.client
	.lua's landing sounds) keeps listening to CombatEvents exactly as before -- this script
	just has to exist and run once; it doesn't export anything.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local FallFeedbackSync = Remotes:WaitForChild("FallFeedbackSync") :: RemoteEvent

FallFeedbackSync.OnClientEvent:Connect(function(eventType: string, player: Player, ...)
	if eventType == "FastFallBegan" then
		local downwardSpeed = ...
		CombatEvents.FastFallBegan:Fire(player, downwardSpeed)
	elseif eventType == "FastFallEnded" then
		CombatEvents.FastFallEnded:Fire(player)
	elseif eventType == "FallImpact" then
		local peakFallSpeed, damageApplied, landingMaterial = ...
		CombatEvents.FallImpact:Fire(player, peakFallSpeed, damageApplied, landingMaterial)
	end
end)