--!strict
--[[
	SettingsService — validates and saves the small set of player preferences.

	The client sends a setting name and a boolean only. The whitelist below is the
	contract: arbitrary profile fields cannot be reached through this remote.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

local SettingsService = {
	Name = "SettingsService",
	Priority = 20,
}

local DataService: any = nil

function SettingsService:Init()
	DataService = Loader.Get("DataService")

	-- The whitelist is the whole security model here: a client may set these three keys
	-- and nothing else, whatever it sends. Listing them rather than writing
	-- `data.Settings[name]` is what stops a crafted call rewriting Stats through the
	-- settings remote.
	local VOLUME_SETTINGS: { [string]: boolean } = {
		MasterVolume = true,
		MusicVolume = true,
		SfxVolume = true,
	}

	Net.BindFunction("UpdateSetting", 4, function(player: Player, settingName: any, value: any)
		if type(settingName) ~= "string" or type(value) ~= "number" then
			return false, "Invalid setting."
		end
		if value ~= value then
			-- NaN survives every comparison below and would persist into the profile.
			return false, "Invalid setting."
		end
		if not VOLUME_SETTINGS[settingName] then
			return false, "That setting does not exist."
		end

		local data = DataService:GetData(player)
		if data == nil then
			return false, "Your data is still loading."
		end

		-- Clamped and rounded server-side. The slider already does this, which is exactly
		-- why the server has to as well.
		local clamped = math.clamp(math.round(value), 0, 100)
		local settings: any = data.Settings
		settings[settingName] = clamped

		DataService:MarkDirty(player)
		return true, `Volume set to {clamped}%.`
	end)
end

return SettingsService
