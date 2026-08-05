-- FirstPersonZoomController.lua (client-only) — replaces ZoomFirstPersonDriver.lua
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local FirstPersonZoomController = {}

local MIN_ZOOM = 0
local MAX_ZOOM = 20
local FP_THRESHOLD = 1.8
local SCROLL_STEP = 2
local KEY_ZOOM_SPEED = 12 -- studs/sec while I/O held

local currentZoom = 10
local enabled = false

-- Scroll wheel
UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseWheel then
		return
	end
	currentZoom = math.clamp(currentZoom - input.Position.Z * SCROLL_STEP, MIN_ZOOM, MAX_ZOOM)
end)

-- I/O keys (Roblox's default zoom keys) — held-key continuous zoom, read every frame
-- instead of relying on stock CameraModule, since that module goes inert once
-- CameraType is Scriptable and would otherwise never tell us I/O was pressed.
RunService.RenderStepped:Connect(function(dt)
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.I) then
		currentZoom = math.clamp(currentZoom - KEY_ZOOM_SPEED * dt, MIN_ZOOM, MAX_ZOOM)
	elseif UserInputService:IsKeyDown(Enum.KeyCode.O) then
		currentZoom = math.clamp(currentZoom + KEY_ZOOM_SPEED * dt, MIN_ZOOM, MAX_ZOOM)
	end

	enabled = currentZoom <= FP_THRESHOLD
end)

function FirstPersonZoomController.IsEnabled(): boolean
	return enabled
end

function FirstPersonZoomController.GetZoom(): number
	return currentZoom
end

-- Called by the render loop after CameraInertiaController:Disable() hands the camera
-- back, so third-person resumes at the distance the player was actually at.
function FirstPersonZoomController.ApplyThirdPersonZoom()
	player.CameraMinZoomDistance = math.max(currentZoom, 2)
	player.CameraMaxZoomDistance = MAX_ZOOM
end

return FirstPersonZoomController