--!strict
--[[
	SoundService.lua  (Ch 10 Audio Framework)

	The single audio playback primitive every other system uses. See file header history
	for the pooling/continuous/global-effects design -- this pass adds RESOLUTION
	ROBUSTNESS: a category is never trusted to just work. Every candidate Sound's SoundId
	is validated before it's eligible to play, and if a category comes up with nothing
	playable (missing folder, empty folder, or every child stuck on a placeholder
	"rbxassetid://0"), SoundService walks that category's `Fallback` chain (SoundLibrary
	.lua) until it finds one that does. This means an unfinished material folder or an
	authoring mistake degrades to a sane default (Concrete, for footsteps) instead of
	silently playing nothing -- the same "never leaves a system quietly broken" spirit as
	the rest of the framework's config-driven fallbacks (e.g. FootstepMaterialGroups'
	DEFAULT_GROUP).
]]

local SoundServiceEngine = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local SoundLibrary = require(script.Parent.Config.SoundLibrary)

local SoundService = {}

export type EffectDescriptor = {
	Type: string,
	Properties: { [string]: any }?,
}

export type PlayOptions = {
	Parent: Instance?,
	Variant: string?,
	PlaybackSpeed: number?,
	PitchVariance: number?,
	Volume: number?,
	Effects: { EffectDescriptor }?,
	MaxDistance: number?,
	RollOffMode: Enum.RollOffMode?,
	EmitterSize: number?,
	FadeInTime: number?,
	TTL: number?, -- PlayContinuous only: auto-stops if not refreshed within this many seconds
}

type PooledSound = { Instance: Sound, InUse: boolean }

local MAX_POOL_SIZE = 96
local pool: { PooledSound } = {}

local continuous: { [string]: { Sound: Sound, TargetVolume: number, FadeRate: number, ExpiresAt: number? } } = {}
local globalEffects: { [string]: Instance } = {}
local lastVariant: { [string]: string } = {}
local warnedCategories: { [string]: boolean } = {}

-- === Pool management (Ch 1.6) ==========================================

local function acquire(): Sound
	for _, entry in ipairs(pool) do
		if not entry.InUse then
			entry.InUse = true
			return entry.Instance
		end
	end

	local sound = Instance.new("Sound")
	sound.Name = "CombatFrameworkPooledSound"

	if #pool < MAX_POOL_SIZE then
		table.insert(pool, { Instance = sound, InUse = true })
	end

	return sound
end

local function release(sound: Sound)
	for _, entry in ipairs(pool) do
		if entry.Instance == sound then
			entry.InUse = false
			sound.Playing = false
			sound.Parent = nil
			for _, child in ipairs(sound:GetChildren()) do
				child:Destroy()
			end
			return
		end
	end
	sound:Destroy()
end

-- === Resolution (folder lookup, validity filtering, fallback chain) ====

local function resolveTarget(path: { string }): Instance?
	local current: Instance = SoundServiceEngine
	for _, name in ipairs(path) do
		local nextInst = current:FindFirstChild(name)
		if not nextInst then
			return nil
		end
		current = nextInst
	end
	return current
end

--- A SoundId only counts as playable if it's non-empty and isn't the "rbxassetid://0"
--- placeholder Studio leaves on a freshly-created, not-yet-assigned Sound instance.
local function isValidSoundId(id: string?): boolean
	if not id or id == "" then
		return false
	end
	if id == "rbxassetid://0" or id == "rbxasset://0" then
		return false
	end
	if not (string.match(id, "^rbxassetid://%d+$") or string.match(id, "^rbxasset://")) then
		return false
	end
	return true
end

