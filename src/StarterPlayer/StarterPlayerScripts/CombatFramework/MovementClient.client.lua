--!strict
--[[
	MovementClient.client.lua  (Ch 1.5 Client Prediction, Ch 2 Character Controller)

	- Owns local input -> stance/lean requests.
	- Predicts immediately using the shared CharacterController (inertia ramp via
	  :Update(dt)), then asks the server to confirm; snaps back on StanceCorrection/
	  LeanCorrection if the server disagrees.
	- Lean is a client-felt camera peek via Humanoid.CameraOffset, smoothly lerped —
	  purely cosmetic on this end; the actual Left/Right/None STATE is still
	  server-validated same as stance, since other systems (accuracy, exposure to AI
	  perception) will want to read a trustworthy LeanState later.

	Keybinds (change freely, this is just a starting mapping):
		C           - toggle Crouch
		X           - toggle Prone (from Crouching OR directly from Standing/TacticalWalk)
		Left Alt    - toggle Tactical Walk
		Left Shift  - hold for Tactical Sprint
		Q / E       - hold to lean Left / Right
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CharacterController = require(CombatFramework.Movement.CharacterController)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local FallTuning = require(CombatFramework.Shared.Config.FallTuning)
local CameraShake = require(script.Parent.CameraShake)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local StanceRequest = Remotes:WaitForChild("StanceRequest") :: RemoteEvent
local StanceCorrection = Remotes:WaitForChild("StanceCorrection") :: RemoteEvent
local LeanRequest = Remotes:WaitForChild("LeanRequest") :: RemoteEvent
local LeanCorrection = Remotes:WaitForChild("LeanCorrection") :: RemoteEvent
local GravitySync = Remotes:WaitForChild("GravitySync") :: RemoteEvent

local player = Players.LocalPlayer

local controller: CharacterController.CharacterControllerInstance? = nil
local tacticalWalkHeld = false

-- Lean camera feel tuning.
local LEAN_OFFSET_STUDS = 2.2
local LEAN_LERP_SPEED = 9
local currentCameraOffset = Vector3.zero

-- Air-rush sound played while falling faster than FallTuning.FastFallVelocity.
-- Replace the placeholder SoundId with a real wind/rush asset before relying on this.
local windSound = Instance.new("Sound")
windSound.Name = "CombatFrameworkFallWind"
windSound.SoundId = "rbxassetid://0"
windSound.Looped = true
windSound.Volume = 0
windSound.Parent = SoundService

local function onCharacterAdded(character: Model)
	character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	controller = CharacterController.new(player, character, true)
	currentCameraOffset = Vector3.zero
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

local function requestStance(newStance: string)
	if not controller then
		return
	end
	local ok = controller:TryChangeStance(newStance)
	if ok then
		StanceRequest:FireServer(newStance)
	end
end

local function requestLean(direction: CharacterController.LeanDirection)
	if not controller then
		return
	end
	local ok = controller:TrySetLean(direction)
	if ok then
		LeanRequest:FireServer(direction)
	end
end

local function handleCrouchPress()
	if not controller then
		return
	end
	if controller.CurrentStance == "Crouching" then
		requestStance("Standing")
	elseif controller.CurrentStance == "Standing" or controller.CurrentStance == "TacticalWalk" then
		requestStance("Crouching")
	elseif controller.CurrentStance == "Prone" then
		requestStance("Crouching")
	end
end

local function handleProneToggle()
	if not controller then
		return
	end
	if controller.CurrentStance == "Prone" then
		requestStance("Crouching")
	else
		-- Standing, TacticalWalk, and Crouching can all drop straight to Prone.
		requestStance("Prone")
	end
end

local function handleTacticalWalkToggle()
	if not controller then
		return
	end
	tacticalWalkHeld = not tacticalWalkHeld
	if tacticalWalkHeld and controller.CurrentStance == "Standing" then
		requestStance("TacticalWalk")
	elseif not tacticalWalkHeld and controller.CurrentStance == "TacticalWalk" then
		requestStance("Standing")
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.C then
		handleCrouchPress()
	elseif input.KeyCode == Enum.KeyCode.X then
		handleProneToggle()
	elseif input.KeyCode == Enum.KeyCode.LeftAlt then
		handleTacticalWalkToggle()
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		if controller and controller.CurrentStance ~= "Crouching" and controller.CurrentStance ~= "Prone" then
			requestStance("TacticalSprint")
		end
	elseif input.KeyCode == Enum.KeyCode.Q then
		requestLean("Left")
	elseif input.KeyCode == Enum.KeyCode.E then
		requestLean("Right")
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		if controller and controller.CurrentStance == "TacticalSprint" then
			requestStance(if tacticalWalkHeld then "TacticalWalk" else "Standing")
		end
	elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.E then
		if controller then
			-- Only clear if THIS key was the one currently leaning (don't cancel a Right
			-- lean because the player happened to also tap Q on the way there, etc.)
			local shouldClear = (input.KeyCode == Enum.KeyCode.Q and controller.LeanState == "Left")
				or (input.KeyCode == Enum.KeyCode.E and controller.LeanState == "Right")
			if shouldClear then
				requestLean("None")
			end
		end
	end
end)

StanceCorrection.OnClientEvent:Connect(function(correctedStance: string)
	if controller then
		controller.CurrentStance = correctedStance
		controller:_applyStanceModifiers(correctedStance)
	end
end)

LeanCorrection.OnClientEvent:Connect(function(correctedLean: CharacterController.LeanDirection)
	if controller then
		controller.LeanState = correctedLean
	end
end)

-- Gravity zones (Ch 8.4, 15.4-15.5) are detected server-side via QuickZone, but the client
-- is the one that actually owns physics for its own character now (MomentumController's
-- VectorForce is what makes a Gravity override physically real) — so the server mirrors
-- every SetGravityOverride/ClearGravityOverride it makes for this player down through this
-- remote, and we replay the same call on our own local CharacterController here.
GravitySync.OnClientEvent:Connect(function(action: string, gravity: Vector3?, sourceId: string, priority: number?)
	if not controller then
		return
	end
	if action == "Set" and gravity then
		controller:SetGravityOverride(gravity, sourceId, priority)
	elseif action == "Clear" then
		controller:ClearGravityOverride(sourceId)
	end
end)

-- Ambient air-rush sound + continuous camera rumble while falling fast (starts the
-- moment downward speed crosses FallTuning.FastFallVelocity, stops the moment the fall ends).
local windTween: Tween? = nil

CombatEvents.FastFallBegan:Connect(function(firingPlayer: Player, _downwardSpeed: number)
	if firingPlayer ~= player then
		return
	end
	if windTween then
		windTween:Cancel()
	end
	if windSound.SoundId ~= "rbxassetid://0" and not windSound.IsPlaying then
		windSound:Play()
	end
	windTween = TweenService:Create(windSound, TweenInfo.new(0.3), { Volume = 0.6 })
	windTween:Play()

	CameraShake.SetContinuous("FastFall", FallTuning.MaxAmbientShakeMagnitude)
end)

CombatEvents.FastFallEnded:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end
	if windTween then
		windTween:Cancel()
	end
	windTween = TweenService:Create(windSound, TweenInfo.new(0.3), { Volume = 0 })
	windTween:Play()
	windTween.Completed:Once(function()
		windSound:Stop()
	end)

	CameraShake.SetContinuous("FastFall", 0)
end)

