--!nocheck
--[[
	simulate — the headless progression and economy model.

	Answers the questions balance guesses have been standing in for: how long is it
	until a new player's first upgrade, first rank, and first new district; where does
	progress stall; how many tokens the economy produces versus consumes; and how much
	any of that moves when a number moves.

	It uses the game's real math. `Formulas` is pure Luau with no requires, so it is
	required directly — the same functions the server runs. The world's numbers come
	from `_balance_inputs.luau`, generated from EquipmentConfig, ZoneConfig, RankConfig
	and TrainingService by `scripts/extract_balance.py`, so a balance change that skips
	this simulation fails check.sh rather than silently invalidating it.

	Deterministic by construction: no `math.random` anywhere. Every play style is a
	fixed policy over a fixed clock, so two runs of the same commit produce identical
	output and a diff in the numbers always means a diff in the game.

	What it deliberately does NOT model: anything it would have to invent. There is no
	guess at how often a real player gets attacked, how long they stare at a menu, or
	what fraction buys Robux. The killed styles below use *stated* interruption rates,
	printed alongside the results, so a reader can see the assumption rather than
	inherit it. Replace them with measured rates once #102 has run.

	Run:  luau scripts/simulate.luau
]]

local Formulas = require("../src/ReplicatedStorage/Modules/Formulas")
local Inputs = require("./_balance_inputs")

local STATS = { "Arms", "Chest", "Back", "Core", "Legs" }

-- Simulation resolution. Small enough that a 0.5s rep interval is not distorted,
-- large enough that a full day of play runs in a moment.
local STEP = 0.25
local HORIZON_HOURS = 24

--[[
	A play style is a policy, not a personality. Each field is a lever a real player
	pulls, and every one of them is stated rather than inferred.
]]
type Style = {
	Name: string,
	Description: string,
	-- Fraction of wall-clock time actually spent mounted and repping. The rest is
	-- walking, menus, looking around.
	Uptime: number,
	-- Seconds between forced dismounts, or 0 for none. Interruption is kill-only, so
	-- this is a death rate, not a hit rate.
	InterruptEvery: number,
	-- Seconds lost per death: respawn plus walking back and remounting.
	InterruptCost: number,
	-- Flat multiplier on gains from boosts (VIP, potions, events).
	GainBoost: number,
	-- Sessions per simulated day, for styles that do not play continuously. Only
	-- affects how the timeline is reported, never the math.
	SessionsPerDay: number,
}

local STYLES: { Style } = {
	{
		Name = "Active",
		Description = "Plays continuously, remounts immediately, rarely interrupted.",
		Uptime = 0.9,
		InterruptEvery = 0,
		InterruptCost = 0,
		GainBoost = 1,
		SessionsPerDay = 1,
	},
	{
		Name = "Casual",
		Description = "Wanders, reads the map, trains about half the time.",
		Uptime = 0.5,
		InterruptEvery = 0,
		InterruptCost = 0,
		GainBoost = 1,
		SessionsPerDay = 3,
	},
	{
		Name = "Social",
		Description = "Trains alongside others; more idling, no deaths.",
		Uptime = 0.6,
		InterruptEvery = 0,
		InterruptCost = 0,
		GainBoost = 1,
		SessionsPerDay = 2,
	},
	{
		Name = "Boosted",
		Description = "Active, plus a permanent 2x from VIP.",
		Uptime = 0.9,
		InterruptEvery = 0,
		InterruptCost = 0,
		GainBoost = 2,
		SessionsPerDay = 1,
	},
	{
		Name = "Killed often",
		Description = "Active, but killed off the machine every 2 minutes.",
		Uptime = 0.9,
		InterruptEvery = 120,
		InterruptCost = 12,
		GainBoost = 1,
		SessionsPerDay = 1,
	},
	{
		Name = "Killed constantly",
		Description = "Worst realistic case: killed every 30 seconds.",
		Uptime = 0.9,
		InterruptEvery = 30,
		InterruptCost = 12,
		GainBoost = 1,
		SessionsPerDay = 1,
	},
}

