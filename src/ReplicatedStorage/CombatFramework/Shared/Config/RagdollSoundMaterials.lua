--!strict
--[[
	RagdollSoundMaterials.lua

	Maps Enum.Material -> which Ragdoll.Impact*/Ragdoll.Scrape* entry in SoundLibrary.lua to
	play. RagdollSounds.lua does SoundLibrary["Ragdoll.Impact" .. Impact[material] etc.
	Anything not listed here falls back to Impact "Medium" / Scrape "Generic" (that fallback
	lives in RagdollSounds.lua, not here, so this table only needs the exceptions).
]]--

local Impact: { [Enum.Material]: string } = {
	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "Wood",

	[Enum.Material.Snow] = "Snow",

	[Enum.Material.Water] = "Water",
}

-- Deliberately sparser than Impact — most surfaces just sound "Generic" while sliding;
-- only stone/wood/snow get their own scrape timbre (matches the 4 loop categories that
-- actually exist in SoundLibrary).
local Scrape: { [Enum.Material]: string } = {
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Rock] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Basalt] = "Concrete",
	[Enum.Material.Asphalt] = "Concrete",
	[Enum.Material.Limestone] = "Concrete",
	[Enum.Material.Sandstone] = "Concrete",
	[Enum.Material.Granite] = "Concrete",
	[Enum.Material.Marble] = "Concrete",

	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "Wood",

	[Enum.Material.Snow] = "Snow",
}

return {
	Impact = Impact,
	Scrape = Scrape,
}