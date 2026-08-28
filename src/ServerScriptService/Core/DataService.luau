--!strict
--[[
	DataService — owns every player profile's lifecycle.

	The only system allowed to talk to ProfileStore. Everything else reads through
	GetData() and announces its writes with MarkDirty(), which is what lets the
	replicator push changes without polling.

	Priority is high so this Init()s before any system that will want data on Start.

	Studio uses ProfileStore's mock store by default, so development never touches live
	save data. Flip USE_MOCK_IN_STUDIO to test real persistence across Play sessions —
	note the mock store only survives within a single Play session.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Types = require(ReplicatedStorage.Modules.Types)
local ProfileTemplate = require(ReplicatedStorage.Modules.ProfileTemplate)
local Migrations = require(script.Parent._Migrations)

local STORE_NAME = "PlayerData"
local USE_MOCK_IN_STUDIO = true

-- ProfileStore is untyped, so pin down just the surface we use.
type Profile = {
	Data: Types.ProfileData,
	LastSavedData: Types.ProfileData,
	OnSessionEnd: { Connect: (any, () -> ()) -> any },
	IsActive: (Profile) -> boolean,
	Reconcile: (Profile) -> (),
	Save: (Profile) -> (),
	EndSession: (Profile) -> (),
	AddUserId: (Profile, number) -> (),
}

local DataService = {
	Name = "DataService",
	-- Ahead of everything else: systems that need data on Start must find it ready.
	Priority = 100,
}

local profiles: { [Player]: Profile } = {}
--[[
	Players whose profile is being fetched right now.

	`profiles` cannot do this job on its own: it is only assigned *after*
	StartSessionAsync returns, and that call yields for as long as a DataStore round
	trip takes. Two calls to _loadProfile for the same player inside that window both
	see an empty `profiles`, both pass the guard, and both open a session on the same
	key — which is a session steal against ourselves. See _loadProfile.
]]
local loading: { [Player]: boolean } = {}
local sessionStart: { [Player]: number } = {}
local store: any = nil

-- Fired once a player's profile is loaded and safe to read.
DataService.ProfileLoaded = Signal.new()
-- Fired as the profile is torn down. Read data here if you need a final value; after
-- this returns, GetData() is nil for that player.
DataService.ProfileReleasing = Signal.new()
-- Fired by MarkDirty. The replicator listens; nothing else should need to.
DataService.DataChanged = Signal.new()

function DataService:Init()
	local live = ProfileStore.New(STORE_NAME, ProfileTemplate)
	store = if RunService:IsStudio() and USE_MOCK_IN_STUDIO then live.Mock else live

	if RunService:IsStudio() and USE_MOCK_IN_STUDIO then
		warn("[DataService] Studio session using the MOCK store — saves will not persist.")
	end
end

function DataService:Start()
	Players.PlayerAdded:Connect(function(player)
		self:_loadProfile(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_releaseProfile(player)
	end)

	-- A player can join before Start runs; catch anyone already here.
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_loadProfile(player)
		end)
	end
end

--[[
	Opens one player's session, migrates it, and publishes it.

	Guarded against being entered twice for the same player, which `Start` can genuinely
	do: it connects PlayerAdded and *then* sweeps Players:GetPlayers(). A player who
	arrives in the gap between those two lines is already parented — so the sweep sees
	them — and PlayerAdded is deferred rather than synchronous, so it fires for them
	afterwards as well. Both paths call this function, and the `profiles` check at the
	top cannot separate them because the assignment it tests for happens after the
	StartSessionAsync yield below. The result is two sessions on one key: ProfileStore's
	own duplicate check reads ActiveSessionCheck, which is likewise not populated until
	the load completes, so it does not catch a concurrent in-flight load either. The
	player is then either kicked by OnSessionEnd the instant they join, or left playing
	on the losing Profile object, whose writes go to a table that will never be saved.

	The window is microseconds wide and it sits on server boot, which is exactly when
	the first players of a fresh server arrive.
]]
function DataService:_loadProfile(player: Player)
	if profiles[player] ~= nil or loading[player] then
		return
	end
	loading[player] = true

	-- ProfileStore pcalls its own DataStore traffic, so a throw here means argument
	-- validation or a duplicate session — but an uncaught one kills this thread before
	-- the kick below, and the player then sits in a live server with GetData() nil
	-- forever: no training, no tokens, no message, no way to tell anything is wrong.
	local ok, result = pcall(function()
		return store:StartSessionAsync(`Player_{player.UserId}`, {
			-- Stop retrying if they gave up and left mid-load.
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
	end)
	loading[player] = nil

	if not ok then
		warn(`[DataService] StartSessionAsync threw for {player.Name}: {result}`)
		player:Kick("Could not load your data. Please rejoin.")
		return
	end

	local profile: Profile? = result
	if profile == nil then
		player:Kick("Could not load your data. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)

	--[[
		Migrate first, reconcile second, and the order is the whole point.

		Reconcile fills in every key the template has and the save does not — including
		`SchemaVersion`, which the template pins at the current version. Run first, it
		stamps a profile that predates versioning as fully current, and Migrations.Apply
		then reads that stamp and runs *nothing*. Apply's own defence against exactly
		this case ("anything below the first step means migrate from the beginning", in
		its header) is unreachable while Reconcile goes first, because Apply never sees
		the absent version it is written to handle.

		Every step is written to tolerate missing and wrong-typed fields, so none of
		them need the reconciled shape; reconciling afterwards then adds whatever the
		migrated data still lacks.
	]]
	local applied, failure = Migrations.Apply(profile.Data)
	if failure ~= nil then
		-- Half-migrated data must never reach gameplay. The profile was left unstamped,
		-- so it will retry on the next join; what must not happen is this session running
		-- on it and saving the partial result back over a good save. One lost session
		-- beats one destroyed profile, and the warning is how we hear about it at all.
		warn(`[DataService] Migration failed for {player.Name}: {failure}`)
		profile:EndSession()
		player:Kick("Could not load your data. Please rejoin.")
		return
	end
	if applied > 0 then
		print(`[DataService] Migrated {player.Name} through {applied} schema step(s)`)
	end

	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		sessionStart[player] = nil
		-- Another server took the session, or it was ended remotely. Continuing to
		-- play would silently discard everything they do from here.
		player:Kick("Your data session was ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
		-- Left while we were loading; hand the lock straight back.
		profile:EndSession()
		return
	end

	profiles[player] = profile
	sessionStart[player] = os.clock()

	DataService.ProfileLoaded:Fire(player, profile.Data)
	DataService.DataChanged:Fire(player)
end

function DataService:_releaseProfile(player: Player)
	local profile = profiles[player]
	if profile == nil then
		return
	end

	local started = sessionStart[player]
	if started ~= nil then
		profile.Data.TotalPlaytime += os.clock() - started
	end

	DataService.ProfileReleasing:Fire(player, profile.Data)

	profiles[player] = nil
	sessionStart[player] = nil
	profile:EndSession()
end

--[[
	The live profile, or nil if it has not loaded yet or the player is leaving.
	Prefer GetData unless you need ProfileStore's own methods.
]]
function DataService:GetProfile(player: Player): Profile?
	return profiles[player]
end

--[[
	The player's saved data table. Mutating it is how you save — changes to this table
	are persisted automatically. Call MarkDirty afterwards so the client sees them.
]]
function DataService:GetData(player: Player): Types.ProfileData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

--[[
	Yields until the player's data is loaded, or until timeout. Returns nil if they
	left or loading failed. For code that runs before ProfileLoaded fires.
]]
function DataService:WaitForData(player: Player, timeout: number?): Types.ProfileData?
	local deadline = os.clock() + (timeout or 10)

	while profiles[player] == nil do
		if player.Parent ~= Players or os.clock() > deadline then
			return nil
		end
		task.wait(0.1)
	end

	return self:GetData(player)
end

--[[
	Announces that a player's data changed, so the replicator pushes it to them.
	Cheap to over-call — the replicator batches per frame.
]]
function DataService:MarkDirty(player: Player)
	if profiles[player] == nil then
		return
	end
	DataService.DataChanged:Fire(player)
end

--[[
	Forces this player's profile to disk now instead of at the next autosave.

	Deliberately not the default: ProfileStore autosaves on its own schedule and every
	training rep calls MarkDirty, so saving on every write would be a DataStore request
	per rep per player. This exists for the handful of writes where the ~30-second
	autosave window is a real risk rather than a theoretical one — a Robux receipt being
	the case it was added for, where losing the window costs the player money.

	Yields. Safe to call for a player whose profile has gone; it simply does nothing.
]]
function DataService:Save(player: Player): boolean
	local profile = profiles[player]
	if profile == nil then
		return false
	end
	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn(`[DataService] Save failed for {player.Name}: {err}`)
	end
	return ok
end

--[[
	Convenience for the common read-modify-mark cycle:
		DataService:Update(player, function(data) data.Tokens += 100 end)
	Returns false if the player has no loaded profile.
]]
function DataService:Update(player: Player, mutator: (Types.ProfileData) -> ()): boolean
	local data = self:GetData(player)
	if data == nil then
		return false
	end

	mutator(data)
	self:MarkDirty(player)
	return true
end

return DataService
