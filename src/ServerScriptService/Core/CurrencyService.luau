--!strict
--[[
	CurrencyService — cash, the spendable currency.

	Deliberately separate from Tokens. Tokens measure time invested and buy permanent
	multipliers; cash flows from activity and buys consumables and unlocks, so a player
	can be rich and weak or broke and strong.

	Income is wired by listening to StatService and CombatService rather than by those
	systems calling in, so adding another way to earn is another listener here and no
	edit anywhere else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

-- Cash per point of stat gained. Training is the baseline income.
local CASH_PER_STAT = 0.35
-- Flat purse for a kill, before any bounty on the victim's head.
local CASH_PER_KILL = 25

local CurrencyService = {
	Name = "CurrencyService",
	Priority = 55,
}

local DataService: any = nil

-- (player, amount, newTotal)
CurrencyService.CashChanged = Signal.new()

function CurrencyService:Init()
	DataService = Loader.Get("DataService")
end

function CurrencyService:Get(player: Player): number
	local data = DataService:GetData(player)
	return if data ~= nil then data.Cash else 0
end

function CurrencyService:Add(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local data = DataService:GetData(player)
	if data == nil then
		return false
	end

	data.Cash += amount
	DataService:MarkDirty(player)
	CurrencyService.CashChanged:Fire(player, amount, data.Cash)

	return true
end

--[[
	Spends cash if the player can afford it, atomically. Returns false and changes
	nothing otherwise, so callers never need to pre-check the balance.
]]
function CurrencyService:TrySpend(player: Player, amount: number): boolean
	local data = DataService:GetData(player)
	if data == nil or amount <= 0 or data.Cash < amount then
		return false
	end

	data.Cash -= amount
	DataService:MarkDirty(player)
	CurrencyService.CashChanged:Fire(player, -amount, data.Cash)

	return true
end

function CurrencyService:Start()
	local StatService = Loader.Get("StatService")
	local CombatService = Loader.Get("CombatService")

	-- Training pays. Awarded off the gain rather than off reps, so a player with big
	-- multipliers earns proportionally more without a second formula to keep in sync.
	StatService.StatChanged:Connect(
		function(player: Player, _statId: string, _newValue: number, gained: number)
			self:Add(player, gained * CASH_PER_STAT)
		end
	)

	CombatService.PlayerKilled:Connect(function(_victim: Player, killer: Player, isRepeatKill: boolean)
		if isRepeatKill then
			return
		end
		self:Add(killer, CASH_PER_KILL)
		Net.Event("Notify"):FireClient(killer, `+${CASH_PER_KILL} for the knockout.`)
	end)
end

return CurrencyService
