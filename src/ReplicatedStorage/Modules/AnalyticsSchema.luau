--!strict
--[[
	AnalyticsSchema — the versioned contract for every analytics event.

	One table declares every event the game may emit: its kind, its funnel step if it
	has one, whether a client is allowed to report it, and the exact shape of its
	payload. `AnalyticsService` refuses to send anything this file does not describe,
	so a typo'd event name or a drifted field is a validation failure at the source
	rather than a hole in a dashboard discovered a month later.

	Why validate server-side at all, when the server is the one emitting? Because some
	events only the client can observe — device, locale, a panel being opened — and
	those arrive over a remote. Everything crossing that boundary is hostile input
	until proven otherwise: unknown name, unknown field, wrong type, non-finite
	number, or oversized string is dropped.

	Adding an event is an entry in EVENTS. No other file changes. Bump VERSION when a
	change would make old rows and new rows non-comparable (a removed field, a changed
	meaning, a renumbered funnel step) — adding a new optional field does not need it.
]]

local AnalyticsSchema = {}

-- Bumped whenever previously-emitted rows stop being comparable with new ones.
-- v1 was the unversioned five-step funnel plus token economy events.
AnalyticsSchema.VERSION = 2

-- The single onboarding funnel. Step numbers are part of the contract: renumbering
-- them invalidates every historical comparison, so it requires a VERSION bump.
AnalyticsSchema.FUNNEL_NAME = "Onboarding"

-- Payload guards. Strings become dashboard dimensions, so an unbounded one is both a
-- cardinality problem and a memory one.
local MAX_STRING = 64
local MAX_FIELDS = 12

export type FieldKind = "string" | "number" | "boolean"

export type Field = {
	Kind: FieldKind,
	Required: boolean?,
}

export type EventKind = "Funnel" | "Custom" | "Economy"

export type EventDefinition = {
	Kind: EventKind,
	-- Funnel events only: position in the onboarding funnel.
	Step: number?,
	-- Funnel and one-shot events: recorded at most once per player per session.
	Once: boolean?,
	-- Whether a client may report this event. Anything the server can observe for
	-- itself must stay false — a client that can assert "I killed someone" is a
	-- client that can forge the dashboard.
	ClientReportable: boolean?,
	Fields: { [string]: Field },
}

local function str(required: boolean?): Field
	return { Kind = "string", Required = required }
end

local function num(required: boolean?): Field
	return { Kind = "number", Required = required }
end

