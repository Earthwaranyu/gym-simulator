--!strict
--[[
	Step two of the rotation: train the trunk and the legs.

	Progress counts the amount that actually reached the profile, not the number of
	reps, so combo bonuses, token multipliers and the stat cap can never make the quest
	disagree with the number the player can watch going up.

	The smaller half of the split, and deliberately worth the same: Legs is the stat
	that carries movement speed and flight, so a player who skipped it is the one this
	step is for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local QuestCycleConfig = require(ReplicatedStorage.Modules.QuestCycleConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local COUNTED: { [string]: boolean } = { Core = true, Legs = true }

local Quest: Types.Quest = {
	Id = "CycleLowerBody",
	DisplayName = "Lower Body Day",
	Description = "Train Core and Legs.",
	Category = "Stat",
	CycleOrder = 2,

	GoalAt = function(loop: number): number
		return QuestCycleConfig.Goal("Lower", loop)
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
