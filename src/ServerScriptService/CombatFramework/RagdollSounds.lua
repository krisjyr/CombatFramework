--!strict
--[[
	RagdollSounds.lua  (Ch 15 Configuration System, consumer of Ragdoll's CombatEvents)

	Server-only. Plays Ragdoll.Impact* (one-shot, via SoundService.Play) on a hard landing
	and Ragdoll.Scrape* (looped, via SoundService.PlayContinuous) while sliding.

	SCRAPE follows the same shape as FootstepService.client.lua's slide-on-stop handling:
	a session table (ScrapeSession) tracked per-character, refreshed with a fresh
	PlayContinuous call every Heartbeat while the scrape condition holds (not just once on
	start) so volume/pitch stay live, plus a TTL passed through as a safety net in case
	cleanup is ever missed. Difference from Movement.Slide: scrape has multiple surface
	categories, so a mid-slide material change explicitly stops the old sourceId and starts
	a new one (PlayContinuous doesn't swap the underlying sound for an existing sourceId).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")

local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local RagdollTuning = require(CombatFramework.Shared.Config.RagdollTuning)
local RagdollSoundMaterials = require(CombatFramework.Shared.Config.RagdollSoundMaterials)
local SoundService = require(CombatFramework.Shared.SoundService)

local SCRAPE_FADE_OUT_TIME = 0.15

type SoundState = {
	RootPart: BasePart,
	Parts: { BasePart }, -- limbs/torso tracked for impact deceleration; excludes root
	PreviousVelocity: { [BasePart]: Vector3 },
	LastImpactTime: number,
	HeartbeatConn: RBXScriptConnection,
	DestroyingConn: RBXScriptConnection?,
}

type ScrapeSession = {
	RootPart: BasePart,
	SourceId: string,
	Category: string,
}

local active: { [Model]: SoundState } = {}
local activeScrapes: { [Model]: ScrapeSession } = {}

local RagdollSounds = {}

local scrapeRayParams = RaycastParams.new()
scrapeRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function alphaBetween(value: number, low: number, high: number): number
	if high <= low then
		return 1
	end
	return math.clamp((value - low) / (high - low), 0, 1)
end

local function scrapeSourceId(character: Model): string
	return `RagdollScrape:{character:GetFullName()}`
end

--- Same collidable-part filter RagdollRig.collectBodyParts uses, minus HumanoidRootPart
--- (tracked separately below as the scrape-detection reference point).
local function collectTrackedParts(character: Model): { BasePart }
	local parts = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			if not descendant.Name:match("NoCollision$") then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

--- First touching part that isn't this character's own body (so a limb resting against
--- another limb doesn't count as "the ground"). Returns nil if nothing valid is touching.
local function findGroundMaterial(part: BasePart, character: Model): Enum.Material?
	for _, touching in ipairs(part:GetTouchingParts()) do
		if touching.CanCollide and not touching:IsDescendantOf(character) then
			return touching.Material
		end
	end
	return nil
end

local function findScrapeGroundMaterial(rootPart: BasePart, character: Model): Enum.Material?
	scrapeRayParams.FilterDescendantsInstances = { character }
	local origin = rootPart.Position
	local hit = Workspace:Raycast(origin, Vector3.new(0, -RagdollTuning.SoundScrapeGroundDistance, 0), scrapeRayParams)
	if not hit then
		return nil
	end
	return hit.Material
end

--- Soft/Medium/Hard purely from how hard the deceleration was.
local function classifySeverity(delta: number): string
	if delta >= RagdollTuning.SoundImpactHardSpeed then
		return "Hard"
	elseif delta >= RagdollTuning.SoundImpactMediumSpeed then
		return "Medium"
	else
		return "Soft"
	end
end

local function updateImpact(character: Model, state: SoundState, now: number)
	local worstDelta = 0
	local worstPart: BasePart? = nil

	for _, part in ipairs(state.Parts) do
		if not part.Parent then
			continue
		end
		local velocity = part.AssemblyLinearVelocity
		local previous = state.PreviousVelocity[part] or velocity
		local delta = (previous - velocity).Magnitude
		state.PreviousVelocity[part] = velocity

		if delta > worstDelta then
			worstDelta = delta
			worstPart = part
		end
	end

	if not worstPart then
		return
	end
	if worstDelta < RagdollTuning.SoundImpactMinSpeed then
		return
	end
	if now - state.LastImpactTime < RagdollTuning.SoundImpactCooldown then
		return
	end

	local material = findGroundMaterial(worstPart, character)
	local family = (material and RagdollSoundMaterials.Impact[material]) or "Generic"

	local key: string
	if family == "Water" then
		key = "Ragdoll.ImpactWater" -- no severity variants
	else
		local severity = classifySeverity(worstDelta)
		key = if family == "Generic" then "Ragdoll.Impact" .. severity else "Ragdoll.Impact" .. family .. severity
	end

	local alpha = alphaBetween(worstDelta, RagdollTuning.SoundImpactMinSpeed, RagdollTuning.SoundImpactHardSpeed)
	local volumeMultiplier = 0.5 + 0.5 * alpha

	SoundService.Play(key, { Parent = worstPart, Volume = volumeMultiplier })
	state.LastImpactTime = now
end

-- === Scrape (Movement.Slide-style session, see file-top note) ==========================

local function stopScrape(character: Model)
	local session = activeScrapes[character]
	if not session then
		return
	end
	activeScrapes[character] = nil
	SoundService.StopContinuous(session.SourceId, SCRAPE_FADE_OUT_TIME)
end

local function updateScrape(character: Model, rootPart: BasePart)
	if not rootPart.Parent then
		stopScrape(character)
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	-- Raycast-based ground check instead of a vertical-speed tolerance -- a fast downhill
	-- slide has real downward velocity from the slope's grade alone, which a
	-- verticalSpeed <= tolerance check would wrongly read as "airborne, stop scraping".
	-- This just asks "is there a surface close under the root right now", independent of
	-- how the velocity vector is angled.
	local groundMaterial = findScrapeGroundMaterial(rootPart, character)

	local shouldScrape = groundMaterial ~= nil and horizontalSpeed >= RagdollTuning.SoundScrapeMinSpeed

	if not shouldScrape then
		stopScrape(character)
		return
	end

	local category = (groundMaterial and RagdollSoundMaterials.Scrape[groundMaterial]) or "Generic"
	local key = "Ragdoll.Scrape" .. category

	local session = activeScrapes[character]
	if session and session.Category ~= category then
		stopScrape(character)
		session = nil
	end

	if not session then
		session = { RootPart = rootPart, SourceId = scrapeSourceId(character), Category = category }
		activeScrapes[character] = session
	end

	local alpha = alphaBetween(horizontalSpeed, RagdollTuning.SoundScrapeMinSpeed, RagdollTuning.SoundScrapeMaxSpeed)
	local volumeMultiplier = 0.3 + 0.7 * alpha

	SoundService.PlayContinuous(key, session.SourceId, {
		Parent = rootPart,
		Volume = volumeMultiplier,
		TTL = RagdollTuning.SoundScrapeSafetyTTL,
	})
end

-- === Lifecycle ===========================================================

local function beginTracking(character: Model, rootPart: BasePart)
	if active[character] then
		return
	end

	local state: SoundState = {
		RootPart = rootPart,
		Parts = collectTrackedParts(character),
		PreviousVelocity = {},
		LastImpactTime = 0,
		HeartbeatConn = nil :: any,
		DestroyingConn = nil,
	}

	state.HeartbeatConn = RunService.Heartbeat:Connect(function()
		updateImpact(character, state, os.clock())
		updateScrape(character, rootPart)
	end)

	local ok, connOrErr = pcall(function()
		return character.Destroying:Connect(function()
			stopTracking(character)
		end)
	end)
	if ok then
		state.DestroyingConn = connOrErr
	end

	active[character] = state
end

local function stopTracking(character: Model)
	local state = active[character]
	if not state then
		return
	end
	active[character] = nil
	state.HeartbeatConn:Disconnect()
	if state.DestroyingConn then
		state.DestroyingConn:Disconnect()
	end
	stopScrape(character)
end

CombatEvents.RagdollBegan:Connect(function(character: Model, cause: string, _player: Player?)
	if cause == "Death" and not RagdollTuning.PlaySoundsOnDeath then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end
	beginTracking(character, rootPart)
end)

CombatEvents.RagdollEnded:Connect(function(character: Model)
	stopTracking(character)
end)

function RagdollSounds.TrackCorpse(corpseModel: Model)
	if not RagdollTuning.PlaySoundsOnDeath then
		return
	end
	local rootPart = corpseModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		warn(`RagdollSounds.TrackCorpse: {corpseModel:GetFullName()} has no HumanoidRootPart -- skipping`)
		return
	end
	beginTracking(corpseModel, rootPart)
end

function RagdollSounds.StopTracking(character: Model)
	stopTracking(character)
end

return RagdollSounds