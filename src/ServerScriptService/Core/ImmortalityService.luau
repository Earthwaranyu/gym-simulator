--!strict
--[[
	ImmortalityService — the one sanctioned way to opt out of PvP.

	Immunity is bought with Robux (see MarketplaceService/Products), never earned, and
	it is deliberately timed rather than toggleable. A free opt-out would kill the game:
	most players would switch PvP off and the whole differentiator would evaporate.

	Expiry lives on the profile as an absolute os.time(), so it survives a rejoin and a
	server restart — someone who buys a day potion gets a day, not a session.

	CombatService reads IsImmortal itself; this service owns granting it and showing it.
	The barrier is a real Roblox ForceField, so attackers can see immunity before they
	swing rather than discovering it by wasting a cooldown.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local BARRIER_NAME = "ImmortalBarrier"
local REFRESH_SECONDS = 1

local ImmortalityService = {
	Name = "ImmortalityService",
	Priority = 23,
}

local DataService: any = nil

-- (player, expiresAt)
ImmortalityService.ImmortalityChanged = Signal.new()

function ImmortalityService:Init()
	DataService = Loader.Get("DataService")
end

--[[
	Seconds of immunity left, or 0.
]]
function ImmortalityService:GetRemaining(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return math.max(0, data.ImmortalUntil - os.time())
end

function ImmortalityService:IsImmortal(player: Player): boolean
	return self:GetRemaining(player) > 0
end

--[[
	Adds immunity time. Stacks onto whatever is left rather than replacing it, so
	buying a second potion while one is active is never a downgrade.
]]
function ImmortalityService:Grant(player: Player, seconds: number): boolean
	if seconds <= 0 then
		return false
	end

	local data = DataService:GetData(player)
	if data == nil then
		return false
	end

	local base = math.max(data.ImmortalUntil, os.time())
	data.ImmortalUntil = base + seconds
	DataService:MarkDirty(player)

	self:_applyBarrier(player)
	ImmortalityService.ImmortalityChanged:Fire(player, data.ImmortalUntil)

	Net.Event("Notify"):FireClient(player, `Immortal for {NumberFormat.Duration(self:GetRemaining(player))}.`)

	return true
end

--[[
	Adds or removes the visible bubble to match current state. Idempotent, so the
	refresh loop can call it every second without churning instances.
]]
function ImmortalityService:_applyBarrier(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local existing: Instance? = character:FindFirstChild(BARRIER_NAME)
	local shouldHave = self:IsImmortal(player)

	-- Nested rather than a compound elseif: the type checker over-narrows `existing`
	-- across `shouldHave and existing == nil`, and then rejects the second nil test.
	if shouldHave then
		if existing == nil then
			local field = Instance.new("ForceField")
			field.Name = BARRIER_NAME
			field.Visible = true
			field.Parent = character
		end
	elseif existing then
		existing:Destroy()
	end
end

function ImmortalityService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			-- A fresh character has no barrier; re-add it if they respawn still immune.
			task.defer(function()
				self:_applyBarrier(player)
			end)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			for _, player in Players:GetPlayers() do
				self:_applyBarrier(player)
			end
		end
	end)
end

return ImmortalityService
