--!strict
--[[
	BoostService — timed and permanent stat multipliers from purchases and events.

	Every boost is an ordinary modifier in the StatService stack, exactly like the token
	upgrades. That is the payoff of building the stack first: a 2x gamepass, a 15-minute
	supplement, and a weekend event buff all compose with each other and with token
	levels, and none of them needed the gain formula touched.

	Timed boosts store an absolute expiry, and StatService drops expired modifiers as it
	encounters them, so nothing here has to run a cleanup timer.

	That expiry lives on the profile, not just in the StatService table. It used to live
	only in memory, which meant a player who bought a ten-minute shake and disconnected
	after two had paid Robux for nothing — the table is dropped on PlayerRemoving. The
	profile is now the durable record and the modifier table is a cache rebuilt from it
	by Restore on join, exactly as ImmortalUntil already worked.

	Permanent boosts (nil duration) are deliberately *not* persisted: those are
	gamepasses, and PurchaseService:ApplyGamepasses re-grants them on every join from
	the authoritative ownership check. Writing them here too would give a revoked pass a
	second life on the profile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local BoostConfig = require(ReplicatedStorage.Modules.BoostConfig)

local BoostService = {
	Name = "BoostService",
	Priority = 22,
}

local StatService: any = nil
local DataService: any = nil

function BoostService:Init()
	StatService = Loader.Get("StatService")
	DataService = Loader.Get("DataService")
end

function BoostService:Start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		self:Restore(player)
	end)
end

--[[
	Re-registers the modifiers for whatever was still running when the player left, and
	prunes what lapsed while they were away.

	Called on ProfileLoaded rather than PlayerAdded because it reads BoostUntil, which
	does not exist until the profile does.
]]
function BoostService:Restore(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	local now = os.time()

	for id, expiresAt in data.BoostUntil do
		local boost = BoostConfig.Get(id)

		-- An unknown id is a boost that has since been removed from BoostConfig. Drop
		-- it rather than restoring a multiplier nothing can describe any more.
		if boost == nil or expiresAt <= now then
			data.BoostUntil[id] = nil
			DataService:MarkDirty(player)
			continue
		end

		StatService:SetModifier(player, {
			Id = id,
			Multipliers = { [Types.ALL_STATS] = boost.Multiplier },
			ExpiresAt = expiresAt,
		})
	end
end

--[[
	Seconds left on one boost, or 0. Mirrors ImmortalityService:GetRemaining.
]]
function BoostService:GetRemaining(player: Player, id: string): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return math.max(0, (data.BoostUntil[id] or 0) - os.time())
end

--[[
	Applies a boost to every stat at once.

	`durationSeconds` of nil makes it permanent for the session — used for gamepasses,
	which are re-applied on join rather than persisted as a modifier.

	Returns false when a timed boost could not be written, so ProcessReceipt can leave
	the receipt unconsumed and Roblox will retry it rather than charging for nothing.
]]
function BoostService:GrantGlobal(
	player: Player,
	id: string,
	multiplier: number,
	durationSeconds: number?
): boolean
	local expiresAt: number? = nil

	if durationSeconds ~= nil then
		local data = DataService:GetData(player)
		if data == nil then
			return false
		end

		-- Extends rather than replaces, the same rule ImmortalityService:Grant uses.
		-- Overwriting would silently bin the minutes a player had already paid for.
		local base = math.max(data.BoostUntil[id] or 0, os.time())
		expiresAt = base + durationSeconds
		data.BoostUntil[id] = expiresAt
		DataService:MarkDirty(player)
	end

	StatService:SetModifier(player, {
		Id = id,
		Multipliers = { [Types.ALL_STATS] = multiplier },
		ExpiresAt = expiresAt,
	})

	if expiresAt ~= nil then
		-- Quotes the total left, not the amount just added, so a second purchase reads
		-- as the extension it is.
		local remaining = math.max(0, expiresAt - os.time())
		Net.Event("Notify"):FireClient(player, `{multiplier}x stats for {NumberFormat.Duration(remaining)}.`)
	end

	return true
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

	local data = DataService:GetData(player)
	if data ~= nil and data.BoostUntil[id] ~= nil then
		data.BoostUntil[id] = nil
		DataService:MarkDirty(player)
	end
end

return BoostService
