--!strict
--[[
	EffectsConfig — sound and visual presets, declared as data.

	Every filled SoundId comes from Roblox's own licensed library — the `ProSoundEffects`
	catalogue, whose entries carry "Courtesy of Pro Sound Effects" and are free to use in
	any experience. That is not a convenience, it is the assets rule: the community audio
	pool is full of ripped game audio (searching for a footstep returns Half-Life 2 and
	CS:GO clips; searching for an explosion returns one credited to Santa Monica Studio),
	and a moderated-away asset takes the sound with it. Verified-creator, first-party audio
	cannot do either.

	Six ids are still blank, and deliberately so rather than filled with something close
	enough: FlightBoom, Footfall, RankUp, Purchase, CustomizerReveal and UiClick. The
	licensed catalogue is a foley and impact library — it has no clean UI click, no musical
	sting and no isolated footstep, and the community results for those are exactly the
	ripped audio described above. EffectsController skips an empty SoundId, so these six
	are silent rather than broken.

	To fill one in: find a sound whose creator is Roblox or ProSoundEffects, copy its asset
	id, and set SoundId to "rbxassetid://<id>". Do not paste an id from an unverified
	uploader without checking what it actually is.
]]

export type SoundSpec = {
	SoundId: string,
	Volume: number,
	-- Randomised each play by ±PitchJitter, so repeated sounds do not sound looped.
	Pitch: number,
	PitchJitter: number,
}

local EffectsConfig = {}

EffectsConfig.Sounds = {
	-- An exercise motion landing. TrainingGain fires it on the completed-rep beat.
	Rep = { SoundId = "rbxassetid://9125672726", Volume = 0.35, Pitch = 1, PitchJitter = 0.08 } :: SoundSpec,
	-- You landed a punch.
	Hit = { SoundId = "rbxassetid://9116486763", Volume = 0.6, Pitch = 1, PitchJitter = 0.1 } :: SoundSpec,
	-- You took a punch.
	Hurt = { SoundId = "rbxassetid://9116488391", Volume = 0.7, Pitch = 0.95, PitchJitter = 0.1 } :: SoundSpec,
	-- Someone was knocked out.
	Knockout = { SoundId = "rbxassetid://9113472000", Volume = 0.8, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- Ground Slam winding up: the crouch and the leap. Quiet and rising, so the
	-- impact that follows has somewhere to come from.
	SlamWindup = { SoundId = "rbxassetid://9120972444", Volume = 0.5, Pitch = 0.9, PitchJitter = 0.05 } :: SoundSpec,
	-- Ground Slam landing. The loudest thing in the game on purpose.
	SlamImpact = { SoundId = "rbxassetid://9126090979", Volume = 1, Pitch = 0.85, PitchJitter = 0.06 } :: SoundSpec,
	-- Hard Punch connecting. Lower and heavier than Hit, which is the jab.
	HeavyHit = { SoundId = "rbxassetid://9116488784", Volume = 0.85, Pitch = 0.8, PitchJitter = 0.08 } :: SoundSpec,
	-- A guard going up.
	BlockRaise = { SoundId = "rbxassetid://9118269934", Volume = 0.55, Pitch = 1.15, PitchJitter = 0.04 } :: SoundSpec,
	-- A hit stopped by a guard. Jittered because it can happen several times a second.
	BlockAbsorb = { SoundId = "rbxassetid://9116487032", Volume = 0.6, Pitch = 1.05, PitchJitter = 0.12 } :: SoundSpec,
	-- Leaving the ground.
	FlightTakeoff = { SoundId = "rbxassetid://9120972724", Volume = 0.6, Pitch = 1.05, PitchJitter = 0.05 } :: SoundSpec,
	-- Coming back down. Softer than a slam landing, which is the point of both.
	FlightLanding = { SoundId = "rbxassetid://9126090621", Volume = 0.5, Pitch = 0.95, PitchJitter = 0.06 } :: SoundSpec,
	-- Crossing into top speed. Fires once per flight, so it can afford to be loud.
	FlightBoom = { SoundId = "", Volume = 0.9, Pitch = 0.9, PitchJitter = 0 } :: SoundSpec,
	-- A foot landing. By far the most frequently played sound in the game once ids are
	-- filled in, so it is quiet and heavily jittered — an unjittered footstep four times
	-- a second is the fastest way to make a game unbearable.
	Footfall = { SoundId = "", Volume = 0.22, Pitch = 1, PitchJitter = 0.18 } :: SoundSpec,
	-- Committing to a sprint.
	SprintBurst = { SoundId = "rbxassetid://9120972321", Volume = 0.45, Pitch = 1, PitchJitter = 0.08 } :: SoundSpec,
	-- The guard shattering. Distinct from BlockAbsorb because it is the moment the
	-- player has to react to, and it must not sound like one more absorbed hit.
	BlockBreak = { SoundId = "rbxassetid://9116460378", Volume = 0.9, Pitch = 0.95, PitchJitter = 0 } :: SoundSpec,
	-- Crossed into a new rank.
	RankUp = { SoundId = "", Volume = 0.9, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- Bought a multiplier or a shop item.
	Purchase = { SoundId = "", Volume = 0.7, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- The character creator taking over the screen. One long low swell rather than a
	-- click, because it plays under a camera move rather than on a button.
	CustomizerReveal = { SoundId = "", Volume = 0.55, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- A menu button was pressed. Quieter than anything in the world, and jittered,
	-- because this is the one sound a player can trigger as fast as they can tap.
	UiClick = { SoundId = "", Volume = 0.25, Pitch = 1.1, PitchJitter = 0.05 } :: SoundSpec,
}

--[[
	Colour of the hit flash and impact particles. Reused for the damage number tint,
	so a single edit restyles all of it.
]]
EffectsConfig.HitColor = Color3.fromRGB(255, 138, 61)
EffectsConfig.HurtColor = Color3.fromRGB(255, 92, 92)

-- How long a floating damage number lives.
EffectsConfig.DAMAGE_NUMBER_SECONDS = 1.1
-- How far it drifts upward over that time.
EffectsConfig.DAMAGE_NUMBER_RISE = 4

return EffectsConfig
