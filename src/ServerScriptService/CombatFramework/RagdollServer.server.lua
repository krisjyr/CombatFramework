--!strict
--[[
	RagdollServer.server.lua  (Ch 1.3 Server Authority, Ch 2.2 "Jumping/Falling", Ch 7)

	Bootstrap that:
	  1. Hooks every player's Humanoid.Died -> RagdollAPI:Ragdoll(character, "Death"), and
	     separately hooks Player.CharacterRemoving -> CorpseHandler.CreateFromCharacter for
	     any character that died. CharacterRemoving fires while the OLD character is still
	     valid, right as Roblox is about to tear it down for the respawn — CharacterAdded on
	     the NEW character is too late, the engine has already destroyed the old one by then.
	     No manual :Destroy() needed afterward; Roblox is already removing it as part of
	     this same event.
	  2. Implements the wake-up scheduler RagdollAPI calls into for non-lethal ragdolls
	     ("Impulse"/timed "Manual") — repositions the character onto the floor beneath
	     wherever it landed, forces the Prone stance (Ch 2.2), rebuilds the Motor6Ds via
	     RagdollController.Exit, and fires CombatEvents.WokeUp.

	Reuse for AI (Ch 13): AI has no Player/CharacterRemoving to hang corpse-creation off of
	— a future AI entity should call CorpseHandler.CreateFromCharacter directly whenever it
	considers the entity's lifecycle over, and setupDeathHook below still works unchanged
	for wiring up its ragdoll-on-death.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local RagdollController = require(CombatFramework.Ragdoll.RagdollController)
local RagdollTuning = require(CombatFramework.Shared.Config.RagdollTuning)
local CombatEvents = require(CombatFramework.Shared.CombatEvents)

local RagdollAPI = require(script.Parent.RagdollAPI)
local CorpseHandler = require(script.Parent.CorpseHandler)
local ControllerRegistry = require(script.Parent.ControllerRegistry)

-- Generation counters make repeated/duplicate schedule calls (e.g. RagdollAPI:Unragdoll
-- calling scheduleWakeUp(character, 0) while a longer timer is already pending) safe: only
-- the MOST RECENT scheduled call for a character is allowed to actually fire.
local pendingGeneration: { [Model]: number } = {}

local wakeUpRayParams = RaycastParams.new()
wakeUpRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function wakeUp(character: Model)
	if not RagdollController.IsRagdolled(character) then
		return
	end
	if RagdollController.GetCause(character) == "Death" then
		-- Never wake up a corpse.
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart or humanoid.Health <= 0 then
		return
	end

	local origin = rootPart.Position
	wakeUpRayParams.FilterDescendantsInstances = { character }
	local hit = Workspace:Raycast(origin, Vector3.new(0, -50, 0), wakeUpRayParams)
	local floorY = if hit then hit.Position.Y else origin.Y

	-- Level yaw only — never carry over the ragdolled pitch/roll.
	local look = rootPart.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.01 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end

	local standPosition = Vector3.new(origin.X, floorY + RagdollTuning.WakeUpLiftStuds, origin.Z)
	local wakeCFrame = CFrame.lookAt(standPosition, standPosition + flatLook)

	RagdollController.Exit(character)

	if rootPart.Parent then
		rootPart.CFrame = wakeCFrame
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end

	local player = Players:GetPlayerFromCharacter(character)
	if player then
		local entry = ControllerRegistry.Get(player)
		if entry then
			-- Wakes up prone (per spec) rather than standing — the player can stand up
			-- through the normal Prone -> Crouching -> Standing transitions from here.
			entry.Character:ForceSetStance("Prone")
		end
		CombatEvents.WokeUp:Fire(player)
	end
end

local function scheduleWakeUp(character: Model, duration: number)
	local generation = (pendingGeneration[character] or 0) + 1
	pendingGeneration[character] = generation

	task.delay(duration, function()
		if pendingGeneration[character] == generation and character.Parent then
			wakeUp(character)
		end
	end)
end

RagdollAPI._bindWakeUpScheduler(scheduleWakeUp)

--- Reusable for AI (Ch 13) — see file-top note.
local function setupDeathHook(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Once(function()
		print("[CombatFramework] Humanoid.Died fired")
		RagdollAPI:Ragdoll(character, "Death")
	end)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(setupDeathHook)
	if player.Character then
		setupDeathHook(player.Character)
	end

	-- Fires while the OLD character is still valid/parented, right as Roblox is about to
	-- remove it for the respawn (death or leaving) — CharacterAdded on the NEW character
	-- is too late, the old one is already destroyed by then (confirmed: oldCharacter.Parent
	-- was already nil by the time CharacterAdded fired).
	player.CharacterRemoving:Connect(function(character: Model)
		print("[CombatFramework] CharacterRemoving fired")
		if RagdollController.IsRagdolled(character) and RagdollController.GetCause(character) == "Death" then
			print("[CombatFramework] CharacterRemoving: creating corpse from ragdolled death")
			CorpseHandler.CreateFromCharacter(character)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

--[[
	Recommended future CMDR commands (Ch 14 / Ch 17.3), once CMDR is wired in — mirrors the
	pattern in FallServiceBootstrap.server.lua:

		ragdoll <player>
			-> RagdollAPI:Ragdoll(player, "Manual", { Duration = math.huge })

		unragdoll <player>
			-> RagdollAPI:Unragdoll(player)

		ragdoll_impulse <player> <force>
			-> RagdollAPI:Ragdoll(player, "Impulse", { Impulse = player.Character.HumanoidRootPart.CFrame.LookVector * force })
]]