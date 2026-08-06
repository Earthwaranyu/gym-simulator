--!strict
--[[
	BoostService — timed and permanent stat multipliers from purchases and events.

	Every boost is an ordinary modifier in the StatService stack, exactly like the token
	upgrades. That is the payoff of building the stack first: a 2x gamepass, a 15-minute
	supplement, and a weekend event buff all compose with each other and with token
	levels, and none of them needed the gain formula touched.

	Timed boosts store an absolute expiry, and StatService drops expired modifiers as it
	encounters them, so nothing here has to run a cleanup timer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local BoostService = {
	Name = "BoostService",
	Priority = 22,
}

local StatService: any = nil

function BoostService:Init()
	StatService = Loader.Get("StatService")
end

--[[
	Applies a boost to every stat at once.

	`durationSeconds` of nil makes it permanent for the session — used for gamepasses,
	which are re-applied on join rather than persisted as a modifier.
]]
function BoostService:GrantGlobal(player: Player, id: string, multiplier: number, durationSeconds: number?)
	local modifier: Types.Modifier = {
		Id = id,
		Multipliers = { [Types.ALL_STATS] = multiplier },
		ExpiresAt = if durationSeconds ~= nil then os.time() + durationSeconds else nil,
	}

	StatService:SetModifier(player, modifier)

	if durationSeconds ~= nil then
		Net.Event("Notify")
			:FireClient(player, `{multiplier}x stats for {NumberFormat.Duration(durationSeconds)}.`)
	end
end

--[[
	Applies a boost to a single stat, for supplements that target one muscle group.
]]
function BoostService:GrantStat(
	player: Player,
	id: string,
	statId: Types.StatId,
	multiplier: number,
	durationSeconds: number?
)
	StatService:SetModifier(player, {
		Id = id,
		Multipliers = { [statId] = multiplier },
		ExpiresAt = if durationSeconds ~= nil then os.time() + durationSeconds else nil,
	})
end

function BoostService:Revoke(player: Player, id: string)
	StatService:RemoveModifier(player, id)
end

-- No Start: StatService drops a player's whole modifier table when they leave, so
-- boosts have no lifetime of their own to manage.

return BoostService
