--!strict
--[[
	MusicConfig — the soundtrack and the world bed, as data.

	## The shape of the score

	Two tracks and one bed, deliberately:

	  - **Explore** plays whenever nothing is trying to kill you. It is the game's theme,
	    so it has to survive hundreds of hours of grinding — which means understated. A
	    track with a hook is a track you hate by Tuesday.
	  - **Combat** takes over the moment you are in a fight and hands back a few seconds
	    after the last hit. The delay matters: without it, a scrappy exchange makes the
	    music flip back and forth every second, which reads as a bug rather than as
	    tension.
	  - **Ambience** never changes. It is a room tone, not a cue — the floor of the mix
	    that you notice only when it stops.

	The reason combat gets its own track rather than a layer is that this game's fights
	start without warning. A player locked into a machine has no idea somebody is behind
	them; the music changing *is* the warning, and a subtle layer would not be one.

	## Where the music comes from

	`APMOfficial` — APM Music, the production library Roblox licenses for use in any
	experience. Free, no attribution, cannot be DMCA'd here. Ambience is Pro Sound
	Effects. See EffectsConfig's header for why nothing comes from the community pool.

	Both tracks loop. Neither was written as a loop, so `CROSSFADE_SECONDS` is doing real
	work at the seam as well as at the switch.
]]

export type Track = {
	SoundId: string,
	-- Ceiling for this track before the player's own music slider is applied. Combat sits
	-- above explore because it is competing with the fight that triggered it.
	Volume: number,
}

local MusicConfig = {}

--[[
	How long one track takes to become another.

	Long enough that the change reads as the score responding rather than as a channel
	being switched, short enough that combat music is present for the fight that caused
	it rather than for the one after. Deliberately slower on the way out than in.
]]
MusicConfig.CROSSFADE_SECONDS = 1.6
MusicConfig.COMBAT_RELEASE_SECONDS = 6

--[[
	"Jumpster", APM / Lemoncake, Dark Trap Jamz — sub-heavy 808s, ticky hats, moody
	rather than energetic. Urban and unglamorous, which is the GTA V register the rest
	of the game is aiming at, and restrained enough to sit under a grind for hours.
]]
MusicConfig.Explore = {
	SoundId = "rbxassetid://9042283306",
	Volume = 0.7,
} :: Track

--[[
	"Eclipse", APM / MUSICA.IT, THE DARKEST HOUR — aggressive electronic and guitars
	building into rhythm. Picked over the album's other half because it has an immediate
	attack: the track has to say "you are being attacked" inside two seconds, which rules
	out anything that opens on atmosphere.
]]
MusicConfig.Combat = {
	SoundId = "rbxassetid://9042301507",
	Volume = 0.85,
} :: Track

--[[
	"Industrial Ambience, Reverberant Interior" — large machinery, distant clunks, a
	buzzer, some groans. Over three minutes long, so the loop point is rare, and it reads
	as a hard, echoing space rather than as any specific room.
]]
MusicConfig.Ambience = {
	SoundId = "rbxassetid://9114872503",
	Volume = 1,
} :: Track

function MusicConfig.RunSelfTest(): { string }
	local failures: { string } = {}

	local tracks: { [string]: Track } = {
		Explore = MusicConfig.Explore,
		Combat = MusicConfig.Combat,
		Ambience = MusicConfig.Ambience,
	}
	for name, track in tracks do
		if not string.match(track.SoundId, "^rbxassetid://%d+$") then
			table.insert(failures, `{name}: SoundId is not an rbxassetid:// path`)
		end
		if track.Volume <= 0 or track.Volume > 1 then
			table.insert(failures, `{name}: Volume must be within (0, 1]`)
		end
	end

	-- A release shorter than the crossfade means combat music would still be fading in
	-- as it started fading out, and a fight would sound like a mistake.
	if MusicConfig.COMBAT_RELEASE_SECONDS <= MusicConfig.CROSSFADE_SECONDS then
		table.insert(failures, "COMBAT_RELEASE_SECONDS must exceed CROSSFADE_SECONDS")
	end

	if MusicConfig.Combat.SoundId == MusicConfig.Explore.SoundId then
		table.insert(failures, "Combat and Explore are the same track — the switch would be inaudible")
	end

	return failures
end

return MusicConfig
