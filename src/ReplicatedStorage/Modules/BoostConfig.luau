--!strict
--[[
	BoostConfig — the timed stat boosts, in one table both sides can read.

	The numbers used to live inside each product module, which was fine while the only
	thing that knew about a boost was the code that granted it. The HUD badge changed
	that: to draw "x2  9:41" the client has to know the multiplier and the glyph, and a
	client cannot require a ServerScriptService product module. So the description of a
	boost moved here and the product module now only says which boost it sells.

	That is also what keeps the badge open to extension. A third supplement is a row in
	this table plus a product module; HudController and BoostService do not change,
	because neither of them names a boost — they both iterate this table.

	Ids are prefixed `Shop_` because they become StatService modifier ids, which share a
	namespace with token upgrades and gamepasses.

	Colour is a UI.Palette key rather than a Color3 so the rows re-theme with everything
	else; the HUD looks it up. Glyphs are emoji for the same reason the immortality
	badge is: at 22px the drawn Icons glyphs render as bright blocks rather than
	objects, and these three badges sit side by side.
]]

export type Boost = {
	-- Multiplies every stat while it runs.
	Multiplier: number,
	-- Seconds granted per purchase. Re-buying extends rather than replaces.
	Duration: number,
	Glyph: string,
	-- A key of UI.Palette.
	Colour: string,
	DisplayName: string,
}

local Boosts: { [string]: Boost } = {
	Shop_ProteinShake = {
		Multiplier = 2,
		Duration = 600,
		Glyph = "🥤",
		Colour = "CartoonLime",
		DisplayName = "Protein Shake",
	},

	Shop_PreWorkout = {
		Multiplier = 3,
		Duration = 180,
		Glyph = "⚡",
		Colour = "Accent",
		DisplayName = "Pre-Workout",
	},
}

local BoostConfig = {
	Boosts = Boosts,
}

function BoostConfig.Get(id: string): Boost?
	return Boosts[id]
end

--[[
	The modifier id for a product id, so the product module never spells the prefix.
]]
function BoostConfig.IdFor(itemId: string): string
	return `Shop_{itemId}`
end

return BoostConfig
