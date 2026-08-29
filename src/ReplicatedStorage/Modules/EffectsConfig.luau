--!strict
--[[
	EffectsConfig — sound and visual presets, declared as data.

	## Where the audio comes from

	Two first-party sources, and nothing else:

	  1. **`rbxasset://sounds/...`** — sounds shipped inside every Roblox client. They
	     have no asset id, cost no download, cannot be moderated away and cannot be
	     anyone's copyright. Anything they can cover, they cover.
	  2. **Roblox's licensed catalogues** — `ProSoundEffects` (entries tagged "Courtesy of
	     Pro Sound Effects") and `APMOfficial` (APM Music). Free, no attribution, cleared
	     for use in any experience.

	The community audio pool is off-limits, and not as a formality: searching it for a
	footstep returns Half-Life 2 and CS:GO rips, and for an explosion, a clip credited to
	Santa Monica Studio. Those are someone else's copyright and they vanish when moderated.
	To add a sound, find one whose creator is Roblox, ProSoundEffects or APMOfficial, or a
	built-in `rbxasset://` path — never an unverified uploader.

	## How a sound is built

	A single file per event sounds cheap, so a `SoundSpec` supports three things beyond an
	id, each earning its place:

	  - **`Variants`** — several ids, one picked per play. Reps and footsteps fire many
	    times a second; one file machine-guns no matter how much pitch jitter it gets.
	  - **`Layers`** — sub-specs played simultaneously. A heavy impact is a transient that
	    says *contact*, a body that says *flesh and concrete*, and a sub you feel rather
	    than hear. `Layers` is what makes a slam land instead of click.
	  - **`Group`** — which mix bus it plays on. `Sfx` ducks the music automatically (the
	    compressor is declared in `default.project.json`), so a punch cuts through without
	    anything being turned up.

	`Spatial` sounds are emitted from the character that caused them rather than from the
	listener, which is what lets you hear somebody running up behind you. Everything on the
	`Ui` bus stays flat — a menu click has no position in the world.
]]

export type SoundSpec = {
	-- Exactly one of SoundId / Variants. Variants picks uniformly at random per play.
	SoundId: string?,
	Variants: { string }?,
	Volume: number,
	-- Randomised each play by ±PitchJitter, so repeated sounds do not sound looped.
	Pitch: number?,
	PitchJitter: number?,
	-- Mix bus: "Sfx" (ducks music), "Ui" (flat, never ducked) or "Ambience".
	Group: string?,
	-- Emit from the acting character instead of the listener.
	Spatial: boolean?,
	RollOffMinDistance: number?,
	RollOffMaxDistance: number?,
	-- Minimum seconds between retriggers. Guards the sounds that fire on a loop.
	Cooldown: number?,
	-- Played together with the parent, for weight the parent file does not have.
	Layers: { SoundSpec }?,
	-- DSP applied to this sound alone. See EffectsConfig.EFFECT_CLASSES.
	Effects: { EffectSpec }?,
}

--[[
	One DSP unit. `Class` is the Roblox class name without the "SoundEffect" suffix, and
	`Props` is applied verbatim, so anything the class exposes is reachable from config
	without this file growing a case per property.
]]
export type EffectSpec = {
	Class: string,
	Props: { [string]: number },
}

local EffectsConfig = {}

-- Mix buses. Declared as instances in default.project.json under SoundService.
EffectsConfig.GROUPS = { "Master", "Music", "Sfx", "Ambience", "Ui" }

