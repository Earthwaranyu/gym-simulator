--!strict
--[[
	WaypointController — the arrow that gets you to a machine you cannot teleport to.

	Fast Travel is a gamepass. Without it, picking a destination does not move you; it
	marks it. This draws that mark two ways, because one is never enough:

	  * a **world beacon** at the destination, drawn on top of everything so it is
	    visible through buildings and from across the city, with a live distance; and
	  * a **screen arrow** that points at it whenever it is off-screen, so you know
	    which way to turn before you can see anything.

	The beacon is a part this controller creates and owns, not the station itself.
	StreamingEnabled means the target machine usually does not exist in the client's
	Workspace when the waypoint is set — the whole point of a waypoint is that you are
	far away — so adorning the real station would produce nothing at all.

	It clears itself on arrival. A waypoint you have to dismiss by hand is one that is
	still on screen an hour later pointing at a bench you are standing on.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)

local WaypointController = {
	Name = "WaypointController",
	Priority = 9,
}

-- Close enough to count as arrived. Roughly the radius of a machine's platform, so
-- the marker clears as you step onto it rather than while you are still walking up.
local ARRIVE_DISTANCE = 26
-- Where the screen arrow sits, as a fraction of the viewport's smaller dimension from
-- the centre. Far enough out to not cover the crosshair, close enough to read.
local ARROW_RADIUS = 0.3

local player = Players.LocalPlayer

local beacon: Part? = nil
local beaconLabel: TextLabel? = nil
local arrowHolder: Frame? = nil
local arrowLabel: TextLabel? = nil
local screen: ScreenGui? = nil

local target: Vector3? = nil
local targetName = ""
local targetColor = Color3.new(1, 1, 1)
local connection: RBXScriptConnection? = nil

local ToastController: any = nil

function WaypointController:Init()
	ToastController = Loader.Get("ToastController")
end

local function buildScreen()
	local gui = Instance.new("ScreenGui")
	gui.Name = "GymWaypoint"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	screen = gui

	local holder = Instance.new("Frame")
	holder.Name = "Arrow"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(54, 54)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	arrowHolder = holder

	-- The arrowhead is a rotated square with its lower half hidden behind the label
	-- strip: a triangle without needing an image asset, which this project does not
	-- allow itself.
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Position = UDim2.fromScale(0.5, 0.5)
	head.Size = UDim2.fromScale(0.5, 0.5)
	head.Rotation = 45
	head.BorderSizePixel = 0
	head.Parent = holder

	local headCorner = Instance.new("UICorner")
	headCorner.CornerRadius = UDim.new(0, 4)
	headCorner.Parent = head

	local text = UI.Label("Distance", gui)
	text.AnchorPoint = Vector2.new(0.5, 0)
	text.Size = UDim2.fromOffset(220, 20)
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextSize = 14
	text.Font = UI.Font.Heading
	arrowLabel = text
end

local function buildBeacon()
	local part = Instance.new("Part")
	part.Name = "GymWaypointBeacon"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	-- Camera, not Workspace: nothing here should replicate, be hit by a raycast, or
	-- survive into anyone else's world.
	part.Parent = Workspace.CurrentCamera
	beacon = part

	local gui = Instance.new("BillboardGui")
	gui.Name = "Marker"
	gui.Adornee = part
	gui.Size = UDim2.fromOffset(230, 54)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	-- Through walls on purpose. A waypoint that hides behind the building it is inside
	-- is a waypoint that only works once you have already found the place.
	gui.AlwaysOnTop = true
	gui.MaxDistance = math.huge
	gui.Parent = part

	local panel = UI.Panel("Body", gui)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundTransparency = 0.15

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 14
	beaconLabel = label
end

local function distanceText(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fk studs", studs / 1000)
	end
	return string.format("%d studs", studs)
end

--[[
	One frame of tracking: move the beacon, update both distances, and point the arrow.
]]
local function step()
	local position = target
	local camera = Workspace.CurrentCamera
	if position == nil or camera == nil then
		return
	end

	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local distance = (position - root.Position).Magnitude
	if distance <= ARRIVE_DISTANCE then
		WaypointController:Clear()
		if ToastController ~= nil then
			ToastController:Show(`Arrived at {targetName}`)
		end
		return
	end

	if beacon ~= nil then
		beacon.Position = position
	end
	if beaconLabel ~= nil then
		beaconLabel.Text = `<b>{targetName}</b>\n<font color="#8A93A8">{distanceText(distance)} away</font>`
	end

	-- Screen-space direction. The arrow only appears when the target is behind the
	-- camera or outside the viewport; on-screen, the beacon is already doing the job
	-- and a second indicator over the top of it is just clutter.
	local screenPoint, onScreen = camera:WorldToViewportPoint(position)
	local viewport = camera.ViewportSize
	local centre = viewport / 2

	local holder = arrowHolder
	local label = arrowLabel
	if holder == nil or label == nil then
		return
	end

	if onScreen then
		holder.Visible = false
		label.Position = UDim2.fromOffset(math.round(screenPoint.X), math.round(screenPoint.Y) + 30)
		label.Text = ""
		return
	end

	holder.Visible = true

	-- Behind the camera, WorldToViewportPoint mirrors the X/Y, so the arrow would
	-- point at exactly the wrong side of the screen. Flipping it back is what makes
	-- "turn around" read as turn around.
	local offset = Vector2.new(screenPoint.X, screenPoint.Y) - centre
	if screenPoint.Z < 0 then
		offset = -offset
	end
	if offset.Magnitude < 1 then
		offset = Vector2.new(0, -1)
	end

	local radius = math.min(viewport.X, viewport.Y) * ARROW_RADIUS
	local direction = offset.Unit
	local point = centre + direction * radius

	holder.Position = UDim2.fromOffset(math.round(point.X), math.round(point.Y))
	-- The head is drawn pointing up, so rotate from -Y.
	holder.Rotation = math.deg(math.atan2(direction.Y, direction.X)) + 90

	label.Position = UDim2.fromOffset(math.round(point.X), math.round(point.Y) + 34)
	label.Text = `{targetName}  ·  {distanceText(distance)}`
end

--[[
	Starts tracking a world position. Replaces any waypoint already set — one arrow,
	because two arrows is a compass rose nobody can follow.
]]
function WaypointController:SetTarget(position: Vector3, name: string, color: Color3)
	if screen == nil then
		buildScreen()
	end
	if beacon == nil then
		buildBeacon()
	end

	target = position
	targetName = name
	targetColor = color

	local holder = arrowHolder
	if holder ~= nil then
		local head = holder:FindFirstChild("Head")
		if head ~= nil and head:IsA("Frame") then
			head.BackgroundColor3 = color
		end
	end
	if arrowLabel ~= nil then
		arrowLabel.TextColor3 = color
	end
	if beaconLabel ~= nil then
		beaconLabel.TextColor3 = color
	end
	if screen ~= nil then
		screen.Enabled = true
	end

	if connection == nil then
		connection = RunService.RenderStepped:Connect(step)
	end
end

function WaypointController:Clear()
	target = nil
	if connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
	if screen ~= nil then
		screen.Enabled = false
	end
	if beacon ~= nil then
		beacon:Destroy()
		beacon = nil
		beaconLabel = nil
	end
end

function WaypointController:HasTarget(): boolean
	return target ~= nil
end

function WaypointController:Start()
	-- The beacon lives under CurrentCamera, which Roblox replaces on respawn. Rebuild
	-- it rather than leaving the player following an arrow attached to nothing.
	player.CharacterAdded:Connect(function()
		local position = target
		if position == nil then
			return
		end

		local name, color = targetName, targetColor
		if beacon ~= nil then
			beacon:Destroy()
			beacon = nil
			beaconLabel = nil
		end
		task.defer(function()
			if target ~= nil then
				self:SetTarget(position, name, color)
			end
		end)
	end)
end

return WaypointController
