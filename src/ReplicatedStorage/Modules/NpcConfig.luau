--!strict
--[[
	NpcConfig — the people standing in the world, and what talking to them does.

	An NPC here is a tagged model with an id attribute and nothing else: no server
	service, no remote, no state. Every one of them opens a screen the menu already
	has, so the whole feature is "a prompt that presses a tab for you" — and putting
	that on the server would mean a remote whose only job is to tell the client to
	open its own UI.

	Adding a shopkeeper, a trainer, or a quest board is one entry here plus a tagged
	model in `build_gym.py`. Pointing one at a new screen is a `Tab` value, because
	MenuController's tabs are already a registry.
]]

export type Npc = {
	Id: string,
	DisplayName: string,
	-- The line under the name on the nameplate.
	Title: string,
	-- Verb on the proximity prompt.
	ActionText: string,
	-- Which MenuController tab this NPC opens.
	Tab: string,
	Color: Color3,
}

-- Tag on the NPC model.
local NPC_TAG = "Npc"
-- Attribute naming which entry below the model is.
local NPC_ATTRIBUTE = "NpcId"
-- The part inside the model that carries the prompt and the nameplate. Same name
-- the training stations use, so everything adornable in the world says "Base".
local BASE_PART_NAME = "Base"
local PROMPT_DISTANCE = 12

local npcs: { Npc } = {
	{
		Id = "Coach",
		DisplayName = "Coach",
		Title = "Quests",
		ActionText = "Talk",
		Tab = "Quests",
		Color = Color3.fromRGB(126, 211, 155),
	},
}

local NpcConfig = {}

NpcConfig.List = npcs
NpcConfig.NPC_TAG = NPC_TAG
NpcConfig.NPC_ATTRIBUTE = NPC_ATTRIBUTE
NpcConfig.BASE_PART_NAME = BASE_PART_NAME
NpcConfig.PROMPT_DISTANCE = PROMPT_DISTANCE

local byId: { [string]: Npc } = {}
for _, npc in npcs do
	if byId[npc.Id] ~= nil then
		error(`[NpcConfig] Duplicate npc id "{npc.Id}"`)
	end
	byId[npc.Id] = npc
end

function NpcConfig.Get(npcId: string): Npc?
	return byId[npcId]
end

--[[
	Resolves the definition a tagged model names. Returns nil plus a reason when the
	model is misconfigured, so the client can log something actionable instead of
	silently ignoring an NPC nobody can talk to.
]]
function NpcConfig.Resolve(model: Instance): (Npc?, string?)
	local npcId = model:GetAttribute(NPC_ATTRIBUTE)

	if npcId == nil then
		return nil, `missing "{NPC_ATTRIBUTE}" attribute`
	end
	if type(npcId) ~= "string" then
		return nil, `"{NPC_ATTRIBUTE}" must be a string, got {typeof(npcId)}`
	end

	local npc = byId[npcId]
	if npc == nil then
		return nil, `no npc defined with id "{npcId}"`
	end

	return npc, nil
end

return NpcConfig
