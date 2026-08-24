--!strict
--[[
	QuestService — one objective at a time, forever.

	Quests live in Quests/ and are discovered at startup, ordered by CycleOrder into a
	rotation. Exactly one step of that rotation is active for a player at any moment;
	finishing it pays Tokens and advances them to the next, and finishing the last one
	wraps around to the first with every goal and reward grown by one loop.

	This replaced a log of fixed daily and one-shot quests. The daily model needed a
	UTC-midnight reset, a completions table and an "already done, stop" marker, all of
	which existed to answer "is this quest available again yet". A cycle never needs
	that question asked: the active step is a position, not a date, so the engine got
	considerably smaller rather than larger when the loop replaced it.

	Every quest's Track listener is wired once and stays live, including the two steps
	that are not currently active. Report discards anything that is not the active
	quest, which is the single place the "one at a time" rule is enforced — a quest
	module never has to know whether it is the one being asked for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local QuestService = {
	Name = "QuestService",
	Priority = 18,
}

local quests: { [Types.QuestId]: Types.Quest } = {}
-- The rotation, ordered by CycleOrder. Index into this with the player's cycle index.
local cycle: { Types.Quest } = {}

local DataService: any = nil
local TokenService: any = nil

-- (player, quest)
QuestService.QuestCompleted = Signal.new()

function QuestService:Init()
	DataService = Loader.Get("DataService")
	TokenService = Loader.Get("TokenService")
	self:_loadQuests()
end

function QuestService:_loadQuests()
	local folder = script:FindFirstChild("Quests")
	if folder == nil then
		warn("[QuestService] No Quests folder — no quests will be offered.")
		return
	end

	for _, module in folder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(require, module)
		if not ok then
			warn(`[QuestService] Failed to load quest {module.Name}: {result}`)
			continue
		end

		local quest = result :: Types.Quest
		if
			type(quest) ~= "table"
			or type(quest.Id) ~= "string"
			or type(quest.Track) ~= "function"
			or type(quest.CycleOrder) ~= "number"
			or type(quest.GoalAt) ~= "function"
			or type(quest.RewardAt) ~= "function"
		then
			warn(`[QuestService] {module.Name} does not implement the Quest contract`)
			continue
		end

		if quests[quest.Id] ~= nil then
			warn(`[QuestService] Duplicate quest id "{quest.Id}" in {module.Name}`)
			continue
		end

		quests[quest.Id] = quest
		table.insert(cycle, quest)
	end

	table.sort(cycle, function(a: Types.Quest, b: Types.Quest): boolean
		return a.CycleOrder < b.CycleOrder
	end)

	for index = 2, #cycle do
		if cycle[index].CycleOrder == cycle[index - 1].CycleOrder then
			warn(
				`[QuestService] "{cycle[index].Id}" and "{cycle[index - 1].Id}" share CycleOrder`
					.. ` {cycle[index].CycleOrder}; the rotation order between them is arbitrary.`
			)
		end
	end
end

--[[
	Where a player is in the rotation. The stored index only ever increases, and the
	modulo is applied at read time — so adding or removing a step between releases
	moves everyone to a sensible position instead of stranding them past the end.
]]
function QuestService:GetActiveQuest(player: Player): Types.Quest?
	if #cycle == 0 then
		return nil
	end
	local data = DataService:GetData(player)
	local index = if data ~= nil then (tonumber(data.QuestCycleIndex) or 0) else 0
	return cycle[(math.floor(index) % #cycle) + 1]
end

--[[
	How many full rotations this player has finished. Callers annotate the result as a
	number: `self` here is the untyped service table, so a method's declared return type
	does not survive the call under --!strict.
]]
function QuestService:GetLoop(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return math.max(0, math.floor(tonumber(data.QuestCycleLoop) or 0))
end

function QuestService:GetProgress(player: Player, quest: Types.Quest): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return data.QuestProgress[quest.Id] or 0
end

--[[
	Snapshot for the quest log and the HUD tracker. A list of one, so the client keeps
	reading a list and needed no change when the cycle replaced the log.
]]
function QuestService:BuildView(player: Player): { any }
	local quest = self:GetActiveQuest(player)
	if quest == nil then
		return {}
	end

	local loop: number = self:GetLoop(player)
	return {
		{
			Id = quest.Id,
			DisplayName = quest.DisplayName,
			Description = quest.Description,
			Category = quest.Category or "Stat",
			Goal = quest.GoalAt(loop),
			TokenReward = quest.RewardAt(loop),
			Progress = self:GetProgress(player, quest),
			Complete = false,
			-- One-based for display: "Rotation 1" reads better than "Rotation 0".
			Loop = loop + 1,
		},
	}
end

function QuestService:_push(player: Player)
	Net.Event("QuestsChanged"):FireClient(player, self:BuildView(player))
end

--[[
	Records progress and advances the rotation when the goal is met. Quests call this
	through the callback handed to Track.
]]
function QuestService:Report(player: Player, questId: Types.QuestId, amount: number)
	if amount <= 0 then
		return
	end

	local quest = quests[questId]
	if quest == nil then
		return
	end

	-- The one-at-a-time rule. All three listeners are live, so a player training legs
	-- during the upper-body step is genuinely reporting progress that does not count.
	local active = self:GetActiveQuest(player)
	if active == nil or active.Id ~= questId then
		return
	end

	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	local loop: number = self:GetLoop(player)
	local goal = quest.GoalAt(loop)
	local progress = (data.QuestProgress[questId] or 0) + amount

	if progress < goal then
		data.QuestProgress[questId] = progress
		DataService:MarkDirty(player)
		self:_push(player)
		return
	end

	-- Completed. Progress is cleared rather than banked: the next time this step comes
	-- around it is a fresh, larger goal, and leftover progress would silently discount
	-- it. The index only advances, and the loop counter ticks when it wraps.
	local reward = quest.RewardAt(loop)
	data.QuestProgress[questId] = nil

	local nextIndex = math.floor(tonumber(data.QuestCycleIndex) or 0) + 1
	data.QuestCycleIndex = nextIndex
	if #cycle > 0 and nextIndex % #cycle == 0 then
		data.QuestCycleLoop = loop + 1
	end

	TokenService:AwardTokens(player, reward)
	Net.Event("Notify"):FireClient(player, `Quest complete: {quest.DisplayName} (+{reward} tokens)`)
	QuestService.QuestCompleted:Fire(player, quest)

	DataService:MarkDirty(player)
	self:_push(player)
end

function QuestService:Start()
	-- Hand each quest a reporter bound to its own id, so a quest cannot report
	-- progress against someone else's objective.
	for _, quest in cycle do
		local questId = quest.Id
		local ok, err = pcall(quest.Track, function(player: Player, amount: number)
			self:Report(player, questId, amount)
		end)

		if not ok then
			warn(`[QuestService] Quest "{questId}" failed to set up tracking: {err}`)
		end
	end

	DataService.ProfileLoaded:Connect(function(player: Player)
		self:_push(player)
	end)
end

return QuestService
