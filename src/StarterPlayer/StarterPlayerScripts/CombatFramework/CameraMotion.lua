--!strict
--[[
	CameraMotion.lua  (client-only, Ch 2.9 Camera)

	Athletic-Operator / freerunning first-person camera feel, layered on top of the
	default camera exactly like CameraShake.lua (binds at RenderPriority.Camera + 1,
	non-destructive additive offset). Three components, all driven by real movement state
	from CharacterController — nothing here is guessed, it all reads actual speed/turn
	data:

	  - HEAD BOB: vertical + lateral sway synced to a gait cycle whose frequency AND
	    amplitude scale with current speed fraction (planarSpeed / referenceSpeed). Zero
	    while stopped or airborne — only bobs while actually grounded and moving.
	  - TURN LEAN: camera rolls a few degrees into the turn, proportional to
	    CharacterController:GetTurnRateDegPerSec() (which MomentumController now reports
	    correctly since it owns the only Move() call). Banking into a turn, not just
	    the character below turning.
	  - SPRINT LEAN: a small forward pitch while TacticalSprint is active, purely a "you
	    are moving with intent" cue — subtle by design, tune/remove via SPRINT_LEAN_DEG.
	  - LANDING JOUNCE: a critically-damped vertical spring, kicked by CombatEvents.
	    FallImpact, so landing has real physical "give" instead of just the existing
	    one-shot CameraShake impulse.
]]

local RunService = game:GetService("RunService")

local FirstPersonZoomController = require(script.Parent.FirstPersonZoomController)
local CameraEffects = require(game.ReplicatedStorage.CombatFramework.Shared.Config.CameraEffects)

local CameraMotion = {}

-- === Head bob ==============================================================
local BOB_FREQUENCY_MIN = 0.6
local BOB_FREQUENCY_MAX = 2.1

local BOB_VERTICAL = 0.045
local BOB_HORIZONTAL = 0.03
local BOB_FORWARD = 0.02

local SPRINT_BOB_MULTIPLIER = 2.5

-- rotational movement (degrees)
local BOB_ROLL_DEG = 0.4
local BOB_PITCH_DEG = 0.15

local BOB_FADE_RATE = 10 -- how fast bob amplitude ramps in/out with movement state

-- === Turn lean (roll) =======================================================
local TURN_LEAN_MAX_DEG = 12 -- degrees of roll at/above TURN_LEAN_REFERENCE_DEG_PER_SEC
local TURN_LEAN_REFERENCE_DEG_PER_SEC = 260
local TURN_LEAN_SMOOTHING = 8

