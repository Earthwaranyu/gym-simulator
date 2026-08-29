--!strict
--[[
	AtmosphereController — puts LightingConfig on the screen.

	Lighting used to be eleven static lines in default.project.json, written once at
	sync and never touched again, which meant every district in the game sat under the
	same afternoon. A rooftop at altitude 430, a beach, a quarry and a sunless void were
	all lit identically, and the only thing telling them apart was the colour of the
	floor.

	This walks the player's zone and crossfades the whole lighting stack when it
	changes. Client-side on purpose: the look is a local matter, so it costs the server
	nothing and one player standing in the docks does not drag the beach into fog.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserSettings = UserSettings()

local LightingConfig = require(ReplicatedStorage.Modules.LightingConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)

-- Zone boundaries are hundreds of studs apart and the crossfade runs for seconds, so
-- nothing is gained by asking more often than this. Matches StationHighlightController's
-- cadence, which walks the same volumes.
local REFRESH_SECONDS = 0.4

-- Named so this layer can be found again. CustomizerStageController owns its own
-- separate grade, and two effects that both answered to FindFirstChildOfClass would
-- take turns overwriting each other.
local GRADE_NAME = "WorldGrade"

-- Volumetric clouds are the one thing here with a real cost on a weak device, and the
-- one thing nobody misses. Below this quality level they simply do not exist.
local CLOUD_MIN_QUALITY = Enum.SavedQualitySetting.QualityLevel5

local AtmosphereController = {
	Name = "AtmosphereController",
	Priority = 7,
}

local player = Players.LocalPlayer
local atmosphere: Atmosphere
local grade: ColorCorrectionEffect
local bloom: BloomEffect
local sunRays: SunRaysEffect
local clouds: Clouds?
local currentZoneId: string? = nil

--[[
	Finds an instance of the right class and name, or makes one.

	Rojo already writes most of these from default.project.json, and taking what is
	there rather than replacing it keeps the edit view and the running game showing the
	same scene.
]]
local function ensure<T>(className: string, name: string, parent: Instance): T
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA(className) then
		return existing :: any
	end

	local created = Instance.new(className)
	created.Name = name
	created.Parent = parent
	return created :: any
end

--[[
	Leaves exactly one of an effect in Lighting.

	The saved place file carries its own Atmosphere, Bloom and SunRays, and Rojo adds
	the ones from default.project.json beside them rather than replacing them, so a
	fresh session opens with two of each quietly stacking -- double bloom, double haze,
	and a grade applied twice. Nothing announces it; the scene is simply wrong in a way
	that reads as bad taste rather than as a bug.

	Only duplicates of what we own are touched. CustomizerStageController's own layers
	are named differently and are none of our business.
]]
local function dedupe(className: string, keep: Instance)
	for _, child in Lighting:GetChildren() do
		if child ~= keep and child.ClassName == className then
			-- Same name as ours, or the pre-rename grade this replaced.
			if child.Name == keep.Name or child.Name == "ColorCorrection" then
				child:Destroy()
			end
		end
	end
end

local function tweenTo(target: Instance, seconds: number, properties: { [string]: any })
	TweenService:Create(target, TweenInfo.new(seconds, Enum.EasingStyle.Sine), properties):Play()
end

--[[
	Whether this machine should be drawing volumetric clouds at all.

	Read once at start rather than watched: a player who changes quality mid-session is
	not owed a sky that reshapes itself around them, and the alternative is a listener
	that fires on every quality nudge for a cosmetic that costs frames.
]]
local function cloudsAllowed(): boolean
	local ok, level = pcall(function()
		return UserSettings:GetService("UserGameSettings").SavedQualityLevel
	end)
	if not ok then
		return true
	end
	-- Automatic reports as QualityLevel0 and means "decide for me", which on a machine
	-- running this game at all is a yes.
	if level == Enum.SavedQualitySetting.Automatic then
		return true
	end
	return level.Value >= CLOUD_MIN_QUALITY.Value
end

--[[
	Writes one resolved look across the whole stack.

	`seconds` of zero is the opening frame, which has to land instantly or the player
	watches the game correct its own colour on spawn.
]]
function AtmosphereController:_apply(look: any, seconds: number)
	tweenTo(Lighting, seconds, {
		Ambient = look.Ambient,
		OutdoorAmbient = look.OutdoorAmbient,
		Brightness = look.Brightness,
		ExposureCompensation = look.ExposureCompensation,
		ShadowSoftness = look.ShadowSoftness,
		EnvironmentDiffuseScale = look.EnvironmentDiffuseScale,
		EnvironmentSpecularScale = look.EnvironmentSpecularScale,
		ColorShift_Top = look.ColorShift_Top,
		ColorShift_Bottom = look.ColorShift_Bottom,
		FogColor = look.FogColor,
		FogStart = look.FogStart,
		FogEnd = look.FogEnd,
	})

	-- ClockTime is where the sun is, and tweening it drags the sun across the sky.
	-- Between the city districts it barely moves; into the Void or the Peak it is a
	-- different time of day, and watching that happen is better than a cut.
	if look.ClockTime ~= nil then
		tweenTo(Lighting, seconds, { ClockTime = look.ClockTime })
	end

	tweenTo(atmosphere, seconds, {
		Density = look.Atmosphere.Density,
		Offset = look.Atmosphere.Offset,
		Color = look.Atmosphere.Color,
		Decay = look.Atmosphere.Decay,
		Glare = look.Atmosphere.Glare,
		Haze = look.Atmosphere.Haze,
	})

	tweenTo(grade, seconds, {
		Brightness = look.ColorCorrection.Brightness,
		Contrast = look.ColorCorrection.Contrast,
		Saturation = look.ColorCorrection.Saturation,
		TintColor = look.ColorCorrection.TintColor,
	})

	tweenTo(bloom, seconds, {
		Intensity = look.Bloom.Intensity,
		Size = look.Bloom.Size,
		Threshold = look.Bloom.Threshold,
	})

	tweenTo(sunRays, seconds, {
		Intensity = look.SunRays.Intensity,
		Spread = look.SunRays.Spread,
	})

	if clouds ~= nil then
		tweenTo(clouds, seconds, {
			Cover = look.Clouds.Cover,
			Density = look.Clouds.Density,
			Color = look.Clouds.Color,
		})
	end
end

function AtmosphereController:_refresh()
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local zone = ZoneConfig.AtPosition(root.Position)
	local zoneId = if zone ~= nil then zone.Id else nil
	if zoneId == currentZoneId then
		return
	end

	currentZoneId = zoneId
	self:_apply(LightingConfig.For(zoneId), LightingConfig.BLEND_SECONDS)
end

function AtmosphereController:Init()
	atmosphere = ensure("Atmosphere", "Atmosphere", Lighting)
	grade = ensure("ColorCorrectionEffect", GRADE_NAME, Lighting)
	bloom = ensure("BloomEffect", "Bloom", Lighting)
	sunRays = ensure("SunRaysEffect", "SunRays", Lighting)

	dedupe("Atmosphere", atmosphere)
	dedupe("ColorCorrectionEffect", grade)
	dedupe("BloomEffect", bloom)
	dedupe("SunRaysEffect", sunRays)

	if cloudsAllowed() then
		clouds = ensure("Clouds", "Clouds", workspace.Terrain)
	end
end

function AtmosphereController:Start()
	-- Instant: the first frame is the one the player judges the game by.
	self:_apply(LightingConfig.For(nil), 0)

	for _, failure in LightingConfig.RunSelfTest() do
		warn(`[AtmosphereController] {failure}`)
	end

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			-- A failure in a cosmetic loop must not stop the loop.
			local ok, err = pcall(function()
				self:_refresh()
			end)
			if not ok then
				warn(`[AtmosphereController] {err}`)
			end
		end
	end)
end

return AtmosphereController
