--!strict
--[[
	Ground Slam — the area attack.

	Punch is the move you throw; this is the move you commit to. It takes nearly three
	quarters of a second to land, announces itself with a ring on the floor the whole
	way down, and then hits everybody standing inside that ring at once.

	The trade is deliberate. A slam that landed as fast as a punch would simply be a
	punch that hits more people, and there would be no reason to ever throw the punch.
	What the long telegraph buys is the only interesting decision in a group fight:
	everyone who can see the ring gets to choose between walking out of it, eating it,
	or putting a guard up — and the slammer, mid-animation and unable to change their
	mind, gets to be wrong about which they will do.

	Nothing here is new machinery. Radius targeting, knockback and the damage routing
	all live in CombatService, which is what makes this file a description of one move
	rather than an implementation of area combat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)

local STRIKE = StrikeConfig.Get("GroundSlam")
assert(STRIKE ~= nil, "StrikeConfig must define GroundSlam")
local ENTRY = AbilityConfig.Get("GroundSlam")
assert(ENTRY ~= nil, "AbilityConfig must define GroundSlam")

-- How wide this particular slam reaches, stamped on the character for the same reason
-- the strike itself is: it is one number that everybody in the room needs and nobody
-- needs privately, and the attribute already replicates to exactly that set of people.
--
-- Only the radius crosses. Where and when are already known — the epicentre is the
-- floor under the character and the timing is the strike's own contact marker, which
-- every client already has in StrikeConfig.
local RADIUS_ATTRIBUTE = "SlamRadius"

--[[
	The point the shockwave comes out of.

	The animation drives the avatar downward with a Motor6D transform, so the actual
	HumanoidRootPart never moves and the epicentre is simply the floor under the
	player. Raycasting for the real floor height would be more correct and would also
	mean the crater silently fails to appear on any surface the ray happens to miss —
	a moving platform, a thin catwalk — so the offset is a fixed drop from the root.
]]
local ROOT_TO_FLOOR = 3

local Slam: Types.Ability = {
	Id = "GroundSlam",
	DisplayName = ENTRY.DisplayName,
	Cooldown = ENTRY.Cooldown,
	-- The blast radius is resolved per-cast from Legs; this is only what CombatService
	-- uses to decide whether the client's claimed target was plausible. It is the
	-- widest the blast can ever be, so range never rejects a slam that would have hit.
	Range = Formulas.BASE_SLAM_RADIUS + Formulas.MAX_SLAM_RADIUS_BONUS,
	DamageMultiplier = Formulas.SLAM_DAMAGE_MULTIPLIER,
	-- Positional, not target-locked. A slam is aimed at the floor you are standing on,
	-- so there is no target to auto-acquire and no target to require: throwing one in
	-- an empty room is a legitimate thing to do and it still cracks the floor.
	AutoTarget = false,
	RequiresTarget = false,

	Execute = function(context: Types.AbilityContext, combatService: any)
		local character = context.AttackerCharacter
		local root = context.AttackerRoot

		character:SetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE, "GroundSlam")
		character:SetAttribute(StrikeConfig.STRIKE_ATTRIBUTE, workspace:GetServerTimeNow())

		local attacker = context.Attacker
		local baseDamage = combatService:GetBaseDamage(attacker)
		local legs = combatService:GetStat(attacker, "Legs")
		local arms = combatService:GetStat(attacker, "Arms")
		local radius = Formulas.SlamRadius(legs)

		-- Announced immediately so the ring is on the floor for the whole wind-up. The
		-- radius travels with it: an opponent has to be able to see how far is far
		-- enough, and a telegraph that lies about its size is worse than none.
		character:SetAttribute(RADIUS_ATTRIBUTE, radius)

		task.delay(STRIKE.Duration * STRIKE.Contacts[1], function()
			-- Re-resolved at the moment of impact rather than captured at the start.
			-- Three quarters of a second is long enough to die, respawn, walk into a
			-- safe zone, or for everybody in the circle to have left it.
			if root.Parent == nil then
				return
			end
			local epicentre = root.Position - Vector3.yAxis * ROOT_TO_FLOOR

			for _, target in combatService:GetTargetsInRadius(attacker, epicentre, radius) do
				local offset = target.Root.Position - epicentre
				local falloff = Formulas.SlamFalloff(offset.Magnitude, radius)
				if falloff <= 0 then
					continue
				end

				-- Damage first, knockback second, and knockback regardless of whether
				-- the damage landed. Being shoved by a slam you fully blocked is
				-- correct: the shockwave is physical and your guard stopped the harm,
				-- not the force.
				combatService:ApplyDamageToTarget(
					attacker,
					target,
					baseDamage * Formulas.SLAM_DAMAGE_MULTIPLIER * falloff
				)

				local back = if target.Player ~= nil then combatService:GetStat(target.Player, "Back") else 0
				combatService:ApplyKnockback(target, offset, Formulas.KnockbackSpeed(arms, back) * falloff)
			end
		end)
	end,
}

return Slam
