--!strict
--[[
	CharacterController.lua  (Ch 2 Character Controller)

	--------------------------------------------------------------------------------
	OWNERSHIP MODEL (renamed from `isServer` to `ownsPhysics` this pass): real planar
	movement is now driven by a MomentumController (LinearVelocity + VectorForce
	constraints — see that file for why), and constraints only mean anything on the side
	that actually owns physics simulation for this character:
	  - The controlling CLIENT owns physics for a player's own character (default Roblox
	    networking) -> construct with ownsPhysics = true. MovementClient.client.lua does this.
	  - The SERVER does NOT own physics for a player's character -> construct with
	    ownsPhysics = false. MovementServer.server.lua does this; it still meaningfully sets
	    JumpPower/HipHeight (simple Humanoid properties that apply regardless of physics
	    ownership) but never touches WalkSpeed or drives momentum.
	  - A future AI/NPC entity (Ch 13) IS server-owned -> its CharacterController should be
	    constructed with ownsPhysics = true on the SERVER, exactly like a player's client.

	This is why the parameter is `ownsPhysics`, not `isServer` — the deciding factor is who
	actually simulates the physics, not which machine the code happens to run on.

	INERTIA: real vector-based momentum lives in MomentumController now, not a scalar
	CurrentSpeed here. Resolve() still computes the instant TARGET (speed magnitude,
	JumpPower, Gravity, etc.) as pure data; Update(dt) is what actually applies it — feeding
	the target into MomentumController when ownsPhysics, or just applying the
	physics-ownership-independent Humanoid properties (JumpPower, HipHeight) when not.

	SLOPE: Update(dt) asks a SlopeController for a live speed + momentum multiplier from a
	multi-point floor raycast and pushes the speed multiplier onto the SAME ModifierStack
	Stances use (sourceId "Slope"); the momentum multiplier scales Acceleration/Deceleration
	directly when handed to MomentumController.

	LEAN: a lightweight sub-state independent of the Stance state machine (you can lean
	while Standing, TacticalWalk, Crouching, or Prone) — see TrySetLean.
]]

local ModifierStack = require(script.Parent.Parent.Shared.ModifierStack)
local MovementProfiles = require(script.Parent.Parent.Shared.Config.MovementProfiles)
local Stances = require(script.Parent.Parent.Shared.Config.Stances)
local CombatEvents = require(script.Parent.Parent.Shared.CombatEvents)
local SlopeController = require(script.Parent.SlopeController)
local MomentumController = require(script.Parent.MomentumController)

local CharacterController = {}
CharacterController.__index = CharacterController

export type LeanDirection = "None" | "Left" | "Right"

export type CharacterControllerInstance = typeof(setmetatable(
	{} :: {
		Player: Player,
		Character: Model,
		Humanoid: Humanoid,
		RootPart: BasePart,

		CurrentMovementProfile: string,
		CurrentStance: string,
		LeanState: LeanDirection,
		Modifiers: ModifierStack.ModifierStackInstance,
		Slope: SlopeController.SlopeControllerInstance,
		Momentum: MomentumController.MomentumControllerInstance?,

		_ownsPhysics: boolean,
	},
	CharacterController
))

local BASE_STANCE = "Standing"
local BASE_PROFILE = "StandardHuman"
local BASE_HIP_HEIGHT = 2 -- tune to your rig's real standing HipHeight (DOGU15, Ch 17.6)
local MOVE_SPEED_THRESHOLD = 0.5 -- studs/s; used by IsMoving() to detect actual motion (not just input)

function CharacterController.new(player: Player, character: Model, ownsPhysics: boolean): CharacterControllerInstance
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	assert(humanoid, "CharacterController requires a Humanoid")
	assert(rootPart, "CharacterController requires a HumanoidRootPart")

	local self = setmetatable({
		Player = player,
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart :: BasePart,

		CurrentMovementProfile = BASE_PROFILE,
		CurrentStance = BASE_STANCE,
		LeanState = "None" :: LeanDirection,
		Modifiers = ModifierStack.new(),
		Slope = SlopeController.new(rootPart :: BasePart, humanoid),
		Momentum = if ownsPhysics then MomentumController.new(rootPart :: BasePart, humanoid) else nil,

		_ownsPhysics = ownsPhysics,
	}, CharacterController) :: any

	self:_applyStanceModifiers(BASE_STANCE)

	return self
end

-- === Movement Profile ==================================================

function CharacterController.SetMovementProfile(self: CharacterControllerInstance, profileName: string, sourceId: string)
	assert(MovementProfiles[profileName] ~= nil, `Unknown MovementProfile: {profileName}`)

	self.Modifiers:Add({
		sourceId = sourceId,
		key = "MovementProfile",
		modifierType = "StateOverride",
		value = profileName,
		priority = 0,
		stackBehavior = "Replace",
	})

	local resolved = self:GetEffectiveMovementProfileName()
	local old = self.CurrentMovementProfile
	self.CurrentMovementProfile = resolved
	if old ~= resolved then
		CombatEvents.MovementProfileChanged:Fire(self.Player, resolved, old, sourceId)
	end
