--!strict
--[[
	AnnounceController — world news, posted to chat.

	The split this exists to draw: **chat is what happened in the world, toasts are what
	happened to you.** A boss rising and a player going on a streak are news for
	everyone, and both used to arrive as toasts — sharing a lane with "Knocked off the
	machine!" and vanishing after four seconds with no way to look back at them.

	Chat is the right shape for that. It already keeps a scrollback, it is already on
	screen, and a player who missed the moment can still read what happened.

	Posted from the client rather than the server on purpose. `TextChannels` is
	populated at runtime, and a player whose chat is unavailable should quietly not see
	the line — not make a boss spawn throw on the server. Everything here is guarded for
	that reason: an announcement failing to display must never be able to break the
	event that produced it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)

local AnnounceController = {
	Name = "AnnounceController",
	Priority = 8,
}

local CHANNEL_TIMEOUT = 10

local channel: TextChannel? = nil

--[[
	Rich text markup is a tiny HTML, so anything that could be read as a tag has to be
	escaped before the message goes inside one. Mob display names come from config
	today, but a bounty line carries a player's display name, and that is not a string
	this code gets to make assumptions about.
]]
local function escape(text: string): string
	local safe = string.gsub(text, "&", "&amp;")
	safe = string.gsub(safe, "<", "&lt;")
	safe = string.gsub(safe, ">", "&gt;")
	return safe
end

function AnnounceController:Start()
	-- Resolved once, off the main path: TextChannels appears a moment after join, and
	-- waiting for it inside the handler would drop the first announcement of a session.
	task.spawn(function()
		local channels = TextChatService:WaitForChild("TextChannels", CHANNEL_TIMEOUT)
		if channels == nil then
			return
		end

		local general = channels:WaitForChild("RBXGeneral", CHANNEL_TIMEOUT)
		if general ~= nil and general:IsA("TextChannel") then
			channel = general
		end
	end)

	Net.Event("Announce").OnClientEvent:Connect(function(message: any, colour: any)
		if type(message) ~= "string" then
			return
		end

		local target = channel
		if target == nil then
			return
		end

		local tint = if typeof(colour) == "Color3" then colour else UI.Palette.Danger

		pcall(function()
			target:DisplaySystemMessage(`<font color="#{tint:ToHex()}">{escape(message)}</font>`)
		end)
	end)
end

return AnnounceController
