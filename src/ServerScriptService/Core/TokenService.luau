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
local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)

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
	Awards an amount stated at Natural, scaled to what the player's class is worth.

	Income doubles with every physique class, so a flat grant decays: four hundred tokens
	is well over an hour of play to a Natural and about forty seconds to a Mythic. A pack
	sold as "400 tokens" would quietly become worthless to exactly the players most likely
	to buy one.

	The number on a pack is therefore its Natural value, and this converts it, so what a
	pack is really selling is a fixed stretch of progress at any point in the game.

	The token shop priced its items by the same rule and for the same reason. It is gone
	— boosts are Robux-only and tokens buy the per-stat multipliers — so this is now the
	only place the class multiplier is used to hold a number's meaning steady.
]]
function TokenService:AwardClassScaled(player: Player, baseAmount: number): boolean
	local data = DataService:GetData(player)
	local level = if data ~= nil then data.MuscleClassLevel else 0
	local class = MuscleClassConfig.Get(level)
	return self:AwardTokens(player, baseAmount * class.TokenMultiplier)
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
	-- Boss kills are the one combat source of training Tokens. Everything else pays
	-- Tokens for time; this pays for a trip and a fight, which is why the lump is large
	-- enough to be worth planning around and why only bosses grant it.
	Loader.Get("MobService").MobKilled:Connect(function(killer: Player, mob)
		if mob.Kind ~= "Boss" then
			return
		end
		-- Same class scaling and same tier cap the goblins use, through the same
		-- function, so the two currencies cannot drift apart.
		local data = DataService:GetData(killer)
		local classLevel = if data ~= nil then data.MuscleClassLevel else 0
		local reward = (mob.TokenReward or 0) * MobConfig.RewardMultiplier(mob, classLevel)
		if reward > 0 then
			self:AwardTokens(killer, reward)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Formulas.TOKEN_TICK_SECONDS)

			for _, player in Players:GetPlayers() do
				if self:IsAccruing(player) then
					-- The physique class multiplies the tick. Everything else in this
					-- economy doubles per step, and a flat income against doubling costs
					-- would make each multiplier tier take twice as long as the last with
					-- nothing a player could do about it. Prestige is that something.
					local data = DataService:GetData(player)
					local level = if data ~= nil then data.MuscleClassLevel else 0
					local class = MuscleClassConfig.Get(level)
					self:AwardTokens(player, Formulas.TokensPerTick() * class.TokenMultiplier)
				end
			end
		end
	end)
end

return TokenService
