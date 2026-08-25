--!strict
--[[
	SoundCandidates — the alternates worth hearing for each slot, for the audition panel.

	## Why this file exists

	Whoever writes the audio config cannot hear it. Every sound in this game was chosen by
	reading a catalogue description, and that produced a ground slam that was a recording
	of a table falling over and a block that was a golf club hitting a pipe. Those are not
	subtle mistakes — they are obvious in half a second to anyone listening — and they
	survived two passes because nobody with ears was ever in the loop.

	So the loop closes here. `AuditionController` reads this table, plays each candidate on
	demand in Studio, and whoever is listening picks. Swapping the winner into
	`EffectsConfig` is then one line.

	## What belongs in here

	Only ids that already load, from `ProSoundEffects` or `APMOfficial` — the same rule as
	`EffectsConfig`, for the same reason. A candidate is a *plausible alternative for this
	specific slot*, not every sound that happens to be in the right category: a list of
	thirty is a list nobody auditions.

	Each entry carries a note saying what the recording actually is, because that is the
	part the name hides. "Steel Door 3" tells you nothing; "big hollow steel slam with a
	long rattling decay" tells you whether it is worth clicking.
]]

export type Candidate = {
	SoundId: string,
	-- What the recording actually is, in plain words.
	Note: string,
}

local SoundCandidates = {}

