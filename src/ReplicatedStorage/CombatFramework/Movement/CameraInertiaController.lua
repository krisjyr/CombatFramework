--!strict
--[[
	CameraInertiaController.lua  (Ch 2.9 Camera)

	Gives first-person mouselook real INERTIA instead of a flat sensitivity scalar. A flat
	cut ("half your mouse speed while sprinting") still lets you snap the camera instantly
	to a new heading, just slower — it never produces the Tarkov feel, which is that your
	head/gun has momentum: a fast flick ramps UP to speed over a few frames and decays back
	DOWN when you stop moving the mouse, instead of tracking 1:1 no matter how hard you flick.

	MECHANISM (deliberately mirrors MomentumController.lua's turn-rate-shrinks-with-speed
	idea, applied to camera look instead of movement direction):

	  - Raw mouse delta this frame -> a DESIRED angular velocity (rad/s), clamped to a max
	    that shrinks the faster the character is currently moving.
	  - The camera's ACTUAL angular velocity chases that desired value via an ACCELERATION
	    cap that also shrinks with speed — never snapped directly to the target.
	  - actualAngularVelocity * dt is what rotates the camera this frame.

	At a standstill both caps are effectively uncapped -> normal 1:1 FPS feel. At a sprint
	both caps collapse -> a flick visibly ramps up and coasts back down instead of snapping.

	WEIGHT / GEAR HOOK: agility also multiplies by
	`controller.Modifiers:ResolveNumeric("CameraControlMultiplier", 1.0)` — the SAME
	ModifierStack Stances/Statuses/Attachments push into (Ch 8.3). This is the extension
	point for the future Weight system (Ch 2.7) and Load-Bearing/Powered-Exo equipment
	(Ch 16.2) to push their own camera-agility modifiers under their own sourceId, exactly
	like SpeedMultiplier already works — no new subsystem required.

	OWNERSHIP: client-only, first-person only (Ch 2.9). Construct once per character
	alongside the client's own CharacterController (ownsPhysics = true).
]]

local UserInputService = game:GetService("UserInputService")

local CameraInertiaController = {}
CameraInertiaController.__index = CameraInertiaController

export type CameraInertiaControllerInstance = typeof(setmetatable(
	{} :: {
		Camera: Camera,
		Humanoid: Humanoid,
		RootPart: BasePart,
		Controller: any, -- CharacterController.CharacterControllerInstance (kept `any` to avoid a circular require)

		Yaw: number,
		Pitch: number,
		_yawVelocity: number,
		_pitchVelocity: number,

		_pendingDeltaX: number,
		_pendingDeltaY: number,
		_inputConn: RBXScriptConnection?,

		LeanOffset: Vector3,
		EyeOffset: Vector3,
		Enabled: boolean,

        BodyYaw: number, 
        Freelooking: boolean
	},
	CameraInertiaController
))

-- === Tuning ==============================================================
-- Mirrors MomentumController's turn-rate-shrinks-with-speed shape and constant name.
local BASE_SENSITIVITY = 0.0022 -- rad/pixel; a typical "medium" FPS mouse feel at zero speed

local FULL_SPEED_REFERENCE = 20 -- studs/s; SAME reference MomentumController uses for its own falloff

-- Yaw is the axis that should feel the "can't flick around at a sprint" effect hardest.
local YAW_MAX_ACCEL_STANDING = math.rad(9000) -- rad/s^2; effectively "snap" at a standstill
local YAW_MIN_ACCEL_FRACTION_AT_FULL_SPEED = 0.40
local YAW_MAX_VELOCITY_STANDING = math.rad(3600)
local YAW_MIN_VELOCITY_FRACTION_AT_FULL_SPEED = 0.40

-- Pitch stays a bit crisper than yaw even while sprinting (matches real Tarkov hip-fire feel).
local PITCH_MAX_ACCEL_STANDING = math.rad(9000)
local PITCH_MIN_ACCEL_FRACTION_AT_FULL_SPEED = 0.35
local PITCH_MAX_VELOCITY_STANDING = math.rad(300)
local PITCH_MIN_VELOCITY_FRACTION_AT_FULL_SPEED = 0.55

local MAX_PITCH = math.rad(85)
local MIN_PITCH = -math.rad(85)

-- === Freelook tuning ==============================================================
local FREELOOK_MAX_YAW = math.rad(110)   -- how far off body-facing freelook can swing
local FREELOOK_RETURN_RATE = 6          -- how fast body facing catches up once released
local FREELOOK_SENSITIVITY_MULTIPLIER = 1.6 -- freelook feels closer to raw/uninertial than normal aim

-- === Camera pivot / eye offsets ==========================================================
local NECK_PIVOT_OFFSET = Vector3.new(0, 1.7, -0.1)      -- pivot point, base of neck
local EYE_LOCAL_OFFSET = Vector3.new(0, 0.45, -0.35)  -- eye relative to pivot, slight forward
local WALL_CLEARANCE = 0.2    

