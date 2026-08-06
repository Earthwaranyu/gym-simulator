--!strict
--[[
	MultiplierService — spends tokens on permanent per-stat multipliers.

	This is the game's long-term progression sink, standing in for the rebirth system
	the design deliberately does not have. Nothing ever resets, so dying to a griefer
	costs minutes rather than hours.

	Note how it feeds StatService: it registers an ordinary modifier called
	"TokenUpgrades" like any other boost. There is no special case for token levels
	anywhere in the gain formula, so a gamepass or event buff composes with these
	automatically.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local MODIFIER_ID = "TokenUpgrades"

local MultiplierService = {
	Name = "MultiplierService",
	Priority = 70,
}

local DataService: any = nil
local StatService: any = nil
local TokenService: any = nil

function MultiplierService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	TokenService = Loader.Get("TokenService")

	Net.BindFunction("PurchaseMultiplier", 4, function(player: Player, statId: any)
		if type(statId) ~= "string" then
			return false, "Invalid request."
		end
		return self:Purchase(player, statId)
	end)
end

function MultiplierService:Start()
	-- Existing levels have to become a live modifier the moment data loads, or a
	-- returning player trains at 1x until their first purchase.
	DataService.ProfileLoaded:Connect(function(player: Player)
		self:_refresh(player)
	end)
end

--[[
	Rebuilds the TokenUpgrades modifier from the player's saved levels.
	Called on load and after every purchase.
]]
function MultiplierService:_refresh(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	local multipliers: { [Types.StatId]: number } = {}
	for statId, level in data.MultiplierLevels do
		if level > 0 then
			multipliers[statId] = Formulas.MultiplierValue(level)
		end
	end

	StatService:SetModifier(player, {
		Id = MODIFIER_ID,
		Multipliers = multipliers,
	})
end

function MultiplierService:GetLevel(player: Player, statId: Types.StatId): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return data.MultiplierLevels[statId] or 0
end

--[[
	Token cost of the player's next upgrade for a stat.
]]
function MultiplierService:GetNextCost(player: Player, statId: Types.StatId): number
	return Formulas.MultiplierCost(self:GetLevel(player, statId))
end

--[[
	Buys one multiplier level. Returns (success, message) — the message is shown
	verbatim in a toast, so it is written for players rather than developers.

	Fully server-authoritative: the client sends only a stat id, and cost, balance,
	and validity are all recomputed here.
]]
function MultiplierService:Purchase(player: Player, statId: Types.StatId): (boolean, string)
	if not StatConfig.IsValid(statId) then
		return false, "That stat does not exist."
	end

	local data = DataService:GetData(player)
	if data == nil then
		return false, "Your data is still loading."
	end

	local level = data.MultiplierLevels[statId] or 0
	local cost = Formulas.MultiplierCost(level)

	if not TokenService:TrySpendTokens(player, cost) then
		return false, `You need {cost} tokens for that upgrade.`
	end

	data.MultiplierLevels[statId] = level + 1
	self:_refresh(player)
	DataService:MarkDirty(player)

	local definition = StatConfig.Get(statId)
	local displayName = if definition ~= nil then definition.DisplayName else statId
	local newMultiplier = Formulas.MultiplierValue(level + 1)

	return true, `{displayName} multiplier is now {string.format("%.2f", newMultiplier)}x`
end

return MultiplierService
