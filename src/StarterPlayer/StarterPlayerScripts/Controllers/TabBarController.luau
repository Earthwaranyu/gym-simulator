--!strict
--[[
	TabBarController — the custom player list.

	Replaces Roblox's default list, which can only show one numeric column and cannot
	show a rank colour or an outlaw marker. Per CLAUDE.md this shows each player's
	overall power and reputation.

	Rows are rebuilt from the roster broadcast rather than diffed. The roster is at most
	a few dozen entries arriving once a second, so rebuilding is simpler and cannot
	drift out of sync with the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local Icons = require(ReplicatedStorage.Modules.Icons)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local ROW_HEIGHT = 26
local MAX_ROWS = 5

local TabBarController = {
	Name = "TabBarController",
	Priority = 8,
}

local panel: Frame? = nil
local rows: Frame? = nil
local header: TextLabel? = nil
local rankButton: TextButton? = nil
local visible = true
local MenuController: any = nil

function TabBarController:Init()
	MenuController = Loader.Get("MenuController")
end

function TabBarController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymTabBar"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = playerGui

	-- Built into locals and published at the end: the module-level fields are optional
	-- (nothing exists before Start), and assigning through them makes every subsequent
	-- property write a nil-check for the type checker.
	local newPanel = UI.Panel("Roster", screen)
	newPanel.AnchorPoint = Vector2.new(1, 0)
	newPanel.Position = UDim2.new(1, -16, 0, 16)
	newPanel.Size = UDim2.fromOffset(300, ROW_HEIGHT * (MAX_ROWS + 1) + 20)

	local newHeader = UI.Label("Header", newPanel)
	newHeader.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	newHeader.Font = UI.Font.Heading
	newHeader.TextColor3 = UI.Palette.TextMuted
	newHeader.TextSize = 13
	newHeader.Text = "PLAYER                 POWER        REPUTATION"

	local newRows = Instance.new("Frame")
	newRows.Name = "Rows"
	newRows.BackgroundTransparency = 1
	newRows.Position = UDim2.fromOffset(0, ROW_HEIGHT)
	newRows.Size = UDim2.new(1, 0, 1, -ROW_HEIGHT)
	newRows.Parent = newPanel

	UI.VerticalList(newRows, 1)

	-- Rank belongs to the roster cluster: immediately left of the player list at the
	-- top-right, sharing its top edge and disappearing with it when Tab hides the list.
	local newRankButton = Instance.new("TextButton")
	newRankButton.Name = "OpenRanks"
	newRankButton.AnchorPoint = Vector2.new(1, 0)
	newRankButton.Position = UDim2.new(1, -326, 0, 16)
	newRankButton.Size = UDim2.fromOffset(88, 72)
	newRankButton.BackgroundColor3 = UI.Palette.Accent
	newRankButton.BackgroundTransparency = 0
	newRankButton.BorderSizePixel = 0
	newRankButton.AutoButtonColor = false
	newRankButton.Text = ""
	newRankButton.Parent = screen

	local rankCorner = Instance.new("UICorner")
	rankCorner.CornerRadius = UDim.new(0, 10)
	rankCorner.Parent = newRankButton

	local rankStroke = Instance.new("UIStroke")
	rankStroke.Color = UI.Palette.CartoonInk
	rankStroke.Thickness = 3
	rankStroke.Parent = newRankButton

	local rankIcon = Instance.new("Frame")
	rankIcon.Name = "Icon"
	rankIcon.AnchorPoint = Vector2.new(0.5, 0)
	rankIcon.Position = UDim2.new(0.5, 0, 0, 7)
	rankIcon.Size = UDim2.fromOffset(36, 36)
	rankIcon.BackgroundTransparency = 1
	rankIcon.Parent = newRankButton

	local rankAspect = Instance.new("UIAspectRatioConstraint")
	rankAspect.AspectRatio = 1
	rankAspect.Parent = rankIcon
	Icons.Draw("Rank", rankIcon, UI.Palette.CartoonInk, UI.Palette.Accent)

	local rankLabel = UI.Label("Label", newRankButton)
	rankLabel.AnchorPoint = Vector2.new(0.5, 1)
	rankLabel.Position = UDim2.new(0.5, 0, 1, -7)
	rankLabel.Size = UDim2.new(1, -10, 0, 18)
	rankLabel.Font = Enum.Font.GothamBold
	rankLabel.TextSize = 12
	rankLabel.TextColor3 = UI.Palette.CartoonInk
	rankLabel.TextXAlignment = Enum.TextXAlignment.Center
	rankLabel.Text = "RANK"

	UI.Pressable(newRankButton, { PressScale = 0.95, HoverScale = 1.03 })
	newRankButton.Activated:Connect(function()
		MenuController:Open("Ranks")
	end)

	panel = newPanel
	header = newHeader
	rows = newRows
	rankButton = newRankButton
end

function TabBarController:_render(roster: { any })
	local list = rows
	local title = header
	if list == nil or title == nil then
		return
	end

	list:ClearAllChildren()
	UI.VerticalList(list, 1)

	title.Text = `PLAYER ({#roster})          POWER        REPUTATION`
	if panel ~= nil then
		local shown = math.min(#roster, MAX_ROWS)
		panel.Size = UDim2.fromOffset(300, ROW_HEIGHT * (shown + 1) + 20)
	end

	for index, entry in roster do
		if index > MAX_ROWS then
			break
		end

		local row = Instance.new("Frame")
		row.Name = tostring(entry.UserId)
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.LayoutOrder = index
		row.Parent = list

		local name = UI.Label("Name", row)
		name.Size = UDim2.fromScale(0.46, 1)
		name.TextSize = 14
		name.TextColor3 = entry.RankColor or UI.Palette.Text

		-- Markers earned rather than decorative: a bounty and immunity both change
		-- how other players should treat this person.
		local marks = ""
		if entry.Immortal then
			marks ..= " 🛡"
		end
		if entry.Bounty > 0 then
			marks ..= ` 💰{NumberFormat.Format(entry.Bounty)}`
		end
		name.Text = `{entry.Name}{marks}`

		local power = UI.Label("Power", row)
		power.Size = UDim2.fromScale(0.28, 1)
		power.Position = UDim2.fromScale(0.46, 0)
		power.TextSize = 14
		power.Font = UI.Font.Numeric
		power.TextColor3 = UI.Palette.Power
		power.Text = NumberFormat.Format(entry.Power)

		local reputation = UI.Label("Reputation", row)
		reputation.Size = UDim2.fromScale(0.26, 1)
		reputation.Position = UDim2.fromScale(0.74, 0)
		reputation.TextSize = 13
		reputation.TextXAlignment = Enum.TextXAlignment.Right
		reputation.TextColor3 = entry.ReputationColor or UI.Palette.TextMuted
		reputation.Text = entry.ReputationName or ""
	end
end

function TabBarController:Start()
	self:_build()

	-- Replace, not overlay: leaving Roblox's list on would show two rosters at once.
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)

	Net.Event("RosterChanged").OnClientEvent:Connect(function(roster: any)
		if type(roster) == "table" then
			self:_render(roster)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Enum.KeyCode.Tab then
			return
		end
		visible = not visible
		if panel ~= nil then
			panel.Visible = visible
		end
		if rankButton ~= nil then
			rankButton.Visible = visible
		end
	end)
end

return TabBarController
