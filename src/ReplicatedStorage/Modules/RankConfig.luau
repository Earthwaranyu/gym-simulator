--!strict
--[[
	RankConfig — the title a player carries, derived from total power.

	Purely a threshold table. Adding, renaming, or retuning a rank is one edit here;
	nothing else in the game hardcodes a rank name or a boundary.

	Entries must stay sorted by MinPower ascending — Get() walks backwards and takes
	the first match, so an out-of-order table would silently return the wrong rank.
]]

export type Rank = {
	Id: string,
	DisplayName: string,
	MinPower: number,
	Color: Color3,
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

local RankConfig = {}

RankConfig.List = ranks
local byId: { [string]: Rank } = {}
for _, rank in ranks do
	byId[rank.Id] = rank
end

function RankConfig.GetById(id: string): Rank?
	return byId[id]
end

function RankConfig.IsUnlocked(id: string, totalPower: number): boolean
	local rank = byId[id]
	return rank ~= nil and totalPower >= rank.MinPower
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
