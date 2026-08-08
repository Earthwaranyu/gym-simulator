--!strict
--[[
	AnalyticsService — every analytics event in the game, and nothing else.

	Listens to existing signals rather than being called from them, so no gameplay
	system knows analytics exists and deleting this file changes nothing else. The
	only thing other services do for it is *fire signals they would want anyway*
	(MultiplierService.MultiplierPurchased, PurchaseService.PurchaseResolved,
	TravelService.Traveled) — none of them mention analytics.

	Everything goes through `AnalyticsSchema`, which is the versioned contract: an
	event this file cannot name, or a payload that does not match its declared shape,
	is refused here rather than becoming a malformed row nobody notices for a month.

	Two rules this file exists to keep:

	  1. **Telemetry can never take gameplay down.** Every Roblox AnalyticsService call
	     is pcall-wrapped, the service itself may be absent (older clients, Studio
	     without API access), and every listener is written so that a failure inside it
	     cannot propagate back into the signal that fired it.
	  2. **The client may only report client-only facts.** Device, locale, which panel
	     was opened. Anything the server can observe for itself stays server-observed —
	     a client that can assert "I killed someone" is a client that can forge the
	     dashboard. `AnalyticsSchema.IsClientReportable` is the whole allowlist, and
	     `Net.BindEvent` rate-limits the remote on top of it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local AnalyticsSchema = require(ReplicatedStorage.Modules.AnalyticsSchema)

local AnalyticsService = {
	Name = "AnalyticsService",
	Priority = 13,
}

local robloxAnalytics: any = nil

-- Per-player session state. Keyed by Player and cleared on PlayerRemoving, which is
-- also the last chance to emit SessionEnd.
type SessionRecord = {
	joinedAt: number,
	once: { [string]: boolean },
	activities: { [string]: boolean },
	deaths: number,
	kills: number,
	unlockedZones: { [string]: boolean },
	trainingStartedAt: number?,
	trainingStationId: string?,
	trainingStatId: string?,
}

local sessionsByPlayer: { [Player]: SessionRecord } = {}

-- Which broad activity each event counts as, for the "distinct activity types per
-- session" metric. An event with no entry does not count as an activity.
local ACTIVITY_OF: { [string]: string } = {
	TrainingStarted = "Train",
	Kill = "Fight",
	Death = "Fight",
	FirstTravel = "Travel",
	MapOpened = "Travel",
	QuestCompleted = "Quest",
	PurchasePrompt = "Shop",
	ItemViewed = "Shop",
	FirstFlight = "Fly",
}

local function sessionOf(player: Player): SessionRecord
	local record = sessionsByPlayer[player]
	if record == nil then
		record = {
			joinedAt = os.clock(),
			once = {},
			activities = {},
			deaths = 0,
			kills = 0,
			unlockedZones = {},
		}
		sessionsByPlayer[player] = record
	end
	return record
end

local function countActivity(player: Player, eventName: string)
	local activity = ACTIVITY_OF[eventName]
	if activity ~= nil then
		sessionOf(player).activities[activity] = true
	end
end

local function activityCount(record: SessionRecord): number
	local count = 0
	for _ in record.activities do
		count += 1
	end
	return count
end

function AnalyticsService:Init()
	-- GetService itself can fail on platforms where the service is absent.
	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	robloxAnalytics = if ok then service else nil

	local failures = AnalyticsSchema.RunSelfTest()
	if #failures > 0 then
		-- The schema is pure data with a pure test; a failure here means the contract
		-- itself is malformed, which is worth shouting about even though telemetry is
		-- never allowed to stop the game.
		for _, failure in failures do
			warn(`[AnalyticsService] schema self-test failed: {failure}`)
		end
	end
end

--[[
	Emits one event, validating it against the schema first.

	Returns whether it was sent, which is what the self-test and the client remote
	both check. A rejected event is warned about on the server and dropped; it never
	errors, because a telemetry mistake must not become a gameplay failure.
]]
local function logEvent(player: Player, eventName: string, payload: { [string]: any }?): boolean
	local valid, reason = AnalyticsSchema.Validate(eventName, payload)
	if not valid then
		warn(`[AnalyticsService] rejected "{eventName}": {reason}`)
		return false
	end

	local definition = AnalyticsSchema.EVENTS[eventName]
	local record = sessionOf(player)

	if definition.Once then
		if record.once[eventName] then
			return false
		end
		record.once[eventName] = true
	end

	countActivity(player, eventName)

	if robloxAnalytics == nil then
		return true
	end

	-- Schema version rides along on every custom event so rows from two contract
	-- versions are never silently averaged together.
	local fields: { [string]: any } = { schema = AnalyticsSchema.VERSION }
	if payload ~= nil then
		for key, value in payload do
			fields[key] = value
		end
	end

	pcall(function()
		if definition.Kind == "Funnel" then
			robloxAnalytics:LogFunnelStepEvent(
				player,
				AnalyticsSchema.FUNNEL_NAME,
				nil,
				definition.Step,
				eventName
			)
		else
			robloxAnalytics:LogCustomEvent(player, eventName, 1, fields)
		end
	end)

	return true
end

--[[
	Emits an economy flow. Same contract, same silence-on-failure rule.
]]
local function logEconomy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	sku: string
): boolean
	local valid, reason = AnalyticsSchema.ValidateEconomy(flow, currency, amount, sku)
	if not valid then
		warn(`[AnalyticsService] rejected economy event: {reason}`)
		return false
	end
	if robloxAnalytics == nil then
		return true
	end

	pcall(function()
		local flowType = if flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		robloxAnalytics:LogEconomyEvent(player, flowType, currency, amount, 0, sku)
	end)
	return true
end

--- Public wrappers. Nothing else in the game calls these today — analytics observes
--- rather than being called — but a future system that genuinely owns a fact the
--- signals cannot express should go through the same validation, not around it.
function AnalyticsService:Log(player: Player, eventName: string, payload: { [string]: any }?): boolean
	return logEvent(player, eventName, payload)
end

function AnalyticsService:LogEconomy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	sku: string
): boolean
	return logEconomy(player, flow, currency, amount, sku)