--[[
	Formats seconds as the coarsest unit that still reads honestly.
]]
local function duration(seconds: number?): string
	if seconds == nil then
		return "never"
	end
	if seconds < 90 then
		return string.format("%.0fs", seconds)
	end
	if seconds < 5400 then
		return string.format("%.1fm", seconds / 60)
	end
	if seconds < 86400 * 2 then
		return string.format("%.1fh", seconds / 3600)
	end
	return string.format("%.1fd", seconds / 86400)
end

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function short(value: number): string
	if value ~= value or value == math.huge then
		return "inf"
	end
	local index = 1
	local scaled = value
	while scaled >= 1000 and index < #SUFFIXES do
		scaled /= 1000
		index += 1
	end
	if index == 1 then
		return string.format("%.0f", scaled)
	end
	return string.format("%.2f%s", scaled, SUFFIXES[index])
end

type Result = {
	Style: Style,
	FirstUpgradeAt: number?,
	FirstRankAt: number?,
	ZoneAt: { [string]: number },
	Power: number,
	PowerAtOneHour: number,
	Tokens: number,
	TokensEarned: number,
	TokensSpent: number,
	Upgrades: number,
	RepsLost: number,
	Deaths: number,
	LongestStallSeconds: number,
	StallAt: string?,
	Timeline: { { At: number, What: string } },
}

