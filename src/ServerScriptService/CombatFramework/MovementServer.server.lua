--!strict
--[[
	MovementServer.server.lua  (Ch 1.3 Server Authority)

	Owns the REAL server-side CharacterController per player for STANCE/lean validation and
	JumpPower/HipHeight — it does NOT own physics for the player's own character anymore
	(constructed with ownsPhysics = false); the controlling client does that via its own
	MomentumController (see CharacterController.lua, MomentumController.lua). Every
	stance/lean change a client claims to have made still gets re-validated here against the
	exact same rules.

	Freelook/Jumping -> "Jumping" stance auto-transition stays here (it's a movement/stance
	concern). Fall-VELOCITY tracking for damage purposes lives ENTIRELY in FallService.lua
	— this file no longer keeps its own IsFalling/peak-speed bookkeeping.

	Animation Move/Idle swapping is driven by controller:IsMoving(), which on this
	(non-physics-owning) side falls back to the character's real replicated planar velocity
	rather than raw input, so it stays accurate even now that releasing input slides to a
	stop via momentum instead of snapping.

	NEW (Look IK pass): every validated Stance/Lean change is also mirrored onto a
	Character Attribute ("CombatStance" / "CombatLean"). Attributes replicate to every
	client automatically, so RemoteLookIKClient.client.lua (Ch 2.9/9 look-direction body
	IK) can read another player's current stance/lean for free, with no extra remote traffic
	— the same trick GravityZoneHandler could have used, but that one needs to actively
	*force* client-side physics state, which Attributes can't do; this one only needs to be
	*read*, which is exactly what Attributes are for.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CharacterController = require(CombatFramework.Movement.CharacterController)
local AnimationController = require(CombatFramework.Movement.AnimationController)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local SoundService = require(CombatFramework.Shared.SoundService)

local ControllerRegistry = require(script.Parent.ControllerRegistry)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local StanceRequest = Remotes:WaitForChild("StanceRequest") :: RemoteEvent
local StanceCorrection = Remotes:WaitForChild("StanceCorrection") :: RemoteEvent
local LeanRequest = Remotes:WaitForChild("LeanRequest") :: RemoteEvent
local LeanCorrection = Remotes:WaitForChild("LeanCorrection") :: RemoteEvent
local LookDirectionUpdate = Remotes:WaitForChild("LookDirectionUpdate") :: RemoteEvent

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

	-- Seed the replicated Attributes so RemoteLookIKClient has a correct value immediately,
	-- instead of waiting for the first stance/lean change to ever happen.
	character:SetAttribute("CombatStance", characterController.CurrentStance)
	character:SetAttribute("CombatLean", characterController.LeanState)

	humanoid.StateChanged:Connect(function(_old, new)
		if character:GetAttribute("Ragdolled") then
			return
		end
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
	if player.Character and player.Character:GetAttribute("Ragdolled") then
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

LookDirectionUpdate.OnServerEvent:Connect(function(player: Player, lookDirection: Vector3)
    local character = player.Character
    if not character then return end
    if typeof(lookDirection) ~= "Vector3" then return end -- basic sanity check
    character:SetAttribute("LookDirection", lookDirection)
end)

CombatEvents.StanceChanged:Connect(function(player: Player, newStance: string, _oldStance: string)
	local entry = ControllerRegistry.Get(player)
	if entry then
		entry.Animation:SetStance(newStance)
	end
	if player.Character then
		player.Character:SetAttribute("CombatStance", newStance)
		if newStance == "Crouching" then
			SoundService.Play("Movement.StanceCrouch", {
				Parent = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart,
				Volume = 0.5,
			})
		elseif newStance == "Prone" then
			SoundService.Play("Movement.StanceProne", {
				Parent = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart,
				Volume = 0.5,
			})
		elseif (_oldStance == "Standing" or _oldStance == "Crouching") and newStance == "Standing" then
			SoundService.Play("Movement.StanceStand", {
				Parent = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart,
				Volume = 0.5,
			})
		end
	end
end)

CombatEvents.LeanChanged:Connect(function(player: Player, direction: string)
	if player.Character then
		player.Character:SetAttribute("CombatLean", direction)
		SoundService.Play("Movement.StanceLean", {
			Parent = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart,
			Volume = 0.5,
		})
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	for _player, entry in pairs(ControllerRegistry.All()) do
		entry.Character:Update(dt)
		entry.Animation:SetMoving(entry.Character:IsMoving())
	end
end)
