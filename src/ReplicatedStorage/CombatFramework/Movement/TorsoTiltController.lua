--!strict
--[[
	TorsoTiltController.lua  (Ch 2.9 Camera / Ch 9 Animation Framework extension)

	SCOPE: this module owns the Waist (UpperTorso) and Root (LowerTorso) Motor6D twist. It
	never touches Head/Neck -- Head look-AT and head lean-tilt are exclusively
	IKLegController's job (native IKControl LookAt + Offset), because Neck is the sole
	joint inside IKLegController's HeadLookIK chain and Roblox LOCKS C0 for any Motor6D
	inside an active IKControl chain -- a direct write throws "Unable to assign property
	C0. Property is read only." This isn't a tuning choice, it's a hard engine constraint.

	REVERSAL, NOT DISENGAGE (LookIKMath.lua): the raw yaw delta is folded through
	LookIKMath.FoldYawDegrees before anything else touches it. Past
	LookIKTuning.Look.BehindDisengageDegrees off body-forward, the tracked yaw swings back
	toward center instead of growing further or snapping to a hardcoded forward pose --
	same math Head uses, so all three joints agree.

	FIVE layers, all driven by LookIKTuning.lua:

	1. YAW LOOK-FOLLOW, split independently across Waist AND Root: each joint has its own
	   MaxYawTiltDegrees / YawFollowFraction (`family.Waist` / `family.Root`), so the
	   lower body can (optionally) follow a smaller amount than the upper body instead of
	   only ever twisting at the waist. Gated by IdleOnly per stance exactly as before.
	2. PITCH LOOK-FOLLOW, same split, same gating.
	3. STANCE FORWARD TILT (Waist pitch, always-on) -- now SMOOTHED via
	   ForwardTiltLerpSpeed instead of snapping the instant the stance attribute changes.
	4. LEAN ROLL + LATERAL SHIFT (Root + Waist, always-on, not gated by moving/idle): Root
	   gets the full roll AND a sideways translate (Lean.RootTranslateStuds, scaled by
	   the current stance's LeanTranslateMultiplier); Waist follows a fraction of the
	   roll only (translating the waist too would look like the whole torso sliding
	   sideways rather than a hip-led lean).
	5. Head lean-tilt lives in IKLegController now (IKControl.Offset), not here.

	CAUTION: Root (HumanoidRootPart -> LowerTorso) is the joint whose CHILDREN include the
	hip Motor6Ds the legs hang off of, but it is NOT what Humanoid reads for
	facing/pathing/AutoRotate -- that's HumanoidRootPart's own CFrame, which this module
	never touches. Adding yaw/pitch to Root therefore doesn't fight AutoRotate, and
	IKLegController's leg IK (ChainRoot = UpperLeg) re-solves foot placement in world
	space every frame regardless of upstream joint rotation, so it self-corrects rather
	than fighting this. Still: keep Root's caps modest (see LookIKTuning) and verify feel
	in Studio before pushing them up -- this is new territory for this module.
]]

local LookIKTuning = require(script.Parent.Parent.Shared.Config.LookIKTuning)
local LookIKMath = require(script.Parent.Parent.Shared.LookIKMath)
local LocalBodyClearance = require(script.Parent.Parent.Shared.LocalBodyClearance)

local CLEARANCE_CHECK_INTERVAL = 0.05    -- ~20Hz while there's any nonzero swing intent
local CLEARANCE_MARGIN = 1.7             -- studs kept clear between swing extreme and the wall
local CLEARANCE_MIN_OFFSET = 0.05        -- studs; below this desired swing, skip the ray entirely (nothing to clamp)
local HEAD_PIVOT_RADIUS = 2.0
local CLEARANCE_LERP_SPEED = 14          -- eases each stored fraction toward its newest sample so a
                                          -- boundary flip (clear <-> blocked between two samples) is a
                                          -- quick ease rather than an instant snap


local TorsoTiltController = {}
TorsoTiltController.__index = TorsoTiltController

export type TorsoTiltControllerInstance = typeof(setmetatable(
	{} :: {
		Character: Model,
		RootPart: BasePart,
		Head: BasePart,
		Waist: Motor6D,
		Root: Motor6D?,
		_waistRestC0: CFrame,
		_rootRestC0: CFrame,
		_enabled: boolean,
		_currentYawTiltDeg: number,
		_currentPitchTiltDeg: number,
		_currentRootYawTiltDeg: number,
		_currentRootPitchTiltDeg: number,
		_currentBaseForwardTiltDeg: number,
		_currentLeanRollDeg: number,
		_currentLeanTranslateStuds: number,
		_currentLeanHeight: number,
		_rawYawDeltaDeg: number,
		_rawPitchDeltaDeg: number,
		_isLocalPlayer: boolean,
		_raycastParams: RaycastParams,

		_yawClearanceFraction: number,
		_pitchClearanceFraction: number,
		_lateralClearanceFraction: number,
		_clearanceCheckAccum: number,

	},
	TorsoTiltController
))

function TorsoTiltController.new(character: Model, isLocalPlayer: boolean): TorsoTiltControllerInstance?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character:FindFirstChild("Head") :: BasePart?
	local upperTorso = character:FindFirstChild("UpperTorso") :: BasePart?
	local lowerTorso = character:FindFirstChild("LowerTorso") :: BasePart?
	local waist = upperTorso and upperTorso:FindFirstChild("Waist") :: Motor6D?
	local root = lowerTorso and lowerTorso:FindFirstChild("Root") :: Motor6D?

	if not (rootPart and upperTorso and head and waist) then
		return nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	return setmetatable({
		Character = character,
		RootPart = rootPart :: BasePart,
		Head = head :: BasePart,
		Waist = waist :: Motor6D,
		Root = root,
		_waistRestC0 = (waist :: Motor6D).C0,
		_rootRestC0 = if root then root.C0 else CFrame.identity,
		_enabled = true,
		_currentYawTiltDeg = 0,
		_currentPitchTiltDeg = 0,
		_currentRootYawTiltDeg = 0,
		_currentRootPitchTiltDeg = 0,
		_currentBaseForwardTiltDeg = 0,
		_currentLeanRollDeg = 0,
		_currentLeanTranslateStuds = 0,
		_currentLeanHeight = 0,
		_rawYawDeltaDeg = 0,
		_rawPitchDeltaDeg = 0,
		_isLocalPlayer = isLocalPlayer,
		_raycastParams = raycastParams,

		_yawClearanceFraction = 1,
		_pitchClearanceFraction = 1,
		_lateralClearanceFraction = 1,
		_clearanceCheckAccum = 0,

	}, TorsoTiltController) :: any
end

--- Folded yaw delta in degrees (positive = look direction right of body facing, already
--- passed through LookIKMath.FoldYawDegrees -- see file header). Zero whenever the
--- look-follow behavior isn't currently engaged. A future turn-in-place system reads
--- this to decide when to actually rotate the root.
function TorsoTiltController.GetRawLookDelta(self: TorsoTiltControllerInstance): number
	return self._rawYawDeltaDeg
end


--- Same idea on the pitch axis (never folded -- see file header).
function TorsoTiltController.GetRawPitchDelta(self: TorsoTiltControllerInstance): number
	return self._rawPitchDeltaDeg
end

--- Casts a single ray from `headPosition` toward `candidateHeadPosition` (measured from
--- `restHeadPosition`) and returns how much of that swing is actually clear, 0..1.
--- Shared by all three axis samples in _updateBodyClearance so the "cast toward the
--- desired offset, clamp to the hit distance minus margin" logic only lives in one place.

local wireframe = Instance.new("WireframeHandleAdornment")
wireframe.Parent = Workspace
wireframe.Adornee = Workspace
wireframe.AlwaysOnTop = true
wireframe.Color3 = Color3.fromRGB(255, 255, 255) -- Default color fallback
wireframe.AdornCullingMode = Enum.AdornCullingMode.Never -- Ensure it stays visib

function TorsoTiltController._sampleAxisClearance(
	self: TorsoTiltControllerInstance,
	restHeadPosition: Vector3,
	candidateHeadPosition: Vector3
): number
	local desiredOffset = candidateHeadPosition - restHeadPosition
	local desiredMagnitude = desiredOffset.Magnitude
	if desiredMagnitude < CLEARANCE_MIN_OFFSET then
		return 1
	end
 
	local direction = desiredOffset.Unit
	local checkDistance = desiredMagnitude + CLEARANCE_MARGIN
 
	local hit = Workspace:Raycast(restHeadPosition, direction * checkDistance, self._raycastParams)

	wireframe:Clear()

	wireframe:AddLine(restHeadPosition, restHeadPosition + direction * checkDistance, Color3.fromRGB(255, 255, 255)) -- White line for raycast
	
	if hit then
		return math.clamp((hit.Distance - CLEARANCE_MARGIN) / desiredMagnitude, 0, 1)
	end
	return 1
end


function TorsoTiltController._updateBodyClearance(
	self: TorsoTiltControllerInstance,
	dt: number,
	targetLeanRoll: number,
	targetLeanTranslate: number,
	targetLeanHeight: number,
	targetWaistYaw: number,
	targetWaistPitch: number,
	targetRootYaw: number,
	targetRootPitch: number
): (number, number, number)
	local head = self.Head
	if not head then
		return 1, 1, 1
	end
 
	local combinedYawDeg = targetWaistYaw + targetRootYaw
	-- Folds in the CURRENT smoothed stance forward tilt, not just the look-follow pitch.
	-- Forward tilt used to be entirely outside this check ("always-on, not gated"), which
	-- meant a stance's baked-in lean (Crouching/Prone especially) plus a look-down on top
	-- of it only ever got tested against the look-down component alone -- the tilt itself
	-- could walk straight through a wall. One frame of lag on the tilt term (it's read
	-- before this tick's forward-tilt smoothing runs, further down in Update) is fine for
	-- a 20Hz-throttled check.
	local combinedPitchDeg = targetWaistPitch + targetRootPitch + self._currentBaseForwardTiltDeg
 
	local rootCF = self.RootPart.CFrame
	local restHeadPosition = rootCF.Position + rootCF.UpVector * HEAD_PIVOT_RADIUS
 
	-- Each candidate isolates ONE axis of motion only.
	local yawCandidateCF = rootCF
		* CFrame.Angles(0, math.rad(combinedYawDeg), 0)
		* CFrame.new(0, HEAD_PIVOT_RADIUS, 0)
	local pitchCandidateCF = rootCF
		* CFrame.Angles(math.rad(combinedPitchDeg), 0, 0)
		* CFrame.new(0, HEAD_PIVOT_RADIUS, 0)
	local lateralCandidateCF = rootCF
		* CFrame.new(targetLeanTranslate, targetLeanHeight, 0)
		* CFrame.Angles(0, 0, math.rad(targetLeanRoll))
		* CFrame.new(0, HEAD_PIVOT_RADIUS, 0)
 
	local yawMagnitude = (yawCandidateCF.Position - restHeadPosition).Magnitude
	local pitchMagnitude = (pitchCandidateCF.Position - restHeadPosition).Magnitude
	local lateralMagnitude = (lateralCandidateCF.Position - restHeadPosition).Magnitude
 
	-- Nothing swinging on any axis this tick: skip all three rays and reset the throttle
	-- so the next real swing (on any axis) gets a fresh sample immediately instead of
	-- reusing a stale one from before things went idle.
	if yawMagnitude < CLEARANCE_MIN_OFFSET and pitchMagnitude < CLEARANCE_MIN_OFFSET and lateralMagnitude < CLEARANCE_MIN_OFFSET then
		self._yawClearanceFraction = 1
		self._pitchClearanceFraction = 1
		self._lateralClearanceFraction = 1
		self._clearanceCheckAccum = 0
		if self._isLocalPlayer then
			LocalBodyClearance.Yaw = 1
			LocalBodyClearance.Pitch = 1
			LocalBodyClearance.Lateral = 1
		end
		return 1, 1, 1
	end
 
	self._clearanceCheckAccum += dt
	if self._clearanceCheckAccum < CLEARANCE_CHECK_INTERVAL then
		-- Reuse last per-axis sample; smoothing downstream absorbs the gap.
		return self._yawClearanceFraction, self._pitchClearanceFraction, self._lateralClearanceFraction
	end
	self._clearanceCheckAccum = 0
 
	local sampledYaw = if yawMagnitude >= CLEARANCE_MIN_OFFSET
		then self:_sampleAxisClearance(restHeadPosition, yawCandidateCF.Position)
		else 1
	local sampledPitch = if pitchMagnitude >= CLEARANCE_MIN_OFFSET
		then self:_sampleAxisClearance(restHeadPosition, pitchCandidateCF.Position)
		else 1
	local sampledLateral = if lateralMagnitude >= CLEARANCE_MIN_OFFSET
		then self:_sampleAxisClearance(restHeadPosition, lateralCandidateCF.Position)
		else 1
 
	-- Ease the stored fraction toward the new sample instead of snapping to it. Fixing
	-- the ray's origin (above) removes the feedback loop that caused outright spamming
	-- near a boundary; this smoothing is the extra guard against a single legitimate
	-- flip (e.g. a moving character's rest position crossing the clear/blocked line
	-- exactly between two 20Hz samples) reading as a visible pop.
	local clearanceAlpha = math.clamp(CLEARANCE_LERP_SPEED * CLEARANCE_CHECK_INTERVAL, 0, 1)
	self._yawClearanceFraction += (sampledYaw - self._yawClearanceFraction) * clearanceAlpha
	self._pitchClearanceFraction += (sampledPitch - self._pitchClearanceFraction) * clearanceAlpha
	self._lateralClearanceFraction += (sampledLateral - self._lateralClearanceFraction) * clearanceAlpha
 
	if self._isLocalPlayer then
		LocalBodyClearance.Yaw = self._yawClearanceFraction
		LocalBodyClearance.Pitch = self._pitchClearanceFraction
		LocalBodyClearance.Lateral = self._lateralClearanceFraction
	end
 
	return self._yawClearanceFraction, self._pitchClearanceFraction, self._lateralClearanceFraction
end


--- Exposes this tick's clearance fraction so IKLegController's head-look (a separate
--- controller, sharing the same character) can scale its own yaw/pitch/roll clamp by the
--- same wall check instead of casting a second ray for the same thing.
function TorsoTiltController.GetBodyClearance(self: TorsoTiltControllerInstance): number
	return math.min(self._yawClearanceFraction, self._pitchClearanceFraction, self._lateralClearanceFraction)
end

function TorsoTiltController.GetYawClearance(self: TorsoTiltControllerInstance): number
	return self._yawClearanceFraction
end
 
function TorsoTiltController.GetPitchClearance(self: TorsoTiltControllerInstance): number
	return self._pitchClearanceFraction
end
 
function TorsoTiltController.GetLateralClearance(self: TorsoTiltControllerInstance): number
	return self._lateralClearanceFraction
end


--- Disable while ragdolled (mirrors IKLegController:SetEnabled) so this doesn't fight
--- ragdoll physics or its own rope-target IKControls. Snaps back to rest immediately.
function TorsoTiltController.SetEnabled(self: TorsoTiltControllerInstance, enabled: boolean)
	self._enabled = enabled
	if not enabled then
		self._currentYawTiltDeg = 0
		self._currentPitchTiltDeg = 0
		self._currentRootYawTiltDeg = 0
		self._currentRootPitchTiltDeg = 0
		self._currentBaseForwardTiltDeg = 0
		self._currentLeanRollDeg = 0
		self._currentLeanTranslateStuds = 0
		self._currentLeanHeight = 0
		self._rawYawDeltaDeg = 0
		self._rawPitchDeltaDeg = 0
		self._yawClearanceFraction = 1
		self._pitchClearanceFraction = 1
		self._lateralClearanceFraction = 1
		self._clearanceCheckAccum = 0
		if self._isLocalPlayer then
			LocalBodyClearance.Yaw = 1
			LocalBodyClearance.Pitch = 1
			LocalBodyClearance.Lateral = 1
		end
		self.Waist.C0 = self._waistRestC0
		if self.Root then
			self.Root.C0 = self._rootRestC0
		end
	end
end



--- worldLookDirection: the same value IKVisualsBootstrap already computes per-character
---                      (live camera for local, replicated LookDirection attribute for
---                      everyone else) and feeds into IKLegController.UpdateHeadLook.
--- leanState: "None" | "Left" | "Right" -- read from the replicated CombatLean Attribute.
function TorsoTiltController.Update(
	self: TorsoTiltControllerInstance,
	dt: number,
	isMoving: boolean,
	worldLookDirection: Vector3?,
	leanState: string?
)
	if not self._enabled then
		return
	end
 
	local stanceName = self.Character:GetAttribute("CombatStance")
	local stanceKey = if typeof(stanceName) == "string" then stanceName else "Standing"
	local family = LookIKTuning.Stances[stanceKey] or LookIKTuning.Stances.Standing
	local gateOk = family.Enabled and (not family.IdleOnly or not isMoving)
 
	-- === (1)+(2) Yaw/pitch look-follow, computed ONCE via the shared fold math, then
	-- applied independently to Waist and Root using each joint's own follow
	-- fraction/cap from `family` -- this is what gives real, separate yaw AND pitch
	-- control over both the upper body (Waist) and lower body (Root).
	local targetWaistYaw, targetWaistPitch = 0, 0
	local targetRootYaw, targetRootPitch = 0, 0
 
	local leanSign = if leanState == "Left" then 1 elseif leanState == "Right" then -1 else 0
	local rawLeanRoll = leanSign * LookIKTuning.Lean.RootRollDegrees
	local rawLeanTranslate = leanSign * -LookIKTuning.Lean.RootTranslateStuds * family.LeanTranslateMultiplier
	local rawLeanHeight = math.abs(leanSign) * LookIKTuning.Lean.RootTranslateHeight
 
	if worldLookDirection and worldLookDirection.Magnitude > 0.01 and gateOk then
		local rawYawDeg, rawPitchDeg = LookIKMath.SignedYawPitchDegrees(self.RootPart.CFrame, worldLookDirection)
		local foldedYawDeg = LookIKMath.FoldYawDegrees(rawYawDeg, LookIKTuning.Look.BehindDisengageDegrees)
 
		self._rawYawDeltaDeg = foldedYawDeg
		self._rawPitchDeltaDeg = rawPitchDeg

		-- Torso pitch lockout (fix: extreme-pitch strafe jitter). rawPitchDeg is the exact
		-- signed look-pitch off horizontal -- the same value that's about to feed both
		-- Waist and Root's pitch follow, AND whose companion yaw extraction is what
		-- destabilizes near vertical (see LookIKTuning.TorsoPitchLockout comment). Fading
		-- BOTH yaw and pitch follow together (not pitch alone) is what actually stops the
		-- torso twisting at all near the poles, rather than just stops nodding while still
		-- twisting -- the yaw instability was the bigger visible offender while strafing.
		local pitchMagnitudeDeg = math.abs(rawPitchDeg)
		local lockout = LookIKTuning.TorsoPitchLockout
		local torsoFollowScale = 1.0
		if lockout and lockout.Enabled then
			torsoFollowScale = 1 - math.clamp(
				(pitchMagnitudeDeg - lockout.FadeStartDegrees) / math.max(lockout.FadeEndDegrees - lockout.FadeStartDegrees, 1e-4),
				0, 1
			)
		end
 
		targetWaistYaw = math.clamp(foldedYawDeg * family.Waist.YawFollowFraction, -family.Waist.MaxYawTiltDegrees, family.Waist.MaxYawTiltDegrees) * torsoFollowScale
		targetWaistPitch = math.clamp(rawPitchDeg * family.Waist.PitchFollowFraction, -family.Waist.MaxPitchTiltDegrees, family.Waist.MaxPitchTiltDegrees) * torsoFollowScale
 
		targetRootYaw = math.clamp(foldedYawDeg * family.Root.YawFollowFraction, -family.Root.MaxYawTiltDegrees, family.Root.MaxYawTiltDegrees) * torsoFollowScale
		targetRootPitch = math.clamp(rawPitchDeg * family.Root.PitchFollowFraction, -family.Root.MaxPitchTiltDegrees, family.Root.MaxPitchTiltDegrees) * torsoFollowScale
	else
		self._rawYawDeltaDeg = 0
		self._rawPitchDeltaDeg = 0
	end
 
	-- Three independent clearance fractions -- each only ever scales the axis it
	-- actually measured. A wall that only blocks the lean no longer eats into yaw/pitch,
	-- and vice versa.
	local yawClearance, pitchClearance, lateralClearance = self:_updateBodyClearance(
		dt, rawLeanRoll, rawLeanTranslate, rawLeanHeight,
		targetWaistYaw, targetWaistPitch, targetRootYaw, targetRootPitch
	)
 
	targetWaistYaw *= yawClearance
	targetRootYaw *= yawClearance
	targetWaistPitch *= pitchClearance
	targetRootPitch *= pitchClearance
 
	local tiltAlpha = math.clamp(LookIKTuning.TiltLerpSpeed * dt, 0, 1)
	self._currentYawTiltDeg += (targetWaistYaw - self._currentYawTiltDeg) * tiltAlpha
	self._currentPitchTiltDeg += (targetWaistPitch - self._currentPitchTiltDeg) * tiltAlpha
	self._currentRootYawTiltDeg += (targetRootYaw - self._currentRootYawTiltDeg) * tiltAlpha
	self._currentRootPitchTiltDeg += (targetRootPitch - self._currentRootPitchTiltDeg) * tiltAlpha
 
	-- === (3) Stance forward tilt -- SMOOTHED (ForwardTiltLerpSpeed) AND, as of this pass,
	-- scaled by pitchClearance same as the look-follow pitch. It used to be fully
	-- unclamped ("always-on, not gated"), which meant a stance's baked-in forward lean
	-- (Crouching/Prone) could push the torso through a wall entirely on its own, on top
	-- of whatever the look-down component was doing. pitchClearance above already
	-- measured the swing WITH this tilt folded in, so applying it here too keeps the
	-- actual rendered pose consistent with what was checked.
	local forwardTiltAlpha = math.clamp(LookIKTuning.ForwardTiltLerpSpeed * dt, 0, 1)
	self._currentBaseForwardTiltDeg += (-family.BaseForwardTilt - self._currentBaseForwardTiltDeg) * forwardTiltAlpha
	local finalWaistPitchDeg = (self._currentBaseForwardTiltDeg * pitchClearance) + self._currentPitchTiltDeg
 
	-- === (4) Lean roll + lateral shift -- always active, not gated =====================
	local targetLeanRoll = rawLeanRoll * lateralClearance
	local targetLeanTranslate = rawLeanTranslate * lateralClearance
	local targetLeanHeight = rawLeanHeight * lateralClearance
	local leanAlpha = math.clamp(LookIKTuning.Lean.LerpSpeed * dt, 0, 1)
	self._currentLeanRollDeg += (targetLeanRoll - self._currentLeanRollDeg) * leanAlpha
	self._currentLeanTranslateStuds += (targetLeanTranslate - self._currentLeanTranslateStuds) * leanAlpha
	self._currentLeanHeight += (targetLeanHeight - self._currentLeanHeight) * leanAlpha
 
	if self.Root then
		self.Root.C0 = self._rootRestC0
			* CFrame.new(self._currentLeanTranslateStuds, self._currentLeanHeight, 0)
			* CFrame.Angles(
				math.rad(self._currentRootPitchTiltDeg),
				math.rad(self._currentRootYawTiltDeg),
				math.rad(self._currentLeanRollDeg)
			)
	end
 
	local waistLeanFollow = self._currentLeanRollDeg * LookIKTuning.Lean.WaistFollowFraction
	self.Waist.C0 = self._waistRestC0
		* CFrame.Angles(math.rad(finalWaistPitchDeg), math.rad(self._currentYawTiltDeg), math.rad(waistLeanFollow))
 
		--[[
	if self._enabled and self.Character:GetAttribute("CombatStance") then
		print(string.format(
			"[TorsoTilt] Stance: %s || Min-Max RootYaw: %.1f - %.1f | RootYaw: %.1f || Min-Max RootPitch: %.1f %.1f | RootPitch: %.1f || Min-Max WaistYaw: %.1f - %.1f | WaistYaw: %.1f || Min-Max WaistPitch: %.1f - %.1f | WaistPitch: %.1f || HumanoidRootPart.Yaw: %.1f | HumanoidRootPart.Pitch: %.1f || GateOk: %s | Enabled: %s | IdleOnly: %s | Moving: %s",
			self.Character:GetAttribute("CombatStance"),
			-family.Root.MaxYawTiltDegrees,
			family.Root.MaxYawTiltDegrees,
			self._currentRootYawTiltDeg,
			-family.Root.MaxPitchTiltDegrees,
			family.Root.MaxPitchTiltDegrees,
			self._currentRootPitchTiltDeg,
			-family.Waist.MaxYawTiltDegrees,
			family.Waist.MaxYawTiltDegrees,
			self._currentYawTiltDeg,
			-family.Waist.MaxPitchTiltDegrees,
			family.Waist.MaxPitchTiltDegrees,
			self._currentPitchTiltDeg,
			math.deg(select(2, self.RootPart.CFrame:ToOrientation())),
			math.deg(select(1, self.RootPart.CFrame:ToOrientation())),
			tostring(gateOk),
			tostring(family.Enabled),
			tostring(family.IdleOnly),
			tostring(isMoving)
		))
	end
	--]]
end



return TorsoTiltController