end

function CharacterController.ClearMovementProfileOverride(self: CharacterControllerInstance, sourceId: string)
	self.Modifiers:Remove(sourceId, "MovementProfile")
	local resolved = self:GetEffectiveMovementProfileName()
	local old = self.CurrentMovementProfile
	self.CurrentMovementProfile = resolved
	if old ~= resolved then
		CombatEvents.MovementProfileChanged:Fire(self.Player, resolved, old, sourceId)
	end
end

function CharacterController.GetEffectiveMovementProfileName(self: CharacterControllerInstance): string
	return self.Modifiers:ResolveStateOverride("MovementProfile") or BASE_PROFILE
end

function CharacterController.GetMovementProfile(self: CharacterControllerInstance): MovementProfiles.MovementProfile
	return MovementProfiles[self:GetEffectiveMovementProfileName()]
end

-- === Stance =============================================================

function CharacterController.TryChangeStance(self: CharacterControllerInstance, newStance: string): (boolean, string?)
	if Stances[newStance] == nil then
		return false, `Unknown stance: {newStance}`
	end

	if newStance == self.CurrentStance then
		return true
	end

	local currentDef = Stances[self.CurrentStance]
	local allowed = table.find(currentDef.AllowedTransitions, newStance) ~= nil
	if not allowed then
		return false, `Cannot transition directly from {self.CurrentStance} to {newStance}`
	end

	local profile = self:GetMovementProfile()
	if newStance == "TacticalSprint" and (not profile.AllowsSprint or not Stances[newStance].CanSprint) then
		return false, "Sprinting is not permitted under the current movement profile"
	end

	local old = self.CurrentStance
	self.CurrentStance = newStance
	self:_applyStanceModifiers(newStance)

	if not Stances[newStance].CanLean and self.LeanState ~= "None" then
		self:TrySetLean("None")
	end

	CombatEvents.StanceChanged:Fire(self.Player, newStance, old)
	return true
end

function CharacterController._applyStanceModifiers(self: CharacterControllerInstance, stanceName: string)
	self.Modifiers:RemoveAllFromSource("Stance")
	local def = Stances[stanceName]

	self.Modifiers:Add({ sourceId = "Stance", key = "SpeedMultiplier", modifierType = "Numeric", op = "Multiply", value = def.SpeedMultiplier })
	self.Modifiers:Add({ sourceId = "Stance", key = "VisibilityMultiplier", modifierType = "Numeric", op = "Multiply", value = def.VisibilityMultiplier })
	self.Modifiers:Add({ sourceId = "Stance", key = "RecoilMultiplier", modifierType = "Numeric", op = "Multiply", value = def.RecoilMultiplier })
	self.Modifiers:Add({ sourceId = "Stance", key = "StabilityBonus", modifierType = "Numeric", op = "Add", value = def.StabilityBonus })
	self.Modifiers:Add({ sourceId = "Stance", key = "NoiseMultiplier", modifierType = "Numeric", op = "Multiply", value = def.NoiseMultiplier })
	self.Modifiers:Add({ sourceId = "Stance", key = "HipHeightScale", modifierType = "Numeric", op = "Set", value = def.Height })

	self.Modifiers:Add({ sourceId = "Stance", key = "CanSprint", modifierType = "Boolean", value = def.CanSprint })
	self.Modifiers:Add({ sourceId = "Stance", key = "CanAim", modifierType = "Boolean", value = def.CanAim })
	self.Modifiers:Add({ sourceId = "Stance", key = "CanFire", modifierType = "Boolean", value = def.CanFire })
	self.Modifiers:Add({ sourceId = "Stance", key = "CanLean", modifierType = "Boolean", value = def.CanLean })
end

-- === Lean ================================================================

function CharacterController.TrySetLean(self: CharacterControllerInstance, direction: LeanDirection): (boolean, string?)
	if direction ~= "None" and direction ~= "Left" and direction ~= "Right" then
		return false, `Invalid lean direction: {direction}`
	end

	if direction ~= "None" then
		local canLean = self.Modifiers:ResolveBoolean("CanLean", true)
		if not canLean then
			return false, `Cannot lean while {self.CurrentStance}`
		end
	end

	if direction == self.LeanState then
		return true
	end

	self.LeanState = direction
	CombatEvents.LeanChanged:Fire(self.Player, direction)
	return true
end

-- === Gravity (Ch 2.3) ===================================================

