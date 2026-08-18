--!strict
--[[
	VfxConfig — world effects, declared as data.

	Before this module the game had no world effects at all. EffectsController drew
	damage numbers and played sounds; nothing in the workspace ever flashed, cracked
	or shook. That was survivable while combat was one punch, and it stopped being
	survivable the moment an ability's whole identity was "the ground breaks".

	Everything here is built at runtime from Roblox primitives — Parts, ParticleEmitters,
	Beams, Trails — and that is not a compromise, it is the project's asset rule. No
	Toolbox model, no uploaded mesh, no purchased effect pack. The same rule produced
	PoseConfig and StrikeConfig, and the same trade applies: a hand-authored effect
	would be faster to make and would not be ours.

	Structure follows StrikeConfig deliberately. An effect is a list of layered
	elements, each with its own delay and lifetime, and the layering is the technique:
	a single expanding ring reads as a Roblox tutorial, while a flash at frame one, two
	rings at different speeds, a fan of floor shards, a debris burst and a lingering
	scorch mark read as an impact. Nothing here is one big effect; everything is six
	cheap ones stacked with a few frames between them.

	Timing is in seconds from the moment the effect fires. StrikeConfig decides *when*
	that moment is, in fractions of a clip, so retiming an animation moves its effects
	with it automatically.
]]

local VfxConfig = {}

export type Easing = "Linear" | "Out" | "In" | "Snap"

--[[
	A flat ring on the ground that expands and fades. The shockwave.
]]
export type RingSpec = {
	Kind: "Ring",
	Delay: number,
	Seconds: number,
	-- Multiplied by the effect's radius, so one spec scales with a slam that grew.
	StartScale: number,
	EndScale: number,
	Thickness: number,
	Height: number,
	Color: { number },
	StartTransparency: number,
	Easing: Easing,
}

--[[
	A sphere that appears at full brightness and vanishes. The flash.
]]
export type FlashSpec = {
	Kind: "Flash",
	Delay: number,
	Seconds: number,
	StartScale: number,
	EndScale: number,
	Color: { number },
	Easing: Easing,
}

--[[
	The fractured floor: a radial fan of slabs hinged up out of the ground.

	Anchored, non-collidable and non-queryable — this is presentation, and a dozen
	unanchored slabs per slam in a six-player fight is a physics bill nobody agreed to
	pay. They tilt up, hold, settle back and fade.
]]
export type ShardSpec = {
	Kind: "Shards",
	Delay: number,
	Seconds: number,
	Count: number,
	-- Fraction of the effect radius the fan reaches.
	Spread: number,
	MinSize: Vector3,
	MaxSize: Vector3,
	-- Degrees the slabs hinge up out of the floor at their peak.
	TiltDegrees: number,
	RiseStuds: number,
	HoldFraction: number,
	-- When true, colour and material are sampled from the floor actually underfoot, so
	-- a slam on tile breaks tile and a slam on grass breaks grass. Falls back to Color.
	SampleFloor: boolean,
	Color: { number },
}

--[[
	A particle burst. Dust, sparks, debris.

	Texture is a `rbxasset://` path — a file shipped inside the Roblox client itself,
	not an upload and not a Marketplace asset. That distinction is the whole reason it
	is allowed here: the project's rule is that nothing in the game may be somebody
	else's work, and an engine-bundled texture is the engine's, the same way
	Enum.Material.ForceField is. A ParticleEmitter with no texture renders nothing at
	all, so this field is not optional in practice.
]]
export type BurstSpec = {
	Kind: "Burst",
	Delay: number,
	Seconds: number,
	Texture: string,
	Count: number,
	Speed: NumberRange,
	Size: NumberRange,
	Spread: number,
	Color: { number },
	-- Studs per second of downward drift. Positive falls, negative rises.
	Gravity: number,
	Lifetime: NumberRange,
}

