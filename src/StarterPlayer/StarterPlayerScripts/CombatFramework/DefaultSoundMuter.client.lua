--!strict
--[[
	DefaultSoundMuter.client.lua

	Silences Roblox's BUILT-IN Humanoid movement sounds for every character this client
	renders -- local and remote alike -- now that FootstepService/SoundService own all of
	that audio instead. These sounds are created lazily by the default "Animate"
	LocalScript the FIRST time each state actually fires (no "Jumping" Sound exists under
	a fresh character until it jumps once), parented directly under HumanoidRootPart
	(R15) or Torso (R6) -- so this has to watch for them being added later, not just mute
	on CharacterAdded.

	Deliberately sets Volume = 0 rather than destroying the instances: Animate still
	expects them to exist and freely calls :Play()/:Stop() on them, and fighting that by
	re-creating deleted Sound instances every frame would be far more fragile than just
	keeping them permanently silent.
]]

local Players = game:GetService("Players")

local DEFAULT_SOUND_NAMES = {
	Climbing = true,
	Died = true,
	FreeFalling = true,
	GettingUp = true,
	Jumping = true,
	Landing = true,
	Running = true,
	Splash = true,
	Swimming = true,
}

local function muteSound(sound: Sound)
	sound.Volume = 0
	-- Defensive: if anything ever resets Volume back up, re-mute immediately instead of
	-- needing another full pass.
	sound:GetPropertyChangedSignal("Volume"):Connect(function()
		if sound.Volume ~= 0 then
			sound.Volume = 0
		end
	end)
end

local function watchContainer(container: Instance)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Sound") and DEFAULT_SOUND_NAMES[child.Name] then
			muteSound(child :: Sound)
		end
	end

	container.ChildAdded:Connect(function(child)
		if child:IsA("Sound") and DEFAULT_SOUND_NAMES[child.Name] then
			muteSound(child :: Sound)
		end
	end)
end

local function onCharacterAdded(character: Model)
	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if rootPart then
		watchContainer(rootPart)
	end
	-- R6 fallback -- harmless no-op on the DOGU15 R15 rig, since Torso won't exist there.
	local torso = character:FindFirstChild("Torso")
	if torso then
		watchContainer(torso)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end