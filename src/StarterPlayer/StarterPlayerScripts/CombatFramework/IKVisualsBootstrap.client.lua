--!strict
--[[
	IKVisualsBootstrap.client.lua

	Constructs an IKLegController + TorsoTiltController for every visible character.

	RAGDOLL INTEGRATION:
	- Ragdolled attribute disables ALL procedural IK and torso posing.
	- On recovery, IK state is reset before being enabled again.
	- A one-frame defer prevents IK from immediately fighting the freshly restored
	  Motor6Ds after RagdollService exits.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local IKLegController = require(CombatFramework.Movement.IKLegController)
local TorsoTiltController = require(CombatFramework.Movement.TorsoTiltController)
local IKControllerRegistry = require(script.Parent.IKControllerRegistry)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local LookDirectionUpdate = Remotes:WaitForChild("LookDirectionUpdate") :: RemoteEvent

local localPlayer = Players.LocalPlayer

type Entry = {
	Leg: IKLegController.IKLegControllerInstance,
	Torso: TorsoTiltController.TorsoTiltControllerInstance?,
	RootPart: BasePart,
	AttributeConn: RBXScriptConnection?,
}

local entries: { [Model]: Entry } = {}

local MOVE_SPEED_THRESHOLD = 0.5

local function isMoving(rootPart: BasePart): boolean
	local velocity = rootPart.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude > MOVE_SPEED_THRESHOLD
end

local function teardown(character: Model)
	local entry = entries[character]
	if not entry then
		return
	end

	if entry.AttributeConn then
		entry.AttributeConn:Disconnect()
	end

	entry.Leg:Destroy()
	entries[character] = nil
	IKControllerRegistry.Remove(character)
end

local function setup(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	local rootPart = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?

	if not humanoid or not rootPart then
		return
	end

	local legController = IKLegController.new(character, humanoid)

	if not legController then
		IKControllerRegistry.Remove(character)
		return
	end

	IKControllerRegistry.Set(character, legController)

	local torsoController =
		TorsoTiltController.new(character, player == localPlayer)

	local function applyRagdollState()
		local ragdolled =
			humanoid:GetAttribute("Ragdolled") == true

		if ragdolled then
			-- Clear any planted-foot / step / arm state before disabling.
			print("Clearning IK state for ragdoll")
			if legController.ResetRagdollState then
				legController:ResetRagdollState()
			end

			print("Disabling IK for ragdoll")
			legController:SetEnabled(false)

			if torsoController then
				torsoController:SetEnabled(false)
			end

			return
		end

		-- The server restores constraints and Motor6Ds before setting
		-- Ragdolled false, but wait one render/update turn before procedural
		-- controllers begin writing again.
		task.defer(function()
			if not character.Parent then
				return
			end

			if humanoid:GetAttribute("Ragdolled") == true then
				return
			end

			print("Enabling IK for ragdoll")
			if legController.ResetRagdollState then
				legController:ResetRagdollState()
			end

			legController:SetEnabled(true)

			if torsoController then
				torsoController:SetEnabled(true)
			end
		end)
	end

	local attributeConn =
		humanoid:GetAttributeChangedSignal("Ragdolled"):Connect(
			applyRagdollState
		)

	entries[character] = {
		Leg = legController,
		Torso = torsoController,
		RootPart = rootPart,
		AttributeConn = attributeConn,
	}

	-- Apply the initial state after the entry exists.
	applyRagdollState()

	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			teardown(character)
		end
	end)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		setup(player, character)
	end)

	if player.Character then
		setup(player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	if player.Character then
		teardown(player.Character)
	end
end)

local LOOK_SEND_INTERVAL = 1 / 20
local lookSendAccum = 0

RunService.Heartbeat:Connect(function(dt: number)
	local camera = workspace.CurrentCamera

	local cameraPosition =
		if camera then camera.CFrame.Position else Vector3.zero

	local localLookDirection =
		if camera then camera.CFrame.LookVector else nil

	local localCharacter = localPlayer.Character

	if localCharacter and localLookDirection then
		lookSendAccum += dt

		if lookSendAccum >= LOOK_SEND_INTERVAL then
			lookSendAccum = 0
			LookDirectionUpdate:FireServer(localLookDirection)
		end
	end

	for character, entry in pairs(entries) do
		-- Do not let ANY procedural body system touch a ragdolled character.
		local humanoid = character:FindFirstChild("Humanoid")
		if humanoid:GetAttribute("Ragdolled") == true then
			continue
		end

		local distance =
			(entry.RootPart.Position - cameraPosition).Magnitude

		entry.Leg:Update(dt, distance)

		local isLocal =
			character == localCharacter

		local lookDirection: Vector3? =
			if isLocal
				then localLookDirection
				else character:GetAttribute("LookDirection") :: Vector3?

		local clearance =
			if entry.Torso
				then entry.Torso:GetBodyClearance()
				else 1

		entry.Leg:UpdateHeadLook(
			dt,
			lookDirection,
			clearance
		)

		if entry.Torso then
			local moving =
				isMoving(entry.RootPart)

			local lean =
				character:GetAttribute("CombatLean") :: string?

			entry.Torso:Update(
				dt,
				moving,
				lookDirection,
				lean
			)
		end
	end
end)