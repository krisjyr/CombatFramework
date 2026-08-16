--!strict
--[[
	IKVisualsBootstrap.client.lua

	Constructs an IKLegController + TorsoTiltController for EVERY character this client
	can see -- its own AND every other player's -- because IK pose is purely cosmetic
	(Ch 11) and therefore purely client-local (see the ownership-model comment at the top
	of IKLegController.lua). There is deliberately no server-side counterpart to this file.

	HEAD LOOK / FREE-LOOK: the local player's head-look direction comes straight from the
	live camera every frame (zero latency). Since IK pose never replicates on its own,
	other clients need SOME way to know where a remote player is actually looking, so the
	local player also republishes its own camera direction onto its character as a
	`LookDirection` Vector3 Attribute -- the same "cheap, cosmetic, non-authoritative"
	attribute convention this framework already uses for `CombatStance`. Every observing
	client (including this one, for everyone else's character) reads that attribute back
	off each character and feeds it into that character's own IKLegController.

	The SAME `lookDirection` value is now also fed into TorsoTiltController (previously
	local-player-only -- it can drive its idle Waist follow / TacticalWalk tilt / lean
	roll for remote players too, for free, off this same attribute). CombatLean is read
	the same way CombatStance already is, for the lean-roll piece.

	Also listens for the "Ragdolled" attribute (set by RagdollService.lua, server-
	authoritative) to disable foot-ground IK AND torso tilt/lean while a character is
	ragdolled, so neither system fights the ragdoll's own IKControls (RagdollService.lua
	drives its own rope-target IKControls for that state).
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
        return -- not an R15-shaped rig; nothing to do
    end

    IKControllerRegistry.Set(character, legController)

    local torsoController = TorsoTiltController.new(character, player == localPlayer)

    local attributeConn = character:GetAttributeChangedSignal("Ragdolled"):Connect(function()
        local ragdolled = character:GetAttribute("Ragdolled") == true
        legController:SetEnabled(not ragdolled)
        if torsoController then
            torsoController:SetEnabled(not ragdolled)
        end
    end)
    if character:GetAttribute("Ragdolled") == true then
        legController:SetEnabled(false)
        if torsoController then
            torsoController:SetEnabled(false)
        end
    end

    entries[character] = {
        Leg = legController,
        Torso = torsoController,
        RootPart = rootPart,
        AttributeConn = attributeConn,
    }

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
    local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
    local localLookDirection = if camera then camera.CFrame.LookVector else nil

    local localCharacter = localPlayer.Character
    if localCharacter and localLookDirection then
        -- Keep the LOCAL read zero-latency by still setting it locally for our own use...
        lookSendAccum += dt
        if lookSendAccum >= LOOK_SEND_INTERVAL then
            lookSendAccum = 0
            LookDirectionUpdate:FireServer(localLookDirection)
        end
    end

    for character, entry in pairs(entries) do
        local distance = (entry.RootPart.Position - cameraPosition).Magnitude
        entry.Leg:Update(dt, distance)

        local isLocal = character == localCharacter
        local lookDirection: Vector3? = if isLocal
            then localLookDirection
            else character:GetAttribute("LookDirection") :: Vector3?

        local clearance = if entry.Torso then entry.Torso:GetBodyClearance() else 1
        entry.Leg:UpdateHeadLook(dt, lookDirection, clearance)


        if entry.Torso then
            local moving = isMoving(entry.RootPart)
            local lean = character:GetAttribute("CombatLean") :: string?
            entry.Torso:Update(dt, moving, lookDirection, lean)
        end
    end
end)
