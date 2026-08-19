--!strict
--[[
	BreathInputController.client.lua

	Local player's hold-breath input only -- request/response with the server, which is the
	sole authority over Oxygen (Ch 1.3). No local prediction of the hold state itself since
	there's nothing to predict visually yet (future vignette UI will read OxygenChanged
	directly, not this).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local BreathHoldRequest = Remotes:WaitForChild("BreathHoldRequest") :: RemoteEvent

local HOLD_BREATH_KEY = Enum.KeyCode.B

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == HOLD_BREATH_KEY then
		BreathHoldRequest:FireServer(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.KeyCode == HOLD_BREATH_KEY then
		BreathHoldRequest:FireServer(false)
	end
end)