--[[
	The guard dome. Deliberately NOT an element kind like the others.

	Every other effect here is a one-shot: it fires, it plays, it is collected. The
	dome is a *state* — it exists exactly as long as the button is held, which is
	anywhere from a fifth of a second to ten. Modelling it as an element meant it
	inherited an element's lifetime, and the first build shipped a barrier that
	flashed for 0.38 seconds and vanished while the guard it represented was still up.
	A state and an event are different things and the type system should say so.

	ForceField is the one material Roblox ships that already reads as an energy shield,
	and using it is what keeps this dome inside the project's asset rule — the
	alternative is a texture, and a texture is an upload. It costs the hex panelling a
	hand-authored shield would have; what it buys is a shield that is ours.
]]
--[[
	Flight contrails, and — like the guard dome — a state rather than an event.

	The same distinction that bit the block dome applies here for the same reason: a
	trail exists for as long as somebody is in the air, which is anywhere from two
	seconds to several minutes, and an element's lifetime is the wrong tool for that.
	VfxController raises these off the FlightState attribute and drops them when it
	clears, reusing the raiseGuard/dropGuard structure rather than rediscovering the
	bug that produced a barrier which flashed for a third of a second.

	Width and brightness ride the speed blend, so a hover barely wisps and a full cruise
	pulls four hard ribbons. That is most of what sells speed — a trail of constant
	width reads as decoration bolted to the character rather than as air being torn.
]]
export type ContrailSpec = {
	-- Rig parts the ribbons hang off. Missing ones are skipped, so an R6 rig quietly
	-- gets fewer trails rather than erroring.
	Attachments: { string },
	MinWidth: number,
	MaxWidth: number,
	MinLifetime: number,
	MaxLifetime: number,
	Color: { number },
	-- Colour at full speed. Interpolated toward as the blend rises, so going fast
	-- visibly heats the ribbons rather than just lengthening them.
	FastColor: { number },
	-- Blend below which no trail is drawn at all. A hovering player should not be
	-- streaming contrails while standing still in the air.
	MinBlend: number,
	CullDistance: number,
}

--[[
	Speed lines: thin streaks sliding past the camera at high speed.

	Local player only, and deliberately so — they are a camera effect rather than a
	world one, and drawing another player's speed lines around your own view would be
	nonsense. Spawned in a shell around the camera and pulled backwards relative to
	travel.
]]
export type SpeedLineSpec = {
	-- Streaks alive at full speed. Scaled down by the blend, to nothing at MinBlend.
	MaxCount: number,
	MinBlend: number,
	Length: number,
	Thickness: number,
	-- How far out from the camera they live. Inside the near plane they smear; too far
	-- and they stop reading as motion.
	MinDistance: number,
	MaxDistance: number,
	Seconds: number,
	Color: { number },
}

export type GuardSpec = {
	Radius: number,
	Color: { number },
	-- Tint the dome takes on once the meter is nearly gone, as a warning that matches
	-- the HUD meter going red. The barrier itself has to say it is about to fail;
	-- a player watching the fight is not watching the corner of their screen.
	WarnColor: { number },
	-- Set on the part, but ForceField draws its own shell and ignores it. Kept because
	-- the field is what a future non-ForceField treatment would read, and removing it
	-- would make the dome the one effect here with no opacity knob at all. Nothing
	-- should animate it — see the notes in VfxController's dropGuard and pulseGuard.
	Transparency: number,
	RaiseSeconds: number,
	DropSeconds: number,
	-- How far the dome swells when it eats a hit, and how long the pulse takes.
	PulseScale: number,
	PulseSeconds: number,
	CullDistance: number,
}

--[[
	Camera shake, with distance falloff applied by the controller.

	Only ever felt by the local player. Amplitude is in studs of camera offset, which is
	small on purpose: shake past a couple of studs stops reading as impact and starts
	reading as a bug.
]]
export type ShakeSpec = {
	Kind: "Shake",
	Delay: number,
	Seconds: number,
	Amplitude: number,
	Roughness: number,
	-- Studs past which the shake is not felt at all.
	FalloffRadius: number,
}

--[[
	The impact beat — a moment where the camera stops dead and the field of view snaps
	in and back out.

	Named for what it is doing rather than for how it does it. A true hit-stop would
	freeze the animation itself, and it cannot: the strike animations are procedural,
	driven off os.clock() in StrikeController on every client, and slowing one would
	mean the body and the server's damage timing disagreed about where in the clip
	they were. What the client owns completely is the camera, and a camera that stops
	moving for four frames while the FOV punches inward produces most of the same read
	for none of the risk.

	TimeScale is therefore how hard the camera holds — 0 is a full stop, 1 is no hold.
	Purely local: it never touches the server clock or anyone else's screen.
]]
export type HitStopSpec = {
	Kind: "HitStop",
	Delay: number,
	Seconds: number,
	TimeScale: number,
}

