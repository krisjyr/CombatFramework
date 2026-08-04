--!strict
--[[
	MomentumController.lua  (Ch 2 — "real" directional inertia, Assassin's Creed / Tom Clancy feel)

	WHY THIS EXISTS: Roblox's Humanoid actively re-asserts its own WalkSpeed * MoveDirection
	velocity every physics step. You cannot make a Humanoid-driven character travel in a
	direction that lags behind input (the "carving a turn" feel) by only setting WalkSpeed —
	the character will always immediately travel in whatever MoveDirection currently is. The
	standard, safe way around this: pin Humanoid.WalkSpeed near zero so its own controller
	stops fighting you, then drive X/Z velocity yourself via a LinearVelocity constraint,
	leaving Y (gravity, jumping) completely untouched — Humanoid's jump/fall state machine
	and vertical physics keep working exactly as before, so FallService, stance auto-jump
	transitions, and AnimationController don't need to know this exists.

	MOMENTUM MODEL: `CurrentVelocity` is a real planar (Y=0) vector that must be STEERED
	toward the desired velocity, not snapped to it:
	  - Magnitude (speed) still ramps via Acceleration/Deceleration, same idea as before.
	  - DIRECTION is separately steered at a turn rate (degrees/sec) that shrinks the faster
	    you're already going — near a stop you can spin to face any direction almost
	    instantly, but redirecting sharply at a sprint takes real time and "carves" a curve
	    instead of snapping. That's the actual Assassin's Creed / Tom Clancy feel: you can't
	    juke instantly at full speed.
	  - Releasing input doesn't erase the direction — the character keeps sliding along its
	    last heading while speed bleeds off via Deceleration, then stops. No snap-to-zero.

	Also owns a VectorForce that counteracts/replaces default engine gravity on the Y axis
	only, so a per-character Gravity override (Ch 2.3, Low/High/Zero-G Movement Profiles)
	actually takes physical effect — this was previously a commented-out TODO.

	OWNERSHIP: only ever construct this on the side that owns real physics for the character
	— the controlling client for a player, or the server for an AI/NPC entity (Ch 13).
	Constructing it where physics isn't owned would be inert or fight the owning side.
]]

local Workspace = game:GetService("Workspace")

local MomentumController = {}
MomentumController.__index = MomentumController

export type MomentumControllerInstance = typeof(setmetatable(
	{} :: {
		RootPart: BasePart,
		Humanoid: Humanoid,
		Attachment: Attachment,
		LinearVelocity: LinearVelocity,
		VectorForce: VectorForce,
		CurrentVelocity: Vector3,
	},
	MomentumController
))

-- Turning feels responsive near a stop, and increasingly resists a sharp direction change
-- the faster you're already going.
local BASE_TURN_RATE_DEG_PER_SEC = 260 -- turn rate available at (near) zero speed
local MIN_TURN_RATE_FRACTION_AT_FULL_SPEED = 0.28 -- fraction of BASE_TURN_RATE retained at FULL_SPEED_REFERENCE
local FULL_SPEED_REFERENCE = 20 -- studs/s; speed at which turn rate bottoms out at the fraction above
local STOP_SNAP_EPSILON = 0.05 -- below this speed, treat direction as undefined (avoids NaN from a zero vector)
local INPUT_MAGNITUDE_THRESHOLD = 0.05

local MAX_PLANAR_FORCE = 1e6 -- effectively "as much force as needed" for LinearVelocity to hit its target

function MomentumController.new(rootPart: BasePart, humanoid: Humanoid): MomentumControllerInstance
	local attachment = Instance.new("Attachment")
	attachment.Name = "CombatFrameworkMomentumAttachment"
	attachment.Parent = rootPart

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "CombatFrameworkPlanarVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	-- Zero force on Y: this constraint NEVER fights gravity or jumping, only X/Z.
	linearVelocity.MaxAxesForce = Vector3.new(MAX_PLANAR_FORCE, 0, MAX_PLANAR_FORCE)
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Enabled = true
	linearVelocity.Parent = attachment

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "CombatFrameworkGravityOverrideForce"
	vectorForce.Attachment0 = attachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Force = Vector3.zero
	vectorForce.Enabled = true
	vectorForce.Parent = attachment

	-- Humanoid's own walk controller must stop trying to move the character (it would
	-- otherwise fight the LinearVelocity constraint every physics step); a near-zero
	-- WalkSpeed hands planar movement fully to our constraint while leaving jumping,
	-- falling, and Humanoid state detection completely alone.
	humanoid.WalkSpeed = 0.01

	return setmetatable({
		RootPart = rootPart,
		Humanoid = humanoid,
		Attachment = attachment,
		LinearVelocity = linearVelocity,
		VectorForce = vectorForce,
		CurrentVelocity = Vector3.zero,
	}, MomentumController) :: any