--- Handles both shapes (a lone Sound, or a folder of variant Sounds), filtering out any
--- child whose SoundId fails isValidSoundId before it's eligible to be picked at all --
--- a folder with 3 variants where 1 has a placeholder ID just behaves like a 2-variant
--- folder, it doesn't ever attempt to play the broken one.
local function pickVariant(category: string, target: Instance, forcedVariant: string?): Sound?
	if target:IsA("Sound") then
		local sound = target :: Sound
		return if isValidSoundId(sound.SoundId) then sound else nil
	end

	local candidates: { Sound } = {}
	for _, child in ipairs(target:GetChildren()) do
		if child:IsA("Sound") and isValidSoundId((child :: Sound).SoundId) then
			if forcedVariant then
				if child.Name == forcedVariant then
					return child :: Sound
				end
			else
				table.insert(candidates, child :: Sound)
			end
		end
	end

	if forcedVariant or #candidates == 0 then
		return nil
	end
	if #candidates == 1 then
		return candidates[1]
	end

	local previous = lastVariant[category]
	local pick = candidates[math.random(1, #candidates)]
	if pick.Name == previous then
		local idx = table.find(candidates, pick) or 1
		pick = candidates[(idx % #candidates) + 1]
	end
	lastVariant[category] = pick.Name
	return pick
end

local function warnOnce(key: string, message: string)
	if warnedCategories[key] then
		return
	end
	warnedCategories[key] = true
	warn(message)
end

--- Resolves `category` to a playable template, walking the Fallback chain (SoundLibrary
--- .lua) if the requested category has no folder, no valid children, or doesn't exist.
--- `visited` guards against a Fallback cycle. Returns the template Sound, the category it
--- ACTUALLY resolved to (used for lastVariant bookkeeping and tuning), and that
--- category's own SoundDefinition -- or nil across all three if the whole chain is empty.
local function resolveTemplate(category: string, forcedVariant: string?): (Sound?, string?, SoundLibrary.SoundDefinition?)
	local visited: { [string]: boolean } = {}
	local current: string? = category

	while current and not visited[current] do
		visited[current] = true
		local def = SoundLibrary[current]
		if not def then
			warnOnce(category, `SoundService: unknown category "{current}"` .. (if current ~= category then ` (fallback from "{category}")` else ""))
			return nil, nil, nil
		end

		local target = resolveTarget(def.FolderPath)
		if target then
			local template = pickVariant(current, target, forcedVariant)
			if template then
				if current ~= category then
					warnOnce(category, `SoundService: "{category}" has no playable sound, falling back to "{current}"`)
				end
				return template, current, def
			end
		end

		current = def.Fallback
	end

	warnOnce(category, `SoundService: "{category}" and its entire fallback chain have no playable sound`)
	return nil, nil, nil
end

-- === Effects =============================================================

local function applyEffects(sound: Sound, effects: { EffectDescriptor }?)
	if not effects then
		return
	end
	for _, descriptor in ipairs(effects) do
		local ok, instance = pcall(Instance.new, descriptor.Type)
		if ok and instance then
			for key, value in pairs(descriptor.Properties or {}) do
				(instance :: any)[key] = value
			end
			instance.Parent = sound
		else
			warn(`SoundService: unknown or invalid SoundEffect type "{descriptor.Type}"`)
		end
	end
end

-- === Public API: one-shot ================================================

function SoundService.Play(category: string, options: PlayOptions?): Sound?
	local opts = options or {}
	local template, _resolvedCategory, def = resolveTemplate(category, opts.Variant)
	if not template or not def then
		return nil
	end

	local sound = acquire()
	sound.SoundId = template.SoundId
	sound.Looped = false
	sound.RollOffMode = opts.RollOffMode or def.RollOffMode or Enum.RollOffMode.InverseTapered
	sound.MaxDistance = opts.MaxDistance or def.MaxDistance or 80
	sound.EmitterSize = opts.EmitterSize or def.EmitterSize or 5

	local pitchVariance = opts.PitchVariance or def.PitchVariance or 0
	local randomPitch = 1 + (math.random() * 2 - 1) * pitchVariance
	sound.PlaybackSpeed = (opts.PlaybackSpeed or 1) * randomPitch

	local targetVolume = template.Volume * (opts.Volume or 1)
	applyEffects(sound, opts.Effects)
	sound.Parent = opts.Parent or SoundServiceEngine

	if opts.FadeInTime and opts.FadeInTime > 0 then
		sound.Volume = 0
		sound:Play()
		TweenService:Create(sound, TweenInfo.new(opts.FadeInTime), { Volume = targetVolume }):Play()
	else
		sound.Volume = targetVolume
		sound:Play()
	end

	local endedConn: RBXScriptConnection
	endedConn = sound.Ended:Connect(function()
		endedConn:Disconnect()
		release(sound)
	end)

	return sound
end

-- === Public API: continuous / held =======================================

function SoundService.PlayContinuous(category: string, sourceId: string, options: PlayOptions?)
	local opts = options or {}

	if (opts.Volume or 1) <= 0 then
		SoundService.StopContinuous(sourceId)
		return
	end

	local template, _resolvedCategory, def = resolveTemplate(category, opts.Variant)
	if not template or not def then
		SoundService.StopContinuous(sourceId)
		return
	end

	local expiresAt = if opts.TTL then os.clock() + opts.TTL else nil

	local existing = continuous[sourceId]
	if existing then
		existing.Sound.PlaybackSpeed = opts.PlaybackSpeed or existing.Sound.PlaybackSpeed
		existing.TargetVolume = def.BaseVolume * (opts.Volume or 1)
		existing.ExpiresAt = expiresAt
		if opts.Parent and existing.Sound.Parent ~= opts.Parent then
			existing.Sound.Parent = opts.Parent
		end
		return
	end

	local sound = acquire()
	sound.SoundId = template.SoundId
	sound.Looped = true
	sound.RollOffMode = opts.RollOffMode or def.RollOffMode or Enum.RollOffMode.InverseTapered
	sound.MaxDistance = opts.MaxDistance or def.MaxDistance or 80
	sound.EmitterSize = opts.EmitterSize or def.EmitterSize or 5
	sound.PlaybackSpeed = opts.PlaybackSpeed or 1
	sound.Volume = 0
	applyEffects(sound, opts.Effects)
	sound.Parent = opts.Parent or SoundServiceEngine
	sound:Play()

	continuous[sourceId] = {
		Sound = sound,
		TargetVolume = def.BaseVolume * (opts.Volume or 1),
		FadeRate = 6,
		ExpiresAt = expiresAt,
	}
end

function SoundService.StopContinuous(sourceId: string, fadeOutTime: number?)
	local entry = continuous[sourceId]
	if not entry then
		return
	end
	continuous[sourceId] = nil

	if fadeOutTime and fadeOutTime > 0 then
		local tween = TweenService:Create(entry.Sound, TweenInfo.new(fadeOutTime), { Volume = 0 })
		tween:Play()
		tween.Completed:Once(function()
			release(entry.Sound)
		end)
	else
		release(entry.Sound)
	end
end

RunService.Heartbeat:Connect(function(dt: number)
	local now = os.clock()
	for sourceId, entry in pairs(continuous) do
		if entry.ExpiresAt and now > entry.ExpiresAt then
			SoundService.StopContinuous(sourceId, 0.25)
			continue
		end
		local alpha = math.clamp(entry.FadeRate * dt, 0, 1)
		entry.Sound.Volume += (entry.TargetVolume - entry.Sound.Volume) * alpha
	end
end)

-- === Global (full-mix) effects ==========================================

function SoundService.SetGlobalEffect(key: string, descriptor: EffectDescriptor)
	SoundService.ClearGlobalEffect(key)
	local ok, instance = pcall(Instance.new, descriptor.Type)
	if not ok or not instance then
		warn(`SoundService: invalid global effect type "{descriptor.Type}"`)
		return
	end
	for prop, value in pairs(descriptor.Properties or {}) do
		(instance :: any)[prop] = value
	end
	instance.Name = `CombatFrameworkGlobalEffect_{key}`
	instance.Parent = SoundServiceEngine
	globalEffects[key] = instance
end

function SoundService.ClearGlobalEffect(key: string)
	local existing = globalEffects[key]
	if existing then
		existing:Destroy()
		globalEffects[key] = nil
	end
end

return SoundService