--!strict
--[[
	FlagConfig — every feature flag and experiment in the game, as data.

	A flag is one of two things:

	  * a **switch** — a value the server reads instead of a hardcoded constant, with a
	    safe default and a kill switch, or
	  * an **experiment** — the same, plus weighted variants that a player is assigned
	    to deterministically.

	Assignment is a pure function of `(UserId, flag salt)`. No randomness, no stored
	cohort, no server-to-server disagreement: the same player resolves to the same
	variant on every server, every session, forever, and two flags never correlate
	because each mixes in its own salt.

	Three rules this file enforces by construction:

	  1. **Every flag has a safe default.** If resolution fails for any reason, the
	     default is what the game runs. The default is always the behavior that is
	     already shipped and known good.
	  2. **Flags select configuration and presentation, never rewards.** A flag may not
	     be the reason a player receives currency, stats, or an entitlement — that turns
	     a cohort assignment into a value grant, and the client sees cohorts.
	  3. **Flags never change saved shape.** A variant that would need a different
	     profile layout is a migration (see `_Migrations`), not a flag, because there is
	     no rollback path once a save is written in the new shape.

	Adding a flag is an entry in FLAGS. No other file changes.
]]

local FlagConfig = {}

export type Variant = {
	Id: string,
	-- Relative weight. Two variants at 1 and 3 split 25/75. Weights are relative on
	-- purpose: adding a third arm does not require rewriting the other two.
	Weight: number,
	Value: any,
}

export type Flag = {
	Id: string,
	Description: string,
	-- The shipped, known-good behavior. Used when the flag is killed, when the player
	-- cannot be resolved, and as the control arm's value if no variant matches.
	Default: any,
	-- Declared so a malformed override cannot smuggle a different type into a
	-- consumer that expects a number.
	Kind: "boolean" | "number" | "string",
	-- When true the flag is off for everyone regardless of variants: the emergency
	-- stop. Flipping this must always be safe and must never need a migration.
	Killed: boolean?,
	-- Absent for a plain switch. Present for an experiment.
	Variants: { Variant }?,
	-- Forces a value in Studio so a developer can exercise either arm without
	-- rolling a new UserId. Ignored on live servers.
	StudioValue: any?,
}

--[[
	Every flag. The two here are deliberately small and reversible — a flag that turns
	off a *panel* is a flag; a flag that turns off saving is not.
]]
local FLAGS: { Flag } = {
	{
		Id = "ShopEnabled",
		Description = "Master switch for the shop panel and every Robux prompt. The kill "
			.. "switch a live monetization bug needs. Never stops fulfillment of a "
			.. "receipt that already exists — see #105.",
		Kind = "boolean",
		Default = true,
	},
	{
		Id = "MapDefaultView",
		Description = "Which view the travel map opens on for a new session. All 55 "
			.. "locations stay visible either way; this only chooses the default "
			.. "filter, which is the honest version of #114's progressive disclosure.",
		Kind = "string",
		Default = "All",
		Variants = {
			{ Id = "Control", Weight = 1, Value = "All" },
			{ Id = "Nearby", Weight = 1, Value = "Nearby" },
		},
	},
}

FlagConfig.FLAGS = FLAGS

local byId: { [string]: Flag } = {}
for _, flag in FLAGS do
	if byId[flag.Id] ~= nil then
		error(`[FlagConfig] Duplicate flag id "{flag.Id}"`)
	end
	byId[flag.Id] = flag
end

function FlagConfig.Get(flagId: string): Flag?
	return byId[flagId]
end

--[[
	32-bit multiply with wraparound.

	Done in two 16-bit halves because the plain product overflows the 53 bits a Luau
	number holds exactly — and a multiply that silently loses its low bits produces a
	hash that clumps, which shows up as an experiment whose arms are not the split
	they claim to be.
]]
local function mul32(value: number, factor: number): number
	local low = bit32.band(value, 0xFFFF) * factor
	local high = bit32.band(bit32.rshift(value, 16) * factor, 0xFFFF)
	return bit32.band(bit32.lshift(high, 16) + low, 0xFFFFFFFF)
end

--[[
	A small deterministic hash of a string, in the range [0, 2^31).

	FNV-1a plus a final avalanche, in 32-bit integer math so it produces the same
	number on every machine and every Luau version. `math.random` would not: it is
	seeded per server, so the same player would land in different cohorts on different
	servers and the experiment would measure nothing.

	The avalanche is not decoration. Raw FNV-1a's low bits barely depend on anything
	but the last byte, so two flags bucketing `hash % 2` over the same user ids agree
	almost every time — two "independent" experiments would silently be one. Mixing
	the high bits down before returning is what makes the salt actually separate them.
]]
function FlagConfig.Hash(key: string): number
	local hash = 2166136261
	for index = 1, #key do
		hash = bit32.bxor(hash, string.byte(key, index) :: number)
		hash = mul32(hash, 16777619)
	end

	hash = bit32.bxor(hash, bit32.rshift(hash, 16))
	hash = mul32(hash, 2246822507)
	hash = bit32.bxor(hash, bit32.rshift(hash, 13))
	hash = mul32(hash, 3266489909)
	hash = bit32.bxor(hash, bit32.rshift(hash, 16))

	return bit32.band(hash, 0x7FFFFFFF)
