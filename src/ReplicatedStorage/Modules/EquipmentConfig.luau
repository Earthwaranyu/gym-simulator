--!strict
--[[
	EquipmentConfig — every training machine in the game.

	Adding a machine is one entry here plus a model in Studio. No code changes: the
	server binds behaviour by CollectionService tag, and the client reads the same
	config for its prompts and UI.

	Placing a machine in Studio:
	  1. Build the model.
	  2. Tag it "TrainingStation" (CollectionService).
	  3. Set a string attribute "EquipmentId" to one of the ids below.

	Players train automatically when they walk within range — there is no prompt to
	configure and nothing for them to press.

	A single shared tag plus an attribute — rather than a tag per machine — means new
	equipment never needs a new tag registered anywhere.
]]

local Types = require(script.Parent.Types)

export type EquipmentDefinition = {
	Id: Types.EquipmentId,
	DisplayName: string,
	-- Which stat reps on this machine train.
	StatId: Types.StatId,
	-- Stat awarded per rep before multipliers. Tiers scale this exponentially, which
	-- is where the billions and trillions actually come from.
	BaseGain: number,
	-- Seconds between automatic reps. Training runs on its own, so this is the
	-- machine's pace rather than a cap on how fast a player can click.
	RepInterval: number,
	-- Total power needed before this machine can be used. 0 is the starter machine.
	UnlockPower: number,
}

-- The shared tag every station carries.
local STATION_TAG = "TrainingStation"
-- The attribute naming which definition a tagged model uses.
local ID_ATTRIBUTE = "EquipmentId"

local definitions: { EquipmentDefinition } = {
	{
		Id = "BenchPress",
		DisplayName = "Bench Press",
		StatId = "Chest",
		BaseGain = 5,
		RepInterval = 0.45,
		UnlockPower = 0,
	},
	{
		Id = "Dumbbells",
		DisplayName = "Dumbbells",
		StatId = "Arms",
		BaseGain = 4,
		RepInterval = 0.35,
		UnlockPower = 0,
	},
	{
		Id = "PullUpBar",
		DisplayName = "Pull-Up Bar",
		StatId = "Back",
		BaseGain = 6,
		RepInterval = 0.55,
		UnlockPower = 500,
	},
	{
		Id = "SitUpBench",
		DisplayName = "Sit-Up Bench",
		StatId = "Core",
		BaseGain = 4.5,
		RepInterval = 0.4,
		UnlockPower = 500,
	},
	{
		Id = "Treadmill",
		DisplayName = "Treadmill",
		StatId = "Legs",
		BaseGain = 5.5,
		RepInterval = 0.5,
		UnlockPower = 2000,
	},
}

local EquipmentConfig = {}

EquipmentConfig.List = definitions
EquipmentConfig.STATION_TAG = STATION_TAG
EquipmentConfig.ID_ATTRIBUTE = ID_ATTRIBUTE

local byId: { [Types.EquipmentId]: EquipmentDefinition } = {}
for _, definition in definitions do
	if byId[definition.Id] ~= nil then
		error(`[EquipmentConfig] Duplicate equipment id "{definition.Id}"`)
	end
	byId[definition.Id] = definition
end

function EquipmentConfig.Get(equipmentId: Types.EquipmentId): EquipmentDefinition?
	return byId[equipmentId]
end

--[[
	Resolves the definition a tagged station model refers to, or nil with a reason if
	the model is misconfigured. Returning the reason lets the server log something a
	level designer can act on instead of failing silently.
]]
function EquipmentConfig.Resolve(station: Instance): (EquipmentDefinition?, string?)
	local equipmentId = station:GetAttribute(ID_ATTRIBUTE)

	if equipmentId == nil then
		return nil, `missing "{ID_ATTRIBUTE}" attribute`
	end
	if type(equipmentId) ~= "string" then
		return nil, `"{ID_ATTRIBUTE}" must be a string, got {typeof(equipmentId)}`
	end

	local definition = byId[equipmentId]
	if definition == nil then
		return nil, `no equipment defined with id "{equipmentId}"`
	end

	return definition, nil
end

return EquipmentConfig
