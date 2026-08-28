--!strict
--[[
	AppearanceConfig — the colours a player may paint themselves.

	Two ordered palettes, skin and shorts. Ordered because the customizer walks the
	array to build its swatch rows: adding a tone here puts a new swatch on screen and
	changes no controller (the open/closed rule this project follows for every other
	config).

	Colours live here as three numbers rather than a Color3 because the chosen **id** is
	what gets saved, and ProfileStore refuses userdata in saved data. An id also
	survives a palette retune — shifting `Tan` two shades warmer repaints everyone who
	picked it, where a stored RGB triple would freeze them at the old value forever.

	`Color` falls back to the first entry for an id it does not recognise. A palette
	entry deleted in a later release must leave the players who chose it with a body,
	not an error on every respawn.
]]

local AppearanceConfig = {}

export type Swatch = {
	Id: string,
	DisplayName: string,
	R: number,
	G: number,
	B: number,
}

-- Skin. Spread across the full range rather than clustered, because the muscle
-- silhouette is now the only other thing separating two players at a distance.
AppearanceConfig.SkinTones = {
	{ Id = "Porcelain", DisplayName = "Porcelain", R = 245, G = 220, B = 201 },
	{ Id = "Tan", DisplayName = "Tan", R = 227, G = 184, B = 149 },
	{ Id = "Olive", DisplayName = "Olive", R = 198, G = 156, B = 109 },
	{ Id = "Bronze", DisplayName = "Bronze", R = 172, G = 120, B = 78 },
	{ Id = "Umber", DisplayName = "Umber", R = 129, G = 84, B = 52 },
	{ Id = "Espresso", DisplayName = "Espresso", R = 84, G = 54, B = 36 },
	{ Id = "Ash", DisplayName = "Ash", R = 156, G = 152, B = 148 },
	{ Id = "Iron", DisplayName = "Iron", R = 96, G = 104, B = 118 },
} :: { Swatch }

-- Shorts. These paint the upper legs, which *are* the shorts on this rig — see
-- AppearanceService for why there is no separate garment part.
AppearanceConfig.PantColors = {
	{ Id = "Charcoal", DisplayName = "Charcoal", R = 38, G = 42, B = 52 },
	{ Id = "Black", DisplayName = "Black", R = 20, G = 21, B = 26 },
	{ Id = "Slate", DisplayName = "Slate", R = 78, G = 88, B = 104 },
	{ Id = "Crimson", DisplayName = "Crimson", R = 138, G = 34, B = 40 },
	{ Id = "Forest", DisplayName = "Forest", R = 42, G = 84, B = 52 },
	{ Id = "Navy", DisplayName = "Navy", R = 32, G = 52, B = 96 },
	{ Id = "Rust", DisplayName = "Rust", R = 150, G = 78, B = 30 },
	{ Id = "Bone", DisplayName = "Bone", R = 214, G = 208, B = 192 },
} :: { Swatch }

--[[
	The ids a player who has never chosen anything ends up with.

	These must stay equal to ProfileTemplate.Appearance. Stated here as well because
	Find needs a fallback and "the first row of the palette" is the wrong one: the
	palettes are ordered lightest-first, so a miss handed back Porcelain — near-white —
	and a body that failed to resolve its tone came out pale rather than the tan every
	new player is actually given. A fallback should look like the default, not like
	whichever entry happens to be listed first.
]]
AppearanceConfig.DEFAULT_SKIN_ID = "Tan"
AppearanceConfig.DEFAULT_PANT_ID = "Charcoal"

--[[
	Looks an id up in one of the palettes above. Unknown ids resolve to that palette's
	default rather than nil: every caller is painting a body that has to end up some
	colour, so there is nothing useful for them to do with a miss.
]]
function AppearanceConfig.Find(list: { Swatch }, id: string?): Swatch
	if id ~= nil then
		for _, swatch in list do
			if swatch.Id == id then
				return swatch
			end
		end
	end
	local fallback = if list == AppearanceConfig.SkinTones
		then AppearanceConfig.DEFAULT_SKIN_ID
		else AppearanceConfig.DEFAULT_PANT_ID
	for _, swatch in list do
		if swatch.Id == fallback then
			return swatch
		end
	end
	return list[1]
end

function AppearanceConfig.Color(list: { Swatch }, id: string?): Color3
	local swatch = AppearanceConfig.Find(list, id)
	return Color3.fromRGB(swatch.R, swatch.G, swatch.B)
end

--[[
	Paints a character's skin and shorts from two palette ids.

	This lives here, rather than in whichever file happens to need it, because it was
	written twice: once in AppearanceService.paint for the committed look and once in
	CustomizerController.preview for the uncommitted one. Two copies of "what a body
	looks like" is the exact shape of the bug the customizer keeps being accused of —
	the preview not matching the result — and the two copies agreeing today is not the
	same as their agreeing after the next edit to either.

	BodyColors rather than per-part Color, so a limb Roblox replaces later (a re-added
	part after a state change) still comes back right. The BodyColors instance is
	created if it is missing: BodyLoftController treats its absence as "this rig has not
	been painted yet" and will not dress a body without one.
]]
function AppearanceConfig.ApplyTo(character: Instance, skinId: string?, pantId: string?)
	local skin = AppearanceConfig.Color(AppearanceConfig.SkinTones, skinId)
	local pants = AppearanceConfig.Color(AppearanceConfig.PantColors, pantId)

	local existing = character:FindFirstChildOfClass("BodyColors")
	local colors: BodyColors
	if existing ~= nil then
		colors = existing
	else
		colors = Instance.new("BodyColors")
		colors.Parent = character
	end

	colors.HeadColor3 = skin
	colors.TorsoColor3 = skin
	colors.LeftArmColor3 = skin
	colors.RightArmColor3 = skin
	colors.LeftLegColor3 = pants
	colors.RightLegColor3 = pants

	-- BodyColors' Leg entries cover the whole leg on R15, so the lower legs have to be
	-- painted back to skin individually. That split — dark thigh, bare shin — is what
	-- makes it read as shorts rather than as trousers.
	for _, name in { "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" } do
		local part = character:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			part.Color = skin
		end
	end
end

-- Whether an id is one this palette actually offers. The server validates with this
-- before saving; `Color` is deliberately forgiving, so it cannot do that job.
function AppearanceConfig.IsValid(list: { Swatch }, id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	for _, swatch in list do
		if swatch.Id == id then
			return true
		end
	end
	return false
end

return AppearanceConfig
