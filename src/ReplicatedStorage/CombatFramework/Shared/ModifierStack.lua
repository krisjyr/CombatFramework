--!strict
--[[
	ModifierStack.lua

	Implements the single Modifier system referenced across the Technical Design Document
	(Ch 2.2 Stances, Ch 5 Attachments, Ch 8.2-8.3 Statuses). Stances, Statuses, Attachments,
	and now Slope/Lean are all just *sources* that push modifiers of the same shape into
	this stack — nothing downstream needs to know whether a "-15% speed" came from Prone,
	a broken leg, a loaded backpack, or a steep hill.

	Modifier types (Ch 8.3):
		"Numeric"       -- changes a value, e.g. Speed -15%
		"Boolean"       -- enables/disables a feature, e.g. CanSprint = false
		"StateOverride" -- forces a different behavior state, e.g. ForceMovementProfile

	Stack behaviors (Ch 8.2):
		"Replace" -- new application overrides old
		"Stack"   -- multiple instances accumulate
		"Refresh" -- new application resets the timer (timer handling lives in Statuses, not here)
		"Ignore"  -- additional applications from the same source+key have no effect
]]

local ModifierStack = {}
ModifierStack.__index = ModifierStack

export type ModifierType = "Numeric" | "Boolean" | "StateOverride"
export type StackBehavior = "Replace" | "Stack" | "Refresh" | "Ignore"
export type NumericOp = "Add" | "Multiply" | "Set"

export type Modifier = {
	sourceId: string,
	key: string,
	modifierType: ModifierType,
	op: NumericOp?,
	value: any,
	priority: number?,
	stackBehavior: StackBehavior?,
}

type Entry = Modifier & { priority: number, stackBehavior: StackBehavior }

export type ModifierStackInstance = typeof(setmetatable(
	{} :: {
		_byKey: { [string]: { Entry } },
	},
	ModifierStack
))

function ModifierStack.new(): ModifierStackInstance
	return setmetatable({
		_byKey = {},
	}, ModifierStack) :: any
end

function ModifierStack.Add(self: ModifierStackInstance, modifier: Modifier)
	local key = modifier.key
	local list = self._byKey[key]
	if not list then
		list = {}
		self._byKey[key] = list
	end

	local behavior: StackBehavior = modifier.stackBehavior or "Replace"
	local priority = modifier.priority or 0

	local existingIndex: number? = nil
	for i, entry in ipairs(list) do
		if entry.sourceId == modifier.sourceId then
			existingIndex = i
			break
		end
	end

	if existingIndex then
		if behavior == "Ignore" then
			return
		elseif behavior == "Stack" then
			-- fall through: append a new entry, keep the old one too
		else
			list[existingIndex] = {
				sourceId = modifier.sourceId,
				key = key,
				modifierType = modifier.modifierType,
				op = modifier.op,
				value = modifier.value,
				priority = priority,
				stackBehavior = behavior,
			}
			return
		end
	end

	table.insert(list, {
		sourceId = modifier.sourceId,
		key = key,
		modifierType = modifier.modifierType,
		op = modifier.op,
		value = modifier.value,
		priority = priority,
		stackBehavior = behavior,
	})
end

function ModifierStack.Remove(self: ModifierStackInstance, sourceId: string, key: string)
	local list = self._byKey[key]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i].sourceId == sourceId then
			table.remove(list, i)
		end
	end
end

function ModifierStack.RemoveAllFromSource(self: ModifierStackInstance, sourceId: string)
	for _key, list in pairs(self._byKey) do
		for i = #list, 1, -1 do
			if list[i].sourceId == sourceId then
				table.remove(list, i)
			end
		end
	end
end

function ModifierStack.ResolveNumeric(self: ModifierStackInstance, key: string, baseValue: number): number
	local list = self._byKey[key]
	if not list then
		return baseValue
	end

	local result = baseValue
	local addSum = 0
	local multProduct = 1
	local setValue: number? = nil
	local setPriority = -math.huge

	for _, entry in ipairs(list) do
		if entry.modifierType == "Numeric" then
			if entry.op == "Add" then
				addSum += entry.value
			elseif entry.op == "Multiply" then
				multProduct *= entry.value
			elseif entry.op == "Set" then
				if entry.priority >= setPriority then
					setPriority = entry.priority
					setValue = entry.value
				end
			end
		end
	end

	result = (result + addSum) * multProduct
	if setValue ~= nil then
		result = setValue
	end
	return result
end

function ModifierStack.ResolveBoolean(self: ModifierStackInstance, key: string, defaultValue: boolean): boolean
	local list = self._byKey[key]
	if not list then
		return defaultValue
	end

	local sawFalse = false
	local sawTrue = false
	for _, entry in ipairs(list) do
		if entry.modifierType == "Boolean" then
			if entry.value == false then
				sawFalse = true
			else
				sawTrue = true
			end
		end
	end

	if sawFalse then
		return false
	elseif sawTrue then
		return true
	end
	return defaultValue
end

function ModifierStack.ResolveStateOverride(self: ModifierStackInstance, key: string): any
	local list = self._byKey[key]
	if not list then
		return nil
	end

	local best: Entry? = nil
	for _, entry in ipairs(list) do
		if entry.modifierType == "StateOverride" then
			if not best or entry.priority >= best.priority then
				best = entry
			end
		end
	end

	return if best then best.value else nil
end

function ModifierStack.Debug(self: ModifierStackInstance, key: string): { Entry }
	return self._byKey[key] or {}
end

return ModifierStack
