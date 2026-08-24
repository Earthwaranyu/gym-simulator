--!strict
--[[
	Step three of the rotation: go and fight something.

	The step that takes the player out of the safe training courts and into a mob field,
	which is the whole reason monsters exist. It is the shortest step by count — five
	kills against hundreds of stat points — because it costs a trip and a real fight
	rather than time spent standing on a machine.

	Bosses count. They are far harder than the goblins the quest is asking for, so
	refusing them would be a trap: a player who happens to fell a boss during this step
	would watch it award nothing.

	MobService is fetched inside Track rather than at module scope. Track runs during
	Start, by which point every system is registered; requiring it any earlier would be
	a load-order crash.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local QuestCycleConfig = require(ReplicatedStorage.Modules.QuestCycleConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local Quest: Types.Quest = {
	Id = "CycleMobHunt",
	DisplayName = "Culling",
	Description = "Defeat goblins in a monster field.",
	Category = "Combat",
	CycleOrder = 3,

	GoalAt = function(loop: number): number
		return QuestCycleConfig.Goal("Mobs", loop)
	end,
	RewardAt = function(loop: number): number
		return QuestCycleConfig.Reward(loop)
	end,

	Track = function(report: (Player, number) -> ())
		Loader.Get("MobService").MobKilled:Connect(function(killer: Player, _mob)
			report(killer, 1)
		end)
	end,
}

return Quest
