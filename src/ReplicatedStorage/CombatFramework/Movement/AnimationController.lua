--!strict
--[[
	AnimationController.lua  (Ch 9 Animation Framework)

	Every stance in Stances.lua can optionally declare its own Idle/Move animations; any
	stance/variant that doesn't falls back to DEFAULT_ANIMATIONS below. This module owns
	loading/playing/crossfading whichever one is correct for the character's current
	stance + whether it's actually moving right now — UNLESS that stance has
	AnimationsEnabled = false, in which case it owns nothing at all (see Section 2 below).

	Instantiated SERVER-SIDE (see MovementServer.server.lua): Roblox replicates Animator
	track playback to every client automatically once played from an Animator under a
	replicated Humanoid, so there is no need for a parallel client-side animation player.

	Swap the "rbxassetid://0" placeholders in Stances.lua / DEFAULT_ANIMATIONS below for
	real animation IDs before relying on this (targets the installed DOGU15 rig, Ch 17.6).

	--------------------------------------------------------------------------------
	1) Spawn / crossfade fixes (unchanged from previous pass)
	--------------------------------------------------------------------------------
	- .new() calls _refresh() itself so an Idle track is playing the instant the character
	  spawns, instead of waiting for the first external SetStance/SetMoving call.
	- That very first play uses INITIAL_FADE_TIME (instant); afterwards, settling to Idle
	  uses a snappier fade than starting to Move.
	- SetMoving is hysteresis-gated (MOVE_STATE_HYSTERESIS) so velocity noise right around
	  the movement threshold can't retrigger overlapping crossfades.

	--------------------------------------------------------------------------------
	2) JointMask REMOVED — this was the source of the IK conflict
	--------------------------------------------------------------------------------
	The previous JointMask feature reset specific Motor6D.Transforms to identity every
	Heartbeat to fake per-joint exclusion. If anything else in the project (an IK leg/arm
	controller) was ALSO driving those same joints, the two systems fought over them every
	frame — stomp, IK correction, stomp, IK correction — which is almost certainly what
	"conflicting with the IK legs/arms controller" was describing. That mechanism is gone.

	In its place: AnimationsEnabled = false on a Stance definition (Stances.lua). When the
	current stance has this set, AnimationController stops any track it was playing and
	then does nothing at all — no Play, no Stop, no joint writes — for as long as the
	character remains in that stance. This is a clean handoff: exactly one system (the IK
	controller, or whatever else) owns those joints while the stance is active, instead of
	two systems both trying to own them simultaneously. See Mounted/Climbing in Stances.lua
	for the intended usage (mount rigs and climb IK are the obvious candidates).

	--------------------------------------------------------------------------------
	3) Default animations per stance
	--------------------------------------------------------------------------------
	Stances.lua's Animations field (and Idle/Move within it) is fully optional now. Missing
	entries resolve to DEFAULT_ANIMATIONS below, so most stances don't need to repeat
	boilerplate animation ids — only stances that want to override get an Animations table.

	--------------------------------------------------------------------------------
	4) Per-animation speed (unchanged from previous pass)
	--------------------------------------------------------------------------------
	Stances.lua's StanceAnimationEntry.Speed, applied via AnimationTrack:AdjustSpeed().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local Stances = require(CombatFramework.Shared.Config.Stances)

local AnimationController = {}
AnimationController.__index = AnimationController

export type AnimationControllerInstance = typeof(setmetatable(
	{} :: {
		Humanoid: Humanoid,
		Animator: Animator,
		_tracks: { [string]: AnimationTrack },
		_currentStance: string,
		_isMoving: boolean,
		_currentTrackKey: string?,

		_pendingMoving: boolean?,
		_pendingMovingSince: number,
	},
	AnimationController
))

