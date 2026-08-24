--!strict
--[[
	LightingConfig — how the world is lit and graded, as data.

	The look is the cheapest thing in the game and the loudest. Twenty-six thousand
	parts are already built, already materialled and already casting shadows; what
	decides whether they read as a city or as a toolbox is the handful of numbers in
	this file. Nothing here touches a single part.

	The direction is GTA V: desaturated, cold in the shadows and warm in the light,
	blacks that actually reach black, and haze with weight to it rather than milk. What
	this replaced was the opposite of all four — a warm, saturated, high-noon grade that
	washed distance to white and left asphalt reading as light grey.

	AtmosphereController applies this at runtime and is the authority. The Lighting
	block in default.project.json mirrors `Base` so the Studio edit view and the first
	frame of a session are not a different game; if you change one, change the other.
]]

local ZoneConfig = require(script.Parent.ZoneConfig)

export type Grade = {
	Brightness: number?,
	Contrast: number?,
	Saturation: number?,
	TintColor: Color3?,
}

export type Sky = {
	Density: number?,
	Offset: number?,
	Color: Color3?,
	Decay: Color3?,
	Glare: number?,
	Haze: number?,
}

export type Cloud = {
	Cover: number?,
	Density: number?,
	Color: Color3?,
}

export type Look = {
	Ambient: Color3?,
	OutdoorAmbient: Color3?,
	Brightness: number?,
	ClockTime: number?,
	ExposureCompensation: number?,
	ShadowSoftness: number?,
	EnvironmentDiffuseScale: number?,
	EnvironmentSpecularScale: number?,
	ColorShift_Top: Color3?,
	ColorShift_Bottom: Color3?,
	FogColor: Color3?,
	FogStart: number?,
	FogEnd: number?,
	Atmosphere: Sky?,
	ColorCorrection: Grade?,
	Bloom: { Intensity: number?, Size: number?, Threshold: number? }?,
	SunRays: { Intensity: number?, Spread: number? }?,
	Clouds: Cloud?,
}

local LightingConfig = {}

-- How long a district's look takes to bleed into the next one. Long enough that a
-- boundary is a change in the weather rather than a cut.
LightingConfig.BLEND_SECONDS = 2.5

--[[
	The house look. Everything else in this file is a deviation from it.

	`ClockTime` is late afternoon on purpose: the sun rakes across the city instead of
	dropping straight down, so every box casts a long shadow and the skyline gains the
	depth a noon sun flattens out of it. `ShadowSoftness` was never set before, which is
	why shadows read as stencils cut out of the ground rather than as light.

	The split that does most of the work: `ColorShift_Top` warm against a cold
	`OutdoorAmbient` and a cold `Ambient`. Lit faces go amber, shadowed faces go blue,
	and the eye reads the difference as sunlight.
]]
LightingConfig.Base = {
	-- Cold and dark. Shadowed faces should fall towards blue, not towards grey.
	Ambient = Color3.new(0.1, 0.1, 0.12),
	OutdoorAmbient = Color3.new(0.3, 0.31, 0.34),
	Brightness = 3.0,
	ClockTime = 15.2,
	ExposureCompensation = 0.05,
	-- Contact shadows that soften with distance from what casts them.
	ShadowSoftness = 0.35,
	EnvironmentDiffuseScale = 0.65,
	EnvironmentSpecularScale = 0.6,
	ColorShift_Top = Color3.new(1, 0.91, 0.76),
	ColorShift_Bottom = Color3.new(0.52, 0.54, 0.58),

	-- Fog backs up the atmosphere at the far plane so the skyline sits in air rather
	-- than being cut out against the sky.
	FogColor = Color3.new(0.6, 0.62, 0.65),
	FogStart = 400,
	FogEnd = 3500,

	Atmosphere = {
		Density = 0.22,
		Offset = 0.1,
		-- Grey-blue, not cream. This is the colour distance turns, and cream is what
		-- made the far buildings look like they were dissolving into paper.
		Color = Color3.new(0.72, 0.73, 0.75),
		-- Decay pulls the horizon towards dusk without touching what is near.
		Decay = Color3.new(0.55, 0.52, 0.5),
		Glare = 0.25,
		Haze = 1.4,
	},

	ColorCorrection = {
		-- Negative, and that single sign is most of the art direction. Roblox's default
		-- materials are already loud; the way to make them look filmic is to take
		-- colour away and let the light carry the image.
		Saturation = -0.12,
		Contrast = 0.12,
		Brightness = -0.01,
		TintColor = Color3.new(0.97, 0.98, 1),
	},

	Bloom = {
		Intensity = 0.45,
		Size = 22,
		-- High threshold: only genuinely bright things bloom. A low threshold is what
		-- makes a scene look like it was shot through grease.
		Threshold = 1.9,
	},

	SunRays = {
		Intensity = 0.08,
		Spread = 0.85,
	},

	Clouds = {
		Cover = 0.62,
		Density = 0.55,
		Color = Color3.new(0.79, 0.82, 0.87),
	},
}

