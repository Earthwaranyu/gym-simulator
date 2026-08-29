--!strict
--[[
	FullMapController — the dedicated, interactive city map.

	The old full map lived inside MenuController's vertical ScrollingFrame. Its own
	zoomable ScrollingFrame therefore competed with the page for every mouse-wheel
	gesture: zooming out could scroll the page, and scrolling the page could move the
	map. This controller owns a separate ScreenGui with no page scroll at all. Wheel,
	drag and touch input have exactly one possible destination: the map canvas.

	Selecting a pin never performs an action immediately. It opens a persistent detail
	panel with two honest choices:

	  * Track is free and creates the existing world waypoint.
	  * Teleport is visibly locked behind Fast Travel and is still revalidated by the
	    server, including ownership, power, combat state and destination existence.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local Icons = require(ReplicatedStorage.Modules.Icons)
local MapRender = require(ReplicatedStorage.Modules.MapRender)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)
local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local MapViewportMath = require(ReplicatedStorage.Modules.MapViewportMath)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

type Destination = MapRender.Destination
type Hostile = MapRender.Hostile
type BossState = { Alive: boolean, SecondsUntil: number }
type MapItemLayout = {
	Position: UDim2,
	Size: UDim2,
}

local FullMapController = {
	Name = "FullMapController",
	Priority = 8,
}

FullMapController.Changed = Signal.new()

local PANEL_SIZE = Vector2.new(980, 620)
-- Breathing room kept between the panel and the window edge at every scale, so the map
-- reads as a page over the world rather than as something jammed against the frame.
local PANEL_MARGIN = 24
-- How far the map may be dragged past the edge of its own canvas, as a fraction of the
-- board. Without slack there is nothing to drag to at the default zoom — the canvas is
-- exactly the viewport, so the offset clamps to zero and the map only starts responding
-- to a drag once you have zoomed in, which is not something a player can guess. It is
-- also the honest way to reach a pin sitting under the filter bar or the zoom buttons.
local PAN_SLACK = 0.35
local HEADER_HEIGHT = 48
local CONTENT_GAP = 12
local SIDEBAR_WIDTH = 250
local MAP_ASPECT = 1.19
local MIN_ZOOM = 1
local MAX_ZOOM = 4
local ZOOM_STEP = 1.25
local PIN_SIZE = 26
local SELECTED_PIN_SIZE = 30
-- Monster pins are deliberately smaller than machine pins, and drawn under them.
-- Fourteen hostile sites at the same size as thirty-five machines made the map look
-- like it was about the monsters; it is about where to train, and a fight is
-- somewhere you may choose to go instead.
local HOSTILE_PIN_SIZE = 18
local SELECTED_HOSTILE_PIN_SIZE = 22

--[[
	Board pixels reserved for the chrome drawn *over* the map.

	The filter bar spans the full width of the board's top; the status strip and the zoom
	buttons sit along its bottom. A pin underneath any of them is exactly as unreachable
	as one past the edge, so the map is drawn between them rather than behind them.

	The legend is deliberately not counted: it covers one corner rather than a full band,
	and reserving its height would cost the map far more area than it saves.
]]
local MAP_TOP_CHROME = 52
local MAP_BOTTOM_CHROME = 48

-- Breathing room past whatever the widest item needs, for the stroke drawn outside a
-- pin's frame and for the 1.12 hover scale, neither of which is in its measured size.
local MAP_EDGE_PADDING = 4

local MAP_PAPER = MapRender.Paper
local MAP_INK = MapRender.Ink

local player = Players.LocalPlayer
local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local content: Frame
local isOpen = false
local hasFastTravel = false
-- Bumped on every _render. The whole panel is torn down and rebuilt, so anything that
-- has to touch the new tree a frame later checks this first and gives up if a newer
-- render has already replaced what it was going to write to.
local renderGeneration = 0

-- How long the panel waits before redrawing for replicated profile data. Slow enough
-- that a rep every frame costs one redraw, fast enough to still look live.
local PROFILE_RENDER_INTERVAL = 0.25

-- What the profile looked like, in map terms, at the last render. See profileSignature.
local lastRenderedSignature = ""
-- Exactly one of these is ever set. The sidebar shows a machine or a monster, and
-- selecting either kind clears the other, so there is no state where the panel has to
-- choose which of two selections it is describing.
local selectedDestination: string? = nil
local selectedHostile: string? = nil
local destinations: { Destination } = {}
local hostiles: { Hostile } = {}
-- Per zone, from MobService's BossStateChanged broadcast. Stamped with the clock time
-- it arrived so the countdown stays honest between broadcasts without a render loop.
local bossState: { [string]: BossState } = {}
local bossStateAt = 0
local mapFeatures: { MapRender.Feature } = {}
local mapZoom = 1
local mapCenter = Vector2.new(0.5, 0.5)
-- Nil is the normal city map. A stat id keeps the same streets and buildings visible
-- while showing only that muscle's destinations.
local activeStatFilter: string? = nil

local function toast(message: string?)
	if ToastController ~= nil and type(message) == "string" and message ~= "" then
		ToastController:Show(message)
	end
end

local function addCorner(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addBorder(
	parent: GuiObject,
	color: Color3,
	transparency: number?,
	thickness: number?
): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency or 0
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function destinationLabel(destination: Destination): (string, Color3)
	local equipment = EquipmentConfig.Get(destination.EquipmentId)
	local zone = ZoneConfig.Get(destination.ZoneId)
	local stat = StatConfig.Get(destination.StatId)
	local equipmentName = if equipment ~= nil then equipment.DisplayName else destination.EquipmentId
	local color = if stat ~= nil then stat.Color else UI.Palette.Accent
	-- Where it is, not which tier owns it. A tier is a rank now, and the one thing
	-- a player tracking a machine across the city needs is the place.
	local where = if destination.LocationName ~= ""
		then destination.LocationName
		elseif zone ~= nil then zone.DisplayName
		else ""
	return (if where ~= "" then `{equipmentName} · {where}` else equipmentName), color
end

-- One island is one multiplier tier, and every station on it shares that island's
-- environment id, so the environment id is already the cluster. This used to have
--[[
	Which pins are close enough to collide, in world studs.

	Pins used to be grouped by EnvironmentId, on the premise -- true at the time --
	that an environment was one compact campus whose five machines stood together.
	The machines have since been scattered across the city and an environment
	became a *region* thousands of studs wide, so grouping by it drew every machine
	at its region's centroid: 34 of 35 pins landed more than 500 studs from their
	machine, the worst 4,809 studs away, which is about a third of the map.

	Grouping now asks the only question that matters -- would these two pins
	actually overlap? -- so it cannot go stale when the world is rearranged again.

	A pin is PIN_SIZE pixels on a board roughly MAP_BOARD_WIDTH_PX across, so its
	footprint in studs is that fraction of the world the map is showing. The margin
	is wide: the starter ring sits 92 studs apart and genuinely overlaps, while the
	nearest two scattered machines are 963 apart and never do.
]]
local MAP_BOARD_WIDTH_PX = 900

local function overlapDistance(bounds: { Width: number }): number
	return bounds.Width * (PIN_SIZE / MAP_BOARD_WIDTH_PX)
end

local function statOrder(statId: string): number
	for index, definition in StatConfig.List do
		if definition.Id == statId then
			return index
		end
	end
	return #StatConfig.List + 1
end

function FullMapController:Init()
	ProfileController = Loader.Get("ProfileController")
	ToastController = Loader.Get("ToastController")
end

function FullMapController:_fetchMap()
	destinations, mapFeatures, hostiles = MapRender.Fetch()
end

--[[
	How long until this zone's boss is back, or nil if it is standing right now.

	Returns nil for a zone nobody has broadcast yet too — an unknown boss is drawn as
	unknown rather than as a countdown from zero.
]]
local function bossCountdown(zoneId: string): number?
	local state = bossState[zoneId]
	if state == nil or state.Alive then
		return nil
	end
	return math.max(state.SecondsUntil - (os.clock() - bossStateAt), 0)
end

local function countdownText(seconds: number): string
	local minutes = math.floor(seconds / 60)
	return `{minutes}:{string.format("%02d", math.floor(seconds % 60))}`
end

--[[
	The line under a hostile site's name: what is standing there, or when it will be.

	A field never has a timer. Its thieves respawn one at a time on their own clocks and
	the field is always worth walking to, so promising a countdown for it would be
	inventing a fact the server never sends.
]]
local function hostileState(hostile: Hostile): (string, Color3)
	if hostile.Kind ~= "Boss" then
		return "ALWAYS HUNTING", UI.Palette.TextMuted
	end
	local remaining = bossCountdown(hostile.ZoneId)
	if remaining == nil then
		local state = bossState[hostile.ZoneId]
		if state == nil then
			return "STATUS UNKNOWN", UI.Palette.TextMuted
		end
		return "ALIVE NOW", UI.Palette.Vital
	end
	return `RESPAWNS IN {countdownText(remaining)}`, UI.Palette.Token
end

function FullMapController:_fetchTravelAccess()
	local ok, access = pcall(function()
		return Net.Function("GetTravelAccess"):InvokeServer()
	end)
	if ok and type(access) == "table" then
		hasFastTravel = access.HasFastTravel == true
	end
end

function FullMapController:_promptFastTravel()
	local ok, message = Net.Function("PromptProduct"):InvokeServer("FastTravel")
	if not ok then
		toast(message or "Fast Travel is unavailable right now.")
	end
end

-- Track and Teleport are told where and what, never which kind. A monster site and a
-- machine are the same request to the waypoint and to the server; only the sidebar
-- above them knows the difference.
function FullMapController:_track(position: Vector3, label: string, color: Color3)
	local WaypointController = Loader.Get("WaypointController")
	WaypointController:SetTarget(position, label, color)
	toast(`Tracking {label} — follow the arrow`)
	self:Close()
end

--[[
	Stops tracking, and stays on the map.

	Tracking closes the map because you are done with it — you have somewhere to go.
	Clearing a waypoint is the opposite: it usually means this was not the place, so the
	map stays open on the board you were reading, with the button flipped back to TRACK.
]]
function FullMapController:_untrack(label: string)
	local WaypointController = Loader.Get("WaypointController")
	WaypointController:Clear()
	toast(`Stopped tracking {label}`)
	self:_render()
end

-- Whether the arrow is already pointing here, which is what turns TRACK into UNTRACK.
function FullMapController:_isTracking(position: Vector3): boolean
	local WaypointController = Loader.Get("WaypointController")
	return WaypointController:IsTracking(position)
end

function FullMapController:_teleport(id: string)
	-- The client lock is presentation only. TravelService repeats every check and is
	-- the sole authority that can move the character.
	local ok, message = Net.Function("Travel"):InvokeServer(id)
	if ok then
		toast(message)
		self:Close()
		return
	end

	if message == "NO_FAST_TRAVEL" then
		hasFastTravel = false
		toast("Fast Travel gamepass required. You can still track this location for free.")
		self:_render()
		return
	end

	toast(message)
end

local function statValue(data: any?, statId: string): number
	return if data ~= nil then (data.Stats[statId] or 0) else 0
end

local function destinationUnlocked(data: any?, destination: Destination): boolean
	return statValue(data, destination.StatId) >= destination.RequiredStat
end

--[[
	Everything the map draws out of the profile, as one comparable string.

	Deliberately not a hash of the profile: stats tick every rep and the map does not
	show them. What it shows is which circles are open, whether Fast Travel is owned,
	and — only while a locked site is selected — how far short the player still is. That
	last one does move per rep, which is correct: it is a number the player is watching.
]]
local function profileSignature(): string
	local data = ProfileController:Get()
	local parts = { if hasFastTravel then "1" else "0" }
	for _, destination in destinations do
		table.insert(parts, if destinationUnlocked(data, destination) then "1" else "0")
	end

	if selectedDestination ~= nil then
		local destination = MapRender.GetDestination(selectedDestination)
		if destination ~= nil then
			table.insert(parts, tostring(destination.RequiredStat - statValue(data, destination.StatId)))
		end
	end
	if selectedHostile ~= nil then
		local hostile = MapRender.GetHostile(selectedHostile)
		if hostile ~= nil then
			local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
			table.insert(parts, tostring(hostile.RequiredPower - power))
		end
	end

	return table.concat(parts, ",")
end

function FullMapController:_currentMultiplier(data: any?, statId: string): number?
	-- Progression is independent: Arms can be in Iron while Legs remain at the beach.
	local best: number? = nil
	for _, destination in destinations do
		if
			destination.StatId == statId
			and destinationUnlocked(data, destination)
			and (best == nil or destination.GainMultiplier > best)
		then
			best = destination.GainMultiplier
		end
	end
	return best
end

function FullMapController:_sideButton(
	parent: GuiObject,
	name: string,
	text: string,
	position: UDim2,
	color: Color3,
	enabled: boolean,
	onClick: () -> ()
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = UDim2.new(1, -20, 0, 44)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = if enabled then 0 else 0.55
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Active = enabled
	button.Font = UI.Font.Heading
	button.TextSize = 14
	button.TextColor3 = if enabled then UI.Palette.CartoonInk else UI.Palette.TextMuted
	button.Text = text
	button.Parent = parent
	addCorner(button, 9)
	addBorder(button, if enabled then UI.Palette.CartoonInk else UI.Palette.GlassStroke, 0.25, 2)

	if enabled then
		UI.Pressable(button, { PressScale = 0.96, HoverScale = 1.015 })
		button.Activated:Connect(onClick)
	end
	return button
end

--[[
	The tier index: every multiplier for the chosen muscle, weakest to strongest.

	"Select a coloured circle on the map" was the whole of this space until a
	destination was picked, which made the only way to find the next tier a hunt for
	the right pin among thirty-five. The muscle filter chips above the map already
	narrow the pins; this turns that same filter into an ordered list you can read,
	and picking a row selects the destination, so the detail panel and its Teleport
	button below are reached without new travel code.
]]
function FullMapController:_renderTierList(parent: Frame, data: any?)
	local rows: { Destination } = {}
	for _, candidate in destinations do
		if activeStatFilter == nil or candidate.StatId == activeStatFilter then
			table.insert(rows, candidate)
		end
	end

	table.sort(rows, function(a: Destination, b: Destination): boolean
		-- Grouped by muscle in StatConfig order when no filter is on, so the unfiltered
		-- list is still a readable index rather than thirty-five interleaved tiers.
		local orderA, orderB = statOrder(a.StatId), statOrder(b.StatId)
		if orderA ~= orderB then
			return orderA < orderB
		end
		if a.GainMultiplier ~= b.GainMultiplier then
			return a.GainMultiplier < b.GainMultiplier
		end
		return a.Id < b.Id
	end)

	local list = Instance.new("ScrollingFrame")
	list.Name = "TierList"
	list.Position = UDim2.fromOffset(10, 36)
	list.Size = UDim2.new(1, -20, 1, -46)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ZIndex = 3
	list.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	for order, candidate in rows do
		local stat = StatConfig.Get(candidate.StatId)
		local zone = ZoneConfig.Get(candidate.ZoneId)
		if stat == nil then
			continue
		end

		local unlocked = destinationUnlocked(data, candidate)

		local row = Instance.new("TextButton")
		row.Name = candidate.Id
		row.LayoutOrder = order
		row.Size = UDim2.new(1, -6, 0, 56)
		row.BackgroundColor3 = UI.Palette.Glass
		row.BackgroundTransparency = if unlocked then 0.12 else 0.4
		row.BorderSizePixel = 0
		row.AutoButtonColor = false
		row.Text = ""
		row.ZIndex = 4
		row.Parent = list
		addCorner(row, 7)
		addBorder(row, stat.Color, if unlocked then 0.25 else 0.7, 1)
		UI.Pressable(row, { PressScale = 0.98, HoverScale = 1.01 })

		local icon = Instance.new("Frame")
		icon.Name = "Icon"
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 8, 0.5, 0)
		icon.Size = UDim2.fromOffset(30, 30)
		icon.BackgroundTransparency = 1
		icon.ZIndex = 5
		icon.Parent = row
		Icons.Draw(stat.Icon, icon, stat.Color, UI.Palette.CartoonInk)

		local name = UI.Label("Name", row)
		name.Position = UDim2.fromOffset(46, 6)
		name.Size = UDim2.new(1, -56, 0, 18)
		name.Font = UI.Font.Heading
		name.TextSize = 12
		name.TextColor3 = if unlocked then UI.Palette.Text else UI.Palette.TextMuted
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 5
		-- The machine, not its tier. Seven Chest machines used to share one row
		-- label because the label named the tier they belonged to, and after the
		-- campuses were dissolved that tier was not even a place any more. What a
		-- player is choosing between is a Bench Press and a Cable Crossover.
		local rowEquipment = EquipmentConfig.Get(candidate.EquipmentId)
		name.Text = if rowEquipment ~= nil then rowEquipment.DisplayName else candidate.EquipmentId

		local detail = UI.Label("Detail", row)
		detail.Position = UDim2.fromOffset(46, 24)
		detail.Size = UDim2.new(1, -56, 0, 16)
		detail.TextSize = 11
		detail.TextColor3 = stat.Color
		detail.ZIndex = 5
		detail.Text = if zone ~= nil
			then `×{NumberFormat.Format(candidate.GainMultiplier)} · {zone.DisplayName}`
			else `×{NumberFormat.Format(candidate.GainMultiplier)} Multiplier`

		local requirement = UI.Label("Requires", row)
		requirement.Position = UDim2.fromOffset(46, 39)
		requirement.Size = UDim2.new(1, -56, 0, 14)
		requirement.TextSize = 10
		requirement.TextColor3 = if unlocked then UI.Palette.TextMuted else UI.Palette.Danger
		requirement.ZIndex = 5
		requirement.Text = if candidate.RequiredStat > 0
			then `REQUIRES {NumberFormat.Format(candidate.RequiredStat)} {stat.DisplayName}`
			else "OPEN TO EVERYONE"

		row.Activated:Connect(function()
			selectedDestination = candidate.Id
			selectedHostile = nil
			self:_render()
		end)
	end

	self:_renderThreatRows(list, data, #rows)
end

--[[
	The monsters, appended under the machine tiers as their own section.

	They belong in the same list rather than behind a separate tab because they are the
	same decision: this is the index of everywhere in the city worth going, ordered by
	what it costs to be allowed there. A muscle filter hides them — a monster does not
	train a muscle, so under "LEGS" it would be noise.
]]
function FullMapController:_renderThreatRows(list: ScrollingFrame, data: any?, offset: number)
	if activeStatFilter ~= nil or #hostiles == 0 then
		return
	end

	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0

	local header = UI.Label("ThreatsHeading", list)
	header.LayoutOrder = offset + 1
	header.Size = UDim2.new(1, -6, 0, 28)
	header.Font = UI.Font.Heading
	header.TextSize = 12
	header.TextColor3 = UI.Palette.TextMuted
	header.ZIndex = 4
	header.Text = "THREATS"

	for index, hostile in hostiles do
		local site = MapRender.SiteIcon(hostile.Kind)
		local accent = if hostile.Kind == "Boss" then UI.Palette.Danger else site.Color
		local unlocked = power >= hostile.RequiredPower

		local row = Instance.new("TextButton")
		row.Name = hostile.Id
		row.LayoutOrder = offset + 1 + index
		row.Size = UDim2.new(1, -6, 0, 56)
		row.BackgroundColor3 = UI.Palette.Glass
		row.BackgroundTransparency = if unlocked then 0.12 else 0.4
		row.BorderSizePixel = 0
		row.AutoButtonColor = false
		row.Text = ""
		row.ZIndex = 4
		row.Parent = list
		addCorner(row, 7)
		addBorder(row, accent, if unlocked then 0.25 else 0.7, 1)
		UI.Pressable(row, { PressScale = 0.98, HoverScale = 1.01 })

		local icon = Instance.new("Frame")
		icon.Name = "Icon"
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 8, 0.5, 0)
		icon.Size = UDim2.fromOffset(30, 30)
		icon.BackgroundTransparency = 1
		icon.ZIndex = 5
		icon.Parent = row
		Icons.Draw(site.Icon, icon, accent, UI.Palette.CartoonInk)

		local name = UI.Label("Name", row)
		name.Position = UDim2.fromOffset(46, 6)
		name.Size = UDim2.new(1, -56, 0, 18)
		name.Font = UI.Font.Heading
		name.TextSize = 12
		name.TextColor3 = if unlocked then UI.Palette.Text else UI.Palette.TextMuted
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 5
		name.Text = hostile.DisplayName

		local stateText, stateColor = hostileState(hostile)
		local detail = UI.Label("Detail", row)
		detail.Position = UDim2.fromOffset(46, 24)
		detail.Size = UDim2.new(1, -56, 0, 16)
		detail.TextSize = 11
		detail.TextColor3 = stateColor
		detail.ZIndex = 5
		detail.Text = stateText

		local requirement = UI.Label("Requires", row)
		requirement.Position = UDim2.fromOffset(46, 39)
		requirement.Size = UDim2.new(1, -56, 0, 14)
		requirement.TextSize = 10
		requirement.TextColor3 = if unlocked then UI.Palette.TextMuted else UI.Palette.Danger
		requirement.ZIndex = 5
		requirement.Text = if hostile.RequiredPower > 0
			then `REQUIRES {NumberFormat.Format(hostile.RequiredPower)} POWER`
			else "OPEN TO EVERYONE"

		row.Activated:Connect(function()
			selectedHostile = hostile.Id
			selectedDestination = nil
			self:_render()
		end)
	end
end

--[[
	The detail card for a mob field or a boss arena.

	Deliberately the same card as a machine's: a glyph, what it is, where it is, what it
	costs to be let in, and the same two buttons in the same two places. The PvE half of
	the game was navigable only from memory; making it look like a different feature
	with different rules would not have fixed that.

	Teleport is offered for a dead boss too. The destination is the arena, and standing
	in it waiting for the timer is a legitimate way to spend the wait.
]]
function FullMapController:_renderHostile(parent: Frame, data: any?, hostile: Hostile)
	local zone = ZoneConfig.Get(hostile.ZoneId)
	-- What this kill is worth to THIS player. Resolved through the same MobConfig
	-- function the server pays through, so the card cannot promise one figure and the
	-- kill hand over another.
	local definition = MobConfig.Get(hostile.Id)
	local classLevel = if data ~= nil then data.MuscleClassLevel else 0
	local rewardBonus = if definition ~= nil then MobConfig.RewardMultiplier(definition, classLevel) else 1
	local classBonus = MuscleClassConfig.Get(classLevel).TokenMultiplier
	local site = MapRender.SiteIcon(hostile.Kind)
	local accent = if hostile.Kind == "Boss" then UI.Palette.Danger else site.Color

	local iconBubble = Instance.new("Frame")
	iconBubble.Name = "MobIcon"
	iconBubble.Position = UDim2.fromOffset(12, 38)
	iconBubble.Size = UDim2.fromOffset(54, 54)
	iconBubble.BackgroundColor3 = accent:Lerp(UI.Palette.CartoonInk, 0.68)
	iconBubble.BorderSizePixel = 0
	iconBubble.Parent = parent
	addCorner(iconBubble, 27)
	addBorder(iconBubble, accent, 0.1, 2)

	local iconPadding = Instance.new("UIPadding")
	iconPadding.PaddingTop = UDim.new(0, 8)
	iconPadding.PaddingBottom = UDim.new(0, 8)
	iconPadding.PaddingLeft = UDim.new(0, 8)
	iconPadding.PaddingRight = UDim.new(0, 8)
	iconPadding.Parent = iconBubble
	Icons.Draw(site.Icon, iconBubble, accent, UI.Palette.CartoonInk)

	local name = UI.Label("Name", parent)
	name.Position = UDim2.fromOffset(76, 40)
	name.Size = UDim2.new(1, -88, 0, 24)
	name.Font = UI.Font.Heading
	name.TextSize = 15
	name.TextColor3 = UI.Palette.Text
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = string.upper(hostile.DisplayName)

	local kind = UI.Label("Kind", parent)
	kind.Position = UDim2.fromOffset(76, 66)
	kind.Size = UDim2.new(1, -88, 0, 18)
	kind.Font = UI.Font.Heading
	kind.TextSize = 12
	kind.TextColor3 = accent
	kind.Text = if hostile.Kind == "Boss" then "BOSS ARENA" else "HUNTING GROUND"

	local where = UI.Label("Where", parent)
	where.Position = UDim2.fromOffset(12, 108)
	where.Size = UDim2.new(1, -24, 0, 38)
	where.Font = UI.Font.Heading
	where.TextSize = 13
	where.TextWrapped = true
	where.TextColor3 = UI.Palette.Text
	where.Text = if zone ~= nil
		then `{zone.DisplayName} tier\n<font color="#8A93A8">{math.round(hostile.Radius)} stud site</font>`
		else hostile.ZoneId

	local threat = UI.Label("Threat", parent)
	threat.Position = UDim2.fromOffset(12, 158)
	threat.Size = UDim2.new(1, -24, 0, 42)
	threat.Font = UI.Font.Numeric
	threat.TextSize = 16
	threat.TextWrapped = true
	threat.TextColor3 = accent
	threat.Text =
		`{NumberFormat.Format(hostile.Health)} HP  ·  {NumberFormat.Format(hostile.Damage)} PER HIT`

	local stateText, stateColor = hostileState(hostile)
	local stateLabel = UI.Label("State", parent)
	stateLabel.Position = UDim2.fromOffset(12, 204)
	stateLabel.Size = UDim2.new(1, -24, 0, 18)
	stateLabel.Font = UI.Font.Heading
	stateLabel.TextSize = 11
	stateLabel.TextColor3 = stateColor
	stateLabel.Text = stateText

	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
	local shortfall = hostile.RequiredPower - power
	local powerLabel = UI.Label("Power", parent)
	powerLabel.Position = UDim2.fromOffset(12, 230)
	powerLabel.Size = UDim2.new(1, -24, 0, 44)
	powerLabel.Font = UI.Font.Heading
	powerLabel.TextSize = 12
	powerLabel.TextWrapped = true
	if shortfall > 0 then
		powerLabel.TextColor3 = UI.Palette.Danger
		powerLabel.Text = `POWER LOCKED\nNEED {NumberFormat.Format(shortfall)} MORE`
	else
		powerLabel.TextColor3 = UI.Palette.Vital
		-- Two different currencies, and the row cannot tell you which without being
		-- told: thieves pay Fight Tokens, which buy physique transformations, and
		-- bosses pay Tokens, which buy stat multipliers. Naming the wrong one sends a
		-- player to farm for something they cannot spend on what they are saving for.
		local currency = if hostile.Kind == "Boss" then "TOKENS" else "FIGHT TOKENS"
		powerLabel.Text = `OPEN TO YOU\nPAYS {NumberFormat.Format(hostile.Reward * rewardBonus)} {currency}`
	end

	local rule = Instance.new("Frame")
	rule.Position = UDim2.fromOffset(12, 286)
	rule.Size = UDim2.new(1, -24, 0, 2)
	rule.BackgroundColor3 = UI.Palette.GlassStroke
	rule.BackgroundTransparency = 0.55
	rule.BorderSizePixel = 0
	rule.Parent = parent

	local actionHint = UI.Label("ActionHint", parent)
	actionHint.Position = UDim2.fromOffset(12, 302)
	actionHint.Size = UDim2.new(1, -24, 0, 34)
	actionHint.TextWrapped = true
	actionHint.TextSize = 11
	actionHint.TextColor3 = UI.Palette.TextMuted
	-- Only worth saying when the cap is actually costing them something. A player whose
	-- class sits below the tier is already paid in full and does not need to be told
	-- about a ceiling they have not reached.
	actionHint.Text = if definition ~= nil and classBonus > definition.RewardCap
		then `This tier caps your class bonus at ×{NumberFormat.Format(definition.RewardCap)}. Stronger monsters pay more.`
		else "Track is free. Teleport needs Fast Travel and enough Power."

	local trackingHostile = self:_isTracking(hostile.Position)
	self:_sideButton(
		parent,
		"Track",
		if trackingHostile then "UNTRACK" else "TRACK",
		UDim2.new(0, 10, 1, -108),
		if trackingHostile then UI.Palette.Glass else accent,
		true,
		function()
			if trackingHostile then
				self:_untrack(hostile.DisplayName)
			else
				self:_track(hostile.Position, hostile.DisplayName, accent)
			end
		end
	)

	if not hasFastTravel then
		self:_sideButton(
			parent,
			"TeleportLocked",
			"LOCKED · GET FAST TRAVEL",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			true,
			function()
				self:_promptFastTravel()
			end
		)
	else
		self:_sideButton(
			parent,
			"Teleport",
			if shortfall > 0 then "LOCKED · NEED MORE POWER" else "TELEPORT",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			shortfall <= 0,
			function()
				self:_teleport(hostile.Id)
			end
		)
	end
end

function FullMapController:_renderSidebar(parent: Frame, data: any?)
	local destination = if selectedDestination ~= nil
		then MapRender.GetDestination(selectedDestination)
		else nil
	local hostile = if selectedHostile ~= nil then MapRender.GetHostile(selectedHostile) else nil

	local heading = UI.Label("Heading", parent)
	heading.Position = UDim2.fromOffset(12, 10)
	heading.Size = UDim2.new(1, -24, 0, 20)
	heading.Font = UI.Font.Heading
	heading.TextSize = 12
	heading.TextColor3 = UI.Palette.TextMuted
	heading.Text = if hostile ~= nil
		then (if hostile.Kind == "Boss" then "SELECTED BOSS" else "SELECTED HUNTING GROUND")
		elseif destination == nil then (if activeStatFilter ~= nil
			then `{string.upper(activeStatFilter)} TIERS`
			else "ALL TIERS")
		elseif
			destination.GainMultiplier == self:_currentMultiplier(data, destination.StatId)
		then "CURRENT MUSCLE TIER"
		else "SELECTED LOCATION"

	if hostile ~= nil then
		self:_renderHostile(parent, data, hostile)
		return
	end

	if destination == nil then
		self:_renderTierList(parent, data)
		return
	end

	local stat = StatConfig.Get(destination.StatId)
	local equipment = EquipmentConfig.Get(destination.EquipmentId)
	local zone = ZoneConfig.Get(destination.ZoneId)
	if stat == nil or equipment == nil or zone == nil then
		return
	end

	local iconBubble = Instance.new("Frame")
	iconBubble.Name = "StatIcon"
	iconBubble.Position = UDim2.fromOffset(12, 38)
	iconBubble.Size = UDim2.fromOffset(54, 54)
	iconBubble.BackgroundColor3 = stat.Color:Lerp(UI.Palette.CartoonInk, 0.68)
	iconBubble.BorderSizePixel = 0
	iconBubble.Parent = parent
	addCorner(iconBubble, 27)
	addBorder(iconBubble, stat.Color, 0.1, 2)

	local iconPadding = Instance.new("UIPadding")
	iconPadding.PaddingTop = UDim.new(0, 10)
	iconPadding.PaddingBottom = UDim.new(0, 10)
	iconPadding.PaddingLeft = UDim.new(0, 10)
	iconPadding.PaddingRight = UDim.new(0, 10)
	iconPadding.Parent = iconBubble
	Icons.Draw(stat.Icon, iconBubble, stat.Color, UI.Palette.CartoonInk)

	local machine = UI.Label("Machine", parent)
	machine.Position = UDim2.fromOffset(76, 40)
	machine.Size = UDim2.new(1, -88, 0, 24)
	machine.Font = UI.Font.Heading
	machine.TextSize = 15
	machine.TextColor3 = UI.Palette.Text
	machine.TextTruncate = Enum.TextTruncate.AtEnd
	machine.Text = string.upper(equipment.DisplayName)

	local muscle = UI.Label("Muscle", parent)
	muscle.Position = UDim2.fromOffset(76, 66)
	muscle.Size = UDim2.new(1, -88, 0, 18)
	muscle.Font = UI.Font.Heading
	muscle.TextSize = 12
	muscle.TextColor3 = stat.Color
	muscle.Text = `{string.upper(stat.DisplayName)} · ×{NumberFormat.Format(destination.GainMultiplier)}`

	local location = UI.Label("Location", parent)
	location.Position = UDim2.fromOffset(12, 108)
	location.Size = UDim2.new(1, -24, 0, 38)
	location.Font = UI.Font.Heading
	location.TextSize = 13
	location.TextWrapped = true
	location.TextColor3 = UI.Palette.Text
	location.Text = `{destination.LocationName}\n<font color="#8A93A8">{destination.LocationTagline}</font>`

	local perSecond = (equipment.BaseGain / equipment.RepInterval) * destination.GainMultiplier
	local rate = UI.Label("Rate", parent)
	rate.Position = UDim2.fromOffset(12, 158)
	rate.Size = UDim2.new(1, -24, 0, 42)
	rate.Font = UI.Font.Numeric
	rate.TextSize = 18
	rate.TextWrapped = true
	rate.TextColor3 = stat.Color
	rate.Text = `+{NumberFormat.Format(perSecond)}/SEC  EQUIPMENT BONUS`

	local access = if destination.AccessKind == "Sky"
		then `SKY DECK · {math.round(destination.Position.Y)} STUDS`
		elseif destination.FloorIndex > 1 then `FLOOR {destination.FloorIndex} INTERIOR`
		else "STREET LEVEL"
	local accessLabel = UI.Label("Access", parent)
	accessLabel.Position = UDim2.fromOffset(12, 204)
	accessLabel.Size = UDim2.new(1, -24, 0, 18)
	accessLabel.Font = UI.Font.Heading
	accessLabel.TextSize = 11
	accessLabel.TextColor3 = UI.Palette.TextMuted
	accessLabel.Text = access

	local relevantStat = statValue(data, destination.StatId)
	local shortfall = destination.RequiredStat - relevantStat
	local powerLabel = UI.Label("Power", parent)
	powerLabel.Position = UDim2.fromOffset(12, 230)
	powerLabel.Size = UDim2.new(1, -24, 0, 44)
	powerLabel.Font = UI.Font.Heading
	powerLabel.TextSize = 12
	powerLabel.TextWrapped = true
	if shortfall > 0 then
		powerLabel.TextColor3 = UI.Palette.Danger
		powerLabel.Text =
			`{string.upper(stat.DisplayName)} LOCKED\nNEED {NumberFormat.Format(shortfall)} MORE`
	else
		powerLabel.TextColor3 = UI.Palette.Vital
		powerLabel.Text = `{string.upper(stat.DisplayName)} UNLOCKED\n{NumberFormat.Format(
			destination.RequiredStat
		)} REQUIRED`
	end

	local rule = Instance.new("Frame")
	rule.Position = UDim2.fromOffset(12, 286)
	rule.Size = UDim2.new(1, -24, 0, 2)
	rule.BackgroundColor3 = UI.Palette.GlassStroke
	rule.BackgroundTransparency = 0.55
	rule.BorderSizePixel = 0
	rule.Parent = parent

	local actionHint = UI.Label("ActionHint", parent)
	actionHint.Position = UDim2.fromOffset(12, 302)
	actionHint.Size = UDim2.new(1, -24, 0, 34)
	actionHint.TextWrapped = true
	actionHint.TextSize = 11
	actionHint.TextColor3 = UI.Palette.TextMuted
	actionHint.Text = `Track is free. Teleport needs Fast Travel and enough {stat.DisplayName}.`

	local trackLabel, trackColor = destinationLabel(destination)
	local tracking = self:_isTracking(destination.Position)
	self:_sideButton(
		parent,
		"Track",
		if tracking then "UNTRACK" else "TRACK",
		UDim2.new(0, 10, 1, -108),
		if tracking then UI.Palette.Glass else stat.Color,
		true,
		function()
			if tracking then
				self:_untrack(trackLabel)
			else
				self:_track(destination.Position, trackLabel, trackColor)
			end
		end
	)

	if not hasFastTravel then
		self:_sideButton(
			parent,
			"TeleportLocked",
			"LOCKED · GET FAST TRAVEL",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			true,
			function()
				self:_promptFastTravel()
			end
		)
	else
		self:_sideButton(
			parent,
			"Teleport",
			if shortfall > 0 then "LOCKED · NEED MORE POWER" else "TELEPORT",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			shortfall <= 0,
			function()
				self:_teleport(destination.Id)
			end
		)
	end
end

function FullMapController:_render()
	if not isOpen then
		return
	end

	self:_fetchMap()
	local data = ProfileController:Get()
	if selectedDestination ~= nil and MapRender.GetDestination(selectedDestination) == nil then
		selectedDestination = nil
	end
	local selected = if selectedDestination ~= nil then MapRender.GetDestination(selectedDestination) else nil
	if selected ~= nil and activeStatFilter ~= nil and selected.StatId ~= activeStatFilter then
		selectedDestination = nil
	end
	-- A muscle filter hides the monsters, so it must also drop a monster selection:
	-- otherwise the sidebar describes a site with no pin anywhere on the board.
	if
		selectedHostile ~= nil and (activeStatFilter ~= nil or MapRender.GetHostile(selectedHostile) == nil)
	then
		selectedHostile = nil
	end

	local visibleDestinations: { Destination } = {}
	for _, destination in destinations do
		if activeStatFilter == nil or destination.StatId == activeStatFilter then
			table.insert(visibleDestinations, destination)
		end
	end

	-- The tier list is rebuilt from scratch on every render, and the profile replicates
	-- on every training rep, so without this the list a player was reading snapped back
	-- to the top a few times a second while their set ran.
	local previousTierList = content:FindFirstChild("TierList", true)
	local tierScroll: Vector2? = if previousTierList ~= nil and previousTierList:IsA("ScrollingFrame")
		then previousTierList.CanvasPosition
		else nil

	renderGeneration += 1
	local generation = renderGeneration
	lastRenderedSignature = profileSignature()
	content:ClearAllChildren()

	local board = Instance.new("Frame")
	board.Name = "MapBoard"
	board.ZIndex = 1
	board.Size = UDim2.new(1, -SIDEBAR_WIDTH - CONTENT_GAP, 1, 0)
	board.BackgroundColor3 = UI.Palette.Backdrop
	board.BorderSizePixel = 0
	board.ClipsDescendants = true
	board.Parent = content
	addCorner(board, 10)
	addBorder(board, UI.Palette.GlassStroke, 0.45, 2)

	local sidebar = UI.Panel("Destination", content)
	sidebar.ZIndex = 2
	sidebar.AnchorPoint = Vector2.new(1, 0)
	sidebar.Position = UDim2.fromScale(1, 0)
	sidebar.Size = UDim2.new(0, SIDEBAR_WIDTH, 1, 0)
	sidebar.BackgroundTransparency = 0.02
	self:_renderSidebar(sidebar, data)

	if tierScroll ~= nil then
		-- AutomaticCanvasSize has not measured the new rows yet, and a write against a
		-- canvas of zero height is clamped to the top — which is the jump being undone.
		task.spawn(function()
			RunService.Heartbeat:Wait()
			local list = if isOpen and renderGeneration == generation
				then content:FindFirstChild("TierList", true)
				else nil
			if list ~= nil and list:IsA("ScrollingFrame") then
				list.CanvasPosition = tierScroll :: Vector2
			end
		end)
	end

	if #destinations == 0 then
		local loading = UI.Label("Loading", board)
		loading.Size = UDim2.fromScale(1, 1)
		loading.TextXAlignment = Enum.TextXAlignment.Center
		loading.TextColor3 = UI.Palette.TextMuted
		loading.Text = "MAPPING THE CITY…"
		return
	end

	local bounds = MapRender.Bounds(mapFeatures, destinations, MAP_ASPECT)
	local project = MapRender.Project(bounds)

	-- ScrollingFrame provides Roblox's native rectangular canvas scissor without owning
	-- scrolling. We still handle drag/wheel explicitly, but this stronger clip prevents
	-- rotated building Frames from escaping the map at high zoom.
	local viewport = Instance.new("ScrollingFrame")
	viewport.Name = "Viewport"
	viewport.Active = true
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundColor3 = UI.Palette.Backdrop
	viewport.BorderSizePixel = 0
	viewport.ClipsDescendants = true
	viewport.ScrollingEnabled = false
	viewport.ScrollBarThickness = 0
	viewport.AutomaticCanvasSize = Enum.AutomaticSize.None
	viewport.CanvasSize = UDim2.fromOffset(0, 0)
	viewport.ElasticBehavior = Enum.ElasticBehavior.Never
	viewport.ZIndex = 1
	viewport.Parent = board

	local canvas = Instance.new("Frame")
	canvas.Name = "MapCanvas"
	canvas.Size = UDim2.fromScale(mapZoom, mapZoom)
	canvas.BackgroundColor3 = MAP_PAPER
	canvas.BorderSizePixel = 0
	canvas:SetAttribute("Zoom", mapZoom)
	canvas.Parent = viewport

	-- Roblox does not reliably apply an ancestor's clipping rectangle to deeply nested
	-- rotated GuiObjects. Keep every moving feature and pin as a *direct* child of the
	-- native viewport, and reproduce the canvas transform explicitly.
	local mapItems: { [GuiObject]: MapItemLayout } = {}
	local function registerMapItem(object: GuiObject)
		mapItems[object] = {
			Position = object.Position,
			Size = object.Size,
		}
		-- Do not allow a one-frame flash outside the board while AbsoluteSize is still
		-- zero. The deferred first layout decides visibility from tested geometry.
		object.Visible = false
	end
	local function setMapItemSize(object: GuiObject, size: UDim2)
		local layout = mapItems[object]
		if layout ~= nil then
			layout.Size = size
		end
	end

	-- Declared here because selecting a pin has to re-run the layout, and that happens
	-- in a handler written long before the viewport maths below exists.
	local layoutMapItems: () -> ()

	local featureSource = Instance.new("Frame")
	featureSource.Name = "FeatureSource"
	featureSource.Size = UDim2.fromScale(1, 1)
	featureSource.BackgroundTransparency = 1
	MapRender.DrawFeatures(featureSource, mapFeatures, bounds)
	for _, child in featureSource:GetChildren() do
		if child:IsA("GuiObject") then
			registerMapItem(child)
			child.Parent = viewport
		end
	end
	featureSource:Destroy()

	-- The full map is deliberately moodier than the minimap. This quiet overlay keeps
	-- the complete street/building context visible without letting it compete with the
	-- the current Power tier drawn above it.
	local mapShade = Instance.new("Frame")
	mapShade.Name = "MapShade"
	mapShade.Size = UDim2.fromScale(1, 1)
	mapShade.BackgroundColor3 = UI.Palette.Backdrop
	mapShade.BackgroundTransparency = 0.18
	mapShade.BorderSizePixel = 0
	mapShade.ZIndex = 10
	mapShade.Parent = viewport
	mapShade.Position = canvas.Position
	mapShade.Size = canvas.Size

	-- Muscle tabs filter destinations, not geography. "ALL" restores the ordinary map;
	-- every filtered view still shows the same roads, buildings and the player's marker.
	local filterBar = Instance.new("Frame")
	filterBar.Name = "MuscleFilters"
	filterBar.Position = UDim2.fromOffset(12, 12)
	filterBar.Size = UDim2.new(1, -24, 0, 40)
	filterBar.BackgroundColor3 = UI.Palette.Backdrop
	filterBar.BackgroundTransparency = 0.05
	filterBar.BorderSizePixel = 0
	filterBar.ZIndex = 70
	filterBar.Parent = board
	addCorner(filterBar, 8)
	addBorder(filterBar, UI.Palette.GlassStroke, 0.4, 1)

	local filterGrid = Instance.new("UIGridLayout")
	filterGrid.CellSize = UDim2.new(1 / (#StatConfig.List + 1), -6, 1, -8)
	filterGrid.CellPadding = UDim2.fromOffset(5, 0)
	filterGrid.FillDirection = Enum.FillDirection.Horizontal
	filterGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	filterGrid.VerticalAlignment = Enum.VerticalAlignment.Center
	filterGrid.SortOrder = Enum.SortOrder.LayoutOrder
	filterGrid.Parent = filterBar

	local filterSpecs: { { Id: string?, Name: string, Color: Color3 } } = {
		{ Id = nil, Name = "ALL", Color = UI.Palette.Accent },
	}
	for _, definition in StatConfig.List do
		table.insert(filterSpecs, {
			Id = definition.Id,
			Name = string.upper(definition.DisplayName),
			Color = definition.Color,
		})
	end
	for order, spec in filterSpecs do
		local chosen = activeStatFilter == spec.Id
		local button = Instance.new("TextButton")
		button.Name = spec.Name
		button.LayoutOrder = order
		button.BackgroundColor3 = if chosen then spec.Color else UI.Palette.Glass
		button.BackgroundTransparency = if chosen then 0.08 else 0.24
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Font = UI.Font.Heading
		button.TextSize = 10
		button.TextColor3 = if chosen then UI.Palette.OnAccent else UI.Palette.TextMuted
		button.Text = spec.Name
		button.ZIndex = 71
		button.Parent = filterBar
		addCorner(button, 6)
		UI.Pressable(button, { PressScale = 0.96, HoverScale = 1.02 })
		button.Activated:Connect(function()
			if activeStatFilter == spec.Id then
				return
			end
			activeStatFilter = spec.Id
			selectedDestination = nil
			self:_render()
		end)
	end

	local hub = UI.Label("Hub", viewport)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(72, 18)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.Font = UI.Font.Heading
	hub.TextSize = 10
	hub.TextColor3 = UI.Palette.Token
	hub.Text = "◆ SPAWN"
	hub.ZIndex = 24
	registerMapItem(hub)

	local unlockedCount = 0
	local pinRecords: { [string]: { Button: TextButton, Stroke: UIStroke } } = {}

	-- Greedy grouping by actual proximity. A destination joins the first group
	-- whose anchor it would overlap, otherwise it starts its own -- which is the
	-- common case now, and means the pin keeps its exact position.
	local threshold = overlapDistance(bounds)
	local clusterMembers: { { Destination } } = {}
	for _, destination in visibleDestinations do
		local placed = false
		for _, members in clusterMembers do
			local anchor = members[1].Position
			local dx = destination.Position.X - anchor.X
			local dz = destination.Position.Z - anchor.Z
			if math.sqrt(dx * dx + dz * dz) <= threshold then
				table.insert(members, destination)
				placed = true
				break
			end
		end
		if not placed then
			table.insert(clusterMembers, { destination })
		end
	end

	local pinPositions: { [string]: UDim2 } = {}
	for _, members in clusterMembers do
		table.sort(members, function(a, b)
			local aOrder = statOrder(a.StatId)
			local bOrder = statOrder(b.StatId)
			if aOrder ~= bOrder then
				return aOrder < bOrder
			end
			if a.GainMultiplier ~= b.GainMultiplier then
				return a.GainMultiplier < b.GainMultiplier
			end
			return a.Id < b.Id
		end)

		-- A pin on its own is drawn exactly where its machine is. Only pins that
		-- would sit on top of each other are nudged apart, and then around their
		-- shared centre -- which is honest, because they really are in the same
		-- place at this scale.
		if #members == 1 then
			local at = members[1].Position
			pinPositions[members[1].Id] = project(at.X, at.Z)
			continue
		end

		local sum = Vector3.zero
		for _, destination in members do
			sum += destination.Position
		end
		local centre = sum / #members
		local projectedCentre = project(centre.X, centre.Z)
		local radius = 18 + #members * 2.6
		for index, destination in members do
			local angle = math.rad(-90 + (index - 1) * 360 / #members)
			local offset = Vector2.new(math.cos(angle), math.sin(angle)) * radius
			pinPositions[destination.Id] = UDim2.new(
				projectedCentre.X.Scale,
				projectedCentre.X.Offset + offset.X,
				projectedCentre.Y.Scale,
				projectedCentre.Y.Offset + offset.Y
			)
		end
	end

	for _, destination in visibleDestinations do
		local stat = StatConfig.Get(destination.StatId)
		if stat == nil then
			continue
		end
		local unlocked = destinationUnlocked(data, destination)
		if unlocked then
			unlockedCount += 1
		end
		local isSelected = selectedDestination == destination.Id
		local currentTier = destination.GainMultiplier == self:_currentMultiplier(data, destination.StatId)
		local pin = Instance.new("TextButton")
		pin.Name = destination.Id
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = pinPositions[destination.Id]
		pin.Size = UDim2.fromOffset(
			if isSelected then SELECTED_PIN_SIZE else PIN_SIZE,
			if isSelected then SELECTED_PIN_SIZE else PIN_SIZE
		)
		pin.BackgroundColor3 = if currentTier
			then stat.Color
			elseif unlocked then stat.Color:Lerp(UI.Palette.Glass, 0.48)
			else stat.Color:Lerp(UI.Palette.Glass, 0.72)
		pin.BorderSizePixel = 0
		pin.AutoButtonColor = false
		pin.Font = UI.Font.Heading
		pin.TextScaled = true
		pin.TextWrapped = true
		pin.LineHeight = 0.82
		pin.TextColor3 = if currentTier then MAP_PAPER else UI.Palette.TextMuted
		pin.Text = `{string.sub(string.upper(stat.DisplayName), 1, 2)}\n×{NumberFormat.Format(
			destination.GainMultiplier
		)}`
		pin.ZIndex = if isSelected then 25 else 22
		pin.Parent = viewport
		registerMapItem(pin)
		addCorner(pin, 20)
		local textLimit = Instance.new("UITextSizeConstraint")
		textLimit.MinTextSize = 6
		textLimit.MaxTextSize = 10
		textLimit.Parent = pin
		local pinStroke =
			addBorder(pin, if isSelected then MAP_PAPER else MAP_INK, 0, if isSelected then 2 else 1)
		pinRecords[destination.Id] = { Button = pin, Stroke = pinStroke }
		UI.Pressable(pin, { PressScale = 0.9, HoverScale = 1.12 })
		pin.Activated:Connect(function()
			selectedDestination = destination.Id
			for id, record in pinRecords do
				local nowSelected = id == selectedDestination
				local size = UDim2.fromOffset(
					if nowSelected then SELECTED_PIN_SIZE else PIN_SIZE,
					if nowSelected then SELECTED_PIN_SIZE else PIN_SIZE
				)
				setMapItemSize(record.Button, size)
				record.Button.Size = size
				record.Button.ZIndex = if nowSelected then 25 else 22
				record.Stroke.Color = if nowSelected then MAP_PAPER else MAP_INK
				record.Stroke.Thickness = if nowSelected then 2 else 1
			end
			-- The selected pin grew, so its containment has to be decided again: without
			-- this it keeps the position and the visibility it was given at 26 px while
			-- drawing at 30.
			layoutMapItems()
			-- Redraw only the small detail card. Recreating thousands of map-feature
			-- Frames for every pin click made destination selection needlessly heavy.
			for _, child in sidebar:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			self:_renderSidebar(sidebar, data)
		end)
	end

	-- Monster sites, on the circles the feature layer already draws for them. Same pin
	-- machinery as a machine, deliberately: this is a place you can decide to go to, and
	-- the map should not make you learn a second way to say so. Smaller and below the
	-- machine pins, just as deliberately, so it stays the secondary reading.
	if activeStatFilter == nil then
		local playerPower = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
		for _, hostile in hostiles do
			local site = MapRender.SiteIcon(hostile.Kind)
			local accent = if hostile.Kind == "Boss" then UI.Palette.Danger else site.Color
			local selectedSite = selectedHostile == hostile.Id
			local unlocked = playerPower >= hostile.RequiredPower
			local size = if selectedSite then SELECTED_HOSTILE_PIN_SIZE else HOSTILE_PIN_SIZE

			local pin = Instance.new("TextButton")
			pin.Name = hostile.Id
			pin.AnchorPoint = Vector2.new(0.5, 0.5)
			pin.Position = project(hostile.Position.X, hostile.Position.Z)
			pin.Size = UDim2.fromOffset(size, size)
			pin.BackgroundColor3 = if unlocked then accent else accent:Lerp(UI.Palette.Glass, 0.6)
			pin.BorderSizePixel = 0
			pin.AutoButtonColor = false
			pin.Text = ""
			pin.ZIndex = if selectedSite then 21 else 20
			pin.Parent = viewport
			registerMapItem(pin)
			addCorner(pin, 20)
			addBorder(pin, if selectedSite then MAP_PAPER else MAP_INK, 0, if selectedSite then 2 else 1)

			local glyph = Instance.new("Frame")
			glyph.Name = "Glyph"
			glyph.Size = UDim2.fromScale(0.74, 0.74)
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.5, 0.5)
			glyph.BackgroundTransparency = 1
			glyph.ZIndex = pin.ZIndex + 1
			glyph.Parent = pin
			Icons.Draw(site.Icon, glyph, MAP_PAPER, UI.Palette.CartoonInk)

			UI.Pressable(pin, { PressScale = 0.9, HoverScale = 1.12 })
			pin.Activated:Connect(function()
				selectedHostile = hostile.Id
				selectedDestination = nil
				self:_render()
			end)
		end
	end

	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local here = MapRender.Dot(viewport, "You", 12, UI.Palette.Text, 28)
		here.Position = project(root.Position.X, root.Position.Z)
		addBorder(here, MAP_INK, 0, 2)
		registerMapItem(here)
	end

	local function theoreticalCanvasSize(): Vector2
		return viewport.AbsoluteSize * mapZoom
	end

	--[[
		How much room, in pixels, the fixed-size items need at the edges of the map.

		Measured rather than assumed. A pin is 26 px, but a clustered pin also carries a
		fan-out offset of up to about 40, and the spawn label is 72 wide — a constant
		guess that covers a lone pin hides the ones that need it most, which is what a
		flat inset did. Only items sized purely in pixels are counted: geography is
		scale-sized and is meant to run to the edges of the paper, and folding a
		building's half-width into this would shrink the city to a stamp.
	]]
	local function itemMargins(): Vector2
		local margin = Vector2.zero
		for object, layout in mapItems do
			if object.Parent == nil or layout.Size.X.Scale ~= 0 or layout.Size.Y.Scale ~= 0 then
				continue
			end
			local halfX, halfY = MapViewportMath.RotatedHalfExtents(
				layout.Size.X.Offset,
				layout.Size.Y.Offset,
				object.Rotation
			)
			margin = Vector2.new(
				math.max(margin.X, halfX + math.abs(layout.Position.X.Offset)),
				math.max(margin.Y, halfY + math.abs(layout.Position.Y.Offset))
			)
		end
		return margin + Vector2.new(MAP_EDGE_PADDING, MAP_EDGE_PADDING)
	end

	function layoutMapItems()
		local canvasSize = theoreticalCanvasSize()
		local viewportSize = viewport.AbsoluteSize
		local offset = Vector2.new(canvas.Position.X.Offset, canvas.Position.Y.Offset)
		-- The drawing rect, not the canvas rect: everything scale-positioned maps into
		-- the inset area so no pin can land under an edge or under the board's chrome.
		-- The inset grows with zoom because it is part of the map, not part of the
		-- window — insetting in window pixels would slide the map under the cursor as
		-- you zoomed. Position and size share the rect; insetting one and not the other
		-- would walk the pins off their buildings.
		local margin = itemMargins()
		local topLeft = Vector2.new(margin.X, margin.Y + MAP_TOP_CHROME) * mapZoom
		local bottomRight = Vector2.new(margin.X, margin.Y + MAP_BOTTOM_CHROME) * mapZoom
		local usable = Vector2.new(
			math.max(canvasSize.X - topLeft.X - bottomRight.X, 1),
			math.max(canvasSize.Y - topLeft.Y - bottomRight.Y, 1)
		)
		local origin = offset + topLeft
		for object, layout in mapItems do
			if object.Parent == nil then
				mapItems[object] = nil
				continue
			end
			local centerX = origin.X + layout.Position.X.Scale * usable.X + layout.Position.X.Offset
			local centerY = origin.Y + layout.Position.Y.Scale * usable.Y + layout.Position.Y.Offset
			local width = layout.Size.X.Scale * usable.X + layout.Size.X.Offset
			local height = layout.Size.Y.Scale * usable.Y + layout.Size.Y.Offset
			object.Position = UDim2.fromOffset(centerX, centerY)
			object.Size = UDim2.fromOffset(width, height)
			-- This software containment is deliberately stricter than clipping: a rotated
			-- feature disappears before any part can cross an edge. It is deterministic on
			-- every renderer and removes the legacy rotated-ClipsDescendants dependency.
			object.Visible = MapViewportMath.Fits(
				centerX,
				centerY,
				width,
				height,
				object.Rotation,
				viewportSize.X,
				viewportSize.Y,
				1
			)
		end
	end

	local function setCanvasOffset(rawOffset: Vector2)
		local windowSize = viewport.AbsoluteSize
		local canvasSize = theoreticalCanvasSize()
		if windowSize.X <= 0 or windowSize.Y <= 0 then
			return
		end
		local overflow =
			Vector2.new(math.max(canvasSize.X - windowSize.X, 0), math.max(canvasSize.Y - windowSize.Y, 0))
		local slack = windowSize * PAN_SLACK
		local offset = Vector2.new(
			math.clamp(rawOffset.X, -overflow.X - slack.X, slack.X),
			math.clamp(rawOffset.Y, -overflow.Y - slack.Y, slack.Y)
		)
		canvas.Position = UDim2.fromOffset(offset.X, offset.Y)
		mapShade.Position = canvas.Position
		mapShade.Size = canvas.Size
		layoutMapItems()
		-- Deliberately unclamped: a view dragged into the slack is outside 0..1, and
		-- clamping here would silently snap the map back the next time anything fed
		-- this centre through applyCenter. The real limits are enforced above, which is
		-- where applyCenter's result lands anyway.
		mapCenter = Vector2.new(
			(windowSize.X / 2 - offset.X) / canvasSize.X,
			(windowSize.Y / 2 - offset.Y) / canvasSize.Y
		)
		canvas:SetAttribute("CenterX", mapCenter.X)
		canvas:SetAttribute("CenterY", mapCenter.Y)
	end

	local function applyCenter()
		local windowSize = viewport.AbsoluteSize
		local canvasSize = theoreticalCanvasSize()
		setCanvasOffset(
			Vector2.new(
				windowSize.X / 2 - mapCenter.X * canvasSize.X,
				windowSize.Y / 2 - mapCenter.Y * canvasSize.Y
			)
		)
	end

	local function zoomAt(targetZoom: number, localFocus: Vector2?)
		targetZoom = math.clamp(targetZoom, MIN_ZOOM, MAX_ZOOM)
		if math.abs(targetZoom - mapZoom) < 0.001 then
			return
		end
		local windowSize = viewport.AbsoluteSize
		local oldSize = theoreticalCanvasSize()
		local oldOffset = Vector2.new(canvas.Position.X.Offset, canvas.Position.Y.Offset)
		local focus = localFocus or windowSize / 2
		local normalizedFocus = Vector2.new(
			math.clamp((focus.X - oldOffset.X) / oldSize.X, 0, 1),
			math.clamp((focus.Y - oldOffset.Y) / oldSize.Y, 0, 1)
		)

		mapZoom = targetZoom
		canvas.Size = UDim2.fromScale(mapZoom, mapZoom)
		canvas:SetAttribute("Zoom", mapZoom)
		local newSize = windowSize * mapZoom
		setCanvasOffset(focus - Vector2.new(normalizedFocus.X * newSize.X, normalizedFocus.Y * newSize.Y))
	end

	-- Explicit drag ownership replaces native ScrollingFrame behaviour. No wheel event
	-- can leak into a parent page because there is no parent page to scroll.
	local draggingMouse = false
	local draggingTouch: InputObject? = nil
	local dragStart = Vector2.zero
	local offsetStart = Vector2.zero
	viewport.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		draggingMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		draggingTouch = if input.UserInputType == Enum.UserInputType.Touch then input else nil
		dragStart = Vector2.new(input.Position.X, input.Position.Y)
		offsetStart = Vector2.new(canvas.Position.X.Offset, canvas.Position.Y.Offset)
	end)

	local moveConnection = UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel and input.Position.Z ~= 0 then
			local mouse = UserInputService:GetMouseLocation()
			local topLeft = viewport.AbsolutePosition
			local size = viewport.AbsoluteSize
			if
				mouse.X >= topLeft.X
				and mouse.Y >= topLeft.Y
				and mouse.X <= topLeft.X + size.X
				and mouse.Y <= topLeft.Y + size.Y
			then
				local focus = mouse - topLeft
				-- Roblox reports wheel-up as positive Z. Up zooms in; down zooms out.
				zoomAt(mapZoom * (if input.Position.Z > 0 then ZOOM_STEP else 1 / ZOOM_STEP), focus)
			end
			return
		end

		local movingMouse = draggingMouse and input.UserInputType == Enum.UserInputType.MouseMovement
		local movingTouch = draggingTouch ~= nil and input == draggingTouch
		if not movingMouse and not movingTouch then
			return
		end
		local current = Vector2.new(input.Position.X, input.Position.Y)
		setCanvasOffset(offsetStart + (current - dragStart))
	end)

	local endConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			draggingMouse = false
		elseif draggingTouch ~= nil and input == draggingTouch then
			draggingTouch = nil
		end
	end)
	viewport.Destroying:Connect(function()
		moveConnection:Disconnect()
		endConnection:Disconnect()
	end)

	--[[
		The zoom controls, along the bottom edge.

		They used to sit at the top right, which is where the muscle filter bar was
		later put: that bar spans the board's whole width and draws above them, so all
		three buttons have been buried underneath it and unclickable. Down here they are
		opposite the status pill and cannot collide with anything.

		The glyphs are drawn rather than typed for the reason the close button is —
		minus was U+2212, which Gotham does not have, and it had been a box for as long
		as it was hidden.
	]]
	local function mapControl(name: string, icon: string, right: number, onClick: () -> ())
		local control = Instance.new("TextButton")
		control.Name = name
		control.AnchorPoint = Vector2.new(1, 1)
		control.Position = UDim2.new(1, -right, 1, -10)
		control.Size = UDim2.fromOffset(38, 38)
		control.BackgroundColor3 = UI.Palette.Glass
		control.BackgroundTransparency = 0.03
		control.BorderSizePixel = 0
		control.AutoButtonColor = false
		control.Text = ""
		control.ZIndex = 60
		control.Parent = board
		addCorner(control, 7)
		addBorder(control, UI.Palette.GlassStroke, 0.35, 2)

		local glyph = Instance.new("Frame")
		glyph.Name = "Glyph"
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
		glyph.Size = UDim2.fromScale(0.5, 0.5)
		glyph.BackgroundTransparency = 1
		glyph.ZIndex = 61
		glyph.Parent = control

		-- The button's own fill is the hole colour, so Recenter's knockout reads as a
		-- window rather than as a smear of whatever the palette's tile colour is.
		Icons.Draw(icon, glyph, UI.Palette.Text, UI.Palette.Glass)

		UI.Pressable(control)
		control.Activated:Connect(onClick)
	end

	mapControl("ZoomIn", "Plus", 10, function()
		zoomAt(mapZoom * ZOOM_STEP)
	end)
	mapControl("ZoomOut", "Minus", 54, function()
		zoomAt(mapZoom / ZOOM_STEP)
	end)
	mapControl("Reset", "Recenter", 98, function()
		mapZoom = 1
		mapCenter = Vector2.new(0.5, 0.5)
		canvas.Size = UDim2.fromScale(1, 1)
		canvas:SetAttribute("Zoom", mapZoom)
		applyCenter()
	end)

	local legend = Instance.new("Frame")
	legend.Name = "Legend"
	-- Below the muscle filter bar, which spans the board's full width across y 12..52
	-- and was drawing straight over this.
	legend.Position = UDim2.fromOffset(10, 60)
	legend.Size = UDim2.fromOffset(326, 38)
	legend.BackgroundColor3 = UI.Palette.Glass
	legend.BackgroundTransparency = 0.03
	legend.BorderSizePixel = 0
	legend.ZIndex = 60
	-- This is navigation chrome, not map geography. It must remain readable while the
	-- sheet beneath it pans and zooms.
	legend.Parent = board
	addCorner(legend, 7)
	addBorder(legend, UI.Palette.GlassStroke, 0.5, 1)
	local legendLayout = Instance.new("UIListLayout")
	legendLayout.FillDirection = Enum.FillDirection.Horizontal
	legendLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	legendLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	legendLayout.Padding = UDim.new(0, 4)
	legendLayout.Parent = legend
	for _, definition in StatConfig.List do
		local key = Instance.new("Frame")
		key.Name = definition.Id
		key.Size = UDim2.fromOffset(59, 24)
		key.BackgroundTransparency = 1
		key.ZIndex = 61
		key.Parent = legend

		-- A real circle rather than the U+25CF this used to print. The map's own
		-- destinations are coloured discs, so the key should be one too, and a
		-- geometric-shape character is the same bet that lost on the close button.
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.fromScale(0, 0.5)
		dot.Size = UDim2.fromOffset(8, 8)
		dot.BackgroundColor3 = definition.Color
		dot.BorderSizePixel = 0
		dot.ZIndex = 62
		dot.Parent = key

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local label = UI.Label("Name", key)
		label.Position = UDim2.fromOffset(12, 0)
		label.Size = UDim2.new(1, -12, 1, 0)
		label.Font = UI.Font.Heading
		label.TextSize = 9
		label.TextColor3 = definition.Color
		label.Text = string.upper(definition.DisplayName)
		label.ZIndex = 62
	end

	local status = UI.Label("Status", board)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 10, 1, -10)
	status.Size = UDim2.fromOffset(390, 28)
	status.BackgroundColor3 = UI.Palette.Glass
	status.BackgroundTransparency = 0.03
	status.Font = UI.Font.Heading
	status.TextSize = 10
	status.TextColor3 = UI.Palette.Text
	status.TextXAlignment = Enum.TextXAlignment.Center
	local filterName = if activeStatFilter ~= nil then string.upper(activeStatFilter) else "ALL MUSCLES"
	status.Text = `{unlockedCount}/{#visibleDestinations} OPEN  ·  {filterName}  ·  TRACK FREE`
	status.ZIndex = 60
	addCorner(status, 7)
	addBorder(status, UI.Palette.GlassStroke, 0.5, 1)

	-- Every map item is registered Visible = false and only turned on by a layout pass,
	-- and a layout pass gives up while the viewport still measures zero. That left the
	-- whole map on one deferred call landing after the panel had been measured — win the
	-- race and you get a map, lose it and you get an empty board until you happen to
	-- drag. Watching the size instead means the map lays out the moment there is
	-- something to lay it out in, and re-frames whenever the window changes size.
	local sizeConnection = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		applyCenter()
	end)
	viewport.Destroying:Connect(function()
		sizeConnection:Disconnect()
	end)

	task.defer(function()
		if viewport.Parent ~= nil then
			applyCenter()
		end
	end)
