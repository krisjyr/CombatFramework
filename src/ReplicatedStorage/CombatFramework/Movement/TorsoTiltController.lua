--!strict
--[[
	TorsoTiltController.lua  (Ch 2.9 Camera / Ch 9 Animation Framework extension)

	"Body should be able to rotate/tilt 15 degrees left/right while standing before legs
	start moving to rotate the body more (unless moving)."

	SCOPE: this module owns ONE thing -- a cosmetic Waist Motor6D twist (±15°) so the
	upper body visually leans toward the camera's look direction while the character is
	idle, without needing the root/legs to actually turn for small look adjustments. It
	deliberately does NOT touch HumanoidRootPart's facing/rotation itself -- root/camera
	locking is a separate, pre-existing concern (typically owned by whatever first-person
	camera controller sets character facing) that this module has no visibility into here.

	Instead, once the raw look delta exceeds MAX_TILT_DEGREES, the twist simply clamps at
	the max (the torso stops following further) and GetRawLookDelta() exposes the
	UNCLAMPED value so a root-facing/turn-in-place system can watch it and decide "this
	has exceeded the tilt budget, time to actually turn the body" -- that decision and the
	resulting root rotation belongs to that system, not this one.

	Only meaningful for the LOCAL player today (it reads workspace.CurrentCamera, which
	only exists for the viewing client). For remote players this smoothly resets the Waist
	to neutral and does nothing else -- a future pass could replicate a compressed look-yaw
	as a Low-priority cosmetic (Ch 1.4 "cosmetics... inspect animations" tier) if seeing
	other players' idle look-around becomes a requirement.

	Disabled (decays to neutral) while: moving, or in a non-idle stance (TacticalSprint,
	Mounted, Swimming, Climbing, Jumping) -- exactly the "(unless moving)" clause.
]]

local TorsoTiltController = {}
TorsoTiltController.__index = TorsoTiltController

local MAX_TILT_DEGREES = 15
local TILT_LERP_SPEED = 8

local IDLE_STANCES = {
	Standing = true,
	TacticalWalk = true,
	Crouching = true,
	Prone = true,
}

export type TorsoTiltControllerInstance = typeof(setmetatable(
	{} :: {
		Character: Model,
		RootPart: BasePart,
		Waist: Motor6D,
		_waistRestC0: CFrame,
		_isLocalPlayer: boolean,
		_currentTiltDeg: number,
		_rawLookDeltaDeg: number,
	},
	TorsoTiltController
))

local function signedYawDeltaDegrees(fromLook: Vector3, toLook: Vector3): number
	local flatFrom = Vector3.new(fromLook.X, 0, fromLook.Z)
	local flatTo = Vector3.new(toLook.X, 0, toLook.Z)
	if flatFrom.Magnitude < 1e-4 or flatTo.Magnitude < 1e-4 then
		return 0
	end
	flatFrom = flatFrom.Unit
	flatTo = flatTo.Unit

	local dot = math.clamp(flatFrom:Dot(flatTo), -1, 1)
	local angle = math.deg(math.acos(dot))
	local cross = flatFrom:Cross(flatTo)
	if cross.Y < 0 then
		angle = -angle
	end
	return angle
end

function TorsoTiltController.new(character: Model, isLocalPlayer: boolean): TorsoTiltControllerInstance?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local upperTorso = character:FindFirstChild("UpperTorso") :: BasePart?
	local waist = upperTorso and upperTorso:FindFirstChild("Waist") :: Motor6D?

	if not (rootPart and waist) then
		return nil
	end

	return setmetatable({
		Character = character,
		RootPart = rootPart :: BasePart,
		Waist = waist :: Motor6D,
		_waistRestC0 = (waist :: Motor6D).C0,
		_isLocalPlayer = isLocalPlayer,
		_currentTiltDeg = 0,
		_rawLookDeltaDeg = 0,
	}, TorsoTiltController) :: any
end

--- Unclamped look-delta in degrees (positive = camera looking right of body facing).
--- A future turn-in-place system reads this to decide when to actually rotate the root.
function TorsoTiltController.GetRawLookDelta(self: TorsoTiltControllerInstance): number
	return self._rawLookDeltaDeg
end

function TorsoTiltController.Update(self: TorsoTiltControllerInstance, dt: number, isMoving: boolean)
	local targetTilt = 0

	if self._isLocalPlayer then
		local camera = workspace.CurrentCamera
		local stance = self.Character:GetAttribute("CombatStance")
		local stanceOk = typeof(stance) ~= "string" or IDLE_STANCES[stance] == true

		if camera and stanceOk and not isMoving then
			local delta = signedYawDeltaDegrees(self.RootPart.CFrame.LookVector, camera.CFrame.LookVector)
			self._rawLookDeltaDeg = delta
			targetTilt = math.clamp(delta, -MAX_TILT_DEGREES, MAX_TILT_DEGREES)
		else
			self._rawLookDeltaDeg = 0
		end
	end

	local alpha = math.clamp(TILT_LERP_SPEED * dt, 0, 1)
	self._currentTiltDeg += (targetTilt - self._currentTiltDeg) * alpha
	self.Waist.C0 = self._waistRestC0 * CFrame.Angles(0, math.rad(self._currentTiltDeg), 0)
end

return TorsoTiltController
