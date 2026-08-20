--!strict
--[[
	CorpseHandler.lua  (Ch 16.10-adjacent — corpse persistence)

	CLONE-BASED (not "reuse the leftover dead Model" — this project's respawn flow destroys
	the old Character on respawn, so that assumption was wrong): CreateFromCharacter clones
	the already-ragdolled character (so the clone inherits ragdoll pose, disabled Motor6Ds,
	the "Ragdolled" Attribute, CollisionGroup — everything, since those are all just normal
	instance properties Clone() carries over), parents the clone into a dedicated
	workspace.Corpses folder, and re-pins the clone's own parts to server network ownership
	(a fresh clone defaults back to Automatic ownership). RagdollServer.server.lua destroys
	the ORIGINAL character shortly after cloning it, so you don't end up with two overlapping
	ragdolls in the same spot.

	Once created, a corpse:
	  1. Is tagged "Corpse" (CollectionService, Ch 1.6 convention).
	  2. Is watched for settling — once every part has stayed below
	     RagdollTuning.CorpseSettleVelocityThreshold for CorpseSettleTime seconds, every part
	     anchors in place (cheap to simulate, stays exactly where it landed).
	  3. Unanchors again (and restarts the settle timer) if Touched, so it can be shoved.
	  4. Is destroyed outright after RagdollTuning.CorpseLifetime seconds (math.huge to
	     disable).

	WEIGHT: corpse parts use whatever CustomPhysicalProperties/density the rig parts already
	have — SetWeightMultiplier below is a hook for a future gear system (Ch 7/16.2: a corpse
	carrying more equipment should weigh + feel heavier) to scale density per part without
	this module needing to know anything about inventory. Call it on the LIVE character
	before death if you want the resulting corpse to inherit the scaled density (Clone()
	will carry it over), or on the corpse directly afterward.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatEvents = require(CombatFramework.Shared.CombatEvents)
local RagdollTuning = require(CombatFramework.Shared.Config.RagdollTuning)

local CORPSE_TAG = "Corpse"
local TOUCH_DEBOUNCE = 0.5

local CorpseHandler = {}

type CorpseEntry = {
	Parts: { BasePart },
	SettledLowTime: number,
	Anchored: boolean,
	LastDisturbedAt: number,
	TouchConnections: { RBXScriptConnection },
}

local corpses: { [Model]: CorpseEntry } = {}

local corpsesFolder: Folder? = nil
local function getCorpsesFolder(): Folder
	if corpsesFolder and corpsesFolder.Parent then
		return corpsesFolder
	end
	local existing = Workspace:FindFirstChild("Corpses")
	if existing and existing:IsA("Folder") then
		corpsesFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Corpses"
	folder.Parent = Workspace
	corpsesFolder = folder
	return folder
end

local function collectParts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and not descendant.Name:match("NoCollision$") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function setAnchored(entry: CorpseEntry, anchored: boolean)
	if entry.Anchored == anchored then
		return
	end
	entry.Anchored = anchored
	for _, part in ipairs(entry.Parts) do
		if part.Parent then
			part.Anchored = anchored
		end
	end
end

local function connectDisturbance(corpse: Model, entry: CorpseEntry)
	for _, part in ipairs(entry.Parts) do
		local conn = part.Touched:Connect(function(_hit)
			if not entry.Anchored then
				return
			end
			local now = os.clock()
			if now - entry.LastDisturbedAt < TOUCH_DEBOUNCE then
				return
			end
			entry.LastDisturbedAt = now
			entry.SettledLowTime = 0
			setAnchored(entry, false)
			CombatEvents.CorpseDisturbed:Fire(corpse)
		end)
		table.insert(entry.TouchConnections, conn)
	end
end

local function track(corpse: Model)
	CollectionService:AddTag(corpse, CORPSE_TAG)

	local entry: CorpseEntry = {
		Parts = collectParts(corpse),
		SettledLowTime = 0,
		Anchored = false,
		LastDisturbedAt = 0,
		TouchConnections = {},
	}
	corpses[corpse] = entry
	connectDisturbance(corpse, entry)

	corpse.AncestryChanged:Connect(function(_child, parent)
		if not parent then
			local existing = corpses[corpse]
			if existing then
				for _, conn in ipairs(existing.TouchConnections) do
					conn:Disconnect()
				end
				corpses[corpse] = nil
			end
		end
	end)

	if RagdollTuning.CorpseLifetime < math.huge then
		task.delay(RagdollTuning.CorpseLifetime, function()
			if corpse.Parent then
				corpse:Destroy()
			end
		end)
	end
end

--- Clones `character` (which must already be ragdolled — RagdollAPI does this before
--- calling in) into workspace.Corpses, re-pins its parts to server network ownership, and
--- starts settle/anchor/lifetime tracking on the CLONE. Returns the corpse Model. Caller
--- (RagdollServer.server.lua) is responsible for cleaning up the original `character`.
function CorpseHandler.CreateFromCharacter(character: Model): Model?
	if not character.Parent then
		return nil
	end

    character.Archivable = true
	local corpse = character:Clone()

    print(corpse, character)
	corpse.Name = character.Name .. "_Corpse"
	corpse.Parent = getCorpsesFolder()

	for _, part in ipairs(collectParts(corpse)) do
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
	end
	local rootPart = corpse:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart then
		pcall(function()
			rootPart:SetNetworkOwner(nil)
		end)
	end

	track(corpse)
	CombatEvents.CorpseCreated:Fire(corpse, character)
	return corpse
end

--- Placeholder hook for a future gear/inventory system: scales every part's density so a
--- more heavily-equipped corpse (Ch 7.10 Rescue: drag/carry weight) feels heavier.
--- `multiplier` of 1 = the rig's stock density.
function CorpseHandler.SetWeightMultiplier(model: Model, multiplier: number)
	for _, part in ipairs(collectParts(model)) do
		local current = part.CurrentPhysicalProperties
		part.CustomPhysicalProperties = PhysicalProperties.new(
			current.Density * multiplier,
			current.Friction,
			current.Elasticity,
			current.FrictionWeight,
			current.ElasticityWeight
		)
	end
end

RunService.Heartbeat:Connect(function(dt: number)
	for corpse, entry in pairs(corpses) do
		if entry.Anchored or not corpse.Parent then
			continue
		end

		local maxSpeed = 0
		for _, part in ipairs(entry.Parts) do
			if part.Parent then
				local speed = part.AssemblyLinearVelocity.Magnitude
				if speed > maxSpeed then
					maxSpeed = speed
				end
			end
		end

		if maxSpeed <= RagdollTuning.CorpseSettleVelocityThreshold then
			entry.SettledLowTime += dt
			if entry.SettledLowTime >= RagdollTuning.CorpseSettleTime then
				setAnchored(entry, true)
				CombatEvents.CorpseSettled:Fire(corpse)
			end
		else
			entry.SettledLowTime = 0
		end
	end
end)

return CorpseHandler