end

function FullMapController:_build()
	local playerGui = player:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymFullMap"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 6
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = playerGui

	--[[
		This screen sizes itself, rather than taking UI.ScaleWithViewport.

		That helper applies UI.LayoutScale — viewport *height* over 720, clamped to
		[0.85, 1.25]. Every other screen can live with it because it is smaller than the
		window in both directions at any scale it will meet. This panel is 980 wide, and
		the 0.85 floor still puts it at 833 — so on a window with less width than that,
		the panel is scaled larger than the space it has and its own ClipsDescendants
		crops the board. Since the map's zoom floor is "the whole city", nothing the
		player can do brings back the part that was cut away.

		So: the same scale as every other screen, but never larger than the window can
		hold. A small window gets a small map, which is legible where a cropped one is
		not. Letting it grow *past* UI.LayoutScale was tried and is not wanted — the map
		is a page laid over the world, and a page that fills the screen stops reading as
		one.
	]]
	local panelScale = Instance.new("UIScale")
	panelScale.Parent = screen

	local function applyPanelScale()
		local available = screen.AbsoluteSize
		if available.X <= 0 or available.Y <= 0 then
			return
		end
		panelScale.Scale = math.min(
			UI.LayoutScale(available.Y),
			(available.X - PANEL_MARGIN * 2) / PANEL_SIZE.X,
			(available.Y - PANEL_MARGIN * 2) / PANEL_SIZE.Y
		)
	end

	applyPanelScale()
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyPanelScale)

	-- The scrim is deliberately visual-only. A full-screen TextButton used to treat
	-- the mouse-up at the end of some map drags as an activation and close the page.
	-- Closing is now explicit: the X button, Escape, or M.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = UI.Palette.CartoonInk
	scrim.BackgroundTransparency = 0.42
	scrim.BorderSizePixel = 0
	scrim.Active = true
	scrim.ZIndex = 1
	scrim.Parent = screen

	local panel = UI.Panel("FullMap", screen)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y)
	panel.BackgroundTransparency = 0.01
	panel.ClipsDescendants = true
	panel.ZIndex = 2
	-- Sink clicks inside the panel so they cannot reach the 3D world behind the map.
	panel.Active = true
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = PANEL_SIZE.X / PANEL_SIZE.Y
	aspect.Parent = panel

	local title = UI.Label("Title", panel)
	title.Position = UDim2.fromOffset(4, 0)
	title.Size = UDim2.new(1, -180, 0, HEADER_HEIGHT)
	title.Font = UI.Font.Heading
	title.TextSize = 20
	title.TextColor3 = UI.Palette.Text
	title.Text = "CITY TRAINING MAP"
	title.ZIndex = 5

	local subtitle = UI.Label("Subtitle", panel)
	subtitle.AnchorPoint = Vector2.new(1, 0)
	subtitle.Position = UDim2.new(1, -48, 0, 0)
	subtitle.Size = UDim2.fromOffset(310, HEADER_HEIGHT)
	subtitle.Font = UI.Font.Heading
	subtitle.TextSize = 10
	subtitle.TextXAlignment = Enum.TextXAlignment.Right
	subtitle.TextColor3 = UI.Palette.TextMuted
	subtitle.Text = "SELECT A CIRCLE · TRACK FREE · TELEPORT WITH PASS"
	subtitle.ZIndex = 5

	local close = Icons.CloseButton(panel, {
		Size = 38,
		OnActivated = function()
			self:Close()
		end,
	})
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, 0, 0, HEADER_HEIGHT / 2)
	close.ZIndex = 6

	content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
	content.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
	content.BackgroundTransparency = 1
	content.ZIndex = 2
	content.Parent = panel
