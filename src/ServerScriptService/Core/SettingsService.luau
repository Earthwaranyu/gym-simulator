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

	Net.BindFunction("UpdateSetting", 4, function(player: Player, settingName: any, enabled: any)
		if type(settingName) ~= "string" or type(enabled) ~= "boolean" then
			return false, "Invalid setting."
		end

		local data = DataService:GetData(player)
		if data == nil then
			return false, "Your data is still loading."
		end

		if settingName == "MusicEnabled" then
			data.Settings.MusicEnabled = enabled
		elseif settingName == "SfxEnabled" then
			data.Settings.SfxEnabled = enabled
		else
			return false, "That setting does not exist."
		end

		DataService:MarkDirty(player)
		return true, if enabled then "Setting enabled." else "Setting disabled."
	end)
end

return SettingsService
