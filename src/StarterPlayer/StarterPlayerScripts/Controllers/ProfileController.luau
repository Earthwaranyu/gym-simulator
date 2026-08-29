--!strict
--[[
	ProfileController — the client's read-only view of its own profile.

	UI reads from here instead of listening to the remote directly, so a panel built
	later still shows correct values if it loads after the first push.

	This copy is authoritative for display only. Writing to it changes nothing on the
	server; every mutation goes through a remote the server validates.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local ProfileController = {
	Name = "ProfileController",
	-- Ahead of the UI controllers, so they can read data during their own Start.
	Priority = 100,
}

local current: Types.ProfileView? = nil

-- Fires on every push with the new profile view.
ProfileController.Changed = Signal.new()

function ProfileController:Init()
	-- Connected in Init rather than Start so the very first push cannot be missed.
	Net.Event("ProfileChanged").OnClientEvent:Connect(function(payload: Types.ProfileView)
		current = payload
		ProfileController.Changed:Fire(payload)
	end)
end

--[[
	The latest profile view, or nil if the first push has not arrived yet.
]]
function ProfileController:Get(): Types.ProfileView?
	return current
end

--[[
	Yields until the first push arrives, or until timeout (default 15s). Returns nil
	on timeout so callers can degrade rather than hang forever.
]]
function ProfileController:WaitFor(timeout: number?): Types.ProfileView?
	if current ~= nil then
		return current
	end

	--[[
		Woken by the Changed signal rather than polled.

		This used to spin on task.wait(0.1), which meant every caller paid up to a tenth
		of a second *after* the data had already arrived. That is invisible in a panel
		that opens later and very visible on the join screen, which is the first thing
		waiting on it.
	]]
	local thread = coroutine.running()
	local resumed = false
	local expired = false

	local function finish()
		if resumed then
			return
		end
		resumed = true
		task.spawn(thread)
	end

	local connection = ProfileController.Changed:Connect(finish)
	local expiry = task.delay(timeout or 15, function()
		expired = true
		finish()
	end)

	coroutine.yield()

	connection:Disconnect()
	-- Only cancel a timer that has not already run: cancelling a finished thread
	-- throws, and the timeout firing is the ordinary path when a profile never lands.
	if not expired then
		task.cancel(expiry)
	end

	return current
end

--[[
	Reads one stat's raw value, treating a missing entry as zero. Stats are absent from
	the table until first earned, so callers should never index Stats directly.
]]
function ProfileController:GetStat(statId: Types.StatId): number
	local data = current
	if data == nil then
		return 0
	end
	return data.Stats[statId] or 0
end

return ProfileController