end

--- Steers CurrentVelocity toward (moveDirection.Unit * targetSpeed): direction is turned
--- at a speed-dependent rate rather than snapped, magnitude ramps via
--- acceleration/deceleration exactly like before. Pushes the result onto the LinearVelocity
--- constraint every call.
function MomentumController.Update(
	self: MomentumControllerInstance,
	dt: number,
	moveDirection: Vector3,
	targetSpeed: number,
	acceleration: number,
	deceleration: number
)
	local horizontalInput = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	local hasInput = horizontalInput.Magnitude > INPUT_MAGNITUDE_THRESHOLD

	local currentSpeed = self.CurrentVelocity.Magnitude
	local currentDirection: Vector3? = if currentSpeed > STOP_SNAP_EPSILON then self.CurrentVelocity / currentSpeed else nil

	local desiredDirection: Vector3? = if hasInput then horizontalInput.Unit else currentDirection
	local desiredSpeed = if hasInput then targetSpeed else 0

	-- Magnitude ramp (same idea as the old scalar system).
	local newSpeed = currentSpeed
	if newSpeed < desiredSpeed then
		newSpeed = math.min(desiredSpeed, newSpeed + acceleration * dt)
	elseif newSpeed > desiredSpeed then
		newSpeed = math.max(desiredSpeed, newSpeed - deceleration * dt)
	end

	-- Direction steering: limited turn rate, tighter the faster you're already going.
	local newDirection = currentDirection
	if desiredDirection then
		if not currentDirection then
			-- Starting from a dead stop: no prior direction to steer from, take input directly.
			newDirection = desiredDirection
		else
			local speedFraction = math.clamp(currentSpeed / FULL_SPEED_REFERENCE, 0, 1)
			local turnRateFraction = 1 - (1 - MIN_TURN_RATE_FRACTION_AT_FULL_SPEED) * speedFraction
			local turnRateRadPerSec = math.rad(BASE_TURN_RATE_DEG_PER_SEC * turnRateFraction)
			local maxTurn = turnRateRadPerSec * dt

			local angleBetween = math.acos(math.clamp((currentDirection :: Vector3):Dot(desiredDirection), -1, 1))

			if angleBetween <= maxTurn or angleBetween < 1e-4 then
				newDirection = desiredDirection
			else
				-- Rotate currentDirection toward desiredDirection by maxTurn radians around
				-- world-up (planar turning only, character never pitches/rolls from this).
				local cross = (currentDirection :: Vector3):Cross(desiredDirection)
				local turnSign = if cross.Y >= 0 then 1 else -1
				local rotation = CFrame.fromAxisAngle(Vector3.yAxis, maxTurn * turnSign)
				newDirection = (rotation * (currentDirection :: Vector3)).Unit
			end
		end
	end

	self.CurrentVelocity = if newDirection then (newDirection :: Vector3) * newSpeed else Vector3.zero
	self.LinearVelocity.VectorVelocity = self.CurrentVelocity
end

--- Applies (or clears) a Y-axis-only counter-gravity force so the character's effective
--- fall acceleration matches `gravityVector.Y` instead of the engine default
--- (`workspace.Gravity`). Only ever touches Y — never reorients "down" sideways (that's
--- future Surface Adhesion work, Ch 2.4).
function MomentumController.SetGravity(self: MomentumControllerInstance, gravityVector: Vector3)
	local mass = self.RootPart.AssemblyMass
	local desiredAccelY = gravityVector.Y
	local engineAccelY = -Workspace.Gravity -- workspace.Gravity is a positive magnitude pulling down
	self.VectorForce.Force = Vector3.new(0, (desiredAccelY - engineAccelY) * mass, 0)
end

function MomentumController.Destroy(self: MomentumControllerInstance)
	self.Attachment:Destroy()
end

return MomentumController
