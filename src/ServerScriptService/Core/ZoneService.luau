--!strict
--[[
	ZoneService — gates between gym tiers.

	Touching a gate teleports you into its zone if you have the power for it, and
	refuses with a reason if you do not. Gates are the only enforcement: a player who
	walks or falls into a high tier by other means is not ejected, because yanking
	someone out of a space mid-fight is worse than letting them look around.

	Server-authoritative because the teleport itself must be: a client that could place
	its own character would skip every gate in the game.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

-- Stops one touch firing dozens of times as a character brushes a part.
local TOUCH_COOLDOWN = 1.5

local ZoneService = {
	Name = "ZoneService",
	Priority = 17,
}

local StatService: any = nil
local lastTouchAt: { [Player]: number } = {}

function ZoneService:Init()
	StatService = Loader.Get("StatService")
end

--[[
	Whether a player meets a zone's power requirement.
]]
function ZoneService:CanEnter(player: Player, zone: ZoneConfig.Zone): boolean
	return StatService:GetTotalPower(player) >= zone.RequiredPower
end

local function findSpawn(zoneId: string): BasePart?
	for _, part in CollectionService:GetTagged(ZoneConfig.SPAWN_TAG) do
		if part:IsA("BasePart") and part:GetAttribute(ZoneConfig.ZONE_ATTRIBUTE) == zoneId then
			return part
		end
	end
	return nil
end

function ZoneService:_tryEnter(player: Player, gate: BasePart)
	local now = os.clock()
	if now - (lastTouchAt[player] or 0) < TOUCH_COOLDOWN then
		return
	end
	lastTouchAt[player] = now

	local zone, reason = ZoneConfig.Resolve(gate)
	if zone == nil then
		warn(`[ZoneService] Gate {gate:GetFullName()} is misconfigured: {reason}`)
		return
	end

	if not self:CanEnter(player, zone) then
		local needed = zone.RequiredPower - StatService:GetTotalPower(player)
		Net.Event("Notify")
			:FireClient(player, `{zone.DisplayName} needs {NumberFormat.Format(needed)} more power.`)
		return
	end

	local destination = findSpawn(zone.Id)
	if destination == nil then
		warn(`[ZoneService] Zone "{zone.Id}" has no part tagged "{ZoneConfig.SPAWN_TAG}"`)
		return
	end

	local character = player.Character
	if character == nil then
		return
	end

	-- Above the pad, so the character does not spawn intersecting it.
	character:PivotTo(destination.CFrame + Vector3.new(0, destination.Size.Y / 2 + 4, 0))
	Net.Event("Notify"):FireClient(player, `Welcome to {zone.DisplayName}.`)
end

function ZoneService:_bindGate(gate: Instance)
	if not gate:IsA("BasePart") then
		return
	end

	gate.Touched:Connect(function(hit: BasePart)
		local character = hit:FindFirstAncestorOfClass("Model")
		if character == nil then
			return
		end

		local player = Players:GetPlayerFromCharacter(character)
		if player ~= nil then
			self:_tryEnter(player, gate)
		end
	end)
end

function ZoneService:Start()
	for _, gate in CollectionService:GetTagged(ZoneConfig.GATE_TAG) do
		self:_bindGate(gate)
	end

	CollectionService:GetInstanceAddedSignal(ZoneConfig.GATE_TAG):Connect(function(gate)
		self:_bindGate(gate)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastTouchAt[player] = nil
	end)
end

return ZoneService