-- Fallback used whenever a stance (or a specific Idle/Move within it) doesn't declare its
-- own animation. Swap these ids for real defaults before relying on this.
local DEFAULT_ANIMATIONS: Stances.StanceAnimations = {
	Idle = { Id = "rbxassetid://2510197257", Speed = 1 },
	Move = { Id = "rbxassetid://2510202577", Speed = 1 },
}

-- Sentinel _currentTrackKey used while parked in an AnimationsEnabled = false stance, so
-- _refresh can tell "nothing is playing because we're deliberately disabled" apart from
-- "nothing is playing because this is the very first frame" (both should feel instant when
-- animations resume, but neither should be confused with a normal Idle<->Move key).
local DISABLED_KEY = "__AnimationsDisabled__"

-- Fade times: the FIRST-EVER play (right after spawn, or right after leaving a disabled
-- stance) is instant so there's never a moment with no animation playing. After that,
-- settling to idle is snappier than starting to move.
local INITIAL_FADE_TIME = 0
local CROSSFADE_TIME_TO_IDLE = 0.1
local CROSSFADE_TIME_TO_MOVE = 0.2

-- How long a new moving/not-moving reading must persist before AnimationController commits
-- to it and actually swaps tracks. Absorbs velocity noise right around the movement
-- threshold (e.g. while MomentumController is decelerating through it) so a single frame of
-- noise can't retrigger a crossfade.
local MOVE_STATE_HYSTERESIS = 0

local function disableDefaultAnimate(humanoid: Humanoid)
	local character = humanoid.Parent
	if not character then
		return
	end

	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		animate.Enabled = false
	end

	for _, track in humanoid:GetPlayingAnimationTracks() do
		track:Stop(0)
	end
end

function AnimationController.new(humanoid: Humanoid): AnimationControllerInstance
	disableDefaultAnimate(humanoid)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local self = setmetatable({
		Humanoid = humanoid,
		Animator = animator :: Animator,
		_tracks = {},
		_currentStance = "Standing",
		_isMoving = false,
		_currentTrackKey = nil,

		_pendingMoving = nil,
		_pendingMovingSince = 0,
	}, AnimationController) :: any

	-- Establish the initial track (or correctly stay silent if Standing somehow started
	-- disabled) right now, instead of waiting for the first external SetStance/SetMoving.
	self:_refresh()

	return self
end

