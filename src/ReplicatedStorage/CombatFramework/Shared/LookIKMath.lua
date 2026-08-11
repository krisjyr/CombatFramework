--!strict
--[[
	LookIKMath.lua

	Shared yaw/pitch math for the look/lean body-posing system (Head/Neck in
	IKLegController.lua, Waist/Root in TorsoTiltController.lua) so all three joints agree
	on sign conventions, the BehindDisengage fold, AND how to handle the vertical-look
	singularity below.

	REVERSAL, NOT DISENGAGE: past LookIKTuning.Look.BehindDisengageDegrees off
	body-forward, tracked yaw REVERSES back toward center instead of growing further or
	falling back to a hardcoded neutral pose (see FoldYawDegrees).

	GIMBAL-LOCK / SINGULARITY AT THE POLES: yaw is derived from the HORIZONTAL (X/Z)
	component of the look direction. When the look direction points (near) straight up or
	down, that horizontal component shrinks toward (0, 0) and `atan2(x, z)` becomes
	undefined in practice -- both inputs are dominated by floating-point noise, so the
	reported yaw can swing wildly frame to frame even though the actual look direction
	barely changed. SignedYawPitchDegrees reports this via the third return value,
	`yawReliable` -- callers MUST hold their last known-good yaw whenever it comes back
	false, rather than consuming the noisy value. This is what previously made torso/head
	yaw "stop functioning" (in practice: jitter unpredictably) while looking straight up
	or down.
]]

local LookIKMath = {}

-- Minimum horizontal (X/Z) magnitude of the look direction, in the origin's local space,
-- before yaw is trusted at all. Below this the look direction is close enough to the
-- vertical pole that atan2 is numerically unstable. ~0.02 corresponds to roughly 1 degree
-- of tilt off dead vertical.
local YAW_SINGULARITY_THRESHOLD = 0.02

--- Signed yaw/pitch of `worldLookDirection` relative to `originCFrame`'s forward, in
--- degrees, PLUS whether yaw is numerically trustworthy this call. Pass yaw through
--- FoldYawDegrees (only when yawReliable) if reversal behavior is wanted -- pitch is
--- never folded and is NOT subject to the same singularity (it stays smooth all the way
--- to +-90 since it's driven by the Y component, which dominates exactly where yaw
--- breaks down).
function LookIKMath.SignedYawPitchDegrees(originCFrame: CFrame, worldLookDirection: Vector3): (number, number, boolean)
	local relative = originCFrame:VectorToObjectSpace(worldLookDirection.Unit)
	local forwardAmount = -relative.Z
	local xComponent = -relative.X

	local horizontalMagnitude = math.sqrt(xComponent * xComponent + forwardAmount * forwardAmount)
	local yawReliable = horizontalMagnitude > YAW_SINGULARITY_THRESHOLD

	local safeHorizontalDist = math.max(horizontalMagnitude, 1e-4)
	local yaw = math.deg(math.atan2(xComponent, forwardAmount))
	local pitch = math.deg(math.atan2(relative.Y, safeHorizontalDist))

	return yaw, pitch, yawReliable
end

--- Folds a signed yaw delta (degrees) around `disengageDegrees`: magnitude increases
--- 0 -> disengageDegrees as normal, then REVERSES back down to 0 as the look direction
--- keeps rotating toward directly behind (180 degrees). Sign (which side) is always
--- preserved. Only call this with a yaw value you already know is reliable.
function LookIKMath.FoldYawDegrees(signedYawDegrees: number, disengageDegrees: number): number
	if disengageDegrees <= 0 then
		return 0
	end
	local sign = if signedYawDegrees < 0 then -1 else 1
	local magnitude = math.abs(signedYawDegrees)
	local period = disengageDegrees * 2
	local m = magnitude % period
	local folded = if m <= disengageDegrees then m else period - m
	return sign * folded
end

--- Reconstructs a world-space direction from a yaw/pitch pair (degrees) relative to
--- `originCFrame`'s forward. Callers clamp yaw/pitch to their own joint limits BEFORE
--- calling this -- this function does no clamping itself.
function LookIKMath.DirectionFromYawPitch(originCFrame: CFrame, yawDegrees: number, pitchDegrees: number): Vector3
	local local2 = (CFrame.Angles(0, math.rad(yawDegrees), 0) * CFrame.Angles(math.rad(pitchDegrees), 0, 0)) * Vector3.new(0, 0, -1)
	return originCFrame:VectorToWorldSpace(local2).Unit
end

return LookIKMath