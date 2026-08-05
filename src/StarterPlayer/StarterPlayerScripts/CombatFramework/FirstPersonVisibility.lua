-- FirstPersonVisibility.lua  (client-only)
local FirstPersonVisibility = {}

-- Same accessory categories stock Roblox hides in first person: things worn ON the head.
-- Neck/Shoulder/Front/Back/Waist accessories stay visible (they read as "on the body").
local HIDDEN_ACCESSORY_TYPES = {
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
}

local function setPartHidden(part: BasePart, hidden: boolean)
	part.LocalTransparencyModifier = hidden and 1 or 0
end

--- Call every frame (or on relevant changes) while FP is active/inactive.
function FirstPersonVisibility.Apply(character: Model, hidden: boolean)
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		setPartHidden(head, hidden)
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Accessory") then
			local shouldHide = hidden and HIDDEN_ACCESSORY_TYPES[child.AccessoryType] == true
			local handle = child:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				setPartHidden(handle, shouldHide)
			end
		end
	end
end

return FirstPersonVisibility