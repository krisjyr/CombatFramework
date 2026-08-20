--!strict
--[[
	MomentumController.lua  (Ch 2 — real turning + pivot-on-reversal, v9)

	NEW THIS PASS — fixes the "u-turn on a 180" bug: the moderate-turn dip (previous pass)
	compares THIS frame's input direction to LAST frame's. A sudden S-press or an instant
	camera flip shows up as one big single-frame delta and gets caught fine — but a FAST
	(not instant) 180 mouse flick spreads the same total rotation across several frames,
	so each individual frame's delta can stay under the moderate-turn threshold even
	though the character's desired direction has completely reversed. That let it fall
	through to the smooth rate-limited facing rotation, which — because it's rate-limited
	— sweeps the body through a visible arc while still carrying speed. That sweep IS the
	u-turn.

	FIX: the pivot decision no longer looks at frame-to-frame input deltas at all. It
	compares the DESIRED input direction against the character's CURRENT FACING (which
	deliberately lags behind fast input) every frame. That deviation grows correctly
	whether the flip was instant (S key: facing vs. new input is 180 immediately) or fast
	but gradual (camera spin: facing lags further behind each frame until the deviation
	crosses the pivot threshold mid-spin) — so both cases are caught the same way.

	At/above PIVOT_ANGLE_DEG of facing-vs-input deviation: PIVOT. Facing stays LOCKED to
	the old heading (no rotation at all) while speed brakes hard toward near-zero via
	PIVOT_BRAKE_MULTIPLIER; the instant speed drops below PIVOT_RELEASE_SPEED, facing
	SNAPS to the (latest) desired direction and normal acceleration takes over on the very
	next Update(). Below that threshold: unchanged from the previous pass — smooth
	rate-limited facing rotation + the turn-slowdown speed-cap tween (based on
	previous-vs-new INPUT delta, which is the right signal for "how sharp was this
	specific frame's correction," separate from the pivot's "how far off is facing
	overall" signal).
]]

local Workspace = game:GetService("Workspace")

local MomentumController = {}
MomentumController.__index = MomentumController

export type MomentumControllerInstance = typeof(setmetatable(
	{} :: {
		RootPart: BasePart,
		Humanoid: Humanoid,
		Attachment: Attachment,
		VectorForce: VectorForce,
		_currentSpeed: number,
		_facingDirection: Vector3?,
		_previousInputDirection: Vector3?,
		_lastTurnRateDegPerSec: number,
		_turnSpeedCap: number,
		_turnSpeedCapTimer: number,
		_turnSpeedCapActive: boolean,
		_pivoting: boolean,
		_pivotTargetDirection: Vector3?,
	},
	MomentumController
))

local INPUT_MAGNITUDE_THRESHOLD = 0.05
local STOP_EPSILON = 0.05

-- Moderate-turn dip (unchanged from previous pass): frame-to-frame INPUT angle change
-- beyond this starts a smooth speed-cap tween, still using the normal rotate-toward
-- facing below.
local TURN_CUT_START_ANGLE_DEG = 25
local TURN_SLOWDOWN_HOLD_TIME = 0.2

-- Pivot (near-reversal) trigger: FACING-vs-DESIRED deviation at/above this triggers a
-- hard plant-and-pivot instead of a rotate-through-the-arc. Comfortably above the
-- moderate-turn threshold so ordinary sharp turns still get the smooth tween.
local PIVOT_ANGLE_DEG = 130
local PIVOT_RELEASE_SPEED = 1.0 -- studs/s; below this, the pivot completes and facing snaps
local PIVOT_BRAKE_MULTIPLIER = 3 -- brakes harder than a normal stop, for a crisp "plant"

local STUCK_GUARD_BUFFER = 5

local MAX_TURN_RATE_DEG_PER_SEC = 720
local MIN_TURN_RATE_DEG_PER_SEC = 240

