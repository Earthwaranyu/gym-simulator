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
	{ Id = "Newbie", DisplayName = "Newbie", MinPower = 0, Color = Color3.fromRGB(158, 168, 190) },
	{ Id = "Beginner", DisplayName = "Beginner", MinPower = 2.5e3, Color = Color3.fromRGB(126, 211, 155) },
	{ Id = "Lifter", DisplayName = "Lifter", MinPower = 5e4, Color = Color3.fromRGB(102, 187, 106) },
	{ Id = "Athlete", DisplayName = "Athlete", MinPower = 1e6, Color = Color3.fromRGB(66, 165, 245) },
	{ Id = "Beast", DisplayName = "Beast", MinPower = 5e7, Color = Color3.fromRGB(126, 231, 255) },
	{ Id = "Monster", DisplayName = "Monster", MinPower = 1e9, Color = Color3.fromRGB(171, 71, 188) },
	{ Id = "Colossus", DisplayName = "Colossus", MinPower = 5e10, Color = Color3.fromRGB(255, 167, 38) },
	{ Id = "Titan", DisplayName = "Titan", MinPower = 1e12, Color = Color3.fromRGB(255, 196, 61) },
	{ Id = "Godlike", DisplayName = "Godlike", MinPower = 1e15, Color = Color3.fromRGB(255, 92, 92) },
}

local RankConfig = {}

RankConfig.List = ranks

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
