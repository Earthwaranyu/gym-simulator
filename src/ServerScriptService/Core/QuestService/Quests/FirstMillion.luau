--!strict
--[[
	One-shot: reach a million total power.

	Progress is reported as a delta rather than an absolute, because Report accumulates.
	Reporting the gain each time keeps the running total honest without the engine
	needing an "absolute progress" mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local Quest: Types.Quest = {
	Id = "FirstMillion",
	DisplayName = "Six Figures",
	Description = "Reach 1,000,000 total power.",
	Goal = 1e6,
	TokenReward = 15,
	Repeat = "Once",

	Track = function(report: (Player, number) -> ())
		Loader.Get("StatService").StatChanged
			:Connect(function(player: Player, _statId: string, _newValue: number, gained: number)
				report(player, gained)
			end)
	end,
}

return Quest
