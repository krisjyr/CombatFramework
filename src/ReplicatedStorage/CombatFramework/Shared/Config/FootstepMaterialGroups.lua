--!strict
--[[
	FootstepMaterialGroups.lua  (Ch 4.5 shared material table, applied to Ch 10 Audio)

	Roblox's Enum.Material currently has 45 items (verified against the live docs, Aug
	2026). Rather than one folder per material -- which means either duplicating the same
	footstep asset dozens of times or leaving most materials silently unhandled -- every
	material aliases to one of a small number of PHYSICAL sound groups. This is the same
	"one material definition drives every system that needs it" principle Ch 4.5 already
	applies to ballistics/melee/fire; footsteps are just another consumer.

	Air and Water are intentionally absent from the alias table: Water is its own footstep
	group driven by Humanoid.FloorMaterial like everything else, and Air has no floor.
]]

local groups: { [string]: { Enum.Material } } = {
	Concrete = {
        Enum.Material.Asphalt, Enum.Material.Brick, Enum.Material.Cobblestone,
		Enum.Material.Concrete, Enum.Material.Pavement, Enum.Material.RoofShingles,
		Enum.Material.Plaster
	},
    Rock = { Enum.Material.Rock, Enum.Material.Basalt, Enum.Material.Slate, Enum.Material.Limestone, Enum.Material.Sandstone, Enum.Material.CrackedLava },
    Marble = { Enum.Material.Marble, Enum.Material.Granite },
    Tiles = { Enum.Material.ClayRoofTiles, Enum.Material.CeramicTiles, },
	Metal = { Enum.Material.Metal, Enum.Material.DiamondPlate },
    MetalThin = { Enum.Material.CorrodedMetal },
	Wood = { Enum.Material.Wood },
    WoodPlanks = { Enum.Material.WoodPlanks },
    Foil = { Enum.Material.Foil },
	Plastic = { Enum.Material.Plastic, Enum.Material.SmoothPlastic, Enum.Material.Rubber, Enum.Material.ForceField },
    Gravel = { Enum.Material.Pebble },
	Glass = { Enum.Material.Glass, Enum.Material.Neon },
	Grass = { Enum.Material.Grass, Enum.Material.LeafyGrass },
    Ground = { Enum.Material.Ground },
	Sand = { Enum.Material.Sand, Enum.Material.Salt },
	Snow = { Enum.Material.Snow, Enum.Material.Glacier },
	Ice = { Enum.Material.Ice },
	Mud = { Enum.Material.Mud },
	Fabric = { Enum.Material.Fabric, Enum.Material.Carpet, Enum.Material.Leather },
	Water = { Enum.Material.Water },
    Cardboard = { Enum.Material.Cardboard },
}

local materialToGroup: { [Enum.Material]: string } = {}
for groupName, materials in pairs(groups) do
	for _, material in ipairs(materials) do
		materialToGroup[material] = groupName
	end
end

local FootstepMaterialGroups = {}
local DEFAULT_GROUP = "Concrete"

function FootstepMaterialGroups.GroupFor(material: Enum.Material): string
	return materialToGroup[material] or DEFAULT_GROUP
end

--- Returns the SoundLibrary category ("Footstep.<Group>") for a floor material.
function FootstepMaterialGroups.CategoryFor(material: Enum.Material): string
	return `Footstep.{FootstepMaterialGroups.GroupFor(material)}`
end

--- Same idea, for landing-impact sounds ("Landing.<Group>") -- same alias table, so a
--- material added to `groups` above automatically gets both a footstep AND a landing
--- sound with zero further changes.
function FootstepMaterialGroups.LandingCategoryFor(material: Enum.Material): string
	return `Landing.{FootstepMaterialGroups.GroupFor(material)}`
end

return FootstepMaterialGroups