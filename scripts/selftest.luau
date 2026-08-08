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
}

local total = 0

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
