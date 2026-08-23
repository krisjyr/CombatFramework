--!strict
--[[
	RagdollController.lua  (Ch 2 Character Controller — ragdoll)

	Shared (ReplicatedStorage) so both server and client can cheaply query ragdoll state,
	but only the SERVER should ever call Enter/Exit/ApplyImpulse (Ch 1.3 Server Authority —
	physics that matters, like getting ragdolled, is a server decision). The client-side
	use of this module is read-only: IsRagdolled()/IsRagdolledAttribute() so
	MovementClient/IKVisualsBootstrap/AnimationController can skip their own updates
	without needing a round trip.

	REPLICATION: ragdoll state is exposed as a Model Attribute — "Ragdolled" — set on the
	CHARACTER itself (not the Humanoid). This matters: it's the exact instance
	IKVisualsBootstrap.client.lua already reads via character:GetAttribute("Ragdolled") /
	character:GetAttributeChangedSignal("Ragdolled") — setting it anywhere else (e.g. on
	the Humanoid) means every listener keyed off the character never fires, which is
	exactly what broke IK shutdown before. If you add another system that needs to react to
	ragdoll, read/listen on the CHARACTER, not the Humanoid.

	SYSTEM SHUTDOWN: this module only owns what's inseparable from the physics itself —
	Humanoid.PlatformStand/AutoRotate and BreakJointsOnDeath/RequiresNeck (set once at
	character setup, see MovementServer.server.lua, not here — they must be set before
	Humanoid ever dies to prevent Roblox's own built-in death/joint-breaking behavior from
	racing our constraint-based one). Everything else — IK, torso posing, the movement
	system's own per-frame Update() — is expected to subscribe to the "Ragdolled" Attribute
	itself (see IKVisualsBootstrap.client.lua, MovementServer.server.lua,
	MovementClient.client.lua) rather than this module reaching into each of them by name.

	MOMENTUM INHERITANCE: before tearing down the Motor6Ds, this captures the character's
	current AssemblyLinearVelocity and AssemblyAngularVelocity and explicitly re-applies it
	to every body part once they're free — the assembly SHOULD already share velocity as one
	rigid body, but setting it explicitly makes "the ragdoll inherits momentum" a guarantee
	instead of an implementation detail.
]]

local RunService = game:GetService("RunService")

local RagdollRig = require(script.Parent.RagdollRig)
local RagdollTuning = require(script.Parent.Parent.Shared.Config.RagdollTuning)
local CombatEvents = require(script.Parent.Parent.Shared.CombatEvents)

local RagdollController = {}

export type RagdollCause = "Death" | "Impulse" | "Manual"

export type EnterOptions = {
	Cause: RagdollCause,
	Impulse: Vector3?, -- world-space impulse applied at ImpulsePart (or root if omitted)
	ImpulsePart: string?, -- BasePart name to focus the impulse on, e.g. "Head", "UpperTorso"
	ImpulsePosition: Vector3?, -- world position to apply the impulse at; defaults to the part's position
}

type ActiveEntry = {
	Rig: RagdollRig.BuiltRig,
	Humanoid: Humanoid,
	RootPart: BasePart,
	Cause: RagdollCause,
	PreviousNetworkOwner: Player?, -- nil means "was already server/auto owned"
	PreviousAutoSetNetworkOwner: boolean,
}

