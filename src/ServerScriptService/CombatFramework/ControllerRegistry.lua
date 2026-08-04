--!strict
--[[
	ControllerRegistry.lua

	Server-only lookup table so MovementServer, FallService, and the QuickZone gravity-zone
	handler can all reach the same per-player CharacterController / AnimationController
	instances without each maintaining its own duplicate copy.
]]

local CharacterController = require(game:GetService("ReplicatedStorage").CombatFramework.Movement.CharacterController)
local AnimationController = require(game:GetService("ReplicatedStorage").CombatFramework.Movement.AnimationController)

export type Entry = {
	Character: CharacterController.CharacterControllerInstance,
	Animation: AnimationController.AnimationControllerInstance,
}

local ControllerRegistry = {}

local entries: { [Player]: Entry } = {}

function ControllerRegistry.Set(player: Player, entry: Entry)
	entries[player] = entry
end

function ControllerRegistry.Get(player: Player): Entry?
	return entries[player]
end

function ControllerRegistry.Remove(player: Player)
	local entry = entries[player]
	if entry then
		entry.Animation:Destroy()
	end
	entries[player] = nil
end

function ControllerRegistry.All(): { [Player]: Entry }
	return entries
end

return ControllerRegistry
