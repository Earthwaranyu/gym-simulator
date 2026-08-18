--!strict
--[[
	EffectsConfig — sound and visual presets, declared as data.

	SoundIds are intentionally left blank. Roblox asset ids have to come from real
	uploaded or Marketplace assets; inventing plausible-looking numbers would produce
	silent failures or, worse, play whatever unrelated asset happens to own that id.
	EffectsController skips any entry with an empty SoundId, so the game runs fine
	without them and starts making noise the moment you paste ids in.

	To fill these in: find a sound on the Creator Marketplace, copy its asset id, and
	set SoundId to "rbxassetid://<id>".
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
	Rep = { SoundId = "", Volume = 0.35, Pitch = 1, PitchJitter = 0.08 } :: SoundSpec,
	-- You landed a punch.
	Hit = { SoundId = "", Volume = 0.6, Pitch = 1, PitchJitter = 0.1 } :: SoundSpec,
	-- You took a punch.
	Hurt = { SoundId = "", Volume = 0.7, Pitch = 0.95, PitchJitter = 0.1 } :: SoundSpec,
	-- Someone was knocked out.
	Knockout = { SoundId = "", Volume = 0.8, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- Ground Slam winding up: the crouch and the leap. Quiet and rising, so the
	-- impact that follows has somewhere to come from.
	SlamWindup = { SoundId = "", Volume = 0.5, Pitch = 0.9, PitchJitter = 0.05 } :: SoundSpec,
	-- Ground Slam landing. The loudest thing in the game on purpose.
	SlamImpact = { SoundId = "", Volume = 1, Pitch = 0.85, PitchJitter = 0.06 } :: SoundSpec,
	-- Hard Punch connecting. Lower and heavier than Hit, which is the jab.
	HeavyHit = { SoundId = "", Volume = 0.85, Pitch = 0.8, PitchJitter = 0.08 } :: SoundSpec,
	-- A guard going up.
	BlockRaise = { SoundId = "", Volume = 0.55, Pitch = 1.15, PitchJitter = 0.04 } :: SoundSpec,
	-- A hit stopped by a guard. Jittered because it can happen several times a second.
	BlockAbsorb = { SoundId = "", Volume = 0.6, Pitch = 1.05, PitchJitter = 0.12 } :: SoundSpec,
	-- Leaving the ground.
	FlightTakeoff = { SoundId = "", Volume = 0.6, Pitch = 1.05, PitchJitter = 0.05 } :: SoundSpec,
	-- Coming back down. Softer than a slam landing, which is the point of both.
	FlightLanding = { SoundId = "", Volume = 0.5, Pitch = 0.95, PitchJitter = 0.06 } :: SoundSpec,
	-- Crossing into top speed. Fires once per flight, so it can afford to be loud.
	FlightBoom = { SoundId = "", Volume = 0.9, Pitch = 0.9, PitchJitter = 0 } :: SoundSpec,
	-- The guard shattering. Distinct from BlockAbsorb because it is the moment the
	-- player has to react to, and it must not sound like one more absorbed hit.
	BlockBreak = { SoundId = "", Volume = 0.9, Pitch = 0.95, PitchJitter = 0 } :: SoundSpec,
	-- Crossed into a new rank.
	RankUp = { SoundId = "", Volume = 0.9, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
	-- Bought a multiplier or a shop item.
	Purchase = { SoundId = "", Volume = 0.7, Pitch = 1, PitchJitter = 0 } :: SoundSpec,
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
