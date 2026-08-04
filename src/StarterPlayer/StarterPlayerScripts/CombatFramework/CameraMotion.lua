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
local TURN_LEAN_MAX_DEG = 8 -- degrees of roll at/above TURN_LEAN_REFERENCE_DEG_PER_SEC
local TURN_LEAN_REFERENCE_DEG_PER_SEC = 260
local TURN_LEAN_SMOOTHING = 8

local STRAFE_LEAN_MAX_DEG = 0.3 -- degrees of roll at full strafe input

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

local _cameraOffset = Vector3.zero
local _cameraVelocity = Vector3.zero

local CAMERA_STIFFNESS = 120
local CAMERA_DAMPING = 20

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
	local impulse = math.min(peakFallSpeed * LANDING_IMPULSE_PER_STUD_PER_SEC, LANDING_IMPULSE_MAX)
	_landingVelocity -= impulse
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera or not _getState then
		return
	end

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

	local targetBobScale = if isMoving then 1 else 0

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
	-- MOVEMENT INERTIA
	--------------------------------------------------

	local localMove =
		camera.CFrame:VectorToObjectSpace(moveDirection)


	local desiredOffset =
		Vector3.new(
			-localMove.X,
			0,
			-localMove.Z
		)
		*
		0.02
		*
		speedFraction


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

	local turnLeanTarget =
		math.clamp(
			turnRateDegPerSec / TURN_LEAN_REFERENCE_DEG_PER_SEC,
			-1,
			1
		)
		*
		TURN_LEAN_MAX_DEG


	_turnLeanCurrent +=
		(turnLeanTarget - _turnLeanCurrent)
		*
		math.clamp(TURN_LEAN_SMOOTHING * dt,0,1)

	--------------------------------------------------
	-- STRAFE LEAN
	--------------------------------------------------

	local strafeRoll =
		localMove.X
		*
		STRAFE_LEAN_MAX_DEG
		*
		speedFraction



	--------------------------------------------------
	-- SPRINT
	--------------------------------------------------

	local sprintForward =
		if isSprinting
		then -0.02
		else 0


	--------------------------------------------------
	-- LANDING SPRING
	--------------------------------------------------

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