--!strict
--[[
	ManualTrainingService — training with the mouse, anywhere in the world.

	Machines are the *good* way to train: they pay the zone multiplier, which runs to
	x100M in the late districts. This is the floor beneath that — pick a muscle with
	the number keys, hold left mouse, and it grows. It means a new player is training
	within a second of spawning instead of walking to find a bench, and it means
	there is always something to do while waiting for an occupied machine.

	Three properties matter, and all three come from the same decision — the server
	owns the clock:

	  * **Spamming earns nothing extra.** The client sends "still holding", never
	    "give me a rep". One uninterrupted second earns one tick, so a hundred clicks
	    a second and one held button pay identically. There is no number in the message to
	    inflate and no per-click grant to farm, which is what makes an auto-clicker
	    pointless rather than merely against the rules.
	  * **The rate is the stat's own multiplier.** The universal base is one per second and
	    goes through StatService, which applies the modifier stack — so a Core on
	    x4 earns +4/s exactly as the Info screen advertises, and token upgrades and
	    boosts compose without this file knowing they exist.
	  * **It never stacks with a machine.** A mounted player is already training on the
	    server's one-second machine clock. Mouse hold is the anywhere fallback, not a
	    second payout source hidden on top of the same workout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Types = require(ReplicatedStorage.Modules.Types)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

-- How long a ping keeps the player "training" for. Longer than the client's 0.4s
-- re-ping so an ordinary frame hitch does not drop the hold, short enough that
-- letting go stops the gain before the player notices they are still earning.
local ACTIVE_WINDOW = 0.9

-- Check holds more often than they pay so starting shortly after a global scheduler
-- boundary never delays the first reward. Each individual hold still owns a strict
-- one-second NextGainAt clock.
local CHECK_INTERVAL = 0.1

-- Client pings are rate limited here as well as paid by the server clock. Flooding
-- cannot move NextGainAt; this also stops it being *free* in bandwidth.
local PING_BUDGET_PER_SECOND = 8

local ManualTrainingService = {
	Name = "ManualTrainingService",
	Priority = 5,
}

type Hold = {
	StatId: Types.StatId,
	Until: number,
	NextGainAt: number,
}

local holds: { [Player]: Hold } = {}

local StatService: any = nil
local TrainingService: any = nil

function ManualTrainingService:Init()
	StatService = Loader.Get("StatService")
	TrainingService = Loader.Get("TrainingService")
end

--[[
	Whether this player may currently earn manual reps for `statId`.

	Mounted on a machine, the answer is always no: the machine already owns the stat
	clock. Off a machine it is always yes — that is the point of the fallback.
]]
function ManualTrainingService:_allowed(player: Player, _statId: Types.StatId): boolean
	return TrainingService:GetSession(player) == nil
end

function ManualTrainingService:Start()
	Net.BindEvent("ManualTrain", PING_BUDGET_PER_SECOND, function(player: Player, statId: any)
		if statId == "Stop" then
			holds[player] = nil
			return
		end

		-- The one thing the client is trusted for is *which* muscle, and even that is
		-- checked against the config rather than taken on faith.
		if type(statId) ~= "string" or not StatConfig.IsValid(statId) then
			return
		end

		local now = os.clock()
		local existing = holds[player]

		if existing ~= nil and existing.StatId == statId then
			existing.Until = now + ACTIVE_WINDOW
			return
		end

		-- A new hold, or a switch to a different muscle. Either way the clock starts
		-- now: switching muscles must not bank the time spent on the previous one.
		holds[player] = {
			StatId = statId,
			Until = now + ACTIVE_WINDOW,
			NextGainAt = now + 1,
		}
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		holds[player] = nil
	end)

	local accumulated = 0
	RunService.Heartbeat:Connect(function(delta: number)
		accumulated += delta
		if accumulated < CHECK_INTERVAL then
			return
		end
		accumulated = 0

		local now = os.clock()
		for player, hold in holds do
			if player.Parent == nil then
				holds[player] = nil
				continue
			end

			if now < hold.NextGainAt then
				if now > hold.Until then
					holds[player] = nil
				end
				continue
			end

			-- A scheduled second that was still inside the client's hold window is valid
			-- even if this 0.1s check arrived just after the window. Never catch up with
			-- multiple rewards in one frame: a visible tick is always exactly one second.
			if hold.NextGainAt > hold.Until then
				holds[player] = nil
				continue
			end
			hold.NextGainAt = now + 1

			-- A dead player earns nothing, the same rule TokenService applies. Being
			-- knocked off a machine should cost the attacker's victim something.
			local character = player.Character
			local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid == nil or humanoid.Health <= 0 then
				if now > hold.Until then
					holds[player] = nil
				end
				continue
			end

			if not self:_allowed(player, hold.StatId) then
				if now > hold.Until then
					holds[player] = nil
				end
				continue
			end

			-- Through AddStat, so the modifier stack turns the universal +1 base rate
			-- into the multiplier the player was shown. Manual rewards use the same
			-- single replacement popup as equipment rewards.
			local gained = StatService:AddStat(player, hold.StatId, Formulas.BASE_TRAINING_PER_SECOND)
			if gained > 0 then
				local payload: Types.TrainingGain = {
					StatId = hold.StatId,
					Amount = gained,
					PerSecond = gained,
					Combo = 0,
					ComboGoal = 0,
					ComboMultiplier = 1,
				}
				Net.Event("TrainingGain"):FireClient(player, payload)
			end

			if now > hold.Until then
				holds[player] = nil
			end
		end
	end)
end

return ManualTrainingService
