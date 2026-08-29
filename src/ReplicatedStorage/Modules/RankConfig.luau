--!strict
--[[
	RankConfig — the title a player carries, derived from total power.

	Purely a threshold table. Adding, renaming, or retuning a rank is one edit here;
	nothing else in the game hardcodes a rank name or a boundary.

	Entries must stay sorted by MinPower ascending — Get() walks backwards and takes
	the first match, so an out-of-order table would silently return the wrong rank.

	Two lists, not one. `ranks` is the power ladder and only the power ladder: Get() and
	GetNext() walk it, the sort assertion below guards it, and RosterService and the
	analytics stream both report whatever it returns. `specials` holds titles that are
	earned some other way — VIP is the first — and they must stay out of `ranks` for two
	reasons: a MinPower of zero would break the ascending order, and Get() would then hand
	the title to every player at zero power whether they own the pass or not.

	`List` is both together, because the title selector is the one place that wants every
	title a player could ever wear.
]]

export type Rank = {
	Id: string,
	DisplayName: string,
	MinPower: number,
	Color: Color3,
	-- A product id from PurchaseService/Products. When set, owning that pass unlocks the
	-- title and MinPower is not consulted.
	RequiresGamepass: string?,
	-- Draws the nameplate title with a stroke around it. For titles that are meant to be
	-- noticed across a gym rather than read up close.
	Glow: boolean?,
}

local ranks: { Rank } = {
	{ Id = "Newbie", DisplayName = "Newbie", MinPower = 0, Color = Color3.fromRGB(104, 114, 136) },
	{ Id = "Beginner", DisplayName = "Beginner", MinPower = 2.5e3, Color = Color3.fromRGB(66, 146, 96) },
	{ Id = "Lifter", DisplayName = "Lifter", MinPower = 5e4, Color = Color3.fromRGB(52, 130, 58) },
	{ Id = "Athlete", DisplayName = "Athlete", MinPower = 1e6, Color = Color3.fromRGB(26, 110, 180) },
	{ Id = "Beast", DisplayName = "Beast", MinPower = 5e7, Color = Color3.fromRGB(16, 128, 156) },
	{ Id = "Monster", DisplayName = "Monster", MinPower = 1e9, Color = Color3.fromRGB(126, 42, 140) },
	{ Id = "Colossus", DisplayName = "Colossus", MinPower = 5e10, Color = Color3.fromRGB(200, 112, 10) },
	{ Id = "Titan", DisplayName = "Titan", MinPower = 1e12, Color = Color3.fromRGB(178, 108, 12) },
	{ Id = "Godlike", DisplayName = "Godlike", MinPower = 1e15, Color = Color3.fromRGB(190, 42, 42) },
}

-- Titles that are bought rather than earned. Gold, because the pass's own artwork is a
-- gold crown and the two should read as the same purchase.
local specials: { Rank } = {
	{
		Id = "Vip",
		DisplayName = "VIP",
		MinPower = 0,
		Color = Color3.fromRGB(255, 190, 46),
		RequiresGamepass = "Vip",
		Glow = true,
	},
}

local RankConfig = {}

RankConfig.Ranks = ranks
RankConfig.Specials = specials

local list: { Rank } = table.clone(ranks)
for _, special in specials do
	table.insert(list, special)
end

RankConfig.List = list

local byId: { [string]: Rank } = {}
for _, rank in list do
	byId[rank.Id] = rank
end

function RankConfig.GetById(id: string): Rank?
	return byId[id]
end

--[[
	Whether a player may wear this title.

	`ownsGamepass` answers for the titles that are bought. It is passed in rather than
	imported because the two callers know ownership by different means — the server asks
	MarketplaceService, the client reads the attribute the grant sets — and this file
	requires nothing so it can be self-tested headlessly.
]]
function RankConfig.IsUnlocked(id: string, totalPower: number, ownsGamepass: ((string) -> boolean)?): boolean
	local rank = byId[id]
	if rank == nil then
		return false
	end
	local required = rank.RequiresGamepass
	if required ~= nil then
		return ownsGamepass ~= nil and ownsGamepass(required) == true
	end
	return totalPower >= rank.MinPower
end

-- Fail loudly at load rather than silently mis-ranking players later.
for index = 2, #ranks do
	if ranks[index].MinPower <= ranks[index - 1].MinPower then
		error(`[RankConfig] Ranks must be sorted ascending by MinPower; "{ranks[index].Id}" breaks the order`)
	end
end

--[[
	The highest rank a player's total power qualifies for. Never nil — the first entry
	is the floor at zero power.
]]
function RankConfig.Get(totalPower: number): Rank
	for index = #ranks, 1, -1 do
		if totalPower >= ranks[index].MinPower then
			return ranks[index]
		end
	end
	return ranks[1]
end

--[[
	The next rank up, or nil at the top. Used for "X more to reach Y" progress text.
]]
function RankConfig.GetNext(totalPower: number): Rank?
	for _, rank in ranks do
		if totalPower < rank.MinPower then
			return rank
		end
	end
	return nil
end

return RankConfig