--[[
	The DSP units a spec may ask for, and the whole reason this pass sounds different.

	A single recording of an ordinary object is never a convincing superhero impact, and no
	amount of searching the catalogue fixes that — Roblox's licensed library is foley
	(props, doors, vehicles, room tone), not impact design. Expensive game audio is not one
	perfect file anyway; it is ordinary recordings stacked and then *shaped*. These are the
	shaping tools, and until now the game used none of them.

	The two that do most of the work:

	  - **Distortion** adds harmonic bite. It is the difference between a thud and a hit,
	    and it is what makes a punch read as violent rather than as a dropped box.
	  - **PitchShift** drops the body of a sound *without* slowing it, which
	    `PlaybackSpeed` cannot do. A heavy punch pitched down with PlaybackSpeed also gets
	    sluggish; pitched down with this, the transient stays snappy and only the weight
	    changes — which is exactly the "same fist, hitting harder" read.

	Cost note: these are instances created per play, so they belong only on the rare, big
	moments. Anything that can fire several times a second — Footfall, Rep, UiClick,
	BlockAbsorb — must stay clean, and `RunSelfTest` enforces that rather than trusting it.
]]
EffectsConfig.EFFECT_CLASSES = {
	"Distortion",
	"Reverb",
	"PitchShift",
	"Echo",
	"Equalizer",
	"Compressor",
	"Chorus",
	"Flange",
	"Tremolo",
}

-- Sounds that fire fast enough that per-play DSP instances would be a real cost.
EffectsConfig.NO_EFFECTS_ALLOWED = {
	Footfall = true,
	Rep = true,
	UiClick = true,
	BlockAbsorb = true,
}

--[[
	Raw material, named for what it is used as rather than what it was recorded from.

	The recorded source is in the comment because it matters when swapping one out: these
	are foley recordings doing a job they were not made for, and knowing that a slam is a
	steel door is what tells you why it needs pitching down and saturating.

	The four legacy `rbxasset://sounds/` defaults that used to live here — victory.wav,
	bass.wav, electronicpingshort.wav, switch.wav — are gone. They are free and safe, but
	every Roblox player has heard them a thousand times, and nothing makes a game read as
	unfinished faster than its menu clicking like the 2010 default.
]]
local CLICK = "rbxassetid://9118826892" -- scissors snap: short, crisp, dry, metallic
local STEP = "rbxasset://sounds/action_jump_land.mp3" -- the one default worth keeping: a bare thud

-- Steel door impacts: big hits, deep hollow thuds, long rattling decay. The heaviest
-- honest impact in the catalogue and the backbone of every big moment below.
local STEEL_BIG = "rbxassetid://9119630180"
local STEEL_MID = "rbxassetid://9119630452"
local STEEL_SHORT = "rbxassetid://9119630548"
-- Metal impacts, multiple hits, rattles. Brighter and busier than the doors.
local METAL_RATTLE = "rbxassetid://9116684884"
-- Grit thrown up by an impact.
local DEBRIS = "rbxassetid://9118687051"

-- Pro Sound Effects "Rumbles" — deep, soft, reverberant booms. Never played alone; these
-- are the sub layer that gives an impact its weight.
local SUB_SHORT = "rbxassetid://9119388020"
local SUB_MID = "rbxassetid://9119387345"
local SUB_LONG = "rbxassetid://9119386802"
local SUB_TIGHT = "rbxassetid://9119386959"

-- Default rolloff for a world event. Roughly: full volume inside a machine's bay,
-- inaudible across a district.
local NEAR, FAR = 10, 120

