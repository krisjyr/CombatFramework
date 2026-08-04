--!strict
--[[
	CameraShake.lua  (client-only)

	Two ways to use it:
	  - CameraShake.Shake(magnitude, duration) -- a one-off impulse that decays over
	    `duration` seconds (landing impacts).
	  - CameraShake.SetContinuous(key, magnitude) -- a sustained shake that stays at
	    `magnitude` until you call SetContinuous(key, 0) (ambient rumble while fast-falling).
	    Keyed so multiple sources (fast-fall, a future suppression status, etc.) can each
	    own their own continuous shake without stomping each other; magnitudes sum.

	Applies on top of whatever the default Roblox camera script is doing by binding at
	Enum.RenderPriority.Camera.Value + 1, which runs after the engine's own camera update
	each frame — the standard pattern for a non-destructive camera shake overlay.
]]

local RunService = game:GetService("RunService")

local CameraShake = {}

type Impulse = {
	Magnitude: number,
	Duration: number,
	Elapsed: number,
}

local impulses: { Impulse } = {}
local continuous: { [string]: number } = {}

local function totalContinuousMagnitude(): number
	local total = 0
	for _, magnitude in pairs(continuous) do
		total += magnitude
	end
	return total
end

local function update(_dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local magnitude = totalContinuousMagnitude()

	for i = #impulses, 1, -1 do
		local impulse = impulses[i]
		impulse.Elapsed += _dt
		if impulse.Elapsed >= impulse.Duration then
			table.remove(impulses, i)
			continue
		end
		local lifeFraction = 1 - (impulse.Elapsed / impulse.Duration)
		magnitude += impulse.Magnitude * lifeFraction
	end

	if magnitude <= 0.001 then
		return
	end

	local offsetPosition = Vector3.new(
		(math.random() - 0.5) * 2,
		(math.random() - 0.5) * 2,
		(math.random() - 0.5) * 2
	) * magnitude * 0.05

	local offsetRotationDegrees = Vector3.new(
		(math.random() - 0.5) * 2,
		(math.random() - 0.5) * 2,
		(math.random() - 0.5) * 2
	) * magnitude

	camera.CFrame = camera.CFrame
		* CFrame.new(offsetPosition)
		* CFrame.Angles(math.rad(offsetRotationDegrees.X), math.rad(offsetRotationDegrees.Y), math.rad(offsetRotationDegrees.Z))
end

RunService:BindToRenderStep("CombatFrameworkCameraShake", Enum.RenderPriority.Camera.Value + 1, update)

--- One-off decaying shake, e.g. a hard landing.
function CameraShake.Shake(magnitude: number, duration: number)
	table.insert(impulses, { Magnitude = magnitude, Duration = math.max(duration, 0.01), Elapsed = 0 })
end

--- Sustained shake at a constant magnitude until cleared with magnitude 0, e.g. an
--- ambient rumble while fast-falling. `key` lets multiple sources coexist without
--- clobbering each other.
function CameraShake.SetContinuous(key: string, magnitude: number)
	if magnitude <= 0 then
		continuous[key] = nil
	else
		continuous[key] = magnitude
	end
end

return CameraShake
