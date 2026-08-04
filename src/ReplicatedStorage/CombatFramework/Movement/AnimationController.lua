--!strict
--[[
	AnimationController.lua  (Ch 9 Animation Framework)

	Every stance in Stances.lua declares an Idle and a Move animation. This module owns
	loading/playing/crossfading whichever one is correct for the character's current
	stance + whether it's actually moving right now.

	Instantiated SERVER-SIDE (see MovementServer.server.lua): Roblox replicates Animator
	track playback to every client automatically once played from an Animator under a
	replicated Humanoid, so there is no need for a parallel client-side animation player.

	Swap the "rbxassetid://0" placeholders in Stances.lua for real animation IDs before
	relying on this (targets the installed DOGU15 rig, Ch 17.6).
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
	},
	AnimationController
))

local CROSSFADE_TIME = 0.2

function AnimationController.new(humanoid: Humanoid): AnimationControllerInstance
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
	}, AnimationController) :: any

	return self
end

function AnimationController._getOrLoadTrack(self: AnimationControllerInstance, stanceName: string, variant: "Idle" | "Move"): AnimationTrack?
	local key = stanceName .. "_" .. variant
	local existing = self._tracks[key]
	if existing then
		return existing
	end

	local def = Stances[stanceName]
	if not def then
		return nil
	end

	local animId = def.Animations[variant]
	if not animId or animId == "" or animId == "rbxassetid://0" then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local ok, track = pcall(function()
		return self.Animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		warn(`AnimationController: failed to load animation for {key}`)
		return nil
	end

	self._tracks[key] = track
	return track
end

function AnimationController._refresh(self: AnimationControllerInstance)
	local variant: "Idle" | "Move" = if self._isMoving then "Move" else "Idle"
	local key = self._currentStance .. "_" .. variant
	if key == self._currentTrackKey then
		return
	end

	local newTrack = self:_getOrLoadTrack(self._currentStance, variant)

	if self._currentTrackKey then
		local oldTrack = self._tracks[self._currentTrackKey]
		if oldTrack and oldTrack.IsPlaying then
			oldTrack:Stop(CROSSFADE_TIME)
		end
	end

	if newTrack then
		newTrack:Play(CROSSFADE_TIME)
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

function AnimationController.SetMoving(self: AnimationControllerInstance, isMoving: boolean)
	if isMoving == self._isMoving then
		return
	end
	self._isMoving = isMoving
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
