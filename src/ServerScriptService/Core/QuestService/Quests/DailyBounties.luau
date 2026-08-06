--!strict
--[[
	Daily: knock out other players.

	Repeat kills on the same victim are excluded, so this cannot be farmed by trading
	deaths with a friend — the same rule CombatService applies to cash and reputation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local Quest: Types.Quest = {
	Id = "DailyKnockouts",
	DisplayName = "Enforcer",
	Description = "Knock out 3 different players today.",
	Goal = 3,
	TokenReward = 6,
	Repeat = "Daily",

	Track = function(report: (Player, number) -> ())
		Loader.Get("CombatService").PlayerKilled
			:Connect(function(_victim: Player, killer: Player, isRepeatKill: boolean)
				if isRepeatKill then
					return
				end
				report(killer, 1)
			end)
	end,
}

return Quest
