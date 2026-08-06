--!strict
--[[
	StaminaService — the per-session resource that paces training.

	Stamina is not saved. It refills on respawn and on rejoin, so it gates how long a
	set runs rather than acting as long-term progress. That matters for the PvP hook:
	draining a victim's stamina is a real setback for the next minute, but costs them
	nothing permanent.

	Max and regen both scale off Core, which is what makes Core worth training even
	though it deals no damage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local StaminaService = {
	Name = "StaminaService",
	Priority = 60,
}

local current: { [Player]: number } = {}
-- Players who should not regenerate this frame, keyed by whoever suppressed them.
local suppressed: { [Player]: boolean } = {}

local StatService: any = nil

-- (player, current, max)
StaminaService.StaminaChanged = Signal.new()

function StaminaService:Init()
	StatService = Loader.Get("StatService")
end

function StaminaService:GetMax(player: Player): number
	return Formulas.MaxStamina(StatService:GetStat(player, "Core"))
end

function StaminaService:Get(player: Player): number
	local value = current[player]
	if value == nil then
		-- First read after joining or respawning: start full.
		value = self:GetMax(player)
		current[player] = value
	end
	return value
end

function StaminaService:_set(player: Player, value: number)
	local max = self:GetMax(player)
	local clamped = math.clamp(value, 0, max)

	if current[player] ~= clamped then
		current[player] = clamped
		StaminaService.StaminaChanged:Fire(player, clamped, max)
	end
end

--[[
	Refills to full. Used on spawn, so death is never punished with an empty bar on
	top of the respawn timer.
]]
function StaminaService:Refill(player: Player)
	self:_set(player, self:GetMax(player))
end

--[[
	Spends stamina if there is enough, and returns whether it succeeded. Callers use
	the false case to stop a set rather than to raise an error.
]]
function StaminaService:TrySpend(player: Player, amount: number): boolean
	if amount <= 0 then
		return true
	end

	local available = self:Get(player)
	if available < amount then
		return false
	end

	self:_set(player, available - amount)
	return true
end

--[[
	Removes stamina without requiring the player to have it — used by the training
	interrupt, where getting punched should hurt even if the bar is nearly empty.
]]
function StaminaService:Drain(player: Player, amount: number)
	local available: number = self:Get(player)
	self:_set(player, available - amount)
end

--[[
	Holds regeneration off while a player is mid-set, so stamina genuinely limits how
	long a set can run.
]]
function StaminaService:SetRegenSuppressed(player: Player, isSuppressed: boolean)
	if isSuppressed then
		suppressed[player] = true
	else
		-- Removed rather than set false, so the regen loop's lookup stays a plain
		-- truthiness check over a sparse table.
		suppressed[player] = nil
	end
end

function StaminaService:Start()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Stat-derived max may have changed since last spawn; recompute by refilling.
			current[player] = nil
			self:Refill(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		current[player] = nil
		suppressed[player] = nil
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		for _, player in Players:GetPlayers() do
			if suppressed[player] then
				continue
			end

			local value = current[player]
			if value == nil then
				continue
			end

			local max = self:GetMax(player)
			if value < max then
				local core = StatService:GetStat(player, "Core")
				self:_set(player, value + Formulas.StaminaRegen(core) * deltaTime)
			end
		end
	end)
end

return StaminaService
