--!strict
--[[
	Net — the only place remotes are created.

	Every RemoteEvent and RemoteFunction in the game is declared in the lists below.
	Adding one means adding a string; no other file changes, and nothing else in the
	codebase is allowed to call Instance.new("RemoteEvent").

	Keeping them in one list is what makes the global rate limiter possible: BindEvent
	and BindFunction wrap every server handler in a per-player token bucket, so no
	individual system has to remember to defend itself. A client that floods a remote
	gets its extra calls dropped here and never reaches game logic.

	The server creates the instances at require time; clients wait for them. Because
	the server bootstrap requires this module before any client code runs, the folder
	is always present by the time a client asks.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"
local IS_SERVER = RunService:IsServer()

-- Client -> server requests, and server -> client pushes. Direction is documented
-- per entry rather than enforced; the receiving side validates regardless.
local EVENT_NAMES: { string } = {
	-- Server -> client: the authoritative profile view changed.
	"ProfileChanged",
	-- Server -> client: training state (station, combo, stagger) changed. Training is
	-- automatic, so there is no client -> server counterpart.
	"TrainingChanged",
	-- Server -> client: one authoritative stat payout that actually landed. Drives the
	-- floating +gain feedback; the client never guesses multipliers or combo math.
	"TrainingGain",
	-- Client -> server: fire an ability by id at an optional target.
	"AbilityActivate",
	-- Client -> server: Shift sprint began/ended. The server resolves the actual
	-- speed from Legs; the client only reports the held-button intent.
	"SprintChanged",
	-- Client -> server: the guard went up / came down. Like SprintChanged, this
	-- reports a held button and nothing else: BlockService owns the meter, decides
	-- how much a guard actually stops, and drops it on its own when the meter runs
	-- out, so a client holding this open forever gets one guard's worth of meter.
	"BlockChanged",
	-- Server -> client: this player's guard meter, as a fraction and a state. Sent
	-- rather than derived because the drain depends on damage the client never sees
	-- the inputs to.
	"BlockState",
	-- Client -> server: which flight silhouette this player is in, or nil on landing.
	-- Flight itself is the client's, like the dash; what the server owns is publishing
	-- the state so *other* clients can pose the flier. Before this, nothing anywhere
	-- said who was actually airborne, so a remote flier was a standing body sliding
	-- through the air on every screen but their own.
	--
	-- Grants nothing. FlightService still decides who may fly at all, and still drops
	-- anybody it has grounded.
	"FlightChanged",
	-- Client -> server: "I am dashing" / "I have stopped". The dash itself is the
	-- client's, like flight; what the server owns is the collision group that stops
	-- a dasher bulldozing anybody standing in the way. Granting nothing and lasting
	-- a fraction of a second under a server-side timeout, so holding it open is not
	-- worth anything.
	"DashChanged",
	-- Server -> client: combat feedback (hit landed, staggered, killed).
	"CombatFeedback",
	-- Server -> client: transient toast/notification text.
	"Notify",
	-- Client -> server: the player wants to stop training (spacebar / jump).
	"StopTraining",
	-- Client -> server: "I am still holding the train button, on this muscle."
	-- Carries no amount and grants nothing by itself. ManualTrainingService pays by
	-- elapsed time, so a client firing this a hundred times a second earns exactly
	-- what one firing it twice a second earns.
	"ManualTrain",
	-- Server -> ALL clients: someone was knocked out. Drives the kill feed.
	"KillFeed",
	-- Server -> client: the public roster (power, rank, reputation, bounty) for the
	-- custom tab bar. Sent as a whole list rather than per-player deltas.
	"RosterChanged",
	-- Server -> client: quest list with current progress.
	"QuestsChanged",
	-- Server -> client: which tier bosses are alive and how long until the rest return.
	-- Pushed on every spawn and kill, and on a slow heartbeat, so a countdown on the
	-- map stays honest without the client having to ask.
	"BossStateChanged",
	-- Server -> client: this player's resolved feature-flag values. Outcomes only —
	-- never the rules, never another player's cohort.
	"FlagsChanged",
	-- Client -> server: report a client-only analytics fact (device, locale, a panel
	-- opened). The server validates the name against AnalyticsSchema and drops
	-- anything not marked ClientReportable, so this grants nothing.
	"AnalyticsReport",
}

local FUNCTION_NAMES: { string } = {
	-- Client -> server: buy one multiplier level for a stat. Returns ok, message.
	"PurchaseMultiplier",
	-- Client -> server: transform into the next ordered physique class. Returns ok, message.
	"SelectPhysiqueClass",
	-- Client -> server: buy one token-priced shop item. Returns ok, message.
	"PurchaseShopItem",
	-- Client -> server: what each shop item costs THIS player. Prices scale with the
	-- physique class, so the client cannot work them out from the config alone without
	-- duplicating the rule the server charges by.
	"GetShopPrices",
	-- Client -> server: prompt a Robux purchase by product id. Returns ok, message.
	"PromptProduct",
	-- Client -> server: the Robux catalogue for the shop screen. Returns a list of
	-- display rows, so adding a product file is enough to make it appear in the UI.
	"GetProductCatalogue",
	-- Client -> server: claim the VIP daily potion. Returns ok, message.
	"ClaimVipDaily",
	-- Client -> server: read the global leaderboards. Returns a list.
	"GetLeaderboard",
	-- Client -> server: travel to a district by id. Returns ok, message.
	"Travel",
	-- Client -> server: whether this player may teleport. The dedicated map always
	-- shows Track separately and uses this answer only to paint Teleport locked or
	-- available; ownership is still re-checked on every actual Travel call.
	"GetTravelAccess",
	-- Client -> server: live occupancy for every station, plus which one the caller is
	-- on. Streaming means most stations are absent from a client's Workspace, so this
	-- is the only way the Train panel can say whether a machine across town is free.
	"GetSpotStatus",
	-- Client -> server: choose an exact stepped kg load for the current machine.
	-- Returns ok, message. The server validates zone, step and muscle requirement.
	"SetTrainingWeight",
	-- Client -> server: opt an Auto Load owner in or out. Returns ok, message.
	"SetAutoLoad",
	-- Client -> server: equip one power-unlocked overhead title.
	"SelectTitle",
	-- Client -> server: every district's landing pad in world space, for the
	-- travel map's pins. Streaming means the client cannot measure them itself.
	"GetDestinations",
	-- Client -> server: save one whitelisted boolean preference. Returns ok, message.
	"UpdateSetting",
	-- Client -> server: the whole chosen look at once — skin, shorts, hair, face — as
	-- ids into the appearance configs. One call rather than four so a player is never
	-- saved half-way through a change. Returns ok, message.
	"SetAppearance",
}

local folder: Folder
if IS_SERVER then
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		folder = existing :: Folder
	else
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = ReplicatedStorage
		folder = created
	end
else
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

local function build(names: { string }, className: "RemoteEvent" | "RemoteFunction")
	if not IS_SERVER then
		return
	end
	for _, name in names do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
		end
	end
end

build(EVENT_NAMES, "RemoteEvent")
build(FUNCTION_NAMES, "RemoteFunction")

local Net = {}

-- player -> remote name -> { tokens, lastRefillAt }
local buckets: { [Player]: { [string]: { tokens: number, at: number } } } = {}

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player: Player)
		buckets[player] = nil
	end)
