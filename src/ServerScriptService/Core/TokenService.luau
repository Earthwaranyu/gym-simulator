--!strict
--[[
	TokenService — awards the currency that buys stat multipliers.

	Tokens accrue for time spent playing, but only while the player is ALIVE, INSIDE
	a gym zone, and SOMEWHERE THEY CAN BE ATTACKED. That condition is what wires the
	economy into the PvP hook: parking a character in a corner earns nothing, and a
	player who does idle in the gym to farm is standing in an open-PvP area as a free
	kill. Dying also forfeits the tick in progress, which is the entire cost of dying
	in this game.

	The safe-zone half of that rule used to be enforced by geometry — zone volumes
	were simply drawn so they never covered the spawn plaza. That worked while the
	gyms were somewhere else, and stopped working the moment the starter gym was
	built around the plaza: a zone volume big enough to hold a ring of machines is
	also big enough to hold the shelter in the middle of it, and no arrangement of
	boxes covers a ring without covering its centre. Enforcing it here instead is
	both simpler and a better rule — it now holds for every safe zone that will ever
	be added, rather than for the ones somebody remembered to draw around.

	Zones are BaseParts tagged "GymZone" in Studio, so the accrual area is level design
	rather than code. Until any exist, the whole map counts — otherwise nothing would
	accrue in a fresh place file and the loop could not be playtested.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local GYM_ZONE_TAG = "GymZone"

local TokenService = {
	Name = "TokenService",
	Priority = 80,
}

local DataService: any = nil
local CombatService: any = nil
local warnedNoZones = false

-- (player, amountAwarded, newTotal)
TokenService.TokensAwarded = Signal.new()

function TokenService:Init()
	DataService = Loader.Get("DataService")
	-- Asking CombatService rather than testing the tag here keeps one definition of
	-- "safe", so a change to how safe zones are shaped cannot make the two disagree.
	CombatService = Loader.Get("CombatService")
end

local function isPointInPart(point: Vector3, part: BasePart): boolean
	local relative = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return math.abs(relative.X) <= half.X
		and math.abs(relative.Y) <= half.Y
		and math.abs(relative.Z) <= half.Z
end

--[[
	True when the player is alive, in a gym zone, and attackable — i.e. earning.
	Also used by the HUD to explain why the token counter has stalled.
]]
function TokenService:IsAccruing(player: Player): boolean
	local character = player.Character
	if character == nil then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	-- No pay where you cannot be hit. The starter gym's zone covers the spawn
	-- plaza it is built around, so without this an AFK body would earn in the one
	-- place nobody can punish it for being AFK.
	if CombatService:IsInSafeZone(player) then
		return false
	end

	local zones = CollectionService:GetTagged(GYM_ZONE_TAG)
	if #zones == 0 then
		if not warnedNoZones then
			warnedNoZones = true
			warn(
				`[TokenService] No parts tagged "{GYM_ZONE_TAG}" — treating the whole map as `
					.. `a gym zone. Tag the gym floor to enable the anti-AFK rule.`
			)
		end
		return true
	end

	for _, zone in zones do
		if zone:IsA("BasePart") and isPointInPart(root.Position, zone) then
			return true
		end
	end

	return false
end

function TokenService:GetTokens(player: Player): number
	local data = DataService:GetData(player)
	return if data ~= nil then data.Tokens else 0
end

--[[
	Adds tokens from any source — the accrual tick, quest rewards, or a product purchase.
	Returns false if the profile is not loaded.
]]
function TokenService:AwardTokens(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local data = DataService:GetData(player)
	if data == nil then
		return false
	end

	data.Tokens += amount
	DataService:MarkDirty(player)
	TokenService.TokensAwarded:Fire(player, amount, data.Tokens)

	return true
end

--[[
	Spends tokens if the player can afford it. Returns false without touching the
	balance when they cannot, so callers never need to pre-check.
]]
function TokenService:TrySpendTokens(player: Player, amount: number): boolean
	local data = DataService:GetData(player)
	if data == nil or amount <= 0 or data.Tokens < amount then
		return false
	end

	data.Tokens -= amount
	DataService:MarkDirty(player)

	return true
end

function TokenService:Start()
	task.spawn(function()
		while true do
			task.wait(Formulas.TOKEN_TICK_SECONDS)

			for _, player in Players:GetPlayers() do
				if self:IsAccruing(player) then
					self:AwardTokens(player, Formulas.TokensPerTick())
				end
			end
		end
	end)
end

return TokenService