EffectsConfig.Sounds = {
	-- An exercise motion landing. TrainingGain fires it on the completed-rep beat.
	-- Three metal variants so a long set does not turn into a metronome. No DSP: this is
	-- the second most frequent sound in the game.
	Rep = {
		Variants = { "rbxassetid://9125672726", "rbxassetid://9125781214", "rbxassetid://9117197627" },
		Volume = 0.35,
		Pitch = 1,
		PitchJitter = 0.08,
		Spatial = true,
		RollOffMinDistance = 8,
		RollOffMaxDistance = 70,
	} :: SoundSpec,

	-- M1. The jab: fast, mid-weight, no sub. A touch of distortion is what stops it
	-- sounding like a dropped bag — the bite is the violence.
	Hit = {
		Variants = { "rbxassetid://9116486763", "rbxassetid://9116487992", "rbxassetid://9116490515" },
		Volume = 0.6,
		Pitch = 1.05,
		PitchJitter = 0.1,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
		Effects = {
			{ Class = "Distortion", Props = { Level = 0.18 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- You took a punch. Duller and darker than the hit you land, so the two are
	-- distinguishable in a fast exchange without looking.
	Hurt = {
		Variants = { "rbxassetid://9116488391", "rbxassetid://9116488211", "rbxassetid://9116488618" },
		Volume = 0.7,
		Pitch = 0.95,
		PitchJitter = 0.1,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
		Effects = {
			{ Class = "Equalizer", Props = { LowGain = 2, MidGain = -3, HighGain = -8 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- Someone was knocked out. A body hitting the floor, a steel slam under it and a real
	-- reverb tail, because a KO is the end of something and should ring out rather than
	-- stop dead like one more hit that happened to be last.
	Knockout = {
		SoundId = "rbxassetid://9113472000",
		Volume = 0.8,
		Pitch = 0.92,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 160,
		Layers = {
			{ SoundId = SUB_TIGHT, Volume = 0.5, Pitch = 0.85 } :: SoundSpec,
			{ SoundId = STEEL_SHORT, Volume = 0.35, Pitch = 0.7 } :: SoundSpec,
		},
		Effects = {
			{ Class = "PitchShift", Props = { Octave = 0.75 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 1.8, WetLevel = -9, DryLevel = 0, Density = 1 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- Q, winding up: the crouch and the leap. Quiet and rising, so the impact that
	-- follows has somewhere to come from.
	--
	-- Named for the StrikeConfig cue rather than for the move, and that is the whole
	-- trick: VfxController plays the sound whose name matches the cue it is already
	-- drawing, so a new cue is audible the moment somebody adds a matching entry here
	-- and no wiring is needed for either half.
	SlamCharge = {
		SoundId = "rbxassetid://9120972444",
		Volume = 0.5,
		Pitch = 0.75,
		PitchJitter = 0.05,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
		Effects = {
			{ Class = "Reverb", Props = { DecayTime = 1.2, WetLevel = -12, DryLevel = 0 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- R, winding up. Shorter and tighter than the slam's crouch, and pitched up so the
	-- two charges are never mistaken for each other.
	HeavyCharge = {
		SoundId = "rbxassetid://9120972321",
		Volume = 0.35,
		Pitch = 1.25,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 80,
	} :: SoundSpec,

	-- Q landing. The loudest thing in the game on purpose, and the most built: a steel
	-- slam for the crack, a sub for the weight, and grit thrown up after it.
	--
	-- The lead used to be a recording of a table falling over, which is the problem with
	-- picking audio by reading descriptions. A ground slam is not a *thing falling*; it
	-- is something enormous arriving, and it needs saturation and a tail to say so.
	--
	-- That table then survived here as a LAYER for two more passes while this comment
	-- claimed it was gone, and it still read as a clatter — a table on concrete is a
	-- handful of small wooden knocks spread over two seconds, which under a steel hit
	-- adds noise with the wrong grain rather than weight. **The layer list is the thing
	-- to check**: a lead swapped without pruning what was mixed under it leaves the old
	-- sound audible and the entry looking correct.
	SlamImpact = {
		SoundId = STEEL_BIG,
		Volume = 1,
		Pitch = 0.62,
		PitchJitter = 0.05,
		Spatial = true,
		RollOffMinDistance = 14,
		RollOffMaxDistance = 220,
		Layers = {
			-- The sub carries it now that the clatter is gone. This is what a slam is
			-- actually made of; the steel above is only its transient.
			{ SoundId = SUB_MID, Volume = 1, Pitch = 0.7 } :: SoundSpec,
			-- Grit thrown up after the hit: scatter of the right kind, and a different
			-- recording from the table that was cut.
			{ SoundId = DEBRIS, Volume = 0.5, Pitch = 0.9, PitchJitter = 0.12 } :: SoundSpec,
		},
		Effects = {
			{ Class = "Distortion", Props = { Level = 0.3 } } :: EffectSpec,
			{ Class = "PitchShift", Props = { Octave = 0.5 } } :: EffectSpec,
			{
				Class = "Reverb",
				Props = { DecayTime = 2.6, WetLevel = -6, DryLevel = 0, Density = 1, Diffusion = 1 },
			} :: EffectSpec,
		},
	} :: SoundSpec,

	-- R connecting. The same fist as the jab, hitting harder — so it is the same Fight
	-- family, pitch-shifted down rather than swapped for a different sound. PitchShift
	-- rather than PlaybackSpeed keeps the transient fast while the body drops; slowing
	-- the file instead would make the heaviest punch also the sloppiest.
	HeavyHit = {
		SoundId = "rbxassetid://9116488784",
		Volume = 0.85,
		Pitch = 0.95,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 150,
		Layers = {
			{ SoundId = SUB_SHORT, Volume = 0.6, Pitch = 0.85 } :: SoundSpec,
			{ SoundId = STEEL_SHORT, Volume = 0.3, Pitch = 0.65 } :: SoundSpec,
		},
		Effects = {
			{ Class = "PitchShift", Props = { Octave = 0.7 } } :: EffectSpec,
			{ Class = "Distortion", Props = { Level = 0.32 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 1.4, WetLevel = -10, DryLevel = 0 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- F. A guard coming up: a bright metal rattle, short and high, so it reads as
	-- something being *raised* rather than something being hit.
	BlockRaise = {
		SoundId = METAL_RATTLE,
		Volume = 0.5,
		Pitch = 1.35,
		PitchJitter = 0.04,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 80,
		Effects = {
			{ Class = "Equalizer", Props = { LowGain = -12, MidGain = -2, HighGain = 3 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- A hit stopped by a guard. Can happen several times a second, so it stays clean of
	-- DSP and leans on variation and jitter instead.
	BlockAbsorb = {
		Variants = { "rbxassetid://9116487032", "rbxassetid://9116486763", METAL_RATTLE },
		Volume = 0.6,
		Pitch = 1.1,
		PitchJitter = 0.12,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 100,
	} :: SoundSpec,

	-- Leaving the ground.
	FlightTakeoff = {
		SoundId = "rbxassetid://9120972724",
		Volume = 0.6,
		Pitch = 1.05,
		PitchJitter = 0.05,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
		Effects = {
			{ Class = "Reverb", Props = { DecayTime = 1, WetLevel = -14, DryLevel = 0 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- Coming back down. Softer than a slam landing, which is the point of both.
	FlightLanding = {
		SoundId = STEEL_SHORT,
		Volume = 0.5,
		Pitch = 0.85,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
		Layers = {
			{ SoundId = DEBRIS, Volume = 0.3, Pitch = 1, PitchJitter = 0.1 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- Crossing into top speed. Fires once per flight, so it can afford to be loud and to
	-- carry much further than a punch. Rebuilt from a short transient and a deep sub: the
	-- previous 6.8s distant artillery recording read as weather, not as you breaking the
	-- sound barrier.
	FlightBoom = {
		SoundId = STEEL_MID,
		Volume = 0.85,
		Pitch = 0.55,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = 20,
		RollOffMaxDistance = 400,
		Layers = {
			{ SoundId = SUB_LONG, Volume = 0.8, Pitch = 0.6 } :: SoundSpec,
		},
		Effects = {
			{ Class = "PitchShift", Props = { Octave = 0.5 } } :: EffectSpec,
			{ Class = "Distortion", Props = { Level = 0.22 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 3, WetLevel = -8, DryLevel = 0, Density = 1 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- A foot landing. By far the most frequently played sound in the game, so it is
	-- quiet, heavily jittered, two-variant and cooldown-guarded — an unjittered footstep
	-- four times a second is the fastest way to make a game unbearable. It also has the
	-- shortest range of anything here: your own steps should not announce you across a
	-- car park. No DSP, deliberately.
	Footfall = {
		Variants = { STEP, DEBRIS },
		Volume = 0.22,
		Pitch = 1,
		PitchJitter = 0.18,
		Spatial = true,
		RollOffMinDistance = 5,
		RollOffMaxDistance = 45,
		Cooldown = 0.12,
	} :: SoundSpec,

	-- Committing to a sprint.
	SprintBurst = {
		SoundId = "rbxassetid://9120972321",
		Volume = 0.45,
		Pitch = 0.95,
		PitchJitter = 0.08,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 90,
		Cooldown = 0.4,
	} :: SoundSpec,

	-- The guard shattering. Distinct from BlockAbsorb because it is the moment the player
	-- has to react to, and it must not sound like one more absorbed hit — so it is the
	-- full steel slam with a broken, rattling tail rather than a tidy clank.
	BlockBreak = {
		SoundId = STEEL_MID,
		Volume = 0.9,
		Pitch = 0.8,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 130,
		Layers = {
			{ SoundId = METAL_RATTLE, Volume = 0.55, Pitch = 1.2 } :: SoundSpec,
			{ SoundId = SUB_SHORT, Volume = 0.4, Pitch = 1 } :: SoundSpec,
		},
		Effects = {
			{ Class = "Distortion", Props = { Level = 0.25 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 1.6, WetLevel = -8, DryLevel = 0 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- Crossed into a new rank. On the Ui bus: this is feedback about you, not an event in
	-- the world, and it should not be quieter because you happen to be running away.
	-- A bright metal hit rung out with a long reverb, which reads as an achievement
	-- without being the 2010 Roblox victory jingle.
	RankUp = {
		SoundId = METAL_RATTLE,
		Volume = 0.8,
		Pitch = 1.5,
		PitchJitter = 0,
		Group = "Ui",
		Effects = {
			{ Class = "Equalizer", Props = { LowGain = -10, MidGain = 0, HighGain = 4 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 2.4, WetLevel = -6, DryLevel = 0, Density = 1 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- Bought a multiplier or a shop item. Short, bright and final.
	Purchase = {
		SoundId = "rbxassetid://9118827069",
		Volume = 0.7,
		Pitch = 1.3,
		PitchJitter = 0,
		Group = "Ui",
		Effects = {
			{ Class = "Equalizer", Props = { LowGain = -8, MidGain = 1, HighGain = 3 } } :: EffectSpec,
			{ Class = "Reverb", Props = { DecayTime = 1.2, WetLevel = -10, DryLevel = 0 } } :: EffectSpec,
		},
	} :: SoundSpec,

	-- The character creator taking over the screen. One long low swell rather than a
	-- click, because it plays under a camera move rather than on a button.
	CustomizerReveal = {
		SoundId = SUB_LONG,
		Volume = 0.6,
		Pitch = 0.5,
		PitchJitter = 0,
		Group = "Ui",
		Effects = {
			{
				Class = "Reverb",
				Props = { DecayTime = 4, WetLevel = -4, DryLevel = -6, Density = 1, Diffusion = 1 },
			} :: EffectSpec,
		},
	} :: SoundSpec,

	-- A menu button was pressed. Quieter than anything in the world, and jittered,
	-- because this is the one sound a player can trigger as fast as they can tap. No DSP
	-- for that same reason.
	UiClick = { SoundId = CLICK, Volume = 0.22, Pitch = 1.6, PitchJitter = 0.06, Group = "Ui" } :: SoundSpec,
}

--[[
	Colour of the hit flash and impact particles. Reused for the damage number tint,
	so a single edit restyles all of it.
]]
--
-- Built through a guard because this module is also required by scripts/selftest.luau,
-- which runs under the plain `luau` CLI where no Roblox global exists. The self-tests
-- check ids, volumes and mix buses and never read a colour, so being nil out there costs
-- nothing — and it is worth the two lines to have the sound table covered by check.sh
-- rather than only by opening Studio.
local function rgb(r: number, g: number, b: number): Color3
	return if Color3 ~= nil then Color3.fromRGB(r, g, b) else nil :: any
end

EffectsConfig.HitColor = rgb(255, 138, 61)
EffectsConfig.HurtColor = rgb(255, 92, 92)

-- How long a floating damage number lives.
EffectsConfig.DAMAGE_NUMBER_SECONDS = 1.1
-- How far it drifts upward over that time.
EffectsConfig.DAMAGE_NUMBER_RISE = 4

--[[
	Checks the shape of every spec, including nested layers.

	The rules worth enforcing are the ones a human gets wrong silently: a spec with no
	id at all (plays nothing, forever, with no error), a spec with *both* an id and a
	variant list (ambiguous — which wins?), an unknown mix bus (lands on Master and never
	ducks), and an empty variant list (indexes nil at runtime, on a random frame).
]]
local function checkSpec(name: string, spec: SoundSpec, failures: { string }, depth: number)
	if depth > 2 then
		table.insert(failures, `{name}: layers nested more than two deep`)
		return
	end

	local hasId = spec.SoundId ~= nil and spec.SoundId ~= ""
	local hasVariants = spec.Variants ~= nil and #(spec.Variants :: { string }) > 0

	if spec.Variants ~= nil and #(spec.Variants :: { string }) == 0 then
		table.insert(failures, `{name}: Variants is an empty list`)
	end
	if not hasId and not hasVariants then
		table.insert(failures, `{name}: has neither SoundId nor Variants`)
	end
	if hasId and hasVariants then
		table.insert(failures, `{name}: has both SoundId and Variants — only one may win`)
	end
	if spec.Volume <= 0 then
		table.insert(failures, `{name}: Volume must be above zero`)
	end

	if spec.Group ~= nil then
		local known = false
		for _, groupName in EffectsConfig.GROUPS do
			if groupName == spec.Group then
				known = true
				break
			end
		end
		if not known then
			table.insert(failures, `{name}: unknown mix bus "{spec.Group :: string}"`)
		end
	end

	local ids: { string } = if hasVariants then spec.Variants :: { string } else { spec.SoundId :: string }
	for index, id in ids do
		if not (string.match(id, "^rbxassetid://%d+$") or string.match(id, "^rbxasset://")) then
			table.insert(failures, `{name}: id {index} is not a rbxassetid:// or rbxasset:// path`)
		end
	end

	-- A Ui sound emitted from a character would be quieter when the player walks away
	-- from their own menu, which is never what anybody means.
	if spec.Group == "Ui" and spec.Spatial == true then
		table.insert(failures, `{name}: Ui sounds cannot be Spatial`)
	end

	if spec.Effects ~= nil then
		for _, effect in spec.Effects :: { EffectSpec } do
			local known = false
			for _, className in EffectsConfig.EFFECT_CLASSES do
				if className == effect.Class then
					known = true
					break
				end
			end
			if not known then
				table.insert(failures, `{name}: unknown DSP class "{effect.Class}"`)
			end
			if next(effect.Props) == nil then
				table.insert(failures, `{name}: {effect.Class} sets no properties, so it does nothing`)
			end
		end
	end

	if spec.Layers ~= nil then
		for index, layer in spec.Layers :: { SoundSpec } do
			checkSpec(`{name}.Layers[{index}]`, layer, failures, depth + 1)
		end
	end
end

function EffectsConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	for name, spec in EffectsConfig.Sounds :: { [string]: SoundSpec } do
		checkSpec(name, spec, failures, 0)

		-- Enforced rather than trusted. Every DSP unit is an Instance created per play,
		-- and these are the sounds that fire many times a second — a chain added to one
		-- of them in a hurry would be a frame-rate bug nobody would connect to audio.
		if EffectsConfig.NO_EFFECTS_ALLOWED[name] and spec.Effects ~= nil then
			table.insert(failures, `{name}: fires too often to carry per-play DSP`)
		end
	end
	return failures
end

return EffectsConfig