end

--[[
	The one client entry point. Name and payload are hostile input: the name must
	exist, must be marked ClientReportable, and the payload must match its declared
	shape. Everything else is dropped without telling the caller why.
]]
function AnalyticsService:_bindClientReports()
	Net.BindEvent("AnalyticsReport", 4, function(player: Player, eventName: any, payload: any)
		if type(eventName) ~= "string" or not AnalyticsSchema.IsClientReportable(eventName) then
			return
		end
		if payload ~= nil and type(payload) ~= "table" then
			return
		end
		logEvent(player, eventName, payload)
	end)
end

function AnalyticsService:Start()
	self:_bindClientReports()

	local DataService = Loader.Get("DataService")
	local StatService = Loader.Get("StatService")
	local CombatService = Loader.Get("CombatService")
	local TokenService = Loader.Get("TokenService")
	local TrainingService = Loader.Get("TrainingService")
	local MultiplierService = Loader.Get("MultiplierService")
	local PurchaseService = Loader.Get("PurchaseService")
	local TravelService = Loader.Get("TravelService")
	local QuestService = Loader.Get("QuestService")

	-- === Session ==========================================================

	DataService.ProfileLoaded:Connect(function(player: Player)
		local record = sessionOf(player)
		record.joinedAt = os.clock()

		logEvent(player, "Joined")

		-- Join source and locale are read once, defensively: both APIs can fail or be
		-- unavailable, and neither is worth a single dropped join.
		local ok, joinData = pcall(function()
			return player:GetJoinData()
		end)
		if ok and type(joinData) == "table" then
			local source = joinData.SourceGameId ~= nil and "Teleport" or "Direct"
			logEvent(player, "AcquisitionSource", { Source = source })
		end

		-- Co-play context: who is already here that this player knows. Spawned because
		-- the friendship API yields — a slow web call must not hold up every other
		-- listener waiting on ProfileLoaded.
		--
		-- Intentional is false here because "joined the same server as a friend" is not
		-- the same as "chose to play together"; #124's invite flow is what sets it true.
		task.spawn(function()
			local friendsPresent = 0
			for _, other in Players:GetPlayers() do
				if other ~= player then
					local friendOk, isFriend = pcall(function()
						return player:IsFriendsWithAsync(other.UserId)
					end)
					if friendOk and isFriend then
						friendsPresent += 1
					end
				end
			end
			if player.Parent ~= nil then
				logEvent(player, "CoPlayContext", { FriendsPresent = friendsPresent, Intentional = false })
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local record = sessionsByPlayer[player]
		if record ~= nil then
			logEvent(player, "SessionEnd", {
				Seconds = os.clock() - record.joinedAt,
				Activities = activityCount(record),
				Deaths = record.deaths,
				Kills = record.kills,
			})
		end
		sessionsByPlayer[player] = nil
	end)

	-- === Training =========================================================

	StatService.StatChanged:Connect(function(player: Player, statId: string)
		logEvent(player, "FirstRep", { StatId = statId })
	end)

	-- One signal covers mount, rep, and dismount, so the transition has to be derived
	-- from whether a session existed a moment ago. Reps fire this constantly, which is
	-- why nothing here allocates or calls out per rep.
	TrainingService.TrainingChanged:Connect(function(player: Player, session: any)
		local record = sessionOf(player)
		local wasTraining = record.trainingStartedAt ~= nil

		if session ~= nil then
			if not wasTraining then
				record.trainingStartedAt = os.clock()
				record.trainingStationId = session.definition.Id
				record.trainingStatId = session.definition.StatId
				logEvent(player, "TrainingStarted", {
					StationId = record.trainingStationId,
					StatId = record.trainingStatId,
				})
			end
			return
		end

		if not wasTraining then
			return
		end

		local seconds = os.clock() - (record.trainingStartedAt or os.clock())
		local stationId = record.trainingStationId or "Unknown"
		local statId = record.trainingStatId or "Unknown"
		record.trainingStartedAt = nil
		record.trainingStationId = nil
		record.trainingStatId = nil

		-- Interruption is kill-only, so a set that ended while the player is dead ended
		-- because someone ended it. That split is the whole interruption metric.
		local character = player.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		local killed = humanoid == nil or humanoid.Health <= 0

		logEvent(player, "TrainingEnded", {
			StationId = stationId,
			StatId = statId,
			Seconds = seconds,
			Reason = if killed then "Killed" else "Stopped",
		})
		if killed then
			logEvent(player, "Interruption", { StationId = stationId, Seconds = seconds })
		end
	end)

	-- === Combat ===========================================================

	CombatService.PlayerKilled:Connect(function(victim: Player, killer: Player, _isRepeatKill: boolean)
		local victimWasTraining = TrainingService:IsTraining(victim)

		sessionOf(victim).deaths += 1
		logEvent(victim, "Death", { WasTraining = victimWasTraining })

		if killer ~= victim then
			sessionOf(killer).kills += 1
			logEvent(killer, "FirstKill")
			logEvent(killer, "Kill", { VictimWasTraining = victimWasTraining })
		end
	end)

	-- === Progression ======================================================

	MultiplierService.MultiplierPurchased:Connect(function(player: Player, statId: string, level: number)
		logEvent(player, "FirstMultiplier", { StatId = statId, Level = level })
		-- The token sink. Cost is re-derived from the level that was just bought rather
		-- than passed along, so the sink can never disagree with the price the player
		-- actually paid.
		logEconomy(player, "Sink", "Tokens", Formulas.MultiplierCost(level - 1), `Multiplier_{statId}`)
	end)

	TokenService.TokensAwarded:Connect(function(player: Player, amount: number)
		logEconomy(player, "Source", "Tokens", amount, "Accrual")
	end)

	QuestService.QuestCompleted:Connect(function(player: Player, quest: any)
		logEvent(player, "QuestCompleted", { QuestId = tostring(quest.Id) })
	end)

	-- Rank and zone crossings are the two clearest measures of progression pacing,
	-- and both are derived from power rather than needing their own signals.
	StatService.StatChanged:Connect(function(player: Player)
		local record = sessionOf(player)
		local power = StatService:GetTotalPower(player)

		local rank = RankConfig.Get(power)
		local rankKey = `Rank_{rank.Id}`
		if not record.once[rankKey] then
			record.once[rankKey] = true
			logEvent(player, "RankReached", { Rank = rank.Id })
		end

		for _, zone in ZoneConfig.List do
			if power >= zone.RequiredPower and not record.unlockedZones[zone.Id] then
				record.unlockedZones[zone.Id] = true
				logEvent(player, "ZoneUnlocked", { ZoneId = zone.Id })
			end
		end
	end)

	TravelService.Traveled:Connect(function(player: Player, zoneId: string)
		logEvent(player, "FirstTravel", { ZoneId = zoneId })
	end)

	-- === Commerce =========================================================

	PurchaseService.ProductPrompted:Connect(function(player: Player, productId: string)
		logEvent(player, "PurchasePrompt", { ProductId = productId })
	end)

	PurchaseService.PurchaseResolved:Connect(function(player: Player, productId: string, result: string)
		logEvent(player, "PurchaseResult", { ProductId = productId, Result = result })
		if result == "Granted" then
			logEvent(player, "PurchaseGrant", { ProductId = productId })
			logEvent(player, "FirstPurchase", { ProductId = productId })
		end
	end)
end

return AnalyticsService
