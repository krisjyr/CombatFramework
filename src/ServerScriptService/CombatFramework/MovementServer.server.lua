--!strict
--[[
	MovementServer.server.lua  (Ch 1.3 Server Authority)

	Owns the REAL server-side CharacterController per player for STANCE/lean validation and
	JumpPower/HipHeight — it does NOT own physics for the player's own character anymore
	(constructed with ownsPhysics = false); the controlling client does that via its own
	MomentumController (see CharacterController.lua, MomentumController.lua). Every
	stance/lean change a client claims to have made still gets re-validated here against the
	exact same rules.

	Freefall/Jumping -> "Jumping" stance auto-transition stays here (it's a movement/stance
	concern). Fall-VELOCITY tracking for damage purposes lives ENTIRELY in FallService.lua
	— this file no longer keeps its own IsFalling/peak-speed bookkeeping.

	Animation Move/Idle swapping is driven by controller:IsMoving(), which on this
	(non-physics-owning) side falls back to the character's real replicated planar velocity
	rather than raw input, so it stays accurate even now that releasing input slides to a
	stop via momentum instead of snapping.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CharacterController = require(CombatFramework.Movement.CharacterController)
local AnimationController = require(CombatFramework.Movement.AnimationController)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)

local ControllerRegistry = require(script.Parent.ControllerRegistry)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local StanceRequest = Remotes:WaitForChild("StanceRequest") :: RemoteEvent
local StanceCorrection = Remotes:WaitForChild("StanceCorrection") :: RemoteEvent
local LeanRequest = Remotes:WaitForChild("LeanRequest") :: RemoteEvent
local LeanCorrection = Remotes:WaitForChild("LeanCorrection") :: RemoteEvent

local lastRequestAt: { [Player]: number } = {}
local MIN_REQUEST_INTERVAL = 0.1

-- Remembers which stance a player was in before they went airborne, so landing restores
-- Standing vs TacticalWalk vs Crouching correctly instead of always snapping to Standing.
local preJumpStance: { [Player]: string } = {}

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	character:WaitForChild("HumanoidRootPart")

	local characterController = CharacterController.new(player, character, false)
	local animationController = AnimationController.new(humanoid)
	ControllerRegistry.Set(player, { Character = characterController, Animation = animationController })

	humanoid.StateChanged:Connect(function(_old, new)
		if new == Enum.HumanoidStateType.Freefall or new == Enum.HumanoidStateType.Jumping then
			if characterController.CurrentStance ~= "Jumping" then
				preJumpStance[player] = characterController.CurrentStance
				characterController:TryChangeStance("Jumping")
			end
		elseif new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
			if characterController.CurrentStance == "Jumping" then
				local restoreTo = preJumpStance[player] or "Standing"
				local ok = characterController:TryChangeStance(restoreTo)
				if not ok then
					characterController:TryChangeStance("Standing")
				end
			end
		end
	end)
end

local function onPlayerAdded(player: Player)
	lastRequestAt[player] = 0
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	ControllerRegistry.Remove(player)
	lastRequestAt[player] = nil
	preJumpStance[player] = nil
end)

StanceRequest.OnServerEvent:Connect(function(player: Player, newStance: unknown)
	if typeof(newStance) ~= "string" then
		return
	end

	local now = os.clock()
	if now - (lastRequestAt[player] or 0) < MIN_REQUEST_INTERVAL then
		return
	end
	lastRequestAt[player] = now

	local entry = ControllerRegistry.Get(player)
	if not entry then
		return
	end

	local ok = entry.Character:TryChangeStance(newStance)
	if not ok then
		StanceCorrection:FireClient(player, entry.Character.CurrentStance)
	end
end)

LeanRequest.OnServerEvent:Connect(function(player: Player, direction: unknown)
	if typeof(direction) ~= "string" then
		return
	end

	local entry = ControllerRegistry.Get(player)
	if not entry then
		return
	end

	local ok = entry.Character:TrySetLean(direction :: any)
	if not ok then
		LeanCorrection:FireClient(player, entry.Character.LeanState)
	end
end)

CombatEvents.StanceChanged:Connect(function(player: Player, newStance: string, _oldStance: string)
	local entry = ControllerRegistry.Get(player)
	if entry then
		entry.Animation:SetStance(newStance)
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	for _player, entry in pairs(ControllerRegistry.All()) do
		entry.Character:Update(dt)
		entry.Animation:SetMoving(entry.Character:IsMoving())
	end
end)
