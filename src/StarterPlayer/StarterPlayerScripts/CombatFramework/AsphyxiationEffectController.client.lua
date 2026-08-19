--!strict
--[[
	AsphyxiationEffectController.client.lua  (Ch 2.8 Breathing -> Asphyxiation visual/audio)

	REWRITTEN to use TweenService instead of a manual per-frame Heartbeat lerp. Every
	property this drives (Size, ImageTransparency, TileSize, Saturation, TintColor,
	BlurEffect.Size, EqualizerSoundEffect gains) is a plain Instance property -- exactly
	what TweenService interpolates natively, so there's no reason to hand-roll it.

	Two things stay outside TweenService because they aren't simple property targets:
	  - CameraShake.SetContinuous is a FUNCTION CALL each frame, not a property -- it's
	    driven off a small NumberValue proxy (criticalValue) that IS tweened normally, and
	    Heartbeat just reads criticalValue.Value each frame to feed CameraShake.
	  - Static noise jitter is discrete random repositioning, not a smooth interpolation
	    target -- stays a small Heartbeat timer, same as before.

	IMPORTANT: retargeting mid-tween (oxygen changes every ~2 points, so this happens
	often) means two tweens can end up fighting the same property if the old one isn't
	cancelled first -- every call to retarget() cancels the previous batch before creating
	new ones.

	Connects to CombatEvents FIRST, before any WaitForChild, so an Asphyxiated/Recovered
	firing while PlayerGui/UI is still replicating is never missed (see prior fix).
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local SoundServiceEngine = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local BreathTuning = require(CombatFramework.Shared.Config.BreathTuning)
local Tuning = require(CombatFramework.Shared.Config.AsphyxiationEffectTuning)
local CameraShake = require(script.Parent.CameraShake)

local player = Players.LocalPlayer

-- === Phase 1: connect to CombatEvents before ANY yield below (WaitForChild etc.) =======

local isAsphyxiated = false
local pendingOxygenFraction = 1

local function computeTargetT(): number
	if isAsphyxiated then
		return 1
	end
	return 1 - math.clamp(pendingOxygenFraction / BreathTuning.CriticalOxygenFraction, 0, 1)
end

-- Forward-declared; assigned once Phase 2 finishes building the tween targets. Anything
-- that fires before Phase 2 is ready just updates the plain booleans/numbers above, which
-- Phase 2 reads immediately once it's set up -- nothing is lost to the connect-order race.
local retarget: ((duration: number?) -> ())? = nil

CombatEvents.OxygenChanged:Connect(function(_player: Player, oxygenFraction: number)
	pendingOxygenFraction = oxygenFraction
	if retarget then
		retarget(nil)
	end
end)

CombatEvents.Asphyxiated:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end
	isAsphyxiated = true
	if retarget then
		retarget(Tuning.AsphyxiationSnapTime)
	end
end)

CombatEvents.Recovered:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end
	isAsphyxiated = false
	pendingOxygenFraction = Tuning.RecoveryOxygenFractionSnap
	if retarget then
		retarget(Tuning.AsphyxiationSnapTime)
	end
end)

CombatEvents.CoughTriggered:Connect(function(_firingPlayer: Player) end) -- placeholder hook, unused here

-- === Phase 2: resolve UI (safe to yield now -- Phase 1 already captured any early state) ==

local playerGui = player:WaitForChild("PlayerGui")
local effectsRoot = playerGui:WaitForChild("CombatFramework"):WaitForChild("Effects")
local asphyxiationGui = effectsRoot:WaitForChild("Asphyxiation")
local mainFrame = asphyxiationGui:WaitForChild("Main") :: Frame
local staticImage = mainFrame:WaitForChild("Static") :: ImageLabel
local vignetteImage = mainFrame:WaitForChild("Vignette") :: ImageLabel

local darknessInstances: { ImageLabel } = {}
for _, child in ipairs(mainFrame:GetChildren()) do
	if child.Name == "Darkness" and (child:IsA("ImageLabel") or child:IsA("Frame")) then
		table.insert(darknessInstances, child :: any)
	end
end

local unconsciousFrame = effectsRoot:WaitForChild("Unconcious"):WaitForChild("Frame") :: Frame
unconsciousFrame.Visible = isAsphyxiated
unconsciousFrame.BackgroundTransparency = 0
mainFrame.Visible = true -- always visible per spec -- only Size ever animates

local colorCorrection = Lighting:FindFirstChild("CombatframeworkAsphyxiation") :: ColorCorrectionEffect?
if not colorCorrection then
	warn('AsphyxiationEffectController: Lighting.CombatframeworkAsphyxiation (ColorCorrectionEffect) not found -- desaturation/tint will be skipped')
end

local blur = Lighting:FindFirstChild("CombatFrameworkAsphyxiationBlur") :: BlurEffect?
if not blur then
	blur = Instance.new("BlurEffect")
	blur.Name = "CombatFrameworkAsphyxiationBlur"
	blur.Size = 0
	blur.Parent = Lighting
end