--[[
	Every event in the game.

	Server-observed events carry `ClientReportable = false` (the default). The client
	may only report things that are genuinely client-only facts and that grant nothing:
	which panel it opened, what device it is on, what locale it renders in.
]]
local EVENTS: { [string]: EventDefinition } = {
	-- === Funnel ==========================================================

	Joined = { Kind = "Funnel", Step = 1, Once = true, Fields = {} },
	FirstRep = { Kind = "Funnel", Step = 2, Once = true, Fields = { StatId = str(true) } },
	FirstMultiplier = {
		Kind = "Funnel",
		Step = 3,
		Once = true,
		Fields = { StatId = str(true), Level = num(true) },
	},
	FirstKill = { Kind = "Funnel", Step = 4, Once = true, Fields = {} },
	FirstPurchase = { Kind = "Funnel", Step = 5, Once = true, Fields = { ProductId = str(true) } },

	-- === Session shape ===================================================

	-- Emitted once the player's character actually moves. Separates "joined" from
	-- "joined and is present", which is the difference between a load failure and a
	-- player who chose to leave.
	Moved = {
		Kind = "Custom",
		Once = true,
		ClientReportable = true,
		Fields = { SecondsSinceJoin = num(true) },
	},
	SessionEnd = {
		Kind = "Custom",
		Fields = { Seconds = num(true), Activities = num(true), Deaths = num(), Kills = num() },
	},
	DeviceInput = {
		Kind = "Custom",
		Once = true,
		ClientReportable = true,
		Fields = { Device = str(true), Input = str(true) },
	},
	Locale = { Kind = "Custom", Once = true, ClientReportable = true, Fields = { LocaleId = str(true) } },
	AcquisitionSource = { Kind = "Custom", Once = true, Fields = { Source = str(true) } },
	CoPlayContext = {
		Kind = "Custom",
		Fields = { FriendsPresent = num(true), Intentional = { Kind = "boolean" } },
	},

	-- === Training ========================================================

	PromptSeen = { Kind = "Custom", ClientReportable = true, Fields = { StationId = str(true) } },
	TrainingStarted = { Kind = "Custom", Fields = { StationId = str(true), StatId = str(true) } },
	TrainingEnded = {
		Kind = "Custom",
		-- Reason distinguishes a player choosing to stop from one who was killed off
		-- the machine. That split is the interruption metric.
		Fields = { StationId = str(true), StatId = str(true), Seconds = num(true), Reason = str(true) },
	},
	Interruption = { Kind = "Custom", Fields = { StationId = str(true), Seconds = num(true) } },

	-- === World and progression ===========================================

	MapOpened = { Kind = "Custom", ClientReportable = true, Fields = {} },
	-- Only the client knows when flight actually engages — the server owns permission,
	-- not the flying itself. Reporting it grants nothing, so the client may say so.
	FirstFlight = { Kind = "Custom", Once = true, ClientReportable = true, Fields = {} },
	FirstTravel = { Kind = "Custom", Once = true, Fields = { ZoneId = str(true) } },
	ZoneUnlocked = { Kind = "Custom", Fields = { ZoneId = str(true) } },
	RankReached = { Kind = "Custom", Fields = { Rank = str(true) } },
	QuestCompleted = { Kind = "Custom", Fields = { QuestId = str(true) } },

	-- === Combat ==========================================================

	Death = { Kind = "Custom", Fields = { WasTraining = { Kind = "boolean" }, KillerPower = num() } },
	Kill = { Kind = "Custom", Fields = { VictimWasTraining = { Kind = "boolean" } } },

	-- === Commerce ========================================================

	ItemViewed = { Kind = "Custom", ClientReportable = true, Fields = { ItemId = str(true) } },
	PurchasePrompt = { Kind = "Custom", Fields = { ProductId = str(true) } },
	PurchaseResult = { Kind = "Custom", Fields = { ProductId = str(true), Result = str(true) } },
	PurchaseGrant = { Kind = "Custom", Fields = { ProductId = str(true) } },
}

AnalyticsSchema.EVENTS = EVENTS

--[[
	Economy flows. Currency and SKU strings are declared rather than free-form so a
	renamed sink cannot silently split one metric into two.
]]
local CURRENCIES: { [string]: boolean } = {
	Tokens = true,
	Cash = true,
}

AnalyticsSchema.CURRENCIES = CURRENCIES

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Validates a payload against an event definition.

	Returns `true` on success, or `false` plus a human-readable reason. The reason is
	for the server log only — a rejected client event is dropped silently, because
	telling a caller precisely why its forgery failed is telling it how to fix it.
]]
function AnalyticsSchema.Validate(eventName: string, payload: { [string]: any }?): (boolean, string?)
	if type(eventName) ~= "string" then
		return false, "event name is not a string"
	end

	local definition = EVENTS[eventName]
	if definition == nil then
		return false, `unknown event "{eventName}"`
	end

	if payload ~= nil and type(payload) ~= "table" then
		return false, "payload is not a table"
	end
	local fields: { [string]: any } = if payload ~= nil then payload else {}

	local count = 0
	for key, value in fields do
		count += 1
		if count > MAX_FIELDS then
			return false, "payload has too many fields"
		end
		if type(key) ~= "string" then
			return false, "payload has a non-string key"
		end

		local field = definition.Fields[key]
		if field == nil then
			return false, `"{eventName}" has no field "{key}"`
		end
		if type(value) ~= field.Kind then
			return false, `"{eventName}.{key}" must be a {field.Kind}`
		end
		if field.Kind == "number" and not isFinite(value :: number) then
			return false, `"{eventName}.{key}" is not finite`
		end
		if field.Kind == "string" and #(value :: string) > MAX_STRING then
			return false, `"{eventName}.{key}" is too long`
		end
	end

	for key, field in definition.Fields do
		if field.Required and fields[key] == nil then
			return false, `"{eventName}" is missing required field "{key}"`
		end
	end

	return true
