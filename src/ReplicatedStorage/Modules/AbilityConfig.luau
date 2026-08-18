--!strict
--[[
	AbilityConfig — the ability manifest both realms read.

	The server has always been open/closed about abilities: a file dropped into
	CombatService/Abilities/ is discovered at startup and nothing else changes. The
	client was not. CombatController hardcoded `DEFAULT_ABILITY = "Punch"`, mirrored
	Punch's cooldown by reaching into StrikeConfig, and bound exactly one key — so a
	second ability meant a second hardcoded method, and a third meant a third.

	This is the missing half. An ability's id, its key, its cooldown and how it reads
	on the HUD are declared here once; CombatController binds every entry in the list
	and HudController draws one slot per entry. Adding a fourth ability is a row in
	this table plus a file in Abilities/, with no edits to either consumer.

	Deliberately free of the Roblox API. KeyCode is the *name* of an Enum.KeyCode
	rather than the enum itself, and Cooldown is a plain number rather than a read of
	StrikeConfig.Duration, so this module can be required by the `luau` CLI and its
	invariants checked by scripts/selftest.luau. Consumers do the one-line lookup
	(`Enum.KeyCode[entry.KeyCode]`) themselves.

	Cooldowns here are a client-side mirror only, exactly as the old PUNCH_COOLDOWN
	was: they stop a doomed request being sent. CombatService re-checks every one of
	them and remains the authority. They must match the server's ability Cooldown —
	StrikeConfig.RunSelfTest cross-checks the two inside Studio.
]]

export type AbilityKind =
	-- Fires once on press. Slam, heavy punch, the ordinary attack.
	"Press"
	-- Held: the server is told when it starts and when it ends. Block.
	| "Hold"

export type AbilityEntry = {
	Id: string,
	DisplayName: string,
	-- One line for the HUD tooltip. Present tense, no stat numbers — those move.
	Description: string,
	-- Name of an Enum.KeyCode. Nil for an ability with no keyboard binding of its
	-- own, which is how Punch stays on the left mouse button.
	KeyCode: string?,
	-- Gamepad fallback, same convention. Touch gets a ContextActionService button.
	GamepadKeyCode: string?,
	Kind: AbilityKind,
	-- Client-side mirror of the server cooldown, in seconds.
	Cooldown: number,
	-- Left-to-right order in the ability bar. Sparse on purpose so an ability can be
	-- slotted between two existing ones without renumbering the rest.
	HudOrder: number,
	-- Drawn on the HUD slot. Text rather than an image: the project ships no uploaded
	-- assets, and Icons.luau is already a glyph table for the same reason.
	Glyph: string,
	-- Tint of the slot and of the ability's effects.
	Color: { number },
}

local AbilityConfig = {}

--[[
	The abilities, in HUD order.

	Punch keeps no KeyCode. It is the left mouse button and has been since the
	training dock arrived — HudController throws it on click — and giving it a
	keyboard key as well meant advertising two controls for one action.
]]
local abilities: { AbilityEntry } = {
	{
		Id = "Punch",
		DisplayName = "Punch",
		Description = "A three-hit combo. Fast, cheap, and how most damage happens.",
		KeyCode = nil,
		GamepadKeyCode = "ButtonX",
		Kind = "Press",
		Cooldown = 0.9,
		HudOrder = 10,
		Glyph = "M1",
		Color = { 255, 138, 61 },
	},
	{
		Id = "GroundSlam",
		DisplayName = "Ground Slam",
		Description = "Leap and smash. Hits everyone around you and launches them.",
		KeyCode = "Q",
		GamepadKeyCode = "ButtonY",
		Kind = "Press",
		Cooldown = 6,
		HudOrder = 20,
		Glyph = "Q",
		Color = { 255, 176, 64 },
	},
	{
		Id = "HardPunch",
		DisplayName = "Hard Punch",
		Description = "One slow, heavy hit. Telegraphed — it can be blocked.",
		KeyCode = "R",
		GamepadKeyCode = "ButtonB",
		Kind = "Press",
		Cooldown = 3,
		HudOrder = 30,
		Glyph = "R",
		Color = { 255, 92, 92 },
	},
	{
		Id = "Block",
		DisplayName = "Block",
		Description = "Hold to raise a barrier. Drains while up, and breaks if emptied.",
		KeyCode = "F",
		GamepadKeyCode = "ButtonL2",
		Kind = "Hold",
		-- Zero: a guard you can raise is not rate-limited by a cooldown, it is limited
		-- by the meter. BlockService applies a real cooldown only after a break.
		Cooldown = 0,
		HudOrder = 40,
		Glyph = "F",
		Color = { 96, 186, 255 },
	},
}

