--!strict
--[[
	ToastController — transient notifications and the kill feed.

	Everything server-side that wants to tell a player something fires Notify, so this
	is the single place that decides how a message looks and how long it lives. Adding
	a new kind of announcement never needs new UI.

	Toasts stack downward from the top-centre and expire on a timer. The list is capped
	so a burst — a killstreak announcement to a full server, say — cannot cover the
	screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)

local MAX_TOASTS = 5
local TOAST_SECONDS = 4
local FADE_SECONDS = 0.35

local ToastController = {
	Name = "ToastController",
	Priority = 9,
}

local container: Frame? = nil
local active: { Frame } = {}

function ToastController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymToasts"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10
	screen.Parent = playerGui

	-- Built into a local and published at the end, so property writes are not each
	-- treated as a nil-check against the optional module field.
	local frame = Instance.new("Frame")
	frame.Name = "Toasts"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 18)
	frame.Size = UDim2.fromOffset(420, 220)
	frame.Parent = screen

	local layout = UI.VerticalList(frame, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	container = frame
end

--[[
	Shows a message. `accent` tints the left edge, which is how kill-feed lines are
	distinguished from ordinary notices without a second widget.
]]
function ToastController:Show(text: string, accent: Color3?)
	local parent = container
	if parent == nil then
		return
	end

	local panel = UI.Panel("Toast", parent)
	panel.Size = UDim2.fromOffset(400, 34)
	panel.BackgroundTransparency = 0.15

	local stripe = Instance.new("Frame")
	stripe.Name = "Accent"
	stripe.BackgroundColor3 = accent or UI.Palette.Accent
	stripe.BorderSizePixel = 0
	stripe.Size = UDim2.new(0, 3, 1, 0)
	stripe.Position = UDim2.fromOffset(-8, 0)
	stripe.Parent = panel

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextSize = 15
	label.Text = text

	table.insert(active, panel)

	-- Oldest first: a burst pushes out stale lines rather than piling up.
	while #active > MAX_TOASTS do
		local oldest = table.remove(active, 1)
		if oldest ~= nil then
			oldest:Destroy()
		end
	end

	task.delay(TOAST_SECONDS, function()
		if panel.Parent == nil then
			return
		end

		local fade = TweenService:Create(panel, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 })
		local fadeText = TweenService:Create(label, TweenInfo.new(FADE_SECONDS), { TextTransparency = 1 })
		fade:Play()
		fadeText:Play()

		fade.Completed:Wait()

		local index = table.find(active, panel)
		if index ~= nil then
			table.remove(active, index)
		end
		panel:Destroy()
	end)
end

function ToastController:Start()
	self:_build()

	Net.Event("Notify").OnClientEvent:Connect(function(text: any)
		if type(text) == "string" then
			ToastController:Show(text)
		end
	end)

	Net.Event("KillFeed").OnClientEvent:Connect(function(entry: any)
		if type(entry) ~= "table" then
			return
		end

		-- Repeat kills are shown but greyed, so the feed stays honest about what
		-- happened without implying the killer earned anything.
		local accent = if entry.IsRepeat
			then UI.Palette.TextMuted
			elseif entry.KillerIsOutlaw then UI.Palette.Danger
			else UI.Palette.Combo

		ToastController:Show(`{entry.KillerName} knocked out {entry.VictimName}`, accent)
	end)
end

return ToastController
