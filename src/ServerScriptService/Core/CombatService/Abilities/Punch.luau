--!strict
--[[
	Punch — the starter attack, and the reference implementation of Types.Ability.

	Everything an attack needs is declared here. CombatService discovers this file at
	startup; adding a Slam or a Dash means copying this shape into a new file in this
	folder, with no edits anywhere else.

	One click is one swing. Click again in time and it chains — jab, then cross, then
	finisher — and if you stop, the next click starts the chain over.

	It used to be one click that played a 0.9-second clip landing all three contacts on
	its own, so a player pressed once and watched. That read as a cutscene rather than
	as fighting: the "three-hit combo" was something the game did to you rather than
	something you did. The three swings still total exactly one old punch's damage and
	still occupy roughly the same 0.9 seconds, so nothing about time-to-kill moved —
	what moved is who is throwing the punches.

	An attack deals damage and nothing else. No stat gain, no power: power comes from
	the machines, and combat is what takes it away from somebody.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)

-- Held as a constant rather than read back off the table: inside Execute, a reference
-- to `Punch` would resolve to a global, since the local is not yet bound while the
-- table constructor is still being evaluated.
local DAMAGE_MULTIPLIER = 1

--[[
	The chain, in order. Each step names its clip, what share of a punch it deals, and
	how hard it reads.

	The shares total one, which is the whole of the balance decision: three clicks deal
	what one old punch did, so a player who chains is not out-damaging the game's
	existing numbers — they are landing the same punch in three pieces they chose.

	The impacts are deliberately steeper than the shares. Damage has to add up to one
	punch, but how a hit *reads* does not, and that gap is what makes the finisher feel
	like the point of the chain. Formulas' self-test pins 0.3 / 0.45 / 0.8 to the Light,
	Solid and Crushing bands, so retuning either list cannot quietly flatten the
	escalation.
]]
local CHAIN = {
	{ StrikeId = "PunchJab", Share = 0.25, Impact = 0.3 },
	{ StrikeId = "PunchCross", Share = 0.3, Impact = 0.45 },
	{ StrikeId = "PunchFinish", Share = 0.45, Impact = 0.8 },
}

local STRIKES: { [string]: StrikeConfig.Strike } = {}
for _, step in CHAIN do
	local strike = StrikeConfig.Get(step.StrikeId)
	assert(strike ~= nil, `StrikeConfig must define {step.StrikeId}`)
	STRIKES[step.StrikeId] = strike
end

local ENTRY = AbilityConfig.Get("Punch")
assert(ENTRY ~= nil, "AbilityConfig must define Punch")

-- How long after a swing the chain still counts as running. Miss it and the next click
-- starts at the jab again. Generous against the cooldown on purpose: the window is
-- judged on the server's clock, so a player on a bad connection should not find their
-- chain resetting more often than it looks like it should.
local CHAIN_WINDOW = 0.6

local CONTACT_RANGE = 18 * 1.35

--[[
	Where each player is in the chain.

	Weak-keyed, and that is load-bearing. An ability is a plain table discovered by
	CombatService; it has no Init, no Start, and no PlayerRemoving hook — those belong
	to the service, and reaching into it for one would put punch-specific knowledge into
	a system that deliberately has none. A plain table keyed by Player would instead
	hold a reference to every player who ever joined, for the life of the server. Weak
	keys mean a player who leaves is simply collected.
]]
type ChainState = { Index: number, LastAt: number }
local chains: { [Player]: ChainState } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Advances the chain and returns the step to throw.

	Reads and writes in one place so the "did the window expire" question is answered
	exactly once per swing — splitting it across a read here and a write there is how
	a chain ends up advancing twice on a single click.
]]
local function nextStep(player: Player): { StrikeId: string, Share: number, Impact: number }
	local now = os.clock()
	local state = chains[player]

	local index = 1
	if state ~= nil and now - state.LastAt <= CHAIN_WINDOW then
		-- Wraps rather than sticking on the finisher, so a player who keeps clicking
		-- gets jab, cross, finisher, jab — the chain repeating, which is what "three
		-- clicks, three hits" means when somebody does not stop at three.
		index = state.Index % #CHAIN + 1
	end

	chains[player] = { Index = index, LastAt = now }
	return CHAIN[index]
end

local Punch: Types.Ability = {
	Id = "Punch",
	DisplayName = "Punch",
	-- One swing, not one chain. Shorter than the jab's own clip on purpose: the next
	-- click cuts into the previous swing's recovery, which is what makes a chain feel
	-- like a chain rather than three punches waiting their turn. StrikeConfig's
	-- self-test pins this against the clip from both directions.
	Cooldown = ENTRY.Cooldown,
	Range = 18,
	DamageMultiplier = DAMAGE_MULTIPLIER,
	AutoTarget = true,
	-- False so a swing at empty air still reaches Execute. The punch animation is
	-- thrown by the server (below) and a punch that only animated when it connected
	-- meant a player standing alone in a gym pressed the attack and saw nothing at
	-- all. CombatService still discards a target that is dead or out of range before
	-- calling in, so "no target" here means exactly that and the damage below is
	-- unreachable without a valid victim.
	RequiresTarget = false,

	Execute = function(context: Types.AbilityContext, combatService: any)
		local step = nextStep(context.Attacker)
		local strike = STRIKES[step.StrikeId]

		-- The swing happens first and unconditionally, because throwing a punch and
		-- landing one are different events. Every client watches this attribute and
		-- plays the animation locally (StrikeController); nothing about the animation
		-- itself is replicated, because the numbers already ship with the game.
		--
		-- A number rather than a flag so two punches in a row are two events, and
		-- stamped on the character rather than sent to the attacker so that everyone
		-- in the room sees the arm go out — including the victim, for whom it is the
		-- only warning they are being attacked.
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE, step.StrikeId)
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ATTRIBUTE, workspace:GetServerTimeNow())

		-- Everything past here is the hit, which needs something to hit. CombatTarget
		-- rather than Target: a punch lands on a mob exactly as it lands on a
		-- player, and ApplyDamageToTarget is what knows the difference.
		local target = context.CombatTarget
		if target == nil then
			return
		end

		local baseDamage = combatService:GetBaseDamage(context.Attacker)
		local attackerRoot = context.AttackerRoot
		local targetRoot = target.Root

		task.delay(strike.Duration * strike.Contacts[1], function()
			if
				attackerRoot.Parent == nil
				or targetRoot.Parent == nil
				or (attackerRoot.Position - targetRoot.Position).Magnitude > CONTACT_RANGE
			then
				return
			end
			combatService:ApplyDamageToTarget(
				context.Attacker,
				target,
				baseDamage * DAMAGE_MULTIPLIER * step.Share,
				step.Impact
			)
		end)

		-- Deliberately no knockback, where the heavy and the slam both have one.
		-- CONTACT_RANGE is 24 studs and the slowest knockback is 40 studs a second, so
		-- shoving the target would carry them out of reach of the rest of the chain and
		-- quietly turn three swings into one. The flinch is what says the hit landed;
		-- the shove belongs to the attacks that are over in one blow.

		-- Landing a hit pays no stats. It used to pay 0.25 Arms, on the reasoning that
		-- throwing a punch is arm training — but that made hitting people a way to
		-- grow the stat that makes you hit harder, and the whole point of the machines
		-- is that training is where power comes from. Fighting costs the victim their
		-- training time; it is not a second way to earn.
	end,
}

return Punch