AbilityConfig.List = abilities

local byId: { [string]: AbilityEntry } = {}
for _, ability in abilities do
	if byId[ability.Id] ~= nil then
		error(`[AbilityConfig] Duplicate ability id "{ability.Id}"`)
	end
	byId[ability.Id] = ability
end

function AbilityConfig.Get(abilityId: string): AbilityEntry?
	return byId[abilityId]
end

--[[
	The entries in the order the HUD should draw them.

	Sorted here rather than by the consumer so every consumer agrees, and so HudOrder
	stays the single place the order is decided.
]]
function AbilityConfig.Ordered(): { AbilityEntry }
	local ordered = table.clone(abilities)
	table.sort(ordered, function(a: AbilityEntry, b: AbilityEntry): boolean
		return a.HudOrder < b.HudOrder
	end)
	return ordered
end

function AbilityConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	local seenKeys: { [string]: string } = {}
	local seenOrders: { [number]: string } = {}
	for _, ability in abilities do
		check(#ability.Id > 0, "every ability has an id")
		check(#ability.DisplayName > 0, `{ability.Id} has a display name`)
		check(#ability.Description > 0, `{ability.Id} has a description`)
		check(#ability.Glyph > 0, `{ability.Id} has a HUD glyph`)
		check(ability.Cooldown >= 0, `{ability.Id} has a non-negative cooldown`)
		check(ability.Kind == "Press" or ability.Kind == "Hold", `{ability.Id} has a known activation kind`)
		check(#ability.Color == 3, `{ability.Id} declares an RGB colour`)
		for _, channel in ability.Color do
			check(channel >= 0 and channel <= 255, `{ability.Id} colour channels are bytes`)
		end

		-- Two abilities on one key is the bug this table exists to prevent: the
		-- binding that loses is simply never reachable, with no error anywhere.
		local key = ability.KeyCode
		if key ~= nil then
			check(seenKeys[key] == nil, `{ability.Id} reuses key {key}`)
			seenKeys[key] = ability.Id
		end
		local pad = ability.GamepadKeyCode
		if pad ~= nil then
			check(seenKeys[pad] == nil, `{ability.Id} reuses pad button {pad}`)
			seenKeys[pad] = ability.Id
		end

		check(seenOrders[ability.HudOrder] == nil, `{ability.Id} shares a HUD slot`)
		seenOrders[ability.HudOrder] = ability.Id
	end

	-- E belongs to the training prompt and the NPC prompt, both created server-side
	-- as ProximityPrompts. An ability bound to E would silently fight the thing the
	-- whole game is about, so it is called out by name rather than left to review.
	-- C is dash, Space and LeftControl are flight, LeftShift is sprint.
	local reserved: { [string]: string } = {
		E = "the training prompt",
		C = "dash",
		Space = "flight",
		LeftControl = "flight",
		LeftShift = "sprint",
	}
	for _, ability in abilities do
		local key = ability.KeyCode
		if key ~= nil and reserved[key] ~= nil then
			table.insert(failures, `{ability.Id} is bound to {key}, which belongs to {reserved[key]}`)
		end
	end

	check(byId.Punch ~= nil, "Punch is still the default attack")
	check(
		byId.Punch ~= nil and byId.Punch.KeyCode == nil,
		"Punch stays on the mouse rather than taking a key"
	)
	check(byId.Block ~= nil and byId.Block.Kind == "Hold", "Block is a held ability")

	return failures
end

return AbilityConfig