--[[
	Runs one play style to the horizon.

	The policy: always train the stat with the lowest value (which is what a player
	chasing total power does, and what the tutorial teaches), on the best machine for
	it that is unlocked, in the best zone that is unlocked. Buy an upgrade the moment
	it is affordable, cheapest first — the greedy choice, and the one a player who is
	not doing arithmetic will make.

	`gainScale` and `costScale` exist for sensitivity runs and are 1 in the main pass.
]]
local function run(style: Style, gainScale: number, costScale: number): Result
	local stats: { [string]: number } = {}
	for _, statId in STATS do
		stats[statId] = 0
	end

	local levels: { [string]: number } = {}
	for _, statId in STATS do
		levels[statId] = 0
	end

	local result: Result = {
		Style = style,
		ZoneAt = {},
		Power = 0,
		PowerAtOneHour = 0,
		Tokens = 0,
		TokensEarned = 0,
		TokensSpent = 0,
		Upgrades = 0,
		RepsLost = 0,
		Deaths = 0,
		LongestStallSeconds = 0,
		Timeline = {},
	}

	local tokens = 0
	local combo = 0
	local nextRepAt = 0
	local nextTokenAt = Formulas.TOKEN_TICK_SECONDS
	-- Offset by a prime-ish number of seconds so interruptions do not land on the same
	-- phase of the duty cycle every time. Without it, a 120s death rate lands exactly
	-- on the second the player remounts, the combo is always 0, and the model reports
	-- that being killed costs nothing.
	local nextInterruptAt = if style.InterruptEvery > 0 then style.InterruptEvery + 7 else math.huge
	local downUntil = -1
	local lastProgressAt = 0
	local lastUpgradeCount = 0

	-- Uptime is applied as a duty cycle rather than as a random coin flip, so the
	-- model stays deterministic: the player trains for `Uptime` of every minute.
	local CYCLE = 60

	local horizon = HORIZON_HOURS * 3600
	local time = 0

	while time < horizon do
		time += STEP

		local power = Formulas.TotalPower(stats)
		result.Power = power
		if time <= 3600 then
			result.PowerAtOneHour = power
		end

		-- Zone and machine selection, both gated on total power. Every unlocked zone is
		-- recorded, not just improving ones: the starter zone's multiplier is 1, and a
		-- "best so far" test would report it as never reached.
		local zoneMultiplier = 1
		for _, zone in Inputs.Zones do
			if power >= zone.RequiredPower then
				zoneMultiplier = math.max(zoneMultiplier, zone.GainMultiplier)
				if result.ZoneAt[zone.Id] == nil then
					result.ZoneAt[zone.Id] = time
					table.insert(result.Timeline, { At = time, What = `zone {zone.Id}` })
					lastProgressAt = time
				end
			end
		end

		-- Rank lookup, same rule as RankConfig.Get: the highest threshold cleared.
		local rankId = Inputs.Ranks[1].Id
		for index = #Inputs.Ranks, 1, -1 do
			if power >= Inputs.Ranks[index].MinPower then
				rankId = Inputs.Ranks[index].Id
				break
			end
		end
		if result.FirstRankAt == nil and rankId ~= Inputs.Ranks[1].Id then
			result.FirstRankAt = time
			table.insert(result.Timeline, { At = time, What = `rank {rankId}` })
			lastProgressAt = time
		end

		-- Down after a death: no reps, no tokens.
		if time < downUntil then
			continue
		end

		-- Duty cycle: the first `Uptime` fraction of each minute is spent mounted.
		local mounted = (time % CYCLE) < (CYCLE * style.Uptime)

		if time >= nextInterruptAt then
			nextInterruptAt = time + style.InterruptEvery
			if mounted then
				result.Deaths += 1
				result.RepsLost += combo
				combo = 0
				downUntil = time + style.InterruptCost
				-- Ticks that fall while the player is dead are forfeited, not banked.
				-- Letting them accumulate and pay out on respawn would make dying free,
				-- which is precisely the thing this model exists to measure.
				while nextTokenAt < downUntil do
					nextTokenAt += Formulas.TOKEN_TICK_SECONDS
				end
				continue
			end
		end

		-- Tokens accrue on the gym floor whether or not the player is repping, but
		-- not while dead. That is what TokenService does.
		if time >= nextTokenAt then
			nextTokenAt += Formulas.TOKEN_TICK_SECONDS
			local awarded = Formulas.TokensPerTick()
			tokens += awarded
			result.TokensEarned += awarded
		end

		if mounted then
			-- Lowest stat first.
			local targetStat = STATS[1]
			for _, statId in STATS do
				if stats[statId] < stats[targetStat] then
					targetStat = statId
				end
			end

			local best = nil
			for _, machine in Inputs.Equipment do
				if machine.StatId == targetStat and power >= machine.UnlockPower then
					if best == nil or machine.BaseGain / machine.RepInterval > best.BaseGain / best.RepInterval then
						best = machine
					end
				end
			end

			if best ~= nil and time >= nextRepAt then
				nextRepAt = time + best.RepInterval
				combo += 1

				local comboMultiplier =
					math.min(Inputs.MAX_COMBO_MULTIPLIER, 1 + combo * Inputs.COMBO_STEP)
				local multiplier = Formulas.MultiplierValue(levels[targetStat])
					* comboMultiplier
					* zoneMultiplier
					* style.GainBoost
					* gainScale

				stats[targetStat] += Formulas.GainPerRep(best.BaseGain, multiplier)
			end
		else
			-- Dismounting to walk around resets the combo, same as in game.
			combo = 0
		end

		-- Spend. Greedy: cheapest affordable upgrade, as often as it is affordable.
		while true do
			local cheapestStat = nil
			local cheapestCost = math.huge
			for _, statId in STATS do
				local cost = Formulas.MultiplierCost(levels[statId]) * costScale
				if cost < cheapestCost then
					cheapestCost = cost
					cheapestStat = statId
				end
			end
			if cheapestStat == nil or tokens < cheapestCost then
				break
			end
			tokens -= cheapestCost
			result.TokensSpent += cheapestCost
			levels[cheapestStat] += 1
			result.Upgrades += 1
			if result.FirstUpgradeAt == nil then
				result.FirstUpgradeAt = time
				table.insert(result.Timeline, { At = time, What = "first upgrade" })
			end
			lastProgressAt = time
		end

		-- A stall is a stretch with no upgrade, no rank, and no new zone: the shape of
		-- a player wondering what they are supposed to be doing.
		if result.Upgrades ~= lastUpgradeCount then
			lastUpgradeCount = result.Upgrades
			lastProgressAt = time
		end
		local stall = time - lastProgressAt
		if stall > result.LongestStallSeconds then
			result.LongestStallSeconds = stall
			result.StallAt = `after {duration(lastProgressAt)}`
		end
	end

	result.Tokens = tokens
	return result
