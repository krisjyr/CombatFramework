--!strict
--[[
	SlopeController.lua  (Ch 2 Character Controller — momentum extension)

	--------------------------------------------------------------------------------
	REDESIGNED (again): the previous dual-raycast version (near foot + one point ahead)
	correctly caught continuous ramps and averaged stairs reasonably, but a single 2-point
	reading has no way to tell "one real staircase" apart from "one random pebble/curb that
	happens to sit under the far sample point" — both just look like one height delta over
	one distance.

	Fixed with MULTI-POINT SAMPLING + MEDIAN: cast SAMPLE_COUNT rays evenly spaced along the
	movement direction, compute the height CHANGE across each consecutive segment (so a
	5-stud reach becomes 5 one-stud segments), then take the MEDIAN segment angle rather
	than the average or the raw endpoint-to-endpoint delta.

	This is what gives the two behaviors asked for, for free, from the same mechanism:
	  - A small isolated bump/part/curb only disturbs ONE (or two) of the segments; the
	    median discards the top and bottom outliers, so an isolated bump barely moves the
	    result — "wouldn't really slow at all," exactly as intended.
	  - A real staircase — even one physically built from a bunch of small individual
	    part-risers — produces a SIMILAR height delta across every segment, so the median
	    correctly reflects that consistent incline and the speed/momentum penalty applies,
	    same as it would for a continuous ramp of the same overall angle.

	SYMMETRIC PENALTY: both uphill and downhill slow the character down (by the same curve,
	driven by |angle| only) — a person doesn't want to speed up and risk falling over going
	down a slope or a staircase either.

	MOMENTUM, not just top speed: Update(dt) returns two multipliers:
	  - speedMultiplier    -> pushed onto the ModifierStack same as before (caps top speed)
	  - momentumMultiplier -> read by CharacterController and applied to the profile's
	                          Acceleration/Deceleration themselves (via MomentumController),
	                          so climbing/descending an incline also makes the character
	                          feel less nimble, not just slower at top speed.
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

local RAY_LENGTH = 6
local SAMPLE_COUNT = 6 -- 5 segments; odd segment count gives a single clean median value
local TOTAL_SAMPLE_DISTANCE = 5 -- studs; ~1 stud per segment, matching typical stair tread depth
local SEGMENT_LENGTH = TOTAL_SAMPLE_DISTANCE / (SAMPLE_COUNT - 1)

local FLAT_ANGLE_DEADZONE = 2 -- degrees; only filters genuine floating-point/geometry noise
local MAX_WALKABLE_ANGLE = 50 -- degrees; a typical Roblox staircase averages ~30-35 here

local MIN_SPEED_MULTIPLIER = 0.55 -- top-speed multiplier at MAX_WALKABLE_ANGLE, either direction
local MIN_MOMENTUM_MULTIPLIER = 0.6 -- Acceleration/Deceleration multiplier at MAX_WALKABLE_ANGLE, either direction

local SMOOTHING_RATE = 6 -- higher = snappier reaction, lower = smoother

function SlopeController.new(rootPart: BasePart, humanoid: Humanoid): SlopeControllerInstance
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rootPart.Parent :: Instance }
	params.IgnoreWater = true

	return setmetatable({
		RootPart = rootPart,
		Humanoid = humanoid,
		_raycastParams = params,
		_smoothedSpeedMultiplier = 1.0,
		_smoothedMomentumMultiplier = 1.0,
	}, SlopeController) :: any
end

--- Casts SAMPLE_COUNT evenly spaced rays along `horizontalDir` starting at the character's
--- position, returning each hit's Y position. Returns nil (rather than a partial list) if
--- ANY sample misses — e.g. right at the edge of a platform — since a partial reading isn't
--- trustworthy enough to compute a fair median from.
function SlopeController._sampleHeights(self: SlopeControllerInstance, horizontalDir: Vector3): { number }?
	local origin = self.RootPart.Position
	local heights = table.create(SAMPLE_COUNT)

	for i = 0, SAMPLE_COUNT - 1 do
		local samplePoint = origin + horizontalDir * (i * SEGMENT_LENGTH)
		local hit = Workspace:Raycast(samplePoint, Vector3.new(0, -RAY_LENGTH, 0), self._raycastParams)
		if not hit then
			return nil
		end
		table.insert(heights, hit.Position.Y)
	end

	return heights
end

--- Returns the MEDIAN signed segment angle in degrees (positive = net uphill ahead,
--- negative = net downhill ahead) across all consecutive sample pairs, or nil if there's no
--- movement input to sample along or any raycast in the chain missed.
function SlopeController._estimateSignedSlopeAngle(self: SlopeControllerInstance): number?
	local moveDirection = self.Humanoid.MoveDirection
	local horizontal = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if horizontal.Magnitude < 0.05 then
		return nil
	end
	horizontal = horizontal.Unit

	local heights = self:_sampleHeights(horizontal)
	if not heights then
		return nil
	end

	local segmentAngles = table.create(#heights - 1)
	for i = 1, #heights - 1 do
		local rise = heights[i + 1] - heights[i]
		table.insert(segmentAngles, math.deg(math.atan2(rise, SEGMENT_LENGTH)))
	end

	table.sort(segmentAngles)
	local n = #segmentAngles
	if n == 0 then
		return nil
	end

	local medianAngle: number
	if n % 2 == 1 then
		medianAngle = segmentAngles[(n + 1) // 2]
	else
		medianAngle = (segmentAngles[n // 2] + segmentAngles[n // 2 + 1]) / 2
	end

	return medianAngle
end

--- Returns (speedMultiplier, momentumMultiplier), both smoothed frame-to-frame. Call once
--- per Update(dt).
function SlopeController.Update(self: SlopeControllerInstance, dt: number): (number, number)
	local targetSpeedMultiplier = 1.0
	local targetMomentumMultiplier = 1.0

	local signedAngle = self:_estimateSignedSlopeAngle()
	if signedAngle then
		local magnitude = math.abs(signedAngle)
		if magnitude > FLAT_ANGLE_DEADZONE then
			local t = math.clamp(magnitude / MAX_WALKABLE_ANGLE, 0, 1)
			-- Symmetric: uphill and downhill both slow you down by the same curve.
			targetSpeedMultiplier = 1.0 - (1.0 - MIN_SPEED_MULTIPLIER) * t
			targetMomentumMultiplier = 1.0 - (1.0 - MIN_MOMENTUM_MULTIPLIER) * t
		end
	end

	local alpha = math.clamp(SMOOTHING_RATE * dt, 0, 1)
	self._smoothedSpeedMultiplier += (targetSpeedMultiplier - self._smoothedSpeedMultiplier) * alpha
	self._smoothedMomentumMultiplier += (targetMomentumMultiplier - self._smoothedMomentumMultiplier) * alpha

	return self._smoothedSpeedMultiplier, self._smoothedMomentumMultiplier
end

return SlopeController
