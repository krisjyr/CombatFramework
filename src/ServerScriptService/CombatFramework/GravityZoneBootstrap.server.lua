--!strict
--[[
	GravityZoneBootstrap.server.lua  (Ch 15.4 Zone Creation Pipeline)

	Turns any part/model tagged "GravityZone" (CollectionService) into a live gravity zone.

	Tag a Part/Model "GravityZone" in Studio and set these Attributes on it:
		GravityX, GravityY, GravityZ  (numbers -- the override gravity vector)
		MovementProfile               (optional string -- e.g. "ZeroGravity")
		Priority                      (optional number, default 0 -- Ch 15.5 zone blending)
]]

local CollectionService = game:GetService("CollectionService")

local CreateGravityZone = require(script.Parent.GravityZoneHandler)

local ZONE_TAG = "GravityZone"

local function setupZoneInstance(instance: Instance)
	local gx = instance:GetAttribute("GravityX")
	local gy = instance:GetAttribute("GravityY")
	local gz = instance:GetAttribute("GravityZ")

	if typeof(gx) ~= "number" or typeof(gy) ~= "number" or typeof(gz) ~= "number" then
		warn(`GravityZoneBootstrap: {instance:GetFullName()} is tagged "{ZONE_TAG}" but is missing numeric GravityX/GravityY/GravityZ attributes`)
		return
	end

	CreateGravityZone({
		Container = instance,
		Gravity = Vector3.new(gx, gy, gz),
		MovementProfile = instance:GetAttribute("MovementProfile"),
		Priority = instance:GetAttribute("Priority") or 0,
	})
end

for _, instance in ipairs(CollectionService:GetTagged(ZONE_TAG)) do
	setupZoneInstance(instance)
end

CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(setupZoneInstance)