--[[
	A dark mark left on the floor after everything else has gone.

	A flat Part rather than an actual Decal, because a Decal has to be attached to a
	face of an existing part and the floor under a slam is not guaranteed to be one
	flat part, or to be a part this client is allowed to modify.
]]
export type ScorchSpec = {
	Kind: "Scorch",
	Delay: number,
	Seconds: number,
	FadeSeconds: number,
	Scale: number,
	Color: { number },
	StartTransparency: number,
}

--[[
	A streak that follows a moving attachment. The heavy punch's fist trail.
]]
export type TrailSpec = {
	Kind: "Trail",
	Delay: number,
	Seconds: number,
	Width: number,
	Color: { number },
	Lifetime: number,
}

--[[
	The impact frame: a ring of thin spikes in a plane facing the camera, thrown outward
	and gone in about an eighth of a second.

	The manga starburst, and the one effect here that is purely a drawing rather than a
	simulation of anything. Built from spikes because the honest alternative is a texture,
	and a texture is an upload — the same constraint that produced the ForceField dome and
	the primitive shockwave rings.

	Camera-facing on purpose. A starburst is a 2D idea; laid flat in the world it reads as
	a dinner plate from every angle except directly above.
]]
export type StarburstSpec = {
	Kind: "Starburst",
	Delay: number,
	Seconds: number,
	Count: number,
	-- Studs, from the centre outward at full expansion.
	Length: number,
	Thickness: number,
	StartScale: number,
	Color: { number },
}

export type Element =
	RingSpec
	| FlashSpec
	| ShardSpec
	| BurstSpec
	| StarburstSpec
	| ShakeSpec
	| HitStopSpec
	| ScorchSpec
	| TrailSpec

export type Effect = {
	Id: string,
	-- Fallback radius in studs, used when the firing site does not supply one. Ground
	-- Slam supplies its own, resolved from Legs.
	Radius: number,
	-- Past this distance from the camera the whole effect is skipped. A crater across
	-- the map costs the same to build as one at your feet and is worth nothing.
	CullDistance: number,
	Elements: { Element },
}

local function rgb(r: number, g: number, b: number): { number }
	return { r, g, b }
end

-- Engine-bundled particle textures. Shipped inside the Roblox client, so using them
-- breaks no asset rule — see the note on BurstSpec.Texture.
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"

-- The palette. Warm orange is the game's existing hit colour (EffectsConfig.HitColor)
-- and the slam is a heavier version of the same family, so combat reads as one system.
local IMPACT = rgb(255, 176, 64)
local IMPACT_HOT = rgb(255, 240, 210)
local HEAVY = rgb(255, 122, 72)
local DUST = rgb(168, 152, 132)
local SCORCH = rgb(38, 32, 28)
-- Flight is its own colour family. Not the warm orange of damage and not the blue of
-- the guard: flying is neither hurting somebody nor surviving them, and a contrail that
-- read as either would be misinformation in a crowded fight.
local SKY = rgb(150, 214, 255)
local SKY_HOT = rgb(236, 250, 255)
local GUARD = rgb(96, 186, 255)
local GUARD_HOT = rgb(214, 240, 255)

