--!strict
--[[
	LeaderboardBoardController — paints the plaza monuments.

	#54 built the `OrderedDataStore` boards and a remote to read them, and then had
	nowhere to show them but a menu tab nobody opens. #70 put two stone monuments in
	the plaza. This joins them: every model tagged `LeaderboardBoard` gets a
	`SurfaceGui` on its `Screen` part showing the board its `BoardId` names.

	Client-side, like the station billboards, so the boards cost the server nothing
	beyond the one remote call they already had — and one call serves every monument
	on screen, because `GetLeaderboard` returns all of them at once and is rate
	limited to one per second at the other end.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

-- Emitted by scripts/build_gym.py. The tag is on the model, the id on the model,
-- and the readable face is a part named Screen.
local BOARD_TAG = "LeaderboardBoard"
local BOARD_ATTRIBUTE = "BoardId"
local SCREEN_PART_NAME = "Screen"

-- The boards move on a two-minute server cycle, so polling faster only costs
-- bandwidth. Slow enough to be cheap, quick enough that a player who just took
-- first place sees it before they walk away.
local REFRESH_SECONDS = 30
local TOP_COUNT = 10

local LeaderboardBoardController = {
	Name = "LeaderboardBoardController",
	Priority = 6,
}

type Entry = {
	boardId: string,
	heading: TextLabel,
	list: TextLabel,
	gui: SurfaceGui,
}

local boards: { [Instance]: Entry } = {}

function LeaderboardBoardController:_bind(model: Instance)
	if boards[model] ~= nil then
		return
	end

	local boardId = model:GetAttribute(BOARD_ATTRIBUTE)
	if type(boardId) ~= "string" then
		warn(`[LeaderboardBoardController] {model:GetFullName()} has no "{BOARD_ATTRIBUTE}" string`)
		return
	end

	local screen = model:FindFirstChild(SCREEN_PART_NAME)
	if screen == nil or not screen:IsA("BasePart") then
		warn(`[LeaderboardBoardController] {model:GetFullName()} has no "{SCREEN_PART_NAME}" part`)
		return
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardFace"
	-- build_gym.py's convention is that the side you approach from is local +Z,
	-- which is Roblox's Back face — its Front is -Z. Naming it beats rotating the
	-- part to make the default come out right.
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 26
	gui.LightInfluence = 0
	gui.MaxDistance = 120
	gui.Parent = screen

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = gui

	local heading = UI.Label("Heading", gui)
	heading.Size = UDim2.new(1, 0, 0, 34)
	heading.Font = UI.Font.Heading
	heading.TextSize = 26
	heading.TextColor3 = UI.Palette.Accent
	heading.TextXAlignment = Enum.TextXAlignment.Center
	heading.Text = "…"

	local list = UI.Label("Entries", gui)
	list.Position = UDim2.fromOffset(0, 42)
	list.Size = UDim2.new(1, 0, 1, -42)
	list.TextSize = 19
	list.TextYAlignment = Enum.TextYAlignment.Top
	list.Text = ""

	boards[model] = { boardId = boardId, heading = heading, list = list, gui = gui }
end

function LeaderboardBoardController:_unbind(model: Instance)
	local entry = boards[model]
	if entry ~= nil then
		entry.gui:Destroy()
		boards[model] = nil
	end
end

--[[
	One call, every monument. Boards that the server could not reach come back
	empty rather than missing, so a monument says so instead of going blank.
]]
function LeaderboardBoardController:_refresh()
	if next(boards) == nil then
		return
	end

	local ok, fetched = pcall(function()
		return Net.Function("GetLeaderboard"):InvokeServer()
	end)
	if not ok or type(fetched) ~= "table" then
		return
	end

	local byId: { [string]: any } = {}
	for _, board in fetched do
		if type(board) == "table" and type(board.Id) == "string" then
			byId[board.Id] = board
		end
	end

	for _, entry in boards do
		local board = byId[entry.boardId]
		if board == nil then
			entry.heading.Text = "OFFLINE"
			entry.list.Text = ""
			continue
		end

		entry.heading.Text = string.upper(board.DisplayName)

		local lines = {}
		for rank, row in board.Entries do
			if rank > TOP_COUNT then
				break
			end
			table.insert(
				lines,
				`{row.Rank}.  {row.Name}   `
					.. `<font color="#FFD666">{NumberFormat.Format(row.Value)}</font>`
			)
		end

		if #lines == 0 then
			-- Normal in Studio and in an unpublished place: OrderedDataStore is
			-- unreachable there and LeaderboardService disables the board rather
			-- than taking the server down with it.
			entry.list.Text = `<font color="#8A93A8">No entries yet.</font>`
		else
			entry.list.Text = table.concat(lines, "\n")
		end
	end
end

function LeaderboardBoardController:Start()
	for _, model in CollectionService:GetTagged(BOARD_TAG) do
		self:_bind(model)
	end

	CollectionService:GetInstanceAddedSignal(BOARD_TAG):Connect(function(model)
		self:_bind(model)
		-- A monument that just streamed in should not wait out the cycle blank.
		self:_refresh()
	end)

	CollectionService:GetInstanceRemovedSignal(BOARD_TAG):Connect(function(model)
		self:_unbind(model)
	end)

	task.spawn(function()
		while true do
			self:_refresh()
			task.wait(REFRESH_SECONDS)
		end
	end)
end

return LeaderboardBoardController
