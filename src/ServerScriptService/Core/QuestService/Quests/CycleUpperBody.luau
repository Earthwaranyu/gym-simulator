--!strict
--[[
	Step one of the rotation: train the pushing and pulling muscles.

	Progress counts the amount that actually reached the profile, not the number of
	reps, so combo bonuses, token multipliers and the stat cap can never make the quest
	disagree with the number the player can watch going up.

	Splitting the five muscles across two steps is what stops the cycle being satisfiable
	from one machine. You have to move.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local QuestCycleConfig = require(ReplicatedStorage.Modules.QuestCycleConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local COUNTED: { [string]: boolean } = { Arms = true, Chest = true, Back = true }

local Quest: Types.Quest = {
	Id = "CycleUpperBody",
	DisplayName = "Upper Body Day",
	Description = "Train Arms, Chest and Back.",
	Category = "Stat",
	CycleOrder = 1,

	GoalAt = function(loop: number): number
		return QuestCycleConfig.Goal("Upper", loop)
	end,
	RewardAt = function(loop: number): number
		return QuestCycleConfig.Reward(loop)
	end,

	Track = function(report: (Player, number) -> ())
		Loader.Get("StatService").StatChanged
			:Connect(function(player: Player, statId: string, _newValue: number, gained: number)
				if COUNTED[statId] then
					report(player, gained)
				end
			end)
	end,
}

return Quest