-- Landing impact: a one-off camera shake scaled by how fast the character was falling,
-- independent of whether it actually dealt damage (a fast-but-safe landing still shakes
-- a little; a lethal one shakes hard).
CombatEvents.FallImpact:Connect(function(firingPlayer: Player, peakFallSpeed: number, _damageApplied: number)
	if firingPlayer ~= player then
		return
	end

	if peakFallSpeed >= FallTuning.NotableLandingVelocity then
		local t = math.clamp(
			(peakFallSpeed - FallTuning.NotableLandingVelocity) / math.max(FallTuning.FastFallVelocity, 1),
			0,
			1
		)
		CameraShake.Shake(t * FallTuning.MaxImpactShakeMagnitude, FallTuning.MaxImpactShakeDuration)
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	if not controller then
		return
	end

	controller:Update(dt)

	-- Lean camera feel: smoothly lerp Humanoid.CameraOffset sideways based on LeanState.
	local targetOffset = Vector3.zero
	if controller.LeanState == "Left" then
		targetOffset = Vector3.new(-LEAN_OFFSET_STUDS, 0, 0)
	elseif controller.LeanState == "Right" then
		targetOffset = Vector3.new(LEAN_OFFSET_STUDS, 0, 0)
	end

	local alpha = math.clamp(LEAN_LERP_SPEED * dt, 0, 1)
	currentCameraOffset = currentCameraOffset:Lerp(targetOffset, alpha)
	controller.Humanoid.CameraOffset = currentCameraOffset
end)
