--!strict
--[[
	InputController.lua  (client-only)

	Raw WASD/gamepad reader, camera-relative — mirrors what Roblox's default ControlModule
	does internally, except WE own the whole pipeline. This exists because of a hard
	conflict: the default ControlModule calls Humanoid:Move() continuously on its own; if
	MomentumController ALSO calls Humanoid:Move() with a smoothed direction, the two fight
	every frame and whichever ran last wins — which is why smoothed turning never actually
	took visible effect in earlier passes. The only reliable fix is to disable the default
	controller entirely (see MovementClient.client.lua) and read input ourselves here.

	Produces a WORLD-SPACE, HORIZONTAL (Y=0) unit-or-zero vector every frame — exactly the
	shape MomentumController.Update expects as `moveDirection`.
]]

local UserInputService = game:GetService("UserInputService")

local InputController = {}
InputController.__index = InputController

export type InputControllerInstance = typeof(setmetatable(
	{} :: {
		_forward: boolean,
		_back: boolean,
		_left: boolean,
		_right: boolean,
		_gamepadThumbstick: Vector2,
		_connections: { RBXScriptConnection },
	},
	InputController
))

local KEY_FORWARD = { Enum.KeyCode.W, Enum.KeyCode.Up }
local KEY_BACK = { Enum.KeyCode.S, Enum.KeyCode.Down }
local KEY_LEFT = { Enum.KeyCode.A, Enum.KeyCode.Left }
local KEY_RIGHT = { Enum.KeyCode.D, Enum.KeyCode.Right }

local function matches(keyCode: Enum.KeyCode, list: { Enum.KeyCode }): boolean
	return table.find(list, keyCode) ~= nil
end

function InputController.new(): InputControllerInstance
	local self = setmetatable({
		_forward = false,
		_back = false,
		_left = false,
		_right = false,
		_gamepadThumbstick = Vector2.zero,
		_connections = {},
	}, InputController) :: any

	local function onInputBegan(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if matches(input.KeyCode, KEY_FORWARD) then
				self._forward = true
			elseif matches(input.KeyCode, KEY_BACK) then
				self._back = true
			elseif matches(input.KeyCode, KEY_LEFT) then
				self._left = true
			elseif matches(input.KeyCode, KEY_RIGHT) then
				self._right = true
			end
		end
	end

	local function onInputEnded(input: InputObject, _gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if matches(input.KeyCode, KEY_FORWARD) then
				self._forward = false
			elseif matches(input.KeyCode, KEY_BACK) then
				self._back = false
			elseif matches(input.KeyCode, KEY_LEFT) then
				self._left = false
			elseif matches(input.KeyCode, KEY_RIGHT) then
				self._right = false
			end
		end
	end

	local function onInputChanged(input: InputObject, _gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
			self._gamepadThumbstick = Vector2.new(input.Position.X, input.Position.Y)
		end
	end

	table.insert(self._connections, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(self._connections, UserInputService.InputEnded:Connect(onInputEnded))
	table.insert(self._connections, UserInputService.InputChanged:Connect(onInputChanged))

	return self
end

--- Returns a world-space, horizontal (Y=0), unit-or-zero move direction relative to the
--- given camera — exactly what MomentumController.Update expects as `moveDirection`.
function InputController.GetWorldMoveDirection(self: InputControllerInstance, camera: Camera): Vector3
	local localX = 0
	local localZ = 0

	if self._forward then
		localZ -= 1
	end
	if self._back then
		localZ += 1
	end
	if self._left then
		localX -= 1
	end
	if self._right then
		localX += 1
	end

	local combined = Vector3.new(localX, 0, localZ)

	-- Gamepad thumbstick takes over only if it's actually pushed and no keyboard input is
	-- active, so the two never fight each other.
	if combined.Magnitude < 0.05 and self._gamepadThumbstick.Magnitude > 0.15 then
		combined = Vector3.new(self._gamepadThumbstick.X, 0, -self._gamepadThumbstick.Y)
	end

	if combined.Magnitude < 0.05 then
		return Vector3.zero
	end

	local flatLook: Vector3
	local flatRight: Vector3

	-- Camera-relative: flatten look/right vectors to the horizontal plane so pitching the
	-- camera up/down doesn't affect ground movement direction or speed.
	if flatAimCFrame then
		-- Yaw-only, pitch/roll-free — see header. Numerically stable at any aim angle,
		-- no fallback branch needed since it can never degenerate.
		flatLook = flatAimCFrame.LookVector
		flatRight = flatAimCFrame.RightVector
	else
		-- Fallback: no first-person camera active (third person). Flatten the raw camera
		-- CFrame's vectors — safe here since the default orbit camera carries no roll and
		-- pitch rarely approaches the poles in third person.
		local cameraCFrame = camera.CFrame
		flatLook = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		flatRight = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)

		if flatLook.Magnitude < 0.01 then
			flatLook = Vector3.new(0, 0, -1)
			flatRight = Vector3.new(1, 0, 0)
		else
			flatLook = flatLook.Unit
			flatRight = flatRight.Unit
		end
	end

	local worldDirection = flatRight * combined.X + flatLook * (-combined.Z)
	if worldDirection.Magnitude < 0.05 then
		return Vector3.zero
	end
	return worldDirection.Unit
end

function InputController.Destroy(self: InputControllerInstance)
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return InputController