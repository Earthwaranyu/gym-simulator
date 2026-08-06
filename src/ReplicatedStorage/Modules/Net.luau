--!strict
--[[
	Net — the only place remotes are created.

	Every RemoteEvent and RemoteFunction in the game is declared in the lists below.
	Adding one means adding a string; no other file changes, and nothing else in the
	codebase is allowed to call Instance.new("RemoteEvent").

	Keeping them in one list is also what makes a global rate limiter possible later
	(checklist #53) — there is a single choke point to wrap.

	The server creates the instances at require time; clients wait for them. Because
	the server bootstrap requires this module before any client code runs, the folder
	is always present by the time a client asks.
]]

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
	-- Client -> server: fire an ability by id at an optional target.
	"AbilityActivate",
	-- Server -> client: combat feedback (hit landed, staggered, killed).
	"CombatFeedback",
	-- Server -> client: transient toast/notification text.
	"Notify",
	-- Server -> ALL clients: someone was knocked out. Drives the kill feed.
	"KillFeed",
	-- Server -> client: the public roster (power, rank, reputation, bounty) for the
	-- custom tab bar. Sent as a whole list rather than per-player deltas.
	"RosterChanged",
	-- Server -> client: quest list with current progress.
	"QuestsChanged",
}

local FUNCTION_NAMES: { string } = {
	-- Client -> server: buy one multiplier level for a stat. Returns ok, message.
	"PurchaseMultiplier",
	-- Client -> server: buy a catalogue item with cash. Returns ok, message.
	"PurchaseShopItem",
	-- Client -> server: prompt a Robux purchase by product id. Returns ok, message.
	"PromptProduct",
	-- Client -> server: claim the VIP daily potion. Returns ok, message.
	"ClaimVipDaily",
	-- Client -> server: read the global leaderboards. Returns a list.
	"GetLeaderboard",
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

return Net
