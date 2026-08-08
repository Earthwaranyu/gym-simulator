--!strict
--[[
	AnalyticsController — reports the handful of facts only a client can know.

	Device, locale, whether a prompt was actually on screen, which panel was opened,
	when the player first moved, when flight first engaged. None of these are visible
	to the server, and none of them grant anything — the server re-derives every fact
	that matters and drops any event `AnalyticsSchema` does not mark ClientReportable,
	so the worst a hacked client can do here is lie about its own screen.

	Like the server side, this file only *observes*. It watches
	`ProximityPromptService`, `MenuController.Changed`, and `FlightController:IsFlying`
	rather than asking any of them to call it, so deleting this file changes nothing
	else in the client.
]]

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

local AnalyticsController = {
	Name = "AnalyticsController",
	-- Late: everything it observes must already exist.
	Priority = 95,
}

local player = Players.LocalPlayer
local joinedAt = os.clock()

-- Movement has to clear a threshold before it counts. A character settling onto the
-- spawn pad drifts a stud or two on its own, and a "player moved" metric that also
-- counts players who never touched a key answers nothing.
local MOVE_THRESHOLD = 8

-- Prompts fire PromptShown constantly as a player walks a row of machines. One
-- report per station per session is the useful shape; the rest is noise.
local seenPrompts: { [string]: boolean } = {}

local reported: { [string]: boolean } = {}
local FlightController: any = nil

local function report(eventName: string, payload: { [string]: any }?)
	Net.Event("AnalyticsReport"):FireServer(eventName, payload)
end

--[[
	Reports an event at most once per session. The server enforces this too — this is
	only here so a per-frame watcher does not spend a remote call every frame after
	the first.
]]
local function reportOnce(eventName: string, payload: { [string]: any }?)
	if reported[eventName] then
		return
	end
	reported[eventName] = true
	report(eventName, payload)
end

local function describeDevice(): (string, string)
	local device = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then "Touch"
		elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then "Console"
		else "Desktop"

	local input = if UserInputService.KeyboardEnabled
		then "KeyboardMouse"
		elseif UserInputService.TouchEnabled then "Touch"
		elseif UserInputService.GamepadEnabled then "Gamepad"
		else "Unknown"

	return device, input
end

function AnalyticsController:Init()
	FlightController = Loader.Get("FlightController")
end

function AnalyticsController:Start()
	local device, input = describeDevice()
	reportOnce("DeviceInput", { Device = device, Input = input })

	-- Locale can fail to resolve on a cold client; a missing locale is not worth an
	-- error in a controller that only watches.
	local ok, localeId = pcall(function()
		return LocalizationService.RobloxLocaleId
	end)
	if ok and type(localeId) == "string" and localeId ~= "" then
		reportOnce("Locale", { LocaleId = localeId })
	end

	-- Which panel the player opened. MenuController.Changed already publishes this
	-- for the button bar's highlight, so nothing new has to be wired.
	local MenuController = Loader.Get("MenuController")
	MenuController.Changed:Connect(function(tabId: string?)
		if tabId == "Map" then
			report("MapOpened")
		elseif tabId == "Shop" then
			-- Opening the shop is the closest thing to an impression the catalogue has
			-- until per-item views exist (#171).
			report("ItemViewed", { ItemId = "ShopPanel" })
		end
	end)

	-- A prompt being *shown* is the client-only half of the training funnel: the
	-- server sees a Triggered, but never sees the player who walked up, read the
	-- prompt, and walked away.
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		local station = prompt.Parent
		if station == nil then
			return
		end
		local definition = EquipmentConfig.Resolve(station)
		if definition == nil or seenPrompts[definition.Id] then
			return
		end
		seenPrompts[definition.Id] = true
		report("PromptSeen", { StationId = definition.Id })
	end)

	-- First movement and first flight. One connection, dropped the moment both have
	-- been reported, so the steady-state cost of this controller is zero.
	local origin: Vector3? = nil
	local connection: RBXScriptConnection? = nil

	connection = RunService.Heartbeat:Connect(function()
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil

		if root ~= nil and root:IsA("BasePart") then
			if origin == nil then
				origin = root.Position
			elseif
				not reported["Moved"] and (root.Position - (origin :: Vector3)).Magnitude > MOVE_THRESHOLD
			then
				reportOnce("Moved", { SecondsSinceJoin = os.clock() - joinedAt })
			end
		end

		if not reported["FirstFlight"] and FlightController ~= nil and FlightController:IsFlying() then
			reportOnce("FirstFlight")
		end

		if reported["Moved"] and reported["FirstFlight"] and connection ~= nil then
			connection:Disconnect()
			connection = nil
		end
	end)
end

return AnalyticsController