end

function FullMapController:IsOpen(): boolean
	return isOpen
end

function FullMapController:Open(destinationId: string?, statFilter: string?)
	local MenuController = Loader.Get("MenuController")
	if MenuController:GetOpenTab() ~= nil then
		MenuController:Toggle()
	end

	self:_fetchMap()
	activeStatFilter = if statFilter ~= nil and StatConfig.Get(statFilter) ~= nil then statFilter else nil
	selectedDestination = if destinationId ~= nil and MapRender.GetDestination(destinationId) ~= nil
		then destinationId
		else nil
	selectedHostile = if selectedDestination == nil
			and destinationId ~= nil
			and MapRender.GetHostile(destinationId) ~= nil
		then destinationId
		else nil

	-- Always open framed on the whole city.
	--
	-- `mapZoom` and `mapCenter` live at module scope so a drag survives a re-render,
	-- which is right while the map is up and wrong the moment it closes: the next open
	-- restored whatever corner you happened to leave it in, so the map appeared to show
	-- a random place. Measured at 4x zoom that is 6 of 35 destinations on screen, with
	-- no cue that the other 29 exist off the edge.
	--
	-- Opening is the one moment the map is being asked "where is everything", so it
	-- answers that. The home control still re-frames mid-session.
	mapZoom = 1
	mapCenter = Vector2.new(0.5, 0.5)

	isOpen = true
	screen.Enabled = true
	self:_fetchTravelAccess()
	self:_render()
	FullMapController.Changed:Fire(true)