local TURN_LEAN_DEADZONE_DEG_PER_SEC = 4 -- below this, treat raw turn rate as exactly 0
local TURN_LEAN_RAW_SLEW_DEG_PER_SEC_SQ = 4000 -- max allowed change in the RAW signal per second;
	-- clips single-frame spikes/sign-flip noise without adding perceptible lag to real turns
	-- (MomentumController's own turn-rate cap already changes gradually)

local STRAFE_LEAN_MAX_DEG = 8 -- degrees of roll at full strafe input

-- === Landing jounce (critically damped spring) ==============================
local LANDING_SPRING_STIFFNESS = 220
local LANDING_SPRING_DAMPING = 24
local LANDING_IMPULSE_PER_STUD_PER_SEC = 0.012 -- how much peakFallSpeed converts to dip depth
local LANDING_IMPULSE_MAX = 1.4

local _gaitPhase = 0
local _bobAmplitudeScale = 0 -- smoothed 0..1, fades in/out with IsMoving()/grounded state
local _turnLeanCurrent = 0
local _landingOffset = 0
local _landingVelocity = 0

local _smoothedRawTurnRate = 0 -- slew-limited, deadzoned version of the raw input signal

local _cameraOffset = Vector3.zero
local _cameraVelocity = Vector3.zero

local CAMERA_STIFFNESS = 120
local CAMERA_DAMPING = 20
local MAX_DT = 1 / 20

local _getState: (() -> (number, number, number, boolean, boolean, Vector3))? = nil

--- `getState` must return: planarSpeed, referenceSpeed, turnRateDegPerSec, isMoving,
--- isSprinting, moveDirection — CameraMotion never reaches into CharacterController directly, it just
--- asks for these five numbers/bools each frame.
function CameraMotion.Start(getState: () -> (number, number, number, boolean, boolean, Vector3))
	_getState = getState
end

--- Call from CombatEvents.FallImpact — kicks the landing spring proportional to how hard
--- the landing was.
function CameraMotion.OnLanding(peakFallSpeed: number)
	local toggles = if FirstPersonZoomController.IsEnabled() then CameraEffects.FirstPerson else CameraEffects.ThirdPerson
	if not toggles.LandingSpring then
		return
	end
	local impulse = math.min(peakFallSpeed * LANDING_IMPULSE_PER_STUD_PER_SEC, LANDING_IMPULSE_MAX)
	_landingVelocity -= impulse
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera or not _getState then
		return
	end

	dt = math.min(dt, MAX_DT)

	local toggles = if FirstPersonZoomController.IsEnabled() then CameraEffects.FirstPerson else CameraEffects.ThirdPerson

    local baseCFrame = camera.CFrame

	local planarSpeed, referenceSpeed, turnRateDegPerSec, isMoving, isSprinting, moveDirection = _getState()

	local speedFraction =
		if referenceSpeed > 0.01 then
			math.clamp(planarSpeed / referenceSpeed, 0, 1)
		else
			0


	--------------------------------------------------
	-- HEAD BOB
	--------------------------------------------------

	-- Gated by toggles.HeadBob: disabling just targets a bob scale of 0, which
	-- _bobAmplitudeScale already eases toward via the exact same BOB_FADE_RATE path it
	-- uses when IsMoving() goes false -- so toggling never pops, it eases out same as
	-- stopping would.
	local targetBobScale = if isMoving and toggles.HeadBob then 1 else 0

	_bobAmplitudeScale +=
		(targetBobScale - _bobAmplitudeScale)
		* math.clamp(BOB_FADE_RATE * dt, 0, 1)


    local gaitSpeed =
        math.pow(speedFraction, 0.5)

    local frequency =
        BOB_FREQUENCY_MIN
        +
        (BOB_FREQUENCY_MAX - BOB_FREQUENCY_MIN)
        * gaitSpeed


	_gaitPhase += frequency * dt * math.pi * 2


	if _gaitPhase > math.pi * 2 then
		_gaitPhase -= math.pi * 2
	end


	local s = math.sin(_gaitPhase)
	local c = math.cos(_gaitPhase)


    local bobScale =
        math.pow(speedFraction,2)
        *
        _bobAmplitudeScale

    if isSprinting then
        bobScale *= SPRINT_BOB_MULTIPLIER
    end


	local verticalBob =
		s
		* BOB_VERTICAL
		* bobScale


	local lateralBob =
		math.sin(_gaitPhase * 0.5)
		* BOB_HORIZONTAL
		* bobScale


	local forwardBob =
		c
		* BOB_FORWARD
		* bobScale


	local gaitPitch =
		-c
		* BOB_PITCH_DEG
		* bobScale


	local gaitRoll =
		s
		* BOB_ROLL_DEG
		* bobScale



	--------------------------------------------------
	-- MOVEMENT INERTIA (a.k.a. strafe lean — the effect this pass makes toggleable)
	--------------------------------------------------

	-- Yaw-only basis: camera.CFrame carries pitch (aim angle) and roll (rig-driven lean
	-- tilt) which would otherwise warp this lateral offset based on how far you're
	-- aiming up/down or how far the rig has leaned. Flattened to yaw only.
	local camLook = camera.CFrame.LookVector
	local flatForward = Vector3.new(camLook.X, 0, camLook.Z)
	if flatForward.Magnitude < 1e-3 then
		local camRight = camera.CFrame.RightVector
		flatForward = Vector3.new(camRight.Z, 0, -camRight.X)
	end
	flatForward = flatForward.Unit
	local flatCFrame = CFrame.lookAt(Vector3.zero, flatForward)

	local localMove =
		flatCFrame:VectorToObjectSpace(moveDirection)


	-- Gated by toggles.MovementInertia: OFF -> target is Vector3.zero, so the existing
	-- critically-damped spring below relaxes the offset back to rest smoothly instead of
	-- snapping it away -- same mechanism as any other transient input dropping to zero.
	local desiredOffset =
		if toggles.MovementInertia then
			Vector3.new(
				-localMove.X,
				0,
				-localMove.Z
			)
			*
			0.02
			*
			speedFraction
		else
			Vector3.zero


	local accel =
		(desiredOffset - _cameraOffset)
		*
		CAMERA_STIFFNESS
		-
		_cameraVelocity
		*
		CAMERA_DAMPING


	_cameraVelocity += accel * dt
	_cameraOffset += _cameraVelocity * dt



	--------------------------------------------------
	-- TURN LEAN
	--------------------------------------------------

	-- Gated by toggles.TurnLean: OFF -> deadzoned raw input forced to 0, so
	-- _smoothedRawTurnRate (and therefore _turnLeanCurrent) eases back to 0 through its
	-- normal slew/smoothing path rather than popping.
	local deadzonedRawTurnRate =
		if not toggles.TurnLean then 0
		elseif math.abs(turnRateDegPerSec) < TURN_LEAN_DEADZONE_DEG_PER_SEC then 0
		else turnRateDegPerSec

	local maxRawStep = TURN_LEAN_RAW_SLEW_DEG_PER_SEC_SQ * dt
	if deadzonedRawTurnRate > _smoothedRawTurnRate then
		_smoothedRawTurnRate = math.min(deadzonedRawTurnRate, _smoothedRawTurnRate + maxRawStep)
	else
		_smoothedRawTurnRate = math.max(deadzonedRawTurnRate, _smoothedRawTurnRate - maxRawStep)
	end

	local turnLeanTarget = math.clamp(_smoothedRawTurnRate / TURN_LEAN_REFERENCE_DEG_PER_SEC, -1, 1) * TURN_LEAN_MAX_DEG

	_turnLeanCurrent +=
		(turnLeanTarget - _turnLeanCurrent)
		* math.clamp(TURN_LEAN_SMOOTHING * dt, 0, 1)

	--------------------------------------------------
	-- STRAFE LEAN (roll, part of TurnLean toggle -- always paired with turn roll)
	--------------------------------------------------

	local strafeRoll =
		if toggles.TurnLean then
			localMove.X
			*
			STRAFE_LEAN_MAX_DEG
			*
			speedFraction
		else
			0



	--------------------------------------------------
	-- SPRINT
	--------------------------------------------------

	local sprintForward =
		if isSprinting and toggles.SprintLean
		then -0.02
		else 0


	--------------------------------------------------
	-- LANDING SPRING
	--------------------------------------------------

	-- No separate gate needed here: OnLanding() above already refuses to kick the spring
	-- when LandingSpring is off, so _landingOffset/_landingVelocity simply never leave
	-- rest in that mode. This block just keeps integrating whatever's already there.
	local springForce =
		-
		LANDING_SPRING_STIFFNESS
		*
		_landingOffset
		-
		LANDING_SPRING_DAMPING
		*
		_landingVelocity


	_landingVelocity += springForce * dt
	_landingOffset += _landingVelocity * dt



	--------------------------------------------------
	-- FINAL OUTPUT
	--------------------------------------------------

	local position =
		Vector3.new(
			lateralBob,
			verticalBob + _landingOffset,
			forwardBob + sprintForward
		)
		+
		_cameraOffset


	local pitch =
		gaitPitch


	local roll =
		-
		_turnLeanCurrent
		+
		strafeRoll
		+
		gaitRoll



    camera.CFrame =
        baseCFrame
        *
        CFrame.new(position)
        *
        CFrame.Angles(
            math.rad(pitch),
            0,
            math.rad(roll)
        )
end

RunService:BindToRenderStep("CombatFrameworkCameraMotion", Enum.RenderPriority.Camera.Value + 1, update)

return CameraMotion