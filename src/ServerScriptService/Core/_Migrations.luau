--!strict
--[[
	_Migrations — ordered schema upgrades for saved profiles.

	Underscore-prefixed so the Loader skips it: this is a helper the DataService owns,
	not a system with its own lifecycle.

	Steps[n] upgrades a profile that is *at* version n to version n+1. Version 1 means
	"original schema, no migrations run", so an empty Steps list pairs with
	SCHEMA_VERSION = 1. Apply() runs every step from the profile's stored version
	upwards, so a player away for five schema versions is walked through all five.

	You only need a step when existing values must be *transformed*. Adding a brand new
	field is handled by ProfileStore:Reconcile() against ProfileTemplate — no step needed.

	To add one:
	  1. Append a function to Steps.
	  2. Set SCHEMA_VERSION in ProfileTemplate.luau to #Steps + 1.
	  3. Never edit or reorder an existing step — live saves have already run them.
]]

local Migrations = {}

-- Each entry takes the profile data table and mutates it in place.
-- Steps[1] upgrades a version-1 profile to version 2, and so on.
local Steps: { (data: any) -> () } = {
	-- v2 changes Gym Rat from counting StatChanged events to counting the amount of
	-- Power actually awarded. Old progress can be up to four times too high because
	-- manual training pays in quarter-second slices, so it cannot be converted
	-- reliably; reset only this daily and leave every other quest untouched.
	[1] = function(data)
		if type(data.QuestProgress) == "table" then
			data.QuestProgress.DailyReps = nil
		end
		if type(data.QuestCompletions) == "table" then
			data.QuestCompletions.DailyReps = nil
		end
	end,
	-- v3 turns the old unbounded doubling upgrade into ten sequential muscle
	-- classes and adds a selectable overhead title. Preserve every valid early level;
	-- cap impossible/legacy levels at the final class rather than deleting purchases.
	[2] = function(data)
		if type(data.MultiplierLevels) == "table" then
			for statId, value in data.MultiplierLevels do
				if type(value) == "number" then
					data.MultiplierLevels[statId] = math.clamp(math.floor(value), 0, 9)
				else
					data.MultiplierLevels[statId] = nil
				end
			end
		end
		if type(data.SelectedTitleId) ~= "string" then
			data.SelectedTitleId = "Newbie"
		end
	end,
	-- v4 merges the five experimental per-muscle skins into one overall physique
	-- class. Preserve the highest class previously bought so a player never loses a
	-- paid unlock; all future purchases are server-gated by every muscle stat.
	[3] = function(data)
		local migratedLevel = 0
		if type(data.MultiplierLevels) == "table" then
			for _, value in data.MultiplierLevels do
				if type(value) == "number" then
					migratedLevel = math.max(migratedLevel, math.clamp(math.floor(value), 0, 9))
				end
			end
		end
		data.MuscleClassLevel = math.max(
			if type(data.MuscleClassLevel) == "number"
				then math.clamp(math.floor(data.MuscleClassLevel), 0, 9)
				else 0,
			migratedLevel
		)
		data.MultiplierLevels = {}
	end,
	-- v5 separated physique selection from token progression. Preserve the
	-- previously purchased shared multiplier by granting that level to every muscle;
	-- the same number remains the earned physique level, so nothing visible is lost.
	[4] = function(data)
		local level = if type(data.MuscleClassLevel) == "number"
			then math.clamp(math.floor(data.MuscleClassLevel), 0, 9)
			else 0
		data.MultiplierLevels = {
			Arms = level,
			Chest = level,
			Back = level,
			Core = level,
			Legs = level,
		}
	end,
	-- v6 removes the Cash economy and replaces the fixed daily/one-shot quest log with
	-- a single repeating three-step cycle.
	--
	-- Cash has to be explicitly cleared: ProfileStore's Reconcile only *adds* missing
	-- template keys, so a removed field would otherwise ride along in every save
	-- forever. Every quest id that could appear in QuestProgress/QuestCompletions
	-- belongs to a quest that no longer exists, so both tables are dead weight rather
	-- than progress worth converting — the cycle starts everyone at step one.
	[5] = function(data)
		data.Cash = nil
		data.QuestProgress = {}
		data.QuestCompletions = nil
		data.QuestCycleIndex = 0
		data.QuestCycleLoop = 0
	end,
	-- v7 separates permanent stat power from muscle earned during the current
	-- physique. Existing players begin this visual system lean at their current
	-- totals; only training after migration changes their shape.
	[6] = function(data)
		local stats = if type(data.Stats) == "table" then data.Stats else {}
		data.PhysiqueStatBaselines = {}
		for _, statId in { "Arms", "Chest", "Back", "Core", "Legs" } do
			local value = stats[statId]
			data.PhysiqueStatBaselines[statId] = if type(value) == "number" and value == value
				then math.max(0, value)
				else 0
		end
	end,
	-- v8 adds player-chosen appearance. The field itself needs no step — Reconcile
	-- fills it from the template — but `Chosen = false` is what forces the first-join
	-- customizer, and a reconciled save arrives with exactly that. Without this step
	-- every returning player would be frozen in front of a character creator on their
	-- next join. Anyone with playtime has already had a look, so accept the one they
	-- have and let them change it from Settings if they want to.
	[7] = function(data)
		if type(data.Appearance) ~= "table" then
			return
		end
		local played = if type(data.TotalPlaytime) == "number" then data.TotalPlaytime else 0
		if played > 0 then
			data.Appearance.Chosen = true
		end
	end,
}