end

--[[
	Token-bucket rate limit. Returns false when the caller has spent its allowance.

	A bucket refills continuously rather than resetting on a window boundary, so a
	client cannot burst double its rate by straddling two windows.
]]
local function allow(player: Player, name: string, perSecond: number): boolean
	local playerBuckets = buckets[player]
	if playerBuckets == nil then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local now = os.clock()
	local bucket = playerBuckets[name]

	if bucket == nil then
		bucket = { tokens = perSecond, at = now }
		playerBuckets[name] = bucket
	end

	-- Burst allowance is one second's worth, which absorbs normal latency jitter
	-- without letting a client bank minutes of unused budget.
	bucket.tokens = math.min(perSecond, bucket.tokens + (now - bucket.at) * perSecond)
	bucket.at = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

local function resolve(name: string, className: string): Instance
	local instance = if IS_SERVER then folder:FindFirstChild(name) else folder:WaitForChild(name, 10)

	if instance == nil then
		error(`[Net] Remote "{name}" does not exist. Declare it in Net.luau.`, 3)
	end
	if not instance:IsA(className) then
		error(`[Net] Remote "{name}" is a {instance.ClassName}, expected {className}.`, 3)
	end
	return instance
end

--[[
	Returns the named RemoteEvent. Errors if it was never declared, which turns a
	typo into an immediate failure instead of a silently dead listener.
]]
function Net.Event(name: string): RemoteEvent
	return resolve(name, "RemoteEvent") :: RemoteEvent
end

--[[
	Returns the named RemoteFunction. Server handlers must never yield indefinitely;
	a hung OnServerInvoke blocks the calling client.
]]
function Net.Function(name: string): RemoteFunction
	return resolve(name, "RemoteFunction") :: RemoteFunction
end

--[[
	Server-side: attaches a rate-limited handler to a RemoteEvent.

	Prefer this over Net.Event(name).OnServerEvent for anything a client can trigger.
	Calls beyond `perSecond` are dropped silently — telling a flooder they were
	throttled just gives them a signal to tune against.
]]
function Net.BindEvent(name: string, perSecond: number, handler: (Player, ...any) -> ())
	Net.Event(name).OnServerEvent:Connect(function(player: Player, ...)
		if not allow(player, name, perSecond) then
			return
		end
		handler(player, ...)
	end)
end

--[[
	Server-side: attaches a rate-limited handler to a RemoteFunction.

	Unlike events, a throttled invoke must still return something, or the caller
	yields until timeout. It answers with the standard (false, message) shape every
	purchase path already uses.
]]
function Net.BindFunction(name: string, perSecond: number, handler: (Player, ...any) -> ...any)
	Net.Function(name).OnServerInvoke = function(player: Player, ...)
		if not allow(player, name, perSecond) then
			return false, "You are doing that too quickly."
		end
		return handler(player, ...)
	end
end

return Net