--[[
	Per-district deviations, keyed by ZoneConfig id. Partial by design: anything left
	out is inherited from Base, so a district says only what makes it itself.

	The world already knows these places apart -- build_gym.py gives each its own ground
	material and prop kit -- but every one of them was lit identically, so a rooftop at
	altitude 430 and a beach and a quarry all sat under the same afternoon. Light is
	how a place tells you where you are before you read a single sign.
]]
LightingConfig.Zones = {
	-- Street level, downtown. The house look is this place.
	Garage = {},

	Iron = {
		Atmosphere = { Density = 0.36, Haze = 2.4 },
		ColorCorrection = { Saturation = -0.2, Contrast = 0.18 },
	},

	-- Docks: damp, flat light off the water, the sun losing its argument with the haze.
	Powerhouse = {
		OutdoorAmbient = Color3.new(0.22, 0.26, 0.32),
		Atmosphere = {
			Density = 0.42,
			Color = Color3.new(0.58, 0.63, 0.70),
			Haze = 2.8,
			Glare = 0.28,
		},
		FogEnd = 1800,
		Clouds = { Cover = 0.78, Density = 0.6, Color = Color3.new(0.7, 0.73, 0.78) },
	},

	-- Beach: the one warm district. Sand bounces light back up, so the shadows lift.
	Strongman = {
		Ambient = Color3.new(0.11, 0.10, 0.09),
		OutdoorAmbient = Color3.new(0.30, 0.28, 0.24),
		ColorShift_Bottom = Color3.new(0.58, 0.52, 0.44),
		Atmosphere = {
			Density = 0.28,
			Color = Color3.new(0.74, 0.70, 0.62),
			Decay = Color3.new(0.52, 0.44, 0.34),
			Glare = 0.5,
			Haze = 2.2,
		},
		ColorCorrection = { Saturation = -0.1, TintColor = Color3.new(1, 0.98, 0.93) },
	},

	-- Quarry: dust in the air, sun glaring off cut stone.
	Titan = {
		Brightness = 3.1,
		Atmosphere = {
			Density = 0.46,
			Color = Color3.new(0.72, 0.66, 0.56),
			Decay = Color3.new(0.5, 0.42, 0.32),
			Glare = 0.62,
			Haze = 3,
		},
		SunRays = { Intensity = 0.14 },
		ColorCorrection = { Saturation = -0.12, Contrast = 0.2 },
	},

	-- Rooftops at altitude 430: thin cold air, nothing between you and the sun.
	Skydeck = {
		Ambient = Color3.new(0.06, 0.08, 0.12),
		OutdoorAmbient = Color3.new(0.18, 0.23, 0.33),
		Brightness = 3.2,
		ExposureCompensation = 0.05,
		Atmosphere = {
			Density = 0.18,
			Color = Color3.new(0.60, 0.68, 0.80),
			Glare = 0.45,
			Haze = 1.2,
		},
		FogStart = 600,
		FogEnd = 4000,
		ColorCorrection = { Saturation = -0.2, Contrast = 0.2, TintColor = Color3.new(0.9, 0.94, 1) },
		Clouds = { Cover = 0.45, Density = 0.45 },
	},

	-- Storm: the sun has gone. Everything is ambient and cold.
	Storm = {
		Ambient = Color3.new(0.05, 0.06, 0.09),
		OutdoorAmbient = Color3.new(0.14, 0.17, 0.24),
		Brightness = 1.9,
		ClockTime = 17.6,
		ColorShift_Top = Color3.new(0.78, 0.80, 0.92),
		Atmosphere = {
			Density = 0.5,
			Color = Color3.new(0.48, 0.52, 0.60),
			Decay = Color3.new(0.24, 0.28, 0.36),
			Glare = 0.1,
			Haze = 3.2,
		},
		FogEnd = 1500,
		ColorCorrection = { Saturation = -0.26, Contrast = 0.22, Brightness = -0.03 },
		Bloom = { Intensity = 0.35 },
		SunRays = { Intensity = 0.02 },
		Clouds = { Cover = 0.92, Density = 0.75, Color = Color3.new(0.55, 0.58, 0.64) },
	},

	--[[
		The four late-game districts leave the city behind, and their taglines are
		lighting briefs on their own: "No sun reaches this far out", "Lit from
		underneath", "Nothing below but colour", "The last place there is".

		These are the places where the grade stops imitating a camera and starts doing
		the work a skybox would have done, since a skybox is an uploaded asset and this
		is not.
	]]

	-- Void: sunless. Nothing but a violet ambient and whatever the world emits itself.
	Void = {
		Ambient = Color3.new(0.05, 0.03, 0.09),
		OutdoorAmbient = Color3.new(0.10, 0.07, 0.16),
		Brightness = 0.6,
		ClockTime = 0,
		ColorShift_Top = Color3.new(0.55, 0.42, 0.80),
		ColorShift_Bottom = Color3.new(0.20, 0.14, 0.34),
		EnvironmentDiffuseScale = 0.2,
		FogColor = Color3.new(0.06, 0.04, 0.11),
		FogStart = 80,
		FogEnd = 900,
		Atmosphere = {
			Density = 0.6,
			Color = Color3.new(0.16, 0.11, 0.26),
			Decay = Color3.new(0.05, 0.03, 0.10),
			Glare = 0,
			Haze = 0.4,
		},
		ColorCorrection = { Saturation = -0.05, Contrast = 0.26, Brightness = -0.02 },
		Bloom = { Intensity = 0.9, Threshold = 1.1 },
		SunRays = { Intensity = 0 },
		Clouds = { Cover = 0, Density = 0 },
	},

	-- Solar Forge: lit from underneath, so the bounce is hotter than the sky.
	Solar = {
		Ambient = Color3.new(0.16, 0.08, 0.03),
		OutdoorAmbient = Color3.new(0.34, 0.18, 0.07),
		Brightness = 3.4,
		ExposureCompensation = 0.1,
		ColorShift_Top = Color3.new(1, 0.72, 0.42),
		ColorShift_Bottom = Color3.new(0.85, 0.42, 0.14),
		FogColor = Color3.new(0.34, 0.16, 0.07),
		FogEnd = 1600,
		Atmosphere = {
			Density = 0.44,
			Color = Color3.new(0.82, 0.52, 0.26),
			Decay = Color3.new(0.60, 0.24, 0.08),
			Glare = 0.8,
			Haze = 2.6,
		},
		ColorCorrection = { Saturation = -0.02, Contrast = 0.2, TintColor = Color3.new(1, 0.93, 0.84) },
		Bloom = { Intensity = 0.8, Threshold = 1.4 },
		SunRays = { Intensity = 0.2, Spread = 1 },
		Clouds = { Cover = 0.3, Density = 0.8, Color = Color3.new(0.85, 0.5, 0.28) },
	},

	-- Nebula Hall: nothing below but colour. The one place saturation is the point.
	Nebula = {
		Ambient = Color3.new(0.12, 0.05, 0.14),
		OutdoorAmbient = Color3.new(0.26, 0.12, 0.30),
		Brightness = 1.6,
		ClockTime = 1.5,
		ColorShift_Top = Color3.new(0.92, 0.52, 0.86),
		ColorShift_Bottom = Color3.new(0.34, 0.22, 0.62),
		FogColor = Color3.new(0.22, 0.09, 0.28),
		FogEnd = 1800,
		Atmosphere = {
			Density = 0.5,
			Color = Color3.new(0.56, 0.30, 0.62),
			Decay = Color3.new(0.28, 0.10, 0.40),
			Glare = 0.3,
			Haze = 2.4,
		},
		-- The only positive saturation in the file, and it earns it.
		ColorCorrection = { Saturation = 0.12, Contrast = 0.18 },
		Bloom = { Intensity = 1, Threshold = 1.2 },
		SunRays = { Intensity = 0.05 },
		Clouds = { Cover = 0.5, Density = 0.7, Color = Color3.new(0.62, 0.34, 0.7) },
	},

	-- Ascendant Peak: blown out and almost white. The end of the game should hurt.
	Ascendant = {
		Ambient = Color3.new(0.20, 0.19, 0.15),
		OutdoorAmbient = Color3.new(0.46, 0.44, 0.38),
		Brightness = 3.6,
		ClockTime = 6.4,
		ExposureCompensation = 0.18,
		ColorShift_Top = Color3.new(1, 0.97, 0.86),
		ColorShift_Bottom = Color3.new(0.72, 0.72, 0.70),
		FogColor = Color3.new(0.80, 0.79, 0.74),
		FogStart = 400,
		FogEnd = 3200,
		Atmosphere = {
			Density = 0.24,
			Color = Color3.new(0.88, 0.86, 0.80),
			Decay = Color3.new(0.70, 0.66, 0.58),
			Glare = 0.9,
			Haze = 1.6,
		},
		ColorCorrection = { Saturation = -0.28, Contrast = 0.12, Brightness = 0.03 },
		Bloom = { Intensity = 0.75, Threshold = 1.5 },
		SunRays = { Intensity = 0.22, Spread = 1 },
		Clouds = { Cover = 0.35, Density = 0.4, Color = Color3.new(0.95, 0.94, 0.9) },
	},
}

