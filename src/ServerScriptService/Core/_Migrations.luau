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
	-- v9 replaces the two on/off audio toggles with three 0-100 volumes.
	--
	-- Like Cash in v6, the old booleans have to be cleared explicitly: Reconcile only
	-- adds missing template keys, so `MusicEnabled` would ride along in every save
	-- forever and the next person to read it would reasonably assume it still meant
	-- something. An "off" toggle carries over as a zero volume, which is the same
	-- silence the player chose; an "on" toggle takes the template default rather than
	-- 100, because the authored mix has music sitting below effects and a migrating
	-- player should hear the game as designed rather than louder than everyone else.
	[8] = function(data)
		if type(data.Settings) ~= "table" then
			return
		end
		local settings = data.Settings
		settings.MasterVolume = 100
		settings.MusicVolume = if settings.MusicEnabled == false then 0 else 70
		settings.SfxVolume = if settings.SfxEnabled == false then 0 else 100
		settings.MusicEnabled = nil
		settings.SfxEnabled = nil
	end,
}

-- A profile that has run every step sits at this version.
Migrations.CurrentVersion = #Steps + 1

--[[
	Runs one step, returning the error text if it threw and nil if it did not.

	A wrapper rather than a bare `xpcall` at the call site because a step is typed as
	returning nothing, so strict mode reads `xpcall`'s arity as a single boolean and the
	error value is unreachable. Capturing it in the handler's closure sidesteps that
	without loosening the type of `Steps`.
]]
local function runStep(step: (data: any) -> (), data: any): string?
	local captured: string? = nil
	local ok = xpcall(step, function(err)
		captured = debug.traceback(tostring(err), 2)
	end, data)
	if ok then
		return nil
	end
	return captured or "unknown error"
end

