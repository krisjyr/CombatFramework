--!strict
--[[
	MovementClient.client.lua  (Ch 1.5 Client Prediction, Ch 2 Character Controller)

	CRITICAL CHANGE this pass: Roblox's default character controller is now DISABLED
	(Controls:Disable() below). It was independently calling Humanoid:Move() every frame
	and fighting MomentumController's smoothed direction, which is the actual reason
	turning never visibly worked in any earlier pass. This script is now the ONLY source
	of movement input for the local player — raw WASD/gamepad via InputController, jump
	handled manually, camera-relative direction fed straight into CharacterController.

	- Predicts stance/lean locally same as before, server confirms/corrects.
	- Movement direction: InputController (camera-relative raw input) -> CharacterController
	  :Update(dt, moveDirection) -> MomentumController (speed ramp, turn cut, facing).
	- Camera: CameraMotion.lua layers Athletic-Operator head-bob/turn-lean/landing-jounce
	  on top of the default camera, driven by real speed/turn-rate data each frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CharacterController = require(CombatFramework.Movement.CharacterController)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local FallTuning = require(CombatFramework.Shared.Config.FallTuning)
local CameraInertiaController = require(CombatFramework.Movement.CameraInertiaController)
local CameraShake = require(script.Parent.CameraShake)
local CameraMotion = require(script.Parent.CameraMotion)
local InputController = require(script.Parent.InputController)
local FirstPersonVisibility = require(script.Parent.FirstPersonVisibility)
local FirstPersonZoomController = require(script.Parent.FirstPersonZoomController)
local LocalBodyClearance = require(CombatFramework.Shared.LocalBodyClearance)
local SoundService = require(CombatFramework.Shared.SoundService)

local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local StanceRequest = Remotes:WaitForChild("StanceRequest") :: RemoteEvent
local StanceCorrection = Remotes:WaitForChild("StanceCorrection") :: RemoteEvent
local LeanRequest = Remotes:WaitForChild("LeanRequest") :: RemoteEvent
local LeanCorrection = Remotes:WaitForChild("LeanCorrection") :: RemoteEvent
local GravitySync = Remotes:WaitForChild("GravitySync") :: RemoteEvent
local RagdollSync = Remotes:WaitForChild("RagdollSync") :: RemoteEvent

local player = Players.LocalPlayer

-- Disable Roblox's default movement/jump control ONCE — see file header for why this is
-- mandatory, not optional. Camera control (CameraModule) is separate and untouched.
local playerScripts = player:WaitForChild("PlayerScripts")
local playerModule = require(playerScripts:WaitForChild("PlayerModule"))
local defaultControls = playerModule:GetControls()
defaultControls:Disable()

local inputController = InputController.new()

local controller: CharacterController.CharacterControllerInstance? = nil
local tacticalWalkHeld = false

-- Lean camera feel tuning.
local LEAN_OFFSET_STUDS = 0
local LEAN_LERP_SPEED = 9
local currentCameraOffset = Vector3.zero

local cameraInertia: CameraInertiaController.CameraInertiaControllerInstance? = nil

type FallSession = { RootPart: BasePart, Humanoid: Humanoid, SourceId: string }
local activeFalls: { [Model]: FallSession } = {}

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	controller = CharacterController.new(player, character, true)
	cameraInertia = CameraInertiaController.new(workspace.CurrentCamera, humanoid, rootPart, controller)
	currentCameraOffset = Vector3.zero
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

-- === Manual jump (Controls:Disable() removes jump input too) ===============
local function tryJump()
	if not controller then
		return
	end
	local resolved = controller:Resolve()
	if resolved.JumpPower <= 0 then
		return
	end
	controller.Humanoid.Jump = true
end

-- === Stance / Lean (unchanged from before) ==================================

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
	elseif input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
		tryJump()
	elseif input.KeyCode == Enum.KeyCode.LeftControl and cameraInertia then
		cameraInertia:SetFreelooking(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		if controller and controller.CurrentStance == "TacticalSprint" then
			requestStance(if tacticalWalkHeld then "TacticalWalk" else "Standing")
		end
	elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.E then
		if controller then
			local shouldClear = (input.KeyCode == Enum.KeyCode.Q and controller.LeanState == "Left")
				or (input.KeyCode == Enum.KeyCode.E and controller.LeanState == "Right")
			if shouldClear then
				requestLean("None")
			end
		end
	elseif input.KeyCode == Enum.KeyCode.LeftControl and cameraInertia then
		cameraInertia:SetFreelooking(false)
		if player.Character then
			player.Character:SetAttribute("CombatFreelooking", false)
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

RagdollSync.OnClientEvent:Connect(function(isRagdolled: boolean)
	if controller then
		controller:SetRagdollSuspended(isRagdolled)
	end
end)

GravitySync.OnClientEvent:Connect(function(action: string, gravity: Vector3?, sourceId: string, priority: number?, movementProfile: string?)
	if not controller then
		return
	end
	if action == "Set" then
		if gravity then
			controller:SetGravityOverride(gravity, sourceId, priority)
		end
		if movementProfile then
			controller:SetMovementProfile(movementProfile, sourceId)
		end
	elseif action == "Clear" then
		controller:ClearGravityOverride(sourceId)
		if movementProfile then
			controller:ClearMovementProfileOverride(sourceId)
		end
	end
end)

-- === Fall feedback (unchanged) ===============================================

local function fallSourceId(character: Model): string
	return `Fall:{character:GetFullName()}`
end

CombatEvents.FastFallBegan:Connect(function(firingPlayer: Player, _downwardSpeed: number)
	if firingPlayer ~= player then
		return
	end

	local sourceId = fallSourceId(firingPlayer.Character)
	activeFalls[firingPlayer.Character] = { RootPart = firingPlayer.Character:WaitForChild("HumanoidRootPart"), Humanoid = firingPlayer.Character:WaitForChild("Humanoid"), SourceId = sourceId }

	SoundService.PlayContinuous("Movement.FallWind", sourceId, {
		Parent = rootPart,
		Volume = 1,
		PlaybackSpeed = 1 + 0.3 * math.clamp(_downwardSpeed / FallTuning.FastFallVelocity, 0, 1)
	})

	CameraShake.SetContinuous("FastFall", FallTuning.MaxAmbientShakeMagnitude)
end)

CombatEvents.FastFallEnded:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end

		local session = activeFalls[firingPlayer.Character]
	if not session then
		return
	end
	activeFalls[firingPlayer.Character] = nil
	SoundService.StopContinuous(session.SourceId)

	SoundService:StopContinuous("Movement.FallWind")

	CameraShake.SetContinuous("FastFall", 0)
end)

CombatEvents.FallImpact:Connect(function(firingPlayer: Player, peakFallSpeed: number, _damageApplied: number, _landingMaterial: Enum.Material)
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

	-- Athletic-Operator landing "jounce" — a real spring dip, separate from (and in
	-- addition to) the random-impulse CameraShake above.
	CameraMotion.OnLanding(peakFallSpeed)
end)

-- === Camera motion: feed real state every frame ==============================
CameraMotion.Start(function(): (number, number, number, boolean, boolean, Vector3)
	if not controller then
		return 0, 1, 0, false, false, Vector3.zero
	end
	local planarSpeed = controller:GetPlanarSpeed()
	local referenceSpeed = controller:GetReferenceSpeed()
	-- Issue 7: pull turn rate from CameraInertiaController's BodyYaw tracking (the exact
	-- signal that drives the visible facing) instead of controller:GetTurnRateDegPerSec()
	-- (Momentum's unrelated internal steering rate).
	
	local turnRate = if cameraInertia then cameraInertia:GetBodyTurnRateDegPerSec() else 0
	local isMoving = controller:IsMoving()
	local isSprinting = controller.CurrentStance == "TacticalSprint"
	local moveDirection = controller:GetMoveDirection()
	return planarSpeed, referenceSpeed, turnRate, isMoving, isSprinting, moveDirection
end)

-- === Main update loop =========================================================
RunService:BindToRenderStep("CombatFrameworkCameraInertia", Enum.RenderPriority.Camera.Value, function(dt)
	local wantFP = FirstPersonZoomController.IsEnabled()
	local camera = workspace.CurrentCamera

	if wantFP then
		if cameraInertia and not cameraInertia.Enabled then
			cameraInertia:Enable()
		end
		-- Force it back every frame regardless of what touched CameraType since —
		-- cheap, idempotent, and closes every "something reset it" case at once.
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
	else
		if cameraInertia and cameraInertia.Enabled then
			cameraInertia:Disable()
			FirstPersonZoomController.ApplyThirdPersonZoom()
		end
	end

	if cameraInertia and cameraInertia.Enabled then
		cameraInertia:Update(dt)
	end

	local char = player.Character
	if char then
		FirstPersonVisibility.Apply(char, cameraInertia ~= nil and cameraInertia.Enabled)
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	if not controller then
		return
	end

	local camera = workspace.CurrentCamera
	local moveDirection = if camera then inputController:GetWorldMoveDirection(camera) else Vector3.zero

	if cameraInertia and cameraInertia.Enabled and cameraInertia.Freelooking and moveDirection.Magnitude > 0.01 then
		local yawDelta = cameraInertia.BodyYaw - cameraInertia.Yaw
		moveDirection = CFrame.fromAxisAngle(Vector3.yAxis, yawDelta) * moveDirection
	end

	controller:Update(dt, moveDirection)

	-- Lean camera feel: smoothly lerp Humanoid.CameraOffset sideways based on LeanState.
	local targetOffset = Vector3.zero
	if controller.LeanState == "Left" then
		targetOffset = Vector3.new(-LEAN_OFFSET_STUDS * LocalBodyClearance.Lateral, 0, 0)
	elseif controller.LeanState == "Right" then
		targetOffset = Vector3.new(LEAN_OFFSET_STUDS * LocalBodyClearance.Lateral, 0, 0)
	end

	local alpha = math.clamp(LEAN_LERP_SPEED * dt, 0, 1)
	currentCameraOffset = currentCameraOffset:Lerp(targetOffset, alpha)
	if cameraInertia then
		cameraInertia:SetLeanOffset(currentCameraOffset)
	end
end)