--- Resolves the animation entry for (stanceName, variant), falling back through:
--- stance-specific override -> DEFAULT_ANIMATIONS -> nil (no valid id, e.g. still a
--- rbxassetid://0 placeholder).
local function resolveEntry(stanceName: string, variant: "Idle" | "Move"): Stances.StanceAnimationEntry?
	local def = Stances[stanceName]
	local override = def and def.Animations and def.Animations[variant]
	local entry = override or DEFAULT_ANIMATIONS[variant]
	if not entry or not entry.Id or entry.Id == "" or entry.Id == "rbxassetid://0" then
		return nil
	end
	return entry
end

function AnimationController._getOrLoadTrack(self: AnimationControllerInstance, stanceName: string, variant: "Idle" | "Move"): AnimationTrack?
	local key = stanceName .. "_" .. variant
	local existing = self._tracks[key]
	if existing then
		return existing
	end

	local entry = resolveEntry(stanceName, variant)
	if not entry then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = entry.Id

	local ok, track = pcall(function()
		return self.Animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		warn(`AnimationController: failed to load animation for {key}`)
		return nil
	end

	-- Explicit, documented layer for locomotion so future upper-body/weapon animations
	-- (aim, reload, fire, inspect — Ch 9) have a predictable priority to sit above.
	(track :: AnimationTrack).Priority = Enum.AnimationPriority.Movement

	self._tracks[key] = track
	return track
end

function AnimationController._refresh(self: AnimationControllerInstance)
	local def = Stances[self._currentStance]
	local animationsEnabled = if def then def.AnimationsEnabled ~= false else true

	if not animationsEnabled then
		-- IMPORTANT: never fully stop the Animator. IKControl blends on top of whatever
		-- the Animator is currently evaluating each frame — with zero tracks playing,
		-- Roblox stops actively stepping this Humanoid's pose and IKControl has nothing
		-- to solve against, which is what produces straight/locked legs and arms.
		-- Keep the stance's own Idle track playing but faded to ~0 weight instead: this
		-- keeps evaluation alive without visibly contributing to the pose IK now owns.
		local keepAliveTrack = self:_getOrLoadTrack(self._currentStance, "Idle")
		if keepAliveTrack then
			if self._currentTrackKey ~= DISABLED_KEY then
				-- coming from a real track: crossfade weight down instead of stopping
				if not keepAliveTrack.IsPlaying then
					keepAliveTrack:Play(CROSSFADE_TIME_TO_IDLE, 0.001)
				else
					keepAliveTrack:AdjustWeight(0.001, CROSSFADE_TIME_TO_IDLE)
				end
				-- stop whatever WAS playing, now that the keep-alive track is taking over
				if self._currentTrackKey then
					local oldTrack = self._tracks[self._currentTrackKey]
					if oldTrack and oldTrack ~= keepAliveTrack and oldTrack.IsPlaying then
						oldTrack:Stop(CROSSFADE_TIME_TO_IDLE)
					end
				end
			elseif not keepAliveTrack.IsPlaying then
				keepAliveTrack:Play(0, 0.001)
			end
		end
		self._currentTrackKey = DISABLED_KEY
		return
	end

	local variant: "Idle" | "Move" = if self._isMoving then "Move" else "Idle"
	local key = self._currentStance .. "_" .. variant
	if key == self._currentTrackKey then
		return
	end

	-- Instant if this is the very first play ever, OR we're coming out of a disabled
	-- stance (either way, nothing was previously playing that we'd want to visibly
	-- crossfade out of).
	local isFreshStart = self._currentTrackKey == nil or self._currentTrackKey == DISABLED_KEY

	local fadeTime = if isFreshStart
		then INITIAL_FADE_TIME
		elseif variant == "Idle" then CROSSFADE_TIME_TO_IDLE
		else CROSSFADE_TIME_TO_MOVE

	if self._currentTrackKey and self._currentTrackKey ~= DISABLED_KEY then
		local oldTrack = self._tracks[self._currentTrackKey]
		if oldTrack and oldTrack.IsPlaying then
			oldTrack:Stop(fadeTime)
		end
	end

	local newTrack = self:_getOrLoadTrack(self._currentStance, variant)
	if newTrack then
		newTrack:Play(fadeTime)
		local entry = resolveEntry(self._currentStance, variant)
		newTrack:AdjustSpeed(if entry and entry.Speed then entry.Speed else 1)
	end

	self._currentTrackKey = key
end

function AnimationController.SetStance(self: AnimationControllerInstance, stanceName: string)
	if Stances[stanceName] == nil then
		return
	end
	self._currentStance = stanceName
	self:_refresh()
end

--- Hysteresis-gated: a new moving/not-moving reading must persist for MOVE_STATE_HYSTERESIS
--- seconds before it's committed and actually swaps the Idle<->Move track.
function AnimationController.SetMoving(self: AnimationControllerInstance, isMoving: boolean)
	if isMoving == self._isMoving then
		self._pendingMoving = nil
		return
	end

	if self._pendingMoving ~= isMoving then
		self._pendingMoving = isMoving
		self._pendingMovingSince = os.clock()
		return
	end

	if os.clock() - self._pendingMovingSince < MOVE_STATE_HYSTERESIS then
		return
	end

	self._isMoving = isMoving
	self._pendingMoving = nil
	self:_refresh()
end

function AnimationController.Destroy(self: AnimationControllerInstance)
	for _, track in pairs(self._tracks) do
		track:Stop(0)
		track:Destroy()
	end
	table.clear(self._tracks)
end

return AnimationController