function CharacterController.SetGravityOverride(self: CharacterControllerInstance, gravity: Vector3, sourceId: string, priority: number?)
	self.Modifiers:Add({
		sourceId = sourceId,
		key = "Gravity",
		modifierType = "StateOverride",
		value = gravity,
		priority = priority or 0,
		stackBehavior = "Replace",
	})
	CombatEvents.GravityChanged:Fire(self.Player, self:GetEffectiveGravity(), sourceId)
end

function CharacterController.ClearGravityOverride(self: CharacterControllerInstance, sourceId: string)
	self.Modifiers:Remove(sourceId, "Gravity")
	CombatEvents.GravityChanged:Fire(self.Player, self:GetEffectiveGravity(), sourceId)
end

function CharacterController.GetEffectiveGravity(self: CharacterControllerInstance): Vector3
	local override = self.Modifiers:ResolveStateOverride("Gravity")
	if override then
		return override
	end
	return self:GetMovementProfile().Gravity
end

-- === Resolved output (instant target, no inertia) ======================

function CharacterController.Resolve(self: CharacterControllerInstance): {
	WalkSpeed: number,
	JumpPower: number,
	Gravity: Vector3,
	CanSprint: boolean,
	CanAim: boolean,
	CanFire: boolean,
	HipHeightScale: number,
}
	local profile = self:GetMovementProfile()
	local baseSpeed = profile.WalkSpeed

	local walkSpeed = self.Modifiers:ResolveNumeric("SpeedMultiplier", 1.0) * baseSpeed
	if self.CurrentStance == "TacticalSprint" and self.Modifiers:ResolveBoolean("CanSprint", profile.AllowsSprint) then
		walkSpeed *= profile.SprintSpeedMultiplier
	end

	return {
		WalkSpeed = walkSpeed,
		JumpPower = if profile.AllowsJump then profile.JumpPower else 0,
		Gravity = self:GetEffectiveGravity(),
		CanSprint = self.Modifiers:ResolveBoolean("CanSprint", profile.AllowsSprint),
		CanAim = self.Modifiers:ResolveBoolean("CanAim", true),
		CanFire = self.Modifiers:ResolveBoolean("CanFire", true),
		HipHeightScale = self.Modifiers:ResolveNumeric("HipHeightScale", 1.0),
	}
end

-- === Applied output ======================================================

--- Call once per Heartbeat (owning side) or per validation tick (non-owning side) with the
--- frame's dt.
function CharacterController.Update(self: CharacterControllerInstance, dt: number)
	if self.Momentum then
		-- Slope/stair multipliers feed into the SAME modifier stack Stances use, under
		-- their own source, so they compose with (rather than override) the current
		-- stance's SpeedMultiplier.
		local slopeSpeedMultiplier, slopeMomentumMultiplier = self.Slope:Update(dt)
		self.Modifiers:Add({
			sourceId = "Slope",
			key = "SpeedMultiplier",
			modifierType = "Numeric",
			op = "Multiply",
			value = slopeSpeedMultiplier,
			stackBehavior = "Replace",
		})

		local resolved = self:Resolve()
		local profile = self:GetMovementProfile()

		local acceleration = profile.Acceleration * slopeMomentumMultiplier
		local deceleration = profile.Deceleration * slopeMomentumMultiplier

		self.Momentum:Update(dt, self.Humanoid.MoveDirection, resolved.WalkSpeed, acceleration, deceleration)
		self.Momentum:SetGravity(resolved.Gravity)

		self.Humanoid.JumpPower = resolved.JumpPower
		self.Humanoid.HipHeight = BASE_HIP_HEIGHT * resolved.HipHeightScale
	else
		-- No physics ownership here (server, for a player-controlled character): only
		-- apply the Humanoid properties that meaningfully take effect regardless of
		-- ownership. Deliberately does NOT touch WalkSpeed — the owning client's
		-- MomentumController pins that once at construction, and this side must never
		-- fight it.
		local resolved = self:Resolve()
		self.Humanoid.JumpPower = resolved.JumpPower
		self.Humanoid.HipHeight = BASE_HIP_HEIGHT * resolved.HipHeightScale
	end
end

--- True while the character is ACTUALLY moving (real velocity), not just holding an input
--- key — this matters now that releasing input doesn't stop the character instantly, it
--- slides to a stop via momentum. On the owning side this reads MomentumController's own
--- simulated velocity; on the non-owning side (server, for a player) it falls back to the
--- real replicated planar velocity, which reflects the truth regardless of who owns physics.
function CharacterController.IsMoving(self: CharacterControllerInstance): boolean
	if self.Momentum then
		return self.Momentum.CurrentVelocity.Magnitude > MOVE_SPEED_THRESHOLD
	end
	local velocity = self.RootPart.AssemblyLinearVelocity
	local planar = Vector3.new(velocity.X, 0, velocity.Z)
	return planar.Magnitude > MOVE_SPEED_THRESHOLD
end

return CharacterController
