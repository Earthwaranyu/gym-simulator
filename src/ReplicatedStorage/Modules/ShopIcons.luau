--!strict
--[[
	ShopIcons — uploaded artwork that ships with the game, keyed by icon name.

	Icons.luau exists because interface art must be original, and drawing it from
	Frames guaranteed that. These images clear the same bar a different way: they
	were made for this project, like the body mesh in BodyMeshConfig, so they are
	ours to upload. Toolbox and third-party images remain off-limits.

	Only the two currencies live here. Every shop product takes its icon from the
	Creator Dashboard instead (see PurchaseService/ProductInfo), because the image is
	already attached to the product and a second copy inside the game would be a
	second thing to keep in sync.

	This is a config table, not a system. Icons.Draw consults it first and falls back
	to the drawn glyph when a key is missing or its id is 0, so an icon that has not
	been uploaded yet degrades to the shape it always had rather than rendering an
	empty square. Adding artwork is one line here and nothing else.

	  Token       skull
	  FightToken  dumbbell
]]

-- 0 means "not uploaded yet" and draws the procedural glyph instead.
local ASSETS: { [string]: number } = {
	Token = 107065365600266,
	FightToken = 106555193192680,
}

local ShopIcons = {}

ShopIcons.Assets = ASSETS

-- Returns a usable rbxassetid, or nil when the caller should draw the glyph.
function ShopIcons.Get(name: string): string?
	local id = ASSETS[name]
	if id == nil or id <= 0 then
		return nil
	end
	return `rbxassetid://{id}`
end

return ShopIcons
