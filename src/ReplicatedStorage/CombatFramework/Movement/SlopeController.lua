--!strict
--[[
	SlopeController.lua
	Ch 2 Character Controller — Local Ground Slope

	--------------------------------------------------------------------------------
	Two-ray slope detection:

	  Ray 1: directly below the character
	  Ray 2: a short distance ahead in the movement direction

	Both rays cast straight down.

	The two hit positions describe the local ground/traversal vector:

		     ● ahead ground
		    /
		   /  <- measured slope vector
		  /
		● current ground
		 ───────────────>
		  horizontal reference

	The angle between that ground vector and the horizontal movement direction is
	the local slope angle.

	Positive angle = uphill
	Negative angle = downhill

	The magnitude of the angle is used for both speed and momentum penalties, so
	uphill and downhill traversal are slowed symmetrically.

	The result is smoothed frame-to-frame to prevent stair steps from causing
	rapid speed oscillation.
	--------------------------------------------------------------------------------
]]

local Workspace = game:GetService("Workspace")

local SlopeController = {}
SlopeController.__index = SlopeController

export type SlopeControllerInstance = typeof(setmetatable(
	{} :: {
		RootPart: BasePart,
		Humanoid: Humanoid,
		_raycastParams: RaycastParams,
		_smoothedSpeedMultiplier: number,
		_smoothedMomentumMultiplier: number,
	},
	SlopeController
))

-- How far ahead the second ground sample is.
local LOOK_AHEAD_DISTANCE = 1.1

-- Both rays start from the character/root and travel downward.
local RAY_LENGTH = 6

-- Ignore tiny surface/physics noise.
local FLAT_ANGLE_DEADZONE = 2 -- degrees

-- Angle at which the maximum configured penalty is reached.
local MAX_SLOPE_ANGLE = 50 -- degrees

-- Minimum multipliers at MAX_SLOPE_ANGLE.
local MIN_SPEED_MULTIPLIER = 0.55
local MIN_MOMENTUM_MULTIPLIER = 0.60

-- Smoothing of the detected slope.
local SMOOTHING_RATE = 8

function SlopeController.new(
	rootPart: BasePart,
	humanoid: Humanoid
): SlopeControllerInstance

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		rootPart.Parent :: Instance,
	}
	params.IgnoreWater = true

	return setmetatable({
		RootPart = rootPart,
		Humanoid = humanoid,
		_raycastParams = params,

		_smoothedSpeedMultiplier = 1,
		_smoothedMomentumMultiplier = 1,
	}, SlopeController) :: any
end

--- Returns the current movement direction projected onto the XZ plane.
function SlopeController._getHorizontalMoveDirection(
	self: SlopeControllerInstance
): Vector3?

	local moveDirection = self.Humanoid.MoveDirection

	local horizontal = Vector3.new(
		moveDirection.X,
		0,
		moveDirection.Z
	)

	if horizontal.Magnitude < 0.05 then
		return nil
	end

	return horizontal.Unit
end

local wireframe = Instance.new("WireframeHandleAdornment")
wireframe.Parent = Workspace
wireframe.Adornee = Workspace
wireframe.AlwaysOnTop = true
wireframe.Color3 = Color3.fromRGB(255, 255, 255) -- Default color fallback
wireframe.AdornCullingMode = Enum.AdornCullingMode.Never -- Ensure it stays visib
	
	-- Draw a straight line from start to end

--- Casts the two downward ground probes.
function SlopeController._sampleGround(
	self: SlopeControllerInstance,
	horizontalDirection: Vector3
): (Vector3, Vector3?)



	local origin = self.RootPart.Position

	-- Current ground sample.
	local currentHit = Workspace:Raycast(
		origin,
		Vector3.new(0, -RAY_LENGTH, 0),
		self._raycastParams
	)

	if not currentHit then
		return nil
	end

	wireframe:Clear()

	wireframe:AddLine(origin, currentHit.Position, Color3.fromRGB(255, 255, 255)) -- Green line for current ground hit

	-- Ground sample ahead of the character.
	local aheadOrigin = origin + horizontalDirection * LOOK_AHEAD_DISTANCE

	local aheadHit = Workspace:Raycast(
		aheadOrigin,
		Vector3.new(0, -RAY_LENGTH, 0),
		self._raycastParams
	)

	if not aheadHit then
		return nil
	end

	wireframe:AddLine(aheadOrigin, aheadHit.Position, Color3.fromRGB(255, 255, 255)) -- Red line for ahead ground hit

	return currentHit.Position, aheadHit.Position
end

--- Calculates the signed local ground slope in degrees.
---
--- Positive = uphill
--- Negative = downhill
function SlopeController._estimateSignedSlopeAngle(
	self: SlopeControllerInstance
): number?

	local horizontalDirection = self:_getHorizontalMoveDirection()

	if not horizontalDirection then
		return nil
	end

	local currentGround, aheadGround = self:_sampleGround(horizontalDirection)

	if not currentGround or not aheadGround then
		return nil
	end

	-- Difference between the two actual ground hit positions.
	local groundDelta = aheadGround - currentGround

	-- Only the horizontal distance matters for the run.
	local horizontalDelta = Vector3.new(
		groundDelta.X,
		0,
		groundDelta.Z
	)

	local run = horizontalDelta.Magnitude

	if run < 0.001 then
		return nil
	end

	-- Vertical difference between current ground and upcoming ground.
	local rise = groundDelta.Y

	-- atan2 gives the signed terrain angle relative to horizontal.
	local angle = math.deg(math.atan2(rise, run))

	wireframe:AddLine(currentGround, (aheadGround+((aheadGround - currentGround).unit * 2)), Color3.fromRGB(255, 255, 255)) -- Blue line for slope vector

	return angle
end

--- Returns:
---   speedMultiplier
---   momentumMultiplier
---
--- Both are smoothed frame-to-frame.
function SlopeController.Update(
	self: SlopeControllerInstance,
	dt: number
): (number, number)

	local targetSpeedMultiplier = 1
	local targetMomentumMultiplier = 1

	local signedAngle = self:_estimateSignedSlopeAngle()

	if signedAngle then
		local magnitude = math.abs(signedAngle)

		if magnitude > FLAT_ANGLE_DEADZONE then
			local t = math.clamp(
				magnitude / MAX_SLOPE_ANGLE,
				0,
				1
			)

			-- Same penalty uphill and downhill.
			targetSpeedMultiplier =
				1 - (1 - MIN_SPEED_MULTIPLIER) * t

			targetMomentumMultiplier =
				1 - (1 - MIN_MOMENTUM_MULTIPLIER) * t
		end
	end

	-- Smooth the response so stairs do not cause:
	--
	-- 1.0 -> 0.7 -> 1.0 -> 0.7 -> 1.0
	--
	-- Instead the multiplier transitions naturally.
	local alpha = math.clamp(
		SMOOTHING_RATE * dt,
		0,
		1
	)

	self._smoothedSpeedMultiplier +=
		(targetSpeedMultiplier - self._smoothedSpeedMultiplier) * alpha

	self._smoothedMomentumMultiplier +=
		(targetMomentumMultiplier - self._smoothedMomentumMultiplier) * alpha

	return
		self._smoothedSpeedMultiplier,
		self._smoothedMomentumMultiplier
end

return SlopeController