function MomentumController.new(rootPart: BasePart, humanoid: Humanoid): MomentumControllerInstance
	local attachment = Instance.new("Attachment")
	attachment.Name = "CombatFrameworkGravityAttachment"
	attachment.Parent = rootPart

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "CombatFrameworkGravityOverrideForce"
	vectorForce.Attachment0 = attachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Force = Vector3.zero
	vectorForce.Enabled = true
	vectorForce.Parent = attachment

	humanoid.WalkSpeed = 0

	return setmetatable({
		RootPart = rootPart,
		Humanoid = humanoid,
		Attachment = attachment,
		VectorForce = vectorForce,
		_currentSpeed = 0,
		_facingDirection = nil,
		_previousInputDirection = nil,
		_lastTurnRateDegPerSec = 0,
		_turnSpeedCap = 0,
		_turnSpeedCapTimer = 0,
		_turnSpeedCapActive = false,
		_pivoting = false,
		_pivotTargetDirection = nil,
	}, MomentumController) :: any
end

function MomentumController.Update(
	self: MomentumControllerInstance,
	dt: number,
	moveDirection: Vector3,
	targetSpeed: number,
	acceleration: number,
	braking: number,
	turnCutStrength: number
)
	local hasInput = moveDirection.Magnitude > INPUT_MAGNITUDE_THRESHOLD
	local inputDirection: Vector3? = if hasInput then moveDirection.Unit else nil

	-- === Pivot detection: FACING vs DESIRED deviation, not frame-to-frame input delta ===
	local facingDeviationDeg = 0
	if hasInput and inputDirection and self._facingDirection then
		local dot = math.clamp((self._facingDirection :: Vector3):Dot(inputDirection :: Vector3), -1, 1)
		facingDeviationDeg = math.deg(math.acos(dot))
	end

	if hasInput and facingDeviationDeg >= PIVOT_ANGLE_DEG and not self._pivoting then
		self._pivoting = true
	end

	if self._pivoting then
		if not hasInput then
			-- Input released mid-pivot: fall through to the normal decel-to-stop path
			-- below instead of holding a pivot with nothing to release into.
			self._pivoting = false
			self._pivotTargetDirection = nil
		else
			-- Keep tracking the latest desired direction while braking, so releasing
			-- lands on wherever input currently points, not a stale snapshot from the
			-- moment the pivot started.
			self._pivotTargetDirection = inputDirection
		end
	end

	if self._pivoting then
		-- === PIVOT: brake hard, facing locked, no rotation/tween this frame ===
		local pivotBrakeRate = braking * PIVOT_BRAKE_MULTIPLIER
		local newSpeed = math.max(0, self._currentSpeed - pivotBrakeRate * dt)
		self._currentSpeed = newSpeed
		self.Humanoid.WalkSpeed = newSpeed

		if newSpeed <= PIVOT_RELEASE_SPEED then
			-- Braked down enough: snap facing straight to the new direction and release
			-- the pivot. Normal acceleration takes over starting next Update().
			self._facingDirection = self._pivotTargetDirection or self._facingDirection
			self._pivoting = false
			self._pivotTargetDirection = nil
		end

		if self._facingDirection then
			self.Humanoid:Move(self._facingDirection :: Vector3, false)
		end

		self._lastTurnRateDegPerSec = 0
		self._previousInputDirection = inputDirection
		return
	end

	-- === Speed: moderate turn slowdown (smooth tween, unchanged from previous pass) ===
	if hasInput and inputDirection and self._previousInputDirection and self._currentSpeed > STOP_EPSILON then
		local previousDirection = self._previousInputDirection :: Vector3
		local newDirection = inputDirection :: Vector3

		local dot = math.clamp(previousDirection:Dot(newDirection), -1, 1)
		local angleDeg = math.deg(math.acos(dot))

		if angleDeg > TURN_CUT_START_ANGLE_DEG then
			local angleSeverity = math.clamp(
				(angleDeg - TURN_CUT_START_ANGLE_DEG) / (180 - TURN_CUT_START_ANGLE_DEG),
				0,
				1
			)
			local speedFraction = if targetSpeed > 0.01 then math.clamp(self._currentSpeed / targetSpeed, 0, 1.25) else 1
			local cutAmount = math.clamp(angleSeverity * turnCutStrength * speedFraction, 0, 1)
			local newCap = self._currentSpeed * (1 - cutAmount)

			if not self._turnSpeedCapActive or newCap < self._turnSpeedCap then
				self._turnSpeedCap = newCap
			end
			self._turnSpeedCapTimer = TURN_SLOWDOWN_HOLD_TIME
			self._turnSpeedCapActive = true
		end
	end

	if self._turnSpeedCapActive then
		self._turnSpeedCapTimer -= dt
		if self._turnSpeedCapTimer <= 0 then
			self._turnSpeedCapActive = false
		end
	end

	-- === Speed: ramp toward target, OR decay to a stop on input loss ========
	local target = if hasInput then targetSpeed else 0
	if self._turnSpeedCapActive then
		target = math.min(target, self._turnSpeedCap)
	end

	local newSpeed = self._currentSpeed
	if newSpeed < target then
		newSpeed = math.min(target, newSpeed + acceleration * dt)
	elseif newSpeed > target then
		newSpeed = math.max(target, newSpeed - braking * dt)
	end

	if hasInput then
		local actualVelocity = self.RootPart.AssemblyLinearVelocity
		local actualSpeed = Vector3.new(actualVelocity.X, 0, actualVelocity.Z).Magnitude
		newSpeed = math.min(newSpeed, actualSpeed + STUCK_GUARD_BUFFER)
	end

	if newSpeed < STOP_EPSILON then
		newSpeed = 0
	end

	self._currentSpeed = newSpeed
	self.Humanoid.WalkSpeed = newSpeed

	-- === Facing: rate-limited rotation toward input direction (moderate turns only) ===
	if hasInput and inputDirection then
		local desired = inputDirection :: Vector3
		local previousFacing = self._facingDirection

		if not previousFacing then
			self._facingDirection = desired
			self._lastTurnRateDegPerSec = 0
		else
			local currentFacing = previousFacing :: Vector3
			local speedFraction = if targetSpeed > 0.01 then math.clamp(newSpeed / targetSpeed, 0, 1) else 0
			local turnRateDegPerSec = MAX_TURN_RATE_DEG_PER_SEC
				- (MAX_TURN_RATE_DEG_PER_SEC - MIN_TURN_RATE_DEG_PER_SEC) * speedFraction
			local maxTurnThisFrame = math.rad(turnRateDegPerSec) * dt

			local facingDot = math.clamp(currentFacing:Dot(desired), -1, 1)
			local angleBetween = math.acos(facingDot)

			local appliedAngle: number
			local turnSign: number

			if angleBetween <= maxTurnThisFrame or angleBetween < 1e-4 then
				self._facingDirection = desired
				appliedAngle = angleBetween
				local cross = currentFacing:Cross(desired)
				turnSign = if cross.Y >= 0 then 1 else -1
			else
				local cross = currentFacing:Cross(desired)
				turnSign = if cross.Y >= 0 then 1 else -1
				local rotation = CFrame.fromAxisAngle(Vector3.yAxis, maxTurnThisFrame * turnSign)
				self._facingDirection = (rotation * currentFacing).Unit
				appliedAngle = maxTurnThisFrame
			end

			self._lastTurnRateDegPerSec = if dt > 0 then (math.deg(appliedAngle) / dt) * turnSign else 0
		end

		self.Humanoid:Move(self._facingDirection :: Vector3, false)
	else
		self._lastTurnRateDegPerSec = 0
	end

	self._previousInputDirection = inputDirection
end

function MomentumController.GetTurnRateDegPerSec(self: MomentumControllerInstance): number
	return self._lastTurnRateDegPerSec
end

function MomentumController.GetCurrentSpeed(self: MomentumControllerInstance): number
	return self._currentSpeed
end

function MomentumController.SetGravity(self: MomentumControllerInstance, gravityVector: Vector3)
	local mass = self.RootPart.AssemblyMass
	local desiredAccelY = gravityVector.Y
	local engineAccelY = -Workspace.Gravity
	self.VectorForce.Force = Vector3.new(0, (desiredAccelY - engineAccelY) * mass, 0)
end

function MomentumController.SetEnabled(self: MomentumControllerInstance, enabled: boolean)
	self.VectorForce.Enabled = enabled
end



function MomentumController.Destroy(self: MomentumControllerInstance)
	self.Attachment:Destroy()
end

return MomentumController