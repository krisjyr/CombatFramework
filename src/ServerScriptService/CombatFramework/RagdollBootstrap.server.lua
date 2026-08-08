--!strict
--[[
	RagdollBootstrap.server.lua

	Tag any Model "DebugRagdoll" (CollectionService) to have it enter ragdoll automatically
	on tag-add and exit on tag-remove -- convenient for testing RagdollService.lua in
	Studio before Ch 8's Status Framework (or a real "downed" trigger from Ch 7) exists to
	drive it for real.

	--------------------------------------------------------------------------------
	Recommended future CMDR commands (Ch 14 Developer API), same pattern as
	FallServiceBootstrap.server.lua, once CMDR is wired in (Ch 17.3):

		ragdoll <player>
			-> RagdollService.Enter(player.Character)

		unragdoll <player>
			-> RagdollService.Exit(player.Character)

		ragdoll_isragdolled <player>
			-> print(RagdollService.IsRagdolled(player.Character))

	A custom CMDR `character` type (mirroring the `weapon`/`status`/`zone` types described
	in Ch 17.3) that resolves a player name (or "me") to their Character is the natural way
	to back these once CMDR is online.
	--------------------------------------------------------------------------------
]]

local CollectionService = game:GetService("CollectionService")

local RagdollService = require(script.Parent.RagdollService)

local TAG = "DebugRagdoll"

CollectionService:GetInstanceAddedSignal(TAG):Connect(function(instance: Instance)
	if instance:IsA("Model") then
		RagdollService.Enter(instance)
	end
end)

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance: Instance)
	if instance:IsA("Model") then
		RagdollService.Exit(instance)
	end
end)

for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
	if instance:IsA("Model") then
		RagdollService.Enter(instance)
	end
end
