--!strict
--[[
	FootstepService.client.lua  (Ch 10 Audio Framework)

	Owns ZERO movement tuning -- no stride length, no cadence, no speed thresholds. All of
	that is already correct in IKLegController (real per-foot plant timing) and
	Stances.lua (NoiseMultiplier, Ch 2.2 -- the same "how loud is this stance" value Ch
	13.3's AI hearing perception is meant to read). This file's only job: when IK says a
	foot landed, play the right material at the right volume. WHEN a footstep happens is
	decided entirely by IKControllerRegistry's FootPlantedEvent, not here.

	Gear/clothing rustle rides the same event stream instead of tracking its own "is this
	character walking" state -- it refreshes a TTL'd continuous sound on every footstep and
	lets SoundService fade it out on its own once steps stop coming in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local SoundService = require(CombatFramework.Shared.SoundService)
local FootstepMaterialGroups = require(CombatFramework.Shared.Config.FootstepMaterialGroups)
local Stances = require(CombatFramework.Shared.Config.Stances)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local IKControllerRegistry = require(script.Parent.IKControllerRegistry)
local FallTuning = require(CombatFramework.Shared.Config.FallTuning)


-- The only two constants this file owns, and both are audio-mix decisions, not movement
-- tuning: how long a gear loop survives without a fresh footstep, and how fast a stance
-- exit out of TacticalSprint needs to be moving to count as a "slide" vs. just stopping.
local GEAR_LOOP_TTL = 0.45

local SLIDE_MIN_SPEED = 10       -- studs/s planar speed required to trigger a slide at all
local SLIDE_STOP_SPEED = 1.5     -- studs/s; below this the slide is considered over
local SLIDE_REFERENCE_SPEED = 20 -- studs/s; speed at which slide volume/pitch hit their max
local SLIDE_FADE_OUT_TIME = 0.35
local SLIDE_SAFETY_TTL = 1.5     -- see note below

local GEAR_CATEGORY_BY_STANCE: { [string]: string } = {
	Crouching = "Gear.Slow",
	Prone = "Gear.Slow", -- Prone rarely reaches onFootPlanted (near-zero speed), kept for completeness
	TacticalWalk = "Gear.Slow",
	Standing = "Gear.Walk",
	TacticalSprint = "Gear.Run",
}

local footPlantedConnections: { [Model]: RBXScriptConnection } = {}
local humanoidStateConnections: { [Model]: RBXScriptConnection } = {}

type SlideSession = { RootPart: BasePart, Humanoid: Humanoid, SourceId: string }
local activeSlides: { [Model]: SlideSession } = {}

local function slideSourceId(character: Model): string
	return `Slide:{character:GetFullName()}`
end

local function gearCategoryForStance(stance: string?): string?
	if typeof(stance) ~= "string" then
		return nil
	end
	return GEAR_CATEGORY_BY_STANCE[stance]
end

local function stopSlide(character: Model)
	local session = activeSlides[character]
	if not session then
		return
	end
	activeSlides[character] = nil
	SoundService.StopContinuous(session.SourceId, SLIDE_FADE_OUT_TIME)
end


local connections: { [Model]: RBXScriptConnection } = {}

local function noiseMultiplierFor(stance: string?): number
	local def = typeof(stance) == "string" and Stances[stance]
	return (def and def.NoiseMultiplier) or 1
end

local function onFootPlanted(character: Model, _side: string, _worldPosition: Vector3, stance: string?, _planarSpeed: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart then
		return
	end

	local floorMaterial = humanoid.FloorMaterial
	if floorMaterial == Enum.Material.Air then
		return
	end

	local volume = noiseMultiplierFor(stance)

	SoundService.Play(FootstepMaterialGroups.CategoryFor(floorMaterial), {
		Parent = rootPart,
		Volume = volume,
	})

	-- Gear rustle: ONE-SHOT per footstrike, same reasoning as Clothing.Run below --
	-- multiple numbered variants per intensity tier only give real variation if a new one
	-- is picked every step, which PlayContinuous can't do (it locks to one variant for the
	-- whole loop). Tier (Slow/Walk/Run) comes from stance; presence/intensity from GearLoad.
	local gearLoad = character:GetAttribute("GearLoad")
	local gearCategory = gearCategoryForStance(stance)
	if gearCategory and typeof(gearLoad) == "number" and gearLoad > 0 then
		SoundService.Play(gearCategory, {
			Parent = rootPart,
			Volume = math.clamp(gearLoad/2, 0, 1) * volume,
		})
	end

	-- Clothing rustle: unchanged from last pass -- sprint-only, ducked under heavy gear.
	if stance == "TacticalSprint" then
		local gearDuck = 1 - math.clamp((typeof(gearLoad) == "number" and gearLoad or 0), 0, 1) * 0.4
		SoundService.Play("Clothing.Run", {
			Parent = rootPart,
			Volume = volume * gearDuck,
		})
	end
end

IKControllerRegistry.Added:Connect(function(character: Model, controller)
	footPlantedConnections[character] = controller.FootPlantedEvent:Connect(function(side, worldPosition, stance, planarSpeed)
		onFootPlanted(character, side, worldPosition, stance, planarSpeed)
	end)

	-- Jump sound: Humanoid.StateType.Jumping fires exactly once per actual jump and is
	-- native Roblox replication (every client sees every character's Humanoid state) --
	-- no new NamedSignal/remote needed. Deliberately NOT Freefall: that also covers
	-- walking off a ledge, which shouldn't play a "jump" sound.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoidStateConnections[character] = humanoid.StateChanged:Connect(function(_old, new)
			if new == Enum.HumanoidStateType.Jumping then
				local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if rootPart then
					SoundService.Play("Movement.Jump", { Parent = rootPart })
				end
			end
		end)
	end
end)

IKControllerRegistry.Removed:Connect(function(character: Model)
	local footConn = footPlantedConnections[character]
	if footConn then
		footConn:Disconnect()
		footPlantedConnections[character] = nil
	end
	local stateConn = humanoidStateConnections[character]
	if stateConn then
		stateConn:Disconnect()
		humanoidStateConnections[character] = nil
	end
	stopSlide(character)
end)

-- === Slide-on-stop (Ch 2.2 TacticalSprint -> anything else) ============================
-- Reads RootPart velocity directly -- works identically for the local player and every
-- remote character, since only the local player ever gets a client-side CharacterController
-- instance (MovementClient's ownership model).

CombatEvents.FallImpact:Connect(function(player: Player, peakFallSpeed: number, _damageApplied: number, landingMaterial: Enum.Material)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end

	-- Always-on material landing sound, scaled 0..1 across the full fall-speed range.
	local overallFraction = math.clamp(peakFallSpeed / FallTuning.FastFallVelocity, 0, 1)
	print("Playing landing sound for: " .. landingMaterial.Name)
	SoundService.Play(FootstepMaterialGroups.LandingCategoryFor(landingMaterial), {
		Parent = rootPart,
		Volume = 0.4 + 0.6 * overallFraction,
		PlaybackSpeed = 1 - 0.1 * overallFraction,
	})

	-- Separate heavy-impact layer, only above the notable-landing threshold.
	if peakFallSpeed >= FallTuning.NotableLandingVelocity then
		local heavyFraction = math.clamp(
			(peakFallSpeed - FallTuning.NotableLandingVelocity) / math.max(FallTuning.FastFallVelocity - FallTuning.NotableLandingVelocity, 1),
			0,
			1
		)
		SoundService.Play("Movement.HeavyImpact", {
			Parent = rootPart,
			Volume = 1 + 0.4 * heavyFraction,
			PlaybackSpeed = 1 - 0.08 * heavyFraction,
		})
	end
end)

CombatEvents.MovementInputReleased:Connect(function(player: Player, speedAtRelease: number)
	if speedAtRelease < SLIDE_MIN_SPEED then
		return -- released input at a walk/jog -- not fast enough to count as a slide
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not rootPart or not humanoid then
		return
	end

	local sourceId = slideSourceId(character)
	activeSlides[character] = { RootPart = rootPart, Humanoid = humanoid, SourceId = sourceId }

	local speedFraction = math.clamp(speedAtRelease / SLIDE_REFERENCE_SPEED, 0, 1)
	local stanceAttr = character:GetAttribute("CombatStance") -- already set by CharacterController

	SoundService.PlayContinuous("Movement.Slide", sourceId, {
		Parent = rootPart,
		Volume = speedFraction,
		PlaybackSpeed = 0.85 + 0.3 * speedFraction,
		TTL = SLIDE_SAFETY_TTL,
	})

	SoundService.Play(FootstepMaterialGroups.CategoryFor(humanoid.FloorMaterial), {
		Parent = rootPart,
		Volume = noiseMultiplierFor(if typeof(stanceAttr) == "string" then stanceAttr else nil) * 0.6 * speedFraction,
		PlaybackSpeed = 0.85,
	})
end)

RunService.Heartbeat:Connect(function()
	for character, session in pairs(activeSlides) do
		if not session.RootPart.Parent then
			activeSlides[character] = nil
			continue
		end

		local velocity = session.RootPart.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

		if speed < SLIDE_STOP_SPEED then
			stopSlide(character)
			continue
		end

		local speedFraction = math.clamp(speed / SLIDE_REFERENCE_SPEED, 0, 1)
		SoundService.PlayContinuous("Movement.Slide", session.SourceId, {
			Parent = session.RootPart,
			Volume = speedFraction,
			PlaybackSpeed = 0.85 + 0.3 * speedFraction,
			TTL = SLIDE_SAFETY_TTL,
		})
	end
end)