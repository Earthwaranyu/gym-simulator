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
}

local EffectsConfig = {}

-- Mix buses. Declared as instances in default.project.json under SoundService.
EffectsConfig.GROUPS = { "Master", "Music", "Sfx", "Ambience", "Ui" }

-- Built-in client sounds, named so the table below reads as intent rather than paths.
local CLICK = "rbxasset://sounds/switch.wav"
local PING = "rbxasset://sounds/electronicpingshort.wav"
local FANFARE = "rbxasset://sounds/victory.wav"
local LOW_SWELL = "rbxasset://sounds/bass.wav"
local STEP = "rbxasset://sounds/action_jump_land.mp3"

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
	-- Three metal variants so a long set does not turn into a metronome.
	Rep = {
		Variants = { "rbxassetid://9125672726", "rbxassetid://9125781214", "rbxassetid://9117197627" },
		Volume = 0.35,
		Pitch = 1,
		PitchJitter = 0.08,
		Spatial = true,
		RollOffMinDistance = 8,
		RollOffMaxDistance = 70,
	} :: SoundSpec,

	-- You landed a punch. The jab: fast, mid-weight, no sub.
	Hit = {
		Variants = { "rbxassetid://9116486763", "rbxassetid://9116487992", "rbxassetid://9116490515" },
		Volume = 0.6,
		Pitch = 1,
		PitchJitter = 0.1,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
	} :: SoundSpec,

	-- You took a punch.
	Hurt = {
		Variants = { "rbxassetid://9116488391", "rbxassetid://9116488211", "rbxassetid://9116488618" },
		Volume = 0.7,
		Pitch = 0.95,
		PitchJitter = 0.1,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
	} :: SoundSpec,

	-- Someone was knocked out. A body hitting the floor, with a sub under it so a KO
	-- reads as final rather than as one more hit that happened to be last.
	Knockout = {
		SoundId = "rbxassetid://9113472000",
		Volume = 0.8,
		Pitch = 1,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 160,
		Layers = {
			{ SoundId = SUB_TIGHT, Volume = 0.5, Pitch = 0.85 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- Ground Slam winding up: the crouch and the leap. Quiet and rising, so the
	-- impact that follows has somewhere to come from.
	--
	-- Named for the StrikeConfig cue rather than for the move, and that is the whole
	-- trick: VfxController plays the sound whose name matches the cue it is already
	-- drawing, so a new cue is audible the moment somebody adds a matching entry here
	-- and no wiring is needed for either half.
	SlamCharge = {
		SoundId = "rbxassetid://9120972444",
		Volume = 0.5,
		Pitch = 0.9,
		PitchJitter = 0.05,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
	} :: SoundSpec,

	-- Hard Punch winding up. Shorter and tighter than the slam's crouch.
	HeavyCharge = {
		SoundId = "rbxassetid://9120972321",
		Volume = 0.35,
		Pitch = 1.2,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 80,
	} :: SoundSpec,

	-- Ground Slam landing. The loudest thing in the game on purpose, and the fullest:
	-- concrete transient, sub, and grit thrown up by it.
	SlamImpact = {
		SoundId = "rbxassetid://9126090979",
		Volume = 1,
		Pitch = 0.85,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = 14,
		RollOffMaxDistance = 220,
		Layers = {
			{ SoundId = SUB_MID, Volume = 0.85, Pitch = 0.8 } :: SoundSpec,
			{ SoundId = "rbxassetid://9118687051", Volume = 0.45, Pitch = 1, PitchJitter = 0.12 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- Hard Punch connecting. Lower and heavier than Hit, which is the jab — the same
	-- family pitched down with a sub under it, so it reads as the same fist hitting
	-- harder rather than as a different weapon.
	HeavyHit = {
		SoundId = "rbxassetid://9116488784",
		Volume = 0.85,
		Pitch = 0.8,
		PitchJitter = 0.08,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 150,
		Layers = {
			{ SoundId = SUB_SHORT, Volume = 0.55, Pitch = 0.9 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- A guard going up.
	BlockRaise = {
		SoundId = "rbxassetid://9118269934",
		Volume = 0.55,
		Pitch = 1.15,
		PitchJitter = 0.04,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 80,
	} :: SoundSpec,

	-- A hit stopped by a guard. Jittered and varied because it can happen several
	-- times a second.
	BlockAbsorb = {
		Variants = { "rbxassetid://9116487032", "rbxassetid://9116486763" },
		Volume = 0.6,
		Pitch = 1.05,
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
	} :: SoundSpec,

	-- Coming back down. Softer than a slam landing, which is the point of both.
	FlightLanding = {
		SoundId = "rbxassetid://9126090621",
		Volume = 0.5,
		Pitch = 0.95,
		PitchJitter = 0.06,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = FAR,
	} :: SoundSpec,

	-- Crossing into top speed. Fires once per flight, so it can afford to be loud and
	-- to carry much further than a punch.
	FlightBoom = {
		SoundId = "rbxassetid://9113169432",
		Volume = 0.9,
		Pitch = 0.9,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = 20,
		RollOffMaxDistance = 400,
		Layers = {
			{ SoundId = SUB_LONG, Volume = 0.7, Pitch = 0.8 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- A foot landing. By far the most frequently played sound in the game, so it is
	-- quiet, heavily jittered, two-variant and cooldown-guarded — an unjittered footstep
	-- four times a second is the fastest way to make a game unbearable. It also has the
	-- shortest range of anything here: your own steps should not announce you across a
	-- car park.
	Footfall = {
		Variants = { STEP, "rbxassetid://9118687051" },
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
		Pitch = 1,
		PitchJitter = 0.08,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 90,
		Cooldown = 0.4,
	} :: SoundSpec,

	-- The guard shattering. Distinct from BlockAbsorb because it is the moment the
	-- player has to react to, and it must not sound like one more absorbed hit.
	BlockBreak = {
		SoundId = "rbxassetid://9116460378",
		Volume = 0.9,
		Pitch = 0.95,
		PitchJitter = 0,
		Spatial = true,
		RollOffMinDistance = NEAR,
		RollOffMaxDistance = 130,
		Layers = {
			{ SoundId = SUB_SHORT, Volume = 0.4, Pitch = 1.1 } :: SoundSpec,
		},
	} :: SoundSpec,

	-- Crossed into a new rank. On the Ui bus: this is feedback about you, not an event
	-- in the world, and it should not be quieter because you happen to be running away.
	RankUp = { SoundId = FANFARE, Volume = 0.9, Pitch = 1, PitchJitter = 0, Group = "Ui" } :: SoundSpec,

	-- Bought a multiplier or a shop item.
	Purchase = { SoundId = PING, Volume = 0.7, Pitch = 1, PitchJitter = 0, Group = "Ui" } :: SoundSpec,

	-- The character creator taking over the screen. One long low swell rather than a
	-- click, because it plays under a camera move rather than on a button.
	CustomizerReveal = {
		SoundId = LOW_SWELL,
		Volume = 0.55,
		Pitch = 0.8,
		PitchJitter = 0,
		Group = "Ui",
	} :: SoundSpec,

	-- A menu button was pressed. Quieter than anything in the world, and jittered,
	-- because this is the one sound a player can trigger as fast as they can tap.
	UiClick = { SoundId = CLICK, Volume = 0.25, Pitch = 1.1, PitchJitter = 0.05, Group = "Ui" } :: SoundSpec,
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
	end
	return failures
end

return EffectsConfig