end

-- Opens the best currently unlocked destination for one muscle. Kept as a small
-- routing API so any future stat-card shortcut still lands on this dedicated surface.
function FullMapController:OpenForStat(statId: string)
	self:_fetchMap()
	local data = ProfileController:Get()
	local chosen: Destination? = nil
	for _, destination in destinations do
		if
			destination.StatId == statId
			and destinationUnlocked(data, destination)
			and (chosen == nil or destination.GainMultiplier > chosen.GainMultiplier)
		then
			chosen = destination
		end
	end
	self:Open(if chosen ~= nil then chosen.Id else nil, statId)
end

function FullMapController:Close()
	if not isOpen then
		return
	end
	isOpen = false
	screen.Enabled = false
	FullMapController.Changed:Fire(false)
end

function FullMapController:Toggle()
	if isOpen then
		self:Close()
	else
		self:Open()
	end
end

function FullMapController:Start()
	self:_build()

	-- MobService has been broadcasting this since bosses existed and nothing listened,
	-- so the respawn timer the server keeps was invisible in game. The map is where a
	-- player decides which fight to walk to, which makes it the right consumer.
	Net.Event("BossStateChanged").OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		table.clear(bossState)
		for zoneId, entry in state do
			if type(zoneId) == "string" and type(entry) == "table" then
				bossState[zoneId] = {
					Alive = entry.Alive == true,
					SecondsUntil = if type(entry.SecondsUntil) == "number" then entry.SecondsUntil else 0,
				}
			end
		end
		bossStateAt = os.clock()
		if isOpen then
			self:_render()
		end
	end)

	-- Training marks the profile dirty on every rep, and this panel rebuilds itself
	-- whole. Coalesce so a running set costs one redraw per interval instead of one per
	-- replicated frame, then drop the redraw entirely unless something the map actually
	-- draws has moved. A stat ticking up changes nothing here until it crosses a
	-- threshold, so an open map normally sits perfectly still through a whole set.
	local profileRenderPending = false
	ProfileController.Changed:Connect(function()
		if not isOpen or profileRenderPending then
			return
		end
		if profileSignature() == lastRenderedSignature then
			return
		end
		profileRenderPending = true
		task.delay(PROFILE_RENDER_INTERVAL, function()
			profileRenderPending = false
			if isOpen then
				self:_render()
			end
		end)
	end)

	-- A successful purchase should unlock the button before the player closes the map.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(purchasingPlayer: Player, _gamePassId: number, wasPurchased: boolean)
			if purchasingPlayer ~= player or not wasPurchased or not isOpen then
				return
			end
			task.delay(0.25, function()
				if isOpen then
					self:_fetchTravelAccess()
					self:_render()
				end
			end)
		end
	)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.M then
			self:Close()
		end
	end)
end

return FullMapController
