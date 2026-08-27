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
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)
local GaitConfig = require(ReplicatedStorage.Modules.GaitConfig)
local FlinchConfig = require(ReplicatedStorage.Modules.FlinchConfig)
local StanceConfig = require(ReplicatedStorage.Modules.StanceConfig)

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
			-- These two build their poses out of Vector3, so the `luau` CLI cannot
			-- require them and scripts/selftest.luau cannot reach them. Studio is the
			-- only place their invariants can be checked at all — that no joint exceeds
			-- the angle ceiling, that a heavy stays slower to land than a jab, that the
			-- flight silhouettes actually progress from upright to horizontal.
			--
			-- StrikeConfig.RunSelfTest was written and then never called from anywhere.
			{ Name = "StrikeConfig", Failures = StrikeConfig.RunSelfTest() },
			{ Name = "FlightConfig", Failures = FlightConfig.RunSelfTest() },
			{ Name = "GaitConfig", Failures = GaitConfig.RunSelfTest() },
			{ Name = "FlinchConfig", Failures = FlinchConfig.RunSelfTest() },
			{ Name = "StanceConfig", Failures = StanceConfig.RunSelfTest() },
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
