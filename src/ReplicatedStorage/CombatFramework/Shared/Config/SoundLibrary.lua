--!strict
--[[
	SoundLibrary.lua  (Ch 15 Configuration System)

	category -> where its template(s) live under game.SoundService + default tuning.
	Adding a category is a data change here (+ dropping Sound instances in Studio), never
	code. Points directly at your existing CombatFrameworkSounds tree (doc 25) -- single
	Sound leaves and variant folders both work identically (see SoundService.lua).
]]

export type SoundDefinition = {
	FolderPath: { string },
	BaseVolume: number,
	PitchVariance: number?,
	MaxDistance: number?,
	RollOffMode: Enum.RollOffMode?,
	EmitterSize: number?,
	Fallback: string?,
}

local ROOT = "CombatFrameworkSounds"

local SoundLibrary: { [string]: SoundDefinition } = {
	-- Footsteps -- every one of these chains to Concrete if its own folder is empty/broken.
	["Footstep.Concrete"] = { FolderPath = { ROOT, "Footsteps", "Concrete" }, BaseVolume = 0.5, PitchVariance = 0.08, MaxDistance = 40 },
	["Footstep.Metal"]    = { FolderPath = { ROOT, "Footsteps", "Metal" },    BaseVolume = 0.55, PitchVariance = 0.08, MaxDistance = 45, Fallback = "Footstep.Concrete" },
    ["Footstep.MetalThin"]    = { FolderPath = { ROOT, "Footsteps", "MetalThin" },    BaseVolume = 0.55, PitchVariance = 0.08, MaxDistance = 45, Fallback = "Footstep.Concrete" },
	["Footstep.Wood"]     = { FolderPath = { ROOT, "Footsteps", "Wood" },     BaseVolume = 0.5, PitchVariance = 0.08, MaxDistance = 40, Fallback = "Footstep.Concrete" },
    ["Footstep.WoodPlanks"]     = { FolderPath = { ROOT, "Footsteps", "WoodPlanks" },     BaseVolume = 0.5, PitchVariance = 0.08, MaxDistance = 40, Fallback = "Footstep.Concrete" },
	["Footstep.Grass"]    = { FolderPath = { ROOT, "Footsteps", "Grass" },    BaseVolume = 0.35, PitchVariance = 0.1, MaxDistance = 30, Fallback = "Footstep.Concrete" },
	["Footstep.Sand"]     = { FolderPath = { ROOT, "Footsteps", "Sand" },     BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
	["Footstep.Snow"]     = { FolderPath = { ROOT, "Footsteps", "Snow" },     BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
	["Footstep.Water"]    = { FolderPath = { ROOT, "Footsteps", "Water" },    BaseVolume = 0.45, PitchVariance = 0.1, MaxDistance = 35, Fallback = "Footstep.Concrete" },
	["Footstep.Plastic"]  = { FolderPath = { ROOT, "Footsteps", "Plastic" }, BaseVolume = 0.4, PitchVariance = 0.08, MaxDistance = 35, Fallback = "Footstep.Concrete" },
	["Footstep.Glass"]    = { FolderPath = { ROOT, "Footsteps", "Glass" },   BaseVolume = 0.5, PitchVariance = 0.06, MaxDistance = 40, Fallback = "Footstep.Concrete" },
	["Footstep.Ice"]      = { FolderPath = { ROOT, "Footsteps", "Ice" },     BaseVolume = 0.4, PitchVariance = 0.06, MaxDistance = 35, Fallback = "Footstep.Concrete" },
	["Footstep.Mud"]      = { FolderPath = { ROOT, "Footsteps", "Mud" },     BaseVolume = 0.4, PitchVariance = 0.12, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Ground"]      = { FolderPath = { ROOT, "Footsteps", "Ground" },     BaseVolume = 0.4, PitchVariance = 0.12, MaxDistance = 25, Fallback = "Footstep.Concrete" },
	["Footstep.Fabric"]   = { FolderPath = { ROOT, "Footsteps", "Fabric" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Tiles"]   = { FolderPath = { ROOT, "Footsteps", "Tiles" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Foil"]   = { FolderPath = { ROOT, "Footsteps", "Foil" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Cardboard"]   = { FolderPath = { ROOT, "Footsteps", "Cardboard" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Gravel"]   = { FolderPath = { ROOT, "Footsteps", "Gravel" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Marble"]   = { FolderPath = { ROOT, "Footsteps", "Marble" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },
    ["Footstep.Rock"]   = { FolderPath = { ROOT, "Footsteps", "Rock" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Footstep.Concrete" },

	-- Landings
	["Landing.Concrete"] = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Concrete" }, BaseVolume = 0.4, PitchVariance = 0.1, MaxDistance = 30 },
	["Landing.Metal"]    = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Metal" },    BaseVolume = 0.5, PitchVariance = 0.1, MaxDistance = 35, Fallback = "Landing.Concrete" },
	["Landing.MetalThin"]    = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "MetalThin" },    BaseVolume = 0.5, PitchVariance = 0.1, MaxDistance = 35, Fallback = "Landing.Concrete" },
	["Landing.Wood"]     = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Wood" },     BaseVolume = 0.4, PitchVariance = 0.1, MaxDistance = 30, Fallback = "Landing.Concrete" },
	["Landing.WoodPlanks"]     = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "WoodPlanks" },     BaseVolume = 0.4, PitchVariance = 0.1, MaxDistance = 30, Fallback = "Landing.Concrete" },
	["Landing.Grass"]    = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Grass" },    BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Landing.Concrete" },
	["Landing.Sand"]     = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Sand" },     BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Snow"]     = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Snow" },     BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Water"]    = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Water" },    BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Plastic"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Plastic" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Landing.Concrete" },
	["Landing.Glass"]    = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Glass" },   BaseVolume = 0.4, PitchVariance = 0.1, MaxDistance = 30, Fallback = "Landing.Concrete" },
	["Landing.Ice"]      = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Ice" },     BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Landing.Concrete" },
	["Landing.Mud"]      = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Mud" },     BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Ground"]      = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Ground" },     BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Fabric"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Fabric" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Tiles"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Tiles" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Foil"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Foil" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Cardboard"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Cardboard" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Gravel"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Gravel" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Marble"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Marble" },  BaseVolume = 0.25, PitchVariance = 0.1, MaxDistance = 20, Fallback = "Landing.Concrete" },
	["Landing.Rock"]   = { FolderPath = { ROOT, "Effects", "Movement", "Landing", "Rock" },  BaseVolume = 0.3, PitchVariance = 0.1, MaxDistance = 25, Fallback = "Landing.Concrete" },

	-- Movement
	["Movement.Slide"]        = { FolderPath = { ROOT, "Effects", "Movement", "InertiaSlide" }, BaseVolume = 0.6, PitchVariance = 0.05, MaxDistance = 40 },
	["Movement.Jump"]         = { FolderPath = { ROOT, "Effects", "Movement", "Jump" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 35 },
	["Movement.QuickTurn"]    = { FolderPath = { ROOT, "Effects", "Movement", "QuickTurn" }, BaseVolume = 0.4, PitchVariance = 0.05, MaxDistance = 25 },
	["Movement.GearQuickTurn"]    = { FolderPath = { ROOT, "Effects", "Movement", "GearQuickTurn" }, BaseVolume = 0.4, PitchVariance = 0.05, MaxDistance = 25 },
	["Movement.HeavyImpact"]  = { FolderPath = { ROOT, "Effects", "Movement", "HeavyImpact" }, BaseVolume = 1.5, PitchVariance = 0.05, MaxDistance = 45 },
	["Movement.StanceCrouch"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceCrouch" }, BaseVolume = 0.45, PitchVariance = 0.05, MaxDistance = 25 },
    ["Movement.StanceProne"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceProne" }, BaseVolume = 0.45, PitchVariance = 0.05, MaxDistance = 25 },
    ["Movement.StanceLean"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceLean" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 25 },
    ["Movement.StanceStand"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceStand" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 25 },
    ["Movement.StanceVault"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceVault" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 25 },
    ["Movement.StanceVaultOver"] = { FolderPath = { ROOT, "Effects", "Movement", "Stances", "StanceVaultOver" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 25 },
	["Movement.FallWind"] = { FolderPath = { ROOT, "Effects", "Movement", "FallWind" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 30 },

	-- Gear / clothing loops
	["Gear.Slow"]  = { FolderPath = { ROOT, "Effects", "Movement", "Equipment", "Slow" }, BaseVolume = 0.35, MaxDistance = 20 },
	["Gear.Walk"]    = { FolderPath = { ROOT, "Effects", "Movement", "Equipment", "Walk" }, BaseVolume = 0.2, MaxDistance = 25 },
	["Gear.Run"]    = { FolderPath = { ROOT, "Effects", "Movement", "Equipment", "Run" }, BaseVolume = 0.05, MaxDistance = 30 },
	["Gear.WeaponMechanicals"]    = { FolderPath = { ROOT, "Effects", "Movement", "Equipment", "WeaponMechanicals" }, BaseVolume = 0.2, MaxDistance = 25 },
	["Clothing.Run"] = { FolderPath = { ROOT, "Effects", "Movement", "Clothing" }, BaseVolume = 0.5, MaxDistance = 25 },

	-- Breathing
	["Breathing.Calm"]   = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "Calm" }, BaseVolume = 0.3, MaxDistance = 15 },
	["Breathing.Medium"] = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "Medium" }, BaseVolume = 0.4, MaxDistance = 18 },
	["Breathing.Heavy"]  = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "Heavy" }, BaseVolume = 0.5, MaxDistance = 20 },
	["Breathing.Wounded"] = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "Wounded" }, BaseVolume = 0.5, MaxDistance = 20, Fallback = "Breathing.Heavy" },
	["Breathing.Cough"] = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "Cough" }, BaseVolume = 0.5, MaxDistance = 20 },

	["Breathing.Hold"]    = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "HoldBreath" }, BaseVolume = 0.4, PitchVariance = 0.05, MaxDistance = 15 },
	["Breathing.Release"] = { FolderPath = { ROOT, "Effects", "Other", "Breathing", "ReleaseBreath" }, BaseVolume = 0.5, PitchVariance = 0.05, MaxDistance = 18 },
}

return SoundLibrary