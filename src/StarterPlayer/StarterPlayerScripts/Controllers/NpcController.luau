--!strict
--[[
	NpcController — makes the figures in the plaza worth walking up to.

	Every model tagged `Npc` gets a proximity prompt and a nameplate, and triggering
	the prompt opens the menu on whichever tab the NPC's config names. That is the
	entire feature: there is no server side to it, because there is nothing for the
	server to decide. A remote here would exist only to tell the client to open its
	own UI, and it would be one more thing a client could spam.

	Bound per tagged model rather than by name, and rebound on add/remove, because
	StreamingEnabled unloads the plaza when you travel out to a district and loads
	it again when you come back. A one-shot pass at startup would leave the quest
	giver mute for the rest of the session.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local NpcConfig = require(ReplicatedStorage.Modules.NpcConfig)

-- How far above the figure's head the nameplate floats.
local HEADROOM = 3

local NpcController = {
	Name = "NpcController",
	Priority = 6,
}

local MenuController: any = nil

type Entry = {
	gui: BillboardGui,
	prompt: ProximityPrompt,
}

local bound: { [Instance]: Entry } = {}

function NpcController:Init()
	MenuController = Loader.Get("MenuController")
end

--[[
	Floats the plate over the whole figure rather than over its torso, which is the
	part the plate is actually attached to.
]]
local function headroomOffset(model: Instance, adornee: BasePart): Vector3
	if model:IsA("Model") then
		local boundsCFrame, boundsSize = model:GetBoundingBox()
		local top = boundsCFrame.Position.Y + boundsSize.Y / 2
		return Vector3.new(0, (top - adornee.Position.Y) + HEADROOM, 0)
	end
	return Vector3.new(0, adornee.Size.Y / 2 + HEADROOM, 0)
end

function NpcController:_bind(model: Instance)
	if bound[model] ~= nil then
		return
	end

	local definition, reason = NpcConfig.Resolve(model)
	if definition == nil then
		warn(`[NpcController] Ignoring {model:GetFullName()}: {reason}`)
		return
	end

	local base = model:FindFirstChild(NpcConfig.BASE_PART_NAME)
	if base == nil or not base:IsA("BasePart") then
		warn(`[NpcController] {model:GetFullName()} has no "{NpcConfig.BASE_PART_NAME}" part`)
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TalkPrompt"
	prompt.ActionText = definition.ActionText
	prompt.ObjectText = definition.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.MaxActivationDistance = NpcConfig.PROMPT_DISTANCE
	-- Figures are built from a stack of boxes that occlude their own torso, so
	-- requiring line of sight mostly means the prompt vanishing at arm's length.
	prompt.RequiresLineOfSight = false
	prompt.Parent = base

	local gui = Instance.new("BillboardGui")
	gui.Name = "NpcLabel"
	gui.Adornee = base
	gui.Size = UDim2.fromOffset(170, 54)
	gui.StudsOffsetWorldSpace = headroomOffset(model, base)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.Parent = base

	local panel = UI.Panel("Body", gui)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundTransparency = 0.2

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 13
	label.Text = `<b><font color="#{definition.Color:ToHex()}">{definition.DisplayName}</font></b>\n`
		.. `<font color="#8A93A8">{definition.Title}  —  press E</font>`

	prompt.Triggered:Connect(function()
		MenuController:Open(definition.Tab)
	end)

	bound[model] = { gui = gui, prompt = prompt }
end

function NpcController:_unbind(model: Instance)
	local entry = bound[model]
	if entry ~= nil then
		entry.gui:Destroy()
		entry.prompt:Destroy()
		bound[model] = nil
	end
end

function NpcController:Start()
	for _, model in CollectionService:GetTagged(NpcConfig.NPC_TAG) do
		self:_bind(model)
	end

	CollectionService:GetInstanceAddedSignal(NpcConfig.NPC_TAG):Connect(function(model)
		self:_bind(model)
	end)

	CollectionService:GetInstanceRemovedSignal(NpcConfig.NPC_TAG):Connect(function(model)
		self:_unbind(model)
	end)
end

return NpcController