local effects: { Effect } = {
	--[[
		The wind-up. Its whole job is to be fair: the ring on the floor is the exact
		radius of the blast that is coming, so an opponent who runs out of it is safe
		and one who stays chose to. A telegraph that lied about its size would be worse
		than no telegraph, because the player would learn to distrust it.
	]]
	{
		Id = "SlamCharge",
		Radius = 20,
		CullDistance = 240,
		Elements = {
			-- The honest circle. Grows to full radius over the leap, so it arrives at
			-- its true size a beat before the fists do.
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.72,
				StartScale = 0.15,
				EndScale = 1,
				Thickness = 0.9,
				Height = 0.12,
				Color = IMPACT,
				StartTransparency = 0.35,
				Easing = "Out" :: "Out",
			},
			-- Dust pulled up off the floor as the charge builds. Negative gravity: it
			-- rises, which is the visual shorthand for gathering rather than scattering.
			{
				Kind = "Burst" :: "Burst",
				Delay = 0.18,
				Seconds = 0.5,
				Texture = SMOKE,
				Count = 26,
				Speed = NumberRange.new(4, 11),
				Size = NumberRange.new(0.6, 1.5),
				Spread = 26,
				Color = DUST,
				Gravity = -14,
				Lifetime = NumberRange.new(0.4, 0.8),
			},
		},
	},

	--[[
		The impact. Seven layers inside a third of a second.

		Order matters more than any single element: the hit-stop and the flash land on
		the same frame, the rings leave a beat later, the floor breaks after the rings
		have already started travelling, and the dust and scorch outlive all of it. Fired
		simultaneously it would read as one white blob.
	]]
	{
		Id = "SlamImpact",
		Radius = 20,
		CullDistance = 320,
		Elements = {
			{ Kind = "HitStop" :: "HitStop", Delay = 0, Seconds = 0.07, TimeScale = 0.18 },
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.55,
				Amplitude = 1.6,
				Roughness = 22,
				FalloffRadius = 140,
			},
			-- Three frames of white. Gone before the eye resolves it, which is why the
			-- rest of the effect looks like it emerged from something bright.
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.09,
				StartScale = 0.2,
				EndScale = 0.9,
				Color = IMPACT_HOT,
				Easing = "Snap" :: "Snap",
			},
			-- Two rings at different speeds. One ring is a ring; two travelling apart
			-- is a shockwave, because the gap between them implies the thing moving.
			{
				Kind = "Ring" :: "Ring",
				Delay = 0.02,
				Seconds = 0.34,
				StartScale = 0.1,
				EndScale = 1.15,
				Thickness = 1.8,
				Height = 0.2,
				Color = IMPACT_HOT,
				StartTransparency = 0.05,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Ring" :: "Ring",
				Delay = 0.06,
				Seconds = 0.6,
				StartScale = 0.1,
				EndScale = 1.7,
				Thickness = 0.7,
				Height = 0.1,
				Color = IMPACT,
				StartTransparency = 0.45,
				Easing = "Out" :: "Out",
			},
			-- The floor itself. Sampled from whatever is underfoot so the slam breaks
			-- the actual gym rather than a generic grey.
			{
				Kind = "Shards" :: "Shards",
				Delay = 0.03,
				Seconds = 1.5,
				-- More, smaller pieces. The first pass used fourteen slabs up to 3.4
				-- studs across, which at a twenty-stud radius is a ring of dinner
				-- plates standing on edge — legible, but reading as objects placed on
				-- the floor rather than as the floor itself coming up. Rubble wants to
				-- be numerous and small enough that no single piece is a silhouette.
				Count = 22,
				Spread = 0.8,
				MinSize = Vector3.new(0.8, 0.4, 0.8),
				MaxSize = Vector3.new(1.9, 0.7, 1.9),
				TiltDegrees = 42,
				RiseStuds = 0.7,
				HoldFraction = 0.32,
				SampleFloor = true,
				Color = rgb(96, 92, 88),
			},
			-- Debris thrown outward, and dust that hangs after it. Two bursts rather
			-- than one because they behave nothing alike: chunks are fast and fall,
			-- dust is slow and lingers, and a single emitter can only be one of those.
			{
				Kind = "Burst" :: "Burst",
				Delay = 0.02,
				Seconds = 0.9,
				Texture = SMOKE,
				Count = 26,
				Speed = NumberRange.new(26, 58),
				Size = NumberRange.new(0.3, 0.8),
				Spread = 42,
				Color = rgb(120, 112, 104),
				Gravity = 92,
				Lifetime = NumberRange.new(0.5, 1),
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0.05,
				Seconds = 1.6,
				Texture = SMOKE,
				-- Smaller and fewer than the first pass, which used forty-four
				-- particles up to seven studs wide and filled the whole screen with
				-- fog — the player could not see the thing they had just hit, which is
				-- the one thing an attack effect must never do. Dust should sit around
				-- the impact, not in front of the camera.
				Count = 26,
				Speed = NumberRange.new(8, 20),
				Size = NumberRange.new(1.5, 3.5),
				Spread = 70,
				Color = DUST,
				Gravity = -3,
				Lifetime = NumberRange.new(1.2, 2.2),
			},
			-- Outlives everything else by five seconds, which is the point: the mark on
			-- the floor is what tells somebody who arrives late that a fight happened.
			{
				Kind = "Scorch" :: "Scorch",
				Delay = 0.04,
				Seconds = 6,
				FadeSeconds = 2.5,
				Scale = 0.85,
				Color = SCORCH,
				StartTransparency = 0.35,
			},
		},
	},

	--[[
		Hard Punch's wind-up: a streak on the fist through the coil, so the arm reads as
		loaded rather than merely posed.
	]]
	{
		Id = "HeavyCharge",
		Radius = 4,
		CullDistance = 160,
		Elements = {
			{
				Kind = "Trail" :: "Trail",
				Delay = 0,
				Seconds = 0.42,
				Width = 1.6,
				Color = HEAVY,
				Lifetime = 0.22,
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0.05,
				Seconds = 0.3,
				Texture = SPARK,
				Count = 14,
				Speed = NumberRange.new(3, 9),
				Size = NumberRange.new(0.4, 0.9),
				Spread = 30,
				Color = HEAVY,
				Gravity = -6,
				Lifetime = NumberRange.new(0.2, 0.4),
			},
		},
	},

	--[[
		Hard Punch connecting. Shorter and sharper than the slam — a smaller shake, a
		faster ring, no floor damage. A heavy punch that cracked the ground would make
		the slam's crater mean nothing.
	]]
	{
		Id = "HeavyImpact",
		-- Four, not seven. At seven the flash sphere is wider than the character it is
		-- anchored to, so a punch read as an aura around the whole body rather than as
		-- something that happened at the end of an arm. An impact effect has to be
		-- smaller than the thing throwing it.
		Radius = 4,
		CullDistance = 220,
		Elements = {
			{ Kind = "HitStop" :: "HitStop", Delay = 0, Seconds = 0.05, TimeScale = 0.25 },
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.26,
				Amplitude = 0.75,
				Roughness = 30,
				FalloffRadius = 70,
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.08,
				StartScale = 0.25,
				EndScale = 1,
				Color = IMPACT_HOT,
				Easing = "Snap" :: "Snap",
			},
			-- Stood upright at the fist rather than laid on the floor: this is an
			-- impact in the air, and a ground ring would read as the slam's little
			-- brother instead of as its own move.
			{
				Kind = "Ring" :: "Ring",
				Delay = 0.01,
				Seconds = 0.22,
				StartScale = 0.15,
				EndScale = 1.3,
				Thickness = 0.5,
				Height = 0.08,
				Color = HEAVY,
				StartTransparency = 0.2,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.4,
				Texture = SPARK,
				Count = 22,
				Speed = NumberRange.new(20, 46),
				Size = NumberRange.new(0.3, 0.8),
				Spread = 55,
				Color = IMPACT,
				Gravity = 24,
				Lifetime = NumberRange.new(0.2, 0.45),
			},
		},
	},

	--[[
		The guard going up. Blue rather than orange on purpose: everything that hurts in
		this game is warm, and the one thing that protects you should not be mistakable
		for it at a glance in a crowded fight.
	]]
	{
		Id = "BlockRaise",
		Radius = 5,
		CullDistance = 180,
		Elements = {
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.3,
				StartScale = 0.3,
				EndScale = 1.2,
				Thickness = 0.4,
				Height = 0.08,
				Color = GUARD_HOT,
				StartTransparency = 0.3,
				Easing = "Out" :: "Out",
			},
		},
	},

	--[[
		A hit stopped. Has to be legible several times a second without becoming noise,
		so it is one short pulse and one small burst and nothing else — no shake, no
		hit-stop. Blocking successfully should feel calm; that is the difference between
		it and being hit.
	]]
	{
		Id = "BlockAbsorb",
		Radius = 5,
		CullDistance = 160,
		Elements = {
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.25,
				Texture = SPARK,
				Count = 12,
				Speed = NumberRange.new(12, 26),
				Size = NumberRange.new(0.3, 0.7),
				Spread = 60,
				Color = GUARD_HOT,
				Gravity = 8,
				Lifetime = NumberRange.new(0.15, 0.35),
			},
		},
	},

	--[[
		The guard shattering. This one does get a shake and a flash, because it is the
		moment the player most needs to notice — three seconds of lockout start here and
		a break they missed feels like the game stopped responding.
	]]
	{
		Id = "BlockBreak",
		Radius = 5,
		CullDistance = 200,
		Elements = {
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.35,
				Amplitude = 0.9,
				Roughness = 26,
				FalloffRadius = 40,
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.12,
				StartScale = 0.8,
				EndScale = 1.4,
				Color = GUARD_HOT,
				Easing = "Snap" :: "Snap",
			},
			-- The dome's own pieces, thrown outward. Reuses the shard element rather
			-- than inventing a "panels" one: a shard is a slab that tilts and fades, and
			-- a shattering dome is slabs that tilt and fade, so the difference is the
			-- numbers, not the mechanism.
			{
				Kind = "Shards" :: "Shards",
				Delay = 0,
				Seconds = 0.7,
				Count = 12,
				Spread = 1,
				MinSize = Vector3.new(1.2, 0.16, 1.2),
				MaxSize = Vector3.new(2.2, 0.22, 2.2),
				TiltDegrees = 70,
				RiseStuds = 2.4,
				HoldFraction = 0.1,
				SampleFloor = false,
				Color = GUARD,
			},
		},
	},
	--[[
		Leaving the ground. A ring and a dust kick under the feet — the same language as
		the slam's shockwave, deliberately, because both are "something pushed off this
		floor hard". Much smaller, and with no shards: takeoff displaces air, not
		concrete.
	]]
	{
		Id = "FlightTakeoff",
		Radius = 8,
		CullDistance = 260,
		Elements = {
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.42,
				StartScale = 0.15,
				EndScale = 1.25,
				Thickness = 0.6,
				Height = 0.12,
				Color = SKY_HOT,
				StartTransparency = 0.2,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.7,
				Texture = SMOKE,
				Count = 20,
				Speed = NumberRange.new(12, 30),
				Size = NumberRange.new(1.2, 2.8),
				Spread = 65,
				Color = DUST,
				Gravity = 10,
				Lifetime = NumberRange.new(0.4, 0.9),
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.14,
				StartScale = 0.2,
				EndScale = 0.7,
				Color = SKY_HOT,
				Easing = "Snap" :: "Snap",
			},
		},
	},

	--[[
		Coming back down. Dust and a small ring, and pointedly no shards and no scorch.

		Landing must not look like a Ground Slam. The slam earns its crater by costing a
		six-second cooldown and a second of commitment; if stepping out of the air broke
		the floor too, the crater would stop meaning anything the first time somebody
		flew across the gym.
	]]
	{
		Id = "FlightLanding",
		Radius = 7,
		CullDistance = 240,
		Elements = {
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.3,
				StartScale = 0.2,
				EndScale = 1,
				Thickness = 0.45,
				Height = 0.1,
				Color = DUST,
				StartTransparency = 0.45,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.8,
				Texture = SMOKE,
				Count = 18,
				Speed = NumberRange.new(8, 20),
				Size = NumberRange.new(1.2, 2.6),
				Spread = 72,
				Color = DUST,
				Gravity = 14,
				Lifetime = NumberRange.new(0.5, 1),
			},
		},
	},

	--[[
		Crossing into top speed. Fires once per flight, re-armed only after dropping out
		of the band, so holding full throttle does not machine-gun it.
	]]
	{
		Id = "FlightBoom",
		Radius = 9,
		CullDistance = 300,
		Elements = {
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.3,
				Amplitude = 0.7,
				Roughness = 24,
				FalloffRadius = 90,
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.12,
				StartScale = 0.3,
				EndScale = 1.6,
				Color = SKY_HOT,
				Easing = "Snap" :: "Snap",
			},
			-- Stood at the character rather than laid on the ground: this happens in
			-- open air, and a ground ring would be drawing a shockwave on a floor that
			-- may be a thousand studs below.
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.35,
				StartScale = 0.2,
				EndScale = 2,
				Thickness = 0.5,
				Height = 0.1,
				Color = SKY,
				StartTransparency = 0.25,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.5,
				Texture = SPARK,
				Count = 24,
				Speed = NumberRange.new(30, 62),
				Size = NumberRange.new(0.4, 1),
				Spread = 80,
				Color = SKY_HOT,
				Gravity = 0,
				Lifetime = NumberRange.new(0.25, 0.5),
			},
		},
	},

	--[[
		A foot landing. Deliberately the cheapest effect in this file.

		Everything else here fires a handful of times a minute; this fires up to four
		times a second for every visible character, so it is two elements, a tight cull,
		and nothing that tweens a part for long. The scuff is a flat disc rather than a
		wide ring because a ring at ankle scale reads as a bug.

		It exists at all because the gait cycle is ours: GaitConfig knows the exact phase
		at which each foot plants, so the dust lands on the frame of the footfall rather
		than on a timer drifting against a stock clip.
	]]
	{
		Id = "Footfall",
		Radius = 1.6,
		CullDistance = 120,
		Elements = {
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.35,
				Texture = SMOKE,
				Count = 5,
				Speed = NumberRange.new(2, 7),
				Size = NumberRange.new(0.5, 1.2),
				Spread = 55,
				Color = DUST,
				Gravity = 6,
				Lifetime = NumberRange.new(0.2, 0.45),
			},
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.22,
				StartScale = 0.2,
				EndScale = 1,
				Thickness = 0.22,
				Height = 0.06,
				Color = DUST,
				StartTransparency = 0.6,
				Easing = "Out" :: "Out",
			},
		},
	},

	--[[
		Hitting a full sprint. One kick as the character commits, re-armed only after
		dropping back out — the same hysteresis FlightBoom uses, and for the same reason:
		without it, sitting on the threshold retriggers it every other frame.
	]]
	{
		Id = "SprintBurst",
		Radius = 5,
		CullDistance = 180,
		Elements = {
			{
				Kind = "Ring" :: "Ring",
				Delay = 0,
				Seconds = 0.34,
				StartScale = 0.2,
				EndScale = 1.3,
				Thickness = 0.4,
				Height = 0.1,
				Color = DUST,
				StartTransparency = 0.4,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.6,
				Texture = SMOKE,
				Count = 16,
				Speed = NumberRange.new(10, 26),
				Size = NumberRange.new(1, 2.4),
				Spread = 60,
				Color = DUST,
				Gravity = 12,
				Lifetime = NumberRange.new(0.35, 0.8),
			},
		},
	},

	--[[
		A jab landing. Two elements, no shake, no flash, gone in a fifth of a second.

		This is the cheapest effect in the game and it has to be, because it is also the
		most frequent: the first contact of every combo thrown at anybody on screen. A
		light hit that shook the camera would make a fistfight unplayable, and one that
		lingered would eat the concurrency budget before the finisher it is building
		toward ever got a slot.
	]]
	{
		Id = "ImpactLight",
		Radius = 2.2,
		CullDistance = 110,
		Elements = {
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.16,
				Texture = SPARK,
				Count = 6,
				Speed = NumberRange.new(12, 24),
				Size = NumberRange.new(0.25, 0.55),
				Spread = 60,
				Color = IMPACT,
				Gravity = 18,
				Lifetime = NumberRange.new(0.12, 0.22),
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.05,
				StartScale = 0.15,
				EndScale = 0.6,
				Color = IMPACT_HOT,
				Easing = "Snap" :: "Snap",
			},
		},
	},

	--[[
		A cross landing. The first hit that touches the camera at all — a small, short
		shake, and a ring so there is something with an edge to it.
	]]
	{
		Id = "ImpactSolid",
		Radius = 3,
		CullDistance = 160,
		Elements = {
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.14,
				Amplitude = 0.28,
				Roughness = 34,
				FalloffRadius = 45,
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.07,
				StartScale = 0.2,
				EndScale = 0.9,
				Color = IMPACT_HOT,
				Easing = "Snap" :: "Snap",
			},
			{
				Kind = "Ring" :: "Ring",
				Delay = 0.01,
				Seconds = 0.18,
				StartScale = 0.15,
				EndScale = 1.1,
				Thickness = 0.35,
				Height = 0.07,
				Color = IMPACT,
				StartTransparency = 0.3,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.3,
				Texture = SPARK,
				Count = 12,
				Speed = NumberRange.new(16, 34),
				Size = NumberRange.new(0.3, 0.7),
				Spread = 58,
				Color = IMPACT,
				Gravity = 22,
				Lifetime = NumberRange.new(0.16, 0.3),
			},
		},
	},

	--[[
		The finisher, and anything else that hits like one.

		Everything the lighter two withhold, arriving at once: the impact frame, a beat of
		hit-stop, a real shake. The escalation is the whole design — a combo where all
		three contacts looked the same would be three jabs rather than a combo, and the
		reason the first two are so restrained is so that this one has somewhere to land.
	]]
	{
		Id = "ImpactCrushing",
		Radius = 4,
		CullDistance = 220,
		Elements = {
			{ Kind = "HitStop" :: "HitStop", Delay = 0, Seconds = 0.045, TimeScale = 0.3 },
			{
				Kind = "Shake" :: "Shake",
				Delay = 0,
				Seconds = 0.24,
				Amplitude = 0.62,
				Roughness = 30,
				FalloffRadius = 65,
			},
			{
				Kind = "Flash" :: "Flash",
				Delay = 0,
				Seconds = 0.08,
				StartScale = 0.25,
				EndScale = 1.1,
				Color = IMPACT_HOT,
				Easing = "Snap" :: "Snap",
			},
			{
				Kind = "Starburst" :: "Starburst",
				Delay = 0,
				Seconds = 0.13,
				Count = 9,
				Length = 4.2,
				Thickness = 0.16,
				StartScale = 0.25,
				Color = IMPACT_HOT,
			},
			{
				Kind = "Ring" :: "Ring",
				Delay = 0.01,
				Seconds = 0.22,
				StartScale = 0.15,
				EndScale = 1.4,
				Thickness = 0.45,
				Height = 0.08,
				Color = HEAVY,
				StartTransparency = 0.2,
				Easing = "Out" :: "Out",
			},
			{
				Kind = "Burst" :: "Burst",
				Delay = 0,
				Seconds = 0.35,
				Texture = SPARK,
				Count = 20,
				Speed = NumberRange.new(22, 46),
				Size = NumberRange.new(0.3, 0.8),
				Spread = 62,
				Color = IMPACT,
				Gravity = 24,
				Lifetime = NumberRange.new(0.18, 0.38),
			},
		},
	},
}

