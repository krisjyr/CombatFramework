--!strict
--[[
	IKLegController.lua  (Ch 2 Character Controller / Ch 9 Animation Framework extension)

	--------------------------------------------------------------------------------
	WHAT THIS IS: procedural foot placement for the R15 rig using Roblox's native
	IKControl system (Chapter 9's "Procedural animation layers on top of authored clips
	for weapon alignment, hand/foot placement, surface adaptation" — this module IS that
	hand/foot-placement layer). It does four things:

		1. Keeps both feet individually grounded on uneven terrain (stairs, slopes,
		   rubble) instead of clipping through or floating above it — each foot raycasts
		   independently, so one foot can sit a step higher than the other.
		2. Drives a real WALKING GAIT while moving: feet alternate stance/swing based on
		   distance traveled (not a fixed timer, so cadence naturally matches speed),
		   swinging fore/aft of the hip with a lift arc — this is what gives visible
		   thigh movement, and is what replaces the old "drift too far, then snap" foot
		   correction that looked like a Michael-Jackson lean during continuous walking
		   (the body would visibly outrun the feet before a correction finally fired).
		3. Procedurally bends the knees to match the current stance's squat depth
		   (Crouching / Prone) by reading the already-authoritative, already-replicated
		   Humanoid.HipHeight (set server-side by CharacterController.Update, Ch 1.3) —
		   NO new custom crouch/prone animations are required, the IK solver does the
		   bending on top of whatever Idle/Move clip is already playing. Crouching now
		   poses BOTH legs explicitly (KNEEL_FOOT_LOCAL_OFFSET for the kneeling leg,
		   KNEEL_FRONT_FOOT_LOCAL_OFFSET for the planted forward leg) instead of only the
		   kneeling leg getting a dedicated pose.
		4. Turns the head toward wherever the camera is actually looking (Neck IK,
		   LookAt-type) once that diverges from body-forward by more than a small
		   threshold — i.e. free-look. Clamped to a human yaw/pitch range so it can't
		   twist unnaturally. See UpdateHeadLook below and IKVisualsBootstrap for wiring.

	Also exposes SetFootOverride / SetHandOverride hooks for a future Vaulting/Climbing
	system (Ch 2.6, Ch 16.3) to explicitly plant a foot or hand on a ledge without
	needing any new IK plumbing — it just calls this controller. Overrides always win
	over both the gait cycle and the idle-correction logic.

	--------------------------------------------------------------------------------
	OWNERSHIP / REPLICATION MODEL — this is the important part:

	IK pose (Motor6D-driven joint rotation via IKControl) is NOT something that
	automatically replicates from one machine to another the way Animator track
	playback does (Ch 9's AnimationController comment). Two options exist:
	  (a) Have the owning client/server compute IK once and try to network the result, or
	  (b) Have EVERY observing client compute IK locally, for EVERY character it renders
	      (its own and everyone else's), using already-replicated ground-truth data
	      (RootPart CFrame, Humanoid.HipHeight, the CombatStance attribute) plus the
	      SAME static terrain every client already has loaded.

	This module takes approach (b), matching Ch 1.3's Client/Server split exactly:
	"Visual prediction... local cosmetic effects" are client-owned, and per Ch 11,
	visual feedback must "never be allowed to affect server-authoritative outcomes."
	Foot placement is squarely cosmetic — hit registration and damage still run entirely
	through the standard server-authoritative pipeline (Ch 1.3, Ch 4.6) untouched by this.

	Head-look direction is the one piece of state here that genuinely needs to come from
	a specific machine (the camera belongs to exactly one client) — see the
	LookDirection attribute convention described at the top of UpdateHeadLook below,
	which follows the same "cosmetic attribute, cheap to replicate, never authoritative"
	pattern the CombatStance attribute already establishes elsewhere in this file.

	Practically: every client constructs one IKLegController PER VISIBLE CHARACTER
	(see IKVisualsBootstrap.client.lua), including remote players. Because every client
	raycasts against the same static geometry using the same replicated RootPart
	position, every observer arrives at the same (or near-identical) foot placement
	independently — no network traffic required for foot IK at all.

	IKControl instances created here are created LOCALLY by the observing client and are
	never parented in a way that replicates to the server or other clients (a client can
	freely parent new Instances under any Model it can see, including other players'
	characters — this is the same trick used for client-only muzzle flashes/VFX). Each
	observer's set of IKControls is therefore entirely private to that observer.
	--------------------------------------------------------------------------------
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local Stances = require(CombatFramework.Shared.Config.Stances)
local LookIKTuning = require(CombatFramework.Shared.Config.LookIKTuning)
local LookIKMath = require(CombatFramework.Shared.LookIKMath)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local FootPlanted = CombatEvents.FootPlanted

local IKLegController = {}
IKLegController.__index = IKLegController

export type FootSide = "Left" | "Right"

-- ====== STANCES ====================================================
local GROUNDED_STANCES = {
	Standing = true,
	TacticalWalk = true,
	TacticalSprint = true,
	Crouching = true,
	Prone = true,
}

-- ====== LEG DETECTION ====================================================
local HIP_WIDTH = 0.6 -- studs, half-distance between the two feet's natural stance
local RAY_UP = 3 -- studs above the natural foot position to start the raycast
local RAY_DOWN = 8 -- studs below that to search for ground
local MAX_FOOT_REACH = 3.2 -- studs of vertical deviation from the "flat ground" pose before IK gives up (cliff/gap)
local FOOT_GROUND_PAD = 0.08 -- studs; keeps the sole just barely off the raycast hit to avoid z-fighting/clipping
local SURFACE_NORMAL_BLEND = 0.55 -- 0 = feet always flat, 1 = feet fully match slope normal (ankle realism vs. stability)
local WEIGHT_LERP_SPEED = 9 -- how fast IKControl.Weight blends in/out

-- ====== KNEEPOLE ====================================================
local FOOT_POSITION_LERP = 18
local FOOT_ROTATION_LERP = 9  -- slower than position — smooths out steep pitch changes specifically
local MOVE_DIRECTION_LERP = 12
local KNEE_POLE_FORWARD = 2.2
local KNEE_POLE_DOWN = 1.2
local KNEE_POLE_SWING_BOOST = 0.4 -- studs; how much extra "up/forward" the pole moves at peak swing-lift
local POLE_LERP_SPEED = 20
local POLE_LERP_SPEED_NEAR_EXTENSION = 6

-- ====== FOOT PITCH ====================================================
local PITCH_HEEL_STRIKE   = 22   -- toe up at initial ground contact
local PITCH_FOOT_FLAT     = 0
local PITCH_TOE_OFF       = -72  -- heel already lifted, toe pushing off last
local PITCH_KNEE_LIFT     = -52    -- ankle relaxes/dorsiflexes as the knee drives the foot up+forward
local PITCH_LEG_SWING     = 32

local MAX_FOOT_PITCH_DEG = 35 -- safety clamp, applies to both crouch and general idle pitch

local PITCH_KEYFRAMES: { { Phase: number, Pitch: number } } = {
	{ Phase = 0.00, Pitch = PITCH_HEEL_STRIKE },
	{ Phase = 0.12, Pitch = PITCH_FOOT_FLAT },   -- Foot Flat
	{ Phase = 0.25, Pitch = PITCH_FOOT_FLAT },   -- Mid Stance
	{ Phase = 0.3, Pitch = PITCH_TOE_OFF },     -- Heel Rise -> Toe Off
	{ Phase = 0.45, Pitch = PITCH_KNEE_LIFT },   -- Knee Lift
	{ Phase = 0.95, Pitch = PITCH_LEG_SWING },   -- Leg Swing -> Leg Extension
	{ Phase = 1.00, Pitch = PITCH_HEEL_STRIKE }, -- back to Heel Strike
}

-- ====== CROUCH ====================================================
local KNEEL_FOOT_LOCAL_OFFSET = CFrame.new(0, -0.25, 0.7) -- kneeling foot: near-ground, behind hip
local KNEEL_FRONT_FOOT_LOCAL_OFFSET = CFrame.new(0, -0.25, -1.1) -- opposite (planted/forward) leg while kneeling
local KNEELING_LEG: FootSide = "Right" -- which leg drops to the ground in Crouching's kneel pose

-- ====== LEG STEPS ====================================================
local STEP_TRIGGER_DISTANCE = 0.65 -- studs a planted foot may drift before it takes a corrective step [Default if stance not set]
local STEP_DURATION = 0.28        -- seconds for one corrective step's arc [Default if stance not set]
local STEP_HEIGHT = 1.1           -- studs of lift mid-step / mid-swing

local REACH_SPEED_MIN_FRACTION = 0.85  -- reach multiplier at/below REACH_SPEED_FLOOR
local REACH_SPEED_FLOOR = 4            -- studs/s; at/below this, reach sits at the min fraction (creeping)
local REACH_SPEED_CEILING = 20        -- studs/s; at/above this, reach is fully scaled (fast sprint)
local GAIT_MOVE_THRESHOLD = 0.6 -- studs/s planar speed below which the gait cycle stops and feet fall back to the idle/turn-correction path

local MAX_LEG_REACH_MULTIPLIER = 3
-- studs a planted foot may drift before it takes a corrective step
local STEP_TRIGGER_DISTANCE_BY_STANCE : { [string]: number } = {
	Standing =  0.65,
	TacticalWalk =  0.65,     
	TacticalSprint =  0.65,  
	Crouching =  0.65,        
}
local STEP_DURATION_BY_STANCE : { [string]: number } = {
	Standing =  0.28,
	TacticalWalk =  0.28,     
	TacticalSprint =  0.18,   
	Crouching =  0.18,        
}
local REACH_SCALE_BY_STANCE: { [string]: number } = {
    Standing = 0.8,
    TacticalWalk = 0.6,   -- short, quiet steps while creeping
    TacticalSprint = 0.8, -- long reach — this is what actually fixes sprint looking marchy
	Crouching = 0.2,
}
local LIFT_SCALE_BY_STANCE: { [string]: number } = {
	Standing = 1,
	TacticalWalk = 0.5,
	TacticalSprint = 2.4,
	Crouching = 0.5,
}

local CADENCE_MIN_HZ = 1.3          -- steps/sec per foot at/below CADENCE_SPEED_FLOOR
local CADENCE_MAX_HZ = 2.6          -- HARD ceiling -- cadence never exceeds this no matter how fast you go
local CADENCE_SPEED_FLOOR = 3       -- studs/s
local CADENCE_SPEED_CEILING = 45    -- studs/s -- tune to your actual max sprint speed

local CADENCE_STANCE_MULTIPLIER: { [string]: number } = {
	Standing = 1.0,
	TacticalWalk = 0.75,
	TacticalSprint = 1.2,
	Crouching = 0.6,
}

local STRIDE_LENGTH_LERP_SPEED = 4

-- ====== ARMS ====================================================
local ARM_SWING_ENABLED_DEFAULT = true
 
local SHOULDER_WIDTH = 1.4        -- studs, half-distance between arms at rest (tune to DOGU15)
local ARM_HANG_DOWN_OFFSET = 1.1    -- studs below shoulder where a relaxed hand naturally sits
local ARM_HANG_FORWARD_OFFSET = 0.4 -- slight forward offset so hands don't clip through the hip/leg
 
local ARM_REACH = 4.3               -- studs; fore-aft swing amplitude at full reach (mirrors STEP_REACH)
local ARM_REACH_SPEED_MIN_FRACTION = 0.5 -- swing amplitude fraction at/below REACH_SPEED_FLOOR (reuses leg's speed curve)
local ARM_LIFT_HEIGHT = 1.02        -- studs; subtle vertical bob at the extremes of the swing (arms don't "step")
 
local MAX_ARM_REACH_MULTIPLIER = 3.0

local ARM_REACH_BY_STANCE: { [string]: number } = {
	Standing = 0.8,
	TacticalWalk = 0.55,   -- short, controlled swing while creeping (matches REACH_SCALE_BY_STANCE.TacticalWalk)
	TacticalSprint = 3.25, -- bigger pump at a sprint
	Crouching = 0.25,
}
 
local ARM_POSITION_LERP = 16
local ARM_ROTATION_LERP = 10
local ARM_WEIGHT_LERP_SPEED = 8
 
-- ====== ELBOW POLE ====================================================
local ELBOW_POLE_BACK_OFFSET = 2.0   -- studs; how far behind the shoulder the elbow pole sits (natural backward elbow bend)
local ELBOW_POLE_DOWN_OFFSET = 0
local ELBOW_POLE_OUT_OFFSET = 2.5 -- studs; sideways, keeps elbows from bending straight through the torso
local ELBOW_POLE_SWING_BOOST = 0.6
local ELBOW_POLE_LERP_SPEED = 20     -- reuses POLE_LERP_SPEED's role but kept separate in case arms need different feel later
 
-- ====== IDLE ====================================================
local IDLE_ARM_SWAY_AMPLITUDE = 0.12 -- studs; deliberately small -- this is a breathing-scale motion, not a swing
local IDLE_ARM_SWAY_SPEED = 1.6      -- radians/sec
local IDLE_ARM_WEIGHT = 0.5          -- IK weight while idle-swaying; drop toward 0 if you want it barely-there

-- ====== HAND PITCH ====================================================
local HAND_LOCAL_PITCH_DEG = 0
local HAND_LOCAL_YAW_DEG = 0
local HAND_LOCAL_ROLL_DEG = 0

local HAND_PITCH_RELAXED  = 0   -- idle / at-rest wrist pitch (not swinging)
local HAND_PITCH_FORWARD  = 30 -- wrist pitch at the forward extreme (arm reaching ahead)
local HAND_PITCH_MID      = -35   -- pitch as the hand passes directly under the shoulder
local HAND_PITCH_BACKWARD = 0  -- wrist pitch at the backward extreme (arm trailing behind)

local HAND_PITCH_KEYFRAMES: { { Phase: number, Pitch: number } } = {
	{ Phase = 0.00, Pitch = HAND_PITCH_FORWARD },
	{ Phase = 0.30, Pitch = HAND_PITCH_MID },
	{ Phase = 1.00, Pitch = HAND_PITCH_FORWARD },
}

-- ====== DISTANCE-BASED UPDATE ====================================================
local NEAR_DISTANCE = 40
local FAR_DISTANCE = 100
local FAR_UPDATE_EVERY_N_FRAMES = 4

export type IKLegControllerInstance = typeof(setmetatable(
	{} :: {
		Character: Model,
		Humanoid: Humanoid,
		RootPart: BasePart,
		LowerTorso: BasePart,
		UpperTorso: BasePart?,
		Head: BasePart?,
		Feet: { [FootSide]: BasePart },
		UpperLegs: { [FootSide]: BasePart },
		LowerLegs: { [FootSide]: BasePart },
		UpperArms: { [FootSide]: BasePart },
		LowerArms: { [FootSide]: BasePart },
		Hands: { [FootSide]: BasePart },
		Targets: { [FootSide]: Attachment },
		HandTargets: { [FootSide]: Attachment },
		Poles: { [FootSide]: Attachment },
		LegIK: { [FootSide]: IKControl },
		HandIK: { [FootSide]: IKControl },
		HeadTarget: Attachment?,
		HeadIK: IKControl?,
		ElbowPoles: { [FootSide]: Attachment },
		_armSwingEnabled: { [FootSide]: boolean },
		_currentArmWeight: { [FootSide]: number },
		_smoothedArmTarget: { [FootSide]: CFrame? },
		_smoothedElbowPolePos: { [FootSide]: Vector3? },
		_idleSwayPhaseOffset: { [FootSide]: number },
		_currentWeight: { [FootSide]: number },
		_footOverride: { [FootSide]: CFrame? },
		_handOverride: { [FootSide]: CFrame? },
		_raycastParams: RaycastParams,
		_enabled: boolean,
		_frameCounter: number,
		_footState: { [FootSide]: string },
		_footStepT: { [FootSide]: number },
		_footStepStart: { [FootSide]: CFrame? },
		_footPlantedCFrame: { [FootSide]: CFrame? },
		_gaitDistance: number,
		_headWeight: number,
		_headLeanRollDeg: number,
		_currentTorsoTrackRollDeg: number,
		_lastReliableYawDeg: number,
		_currentLift: { [FootSide]: number },
		_currentStrideLength: number,
		_smoothedPolePos: { [FootSide]: Vector3? },
		_currentForeAft: { [FootSide]: number },
		_smoothedStrideLength: number?,
		FootPlantedEvent: any, -- NamedSignal<(side: FootSide, worldPosition: Vector3, stance: string?, planarSpeed: number) -> ()>
		_lastGaitPhase: { [FootSide]: number },
		_lastPlanarSpeedForGait: number,
	},
	IKLegController
))

local function findPart(character: Model, name: string): BasePart?
	local inst = character:FindFirstChild(name)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

function IKLegController.new(character: Model, humanoid: Humanoid): IKLegControllerInstance?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local lowerTorso = findPart(character, "LowerTorso")
	local upperTorso = findPart(character, "UpperTorso")
	local head = findPart(character, "Head")
	local leftFoot, rightFoot = findPart(character, "LeftFoot"), findPart(character, "RightFoot")
	local leftUpperLeg, rightUpperLeg = findPart(character, "LeftUpperLeg"), findPart(character, "RightUpperLeg")
	local leftLowerLeg, rightLowerLeg = findPart(character, "LeftLowerLeg"), findPart(character, "RightLowerLeg")
	local leftUpperArm, rightUpperArm = findPart(character, "LeftUpperArm"), findPart(character, "RightUpperArm")
	local leftLowerArm, rightLowerArm = findPart(character, "LeftLowerArm"), findPart(character, "RightLowerArm")
	local leftHand, rightHand = findPart(character, "LeftHand"), findPart(character, "RightHand")

	if not (rootPart and lowerTorso and leftFoot and rightFoot and leftUpperLeg and rightUpperLeg) then
		-- Not an R15 rig (or DOGU15-equivalent) with the expected part names -- IK simply
		-- doesn't apply; caller should skip constructing this controller.
		return nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local self = setmetatable({
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart :: BasePart,
		LowerTorso = lowerTorso :: BasePart,
		UpperTorso = upperTorso,
		Head = head,
		Feet = { Left = leftFoot :: BasePart, Right = rightFoot :: BasePart },
		UpperLegs = { Left = leftUpperLeg :: BasePart, Right = rightUpperLeg :: BasePart },
		LowerLegs = { Left = leftLowerLeg, Right = rightLowerLeg },
		UpperArms = { Left = leftUpperArm, Right = rightUpperArm },
		LowerArms = { Left = leftLowerArm, Right = rightLowerArm },
		Hands = { Left = leftHand, Right = rightHand },
		Targets = {},
		HandTargets = {},
		Poles = {},
		LegIK = {},
		HandIK = {},
		HeadTarget = nil,
		HeadIK = nil,
		ElbowPoles = {},
		_armSwingEnabled = { Left = ARM_SWING_ENABLED_DEFAULT, Right = ARM_SWING_ENABLED_DEFAULT },
		_currentArmWeight = { Left = 0, Right = 0 },
		_smoothedArmTarget = { Left = nil, Right = nil },
		_smoothedElbowPolePos = { Left = nil, Right = nil },
		_idleSwayPhaseOffset = { Left = 0, Right = math.pi },
		_currentWeight = { Left = 0, Right = 0 },
		_footOverride = { Left = nil, Right = nil },
		_handOverride = { Left = nil, Right = nil },
		_raycastParams = raycastParams,
		_footState = { Left = "Planted", Right = "Planted" } :: { [FootSide]: "Planted" | "Stepping" },
		_footStepT =  { Left = 0, Right = 0 } :: { [FootSide]: number },
		_footStepStart =  { Left = nil, Right = nil } :: { [FootSide]: CFrame? },
		_footPlantedCFrame =  { Left = nil, Right = nil } :: { [FootSide]: CFrame? },
		_gaitDistance = 0,
		_smoothedMoveDir = Vector3.zAxis,
		_smoothedFootTarget = {
			Left = nil :: CFrame?,
			Right = nil :: CFrame?,
		},
		_headWeight = 0,
		_headLeanRollDeg = 0,
		_currentTorsoTrackRollDeg = 0,
		_lastReliableYawDeg = 0,
		_enabled = true,
		_frameCounter = 0,
		_currentLift = { Left = 0, Right = 0 },
		_currentStrideLength = STRIDE_LENGTH_MIN,
		_smoothedPolePos = { Left = nil, Right = nil },
		_currentForeAft = { Left = 0, Right = 0 },
		_smoothedStrideLength = nil,
		FootPlantedEvent = FootPlanted,
		_lastGaitPhase = { Left = 0, Right = 0.5 }, -- matches the sideOffset the two feet start at
		_lastPlanarSpeedForGait = 0,
	}, IKLegController) :: any

	self:_buildLegIK("Left")
	self:_buildLegIK("Right")

	if leftUpperArm and leftHand then
		self:_buildHandIK("Left")
	end
	if rightUpperArm and rightHand then
		self:_buildHandIK("Right")
	end
	if upperTorso and head then
		self:_buildHeadIK()
	end

	return self
end

function IKLegController._buildLegIK(self: IKLegControllerInstance, side: FootSide)
	local sign = if side == "Left" then -1 else 1

	-- Pole attachment fixed relative to LowerTorso: forward + slightly down, so the knee
	-- solve always bends forward (natural human knee direction) instead of the solver
	-- picking an arbitrary/backward bend.
	local pole = Instance.new("Attachment")
	pole.Name = `{side}KneePole`
	pole.CFrame = CFrame.new()
	pole.Parent = self.LowerTorso
	self.Poles[side] = pole

	-- Target attachment: world position updated every frame from the raycast result.
	-- Parented to Terrain (stable, non-moving) purely so it has somewhere to live --
	-- its WorldCFrame is what actually matters, not its parent.
	local target = Instance.new("Attachment")
	target.Name = `{side}FootIKTarget`
	target.Parent = Workspace.Terrain
	self.Targets[side] = target

	local ik = Instance.new("IKControl")
	ik.Name = `{side}LegIK`
	ik.Type = Enum.IKControlType.Transform
	ik.ChainRoot = self.UpperLegs[side]
	ik.EndEffector = self.Feet[side]
	ik.Target = target
	ik.Pole = pole
	ik.Weight = 0
	ik.SmoothTime = 0.08
	ik.Parent = self.Humanoid
	self.LegIK[side] = ik
end

local function cadenceHzFor(planarSpeed: number, stance: string?): number
	local t = math.clamp((planarSpeed - CADENCE_SPEED_FLOOR) / (CADENCE_SPEED_CEILING - CADENCE_SPEED_FLOOR), 0, 1)
	local eased = math.sqrt(t) -- rises fast off the floor, flattens hard -- real ceiling, not a straight line
	local hz = CADENCE_MIN_HZ + (CADENCE_MAX_HZ - CADENCE_MIN_HZ) * eased
	local mult = (typeof(stance) == "string" and CADENCE_STANCE_MULTIPLIER[stance]) or 1.0
	return hz * mult
end

function IKLegController._maxLegReach(self: IKLegControllerInstance, side: FootSide): number
	local upperLeg = self.UpperLegs[side]
	local lowerLeg = self.LowerLegs[side]
	local foot = self.Feet[side]
	local totalLegLength = upperLeg.Size.Y + (lowerLeg and lowerLeg.Size.Y or upperLeg.Size.Y) + foot.Size.Y
	return totalLegLength * MAX_LEG_REACH_MULTIPLIER
end

function IKLegController._maxArmReach(self: IKLegControllerInstance, side: FootSide): number
	local upperArm = self.UpperArms[side]
	local lowerArm = self.LowerArms[side]
	local hand = self.Hands[side]
	if not upperArm or not hand then
		return ARM_REACH -- fallback, shouldn't normally hit this
	end
	local totalArmLength = upperArm.Size.Y + (lowerArm and lowerArm.Size.Y or upperArm.Size.Y) + hand.Size.Y
	return totalArmLength * MAX_ARM_REACH_MULTIPLIER
end

function IKLegController._updateKneePole(self: IKLegControllerInstance, side: FootSide, dt: number)
	local pole = self.Poles[side]
	local target = self.Targets[side]
	if not pole or not target then
		return
	end

	local sign = side == "Left" and -1 or 1
	local root = self.RootPart.CFrame
	local forward = root.LookVector
	local right = root.RightVector

	local hipPos = self.LowerTorso.Position + right * sign * HIP_WIDTH
	local footPos = target.WorldPosition

	local toTarget = footPos - hipPos
	local targetDir = if toTarget.Magnitude > 1e-4 then toTarget.Unit else forward

	-- Natural knee-bend direction (forward + a bit down). This is what was being used
	-- directly as the pole offset before -- the problem is that when the foot swings out
	-- in FRONT of the hip, "forward" (the target direction) and this base bend direction
	-- both point the same way and go nearly collinear. A two-bone solver needs the pole
	-- direction to be off-axis from hip->target to pick a stable bend plane; once they're
	-- collinear the plane is undefined and the solver can flip the knee/twist 180 from
	-- one frame to the next. That's exactly why this only showed up stepping forward.
	local baseDir = (forward - Vector3.yAxis * 0.35)
	if baseDir.Magnitude < 1e-4 then
		baseDir = forward
	end
	baseDir = baseDir.Unit

	-- Strip out the component of baseDir that's parallel to targetDir (Gram-Schmidt),
	-- leaving only the part that's actually perpendicular -- this is what keeps the pole
	-- off-axis even as the foot swings through directly-forward.
	local orthogonal = baseDir - targetDir * baseDir:Dot(targetDir)

	if orthogonal.Magnitude < 0.05 then
		-- baseDir and targetDir are (nearly) fully collinear -- e.g. leg almost fully
		-- extended straight forward. Fall back to World Down, which is reliably
		-- perpendicular to a mostly-horizontal target direction, as a stable tiebreaker
		-- so the knee still bends predictably (down/forward) instead of the solver
		-- picking an arbitrary plane.
		orthogonal = Vector3.new(0, -1, 0) - targetDir * Vector3.new(0, -1, 0):Dot(targetDir)
	end

	orthogonal = if orthogonal.Magnitude > 1e-4 then orthogonal.Unit else forward

	local swingBoost = (self._currentLift[side] or 0) * KNEE_POLE_SWING_BOOST
	local desiredPolePos =
		hipPos
		+ orthogonal * (KNEE_POLE_FORWARD + swingBoost * 0.5)
		- Vector3.yAxis * math.max(KNEE_POLE_DOWN - swingBoost, 0.2)

	local hipToFootDist = (footPos - hipPos).Magnitude
	local legLength = self.UpperLegs[side].Size.Y
	+ (self.LowerLegs[side] and self.LowerLegs[side].Size.Y or self.UpperLegs[side].Size.Y)
	+ self.Feet[side].Size.Y
	local extensionFraction = math.clamp(hipToFootDist / math.max(legLength * 1.8, 1), 0, 1)
	local lerpSpeed = POLE_LERP_SPEED - (POLE_LERP_SPEED - POLE_LERP_SPEED_NEAR_EXTENSION) * extensionFraction

	local current = self._smoothedPolePos[side]
	if not current then
		current = desiredPolePos
	end
	local alpha = math.clamp(lerpSpeed * dt, 0, 1)
	current = current:Lerp(desiredPolePos, alpha)
	self._smoothedPolePos[side] = current

	pole.WorldPosition = current
end

local function sampleGaitPitch(phase: number): number
	phase = phase % 1
	for i = 1, #PITCH_KEYFRAMES - 1 do
		local a, b = PITCH_KEYFRAMES[i], PITCH_KEYFRAMES[i + 1]
		if phase >= a.Phase and phase <= b.Phase then
			local span = math.max(b.Phase - a.Phase, 1e-4)
			local f = (phase - a.Phase) / span
			local eased = f * f * (3 - 2 * f) -- smoothstep between keyframes
			return a.Pitch + (b.Pitch - a.Pitch) * eased
		end
	end
	return PITCH_KEYFRAMES[#PITCH_KEYFRAMES].Pitch
end

local function sampleHandGaitPitch(phase: number): number
	phase = phase % 1
	for i = 1, #HAND_PITCH_KEYFRAMES - 1 do
		local a, b = HAND_PITCH_KEYFRAMES[i], HAND_PITCH_KEYFRAMES[i + 1]
		if phase >= a.Phase and phase <= b.Phase then
			local span = math.max(b.Phase - a.Phase, 1e-4)
			local f = (phase - a.Phase) / span
			local eased = f * f * (3 - 2 * f) -- smoothstep between keyframes
			return a.Pitch + (b.Pitch - a.Pitch) * eased
		end
	end
	return HAND_PITCH_KEYFRAMES[#HAND_PITCH_KEYFRAMES].Pitch
end

local function getStrideLength(stance: string?): number
	if typeof(stance) == "string" then
		return STRIDE_LENGTH_BY_STANCE[stance] or STRIDE_LENGTH
	end
	return STRIDE_LENGTH
end

local function speedReachMultiplier(planarSpeed: number): number
	if planarSpeed <= REACH_SPEED_FLOOR then
		return REACH_SPEED_MIN_FRACTION
	end
	local t = math.clamp((planarSpeed - REACH_SPEED_FLOOR) / (REACH_SPEED_CEILING - REACH_SPEED_FLOOR), 0, 1)
	local eased = t * t * (3 - 2 * t) -- smoothstep, avoids a linear/robotic ramp
	return REACH_SPEED_MIN_FRACTION + (1 - REACH_SPEED_MIN_FRACTION) * eased
end

function IKLegController._buildHandIK(self, side)
	local upperArm = self.UpperArms[side]
	local hand = self.Hands[side]
	if not upperArm or not hand then
		return
	end
 
	-- Elbow pole: fixed relative to UpperTorso (falls back to LowerTorso if a rig has no
	-- UpperTorso), roughly where a relaxed elbow naturally points -- behind and slightly
	-- out from the shoulder. Updated live in _updateElbowPole so it can react to the
	-- current swing phase the same way the knee pole reacts to leg lift.
	local poleParent = self.UpperTorso or self.LowerTorso
	local pole = Instance.new("Attachment")
	pole.Name = `{side}ElbowPole`
	pole.CFrame = CFrame.new()
	pole.Parent = poleParent
	self.ElbowPoles[side] = pole
 
	local target = Instance.new("Attachment")
	target.Name = `{side}HandIKTarget`
	target.Parent = Workspace.Terrain
	self.HandTargets[side] = target
 
	local ik = Instance.new("IKControl")
	ik.Name = `{side}HandIK`
	ik.Type = Enum.IKControlType.Transform
	ik.ChainRoot = upperArm
	ik.EndEffector = hand
	ik.Target = target
	ik.Pole = pole
	ik.Weight = 0
	ik.SmoothTime = 0.06
	ik.Parent = self.Humanoid
	self.HandIK[side] = ik
end

function IKLegController._updateElbowPole(self, side, dt, foreAftMagnitude: number?)
	local pole = self.ElbowPoles[side]
	if not pole then
		return
	end

	local sign = if side == "Left" then -1 else 1
	local torsoCF = (self.UpperTorso or self.LowerTorso).CFrame

	local swingBoost = math.abs(foreAftMagnitude or 0) * ELBOW_POLE_SWING_BOOST

	local desired = (torsoCF * CFrame.new(
		sign * (SHOULDER_WIDTH + ELBOW_POLE_OUT_OFFSET),
		-ELBOW_POLE_DOWN_OFFSET,
		ELBOW_POLE_BACK_OFFSET + swingBoost
	)).Position

	local current = self._smoothedElbowPolePos[side]
	if not current then
		current = desired
	end
	local alpha = math.clamp(ELBOW_POLE_LERP_SPEED * dt, 0, 1)
	current = current:Lerp(desired, alpha)
	self._smoothedElbowPolePos[side] = current

	pole.WorldPosition = current
end

--- Neck IK for free-look: ChainRoot = UpperTorso, EndEffector = Head, so only the Neck
--- joint actually rotates (a chain of length 1) -- this deliberately does NOT reach down
--- into the spine, so a sharp look doesn't bend the whole upper body.
function IKLegController._buildHeadIK(self: IKLegControllerInstance)
	local upperTorso, head = self.UpperTorso, self.Head
	if not upperTorso or not head then
		return
	end

	local target = Instance.new("Attachment")
	target.Name = "HeadLookIKTarget"
	target.Parent = Workspace.Terrain
	self.HeadTarget = target

	local ik = Instance.new("IKControl")
	ik.Name = "HeadLookIK"
	ik.Type = Enum.IKControlType.Rotation
	ik.ChainRoot = upperTorso
	ik.EndEffector = head
	ik.Target = target
	ik.Weight = 0
	ik.SmoothTime = 0
	ik.Parent = self.Humanoid
	self.HeadIK = ik
end

-- === Future Vaulting/Climbing hooks ====================================

--- Explicitly plants a foot at `worldCFrame` (e.g. on a ledge mid-vault), overriding the
--- normal ground-following/gait behavior until ClearFootOverride is called. Weight snaps
--- to 1 immediately since an explicit placement call implies "put it here now."
function IKLegController.SetFootOverride(self: IKLegControllerInstance, side: FootSide, worldCFrame: CFrame)
	self._footOverride[side] = worldCFrame
end

function IKLegController.ClearFootOverride(self: IKLegControllerInstance, side: FootSide)
	self._footOverride[side] = nil
end

--- Same idea for hands -- a future climbing system calls this per-hand to place them on
--- handholds; this controller does not attempt to find handholds itself.
function IKLegController.SetHandOverride(self: IKLegControllerInstance, side: FootSide, worldCFrame: CFrame)
	self._handOverride[side] = worldCFrame
	local ik = self.HandIK[side]
	local target = self.HandTargets[side]
	if ik and target then
		target.WorldCFrame = worldCFrame
		ik.Weight = 1
	end
end

function IKLegController.ClearHandOverride(self: IKLegControllerInstance, side: FootSide)
	self._handOverride[side] = nil
	local ik = self.HandIK[side]
	if ik then
		ik.Weight = 0
	end
end

function IKLegController.SetEnabled(
	self: IKLegControllerInstance,
	enabled: boolean
)
	self._enabled = enabled

	if not enabled then
		-- Disable leg IK completely.
		for side, ik in pairs(self.LegIK) do
			ik.Weight = 0
			self._currentWeight[side] = 0
		end

		-- Disable hand IK completely.
		for side, ik in pairs(self.HandIK) do
			ik.Weight = 0

			if self._currentArmWeight then
				self._currentArmWeight[side] = 0
			end
		end

		-- Clear all procedural overrides so a ragdoll cannot retain
		-- an old planted foot or climbing hand target.
		self._footOverride.Left = nil
		self._footOverride.Right = nil

		self._handOverride.Left = nil
		self._handOverride.Right = nil

		-- Disable head IK.
		if self.HeadIK then
			self.HeadIK.Weight = 0
			self.HeadIK.Offset = CFrame.identity
			self._headWeight = 0
			self._headLeanRollDeg = 0
		end
	end
end

function IKLegController.ResetRagdollState(
	self: IKLegControllerInstance
)
	self._gaitDistance = 0

	self._footOverride.Left = nil
	self._footOverride.Right = nil

	self._handOverride.Left = nil
	self._handOverride.Right = nil

	for _, side in ipairs({ "Left", "Right" }) do
		if self._currentWeight then
			self._currentWeight[side] = 0
		end

		if self._currentArmWeight then
			self._currentArmWeight[side] = 0
		end

		if self._footState then
			self._footState[side] = "Planted"
		end

		if self._footStepT then
			self._footStepT[side] = 0
		end

		if self._footStepStart then
			self._footStepStart[side] = nil
		end

		if self._footPlantedCFrame then
			self._footPlantedCFrame[side] = nil
		end

		if self._smoothedFootTarget then
			self._smoothedFootTarget[side] = nil
		end

		if self._smoothedPolePos then
			self._smoothedPolePos[side] = nil
		end

		if self._smoothedArmTarget then
			self._smoothedArmTarget[side] = nil
		end

		if self._smoothedElbowPolePos then
			self._smoothedElbowPolePos[side] = nil
		end
	end

	if self._smoothedMoveDir then
		self._smoothedMoveDir = Vector3.zero
	end

	if self._smoothedStrideLength then
		self._smoothedStrideLength = nil
	end

	if self._lastPlanarSpeedForGait then
		self._lastPlanarSpeedForGait = 0
	end

	self._headWeight = 0
	self._headLeanRollDeg = 0

	if self.HeadIK then
		self.HeadIK.Weight = 0
		self.HeadIK.Offset = CFrame.identity
	end
end

function IKLegController._naturalHandWorldPosition(self, side)
	local sign = if side == "Left" then -1 else 1
	local torsoCF = (self.UpperTorso or self.LowerTorso).CFrame
	return (torsoCF * CFrame.new(sign * SHOULDER_WIDTH, -ARM_HANG_DOWN_OFFSET, -ARM_HANG_FORWARD_OFFSET)).Position
end

local function idlePoseFor(stance: string?)
	local def = stance and Stances[stance]
	return (def and def.IKIdlePose) or { FootPitchDegrees = 0, HandPitchDegrees = 0, SurfaceFollow = SURFACE_NORMAL_BLEND }
end

function IKLegController._handRestCFrame(self: IKLegControllerInstance, side: FootSide): CFrame
	local lowerArm = self.LowerArms[side]
	local position = self:_naturalHandWorldPosition(side) -- keep existing hang-point calc

	local sideSign = if side == "Left" then -1 else 1

	local rotation = lowerArm.CFrame.Rotation
		* CFrame.Angles(math.rad(HAND_LOCAL_PITCH_DEG), math.rad(sideSign * HAND_LOCAL_YAW_DEG), math.rad(HAND_LOCAL_ROLL_DEG))

	return rotation + position
end


function IKLegController._armGaitOffset(self, side, strideLength, reachAmount)
	local oppositeFoot = if side == "Left" then "Right" else "Left"
	local sideOffset = if oppositeFoot == "Left" then 0 else 0.5
	local phase = (self._gaitDistance / strideLength + sideOffset) % 1

	local halfReach = reachAmount / 2
	local foreAft: number
	if phase < 0.5 then
		local f = phase / 0.5
		local eased = f * f * (3 - 2 * f)
		foreAft = halfReach - eased * (halfReach * 2)
	else
		local f = (phase - 0.5) / 0.5
		local eased = f * f * (3 - 2 * f)
		foreAft = -halfReach + eased * (halfReach * 2)
	end

	local forwardFraction = if halfReach > 1e-4 then math.clamp(foreAft / halfReach, 0, 1) else 0

	local liftCurve = forwardFraction ^ 2.2
	local lift = liftCurve * ARM_LIFT_HEIGHT
	local pitch = sampleHandGaitPitch(phase)

	return foreAft, lift, pitch
end

function IKLegController._updateHandGait(self, side, dt, strideLength, reachAmount)
	local ik, target = self.HandIK[side], self.HandTargets[side]
	if not ik or not target then
		return
	end

	local restCFrame = self:_handRestCFrame(side)
	local foreAft, lift, pitchDeg = self:_armGaitOffset(side, strideLength, reachAmount)

	local forward = (self.UpperTorso or self.LowerTorso).CFrame.LookVector
	local desiredCFrame = (restCFrame + forward * foreAft + Vector3.new(0, lift, 0))
		* CFrame.Angles(math.rad(pitchDeg), 0, 0)

	local current = self._smoothedArmTarget[side] or target.WorldCFrame
	local posAlpha = math.clamp(ARM_POSITION_LERP * dt, 0, 1)
	local rotAlpha = math.clamp(ARM_ROTATION_LERP * dt, 0, 1)
	local newPos = current.Position:Lerp(desiredCFrame.Position, posAlpha)
	local newRot = current.Rotation:Lerp(desiredCFrame.Rotation, rotAlpha)
	current = newRot + newPos
	self._smoothedArmTarget[side] = current
	target.WorldCFrame = current

	self:_updateElbowPole(side, dt, foreAft)

	local alpha = math.clamp(ARM_WEIGHT_LERP_SPEED * dt, 0, 1)
	self._currentArmWeight[side] += (1 - self._currentArmWeight[side]) * alpha
	ik.Weight = self._currentArmWeight[side]
end

function IKLegController._updateHandIdle(self, side, dt)
	local ik, target = self.HandIK[side], self.HandTargets[side]
	if not ik or not target then
		return
	end

	local restCFrame = self:_handRestCFrame(side)
	local t = os.clock() * IDLE_ARM_SWAY_SPEED + self._idleSwayPhaseOffset[side]
	local sway = math.sin(t) * IDLE_ARM_SWAY_AMPLITUDE

	local forward = (self.UpperTorso or self.LowerTorso).CFrame.LookVector
	local desiredCFrame = (restCFrame + forward * sway)
		* CFrame.Angles(math.rad(HAND_PITCH_RELAXED), 0, 0)

	local current = self._smoothedArmTarget[side] or target.WorldCFrame
	local posAlpha = math.clamp(ARM_POSITION_LERP * dt, 0, 1)
	local newPos = current.Position:Lerp(desiredCFrame.Position, posAlpha)
	local newRot = current.Rotation:Lerp(desiredCFrame.Rotation, posAlpha)
	current = newRot + newPos
	self._smoothedArmTarget[side] = current
	target.WorldCFrame = current

	self:_updateElbowPole(side, dt, nil)

	local alpha = math.clamp(ARM_WEIGHT_LERP_SPEED * dt, 0, 1)
	self._currentArmWeight[side] += (IDLE_ARM_WEIGHT - self._currentArmWeight[side]) * alpha
	ik.Weight = self._currentArmWeight[side]
end

function IKLegController._updateHand(self, side, dt, grounded, stance, isWalking, strideLength, reachScale)
	local ik = self.HandIK[side]
	if not ik then
		return
	end
 
	-- An explicit SetHandOverride (future Vaulting/Climbing, Ch 2.6/16.3) always wins --
	-- SetHandOverride already snaps Weight to 1 and writes the target directly, so there's
	-- nothing to do here per-frame while one is active.
	if self._handOverride[side] then
		return
	end
 
	if not self._armSwingEnabled[side] or not grounded then
		local alpha = math.clamp(ARM_WEIGHT_LERP_SPEED * dt, 0, 1)
		self._currentArmWeight[side] += (0 - self._currentArmWeight[side]) * alpha
		ik.Weight = self._currentArmWeight[side]
		return
	end
 
	if isWalking and stance ~= "Crouching" and stance ~= "Prone" then
		self:_updateHandGait(side, dt, strideLength, reachScale)
	else
		self:_updateHandIdle(side, dt, stance)
	end
end

function IKLegController.SetArmSwingEnabled(self, enabled, side)
	if side then
		self._armSwingEnabled[side] = enabled
	else
		self._armSwingEnabled.Left = enabled
		self._armSwingEnabled.Right = enabled
	end
 
	if not enabled then
		local sides = if side then { side } else { "Left", "Right" }
		for _, s in ipairs(sides) do
			if not self._handOverride[s] then
				local ik = self.HandIK[s]
				if ik then
					ik.Weight = 0
				end
				self._currentArmWeight[s] = 0
			end
		end
	end
end


-- === Per-frame update ====================================================

function IKLegController._naturalFootWorldPosition(self: IKLegControllerInstance, side: FootSide): Vector3
	local sign = if side == "Left" then -1 else 1
	local rootCF = self.RootPart.CFrame
	-- Roblox keeps RootPart hovering HipHeight (+ leg length) above the floor via the
	-- Humanoid's own floor sensor, so "current HipHeight" already reflects Standing vs
	-- Crouching vs Prone (set server-side by CharacterController.Update, Ch 1.3/Ch 2.2) --
	-- we don't need to duplicate that squat-depth data here, just read it live.
	local downOffset = self.Humanoid.HipHeight + 2
	return (rootCF * CFrame.new(sign * HIP_WIDTH, -downOffset, 0)).Position
end

--- Returns (fore/aft offset ALONG moveDirWorld, vertical lift) for `side`'s foot at the
--- current gait phase. Phase is driven by distance traveled (self._gaitDistance), not
--- time, so cadence naturally scales with actual movement speed instead of shuffling at
--- a slow walk or moonwalking at a sprint.
---
--- First half of the cycle = STANCE: the foot is planted on the ground and slides from
--- ahead of the hip to behind it as the body passes over it (offset goes +half -> -half).
--- Second half = SWING: the foot lifts (sine arc) and carries from behind the hip back to
--- ahead of it, ready to plant again. Left/Right are 0.5 out of phase, giving the
--- alternating gait.
function IKLegController._gaitFootOffset(
	self: IKLegControllerInstance,
	side: FootSide,
	strideLength: number,
	reachAmount: number,
	liftScale: number
): (number, number, number)
	local sideOffset = if side == "Left" then 0 else 0.5
	local phase = (self._gaitDistance / strideLength + sideOffset) % 1
	local halfStride = reachAmount / 2

	local foreAft: number
	local lift: number

	local previousPhase = self._lastGaitPhase[side]
	if previousPhase > 0.75 and phase < 0.25 then
		local target = self.Targets[side]
		if target then
			self.FootPlantedEvent:Fire(side, target.WorldPosition, self.Character:GetAttribute("CombatStance"), self._lastPlanarSpeedForGait)
		end
	end
	self._lastGaitPhase[side] = phase

	if phase < 0.5 then
		local f = phase / 0.5
		local eased = f * f * (3 - 2 * f)
		foreAft = halfStride - eased * (halfStride * 2)
		lift = 0
	else
		local f = (phase - 0.5) / 0.5
		local liftFraction = math.sin((f ^ 0.7) * math.pi)
		foreAft = -halfStride + f * (halfStride * 2)
		lift = liftFraction * STEP_HEIGHT * liftScale
	end

	return foreAft, lift, sampleGaitPitch(phase)
end

--- `foreAftOffset`/`lift` come from the gait cycle when walking (nil/0 otherwise). Crouch
--- kneel pose ignores both, since it's a static pose rather than a walking gait.
function IKLegController._computeDesiredFootCFrame(
	self: IKLegControllerInstance,
	side: FootSide,
	natural: Vector3,
	stance: string?,
	foreAftOffset: number?,
	lift: number?,
	pitchDegrees: number?
): (CFrame?, boolean)
	local override = self._footOverride[side]
	if override then
		return override, true
	end

	if stance == "Crouching" then
		local sign = if side == "Left" then -1 else 1
		-- The kneeling leg drops behind/under; the OTHER leg plants forward -- together
		-- these give a proper one-knee-down pose instead of two same-height feet.
		local localOffset = if side == KNEELING_LEG then KNEEL_FOOT_LOCAL_OFFSET else KNEEL_FRONT_FOOT_LOCAL_OFFSET
		self._currentForeAft[side] = -localOffset.Z
		local desired = self.LowerTorso.CFrame * CFrame.new(sign * HIP_WIDTH, 0, 0) * localOffset

		local origin = desired.Position + Vector3.new(0, RAY_UP, 0)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -(RAY_UP + RAY_DOWN), 0), self._raycastParams)

		local baseCFrame: CFrame
		if hit then
			local groundedPos = hit.Position + Vector3.new(0, FOOT_GROUND_PAD, 0)
			baseCFrame = desired.Rotation + groundedPos
		else
			baseCFrame = desired
		end

		if pitchDegrees and pitchDegrees ~= 0 then
			-- Same local ankle-tilt rotation the general path already applies below —
			-- clamp it so a stance config typo can't fold the ankle past what's physical.
			local clampedPitch = math.clamp(pitchDegrees, -MAX_FOOT_PITCH_DEG, MAX_FOOT_PITCH_DEG)
			baseCFrame = baseCFrame * CFrame.Angles(math.rad(clampedPitch), 0, 0)
    	end

		return baseCFrame, true
	end

	local samplePosition = natural
	local origin = samplePosition + Vector3.new(0, RAY_UP, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(RAY_UP + RAY_DOWN), 0), self._raycastParams)
	if not hit or math.abs(hit.Position.Y - samplePosition.Y) > MAX_FOOT_REACH then
		return nil, false
	end

	local blendedUp = Vector3.new(0, 1, 0):Lerp(hit.Normal, SURFACE_NORMAL_BLEND)
	if blendedUp.Magnitude < 1e-4 then blendedUp = Vector3.yAxis end
	blendedUp = blendedUp.Unit
	local forward = self.RootPart.CFrame.LookVector
	local right = forward:Cross(blendedUp)
	if right.Magnitude < 1e-4 then right = self.RootPart.CFrame.RightVector end
	right = right.Unit
	local correctedForward = blendedUp:Cross(right).Unit
	local position = hit.Position + Vector3.new(0, FOOT_GROUND_PAD + (lift or 0), 0)

	local baseCFrame = CFrame.fromMatrix(position, right, blendedUp, -correctedForward)
	if pitchDegrees and pitchDegrees ~= 0 then
		-- Local rotation around the foot's own right axis == ankle-style tilt (toe up/down).
		baseCFrame = baseCFrame * CFrame.Angles(math.rad(pitchDegrees), 0, 0)
	end

	return baseCFrame, true
end

--- Walking-gait path: called every frame while isWalking is true. Positions the foot
--- directly from the gait cycle (no drift threshold, no snap) -- this is what gives
--- continuous, natural-looking thigh swing instead of the old drag-then-correct behavior.
function IKLegController._updateFootGait(self, side, dt, stance, moveDirWorld, strideLength, reachAmount, liftScale)
	local ik, target = self.LegIK[side], self.Targets[side]
	if not ik or not target then return end

	local alpha = math.clamp(WEIGHT_LERP_SPEED * dt, 0, 1)
	local natural = self:_naturalFootWorldPosition(side)
	local foreAftOffset, lift, pitchDegrees = self:_gaitFootOffset(side, strideLength, reachAmount, liftScale)

	self._currentLift[side] = lift
	self._currentForeAft[side] = foreAftOffset
	local sampledNatural = natural + moveDirWorld * foreAftOffset

	local desired, ok = self:_computeDesiredFootCFrame(side, sampledNatural, stance, foreAftOffset, lift, pitchDegrees)
	if ok and desired then
		local current = self._smoothedFootTarget[side]
		if not current then
			current = target.WorldCFrame
		end
		
		local posAlpha = math.clamp(FOOT_POSITION_LERP * dt, 0, 1)
		local rotAlpha = math.clamp(FOOT_ROTATION_LERP * dt, 0, 1)

		local newPosition = current.Position:Lerp(desired.Position, posAlpha)
		local newRotation = current.Rotation:Lerp(desired.Rotation, rotAlpha)
		current = newRotation + newPosition

		self._smoothedFootTarget[side] = current
		target.WorldCFrame = current
	end

	self._footPlantedCFrame[side] = nil
	self._footState[side] = "Planted"

	self._currentWeight[side] += ((if ok then 1 else 0) - self._currentWeight[side]) * alpha
	ik.Weight = self._currentWeight[side]
end

--- Idle / turning-in-place path (unchanged from before): drift-triggered corrective
--- steps, so a foot smoothly catches up if the body rotates or repositions while
--- standing still, instead of the foot instantly snapping.
function IKLegController._updateFootIdle(self: IKLegControllerInstance, side: FootSide, dt: number, stance: string?)
	local ik, target = self.LegIK[side], self.Targets[side]
	if not ik or not target then return end

	local pose = idlePoseFor(stance)
	local alpha = math.clamp(WEIGHT_LERP_SPEED * dt, 0, 1)
	local natural = self:_naturalFootWorldPosition(side)
	local desired, ok = self:_computeDesiredFootCFrame(side, natural, stance, nil, 0, pose.FootPitchDegrees)
	if not ok or not desired then
		self._currentWeight[side] += (0 - self._currentWeight[side]) * alpha
		ik.Weight = self._currentWeight[side]
		return
	end

	if self._footState[side] == "Stepping" then
		local t = math.min(1, self._footStepT[side] + dt / (STEP_DURATION_BY_STANCE[stance] or STEP_DURATION))
		self._footStepT[side] = t
		local eased = t * t * (3 - 2 * t) -- smoothstep
		local startCF = self._footStepStart[side] :: CFrame
		local pos = startCF.Position:Lerp(desired.Position, eased) + Vector3.new(0, math.sin(t * math.pi) * STEP_HEIGHT, 0)
		target.WorldCFrame = startCF.Rotation:Lerp(desired.Rotation, eased) + pos
		if t >= 1 then
			self._footState[side] = "Planted"
			self._currentLift[side] = 0
			self._footPlantedCFrame[side] = desired
			self.FootPlantedEvent:Fire(side, target.WorldPosition, stance, self._lastPlanarSpeedForGait)
		end
	else
		local plantedCF = self._footPlantedCFrame[side]
		local otherSide: FootSide = if side == "Left" then "Right" else "Left"
		local otherStepping = self._footState[otherSide] == "Stepping"

		if not plantedCF then
			target.WorldCFrame = desired
			self._footPlantedCFrame[side] = desired
		elseif (plantedCF.Position - desired.Position).Magnitude > (STEP_TRIGGER_DISTANCE_BY_STANCE[stance] or STEP_TRIGGER_DISTANCE) and not otherStepping then
			-- Only ONE foot steps at a time -- this is what gives you an alternating
			-- gait instead of both feet sliding together.
			self._footState[side] = "Stepping"
			self._footStepT[side] = 0
			self._footStepStart[side] = plantedCF
		else
			-- Held: keep the foot's xz footprint locked, just correct height for terrain noise.
			local heldPos = Vector3.new(plantedCF.Position.X, desired.Position.Y, plantedCF.Position.Z)
			target.WorldCFrame = plantedCF.Rotation + heldPos
		end
	end

	self._currentWeight[side] += (1 - self._currentWeight[side]) * alpha
	ik.Weight = self._currentWeight[side]
end

function IKLegController._updateFoot(self, side, dt, grounded, stance, isWalking, moveDirWorld, strideLength, reachAmount, liftScale)
	local ik = self.LegIK[side]
	if not ik then return end

	if not grounded then
		local alpha = math.clamp(WEIGHT_LERP_SPEED * dt, 0, 1)
		self._currentWeight[side] += (0 - self._currentWeight[side]) * alpha
		ik.Weight = self._currentWeight[side]
		self._footState[side] = "Planted"
		self._footPlantedCFrame[side] = nil
		self._currentLift[side] = 0
		self._smoothedFootTarget.Left = nil
		self._smoothedFootTarget.Right = nil
		return
	end

	if self._footOverride[side] then
		self:_updateFootIdle(side, dt, stance)
		self._currentLift[side] = 0
		return
	end

	if isWalking and stance ~= "Crouching" then
		self:_updateFootGait(side, dt, stance, moveDirWorld, strideLength, reachAmount, liftScale)
	else
		self:_updateFootIdle(side, dt, stance)
		self._currentLift[side] = 0
	end
end

--- Engages/disengages and steers the Neck LookAt IK toward `worldLookDirection`
--- (typically the camera's LookVector). Never falls back to a hardcoded forward pose --
--- past LookIKTuning.Look.BehindDisengageDegrees the tracked yaw REVERSES back toward
--- center instead (LookIKMath.FoldYawDegrees), same math TorsoTiltController's Waist/Root
--- use, so all three joints agree on where "the character is looking."
---
--- Also applies head lean-tilt via IKControl.Offset -- a constant local roll layered on
--- TOP of the LookAt solve, independent of whether the head is currently tracking a look
--- direction. This is the only way to get a genuine head roll during a lean: Neck itself
--- can never be written directly while it's inside this active IK chain (see file header).
--- Reads the replicated CombatLean Attribute directly (same pattern Update() already uses
--- for CombatStance), so no extra plumbing is needed from the caller.
---
--- CALLER CONTRACT (see IKVisualsBootstrap.client.lua): for the LOCAL player, pass the
--- live camera.CFrame.LookVector directly (zero latency). For REMOTE players, this
--- controller has no access to their camera, so the bootstrap script instead reads a
--- replicated `LookDirection` Vector3 Attribute that the owning client sets on its own
--- character each frame.
function IKLegController.UpdateHeadLook(self: IKLegControllerInstance, dt: number, worldLookDirection: Vector3?, bodyClearance: number?)
	local ik, target = self.HeadIK, self.HeadTarget
	local head = self.Head
	if not ik or not target or not head or not self._enabled then
		return
	end

	local alpha = math.clamp(WEIGHT_LERP_SPEED * dt, 0, 1)
	local desiredWeight = 0
	-- Keep these local variables scoped correctly so the entire function can read/write them
	local clampedYaw, clampedPitch = 0, 0
	local rootCF = self.RootPart.CFrame

	local clearance = bodyClearance or 1

	if worldLookDirection and worldLookDirection.Magnitude > 0.01 then
		local flatDesired = Vector3.new(worldLookDirection.X, 0, worldLookDirection.Z)
		local flatForward = Vector3.new(rootCF.LookVector.X, 0, rootCF.LookVector.Z)

		if flatDesired.Magnitude > 0.01 and flatForward.Magnitude > 0.01 then
			local angleDeg = math.deg(math.acos(math.clamp(flatDesired.Unit:Dot(flatForward.Unit), -1, 1)))
			desiredWeight = if angleDeg > LookIKTuning.Head.EngageAngleDegrees then 1 else 0
		end

		if desiredWeight > 0 then
			local yawDeg, pitchDeg, yawReliable = LookIKMath.SignedYawPitchDegrees(rootCF, worldLookDirection)
			local foldedYaw: number
			if yawReliable then
				foldedYaw = LookIKMath.FoldYawDegrees(yawDeg, LookIKTuning.Look.BehindDisengageDegrees)
				self._lastReliableYawDeg = foldedYaw
			else
				foldedYaw = self._lastReliableYawDeg
			end
			-- FIXED: Removed the 'local' keyword here so the outer scope variables are updated
			clampedYaw = math.clamp(foldedYaw, -LookIKTuning.Head.MaxYawDegrees, LookIKTuning.Head.MaxYawDegrees) * clearance
			clampedPitch = math.clamp(pitchDeg, -LookIKTuning.Head.MaxPitchDegrees, LookIKTuning.Head.MaxPitchDegrees) * clearance
		end
	end

	self._headWeight += (desiredWeight - self._headWeight) * alpha
	ik.Weight = self._headWeight

	-- Lean head-tilt calculation
	local stanceName = self.Character:GetAttribute("CombatStance")
	local stanceKey = if typeof(stanceName) == "string" then stanceName else "Standing"
	local family = LookIKTuning.Stances[stanceKey] or LookIKTuning.Stances.Standing

	local leanAttr = self.Character:GetAttribute("CombatLean")
	local leanState = if typeof(leanAttr) == "string" then leanAttr else "None"
	local leanSign = if leanState == "Left" then 1 elseif leanState == "Right" then -1 else 0

	local targetHeadTiltDeg = leanSign * -LookIKTuning.Lean.HeadTiltDegrees * family.LeanRollMultiplier
	local leanAlpha = math.clamp(LookIKTuning.Lean.LerpSpeed * dt, 0, 1)
	self._headLeanRollDeg += (targetHeadTiltDeg - self._headLeanRollDeg) * leanAlpha

	local baseTorsoRoll = leanSign * LookIKTuning.Lean.RootRollDegrees
	local totalTorsoLeanRollDeg = baseTorsoRoll + (baseTorsoRoll * LookIKTuning.Lean.WaistFollowFraction)

	if not self._currentTorsoTrackRollDeg then
		self._currentTorsoTrackRollDeg = 0
	end
	self._currentTorsoTrackRollDeg += (totalTorsoLeanRollDeg - self._currentTorsoTrackRollDeg) * leanAlpha

	local combinedRollDeg = (self._currentTorsoTrackRollDeg + self._headLeanRollDeg) * clearance
	local baseRotation = rootCF - rootCF.Position

	--print("Target Head Tilt:", targetHeadTiltDeg, " | Current Head Tilt:", self._headLeanRollDeg, " | Roll Multiplier:", family.LeanRollMultiplier, " | Head Tilt Degrees:", LookIKTuning.Lean.HeadTiltDegrees, " | MathRad:", math.rad(self._headLeanRollDeg))

	local baseRotation = rootCF - rootCF.Position 
	target.WorldCFrame = CFrame.new(head.Position)
			* baseRotation
			* CFrame.Angles(math.rad(clampedPitch), math.rad(clampedYaw), math.rad(combinedRollDeg))
end

--- Call once per Heartbeat from the bootstrap script. `distanceFromCamera` drives the
--- update-frequency throttle (Ch 1.6).
function IKLegController.Update(self: IKLegControllerInstance, dt: number, distanceFromCamera: number)
	if not self._enabled then return end

	local stance = self.Character:GetAttribute("CombatStance")
	local state = self.Humanoid:GetState()
	local grounded =
		typeof(stance) == "string"
		and GROUNDED_STANCES[stance] == true
		and stance ~= "Prone"
		and state ~= Enum.HumanoidStateType.Freefall
		and state ~= Enum.HumanoidStateType.Jumping
		and state ~= Enum.HumanoidStateType.Swimming
		and state ~= Enum.HumanoidStateType.Ragdoll
		and self.Humanoid.Health > 0

	self._frameCounter += 1
	local shouldSample = true
	if distanceFromCamera > FAR_DISTANCE then
		shouldSample = (self._frameCounter % (FAR_UPDATE_EVERY_N_FRAMES * 2) == 0)
	elseif distanceFromCamera > NEAR_DISTANCE then
		shouldSample = (self._frameCounter % FAR_UPDATE_EVERY_N_FRAMES == 0)
	end
	if not shouldSample and not (self._footOverride.Left or self._footOverride.Right) then
		return
	end

	local moveDirInput = self.Humanoid.MoveDirection
	local flatInputDir = Vector3.new(moveDirInput.X, 0, moveDirInput.Z)
	local hasInputDir = flatInputDir.Magnitude > 0.05

	local velocity = self.RootPart.AssemblyLinearVelocity
	local planarVel = Vector3.new(velocity.X, 0, velocity.Z)
	local planarSpeed = planarVel.Magnitude
	self._lastPlanarSpeedForGait = planarSpeed

	local cadenceHz = cadenceHzFor(planarSpeed, stance)
	local rawStrideLength = math.max(planarSpeed / cadenceHz, 0.5)

	local armReachScale = ((typeof(stance) == "string" and ARM_REACH_BY_STANCE[stance]) or 1.0) * speedReachMultiplier(planarSpeed)

	local desiredMoveDir =
		if hasInputDir then flatInputDir.Unit
		elseif planarSpeed > 0.05 then planarVel.Unit
		else self.RootPart.CFrame.LookVector

	local alpha = math.clamp(MOVE_DIRECTION_LERP * dt,0,1)

	self._smoothedMoveDir =
		self._smoothedMoveDir:Lerp(desiredMoveDir,alpha)

	if self._smoothedMoveDir.Magnitude > 0 then
		self._smoothedMoveDir =
			self._smoothedMoveDir.Unit
	end

	local moveDirWorld = self._smoothedMoveDir


	self._smoothedStrideLength = self._smoothedStrideLength or rawStrideLength
	local strideLerpAlpha = math.clamp(STRIDE_LENGTH_LERP_SPEED * dt, 0, 1)
	self._smoothedStrideLength += (rawStrideLength - self._smoothedStrideLength) * strideLerpAlpha
	local strideLength = self._smoothedStrideLength

	local liftScale = (typeof(stance) == "string" and LIFT_SCALE_BY_STANCE[stance]) or 1.0
	local legReachScale = (typeof(stance) == "string" and REACH_SCALE_BY_STANCE[stance]) or 1.0
	local rawReachAmount = strideLength * legReachScale
	local maxReach = math.min(self:_maxLegReach("Left"), self:_maxLegReach("Right"))
	local reachAmount = math.min(rawReachAmount, maxReach)
	local isWalking = grounded and planarSpeed > GAIT_MOVE_THRESHOLD and stance ~= "Crouching"

	local armReachScale = ((typeof(stance) == "string" and ARM_REACH_BY_STANCE[stance]) or 1.0) * speedReachMultiplier(planarSpeed)
	local rawArmReach = ARM_REACH * armReachScale
	local maxArmReach = math.min(self:_maxArmReach("Left"), self:_maxArmReach("Right"))
	local armReachAmount = math.min(rawArmReach, maxArmReach)

	if isWalking then
		self._gaitDistance = (self._gaitDistance + planarSpeed * dt) % strideLength
	end

	self:_updateFoot("Left", dt, grounded, stance, isWalking, moveDirWorld, strideLength, reachAmount, liftScale)
	self:_updateFoot("Right", dt, grounded, stance, isWalking, moveDirWorld, strideLength, reachAmount, liftScale)
	self:_updateKneePole("Left", dt)
	self:_updateKneePole("Right", dt)

	self:_updateHand("Left", dt, grounded, stance, isWalking, strideLength, armReachAmount)
	self:_updateHand("Right", dt, grounded, stance, isWalking, strideLength, armReachAmount)
end

function IKLegController.Destroy(self: IKLegControllerInstance)
	for _, pole in pairs(self.Poles) do
		pole:Destroy()
	end
	for _, target in pairs(self.Targets) do
		target:Destroy()
	end
	for _, target in pairs(self.HandTargets) do
		target:Destroy()
	end
	for _, ik in pairs(self.LegIK) do
		ik:Destroy()
	end
	for _, ik in pairs(self.HandIK) do
		ik:Destroy()
	end
	for _, pole in pairs(self.ElbowPoles) do
		pole:Destroy()
	end
	if self.HeadTarget then
		self.HeadTarget:Destroy()
	end
	if self.HeadIK then
		self.HeadIK:Destroy()
	end
end

return IKLegController
