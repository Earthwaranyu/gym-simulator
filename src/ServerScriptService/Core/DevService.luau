--!strict
--[[
	DevService — Studio-only commands for reaching content you have not earned.

	Fifty-five stations across eleven districts cannot be tested by grinding to them.
	Playtesting the Ascendant machines legitimately means 20 hours of continuous play
	(see `docs/BALANCE_MODEL.md`), which is why the pose on most machines in this game
	has still never been looked at by a human. This file is how you look at them.

	**It does not exist on a live server.** Every command is behind
	`RunService:IsStudio()`, checked when the service starts *and* again on every
	command. There is no allowlist of trusted user ids, no gamepass, and no remote —
	commands arrive through the ordinary chat, which means a published place cannot
	reach them even if this file ships. If you ever want live admin tools, they need
	their own auditable design; this is a test fixture, not the start of one.

	Because it writes stats directly it bypasses `StatService:AddStat`, so everything
	it sets goes through `Formulas.SanitizeStat` here instead — a dev command is
	exactly the sort of thing that ends up putting `1e400` in a profile.

	Commands (type them in chat while playing in Studio):

	    /power <n>        set total power to n, split across all five stats
	    /stat <id> <n>    set one stat: /stat Legs 1e9
	    /tokens <n>       set token balance
	    /unlockall        enough power to open every district and machine
	    /reset            back to a fresh profile's stats and tokens
	    /where <muscle>   list every station for a muscle and whether it is open
	    /help             print this list in the output window
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local DevService = {
	Name = "DevService",
	-- Last: it reaches into other services' data and should never be part of anyone
	-- else's startup.
	Priority = 999,
}

local DataService: any = nil
local StatService: any = nil
local TrainingService: any = nil

--[[
	The one gate. Called on every command, not just at startup, so that a service left
	running in an exported place still refuses.
]]
local function allowed(): boolean
	return RunService:IsStudio()
end

local function notify(player: Player, message: string)
	print(`[DevService] {message}`)
	Net.Event("Notify"):FireClient(player, message)
end

--[[
	Parses a number the way a developer types it: 1e9, 2.5e12, 5000.
]]
local function parseNumber(text: string?): number?
	if text == nil then
		return nil
	end
	local value = tonumber(text)
	if value == nil or not Formulas.IsFinite(value) or value < 0 then
		return nil
	end
	return value
end

local function setStat(player: Player, statId: string, value: number): boolean
	local data = DataService:GetData(player)
	if data == nil then
		return false
	end
	data.Stats[statId] = Formulas.SanitizeStat(value)
	DataService:MarkDirty(player)
	-- Fires the same signal a rep does, so muscle scaling, the HUD, ranks, and
	-- analytics all react exactly as they would to earned progress.
	StatService.StatChanged:Fire(player, statId, data.Stats[statId], 0)
	return true
end

-- Typed as returning `...any` rather than `()` for the same reason the Loader's
-- lifecycle hooks are: with `()`, the type checker sees pcall as returning only the
-- success boolean and the error message cannot be captured.
local COMMANDS: { [string]: (Player, { string }) -> ...any } = {}

COMMANDS["/power"] = function(player: Player, args: { string })
	local total = parseNumber(args[1])
	if total == nil then
		notify(player, "Usage: /power 1e9")
		return
	end

	local share = total / #StatConfig.List
	for _, definition in StatConfig.List do
		setStat(player, definition.Id, share)
	end
	notify(player, `Power set to {NumberFormat.Format(total)}`)
end

COMMANDS["/stat"] = function(player: Player, args: { string })
	local statId = args[1]
	local value = parseNumber(args[2])
	if statId == nil or value == nil or not StatConfig.IsValid(statId) then
		notify(player, "Usage: /stat Legs 1e9")
		return
	end

	setStat(player, statId, value)
	notify(player, `{statId} set to {NumberFormat.Format(value)}`)
end

COMMANDS["/tokens"] = function(player: Player, args: { string })
	local value = parseNumber(args[1])
	local data = DataService:GetData(player)
	if value == nil or data == nil then
		notify(player, "Usage: /tokens 500")
		return
	end

	data.Tokens = math.floor(value)
	DataService:MarkDirty(player)
	notify(player, `Tokens set to {NumberFormat.Format(data.Tokens)}`)
end

--[[
	Enough power for every district and every machine, found from the configs rather
	than hardcoded — a new top district raises this automatically.
]]
COMMANDS["/unlockall"] = function(player: Player, _args: { string })
	local needed = 0
	for _, zone in ZoneConfig.List do
		needed = math.max(needed, zone.RequiredPower)
	end
	for _, definition in EquipmentConfig.List do
		needed = math.max(needed, definition.UnlockPower)
	end

	-- A margin above the highest gate, because gates compare with `>=` against a total
	-- that floating-point division across five stats can land a hair under.
	local total = needed * 1.1
	local share = total / #StatConfig.List
	for _, definition in StatConfig.List do
		setStat(player, definition.Id, share)
	end
	notify(player, `Everything unlocked — power {NumberFormat.Format(total)}`)
end

COMMANDS["/reset"] = function(player: Player, _args: { string })
	local data = DataService:GetData(player)
	if data == nil then
		return
	end
	for _, definition in StatConfig.List do
		setStat(player, definition.Id, 0)
	end
	data.Tokens = 0
	DataService:MarkDirty(player)
	notify(player, "Stats and tokens reset")
end

--[[
	The console half of the Train panel: every station for a muscle, whether it is open
	to you, and what it is worth. Prints to Output so it can be read while the game is
	running without opening a menu.
]]
COMMANDS["/where"] = function(player: Player, args: { string })
	local statId = args[1]
	if statId == nil or not StatConfig.IsValid(statId) then
		notify(player, "Usage: /where Back")
		return
	end

	local power = StatService:GetTotalPower(player)
	local status = TrainingService:GetSpotStatus(player)

	print(`[DevService] {statId} stations (your power: {NumberFormat.Format(power)}):`)
	local count = 0
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		local definition = EquipmentConfig.Resolve(station)
		if definition == nil or definition.StatId ~= statId then
			continue
		end
		count += 1

		local travelId = station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE)
		local zone = ZoneConfig.AtPosition(station:GetPivot().Position)
		local required = math.max(if zone ~= nil then zone.RequiredPower else 0, definition.UnlockPower)
		local spot = if type(travelId) == "string" then status.Spots[travelId] else nil

		print(
			`  {if power >= required then "OPEN  " else "LOCKED"} `
				.. `{definition.DisplayName} @ {if zone ~= nil then zone.DisplayName else "?"} `
				.. `needs {NumberFormat.Format(required)} `
				.. (if spot ~= nil then `({spot.Capacity - spot.Occupied}/{spot.Capacity} free)` else "")
		)
	end
	notify(player, `{count} {statId} stations listed in Output`)
end

COMMANDS["/help"] = function(player: Player, _args: { string })
	print("[DevService] /power n · /stat id n · /tokens n · /unlockall · /reset · /where muscle")
	notify(player, "Commands printed to Output")
end

function DevService:Init()
	if not allowed() then
		return
	end
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	TrainingService = Loader.Get("TrainingService")
end

function DevService:_onChatted(player: Player, message: string)
	if not allowed() then
		return
	end

	local args: { string } = {}
	for word in string.gmatch(message, "%S+") do
		table.insert(args, word)
	end
	if #args == 0 then
		return
	end

	local command = COMMANDS[string.lower(args[1])]
	if command == nil then
		return
	end

	table.remove(args, 1)
	-- Wrapped: a typo in a dev command must not take down the server everyone else is
	-- testing on.
	local ok, err = pcall(command, player, args)
	if not ok then
		warn(`[DevService] {message} failed: {err}`)
	end
end

function DevService:Start()
	if not allowed() then
		return
	end

	warn("[DevService] Studio session — dev commands are ACTIVE. Type /help in chat.")

	local function bind(player: Player)
		player.Chatted:Connect(function(message: string)
			self:_onChatted(player, message)
		end)
	end

	for _, player in Players:GetPlayers() do
		bind(player)
	end
	Players.PlayerAdded:Connect(bind)
end

return DevService
