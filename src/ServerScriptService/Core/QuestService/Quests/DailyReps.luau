--!strict
--[[
	Daily: train a lot of reps.

	Reference implementation of Types.Quest. Track() runs once at startup and wires
	whatever listener this objective needs; the engine never learns what a "rep" is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local Quest: Types.Quest = {
	Id = "DailyReps",
	DisplayName = "Gym Rat",
	Description = "Complete 500 reps today.",
	Goal = 500,
	TokenReward = 5,
	Repeat = "Daily",

	Track = function(report: (Player, number) -> ())
		-- StatChanged fires once per awarded rep, which is exactly one unit of progress.
		Loader.Get("StatService").StatChanged:Connect(function(player: Player)
			report(player, 1)
		end)
	end,
}

return Quest
