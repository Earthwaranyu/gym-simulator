--!strict
--[[
	Server entry point. The only Script on the server — everything else is a system
	module under Core/ that the Loader discovers.

	Requiring Net first is load-bearing: it creates the Remotes folder, so it exists
	before any client asks for it and before any service tries to attach a handler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

require(ReplicatedStorage.Modules.Net)

if RunService:IsStudio() then
	local failures = NumberFormat.RunSelfTest()
	if #failures > 0 then
		warn(`[Bootstrap] NumberFormat self-test failed ({#failures}):`)
		for _, failure in failures do
			warn(`  - {failure}`)
		end
	end
end

Loader.AddContainer(ServerScriptService.Core)
Loader.Ignite()
