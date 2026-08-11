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

local TorsoTiltController = {}
TorsoTiltController.__index = TorsoTiltController

export type TorsoTiltControllerInstance = typeof(setmetatable(
	{} :: {
		Character: Model,
		RootPart: BasePart,
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
		_rawYawDeltaDeg: number,
		_rawPitchDeltaDeg: number,
	},
	TorsoTiltController
))

function TorsoTiltController.new(character: Model, _isLocalPlayer: boolean): TorsoTiltControllerInstance?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local upperTorso = character:FindFirstChild("UpperTorso") :: BasePart?
	local lowerTorso = character:FindFirstChild("LowerTorso") :: BasePart?
	local waist = upperTorso and upperTorso:FindFirstChild("Waist") :: Motor6D?
	local root = lowerTorso and lowerTorso:FindFirstChild("Root") :: Motor6D?

	if not (rootPart and waist) then
		return nil
	end

	return setmetatable({
		Character = character,
		RootPart = rootPart :: BasePart,
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
		_rawYawDeltaDeg = 0,
		_rawPitchDeltaDeg = 0,
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
		self._rawYawDeltaDeg = 0
		self._rawPitchDeltaDeg = 0
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

	if worldLookDirection and worldLookDirection.Magnitude > 0.01 and gateOk then
		local rawYawDeg, rawPitchDeg = LookIKMath.SignedYawPitchDegrees(self.RootPart.CFrame, worldLookDirection)
		local foldedYawDeg = LookIKMath.FoldYawDegrees(rawYawDeg, LookIKTuning.Look.BehindDisengageDegrees)

		self._rawYawDeltaDeg = foldedYawDeg
		self._rawPitchDeltaDeg = rawPitchDeg

		targetWaistYaw = math.clamp(foldedYawDeg * family.Waist.YawFollowFraction, -family.Waist.MaxYawTiltDegrees, family.Waist.MaxYawTiltDegrees)
		targetWaistPitch = math.clamp(rawPitchDeg * family.Waist.PitchFollowFraction, -family.Waist.MaxPitchTiltDegrees, family.Waist.MaxPitchTiltDegrees)

		targetRootYaw = math.clamp(foldedYawDeg * family.Root.YawFollowFraction, -family.Root.MaxYawTiltDegrees, family.Root.MaxYawTiltDegrees)
		targetRootPitch = math.clamp(rawPitchDeg * family.Root.PitchFollowFraction, -family.Root.MaxPitchTiltDegrees, family.Root.MaxPitchTiltDegrees)
	else
		self._rawYawDeltaDeg = 0
		self._rawPitchDeltaDeg = 0
	end

	local tiltAlpha = math.clamp(LookIKTuning.TiltLerpSpeed * dt, 0, 1)
	self._currentYawTiltDeg += (targetWaistYaw - self._currentYawTiltDeg) * tiltAlpha
	self._currentPitchTiltDeg += (targetWaistPitch - self._currentPitchTiltDeg) * tiltAlpha
	self._currentRootYawTiltDeg += (targetRootYaw - self._currentRootYawTiltDeg) * tiltAlpha
	self._currentRootPitchTiltDeg += (targetRootPitch - self._currentRootPitchTiltDeg) * tiltAlpha

	-- === (3) Stance forward tilt -- always active, not gated, but now SMOOTHED. Used to
	-- snap instantly the frame CombatStance changed; now eases toward the new stance's
	-- BaseForwardTilt at ForwardTiltLerpSpeed like everything else in this module.
	local forwardTiltAlpha = math.clamp(LookIKTuning.ForwardTiltLerpSpeed * dt, 0, 1)
	self._currentBaseForwardTiltDeg += (-family.BaseForwardTilt - self._currentBaseForwardTiltDeg) * forwardTiltAlpha
	local finalWaistPitchDeg = self._currentBaseForwardTiltDeg + self._currentPitchTiltDeg

	-- === (4) Lean roll + lateral shift -- always active, not gated =====================
	local leanSign = if leanState == "Left" then 1 elseif leanState == "Right" then -1 else 0
	local targetLeanRoll = leanSign * LookIKTuning.Lean.RootRollDegrees
	local targetLeanTranslate = leanSign * -LookIKTuning.Lean.RootTranslateStuds * family.LeanTranslateMultiplier
	local leanAlpha = math.clamp(LookIKTuning.Lean.LerpSpeed * dt, 0, 1)
	self._currentLeanRollDeg += (targetLeanRoll - self._currentLeanRollDeg) * leanAlpha
	self._currentLeanTranslateStuds += (targetLeanTranslate - self._currentLeanTranslateStuds) * leanAlpha

	if self.Root then
		self.Root.C0 = self._rootRestC0
			* CFrame.new(self._currentLeanTranslateStuds, 0, 0)
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