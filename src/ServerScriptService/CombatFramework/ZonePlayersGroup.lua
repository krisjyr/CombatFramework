--!strict
--[[
	ZonePlayersGroup.lua

	Single shared QuickZone Group.players() instance, reused by every zone handler
	(GravityZoneHandler, BreathZoneHandler, and any future Ch16.6 zone system) instead of
	each handler creating its own duplicate player-tracking group. Module caching makes
	this a true singleton -- every require() of this file returns the same Group.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local QuickZone = require(ReplicatedStorage.Packages.quickzone)
local Group = QuickZone.Group

return Group.players()