SoundCandidates.For = {
	Hit = {
		{ SoundId = "rbxassetid://9116486763", Note = "meaty thud, arm/leg block, 1.4s (current)" },
		{ SoundId = "rbxassetid://9116487992", Note = "meaty thud, body hit, 1.8s" },
		{ SoundId = "rbxassetid://9116490515", Note = "meaty thud, hit arm or leg, 1.5s" },
		{ SoundId = "rbxassetid://9116490325", Note = "meaty thud, longer tail, 2.4s" },
		{ SoundId = "rbxassetid://9116487032", Note = "meaty thud, tighter, 1.4s" },
	},

	HeavyHit = {
		{ SoundId = "rbxassetid://9116488784", Note = "meaty thud, full body, 2.2s (current)" },
		{ SoundId = "rbxassetid://9116488438", Note = "meaty thud, deepest of the family, 2.2s" },
		{ SoundId = "rbxassetid://9116488618", Note = "meaty thud, body hit, 2.0s" },
		{ SoundId = "rbxassetid://9120270688", Note = "truck hit body, metallic crash, 1.9s" },
		{ SoundId = "rbxassetid://9119630548", Note = "steel door impact, hollow, 1.9s" },
	},

	SlamImpact = {
		{
			SoundId = "rbxassetid://9119630180",
			Note = "steel door, biggest hit, long rattling decay, 2.8s (current)",
		},
		{ SoundId = "rbxassetid://9119630452", Note = "steel door, big hit, 2.1s" },
		{ SoundId = "rbxassetid://9119632199", Note = "steel door, thinner metallic slam, 2.4s" },
		{ SoundId = "rbxassetid://9120270688", Note = "truck hit body, metal crash, 1.9s" },
		{
			SoundId = "rbxassetid://9126090979",
			Note = "table falling on concrete, 2.1s — the old lead, and later a layer. Cut for clattering; kept here only to A/B against.",
		},
		{ SoundId = "rbxassetid://9125870973", Note = "rock hitting wood, crash and boards, 1.8s" },
	},

	BlockRaise = {
		{
			SoundId = "rbxassetid://9116684884",
			Note = "metal impacts, multiple hits and rattles, 2.0s (current)",
		},
		{ SoundId = "rbxassetid://9118269934", Note = "hollow metal hit, ringy, 1.1s (the old golf club)" },
		{ SoundId = "rbxassetid://9116460378", Note = "manacles, metal clangs, 1.6s" },
		{ SoundId = "rbxassetid://9117197627", Note = "pan drop, metal on wood, 1.3s" },
	},

	BlockBreak = {
		{ SoundId = "rbxassetid://9119630452", Note = "steel door, big hit with rattle, 2.1s (current)" },
		{ SoundId = "rbxassetid://9116460378", Note = "manacles, metal clangs, 1.6s (the old one)" },
		{ SoundId = "rbxassetid://9116684884", Note = "metal impacts, busy rattle, 2.0s" },
		{ SoundId = "rbxassetid://9117180053", Note = "oven door off hinges, dropped, 2.1s" },
	},

	Knockout = {
		{ SoundId = "rbxassetid://9113472000", Note = "body fall, stumble and slam, 2.1s (current)" },
		{ SoundId = "rbxassetid://9119630180", Note = "steel door, biggest slam, 2.8s" },
		{ SoundId = "rbxassetid://9116490325", Note = "meaty thud, long, 2.4s" },
	},

	FlightBoom = {
		{ SoundId = "rbxassetid://9119630452", Note = "steel door slam, pitched way down, 2.1s (current)" },
		{
			SoundId = "rbxassetid://9113169432",
			Note = "distant artillery booms, 6.8s (the old one, very long)",
		},
		{ SoundId = "rbxassetid://9119386802", Note = "deep reverberant rumble, 2.2s" },
	},

	Rep = {
		{ SoundId = "rbxassetid://9125672726", Note = "sledgehammer on an I-beam, 1.3s (current)" },
		{ SoundId = "rbxassetid://9125781214", Note = "pot clank, metal ring, 1.3s" },
		{ SoundId = "rbxassetid://9117197627", Note = "pan drop on wood, 1.3s" },
		{ SoundId = "rbxassetid://9116684884", Note = "metal impacts and rattles, 2.0s" },
	},

	UiClick = {
		{ SoundId = "rbxassetid://9118826892", Note = "scissors snap, short crisp metallic, 0.9s (current)" },
		{ SoundId = "rbxassetid://9118827270", Note = "scissors snap, driest, 0.8s" },
		{ SoundId = "rbxassetid://9118827069", Note = "scissors snap, 1.0s" },
		{ SoundId = "rbxasset://sounds/switch.wav", Note = "Roblox default click (what it used to be)" },
	},

	RankUp = {
		{ SoundId = "rbxassetid://9116684884", Note = "metal impacts rung out with reverb, 2.0s (current)" },
		{
			SoundId = "rbxassetid://9042283306",
			Note = "APM 'Jumpster' — music, only the first moment plays",
		},
		{ SoundId = "rbxasset://sounds/victory.wav", Note = "Roblox default fanfare (what it used to be)" },
	},

	Purchase = {
		{ SoundId = "rbxassetid://9118827069", Note = "scissors snap, bright, 1.0s (current)" },
		{ SoundId = "rbxassetid://9125781214", Note = "pot clank, metal ring, 1.3s" },
		{
			SoundId = "rbxasset://sounds/electronicpingshort.wav",
			Note = "Roblox default ping (what it used to be)",
		},
	},
}

--[[
	Structural checks only, and deliberately so: this module requires nothing, which is
	what lets `scripts/selftest.luau` load it under the plain `luau` CLI where
	`script.Parent` does not exist. The cross-check that every slot named here still
	exists in EffectsConfig needs both modules, so it lives in `AuditionController`, which
	legitimately has both.
]]
function SoundCandidates.RunSelfTest(): { string }
	local failures: { string } = {}

	for name, list in SoundCandidates.For :: { [string]: { Candidate } } do
		if #list < 2 then
			table.insert(failures, `{name}: fewer than two candidates is not a choice`)
		end
		for index, candidate in list do
			local id = candidate.SoundId
			if not (string.match(id, "^rbxassetid://%d+$") or string.match(id, "^rbxasset://")) then
				table.insert(failures, `{name}[{index}]: not an asset path`)
			end
			if candidate.Note == "" then
				table.insert(
					failures,
					`{name}[{index}]: a candidate with no note cannot be judged from the list`
				)
			end
		end
	end

	return failures
end

return SoundCandidates
