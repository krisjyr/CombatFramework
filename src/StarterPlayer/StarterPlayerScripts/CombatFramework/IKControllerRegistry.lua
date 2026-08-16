--!strict
--[[
	IKControllerRegistry.lua  (client-only)

	Mirrors ServerScriptService/CombatFramework/ControllerRegistry.lua's pattern for the
	client-side IK layer: IKVisualsBootstrap.client.lua constructs one IKLegController per
	VISIBLE character and registers it here so other client systems (FootstepService today,
	a future dust-kickup VFX listener tomorrow) can subscribe to FootPlantedEvent without
	needing to know how/where IK controllers are built. This is the whole reason
	FootstepService doesn't need its own tuning -- IK already did the work, this is just how
	that work reaches other systems.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Packages.namedsignal)
local IKLegController = require(ReplicatedStorage.CombatFramework.Movement.IKLegController)

local IKControllerRegistry = {}

IKControllerRegistry.Added = Signal.new<<(character: Model, controller: IKLegController.IKLegControllerInstance) -> ()>>()
IKControllerRegistry.Removed = Signal.new<<(character: Model) -> ()>>()

local entries: { [Model]: IKLegController.IKLegControllerInstance } = {}

function IKControllerRegistry.Set(character: Model, controller: IKLegController.IKLegControllerInstance)
	entries[character] = controller
	IKControllerRegistry.Added:Fire(character, controller)
end

function IKControllerRegistry.Get(character: Model): IKLegController.IKLegControllerInstance?
	return entries[character]
end

function IKControllerRegistry.Remove(character: Model)
	if entries[character] then
		entries[character] = nil
		IKControllerRegistry.Removed:Fire(character)
	end
end

function IKControllerRegistry.All(): { [Model]: IKLegController.IKLegControllerInstance }
	return entries
end

return IKControllerRegistry