--[[
	Flight contrails and speed lines. Raised and dropped off the FlightState attribute
	by VfxController rather than fired as effects — see ContrailSpec above for why.
]]
VfxConfig.Contrail = {
	Attachments = { "RightHand", "LeftHand", "RightFoot", "LeftFoot" },
	MinWidth = 0.35,
	MaxWidth = 1.5,
	MinLifetime = 0.18,
	MaxLifetime = 0.55,
	Color = SKY,
	FastColor = SKY_HOT,
	MinBlend = 0.12,
	CullDistance = 320,
} :: ContrailSpec

VfxConfig.SpeedLines = {
	MaxCount = 22,
	MinBlend = 0.55,
	Length = 14,
	Thickness = 0.12,
	MinDistance = 14,
	MaxDistance = 42,
	Seconds = 0.34,
	Color = SKY_HOT,
} :: SpeedLineSpec

--[[
	Speed lines while sprinting on the ground.

	Flight's treatment, turned well down. Running fast is not flying fast, and reusing
	the flight numbers made a sprint across the gym look like a takeoff — so it gets its
	own table even though the controller code is shared.
]]
VfxConfig.SprintLines = {
	MaxCount = 10,
	MinBlend = 0.75,
	Length = 9,
	Thickness = 0.09,
	MinDistance = 10,
	MaxDistance = 28,
	Seconds = 0.28,
	Color = rgb(226, 220, 208),
} :: SpeedLineSpec