end

--[[
	Whether a client is permitted to report this event at all.
]]
function AnalyticsSchema.IsClientReportable(eventName: string): boolean
	local definition = EVENTS[eventName]
	return definition ~= nil and definition.ClientReportable == true
end

--[[
	Validates an economy flow. Amount must be a finite positive number: a negative
	source or sink flips the sign of a metric nobody re-derives by hand.
]]
function AnalyticsSchema.ValidateEconomy(
	flow: string,
	currency: string,
	amount: number,
	sku: string?
): (boolean, string?)
	if flow ~= "Source" and flow ~= "Sink" then
		return false, `unknown flow "{tostring(flow)}"`
	end
	if not CURRENCIES[currency] then
		return false, `unknown currency "{tostring(currency)}"`
	end
	if type(amount) ~= "number" or not isFinite(amount) or amount <= 0 then
		return false, "amount must be a finite positive number"
	end
	if sku ~= nil and (type(sku) ~= "string" or #sku > MAX_STRING) then
		return false, "sku must be a short string"
	end
	return true
end

--[[
	Self-test. Runs in plain Luau with no Roblox API, so `./scripts/check.sh` and the
	server bootstrap both exercise it.
]]
function AnalyticsSchema.RunSelfTest(): { string }
	local failures: { string } = {}

	local function check(label: string, condition: boolean)
		if not condition then
			table.insert(failures, label)
		end
	end

	local function rejects(label: string, eventName: string, payload: any)
		local ok = AnalyticsSchema.Validate(eventName, payload)
		check(label, not ok)
	end

	-- Funnel integrity: steps must be unique and contiguous from 1.
	local seenSteps: { [number]: string } = {}
	local maxStep = 0
	for name, definition in EVENTS do
		if definition.Kind == "Funnel" then
			check(`funnel event "{name}" has a step`, definition.Step ~= nil)
			local step = definition.Step or 0
			check(`funnel step {step} is unique`, seenSteps[step] == nil)
			seenSteps[step] = name
			maxStep = math.max(maxStep, step)
		end
	end
	for step = 1, maxStep do
		check(`funnel step {step} exists`, seenSteps[step] ~= nil)
	end

	-- No event that the server can observe may be reportable by a client.
	check("Kill is not client-reportable", not AnalyticsSchema.IsClientReportable("Kill"))
	check("FirstPurchase is not client-reportable", not AnalyticsSchema.IsClientReportable("FirstPurchase"))
	check("MapOpened is client-reportable", AnalyticsSchema.IsClientReportable("MapOpened"))

	check("valid payload passes", (AnalyticsSchema.Validate("FirstRep", { StatId = "Chest" })))
	check("empty-field event passes", (AnalyticsSchema.Validate("Joined", {})))
	check("nil payload passes for fieldless event", (AnalyticsSchema.Validate("MapOpened")))

	rejects("unknown event rejected", "NotAnEvent", {})
	rejects("unknown field rejected", "FirstRep", { StatId = "Chest", Sneaky = 1 })
	rejects("missing required field rejected", "FirstRep", {})
	rejects("wrong type rejected", "FirstRep", { StatId = 5 })
	rejects("NaN rejected", "FirstMultiplier", { StatId = "Arms", Level = 0 / 0 })
	rejects("inf rejected", "FirstMultiplier", { StatId = "Arms", Level = math.huge })
	rejects("oversized string rejected", "FirstRep", { StatId = string.rep("x", MAX_STRING + 1) })
	rejects("non-table payload rejected", "Joined", "nope")

	check("economy source passes", (AnalyticsSchema.ValidateEconomy("Source", "Tokens", 5, "Accrual")))
	check("unknown currency rejected", not AnalyticsSchema.ValidateEconomy("Source", "Doubloons", 5))
	check("unknown flow rejected", not AnalyticsSchema.ValidateEconomy("Sideways", "Tokens", 5))
	check("negative amount rejected", not AnalyticsSchema.ValidateEconomy("Source", "Tokens", -1))
	check("NaN amount rejected", not AnalyticsSchema.ValidateEconomy("Source", "Tokens", 0 / 0))

	return failures
end

return AnalyticsSchema