--[[
	Base with one district's deviations folded in.

	Two levels deep and no further, which is exactly as deep as the shape goes: a look
	is flat values plus a handful of named sub-tables, and pretending otherwise would
	buy a generic deep merge nobody needs.
]]
function LightingConfig.For(zoneId: string?): Look
	local resolved: { [string]: any } = {}
	for key, value in LightingConfig.Base :: { [string]: any } do
		if type(value) == "table" then
			resolved[key] = table.clone(value :: { [string]: any })
		else
			resolved[key] = value
		end
	end

	local overrides = if zoneId ~= nil then LightingConfig.Zones[zoneId] else nil
	if overrides == nil then
		return resolved :: any
	end

	for key, value in overrides :: { [string]: any } do
		if type(value) == "table" and type(resolved[key]) == "table" then
			for innerKey, innerValue in value :: { [string]: any } do
				resolved[key][innerKey] = innerValue
			end
		else
			resolved[key] = value
		end
	end

	return resolved :: any
end

--[[
	Every zone in ZoneConfig should have an entry here, even an empty one, so that
	adding a district is a decision about how it looks rather than a silent inheritance
	nobody noticed. Reported rather than thrown: a missing look is a flat district, not
	a broken game.
]]
function LightingConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	for _, zone in ZoneConfig.List do
		if LightingConfig.Zones[zone.Id] == nil then
			table.insert(failures, `zone "{zone.Id}" has no lighting entry`)
		end
	end
	return failures
end

return LightingConfig