--[[
	The guard dome, raised and dropped off the Blocking attribute rather than fired as an
	effect. See GuardSpec above for why it is not one.
]]
VfxConfig.Guard = {
	Radius = 3.6,
	Color = GUARD,
	WarnColor = rgb(255, 120, 96),
	Transparency = 0.72,
	RaiseSeconds = 0.18,
	DropSeconds = 0.14,
	PulseScale = 0.14,
	PulseSeconds = 0.22,
	CullDistance = 200,
} :: GuardSpec

VfxConfig.List = effects

local byId: { [string]: Effect } = {}
for _, effect in effects do
	if byId[effect.Id] ~= nil then
		error(`[VfxConfig] Duplicate effect id "{effect.Id}"`)
	end
	byId[effect.Id] = effect
end

function VfxConfig.Get(effectId: string): Effect?
	return byId[effectId]
end

--[[
	Total lifetime of an effect, in seconds — the last moment any of its elements is
	still on screen. VfxController uses it to know when a pooled effect can be reclaimed
	without walking its parts.
]]
function VfxConfig.Duration(effect: Effect): number
	local longest = 0
	for _, element in effect.Elements do
		longest = math.max(longest, element.Delay + element.Seconds)
	end
	return longest
end

--[[
	How long an effect occupies a slot in the controller's concurrency budget.

	Not the same as Duration, and the difference matters. A slam's scorch mark lingers
	for six seconds, so budgeting by Duration would let twelve slams in six seconds
	exhaust the budget and start silently dropping effects — while the things actually
	being counted were twelve motionless flat parts costing nothing to keep on screen.

	A scorch is therefore excluded. Everything else — the tweens, the emitters, the
	fourteen tweening slabs — is work the frame is doing, and is what the budget is
	protecting.
]]
function VfxConfig.BusyDuration(effect: Effect): number
	local longest = 0
	for _, element in effect.Elements do
		if element.Kind ~= "Scorch" then
			longest = math.max(longest, element.Delay + element.Seconds)
		end
	end
	return longest
end

return VfxConfig
