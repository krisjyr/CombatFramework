--!strict
--[[
	FallService.lua  (Ch 2.2 "Jumping / Falling — supports fall damage, landing impact")

	--------------------------------------------------------------------------------
	DAMAGE CURVE (updated): previously damage was strictly linear past MinDistance, which
	made death trivially easy (~19.5 studs) while ALSO making short falls sting more than
	they should. Replaced with a MinDistance/LethalDistance/Curve model:

		t = clamp((equivalentDistance - MinDistance) / (LethalDistance - MinDistance), 0, 1)
		damage = DamageMultiplier * (t ^ Curve) * 100

	- Below MinDistance: always 0 damage.
	- At/above LethalDistance: t = 1, damage = 100 * DamageMultiplier (a full-health kill
	  at the default DamageMultiplier of 1).
	- Curve > 1 makes the curve concave: a fall just past MinDistance does almost nothing,
	  and damage only ramps up sharply as you approach LethalDistance. This is what makes
	  short/moderate falls forgiving while still requiring real height to actually die.
	  See FallTuning.lua for the default numbers and how to retune them.

	FAST-FALL FEEDBACK (new): while a tracked character is falling, this service also
	watches for the moment their downward speed crosses FallTuning.FastFallVelocity and
	fires CombatEvents.FastFallBegan / FastFallEnded once per fall — purely a feedback
	trigger for the client to start/stop an air-rush sound and an ambient screenshake while
	plummeting (see MovementClient.client.lua). This is independent of whether the fall
	will actually end up dealing damage.

	This is also the SINGLE place that listens to Humanoid.StateChanged for Freefall/Landed
	for damage purposes — MovementServer.server.lua listens to the same states separately,
	but only for STANCE purposes, and no longer tracks fall velocity itself.

	This is a placeholder ahead of the real Medical Framework (Ch 7): today it calls
	Humanoid:TakeDamage(). Once Ch 7's Trauma Calculation / Body Region pipeline exists,
	swap the TakeDamage call below for a call into that pipeline instead.

	--------------------------------------------------------------------------------
	Public API (unchanged shape):

		FallService.new(groupName, minDistance, damageMultiplier, options) -> FallGroup
		FallService:SetCustomData(characterOrPlayer, minDistance, damageMultiplier, options)
		FallService:GetCustomData(characterOrPlayer)
		FallService:GetGroupOf(characterOrPlayer)
		FallService:GetGroup(groupName)
		FallService:GetFallSignalFor(characterOrPlayer, inInvocation)

		FallGroup:Enable(character)
		FallGroup:Disable(character)
		FallGroup:LinkPlayer(player)
		FallGroup:UnlinkPlayer(player)
		FallGroup:Toggle(characterOrPlayer, boolean)

	options shape (all optional):
		{
			MaterialsDamage = { [materialName: string] = multiplier: number }, -- 0 = safe landing
			LethalDistance = number,   -- overrides FallTuning.LethalDistance for this group/character
			Curve = number,            -- overrides FallTuning.Curve
			FastFallVelocity = number, -- overrides FallTuning.FastFallVelocity
		}
	--------------------------------------------------------------------------------
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local RagdollAPI = require(ServerScriptService.CombatFramework.RagdollAPI)
local Signal = require(ReplicatedStorage.Packages.namedsignal)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local FallTuning = require(CombatFramework.Shared.Config.FallTuning)
local Remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local FallFeedbackSync = Remotes:WaitForChild("FallFeedbackSync") :: RemoteEvent

export type MaterialsDamageOptions = { [string]: number }

export type FallOptions = {
	MaterialsDamage: MaterialsDamageOptions?,
	LethalDistance: number?,
	Curve: number?,
	FastFallVelocity: number?,
}

export type FallEventData = {
	PeakFallSpeed: number,
	EquivalentDistance: number,
	Damage: number,
	LandingMaterial: Enum.Material,
}

type CustomDataEntry = {
	MinDistance: number?,
	DamageMultiplier: number?,
	Options: FallOptions?,
}

type CharacterEntry = {
	Character: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	Player: Player?,
	Enabled: boolean,
	IsFalling: boolean,
	PeakDownwardVelocity: number,
	FastFallSignaled: boolean,
	Connections: { RBXScriptConnection },
	FallSignal: any?,
}

local FallService = {}
local FallGroup = {}
FallGroup.__index = FallGroup

local groups: { [string]: any } = {}
local groupOfCharacter: { [Model]: any } = {}
local customData: { [Model]: CustomDataEntry } = {}
local characterEntries: { [Model]: CharacterEntry } = {}

local function resolveCharacter(characterOrPlayer: Instance?): Model?
	if not characterOrPlayer then
		return nil
	end
	if characterOrPlayer:IsA("Player") then
		return (characterOrPlayer :: Player).Character
	elseif characterOrPlayer:IsA("Model") then
		return characterOrPlayer :: Model
	end
	return nil
end

local function getEffectiveOptions(character: Model): FallOptions
	local custom = customData[character]
	local group = groupOfCharacter[character]
	return (custom and custom.Options) or (group and group.Options) or {}
end

local function resolveLandingMaterial(character: Model, rootPart: BasePart, humanoidFloorMaterial: Enum.Material): Enum.Material
	-- Humanoid.FloorMaterial can momentarily read Air right at the exact instant the
	-- Landed state transition fires (known Roblox engine timing quirk) -- FootstepMaterial
	-- Groups has no alias for Air, so that silently falls to DEFAULT_GROUP ("Concrete"),
	-- which is indistinguishable from "material detection is broken" even though every
	-- other part of the pipeline is working correctly. A direct downward raycast is immune
	-- to that timing gap -- same technique SlopeController/IKLegController already use to
	-- read the floor instead of trusting a Humanoid property.
	if humanoidFloorMaterial ~= Enum.Material.Air then
		return humanoidFloorMaterial
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = false

	local hit = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
	if hit and hit.Instance.Material ~= Enum.Material.Air then
		return hit.Instance.Material
	end

	print("No hits")

	return humanoidFloorMaterial -- genuinely airborne/no floor found -- pass through as-is
end

local function calculateDamage(
	peakDownwardVelocity: number,
	gravityMagnitude: number,
	minDistance: number,
	damageMultiplier: number,
	lethalDistance: number,
	curveExponent: number
): (number, number)
	local g = math.max(gravityMagnitude, 1)
	local equivalentDistance = (peakDownwardVelocity * peakDownwardVelocity) / (2 * g)

	if equivalentDistance <= minDistance then
		return 0, equivalentDistance
	end

	local span = math.max(lethalDistance - minDistance, 1)
	local t = math.clamp((equivalentDistance - minDistance) / span, 0, 1)
	local damage = damageMultiplier * (t ^ curveExponent) * 100
	return damage, equivalentDistance
end

-- === per-character internal tracking (not part of the public API) =====

local function ensureEntry(character: Model, player: Player?): CharacterEntry
	local existing = characterEntries[character]
	if existing then
		if player then
			existing.Player = player
		end
		return existing
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local entry: CharacterEntry = {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
		Player = player,
		Enabled = false,
		IsFalling = false,
		PeakDownwardVelocity = 0,
		FastFallSignaled = false,
		Connections = {},
		FallSignal = nil,
	}
	characterEntries[character] = entry

	local stateConn = humanoid.StateChanged:Connect(function(_old, new)
		if not entry.Enabled then
			return
		end

		if new == Enum.HumanoidStateType.Freefall then
			entry.IsFalling = true
			entry.PeakDownwardVelocity = 0
			entry.FastFallSignaled = false
			return
		end

		local isLandingState = new == Enum.HumanoidStateType.Landed
			or new == Enum.HumanoidStateType.Swimming
			or new == Enum.HumanoidStateType.Running

		if isLandingState and entry.IsFalling then
			entry.IsFalling = false

			if entry.FastFallSignaled then
				entry.FastFallSignaled = false
				if entry.Player then
					CombatEvents.FastFallEnded:Fire(entry.Player)
					FallFeedbackSync:FireAllClients("FastFallEnded", entry.Player) -- ADD
				end
			end

			local custom = customData[character]
			local group = groupOfCharacter[character]
			local options = getEffectiveOptions(character)

			local minDistance = (custom and custom.MinDistance) or (group and group.MinDistance) or FallTuning.MinDistance
			local damageMultiplier = (custom and custom.DamageMultiplier) or (group and group.DamageMultiplier) or FallTuning.DamageMultiplier
			local lethalDistance = options.LethalDistance or FallTuning.LethalDistance
			local curveExponent = options.Curve or FallTuning.Curve
			local materialsDamage: MaterialsDamageOptions = options.MaterialsDamage or {}

			print("[FallService] raw FloorMaterial at landing:", humanoid.FloorMaterial)
			local landingMaterial = resolveLandingMaterial(character, entry.RootPart, humanoid.FloorMaterial)
			print("[FallService] resolved landing material:", landingMaterial)
			local materialMultiplier = materialsDamage[landingMaterial.Name]

			local damage = 0
			local equivalentDistance = 0

			if new == Enum.HumanoidStateType.Swimming or materialMultiplier == 0 then
				damage = 0
			else
				local gravity = Workspace.Gravity
				damage, equivalentDistance = calculateDamage(
					entry.PeakDownwardVelocity,
					gravity,
					minDistance,
					damageMultiplier * (materialMultiplier or 1),
					lethalDistance,
					curveExponent
				)
			end

			if damage > 0 and humanoid.Health > 0 then
				humanoid:TakeDamage(damage)
			end

			if entry.FallSignal then
				entry.FallSignal:Fire({
					PeakFallSpeed = entry.PeakDownwardVelocity,
					EquivalentDistance = equivalentDistance,
					Damage = damage,
					LandingMaterial = landingMaterial,
				})
			end

			if entry.Player then
				CombatEvents.FallImpact:Fire(entry.Player, entry.PeakDownwardVelocity, damage, landingMaterial)
				FallFeedbackSync:FireAllClients("FallImpact", entry.Player, entry.PeakDownwardVelocity, damage, landingMaterial) -- ADD
			end


			if humanoid.Health > 0 then
				RagdollAPI:Unragdoll(entry.Player.Character)
			end
			entry.PeakDownwardVelocity = 0
		end
	end)
	table.insert(entry.Connections, stateConn)

	return entry
end

RunService.Heartbeat:Connect(function()
	for character, entry in pairs(characterEntries) do
		if entry.Enabled and entry.IsFalling then
			local downwardSpeed = -entry.RootPart.AssemblyLinearVelocity.Y
			if downwardSpeed > entry.PeakDownwardVelocity then
				entry.PeakDownwardVelocity = downwardSpeed
			end

			if not entry.FastFallSignaled then
				local options = getEffectiveOptions(character)
				local fastFallVelocity = options.FastFallVelocity or FallTuning.FastFallVelocity
				if downwardSpeed >= fastFallVelocity then
					entry.FastFallSignaled = true
					if entry.Player then
						RagdollAPI:Ragdoll(entry.Player.Character, "Manual")
						CombatEvents.FastFallBegan:Fire(entry.Player, downwardSpeed)
						FallFeedbackSync:FireAllClients("FastFallBegan", entry.Player, downwardSpeed) -- ADD
					end
				end
			end
		end
	end
end)

local function cleanupCharacter(character: Model)
	local entry = characterEntries[character]
	if not entry then
		return
	end
	for _, conn in ipairs(entry.Connections) do
		conn:Disconnect()
	end
	characterEntries[character] = nil
	groupOfCharacter[character] = nil
	customData[character] = nil
end

Players.PlayerRemoving:Connect(function(player)
	if player.Character then
		cleanupCharacter(player.Character)
	end
end)

-- === FallService (called with `:` on the module table itself, matching the requested API) ==

function FallService.new(groupName: string, minDistance: number, damageMultiplier: number, options: FallOptions?)
	assert(groups[groupName] == nil, `FallGroup "{groupName}" already exists`)
	local self = setmetatable({
		Name = groupName,
		MinDistance = minDistance,
		DamageMultiplier = damageMultiplier,
		Options = options or {},
		_linkedPlayers = {} :: { [Player]: boolean },
	}, FallGroup)
	groups[groupName] = self
	return self
end

function FallService:GetGroup(groupName: string)
	return groups[groupName]
end

function FallService:GetGroupOf(characterOrPlayer: Instance)
	local character = resolveCharacter(characterOrPlayer)
	return character and groupOfCharacter[character]
end

--- Pass minDistance/damageMultiplier as nil (both) to clear the override for this
--- character/player and fall back to whatever group it belongs to.
function FallService:SetCustomData(characterOrPlayer: Instance, minDistance: number?, damageMultiplier: number?, options: FallOptions?)
	local character = resolveCharacter(characterOrPlayer)
	if not character then
		return
	end
	if minDistance == nil and damageMultiplier == nil then
		customData[character] = nil
	else
		customData[character] = { MinDistance = minDistance, DamageMultiplier = damageMultiplier, Options = options }
	end
end

function FallService:GetCustomData(characterOrPlayer: Instance): CustomDataEntry?
	local character = resolveCharacter(characterOrPlayer)
	return character and customData[character]
end

--- Returns a per-character signal that fires with FallEventData on every landing while
--- enabled. Created lazily (on Enable/LinkPlayer) and constant for that character's lifetime.
--- Pass inInvocation = true if calling this synchronously from inside a
--- CharacterAdded/PlayerAdded callback, in case this runs before FallService's own
--- CharacterAdded handling has created the entry yet -- this briefly waits for it instead
--- of returning nil.
function FallService:GetFallSignalFor(characterOrPlayer: Instance, inInvocation: boolean?)
	local character = resolveCharacter(characterOrPlayer)
	if not character then
		return nil
	end

	local entry = characterEntries[character]
	if not entry and inInvocation then
		local waited = 0
		while not characterEntries[character] and waited < 30 do
			task.wait()
			waited += 1
		end
		entry = characterEntries[character]
	end

	if not entry then
		return nil
	end

	if not entry.FallSignal then
		entry.FallSignal = Signal.new<<(data: FallEventData) -> ()>>()
	end
	return entry.FallSignal
end

-- === FallGroup ===========================================================

function FallGroup:Enable(character: Model)
	local entry = ensureEntry(character, nil)
	entry.Enabled = true
	if not entry.FallSignal then
		entry.FallSignal = Signal.new<<(data: FallEventData) -> ()>>()
	end
	groupOfCharacter[character] = self
end

function FallGroup:Disable(character: Model)
	local entry = characterEntries[character]
	if entry then
		entry.Enabled = false
		entry.IsFalling = false
	end
	if groupOfCharacter[character] == self then
		groupOfCharacter[character] = nil
	end
end

function FallGroup:LinkPlayer(player: Player)
	self._linkedPlayers[player] = true

	local function onCharacterAdded(character: Model)
		if not self._linkedPlayers[player] then
			return
		end
		local entry = ensureEntry(character, player)
		entry.Player = player
		self:Enable(character)
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

function FallGroup:UnlinkPlayer(player: Player)
	self._linkedPlayers[player] = nil
	if player.Character then
		self:Disable(player.Character)
	end
end

function FallGroup:Toggle(characterOrPlayer: Instance, enabled: boolean)
	if characterOrPlayer:IsA("Player") then
		if enabled then
			self:LinkPlayer(characterOrPlayer :: Player)
		else
			self:UnlinkPlayer(characterOrPlayer :: Player)
		end
	else
		if enabled then
			self:Enable(characterOrPlayer :: Model)
		else
			self:Disable(characterOrPlayer :: Model)
		end
	end
end

return FallService
