--!strict
--[[
	AuditionController — hear every sound, and every alternative, without leaving Studio.

	## Why this exists

	Whoever writes the audio config cannot hear it. That is not a small caveat: it is how
	the ground slam ended up being a recording of a table falling over, and the block a
	golf club hitting a pipe. Both were chosen by reading a catalogue description, both
	were obviously wrong within half a second of listening, and both survived two passes
	because no one who could hear was ever asked.

	A panel that plays anything on demand turns that from a guessing loop into a two-minute
	job: press F9, click through, note the ids that sound right. It also makes every future
	tweak cheap, which is the difference between an audio pass that gets finished and one
	that gets abandoned halfway.

	## Studio only

	Gated on `RunService:IsStudio()` at Init *and* again before the panel is built, the
	same belt-and-braces `DevService` uses. A dev tool that can reach a live player is a
	dev tool that will, eventually.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local EffectsConfig = require(ReplicatedStorage.Modules.EffectsConfig)
local SoundCandidates = require(ReplicatedStorage.Modules.SoundCandidates)

local AuditionController = {
	Name = "AuditionController",
	-- Below everything real. This is a tool, and it must never be in the way of a system
	-- that the game actually needs.
	Priority = 1,
}

local EffectsController: any = nil
local screen: ScreenGui? = nil
local open = false

local function allowed(): boolean
	return RunService:IsStudio()
end

--[[
	Plays a raw id with no config behind it, so a candidate can be heard as itself.

	Deliberately dry: no layers, no DSP, no rolloff. The question this panel answers is
	"is this the right recording", and processing is what you decide *after* that. A
	candidate auditioned through the full chain would be judged on the chain.
]]
local function playRaw(soundId: string)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.7
	sound.Parent = workspace
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(10, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
end

function AuditionController:Init()
	if not allowed() then
		return
	end
	EffectsController = Loader.Get("EffectsController")
end

function AuditionController:_row(
	parent: Instance,
	order: number,
	label: string,
	detail: string,
	onPlay: () -> ()
)
	local row = Instance.new("Frame")
	row.Name = label
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 30)
	row.LayoutOrder = order
	row.Parent = parent

	local text = UI.Label("Text", row)
	text.Size = UDim2.new(1, -74, 1, 0)
	text.TextSize = 12
	text.Text = `<b>{label}</b>  <font color="#8A93A8">{detail}</font>`

	local play = Instance.new("TextButton")
	play.Name = "Play"
	play.Text = "PLAY"
	play.Font = UI.Font.Body
	play.TextSize = 11
	play.TextColor3 = UI.Palette.OnAccent
	play.BackgroundColor3 = UI.Palette.Accent
	play.BorderSizePixel = 0
	play.Size = UDim2.fromOffset(64, 22)
	play.Position = UDim2.new(1, -66, 0.5, -11)
	play.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = play

	UI.Pressable(play)
	play.Activated:Connect(onPlay)
end

function AuditionController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "GymAudition"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 60
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = UI.Panel("Panel", gui)
	panel.Size = UDim2.fromOffset(430, 560)
	panel.Position = UDim2.new(0, 24, 0.5, -280)

	local title = UI.Label("Title", panel)
	title.Size = UDim2.new(1, -24, 0, 34)
	title.Position = UDim2.fromOffset(12, 8)
	title.Font = UI.Font.Heading
	title.TextSize = 16
	title.Text = 'SOUND AUDITION  <font color="#8A93A8">F9 to close · Studio only</font>'

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -24, 1, -56)
	scroll.Position = UDim2.fromOffset(12, 46)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.Parent = panel

	local layout = UI.VerticalList(scroll, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	local order = 0
	-- Sorted, because an unordered dictionary means the row you want is somewhere
	-- different every session.
	local names: { string } = {}
	for name in EffectsConfig.Sounds :: { [string]: EffectsConfig.SoundSpec } do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		local spec = (EffectsConfig.Sounds :: any)[name] :: EffectsConfig.SoundSpec
		order += 1

		local built = {}
		if spec.Layers ~= nil then
			table.insert(built, `{#spec.Layers} layers`)
		end
		if spec.Effects ~= nil then
			for _, effect in spec.Effects do
				table.insert(built, effect.Class)
			end
		end
		local detail = if #built > 0 then table.concat(built, " + ") else "dry"

		-- The real thing: layers, DSP and all, exactly as the game plays it.
		self:_row(scroll, order, name, `IN GAME · {detail}`, function()
			local character = Players.LocalPlayer.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			EffectsController:Play(name, if root ~= nil and root:IsA("BasePart") then root else nil)
		end)

		local candidates = (SoundCandidates.For :: any)[name] :: { SoundCandidates.Candidate }?
		if candidates ~= nil then
			for _, candidate in candidates do
				order += 1
				local id = string.match(candidate.SoundId, "%d+$") or candidate.SoundId
				self:_row(scroll, order, `    {id}`, candidate.Note, function()
					playRaw(candidate.SoundId)
				end)
			end
		end
	end

	screen = gui
end

function AuditionController:Toggle()
	if not allowed() or screen == nil then
		return
	end
	open = not open;
	(screen :: ScreenGui).Enabled = open
end

function AuditionController:Start()
	if not allowed() then
		return
	end

	for _, failure in SoundCandidates.RunSelfTest() do
		warn(`[AuditionController] {failure}`)
	end

	-- The half of the check SoundCandidates cannot do for itself: a candidate list for a
	-- slot that no longer exists is dead weight that rots silently as sounds are renamed.
	for name in SoundCandidates.For :: { [string]: any } do
		if (EffectsConfig.Sounds :: any)[name] == nil then
			warn(`[AuditionController] candidates listed for "{name}", which is not a sound`)
		end
	end

	self:_build()

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F9 then
			self:Toggle()
		end
	end)

	print("[AuditionController] Studio session — press F9 for the sound audition panel.")
end

return AuditionController
