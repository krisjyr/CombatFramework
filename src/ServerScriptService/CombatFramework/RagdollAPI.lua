--!strict
--[[
	RagdollAPI.lua  (Ch 14 Developer API style — the public entry point)

	This is the ONLY module other systems (a future Weapon/Ballistics hit-resolution, an
	Explosion's knockback, a Medical "Unconscious" status, an admin/CMDR command) should
	call to ragdoll something. It wraps RagdollController (which just builds/tears down
	physics) with the higher-level policy: auto wake-up timers for non-lethal ragdolls.
	"Death" just ragdolls — RagdollServer.server.lua is what clones a corpse and destroys
	the original, and it does that at RESPAWN time, not here (see that file).

	Same "call with :" table-function shape as FallService.lua (Ch 14's own
	CreateWeapon()/CreateStatus() convention) so it reads consistently across the codebase.

	Usage (once Weapon/Explosion/Medical systems exist):
		RagdollAPI:Ragdoll(player_or_character, "Impulse", {
			Impulse = shotDirection * 4000,
			ImpulsePart = "UpperTorso",
		})

		RagdollAPI:Ragdoll(player_or_character, "Death") -- clones a corpse, destroys the original

		RagdollAPI:Unragdoll(player_or_character) -- force an early wake-up
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFramework = ReplicatedStorage:WaitForChild("CombatFramework")
local RagdollController = require(CombatFramework.Ragdoll.RagdollController)
local RagdollTuning = require(CombatFramework.Shared.Config.RagdollTuning)

local RagdollAPI = {}

export type RagdollRequestOptions = {
	Impulse: Vector3?,
	ImpulsePart: string?,
	ImpulsePosition: Vector3?,
	Duration: number?, -- overrides RagdollTuning.ImpulseRagdollDuration for non-death causes; math.huge = stays ragdolled until Unragdoll() is called manually
}

-- Filled in by RagdollServer.server.lua (avoids a circular require — RagdollServer owns
-- the wake-up scheduling, this module just needs to be able to ask for it).
local wakeUpScheduler: ((character: Model, duration: number) -> ())? = nil

function RagdollAPI._bindWakeUpScheduler(fn: (character: Model, duration: number) -> ())
	wakeUpScheduler = fn
end

local function resolveCharacter(characterOrPlayer: Instance): Model?
	if characterOrPlayer:IsA("Player") then
		return (characterOrPlayer :: Player).Character
	elseif characterOrPlayer:IsA("Model") then
		return characterOrPlayer :: Model
	end
	return nil
end

--- Ragdolls `characterOrPlayer`. `cause` is "Death" (clones a persistent corpse and
--- destroys the original — see file-top note), "Impulse" (a hit that staggers/knocks the
--- character down but they get back up), or "Manual" (admin/debug, stays down until
--- Unragdoll() is called — same as passing Duration = math.huge).
function RagdollAPI:Ragdoll(characterOrPlayer: Instance, cause: RagdollController.RagdollCause, options: RagdollRequestOptions?)
	local character = resolveCharacter(characterOrPlayer)
	if not character then
		return
	end
	local opts = options or {}

	RagdollController.Enter(character, {
		Cause = cause,
		Impulse = opts.Impulse,
		ImpulsePart = opts.ImpulsePart,
		ImpulsePosition = opts.ImpulsePosition,
	})

	if cause == "Death" then
		-- No clone/destroy here anymore — RagdollServer.server.lua clones the corpse and
		-- destroys this original once the player actually RESPAWNS (CharacterAdded), not
		-- immediately on death, so the ragdoll stays the live, visible body in the
		-- meantime rather than instantly being swapped for a static clone.
		return
	end

	local duration = opts.Duration or RagdollTuning.ImpulseRagdollDuration
	if cause == "Impulse" and duration < math.huge and wakeUpScheduler then
		wakeUpScheduler(character, duration)
	end
	-- "Manual" (or an explicit Duration = math.huge "Impulse") never auto-schedules —
	-- caller is responsible for eventually calling RagdollAPI:Unragdoll().
end

--- Applies an additional impulse to an already-ragdolled character/corpse (e.g. an
--- explosion rocking a body that's already down). No-op if not currently ragdolled.
function RagdollAPI:ApplyImpulse(characterOrPlayer: Instance, partName: string?, impulse: Vector3, position: Vector3?)
	local character = resolveCharacter(characterOrPlayer)
	if not character then
		return
	end
	RagdollController.ApplyImpulse(character, partName, impulse, position)
end

--- Forces an immediate wake-up (alive characters only — do not call this on a corpse; a
--- dead Humanoid has no "getting up" to do). Safe to call even if not currently ragdolled.
function RagdollAPI:Unragdoll(characterOrPlayer: Instance)
	local character = resolveCharacter(characterOrPlayer)
	if not character or not RagdollController.IsRagdolled(character) then
		return
	end
	if wakeUpScheduler then
		-- Duration 0 -> RagdollServer's scheduler wakes it up on the very next check.
		wakeUpScheduler(character, 0)
	end
end

function RagdollAPI:IsRagdolled(characterOrPlayer: Instance): boolean
	local character = resolveCharacter(characterOrPlayer)
	return character ~= nil and RagdollController.IsRagdolled(character)
end

function RagdollAPI:GetCause(characterOrPlayer: Instance): RagdollController.RagdollCause?
	local character = resolveCharacter(characterOrPlayer)
	if not character then
		return nil
	end
	return RagdollController.GetCause(character)
end

return RagdollAPI