local MOVE_INPUT_KEYS = {
	Forward = Enum.KeyCode.W,
	Back = Enum.KeyCode.S,
	Left = Enum.KeyCode.A,
	Right = Enum.KeyCode.D,
}-- studs kept between eye and any hit surface

-- new fields on the instance: BodyYaw: number, Freelooking: boolean

--- Accel-capped chase toward `target` — never snaps, same idea as MomentumController's
--- speed ramp.
local function chase(current: number, target: number, maxAccel: number, dt: number): number
	if current < target then
		return math.min(target, current + maxAccel * dt)
	elseif current > target then
		return math.max(target, current - maxAccel * dt)
	end
	return current
end

function CameraInertiaController.new(camera: Camera, humanoid: Humanoid, rootPart: BasePart, controller: any): CameraInertiaControllerInstance
	local self = setmetatable({
		Camera = camera,
		Humanoid = humanoid,
		RootPart = rootPart,
		Controller = controller,

		Yaw = 0,
		Pitch = 0,
		_yawVelocity = 0,
		_pitchVelocity = 0,

		_pendingDeltaX = 0,
		_pendingDeltaY = 0,
		_inputConn = nil,

		LeanOffset = Vector3.zero,
		Enabled = false,

        BodyYaw = 0,
        Freelooking = false
		
	}, CameraInertiaController) :: any

	-- after building `self`, before returning it:
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rootPart.Parent :: Instance }
	params.IgnoreWater = true
	self._raycastParams = params

	-- Seed yaw from the character's current facing so entering Scriptable mode doesn't
	-- visibly snap the camera to world-forward.
	local look = rootPart.CFrame.LookVector
	self.Yaw = math.atan2(-look.X, -look.Z)

	return self
end

--- Takes over the camera (Scriptable + mouse locked/centered) and starts accumulating
--- mouse delta. Call when entering first person (Ch 2.9: forced whenever a weapon is
--- equipped).
function CameraInertiaController.Enable(self: CameraInertiaControllerInstance)
	if self.Enabled then
		return
	end
	self.Enabled = true

	self.Camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	self._inputConn = UserInputService.InputChanged:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			self._pendingDeltaX += input.Delta.X
			self._pendingDeltaY += input.Delta.Y
		end
	end)
end

--- Hands the camera back to the default Roblox controller (third person / unarmed states,
--- Ch 2.9).
function CameraInertiaController.Disable(self: CameraInertiaControllerInstance)
	if not self.Enabled then
		return
	end
	self.Enabled = false

	if self._inputConn then
		self._inputConn:Disconnect()
		self._inputConn = nil
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	self.Camera.CameraType = Enum.CameraType.Custom
	self.Humanoid.AutoRotate = true
end

--- MovementClient's existing lean peek (Q/E) now feeds in here instead of
--- Humanoid.CameraOffset, since Scriptable cameras don't respect CameraOffset.
function CameraInertiaController.SetLeanOffset(self: CameraInertiaControllerInstance, offset: Vector3)
	self.LeanOffset = offset
end

function CameraInertiaController.SetFreelooking(self, active: boolean)
	self.Freelooking = active
end

--- Call once per RenderStep(dt) while Enabled.
function CameraInertiaController.Update(self, dt)
	if not self.Enabled or dt <= 0 then
		return
	end

	-- Something else (Shift+P spectate, Studio free-cam, a cutscene system) has taken
	-- the camera since we last checked — stand down instead of fighting it. We reclaim
	-- automatically the next time FirstPersonState says we should be active AND the
	-- camera is back to whatever we expect.
	if self.Camera.CameraType ~= Enum.CameraType.Scriptable then
		return
	end

	local deltaX = self._pendingDeltaX
	local deltaY = self._pendingDeltaY
	self._pendingDeltaX = 0
	self._pendingDeltaY = 0

