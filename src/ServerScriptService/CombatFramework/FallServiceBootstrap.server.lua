--!strict
--[[
	FallServiceBootstrap.server.lua

	Sets up a "Default" FallGroup (using FallTuning.lua's shared defaults) and links every
	player to it. Create additional FallGroups here for e.g. a hardcore game mode, and
	call FallGroup:LinkPlayer / :Toggle for the players who should use them instead of
	Default.

	MaterialsDamage.Water = 0 means landing in water is always a safe landing regardless
	of fall speed (on top of FallService already treating the Swimming Humanoid state as
	safe automatically) — kept here as an explicit example of the options shape.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local FallTuning = require(CombatFramework.Shared.Config.FallTuning)
local FallService = require(script.Parent.FallService)

local DefaultGroup = FallService.new("Default", FallTuning.MinDistance, FallTuning.DamageMultiplier, {
	MaterialsDamage = {
		Water = 0,
	},
	-- LethalDistance / Curve / FastFallVelocity intentionally omitted here so this group
	-- just uses FallTuning's shared defaults; override per-group by passing them explicitly.
})

local function onPlayerAdded(player: Player)
	DefaultGroup:LinkPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

--[[
	Recommended future CMDR commands (Ch 14 Developer API) once CMDR is wired in:

		falldamage_toggle <player> <bool>
			-> FallService:GetGroupOf(player):Toggle(player, bool)

		falldamage_setgroup <player> <groupName>
			-> FallService:GetGroupOf(player):UnlinkPlayer(player)
			   FallService:GetGroup(groupName):LinkPlayer(player)

		falldamage_setcustom <player> <minDistance> <damageMultiplier>
			-> FallService:SetCustomData(player, minDistance, damageMultiplier)

		falldamage_clearcustom <player>
			-> FallService:SetCustomData(player, nil, nil)

		falldamage_inspect <player>
			-> print(FallService:GetCustomData(player) or FallService:GetGroupOf(player))

	A custom CMDR `fallGroup` type that autocompletes registered group names (mirroring the
	`weapon`/`status`/`zone` types described in Ch 17.3) is the natural way to back
	falldamage_setgroup once CMDR is online.
]]