-- A profile that has run every step sits at this version.
Migrations.CurrentVersion = #Steps + 1

--[[
	Brings a profile up to the current schema version. Returns how many steps ran, so
	the caller can log migrations without inspecting the data itself.

	A profile stamped newer than this server knows about is left alone rather than
	downgraded, which keeps a rolled-back server from corrupting newer saves.
]]
function Migrations.Apply(data: any): number
	local from = tonumber(data.SchemaVersion) or 1
	local applied = 0

	for version = from, #Steps do
		Steps[version](data)
		applied += 1
	end

	if applied > 0 then
		data.SchemaVersion = Migrations.CurrentVersion
	end

	return applied
end

function Migrations.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	local shared = {
		SchemaVersion = 4,
		MuscleClassLevel = 6,
		MultiplierLevels = {},
	}
	check(Migrations.Apply(shared) == 4, "v4 profile runs the four outstanding migrations")
	check(shared.SchemaVersion == 8, "split migration chain stamps schema version 8")
	check(shared.MuscleClassLevel == 6, "split migration preserves selected physique")
	for _, statId in { "Arms", "Chest", "Back", "Core", "Legs" } do
		check(shared.MultiplierLevels[statId] == 6, `split migration preserves level for {statId}`)
	end

	-- A live v5 save is the common case for this release: it carries Cash and a quest
	-- log full of ids that no longer resolve to a quest module.
	-- Typed loose on purpose: the whole point of the step is that it adds keys this
	-- literal does not have, so a strict inferred shape would reject reading them back.
	local cashEra: any = {
		SchemaVersion = 5,
		Cash = 12500,
		Tokens = 40,
		FightTokens = 3,
		MuscleClassLevel = 2,
		QuestProgress = { DailyReps = 320, FirstMillion = 8000 },
		QuestCompletions = { DailyKnockouts = "2026-08-15" },
	}
	check(
		Migrations.Apply(cashEra) == 3,
		"v5 profile runs cash removal, visual baseline and appearance migrations"
	)
	check(cashEra.SchemaVersion == 8, "cash-era profile reaches schema version 8")
	check(cashEra.Cash == nil, "cash removal clears the retired currency")
	check(cashEra.Tokens == 40 and cashEra.FightTokens == 3, "cash removal keeps the surviving currencies")
	check(cashEra.MuscleClassLevel == 2, "cash removal preserves physique progress")
	check(next(cashEra.QuestProgress) == nil, "cash removal clears progress for retired quests")
	check(cashEra.QuestCompletions == nil, "cash removal drops the retired completions table")
	check(
		cashEra.QuestCycleIndex == 0 and cashEra.QuestCycleLoop == 0,
		"cash removal starts the quest cycle at step one"
	)
	check(cashEra.PhysiqueStatBaselines.Arms == 0, "missing legacy stats baseline at zero")

	local visualEra: any = {
		SchemaVersion = 6,
		Stats = { Arms = 1200, Chest = 800, Back = 400, Core = 200, Legs = 100 },
	}
	check(Migrations.Apply(visualEra) == 2, "v6 profile runs the visual baseline and appearance migrations")
	check(visualEra.SchemaVersion == 8, "visual baseline migration stamps schema version 8")
	check(visualEra.PhysiqueStatBaselines.Arms == 1200, "visual baseline preserves Arms lifetime total")
	check(visualEra.PhysiqueStatBaselines.Legs == 100, "visual baseline preserves Legs lifetime total")

	-- A profile that missed both v4 and v5 must still retain its strongest experimental
	-- per-muscle purchase when the two immutable historical steps run in sequence.
	local older = {
		SchemaVersion = 3,
		MuscleClassLevel = 1,
		MultiplierLevels = { Arms = 2, Chest = 4, Back = 3 },
	}
	check(Migrations.Apply(older) == 5, "v3 profile runs all five outstanding migrations")
	check(older.MuscleClassLevel == 4, "chained migration preserves strongest old purchase")
	for _, statId in { "Arms", "Chest", "Back", "Core", "Legs" } do
		check(older.MultiplierLevels[statId] == 4, `chained migration grants level to {statId}`)
	end

	-- The appearance gate cuts both ways, so both sides get an assertion: a save with
	-- playtime must skip the creator, and one without it must still be sent there.
	local veteran: any = {
		SchemaVersion = 7,
		TotalPlaytime = 4200,
		Appearance = {
			SkinId = "Tan",
			PantId = "Charcoal",
			HairId = "Buzz",
			FaceId = "Neutral",
			Chosen = false,
		},
	}
	check(Migrations.Apply(veteran) == 1, "v7 profile runs exactly the appearance migration")
	check(veteran.SchemaVersion == 8, "appearance migration stamps schema version 8")
	check(veteran.Appearance.Chosen, "a player with playtime is not sent back to the creator")

	local unplayed: any = {
		SchemaVersion = 7,
		TotalPlaytime = 0,
		Appearance = {
			SkinId = "Tan",
			PantId = "Charcoal",
			HairId = "Buzz",
			FaceId = "Neutral",
			Chosen = false,
		},
	}
	Migrations.Apply(unplayed)
	check(not unplayed.Appearance.Chosen, "a save with no playtime still owes a first-join pick")

	return failures
end

return Migrations
