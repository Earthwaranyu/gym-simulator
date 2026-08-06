--!strict
--[[
	VipService — the VIP gamepass's daily immortal potion.

	Kept out of the gamepass product module because a daily claim is a recurring
	entitlement with its own remote and its own reset rule, not a one-shot grant.

	The reset is calendar-based (a UTC date string) rather than a rolling 24-hour
	timer. That is a deliberate trade: a player who claims at 23:59 can claim again at
	00:01, but "once a day" matches what players expect a daily to mean, and a rolling
	timer punishes anyone whose play session drifts later each day.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

local VIP_PRODUCT_ID = "Vip"
local DAILY_POTION_SECONDS = 60 * 60

local VipService = {
	Name = "VipService",
	Priority = 20,
}

local DataService: any = nil
local PurchaseService: any = nil
local ImmortalityService: any = nil

function VipService:Init()
	DataService = Loader.Get("DataService")
	PurchaseService = Loader.Get("PurchaseService")
	ImmortalityService = Loader.Get("ImmortalityService")
end

local function today(): string
	return os.date("!%Y-%m-%d") :: string
end

function VipService:IsVip(player: Player): boolean
	local product = PurchaseService:GetProduct(VIP_PRODUCT_ID)
	if product == nil then
		return false
	end
	return PurchaseService:OwnsGamepass(player, product.AssetId)
end

--[[
	Whether the player has a daily potion waiting. False for non-VIPs and for anyone
	who already claimed today.
]]
function VipService:CanClaim(player: Player): boolean
	local data = DataService:GetData(player)
	if data == nil then
		return false
	end
	if data.VipLastClaimDay == today() then
		return false
	end
	return self:IsVip(player)
end

--[[
	Claims the daily potion. Returns (success, message) for display in a toast.
]]
function VipService:Claim(player: Player): (boolean, string)
	local data = DataService:GetData(player)
	if data == nil then
		return false, "Your data is still loading."
	end

	if data.VipLastClaimDay == today() then
		return false, "You have already claimed today. Come back tomorrow."
	end

	if not self:IsVip(player) then
		return false, "VIP only."
	end

	-- Stamped before granting, so a failure inside Grant cannot leave a claimable day
	-- open to be re-run in a loop.
	data.VipLastClaimDay = today()
	DataService:MarkDirty(player)

	ImmortalityService:Grant(player, DAILY_POTION_SECONDS)

	return true, "Claimed your VIP daily potion — immortal for 1 hour."
end

function VipService:Start()
	Net.BindFunction("ClaimVipDaily", 1, function(player: Player)
		return self:Claim(player)
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(function()
			if self:CanClaim(player) then
				Net.Event("Notify"):FireClient(player, "Your VIP daily potion is ready to claim.")
			end
		end)
	end)
end

return VipService
