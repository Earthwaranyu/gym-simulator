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
	Looks an id up in one of the palettes above. Unknown ids resolve to the first
	entry rather than nil: every caller is painting a body that has to end up some
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
	return list[1]
end

function AppearanceConfig.Color(list: { Swatch }, id: string?): Color3
	local swatch = AppearanceConfig.Find(list, id)
	return Color3.fromRGB(swatch.R, swatch.G, swatch.B)
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
