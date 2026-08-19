--!strict
--[[
	DeathRagdollBootstrap.server.lua

	Death sequence:

	1. Humanoid dies.
	2. ORIGINAL character immediately enters ragdoll.
	3. The body physically begins collapsing.
	4. After DeathCorpseCloneDelay, the CURRENT ragdoll body is cloned.
	5. The clone is placed into Workspace.Ragdolls.
	6. Roblox may destroy the original and respawn the player.
	7. The cloned corpse remains.

	This avoids the ugly "fresh corpse suddenly appears at the moment of death"
	behaviour.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework =
	ReplicatedStorage:WaitForChild(
		"CombatFramework"
	)

local RagdollTuning =
	require(
		CombatFramework.Shared.Config.RagdollTuning
	)

local RagdollService =
	require(
		script.Parent.RagdollService
	)

local function onCharacterAdded(
	character: Model
)
	local humanoid =
		character:WaitForChild("Humanoid") :: Humanoid

	humanoid.BreakJointsOnDeath = false

	humanoid.Died:Connect(function()
		-- The body itself ragdolls immediately.
		local impulse, impulsePart =
			RagdollService.ConsumePendingImpact(
				character
			)

		RagdollService.Enter(
			character,
			{
				Reason = "Death",
				Impulse = impulse,
				ImpulsePart = impulsePart,
			}
		)

		-- Clone the body AFTER it has already physically started falling.
		task.delay(
			RagdollTuning.DeathCorpseCloneDelay,
			function()
				if not character.Parent then
					return
				end

				RagdollService.CreateDeathCorpse(
					character
				)
			end
		)
	end)
end

local function onPlayerAdded(
	player: Player
)
	player.CharacterAdded:Connect(
		onCharacterAdded
	)

	if player.Character then
		onCharacterAdded(
			player.Character
		)
	end

	player.CharacterRemoving:Connect(function(
		character: Model
	)
		-- This only cleans references belonging to the original.
		-- The persistent corpse is a separate model and survives.
		RagdollService.Cleanup(
			character
		)
	end)
end

Players.PlayerAdded:Connect(
	onPlayerAdded
)

for _, player in ipairs(
	Players:GetPlayers()
) do
	onPlayerAdded(player)
end