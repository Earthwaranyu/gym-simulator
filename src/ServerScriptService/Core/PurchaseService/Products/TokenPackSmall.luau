--!strict
--[[
	Token Pack (Small) — the reference pack. The arithmetic for all four lives here.

	Tokens are the multiplier sink, so selling them sells progress.

	TOKENS is a **Natural-quoted** figure: AwardClassScaled multiplies it by the buyer's
	physique-class TokenMultiplier (x1 at Natural through x512 at Mythic), because token
	income doubles with every class and a flat grant would decay into a rounding error
	for exactly the players most likely to buy one.

	Two identities follow, and they are the reason packs are sized in *hours* rather
	than in tokens:

	  * A pack is worth TOKENS / 4 minutes of play, at every stage of the game — 4 is
	    Formulas.TokensPerMinute() at Natural, and both sides of the comparison scale
	    with class.
	  * Multiplier costs double per level at exactly the rate class income doubles, so a
	    pack of X buys log2(X / 100 + 1) *successive* multiplier levels whether it is
	    bought by a Natural or a Mythic. 100 is TokenMultiplierConfig's first level.

	The ladder, then, is a ladder of hours:

	  Small     250 tokens    ~1.0 h saved    ~1.8 levels     49 R$
	  Medium    750 tokens    ~3.1 h saved    ~3.1 levels     99 R$
	  Large   2,000 tokens    ~8.3 h saved    ~4.4 levels    199 R$
	  Huge    5,000 tokens   ~20.8 h saved    ~5.7 levels    399 R$

	None of them is a route to the cap: one muscle costs 26.2M tokens to max and all
	five cost 131M, and those numbers do not scale with anything.

	The AssetId is the live developer product on the Roblox Creator Dashboard, with
	managed pricing off so the Robux price below is the one the buyer sees. RobuxPrice
	is only the fallback ProductInfo quotes before its first fetch lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local TOKENS = 250

local Product: Types.Product = {
	Id = "TokenPackSmall",
	Kind = "DevProduct",
	AssetId = 3709886043,
	DisplayName = "Small Token Pack",
	Description = "About one hour of training.",
	TokenGrant = TOKENS,
	RobuxPrice = 49,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardClassScaled(player, TOKENS)
	end,
}

return Product