-- === Speed / weight agility — same falloff shape MomentumController uses ==========
	-- Reads directly off RootPart's real velocity instead of reaching into
	-- CharacterController/MomentumController internals — this stays correct regardless
	-- of ownership model or internal field names, same fallback IsMoving() itself uses.
	local velocity = self.RootPart.AssemblyLinearVelocity
	local planarVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local currentSpeed = planarVelocity.Magnitude
	local speedFraction = math.clamp(currentSpeed / FULL_SPEED_REFERENCE, 0, 1)

	local gearMultiplier = 1.0
	if self.Controller.Modifiers then
		gearMultiplier = self.Controller.Modifiers:ResolveNumeric("CameraControlMultiplier", 1.0)
	end

	local yawAccelFraction = gearMultiplier * (1 - (1 - YAW_MIN_ACCEL_FRACTION_AT_FULL_SPEED) * speedFraction)
	local yawVelFraction = gearMultiplier * (1 - (1 - YAW_MIN_VELOCITY_FRACTION_AT_FULL_SPEED) * speedFraction)
	local pitchAccelFraction = gearMultiplier * (1 - (1 - PITCH_MIN_ACCEL_FRACTION_AT_FULL_SPEED) * speedFraction)
	local pitchVelFraction = gearMultiplier * (1 - (1 - PITCH_MIN_VELOCITY_FRACTION_AT_FULL_SPEED) * speedFraction)

	local yawMaxAccel = YAW_MAX_ACCEL_STANDING * math.max(yawAccelFraction, 0.01)
	local yawMaxVel = YAW_MAX_VELOCITY_STANDING * math.max(yawVelFraction, 0.01)
	local pitchMaxAccel = PITCH_MAX_ACCEL_STANDING * math.max(pitchAccelFraction, 0.01)
	local pitchMaxVel = PITCH_MAX_VELOCITY_STANDING * math.max(pitchVelFraction, 0.01)

	-- === Desired angular velocity from raw mouse delta this frame =====================
	local desiredPitchVel = math.clamp((-deltaY * BASE_SENSITIVITY) / dt, -pitchMaxVel, pitchMaxVel)

	-- === Actual angular velocity CHASES desired — accel-capped, never snapped =========
	self._pitchVelocity = chase(self._pitchVelocity, desiredPitchVel, pitchMaxAccel, dt)
	self.Pitch = math.clamp(self.Pitch + self._pitchVelocity * dt, MIN_PITCH, MAX_PITCH)

    if self.Freelooking then
        -- Freelook: much lighter inertia (near-raw), camera yaw ranges around BodyYaw but
        -- body facing itself does NOT follow — this is what makes it "look without turning."
        local desiredYawVel = math.clamp((-deltaX * BASE_SENSITIVITY * FREELOOK_SENSITIVITY_MULTIPLIER) / dt, -yawMaxVel, yawMaxVel)
        self._yawVelocity = chase(self._yawVelocity, desiredYawVel, yawMaxAccel * 4, dt) -- much snappier accel cap
        local proposedYaw = self.Yaw + self._yawVelocity * dt
        local offsetFromBody = math.clamp(
            (proposedYaw - self.BodyYaw + math.pi) % (2 * math.pi) - math.pi,
            -FREELOOK_MAX_YAW, FREELOOK_MAX_YAW
        )
        self.Yaw = self.BodyYaw + offsetFromBody
    else
        -- normal inertial tracking (as before), and body facing follows camera again
        local desiredYawVel = math.clamp((-deltaX * BASE_SENSITIVITY) / dt, -yawMaxVel, yawMaxVel)
        self._yawVelocity = chase(self._yawVelocity, desiredYawVel, yawMaxAccel, dt)
        self.Yaw += self._yawVelocity * dt

        -- smoothly reconcile BodyYaw back to camera Yaw so releasing freelook doesn't snap
        local alpha = math.clamp(FREELOOK_RETURN_RATE * dt, 0, 1)
        local diff = (self.Yaw - self.BodyYaw + math.pi) % (2 * math.pi) - math.pi
        self.BodyYaw += diff * alpha
    end

-- === Apply — body-relative pivot, arcing eyes, wall-clip prevention ==============
	local rootCFrame = self.RootPart.CFrame
	local bodyCFrame = CFrame.new(rootCFrame.Position) * CFrame.Angles(0, self.BodyYaw, 0)

	-- LeanOffset and the neck pivot are both LOCAL to the body's facing (BodyYaw), not
	-- world axes or freelook Yaw — this is what keeps the eye glued to the torso as you
	-- turn, instead of drifting toward the spine.
	local pivotWorld = bodyCFrame:PointToWorldSpace(NECK_PIVOT_OFFSET + self.LeanOffset)

	-- Eyes ARC around the pivot as pitch changes (real neck kinematics), then the whole
	-- thing is rotated by camera Yaw (which may be ahead of BodyYaw during freelook).
	local headRotation = CFrame.Angles(0, self.Yaw, 0) * CFrame.Angles(self.Pitch, 0, 0)
	local desiredEyePosition = pivotWorld + (headRotation * EYE_LOCAL_OFFSET)

	-- Wall-clip prevention: raycast from the pivot (safely inside the torso) out to the
	-- desired eye position. If something's in the way (chest pressed to a wall), clamp
	-- the eye to just short of it — same idea stock third-person camera collision uses.
	local toEye = desiredEyePosition - pivotWorld
	local dist = toEye.Magnitude
	if dist > 0.01 then
		local result = workspace:Raycast(pivotWorld, toEye, self._raycastParams)
		if result then
			local safeDist = math.max(result.Distance - WALL_CLEARANCE, 0)
			desiredEyePosition = pivotWorld + toEye.Unit * safeDist
		end
	end

	self.Camera.CFrame = CFrame.new(desiredEyePosition) * headRotation

	-- Body facing still follows BodyYaw, unaffected by freelook Yaw.
	local flatLook = Vector3.new(-math.sin(self.BodyYaw), 0, -math.cos(self.BodyYaw))
	self.RootPart.CFrame = CFrame.new(rootCFrame.Position, rootCFrame.Position + flatLook)

end

function CameraInertiaController.Destroy(self: CameraInertiaControllerInstance)
	self:Disable()
end

return CameraInertiaController