end

local function header(title: string)
	print("")
	print(title)
	print(string.rep("=", #title))
end

header(`Progression & economy model — {HORIZON_HOURS}h horizon, {STEP}s resolution`)
print("Deterministic: no randomness anywhere. Same commit, same numbers.")
print("Interruption rates are STATED assumptions, not measurements. See #102.")

local results: { Result } = {}
for _, style in STYLES do
	table.insert(results, run(style, 1, 1))
end

header("Time to the first things that matter")
print(string.format("%-20s %12s %12s %12s %14s", "Style", "1st upgrade", "1st rank", "2nd zone", "power @ 1h"))
for _, result in results do
	local secondZone: number? = nil
	for _, zone in Inputs.Zones do
		local at = result.ZoneAt[zone.Id]
		if at ~= nil and zone.RequiredPower > 0 and (secondZone == nil or at < secondZone) then
			secondZone = at
		end
	end

	print(
		string.format(
			"%-20s %12s %12s %12s %14s",
			result.Style.Name,
			duration(result.FirstUpgradeAt),
			duration(result.FirstRankAt),
			duration(secondZone),
			short(result.PowerAtOneHour)
		)
	)
end

header("Economy after 24h")
print(string.format("%-20s %10s %10s %10s %8s %10s", "Style", "earned", "spent", "held", "upgrades", "power"))
for _, result in results do
	print(
		string.format(
			"%-20s %10s %10s %10s %8d %10s",
			result.Style.Name,
			short(result.TokensEarned),
			short(result.TokensSpent),
			short(result.Tokens),
			result.Upgrades,
			short(result.Power)
		)
	)
end

header("Cost of being killed")
local baseline = results[1]
for _, result in results do
	if result.Deaths > 0 then
		local lost = 1 - (result.Power / baseline.Power)
		print(
			string.format(
				"%-20s %5d deaths, %6d reps of combo lost, %.1f%% less power than an uninterrupted Active player",
				result.Style.Name,
				result.Deaths,
				result.RepsLost,
				lost * 100
			)
		)
	end
end

header("Longest stall (no upgrade, rank, or zone)")
for _, result in results do
	print(string.format("%-20s %10s  %s", result.Style.Name, duration(result.LongestStallSeconds), result.StallAt or "-"))
end

header("Zone pacing — Active player")
for _, zone in Inputs.Zones do
	local at = baseline.ZoneAt[zone.Id]
	print(string.format("  %-12s needs %10s power   reached %s", zone.Id, short(zone.RequiredPower), duration(at)))
end

header("Sensitivity — how much do the levers actually move things?")
print("Each row re-runs the Active player with one number scaled.")
print(string.format("%-28s %14s %14s %10s", "Change", "1st upgrade", "24h power", "upgrades"))
local SENSITIVITY = {
	{ Label = "baseline", Gain = 1, Cost = 1 },
	{ Label = "gains -25%", Gain = 0.75, Cost = 1 },
	{ Label = "gains +25%", Gain = 1.25, Cost = 1 },
	{ Label = "gains x2", Gain = 2, Cost = 1 },
	{ Label = "upgrade cost -25%", Gain = 1, Cost = 0.75 },
	{ Label = "upgrade cost +25%", Gain = 1, Cost = 1.25 },
	{ Label = "upgrade cost x2", Gain = 1, Cost = 2 },
}
for _, row in SENSITIVITY do
	local sensitivity = run(STYLES[1], row.Gain, row.Cost)
	print(
		string.format(
			"%-28s %14s %14s %10d",
			row.Label,
			duration(sensitivity.FirstUpgradeAt),
			short(sensitivity.Power),
			sensitivity.Upgrades
		)
	)
end

header("Timeline — Active player, first ten events")
for index, event in baseline.Timeline do
	if index > 10 then
		break
	end
	print(string.format("  %8s  %s", duration(event.At), event.What))
end

print("")
