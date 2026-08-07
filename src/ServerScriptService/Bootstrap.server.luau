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
local Formulas = require(ReplicatedStorage.Modules.Formulas)

require(ReplicatedStorage.Modules.Net)

if RunService:IsStudio() then
	-- Formulas' self-test holds the PvP balance invariants — that a maxed player
	-- cannot one-shot a beginner, that time-to-kill is stable at every scale. It
	-- existed for a long time without anything calling it, which meant a retuned
	-- weight could break combat silently. scripts/check.sh runs it before a commit
	-- now; this catches a build that reached Studio anyway.
	for _, suite in
		{
			{ Name = "NumberFormat", Failures = NumberFormat.RunSelfTest() },
			{ Name = "Formulas", Failures = Formulas.RunSelfTest() },
		}
	do
		if #suite.Failures > 0 then
			warn(`[Bootstrap] {suite.Name} self-test failed ({#suite.Failures}):`)
			for _, failure in suite.Failures do
				warn(`  - {failure}`)
			end
		end
	end
end

Loader.AddContainer(ServerScriptService.Core)
Loader.Ignite()
