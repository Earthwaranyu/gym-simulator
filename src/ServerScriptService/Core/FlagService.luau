--!strict
--[[
	FlagService — resolves feature flags and experiment cohorts, server-side only.

	The server is the only place a flag is decided. Clients receive the *resolved
	values* for their own player and nothing else: no flag table, no other player's
	cohort, and no way to ask for a different answer. A client that ignores what it
	was sent changes only its own presentation, because every consumer that matters
	reads the flag here rather than trusting what the client renders.

	Three layers, in order of precedence:

	  1. **Kill switch** — `Killed` in FlagConfig, or a live override setting the flag
	     to its default. Always resolves to the safe default. This is the layer that
	     has to work at 3am, so it is the simplest one.
	  2. **Live override** — a typed attribute on the `FlagOverrides` Configuration in
	     ReplicatedStorage, editable in a running server without a deploy. Wrong type,
	     unknown flag, or a non-finite number is ignored in favour of the default,
	     never coerced.
	  3. **Cohort** — the deterministic assignment from FlagConfig. Same player, same
	     answer, on every server forever.

	Studio adds one more: `StudioValue` wins over everything except the kill switch, so
	a developer can exercise either arm without rolling a new account. It is ignored on
	live servers by construction — `RunService:IsStudio()` is not something a client
	can assert.

	Exposure is logged once per player per flag, and only when a consumer actually
	reads the flag. Logging assignment instead of exposure counts players who never
	reached the feature, which quietly dilutes every experiment result toward zero.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local FlagConfig = require(ReplicatedStorage.Modules.FlagConfig)

local OVERRIDES_NAME = "FlagOverrides"

local FlagService = {
	Name = "FlagService",
	-- Early: other services read flags during their own Init.
	Priority = 5,
}

local overrides: Configuration
local resolved: { [Player]: { [string]: any } } = {}
local exposed: { [Player]: { [string]: boolean } } = {}
local AnalyticsService: any = nil

--[[
	Reads the live override for a flag, or nil when there is none worth honouring.
]]
local function overrideFor(flag: FlagConfig.Flag): any?
	local value = overrides:GetAttribute(flag.Id)
	if value == nil then
		return nil
	end
	if not FlagConfig.IsValidValue(flag, value) then
		warn(`[FlagService] Ignoring override for "{flag.Id}": wrong type or value`)
		return nil
	end
	return value
end

--[[
	Resolves one flag for one player, with no side effects.
]]
local function resolve(flag: FlagConfig.Flag, userId: number): any
	if flag.Killed then
		return flag.Default
	end

	if RunService:IsStudio() and flag.StudioValue ~= nil then
		return flag.StudioValue
	end

	local override = overrideFor(flag)
	if override ~= nil then
		return override
	end

	local variant = FlagConfig.VariantFor(flag, userId)
	if variant ~= nil then
		return variant.Value
	end

	return flag.Default
end

local function resolveAll(player: Player)
	local values: { [string]: any } = {}
	for _, flag in FlagConfig.FLAGS do
		values[flag.Id] = resolve(flag, player.UserId)
	end
	resolved[player] = values

	-- The client is told the outcome so it can render the right thing, never the
	-- rules that produced it.
	Net.Event("FlagsChanged"):FireClient(player, values)
end

function FlagService:Init()
	local existing = ReplicatedStorage:FindFirstChild(OVERRIDES_NAME)
	if existing ~= nil and existing:IsA("Configuration") then
		overrides = existing
	else
		local created = Instance.new("Configuration")
		created.Name = OVERRIDES_NAME
		created.Parent = ReplicatedStorage
		overrides = created
	end

	local failures = FlagConfig.RunSelfTest()
	for _, failure in failures do
		warn(`[FlagService] flag self-test failed: {failure}`)
	end

	-- An override changed under a running server. Every player is re-resolved, which
	-- is the whole point of the layer: a bad feature is turned off without a deploy
	-- and without kicking anyone.
	overrides.AttributeChanged:Connect(function(attribute: string)
		if FlagConfig.Get(attribute) == nil then
			warn(`[FlagService] Override set for unknown flag "{attribute}"`)
			return
		end
		for _, player in Players:GetPlayers() do
			resolveAll(player)
		end
	end)
end

--[[
	The resolved value of a flag for a player, and the call that counts as exposure.

	Always returns something usable: an unknown flag id, a player whose values are not
	resolved yet, or any other surprise falls back to the declared default.
]]
function FlagService:Get(player: Player, flagId: string): any
	local flag = FlagConfig.Get(flagId)
	if flag == nil then
		warn(`[FlagService] Unknown flag "{flagId}"`)
		return nil
	end

	local values = resolved[player]
	local value = if values ~= nil then values[flagId] else nil
	if value == nil then
		value = resolve(flag, player.UserId)
	end

	self:_logExposure(player, flag, value)
	return value
end

--[[
	Reads a flag without counting it as exposure. For code that needs the value to
	decide whether to *offer* something the player has not seen yet.
]]
function FlagService:Peek(player: Player, flagId: string): any
	local flag = FlagConfig.Get(flagId)
	if flag == nil then
		return nil
	end
	local values = resolved[player]
	local value = if values ~= nil then values[flagId] else nil
	return if value ~= nil then value else resolve(flag, player.UserId)
end

function FlagService:_logExposure(player: Player, flag: FlagConfig.Flag, value: any)
	local seen = exposed[player]
	if seen == nil then
		seen = {}
		exposed[player] = seen
	end
	if seen[flag.Id] then
		return
	end
	seen[flag.Id] = true

	if AnalyticsService == nil then
		return
	end

	local variant = FlagConfig.VariantFor(flag, player.UserId)
	AnalyticsService:Log(player, "FlagExposure", {
		FlagId = flag.Id,
		Variant = if variant ~= nil then variant.Id else "Default",
		Value = tostring(value),
	})
end

function FlagService:Start()
	AnalyticsService = Loader.Get("AnalyticsService")

	for _, player in Players:GetPlayers() do
		resolveAll(player)
	end

	Players.PlayerAdded:Connect(resolveAll)

	Players.PlayerRemoving:Connect(function(player: Player)
		resolved[player] = nil
		exposed[player] = nil
	end)
end

return FlagService
