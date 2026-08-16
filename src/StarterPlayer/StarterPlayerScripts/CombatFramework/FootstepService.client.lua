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

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local SoundService = require(CombatFramework.Shared.SoundService)
local FootstepMaterialGroups = require(CombatFramework.Shared.Config.FootstepMaterialGroups)
local Stances = require(CombatFramework.Shared.Config.Stances)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local IKControllerRegistry = require(script.Parent.IKControllerRegistry)

-- The only two constants this file owns, and both are audio-mix decisions, not movement
-- tuning: how long a gear loop survives without a fresh footstep, and how fast a stance
-- exit out of TacticalSprint needs to be moving to count as a "slide" vs. just stopping.
local GEAR_LOOP_TTL = 0.45
local SLIDE_MIN_SPEED = 10

local connections: { [Model]: RBXScriptConnection } = {}

local function noiseMultiplierFor(stance: string?): number
	local def = typeof(stance) == "string" and Stances[stance]
	return (def and def.NoiseMultiplier) or 1
end

local function gearSourceId(character: Model): string
	return `Gear:{character:GetFullName()}`
end

local function onFootPlanted(character: Model, _side: string, _worldPosition: Vector3, stance: string?, _planarSpeed: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart then
		return
	end

	local floorMaterial = humanoid.FloorMaterial
	if floorMaterial == Enum.Material.Air then
		return -- IK can still report gait phase for a frame right after leaving a ledge
	end

	local volume = noiseMultiplierFor(stance)

	SoundService.Play(FootstepMaterialGroups.CategoryFor(floorMaterial), {
		Parent = rootPart,
		Volume = volume,
	})

	local gearLoad = character:GetAttribute("GearLoad")
	if typeof(gearLoad) == "number" and gearLoad > 0 then
		local category = if stance == "Crouching" or stance == "Prone" then "Gear.Walk" else "Gear.Sprint"
		SoundService.PlayContinuous(category, gearSourceId(character), {
			Parent = rootPart,
			Volume = math.clamp(gearLoad, 0, 1) * volume,
			TTL = GEAR_LOOP_TTL,
		})
	end
end

IKControllerRegistry.Added:Connect(function(character: Model, controller)
	connections[character] = controller.FootPlantedEvent:Connect(function(side, worldPosition, stance, planarSpeed)
		onFootPlanted(character, side, worldPosition, stance, planarSpeed)
	end)
end)

IKControllerRegistry.Removed:Connect(function(character: Model)
	local conn = connections[character]
	if conn then
		conn:Disconnect()
		connections[character] = nil
	end
	SoundService.StopContinuous(gearSourceId(character), 0.2)
end)

-- === Slide-on-stop (Ch 2.2 TacticalSprint -> anything else) ============================
-- Reads RootPart velocity directly -- works identically for the local player and every
-- remote character, since only the local player ever gets a client-side CharacterController
-- instance (MovementClient's ownership model).

CombatEvents.StanceChanged:Connect(function(player: Player, newStance: string, oldStance: string)
	if oldStance ~= "TacticalSprint" and (newStance ~= "Standing" or newStance == "TacticalWalk") then
		return
	end
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not rootPart or not humanoid then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if speed < SLIDE_MIN_SPEED then
		return
	end

	if humanoid.FloorMaterial == Enum.Material.Air then
		return -- don't play a slide sound if the character is midair (e.g. vaulting)
	end

	SoundService.Play("Movement.Slide", {
		Parent = rootPart,
		Volume = math.clamp(speed / 30, 0, 1.0) * noiseMultiplierFor(newStance) * 0.6,
	})

	SoundService.Play(FootstepMaterialGroups.CategoryFor(humanoid.FloorMaterial), {
		Parent = rootPart,
		Volume = noiseMultiplierFor(newStance) * 0.6,
		PlaybackSpeed = 0.85,
	})
end)