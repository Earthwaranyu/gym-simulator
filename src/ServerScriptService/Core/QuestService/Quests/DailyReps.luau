--!strict
--[[
	Daily: gain Power through training.

	Every training source now pays on one shared one-second cadence. Progress still uses
	the amount that actually reached the profile rather than counting events, so combo,
	upgrades and stat caps can never make the quest disagree with visible Power.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local Quest: Types.Quest = {
	Id = "DailyReps",
	DisplayName = "Gym Rat",
	Description = "Gain 500 Power today.",
	Goal = 500,
	TokenReward = 5,
	Repeat = "Daily",

	Track = function(report: (Player, number) -> ())
		Loader.Get("StatService").StatChanged
			:Connect(function(player: Player, _statId: string, _newValue: number, gained: number)
				report(player, gained)
			end)
	end,
}

return Quest