-- NOTE ON IK: this module does NOT (and can't) touch IKControl instances
-- (RightLegIK/LeftLegIK/RightHandIK/LeftHandIK/HeadLookIK) — confirmed via debug print
-- that humanoid:FindFirstChild(name) finds nothing server-side for these; they're created
-- client-side (IKLegController.lua, presumably Instance.new("IKControl")) and never exist
-- on the server at all. IK shutdown is entirely IKVisualsBootstrap.client.lua's job, keyed
-- off the same "Ragdolled" Attribute this module sets — see that file. If limbs still
-- drift/teleport while ragdolled or right after a corpse is cloned, the fix belongs in
-- IKLegController.SetEnabled(false): setting ik.Enabled = false there (not just Weight = 0)
-- is worth trying, since Weight only blends the solver's output at 0%, it doesn't stop the
-- solver itself from running against a joint chain whose Motor6Ds are now disabled.

local active: { [Model]: ActiveEntry } = {}

function RagdollController.IsRagdolled(character: Model): boolean
	return active[character] ~= nil
end

function RagdollController.GetCause(character: Model): RagdollCause?
	local entry = active[character]
	return entry and entry.Cause
end

--- SERVER ONLY. Ragdolls `character`. No-op if already ragdolled.
function RagdollController.Enter(character: Model, options: EnterOptions)
	if active[character] then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart then
		return
	end

	-- Capture pre-ragdoll assembly velocity so it can be explicitly reapplied below
	-- (momentum inheritance).
	local capturedLinearVelocity = rootPart.AssemblyLinearVelocity
	local capturedAngularVelocity = rootPart.AssemblyAngularVelocity

	local rig = RagdollRig.Build(character)

	-- PlatformStand/AutoRotate FIRST: flipping PlatformStand on a Humanoid that's been
	-- driving movement via WalkSpeed/:Move() (this project's MomentumController, not a
	-- physical force) appears to zero the assembly's velocity as part of handing off
	-- control — reapplying the captured velocity has to happen AFTER that, or it just gets
	-- wiped out immediately, which is why ragdolling while moving was crumpling in place
	-- instead of tumbling with momentum.
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	-- Roblox suppresses collision on an alive Humanoid's own limbs based on HumanoidState,
	-- independent of CanCollide/CollisionGroup — PlatformStand=true wasn't reliably enough
	-- on its own to lift that suppression, forcing Physics state directly is what does it.
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	for _, part in ipairs(rig.Parts) do
		part.AssemblyLinearVelocity = capturedLinearVelocity
		part.AssemblyAngularVelocity = capturedAngularVelocity
	end
	rootPart.AssemblyLinearVelocity = capturedLinearVelocity
	rootPart.AssemblyAngularVelocity = capturedAngularVelocity

	if options.Impulse then
		local focusPart = (options.ImpulsePart and character:FindFirstChild(options.ImpulsePart) :: BasePart?) or rootPart
		local focusImpulse = options.Impulse * RagdollTuning.ImpulseFocusFraction
		local spreadImpulse = options.Impulse - focusImpulse
		local applyPosition = options.ImpulsePosition or focusPart.Position

		focusPart:ApplyImpulseAtPosition(focusImpulse, applyPosition)

		local otherParts = {}
		for _, part in ipairs(rig.Parts) do
			if part ~= focusPart then
				table.insert(otherParts, part)
			end
		end
		if #otherParts > 0 then
			local perPart = spreadImpulse / #otherParts
			for _, part in ipairs(otherParts) do
				part:ApplyImpulse(perPart)
			end
		end
	end

	local previousAutoOwner = rootPart:GetNetworkOwnershipAuto()
	local previousOwner: Player? = nil
	if RunService:IsServer() then
		local ok, owner = pcall(function()
			return rootPart:GetNetworkOwner()
		end)
		previousOwner = if ok then owner else nil
		-- Ragdoll physics is chaotic and needs a single authority everyone agrees on —
		-- hand it to the server (Ch 1.3), same reasoning as a corpse nobody is "driving".
		for _, part in ipairs(rig.Parts) do
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
		end
		pcall(function()
			rootPart:SetNetworkOwner(nil)
		end)
	end

	active[character] = {
		Rig = rig,
		Humanoid = humanoid,
		RootPart = rootPart,
		Cause = options.Cause,
		PreviousNetworkOwner = previousOwner,
		PreviousAutoSetNetworkOwner = previousAutoOwner,
	}

	-- Set LAST, and on the CHARACTER (see file-top REPLICATION note) — every other system
	-- (IK, movement, animation) keys entirely off this Attribute changing.
	character:SetAttribute("Ragdolled", true)
	character:SetAttribute("RagdollCause", options.Cause)

	local player = game:GetService("Players"):GetPlayerFromCharacter(character)
	CombatEvents.RagdollBegan:Fire(character, options.Cause, player)
end

--- SERVER ONLY. Applies an additional impulse to an already-ragdolled character (e.g. an
--- explosion rocking a corpse). No-op if not currently ragdolled.
function RagdollController.ApplyImpulse(character: Model, partName: string?, impulse: Vector3, position: Vector3?)
	local entry = active[character]
	if not entry then
		return
	end
	local part = (partName and character:FindFirstChild(partName) :: BasePart?) or entry.RootPart
	if position then
		part:ApplyImpulseAtPosition(impulse, position)
	else
		part:ApplyImpulse(impulse)
	end
end

--- SERVER ONLY. Rebuilds Motor6Ds, restores collision/collision group, re-enables
--- AutoRotate, and restores network ownership. Does NOT reposition the character —
--- RagdollServer.lua's wake-up sequence handles that (needs to happen before this, see
--- there). Sets the "Ragdolled" Attribute to false FIRST so IK/movement get a one-frame
--- head start seeing "not ragdolled" before Motor6Ds actually come back online (both
--- IKVisualsBootstrap and MovementClient defer their own re-enable by a frame for exactly
--- this reason — see those files).
function RagdollController.Exit(character: Model)
	local entry = active[character]
	if not entry then
		return
	end
	active[character] = nil

	if character.Parent then
		character:SetAttribute("Ragdolled", false)
	end

	RagdollRig.Teardown(entry.Rig)

	if entry.Humanoid.Parent then
		entry.Humanoid.AutoRotate = true
		entry.Humanoid.PlatformStand = false
	end

	if RunService:IsServer() and entry.RootPart.Parent then
		pcall(function()
			if entry.PreviousAutoSetNetworkOwner then
				entry.RootPart:SetNetworkOwnershipAuto()
			else
				entry.RootPart:SetNetworkOwner(entry.PreviousNetworkOwner)
			end
		end)
	end

	CombatEvents.RagdollEnded:Fire(character)
end

--- Cheap read for any Model, ragdolled or not, from either side of the network boundary.
function RagdollController.IsRagdolledAttribute(character: Model): boolean
	return character:GetAttribute("Ragdolled") == true
end

return RagdollController