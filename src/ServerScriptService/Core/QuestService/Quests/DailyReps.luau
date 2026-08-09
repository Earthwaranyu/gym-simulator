--!strict
--[[
	Daily: gain Power through training.

	Manual training pays four small slices per second while machines pay once per
	exercise cycle. Counting StatChanged events therefore made the same +1 Power read
	as four "reps" in the quest HUD. Progress uses the amount that actually reached the
	profile instead, so the quest and the player's Power rise by the same number.
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