end

--[[
	Resolves which variant a user id falls into for a flag. Pure and total: returns
	nil for a flag with no variants, and never errors.

	The salt is the flag id, so a player who lands in the first arm of one experiment
	is no more likely to land in the first arm of the next.
]]
function FlagConfig.VariantFor(flag: Flag, userId: number): Variant?
	local variants = flag.Variants
	if variants == nil or #variants == 0 then
		return nil
	end

	local total = 0
	for _, variant in variants do
		total += math.max(0, variant.Weight)
	end
	if total <= 0 then
		return nil
	end

	local bucket = FlagConfig.Hash(`{flag.Id}:{userId}`) % total
	local running = 0
	for _, variant in variants do
		running += math.max(0, variant.Weight)
		if bucket < running then
			return variant
		end
	end

	-- Unreachable while total > 0, but a fallthrough that returns the last arm is
	-- better than one that returns nil and silently drops a player into the default.
	return variants[#variants]
end

--[[
	Whether a value is usable for a flag. An override that fails this is ignored in
	favour of the default rather than being coerced — a string "false" arriving where
	a boolean was declared is a bug in the override, not an instruction.
]]
function FlagConfig.IsValidValue(flag: Flag, value: any): boolean
	if type(value) ~= flag.Kind then
		return false
	end
	if flag.Kind == "number" then
		local number = value :: number
		return number == number and number ~= math.huge and number ~= -math.huge
	end
	if flag.Kind == "string" then
		return #(value :: string) <= 64
	end
	return true
end

function FlagConfig.RunSelfTest(): { string }
	local failures: { string } = {}

	local function check(label: string, condition: boolean)
		if not condition then
			table.insert(failures, label)
		end
	end

	for _, flag in FLAGS do
		check(`"{flag.Id}" default matches its kind`, FlagConfig.IsValidValue(flag, flag.Default))
		if flag.Variants ~= nil then
			for _, variant in flag.Variants do
				check(
					`"{flag.Id}/{variant.Id}" value matches its kind`,
					FlagConfig.IsValidValue(flag, variant.Value)
				)
				check(`"{flag.Id}/{variant.Id}" has positive weight`, variant.Weight > 0)
			end
		end
		if flag.StudioValue ~= nil then
			check(`"{flag.Id}" StudioValue matches its kind`, FlagConfig.IsValidValue(flag, flag.StudioValue))
		end
	end

	-- Determinism is the whole point: same input, same answer, always.
	check("hash is stable", FlagConfig.Hash("abc") == FlagConfig.Hash("abc"))
	check("hash separates inputs", FlagConfig.Hash("abc") ~= FlagConfig.Hash("abd"))
	check("hash is non-negative", FlagConfig.Hash("abc") >= 0)

	local experiment: Flag = {
		Id = "SelfTest",
		Description = "",
		Kind = "string",
		Default = "A",
		Variants = {
			{ Id = "A", Weight = 1, Value = "A" },
			{ Id = "B", Weight = 1, Value = "B" },
		},
	}

	local first = FlagConfig.VariantFor(experiment, 12345)
	check("assignment is deterministic", first ~= nil and FlagConfig.VariantFor(experiment, 12345) == first)

	-- Distribution: an even split should be roughly even over a few thousand ids. The
	-- band is wide because this asserts "not broken", not "statistically perfect".
	local counts: { [string]: number } = { A = 0, B = 0 }
	for userId = 1, 4000 do
		local variant = FlagConfig.VariantFor(experiment, userId)
		if variant ~= nil then
			counts[variant.Id] += 1
		end
	end
	check("both arms are populated", counts.A > 1500 and counts.B > 1500)
	check("arms account for everyone", counts.A + counts.B == 4000)

	-- Two flags must not correlate, or an experiment measures the other experiment.
	local other: Flag = {
		Id = "SelfTestOther",
		Description = "",
		Kind = "string",
		Default = "A",
		Variants = experiment.Variants,
	}
	local agree = 0
	for userId = 1, 4000 do
		local a = FlagConfig.VariantFor(experiment, userId)
		local b = FlagConfig.VariantFor(other, userId)
		if a ~= nil and b ~= nil and a.Id == b.Id then
			agree += 1
		end
	end
	check("flags are independent", agree > 1600 and agree < 2400)

	local weighted: Flag = {
		Id = "SelfTestWeighted",
		Description = "",
		Kind = "number",
		Default = 0,
		Variants = {
			{ Id = "Rare", Weight = 1, Value = 1 },
			{ Id = "Common", Weight = 9, Value = 2 },
		},
	}
	local rare = 0
	for userId = 1, 4000 do
		local variant = FlagConfig.VariantFor(weighted, userId)
		if variant ~= nil and variant.Id == "Rare" then
			rare += 1
		end
	end
	check("weights are respected", rare > 250 and rare < 550)

	check("no variants means no assignment", FlagConfig.VariantFor(byId.ShopEnabled, 1) == nil)

	check("wrong type rejected", not FlagConfig.IsValidValue(byId.ShopEnabled, "true"))
	check("NaN rejected", not FlagConfig.IsValidValue(weighted, 0 / 0))
	check("inf rejected", not FlagConfig.IsValidValue(weighted, math.huge))

	return failures
end

return FlagConfig
