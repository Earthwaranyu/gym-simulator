--!strict
--[[
	QuestService — the second source of Tokens, alongside idle accrual.

	Quests live in Quests/ and are discovered at startup. Each one wires its own
	listener in Track(), so this engine never learns what kinds of objective exist:
	"train 500 reps", "win 5 fights", and "reach a rank" are all just files that call
	report(player, amount). Adding one is never a branch here.

	Progress and completions are saved. Daily quests compare their recorded completion
	day against today in UTC, so a reset happens at a fixed wall-clock moment for
	everyone rather than drifting per player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local ONCE_MARKER = "once"

local QuestService = {
	Name = "QuestService",
	Priority = 18,
}

local quests: { [Types.QuestId]: Types.Quest } = {}
local order: { Types.Quest } = {}

local DataService: any = nil
local TokenService: any = nil

-- (player, quest)
QuestService.QuestCompleted = Signal.new()

local function today(): string
	return os.date("!%Y-%m-%d") :: string
end

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
		if type(quest) ~= "table" or type(quest.Id) ~= "string" or type(quest.Track) ~= "function" then
			warn(`[QuestService] {module.Name} does not implement the Quest contract`)
			continue
		end

		if quests[quest.Id] ~= nil then
			warn(`[QuestService] Duplicate quest id "{quest.Id}" in {module.Name}`)
			continue
		end

		quests[quest.Id] = quest
		table.insert(order, quest)
	end

	table.sort(order, function(a: Types.Quest, b: Types.Quest): boolean
		return a.Id < b.Id
	end)
end

--[[
	Whether a quest is currently claimable-complete for this player: one-shot quests
	stay done forever, daily quests only until UTC midnight.
]]
function QuestService:IsComplete(player: Player, quest: Types.Quest): boolean
	local data = DataService:GetData(player)
	if data == nil then
		return false
	end

	local completion = data.QuestCompletions[quest.Id]
	if completion == nil then
		return false
	end

	if quest.Repeat == "Once" then
		return true
	end
	return completion == today()
end

function QuestService:GetProgress(player: Player, quest: Types.Quest): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return data.QuestProgress[quest.Id] or 0
end

--[[
	Snapshot for the quest log UI.
]]
function QuestService:BuildView(player: Player): { any }
	local view = {}

	for _, quest in order do
		table.insert(view, {
			Id = quest.Id,
			DisplayName = quest.DisplayName,
			Description = quest.Description,
			Goal = quest.Goal,
			TokenReward = quest.TokenReward,
			Repeat = quest.Repeat,
			Progress = self:GetProgress(player, quest),
			Complete = self:IsComplete(player, quest),
		})
	end

	return view
end

function QuestService:_push(player: Player)
	Net.Event("QuestsChanged"):FireClient(player, self:BuildView(player))
end

--[[
	Records progress toward a quest and pays out when the goal is met. Quests call this
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

	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	-- A daily whose completion is from a previous day starts over.
	local completion = data.QuestCompletions[questId]
	if quest.Repeat == "Daily" and completion ~= nil and completion ~= today() then
		data.QuestCompletions[questId] = nil
		data.QuestProgress[questId] = 0
	elseif self:IsComplete(player, quest) then
		return
	end

	local progress = (data.QuestProgress[questId] or 0) + amount
	data.QuestProgress[questId] = progress

	if progress >= quest.Goal then
		data.QuestCompletions[questId] = if quest.Repeat == "Once" then ONCE_MARKER else today()
		data.QuestProgress[questId] = quest.Goal

		TokenService:AwardTokens(player, quest.TokenReward)
		Net.Event("Notify")
			:FireClient(player, `Quest complete: {quest.DisplayName} (+{quest.TokenReward} tokens)`)
		QuestService.QuestCompleted:Fire(player, quest)
	end

	DataService:MarkDirty(player)
	self:_push(player)
end

function QuestService:Start()
	-- Hand each quest a reporter bound to its own id, so a quest cannot report
	-- progress against someone else's objective.
	for _, quest in order do
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
