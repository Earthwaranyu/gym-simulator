--!strict
--[[
	BlockService — the guard, and the only defense in the game you have to press.

	Back and Core already defend you. They do it by comparing stats, they do it whether
	you are paying attention or not, and against somebody ten times your size they do
	nothing at all — that is the deliberate SPTS band in Formulas.ResolveDamage. Which
	means that before this file, a fight against anybody meaningfully stronger had no
	inputs in it: you lost at exactly the rate the stat gap said you would.

	The guard is the answer to that. It is generous when you are outmatched on purpose
	(Formulas.MIN_BLOCK_REDUCTION is a floor, not a curve), because a defensive move
	that stops working precisely when you need it is not a move. What it is not is
	free: it drains while it is up, it drains faster while it is eating hits, and when
	it empties it shatters and leaves you worse off than if you had never raised it.

	So the interesting case is the one the abilities were built around. Hard Punch has
	nearly half a second of visible wind-up; you can see it coming and guard it. But
	holding the guard the whole fight empties the meter, and the attacker can see the
	guard is up and simply wait. That is the read, and it is the first one this game
	has had.

	The server owns all of it. The client reports a held button and nothing else — the
	same split as sprint and flight — so a client that never sends "released" gets
	exactly one meter's worth of guard and then a break, which is worse than playing
	honestly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

-- Watched by VfxController for the dome and by HudController for the meter. An
-- attribute rather than a private remote because a guard is public information: the
-- whole point of the read above is that an attacker can see it is up.
local BLOCKING_ATTRIBUTE = "Blocking"
-- The meter as a 0-1 fraction, on the character for the same reason. Rounded before
-- it is written, so a smoothly draining meter does not replicate a new float every
-- frame to every client in the server.
local METER_ATTRIBUTE = "BlockMeter"
local METER_STEPS = 100

-- Held state is one press and one release. This is the same budget sprint gets, and
-- is far more than a human hand produces.
local BLOCK_BUDGET_PER_SECOND = 8

local BlockService = {
	Name = "BlockService",
	-- After CombatService (30), because Start registers a damage modifier with it.
	Priority = 26,
}

type Guard = {
	-- Whether the button is currently held. Distinct from whether the guard is
	-- actually up: a broken guard has this true and is stopping nothing.
	Held: boolean,
	-- Seconds of meter remaining.
	Meter: number,
	-- Capacity, resolved from Core. Cached per raise rather than read per frame.
	Capacity: number,
	-- os.clock() before which the guard cannot come back up.
	BrokenUntil: number,
}

local guards: { [Player]: Guard } = {}

local CombatService: any = nil
local StatService: any = nil
local TrainingService: any = nil

function BlockService:Init()
	CombatService = Loader.Get("CombatService")
	StatService = Loader.Get("StatService")
	TrainingService = Loader.Get("TrainingService")
end

local function guardFor(player: Player): Guard
	local guard = guards[player]
	if guard == nil then
		guard = {
			Held = false,
			Meter = Formulas.BASE_BLOCK_SECONDS,
			Capacity = Formulas.BASE_BLOCK_SECONDS,
			BrokenUntil = 0,
		}
		guards[player] = guard
	end
	return guard
end

--[[
	Whether this player's guard is actually stopping anything right now.

	Three separate things have to be true, and they are separate on purpose: the button
	is held, the meter has something left, and the guard is not inside its post-break
	lockout. Collapsing them into one flag is what would let a broken guard silently
	keep working.
]]
function BlockService:IsBlocking(player: Player): boolean
	local guard = guards[player]
	if guard == nil then
		return false
	end
	return guard.Held and guard.Meter > 0 and os.clock() >= guard.BrokenUntil
end

function BlockService:_publish(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	local guard = guardFor(player)
	local fraction = math.clamp(guard.Meter / math.max(guard.Capacity, 1e-3), 0, 1)
	character:SetAttribute(BLOCKING_ATTRIBUTE, self:IsBlocking(player))
	character:SetAttribute(METER_ATTRIBUTE, math.round(fraction * METER_STEPS) / METER_STEPS)
end

--[[
	Ends a guard that ran out of meter.

	Separate from an ordinary release because it is a punish, not a choice: the button
	stays held, the guard stops working, and BLOCK_BREAK_PENALTY_SECONDS have to pass
	before it can come back — during which the player is standing still in a guard
	stance that is doing nothing, which is exactly the moment an attacker wants.
]]
function BlockService:_break(player: Player)
	local guard = guardFor(player)
	guard.Meter = 0
	guard.BrokenUntil = os.clock() + Formulas.BLOCK_BREAK_PENALTY_SECONDS
	self:_publish(player)
	Net.Event("BlockState"):FireClient(player, { Kind = "Break" })
end

function BlockService:SetHeld(player: Player, held: boolean)
	local guard = guardFor(player)
	if guard.Held == held then
		return
	end

	-- You cannot guard from a machine. Training is the thing PvP interrupts, and a
	-- player who could sit locked into an exercise behind a barrier would remove the
	-- interrupt entirely — which is the one mechanic the whole loop is built on.
	if held and TrainingService:IsTraining(player) then
		return
	end
	if held and os.clock() < guard.BrokenUntil then
		return
	end
	if held and guard.Meter <= 0 then
		return
	end

	guard.Held = held
	if held then
		-- Capacity is resolved on the raise rather than continuously, so a guard cannot
		-- grow underneath you mid-hit and a training payout landing during a block does
		-- not silently refill it.
		guard.Capacity = Formulas.BlockMeter(StatService:GetStat(player, "Core"))
		guard.Meter = math.min(guard.Meter, guard.Capacity)
		Net.Event("BlockState"):FireClient(player, { Kind = "Raise" })
	end
	self:_publish(player)
end

--[[
	The damage modifier CombatService calls on every hit that reaches a player.

	Returns what should survive the guard. Draining here rather than on a timer is what
	makes the guard break under pressure as well as under time: absorbing a full health
	bar's worth costs BLOCK_DAMAGE_DRAIN_SECONDS of meter regardless of how long the
	button has been down, so standing in a slam is expensive even if you only stood in
	it for an instant.
]]
function BlockService:_absorb(victim: Player, attacker: Player?, damage: number): number
	if not self:IsBlocking(victim) then
		return damage
	end

	local attackerArms = if attacker ~= nil then StatService:GetStat(attacker, "Arms") else 0
	local reduction = Formulas.BlockReduction(StatService:GetStat(victim, "Back"), attackerArms)
	local absorbed = damage * reduction

	local guard = guardFor(victim)
	guard.Meter -= Formulas.BlockDrainForAbsorbed(
		absorbed,
		Formulas.MaxHealth(StatService:GetStat(victim, "Chest"))
	)

	if guard.Meter <= 0 then
		-- The hit that empties the meter is still blocked. Breaking on the hit that
		-- broke you would mean a guard is worth nothing against exactly the attack it
		-- was raised for, and the punish is already the three seconds that follow.
		self:_break(victim)
	else
		self:_publish(victim)
		Net.Event("BlockState"):FireClient(victim, { Kind = "Absorb", Absorbed = absorbed })
	end

	return damage - absorbed
end

--[[
	Drains a held guard and regenerates a lowered one.
]]
function BlockService:_tick(deltaTime: number)
	local now = os.clock()
	for player, guard in guards do
		if player.Parent == nil then
			continue
		end

		local before = guard.Meter
		if guard.Held and guard.Meter > 0 and now >= guard.BrokenUntil then
			guard.Meter -= deltaTime
			if guard.Meter <= 0 then
				self:_break(player)
				continue
			end
		elseif not guard.Held and now >= guard.BrokenUntil then
			local capacity = guard.Capacity
			guard.Meter = math.min(capacity, guard.Meter + deltaTime * Formulas.BLOCK_REGEN_PER_SECOND)
		end

		-- Only publish on a visible change. The attribute is rounded to METER_STEPS, so
		-- most frames of a slow drain are the same value and replicating them all would
		-- put a per-frame property write on every client for every guarding player.
		if math.round(before * METER_STEPS) ~= math.round(guard.Meter * METER_STEPS) then
			self:_publish(player)
		end
	end
end

function BlockService:Start()
	CombatService:RegisterDamageModifier({
		Id = "Block",
		Apply = function(victim: Player, attacker: Player?, damage: number): number
			return self:_absorb(victim, attacker, damage)
		end,
	})

	Net.BindEvent("BlockChanged", BLOCK_BUDGET_PER_SECOND, function(player: Player, held: any)
		if type(held) ~= "boolean" then
			return
		end
		self:SetHeld(player, held)
	end)

	local function track(player: Player)
		guardFor(player)
		local function adopt(_character: Model)
			-- A fresh character has no guard and a full meter. Dying to break a block
			-- is already the worst outcome in the exchange; carrying the empty meter
			-- and the lockout through the respawn would punish it twice.
			local guard = guardFor(player)
			guard.Held = false
			guard.BrokenUntil = 0
			guard.Capacity = Formulas.BlockMeter(StatService:GetStat(player, "Core"))
			guard.Meter = guard.Capacity
			self:_publish(player)
		end
		if player.Character ~= nil then
			adopt(player.Character)
		end
		player.CharacterAdded:Connect(adopt)
	end

	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player: Player)
		guards[player] = nil
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		self:_tick(deltaTime)
	end)
end

return BlockService
