--!strict
--[[
	Announce — server-wide news, in one call.

	Both callers used to hand-roll the same loop:

		for _, other in Players:GetPlayers() do
			Net.Event("Notify"):FireClient(other, message)
		end

	which is a broadcast written as N unicasts, and — worse — put world news into the
	personal notification stack, where it sat next to "Knocked off the machine!" and
	expired after four seconds.

	This is a plain module rather than a Loader system because it holds no state and
	needs no lifecycle: it is one FireAllClients and a default colour. A service that
	wants to announce something should not have to think about ignite order to do it.

	The colour travels with the message rather than being decided on the client, so a
	future announcement can be a different colour without the client learning what
	kinds of announcement exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)

local Announce = {}

--[[
	Posts one line of world news to every player's chat.

	`colour` defaults to the palette's red, which is what a boss rising and a bounty
	worth hunting both want: this is news you may need to act on.
]]
function Announce.Broadcast(message: string, colour: Color3?)
	Net.Event("Announce"):FireAllClients(message, colour or UI.Palette.Danger)
end

return Announce
