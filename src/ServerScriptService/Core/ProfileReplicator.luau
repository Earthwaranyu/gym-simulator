--!strict
--[[
	ProfileReplicator — pushes each player's profile to that player, and only that player.

	Systems mutate data and call DataService:MarkDirty(). This batches those marks per
	frame, so a burst of twenty stat awards in one tick costs one remote call, not twenty.

	Replication is one-way by construction: the client receives a serialised copy across
	the remote, so nothing it does to that table can reach the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

local ProfileReplicator = {
	Name = "ProfileReplicator",
	Priority = 50,
}

local dirty: { [Player]: true } = {}
local remote: RemoteEvent

function ProfileReplicator:Init()
	remote = Net.Event("ProfileChanged")
end

function ProfileReplicator:Start()
	local DataService = Loader.Get("DataService")

	DataService.ProfileLoaded:Connect(function(player: Player)
		dirty[player] = true
	end)

	DataService.DataChanged:Connect(function(player: Player)
		dirty[player] = true
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		dirty[player] = nil
	end)

	RunService.Heartbeat:Connect(function()
		if next(dirty) == nil then
			return
		end

		-- Swap rather than clear in place, so a MarkDirty fired from a listener
		-- during this loop lands in the next batch instead of mutating what we
		-- are iterating.
		local pending = dirty
		dirty = {}

		for player in pending do
			local data = DataService:GetData(player)
			if data ~= nil then
				remote:FireClient(player, data)
			end
		end
	end)
end

return ProfileReplicator
