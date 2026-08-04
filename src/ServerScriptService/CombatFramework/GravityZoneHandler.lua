--!strict
--[[
	GravityZoneHandler.lua  (Ch 8.4, 15.4-15.5, 16.6)

	QuickZone owns "who is in the zone." This module forwards its enter/exit events into
	the same CharacterController every other system uses (SetGravityOverride /
	SetMovementProfile) — QuickZone never touches gameplay outcomes directly (Ch 17.4's
	rule for ZonePlus applies identically here).

	IMPORTANT: since real gravity force application now happens client-side via
	MomentumController (the controlling client owns physics for its own character), a
	server-detected zone change is meaningless on its own — the client's independent
	CharacterController/ModifierStack has no way to know a zone was entered unless we tell
	it. So every SetGravityOverride/ClearGravityOverride made here is mirrored to that
	player's client through the GravitySync RemoteEvent, and the client replays the same
	call on its own local CharacterController (see MovementClient.client.lua). Without this,
	gravity zones would silently do nothing.

	NOTE: quickzone lives under ReplicatedStorage.Packages (the single shared Packages
	folder), not a separate ServerPackages — there is no ServerPackages in this project.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Quickzone = require(ReplicatedStorage.Packages.quickzone)

local ControllerRegistry = require(script.Parent.ControllerRegistry)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local GravitySync = Remotes:WaitForChild("GravitySync") :: RemoteEvent

export type GravityZoneConfig = {
	Container: Instance,
	Gravity: Vector3,
	MovementProfile: string?,
	Priority: number,
}

local function CreateGravityZone(config: GravityZoneConfig)
	local zone = Quickzone.new(config.Container)
	local sourceId = `Zone:{config.Container:GetFullName()}`

	zone.playerEntered:Connect(function(player: Player)
		local entry = ControllerRegistry.Get(player)
		if not entry then
			return
		end
		entry.Character:SetGravityOverride(config.Gravity, sourceId, config.Priority)
		if config.MovementProfile then
			entry.Character:SetMovementProfile(config.MovementProfile, sourceId)
		end

		GravitySync:FireClient(player, "Set", config.Gravity, sourceId, config.Priority)
	end)

	zone.playerExited:Connect(function(player: Player)
		local entry = ControllerRegistry.Get(player)
		if not entry then
			return
		end
		entry.Character:ClearGravityOverride(sourceId)
		if config.MovementProfile then
			entry.Character:ClearMovementProfileOverride(sourceId)
		end

		GravitySync:FireClient(player, "Clear", nil, sourceId, nil)
	end)

	return zone
end

return CreateGravityZone
