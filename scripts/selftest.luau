--!nocheck
--[[
	selftest — runs the pure self-tests outside Roblox.

	Formulas and NumberFormat touch no Roblox API by design, so the balance
	invariants and the number abbreviations can both be checked by the `luau` CLI
	in milliseconds instead of by opening Studio. scripts/check.sh runs this.

	Why it exists: Formulas.RunSelfTest holds the rules that keep PvP playable at
	trillion-stat scale — a maxed player cannot one-shot a beginner, time-to-kill
	does not drift as the server ages — and for a long time nothing called it at
	all. A retuned weight could break combat and no check would notice. Balance is
	the kind of thing that breaks quietly, so it wants a loud test.

	Run directly with:  luau scripts/selftest.luau
]]

local SUITES = {
	{ Name = "Formulas", Module = require("../src/ReplicatedStorage/Modules/Formulas") },
	{ Name = "NumberFormat", Module = require("../src/ReplicatedStorage/Modules/NumberFormat") },
	{ Name = "AnalyticsSchema", Module = require("../src/ReplicatedStorage/Modules/AnalyticsSchema") },
	{ Name = "FlagConfig", Module = require("../src/ReplicatedStorage/Modules/FlagConfig") },
	{ Name = "AbilityConfig", Module = require("../src/ReplicatedStorage/Modules/AbilityConfig") },
	{ Name = "PhysiqueConfig", Module = require("../src/ReplicatedStorage/Modules/PhysiqueConfig") },
	{ Name = "BodyMeshConfig", Module = require("../src/ReplicatedStorage/Modules/BodyMeshConfig") },
	{
		Name = "BodySkinConfig",
		Module = require("../src/ReplicatedStorage/Modules/BodySkinConfig"),
	},
	{
		Name = "BodyLoftConfig",
		Module = require("../src/ReplicatedStorage/Modules/BodyLoftConfig"),
	},
	{
		Name = "MuscleDefinitionConfig",
		Module = require("../src/ReplicatedStorage/Modules/MuscleDefinitionConfig"),
	},
	{ Name = "MapViewportMath", Module = require("../src/ReplicatedStorage/Modules/MapViewportMath") },
	{ Name = "WeightConfig", Module = require("../src/ReplicatedStorage/Modules/WeightConfig") },
	{ Name = "MuscleClassConfig", Module = require("../src/ReplicatedStorage/Modules/MuscleClassConfig") },
	{
		Name = "TokenMultiplierConfig",
		Module = require("../src/ReplicatedStorage/Modules/TokenMultiplierConfig"),
	},
	{ Name = "QuestCycleConfig", Module = require("../src/ReplicatedStorage/Modules/QuestCycleConfig") },
	{ Name = "EffectsConfig", Module = require("../src/ReplicatedStorage/Modules/EffectsConfig") },
	{ Name = "MusicConfig", Module = require("../src/ReplicatedStorage/Modules/MusicConfig") },
	{ Name = "SoundCandidates", Module = require("../src/ReplicatedStorage/Modules/SoundCandidates") },
	{ Name = "Migrations", Module = require("../src/ServerScriptService/Core/_Migrations") },
}

--[[
	Invariants that span two modules, and so cannot live in either.

	BodySkinConfig describes a texture and BodyLoftConfig describes a body; neither may
	require the other, because both are loaded here by the bare `luau` CLI, which has no
	ReplicatedStorage to resolve a require through. The atlas is the seam between them —
	the tubes own the u columns, the strokes are drawn inside those columns — so the one
	place able to check them against each other is here.
]]
local function crossChecks(): { string }
	local BodyLoftConfig = require("../src/ReplicatedStorage/Modules/BodyLoftConfig")
	local BodySkinConfig = require("../src/ReplicatedStorage/Modules/BodySkinConfig")
	local failures = {}

	local pixels: { [string]: number } = {}
	for _, tube in BodyLoftConfig.TUBES do
		pixels[tube.Id] = math.floor((tube.U1 - tube.U0) * BodySkinConfig.RESOLUTION)
	end

	--[[
		The fallback tone has to be the default tone.

		AppearanceConfig.Find must return *something* for an unknown id, and it used to
		return the first row of the palette. The palettes are ordered lightest-first, so
		that was Porcelain — near-white — while every new player is actually given Tan.
		Any body that failed to resolve its id therefore came out pale and looked like a
		deliberate choice. ProfileTemplate cannot be required here (it reaches for
		`script.Parent`, which the bare CLI has no answer for), so this checks the half
		it can see: that the named default is really in the palette. Keep
		DEFAULT_SKIN_ID equal to ProfileTemplate.Appearance.SkinId by hand.
	]]
	local AppearanceConfig = require("../src/ReplicatedStorage/Modules/AppearanceConfig")
	for _, case in
		{
			{ List = AppearanceConfig.SkinTones, Id = AppearanceConfig.DEFAULT_SKIN_ID, What = "skin" },
			{ List = AppearanceConfig.PantColors, Id = AppearanceConfig.DEFAULT_PANT_ID, What = "pant" },
		}
	do
		if AppearanceConfig.Find(case.List, case.Id).Id ~= case.Id then
			table.insert(failures, `the default {case.What} id "{case.Id}" is not in its own palette`)
		end
		-- And a miss must land on that default rather than on whatever is listed first.
		if AppearanceConfig.Find(case.List, "\0 not a real id").Id ~= case.Id then
			table.insert(failures, `an unknown {case.What} id does not fall back to "{case.Id}"`)
		end
	end

	for _, stroke in BodySkinConfig.STROKES do
		local column = pixels[stroke.Region]
		if column == nil then
			table.insert(failures, `{stroke.Id} draws on {stroke.Region}, which is not a tube`)
			continue
		end
		--[[
			Three pixels across, measured on the stroke's own column.

			A crease thinner than that has nowhere to put an edge and blurs, and the
			columns are wildly uneven: an arm owns a fraction of the width a torso does,
			so one flat threshold for all five regions is a threshold that is wrong for
			four of them. That is what let arm and leg definition ship as a smear.
		]]
		local across = stroke.Width * 2 * column
		if across < 3 then
			table.insert(
				failures,
				`{stroke.Id} covers {string.format("%.1f", across)} pixels of {stroke.Region}'s `
					.. `{column}-pixel column, under the three it needs to hold an edge`
			)
		end
	end
	return failures
end

local total = 0

do
	local failures = crossChecks()
	total += #failures
	if #failures == 0 then
		print("  ok    cross-module (atlas, appearance defaults)")
	else
		print(`  FAIL  cross-module (atlas, appearance defaults) ({#failures})`)
		for _, failure in failures do
			print(`          - {failure}`)
		end
	end
end

for _, suite in SUITES do
	local failures = suite.Module.RunSelfTest()
	total += #failures

	if #failures == 0 then
		print(`  ok    {suite.Name}`)
	else
		print(`  FAIL  {suite.Name} ({#failures})`)
		for _, failure in failures do
			print(`          - {failure}`)
		end
	end
end

if total > 0 then
	error(`{total} self-test failure(s)`, 0)
end
