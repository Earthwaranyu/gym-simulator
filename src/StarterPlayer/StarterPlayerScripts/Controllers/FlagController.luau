--!strict
--[[
	FlagController — the client's copy of its own resolved flag values.

	The server sends outcomes, not rules: this file never computes an assignment and
	has nothing to compute it from. Until the first push arrives, every read falls
	back to the declared default in `FlagConfig`, so a controller that starts before
	the network does still renders the shipped behavior rather than nothing.

	Flags read here may only change presentation. Anything a flag would gate that has
	value — a reward, a purchase, an entitlement — is gated on the server, because the
	client's copy is a hint and a hint is forgeable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Modules.Net)
local FlagConfig = require(ReplicatedStorage.Modules.FlagConfig)
local Signal = require(ReplicatedStorage.Packages.Signal)

local FlagController = {
	Name = "FlagController",
	-- Early: UI controllers read flags while building themselves.
	Priority = 2,
}

--- Fires with the whole resolved table whenever the server re-resolves, which
--- happens when a live override changes mid-session.
FlagController.Changed = Signal.new()

local values: { [string]: any } = {}

function FlagController:Init()
	Net.Event("FlagsChanged").OnClientEvent:Connect(function(incoming: any)
		if type(incoming) ~= "table" then
			return
		end
		values = incoming
		FlagController.Changed:Fire(values)
	end)
end

--[[
	The resolved value of a flag, or its default if the server has not spoken yet or
	sent something that does not match the declared type.
]]
function FlagController:Get(flagId: string): any
	local flag = FlagConfig.Get(flagId)
	if flag == nil then
		warn(`[FlagController] Unknown flag "{flagId}"`)
		return nil
	end

	local value = values[flagId]
	if value == nil or not FlagConfig.IsValidValue(flag, value) then
		return flag.Default
	end
	return value
end

return FlagController