--[[
	Brings a profile up to the current schema version.

	Returns `(applied, failure)` — how many steps ran, and the error from the step that
	stopped the chain if one did. A caller that gets a failure must **not** let the
	session continue: see DataService.

	Three things this guards, all of which are what a real DataStore eventually hands you
	and none of which the mock store in Studio has ever produced:

	  1. **A nonsense version.** `SchemaVersion` arrives from storage, so it can be zero,
	     negative, fractional or a string. The loop used to run `for version = from, #Steps`
	     straight off `tonumber(...)`, so a `0` or a `3.5` indexed a step that does not
	     exist and threw inside the join path. It is floored and clamped now: anything
	     below the first step means "migrate from the beginning", which is also the right
	     answer for a profile that predates versioning.

	  2. **A step that throws.** Steps run over data written by older builds, and the one
	     assumption that turns out to be wrong takes the player's whole session with it.
	     Each is isolated, and a failure stops the chain.

	  3. **Being marked done when it is not.** This is the half that matters. A profile
	     stamped at the current version with only half its steps applied is corrupt
	     *permanently* — every later join skips the steps it still needs. Leaving it
	     unstamped means the next join retries from exactly where it stopped, so a bad
	     deploy costs sessions rather than saves.

	A profile stamped newer than this server knows about is left alone rather than
	downgraded, which keeps a rolled-back server from corrupting newer saves.
]]
function Migrations.Apply(data: any): (number, string?)
	local stored = tonumber(data.SchemaVersion)
	local from = if stored ~= nil then math.floor(stored) else 1
	from = math.clamp(from, 1, #Steps + 1)

	local applied = 0

	for version = from, #Steps do
		local err = runStep(Steps[version], data)
		if err ~= nil then
			-- Deliberately not stamped: see (3) above.
			return applied, `step {version} failed: {err}`
		end
		applied += 1
	end

	if applied > 0 then
		data.SchemaVersion = Migrations.CurrentVersion
	end

	return applied, nil
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
	check(Migrations.Apply(shared) == 5, "v4 profile runs the five outstanding migrations")
	check(shared.SchemaVersion == 9, "split migration chain stamps schema version 9")
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
		Migrations.Apply(cashEra) == 4,
		"v5 profile runs cash removal, visual baseline, appearance and audio migrations"
	)
	check(cashEra.SchemaVersion == 9, "cash-era profile reaches schema version 9")
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
	check(
		Migrations.Apply(visualEra) == 3,
		"v6 profile runs the visual baseline, appearance and audio migrations"
	)
	check(visualEra.SchemaVersion == 9, "visual baseline migration stamps schema version 9")
	check(visualEra.PhysiqueStatBaselines.Arms == 1200, "visual baseline preserves Arms lifetime total")
	check(visualEra.PhysiqueStatBaselines.Legs == 100, "visual baseline preserves Legs lifetime total")

	-- A profile that missed both v4 and v5 must still retain its strongest experimental
	-- per-muscle purchase when the two immutable historical steps run in sequence.
	local older = {
		SchemaVersion = 3,
		MuscleClassLevel = 1,
		MultiplierLevels = { Arms = 2, Chest = 4, Back = 3 },
	}
	check(Migrations.Apply(older) == 6, "v3 profile runs all six outstanding migrations")
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
	check(Migrations.Apply(veteran) == 2, "v7 profile runs the appearance and audio migrations")
	check(veteran.SchemaVersion == 9, "appearance migration stamps schema version 9")
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

	-- The audio step converts two booleans into three volumes, and both sides matter: a
	-- player who muted the game must stay muted, and a player who did not must not be
	-- left at zero. Retiring the old keys is asserted too — Reconcile only adds, so a
	-- key this step forgets would ride along in every save forever.
	local muted: any = {
		SchemaVersion = 8,
		Settings = { MusicEnabled = false, SfxEnabled = false },
	}
	Migrations.Apply(muted)
	check(muted.SchemaVersion == 9, "audio migration stamps schema version 9")
	check(muted.Settings.MusicVolume == 0, "a muted soundtrack stays muted")
	check(muted.Settings.SfxVolume == 0, "muted effects stay muted")
	check(
		muted.Settings.MusicEnabled == nil and muted.Settings.SfxEnabled == nil,
		"audio migration retires the old boolean toggles"
	)

	local audible: any = {
		SchemaVersion = 8,
		Settings = { MusicEnabled = true, SfxEnabled = true },
	}
	Migrations.Apply(audible)
	check(audible.Settings.SfxVolume == 100, "effects that were on migrate to full volume")
	check(
		audible.Settings.MusicVolume > 0 and audible.Settings.MusicVolume < 100,
		"music that was on migrates to the authored mix rather than to full volume"
	)
	check(audible.Settings.MasterVolume == 100, "master starts at full for everyone")

	-- Everything below is data a real DataStore can hand back and the Studio mock store
	-- never has. Each of these used to throw inside the join path, which meant the player
	-- could not get in at all.
	-- Note the absent version is tested separately below: a trailing nil in a table
	-- literal simply shortens the array, so listing it here would silently test nothing.
	local corruptVersions: { any } = { 0, -3, 3.5, "banana" }
	for _, broken in corruptVersions do
		local corrupt: any = { SchemaVersion = broken, Settings = {} }
		local result = table.pack(pcall(Migrations.Apply, corrupt))
		check(result[1] == true, `a SchemaVersion of {tostring(broken)} does not throw`)
		if result[1] == true then
			check(result[3] == nil, `a SchemaVersion of {tostring(broken)} migrates cleanly`)
			check(result[2] > 0, `a SchemaVersion of {tostring(broken)} runs the chain from the start`)
			check(
				corrupt.SchemaVersion == Migrations.CurrentVersion,
				`a SchemaVersion of {tostring(broken)} ends up current`
			)
		end
	end

	-- A server rolled back to an older build must leave a newer save exactly as it found
	-- it rather than dragging it backwards.
	local future: any = { SchemaVersion = Migrations.CurrentVersion + 5, Tokens = 99 }
	local futureApplied, futureFailure = Migrations.Apply(future)
	check(futureApplied == 0, "a newer profile runs no steps")
	check(futureFailure == nil, "a newer profile is not an error")
	check(future.SchemaVersion == Migrations.CurrentVersion + 5, "a newer profile keeps its own version")
	check(future.Tokens == 99, "a newer profile is otherwise untouched")

	-- An already-current profile is a no-op, which is the common case on every join.
	local current: any = { SchemaVersion = Migrations.CurrentVersion }
	check(Migrations.Apply(current) == 0, "an up-to-date profile runs no steps")

	-- No SchemaVersion at all: a profile predating versioning, which must run everything.
	local ancient: any = { Settings = {} }
	local ancientResult = table.pack(pcall(Migrations.Apply, ancient))
	check(ancientResult[1] == true, "a profile with no SchemaVersion does not throw")
	if ancientResult[1] == true then
		check(ancientResult[2] == #Steps, "a profile with no SchemaVersion runs every step")
		check(ancient.SchemaVersion == Migrations.CurrentVersion, "an unversioned profile ends up current")
	end

	-- The v9 step reads data.Settings; a profile that somehow has none must survive it.
	local settingless: any = { SchemaVersion = 8 }
	local settinglessOk = pcall(Migrations.Apply, settingless)
	check(settinglessOk, "a profile with no Settings table survives the audio step")

	-- The behaviour the whole design rests on: a step that throws must stop the chain and
	-- leave the version alone, so the next join retries instead of skipping what it still
	-- owes. Asserted with a temporarily swapped step rather than by trusting the comment.
	local realStep = Steps[#Steps]
	Steps[#Steps] = function()
		error("deliberate failure")
	end
	local broken: any = { SchemaVersion = #Steps, Tokens = 7 }
	local brokenApplied, brokenFailure = Migrations.Apply(broken)
	Steps[#Steps] = realStep

	check(brokenApplied == 0, "a failing step reports that it did not run")
	check(brokenFailure ~= nil, "a failing step returns the failure to the caller")
	check(broken.SchemaVersion == #Steps, "a failing step leaves the version unstamped for a retry")
	check(broken.Tokens == 7, "a failing step does not discard the rest of the profile")

	return failures
end

return Migrations
