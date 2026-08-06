--!strict
--[[
	LeaderboardService — global cross-server rankings on OrderedDataStore.

	Boards are declared in one table, so adding "Most Bounty Claimed" is an entry plus
	a value function, never a new save path or a new remote.

	OrderedDataStore only stores integers, and only up to 2^63. Power runs past that
	into the trillions and beyond, so values are stored log-scaled: 1e6 times the
	base-10 log. That keeps ordering exact while fitting the range, and the display
	value is recovered on read. A raw truncation would collide every player above the
	cap into one indistinguishable score.

	Writes are throttled and wrapped: a DataStore outage must never take the game down
	with it, so failures are logged and skipped.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local UPDATE_INTERVAL = 120
local TOP_COUNT = 25
-- Scale factor that turns a log10 into an integer with six decimal places of
-- precision, which is finer than any two players will realistically tie at.
local LOG_SCALE = 1e6

type BoardDefinition = {
	Id: string,
	DisplayName: string,
	StoreKey: string,
	-- Whether the stored value is log-scaled and must be un-scaled for display.
	LogScaled: boolean,
	Value: (player: Player, data: Types.ProfileData) -> number,
}

local LeaderboardService = {
	Name = "LeaderboardService",
	Priority = 14,
}

local DataService: any = nil
local StatService: any = nil

local boards: { BoardDefinition } = {}
local stores: { [string]: OrderedDataStore? } = {}
local cache: { [string]: { any } } = {}

function LeaderboardService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")

	boards = {
		{
			Id = "Power",
			DisplayName = "Strongest",
			StoreKey = "TotalPower_v1",
			LogScaled = true,
			Value = function(player: Player): number
				return StatService:GetTotalPower(player)
			end,
		},
		{
			Id = "Kills",
			DisplayName = "Most Knockouts",
			StoreKey = "Kills_v1",
			LogScaled = false,
			Value = function(_player: Player, data: Types.ProfileData): number
				return data.Kills
			end,
		},
	}

	for _, board in boards do
		stores[board.Id] = DataStoreService:GetOrderedDataStore(board.StoreKey)
	end
end

local function encode(value: number, logScaled: boolean): number
	if not logScaled then
		return math.clamp(math.floor(value), 0, 2 ^ 53)
	end
	if value <= 0 then
		return 0
	end
	return math.floor(math.log(1 + value, 10) * LOG_SCALE)
end

local function decode(stored: number, logScaled: boolean): number
	if not logScaled then
		return stored
	end
	return 10 ^ (stored / LOG_SCALE) - 1
end

function LeaderboardService:_publish(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	for _, board in boards do
		local store = stores[board.Id]
		if not store then
			continue
		end

		local encoded = encode(board.Value(player, data), board.LogScaled)
		local ok, err = pcall(function()
			store:SetAsync(tostring(player.UserId), encoded)
		end)

		if not ok then
			warn(`[LeaderboardService] Failed to publish "{board.Id}" for {player.Name}: {err}`)
		end
	end
end

function LeaderboardService:_refresh(board: BoardDefinition)
	local store = stores[board.Id]
	if not store then
		return
	end

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT)
	end)

	if not ok then
		warn(`[LeaderboardService] Failed to read "{board.Id}": {pages}`)
		return
	end

	local entries = {}
	for rank, entry in (pages :: any):GetCurrentPage() do
		local userId = tonumber(entry.key)
		local name = "Unknown"

		if userId ~= nil then
			-- Name lookups are a network call each; failures fall back rather than
			-- aborting the whole board.
			local nameOk, resolved = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if nameOk then
				name = resolved
			end
		end

		table.insert(entries, {
			Rank = rank,
			UserId = userId,
			Name = name,
			Value = decode(entry.value, board.LogScaled),
		})
	end

	cache[board.Id] = entries
end

function LeaderboardService:GetBoard(boardId: string): { any }
	return cache[boardId] or {}
end

function LeaderboardService:GetBoards(): { any }
	local result = {}
	for _, board in boards do
		table.insert(result, {
			Id = board.Id,
			DisplayName = board.DisplayName,
			Entries = self:GetBoard(board.Id),
		})
	end
	return result
end

function LeaderboardService:Start()
	Net.Function("GetLeaderboard").OnServerInvoke = function()
		return self:GetBoards()
	end

	-- Publish a departing player's final numbers while their profile is still loaded.
	DataService.ProfileReleasing:Connect(function(player: Player)
		self:_publish(player)
	end)

	if RunService:IsStudio() then
		-- Studio has no reliable DataStore access by default, and a failing board on
		-- every playtest is noise rather than signal.
		warn(
			"[LeaderboardService] Studio session — global boards will be empty unless API access is enabled."
		)
	end

	task.spawn(function()
		while true do
			for _, board in boards do
				self:_refresh(board)
			end

			task.wait(UPDATE_INTERVAL)

			for _, player in Players:GetPlayers() do
				self:_publish(player)
			end
		end
	end)
end

return LeaderboardService