local audioMuffle = SoundServiceEngine:FindFirstChild("CombatFrameworkAsphyxiationMuffle") :: EqualizerSoundEffect?
if not audioMuffle then
	audioMuffle = Instance.new("EqualizerSoundEffect")
	audioMuffle.Name = "CombatFrameworkAsphyxiationMuffle"
	audioMuffle.HighGain = 0
	audioMuffle.MidGain = 0
	audioMuffle.LowGain = 0
	audioMuffle.Parent = SoundServiceEngine
end

-- Proxy NumberValue: CameraShake.SetContinuous isn't a property, so it can't be a tween
-- target directly -- this NumberValue IS tweened normally, and Heartbeat below just reads
-- its current (interpolated) Value each frame to drive the shake call.
local criticalValue = Instance.new("NumberValue")
criticalValue.Name = "CombatFrameworkAsphyxiationCriticalValue"
criticalValue.Value = 0
criticalValue.Parent = script

-- Reconnect the UI-visibility side effects that Phase 1 couldn't safely touch (UI didn't
-- exist yet when those handlers first ran).
CombatEvents.Asphyxiated:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end
	unconsciousFrame.Visible = true
end)

CombatEvents.Recovered:Connect(function(firingPlayer: Player)
	if firingPlayer ~= player then
		return
	end
	unconsciousFrame.Visible = false
end)

-- === Tween retargeting ======================================================

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

local activeTweens: { Tween } = {}

local function cancelActiveTweens()
	for _, tw in ipairs(activeTweens) do
		tw:Cancel()
	end
	table.clear(activeTweens)
end

--- Cancels whatever's mid-flight and starts a fresh batch of tweens toward the CURRENT
--- target `t` (derived from pendingOxygenFraction/isAsphyxiated). `duration` overrides the
--- default smoothing time -- used for a fast snap on Asphyxiated/Recovered vs. the normal
--- gradual pace for routine OxygenChanged updates.
retarget = function(duration: number?)
	local t = computeTargetT()
	local time = duration or Tuning.EffectTweenTime

	cancelActiveTweens()

	local ti = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

	local function tween(instance: Instance, props: { [string]: any })
		local tw = TweenService:Create(instance, ti, props)
		tw:Play()
		table.insert(activeTweens, tw)
	end

	local mainScale = lerp(Tuning.MainSizeScaleAtFull, Tuning.MainSizeScaleAtCritical, t)
	tween(mainFrame, { Size = UDim2.fromScale(mainScale, mainScale) })

	local staticTile = lerp(Tuning.StaticTileSizeAtFull, Tuning.StaticTileSizeAtCritical, t)
	tween(staticImage, {
		ImageTransparency = lerp(Tuning.StaticTransparencyAtFull, Tuning.StaticTransparencyAtCritical, t),
		TileSize = UDim2.fromScale(staticTile, staticTile),
	})

	tween(vignetteImage, { ImageTransparency = lerp(Tuning.VignetteTransparencyAtFull, Tuning.VignetteTransparencyAtCritical, t) })

	for _, darkness in ipairs(darknessInstances) do
		if darkness:IsA("ImageLabel") then
			tween(darkness, { ImageTransparency = lerp(Tuning.DarknessTransparencyAtFull, Tuning.DarknessTransparencyAtCritical, t) })
		else
			tween(darkness, { BackgroundTransparency = lerp(Tuning.DarknessTransparencyAtFull, Tuning.DarknessTransparencyAtCritical, t) })
		end
	end

	if colorCorrection then
		tween(colorCorrection, {
			Saturation = lerp(Tuning.SaturationAtFull, Tuning.SaturationAtCritical, t),
			TintColor = lerpColor(Tuning.TintAtFull, Tuning.TintAtCritical, t),
		})
	end

	if blur then
		tween(blur, { Size = lerp(Tuning.BlurSizeAtFull, Tuning.BlurSizeAtCritical, t) })
	end

	if audioMuffle then
		tween(audioMuffle, {
			HighGain = lerp(0, Tuning.AudioHighGainAtCritical, t),
			MidGain = lerp(0, Tuning.AudioMidGainAtCritical, t),
		})
	end

	tween(criticalValue, { Value = t })
end

-- Apply whatever state accumulated during Phase 1 immediately, snapping rather than
-- animating from a stale zero (there's nothing meaningful to transition FROM on load).
retarget(0.01)

-- === Heartbeat: only the two things TweenService can't own =============================

local staticJitterTimer = 0

RunService.Heartbeat:Connect(function(dt: number)
	local t = criticalValue.Value -- reads the LIVE, currently-tweening value, not the target

	staticJitterTimer -= dt
	if staticJitterTimer <= 0 and t > 0.01 then
		staticJitterTimer = Tuning.StaticJitterInterval
		staticImage.Position = UDim2.fromScale(math.random() * 0.02 - 0.01, math.random() * 0.02 - 0.01)
	end

	if isAsphyxiated then
		CameraShake.SetContinuous("Asphyxiation", 0) -- no tremor while fully out
	else
		CameraShake.SetContinuous("Asphyxiation", Tuning.CameraShakeMagnitudeAtCritical * t)
	end
end)