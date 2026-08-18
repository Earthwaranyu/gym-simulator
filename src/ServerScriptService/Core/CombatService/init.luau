--!strict
--[[
	CombatService — server-authoritative PvP, and the reason this game exists.

	Players can attack each other anywhere except tagged SafeZone volumes, including
	while their victim is mid-set at a machine. Hits deal damage but do not knock
	the victim off their machine — only dying does that. The attacker must commit
	to a full kill to disrupt someone's set, which makes the decision to fight
	meaningful rather than just an annoyance.

	Abilities live in the Abilities/ folder next to this file and are discovered at
	startup. Because the Loader does not descend into a ModuleScript's children, they
	are ours to load, not systems in their own right. Adding an attack is one new file
	implementing Types.Ability — there is no registry list here to extend and no
	`if abilityId == "Punch"` anywhere.

	A punch deals exactly the attacker's Arms, to anybody. There used to be a
	power-gap falloff in front of it that scaled a strong player's hit down against a
	weak victim; it was removed deliberately, because it meant the damage you saw bore
	no relation to the stat you had trained — a trillion-power player hit a beginner
	for about fifteen. What protects a new player now is the safe zone they spawn in
	and the immortality potions, not a number quietly divided behind their back.

	The consequence is that a maxed player one-shots a fresh one. That is the intended
	shape of open PvP here.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local SAFE_ZONE_TAG = "SafeZone"
-- Killing the same victim again inside this window still works — griefing is the
-- point of the game — but pays nothing, so farming one person is not a strategy.
local REPEAT_KILL_WINDOW = 120
-- Slow fallback for respawn/property interference. Chest and Legs changes also apply
-- immediately below, so the health bar and Info value never drift for a full second.
local VITALS_REFRESH_SECONDS = 1
-- Generosity on the client's claimed range, to absorb latency.
local RANGE_TOLERANCE = 1.35
-- How long a knockback constraint pushes for. Short: this is an impulse, not a shove.
-- Long enough to clear the ground and let the ragdoll-free Humanoid arc; short enough
-- that a player is back in control before they have time to be annoyed about it.
local KNOCKBACK_SECONDS = 0.16

local CombatService = {
	Name = "CombatService",
	Priority = 30,
}

local abilities: { [Types.AbilityId]: Types.Ability } = {}
local cooldowns: { [Player]: { [Types.AbilityId]: number } } = {}
-- victim -> killer -> os.clock() of the last kill, for the repeat-farm check.
local recentKills: { [Player]: { [Player]: number } } = {}
local sprinting: { [Player]: boolean } = {}

local DataService: any = nil
local StatService: any = nil
local FlightService: any = nil
local TrainingService: any = nil

-- (victim, attacker, damage, isKill)
CombatService.DamageDealt = Signal.new()
-- (victim, killer, isRepeatKill) — isRepeatKill is true when the same killer already
-- knocked this victim out inside REPEAT_KILL_WINDOW. Listeners that hand out rewards
-- must skip those; the kill itself still counts and still annoys the victim.
CombatService.PlayerKilled = Signal.new()
-- (model, killer) — a non-player combatant died. Deliberately a separate signal from
-- PlayerKilled, which seven services consume with a `(Player, Player, boolean)` shape;
-- firing that one with a mob as the victim would break every one of them at once.
CombatService.EntityKilled = Signal.new()

--[[
	Non-player things a player can hit.

	CombatService knows how a punch travels, what a safe zone means and how Back and
	Core resolve a hit. It deliberately does not know what a goblin is. A system that
	owns some other kind of combatant registers a provider here and gets targeting and
	damage routing for free, exactly as a new file in Abilities/ gets an ability.

	`FindNearest` is only ever consulted after the player sweep comes up empty, so
	registering a provider can never make an ability stop aiming at a player.
]]
export type TargetProvider = {
	Id: string,
	Owns: (model: Model) -> boolean,
	FindNearest: (origin: Vector3, range: number, forPlayer: Player) -> (Model?, BasePart?),
	-- Optional: every owned entity inside a radius, for area attacks. Optional rather
	-- than required so registering a provider stays a small commitment and no existing
	-- provider had to change when Ground Slam arrived; GetTargetsInRadius falls back to
	-- FindNearest, which means a provider without this contributes its closest entity
	-- to a blast instead of all of them.
	FindAllInRadius: ((
		origin: Vector3,
		radius: number,
		forPlayer: Player
	) -> { { Model: Model, Root: BasePart } })?,
	-- Returns (damageDealt, wasKilled). The provider owns the entity's health rules.
	ApplyDamage: (attacker: Player, model: Model, damage: number) -> (number, boolean),
}

local targetProviders: { TargetProvider } = {}

--[[
	A last say over how much damage actually lands on a victim.

	Registered rather than branched for the usual reason: CombatService owns the rules
	that come from stats — safe zones, immortality, Back, Core — and deliberately does
	not own the rules that come from what a player is *doing* at that instant. Block is
	the first of those, and it holds a meter, a break state and a cooldown that have no
	business living in here.

	A modifier receives the damage that survived ResolveDamage and returns what should
	survive it. It must be pure and prompt: it runs inside the damage path, so yielding
	in one would stall every hit in the server.
]]
export type DamageModifier = {
	Id: string,
	Apply: (victim: Player, attacker: Player?, damage: number) -> number,
}

local damageModifiers: { DamageModifier } = {}

function CombatService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	FlightService = Loader.Get("FlightService")
	TrainingService = Loader.Get("TrainingService")

	self:_loadAbilities()
end

function CombatService:_loadAbilities()
	local folder = script:FindFirstChild("Abilities")
	if folder == nil then
		warn("[CombatService] No Abilities folder found — nobody can attack.")
		return
	end

	for _, module in folder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(require, module)
		if not ok then
			warn(`[CombatService] Failed to load ability {module.Name}: {result}`)
			continue
		end

		local ability = result :: Types.Ability
		if
			type(ability) ~= "table"
			or type(ability.Id) ~= "string"
			or type(ability.Execute) ~= "function"
		then
			warn(`[CombatService] {module.Name} does not implement the Ability contract`)
			continue
		end

		if abilities[ability.Id] ~= nil then
			warn(`[CombatService] Duplicate ability id "{ability.Id}" in {module.Name}`)
			continue
		end

		abilities[ability.Id] = ability
	end

	local count = 0
	for _ in abilities do
		count += 1
	end
	print(`[CombatService] Loaded {count} abilities`)
end

function CombatService:GetAbility(abilityId: Types.AbilityId): Types.Ability?
	return abilities[abilityId]
end

local function isPointInPart(point: Vector3, part: BasePart): boolean
	local relative = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return math.abs(relative.X) <= half.X
		and math.abs(relative.Y) <= half.Y
		and math.abs(relative.Z) <= half.Z
end

--[[
	True while the player stands in a tagged SafeZone. Checked for attacker and victim
	alike, so a safe zone can neither be attacked into nor sniped out of.
]]
function CombatService:IsInSafeZone(player: Player): boolean
	local character = player.Character
	if character == nil then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	for _, zone in CollectionService:GetTagged(SAFE_ZONE_TAG) do
		if zone:IsA("BasePart") and isPointInPart(root.Position, zone) then
			return true
		end
	end

	return false
end

--[[
	True while the player has an unexpired immortal potion. The potion is bought with
	Robux, so this is the only sanctioned way to opt out of PvP.
]]
function CombatService:IsImmortal(player: Player): boolean
	local data = DataService:GetData(player)
	if data == nil then
		return false
	end
	return data.ImmortalUntil > os.time()
end

local function getLivingParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil, nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil, nil, nil
	end

	return character, humanoid, root
end

-- Server-side fallback for forgiving melee. The client normally supplies its nearest
-- candidate, but streaming, a character spawning during the click, or a modified
-- camera controller can leave that nil. Distance is the only targeting rule here;
-- ApplyDamage still owns safe zones, immortality and every combat permission.
local function nearestLivingTarget(
	attacker: Player,
	origin: Vector3,
	range: number
): (Player?, Model?, BasePart?)
	local bestPlayer: Player? = nil
	local bestCharacter: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = range

	for _, candidate in Players:GetPlayers() do
		if candidate == attacker then
			continue
		end
		local character, _, root = getLivingParts(candidate)
		if character == nil or root == nil then
			continue
		end
		local distance = (origin - root.Position).Magnitude
		if distance <= bestDistance then
			bestDistance = distance
			bestPlayer = candidate
			bestCharacter = character
			bestRoot = root
		end
	end

	return bestPlayer, bestCharacter, bestRoot
end

--[[
	The same sweep over registered non-player providers. Kept separate from the player
	sweep and always called after it, so a mob standing closer than an enemy player
	never steals the swing: in a PvP game the person is the target that matters.
]]
local function nearestEntityTarget(attacker: Player, origin: Vector3, range: number): (Model?, BasePart?)
	local bestModel: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = range

	for _, provider in targetProviders do
		local model, root = provider.FindNearest(origin, bestDistance, attacker)
		if model ~= nil and root ~= nil then
			local distance = (origin - root.Position).Magnitude
			if distance <= bestDistance then
				bestDistance = distance
				bestModel = model
				bestRoot = root
			end
		end
	end

	return bestModel, bestRoot
end

--[[
	Applies damage from one player to another, with every PvP rule in one place:
	safe zones, immortality, Back's ratio-based block and Core's ratio-based
	reflection.

	`isRetaliation` marks true return damage sent by Core. It cannot trigger Core again
	or pass through Back, so a displayed reflection amount is exact and a single punch
	cannot bounce forever. It still passes through this function so safe zones,
	immortality, kill credit and Fight Token rewards remain server-authoritative.

	Returns the damage actually dealt, which is zero for any blocked hit.
]]
--[[
	Registers a source of non-player targets. Call from a system's Start.
]]
function CombatService:RegisterTargetProvider(provider: TargetProvider)
	for _, existing in targetProviders do
		if existing.Id == provider.Id then
			warn(`[CombatService] Target provider "{provider.Id}" is already registered`)
			return
		end
	end
	table.insert(targetProviders, provider)
end

--[[
	Registers a damage modifier. Call from a system's Start, same as a target provider.
]]
function CombatService:RegisterDamageModifier(modifier: DamageModifier)
	for _, existing in damageModifiers do
		if existing.Id == modifier.Id then
			warn(`[CombatService] Damage modifier "{modifier.Id}" is already registered`)
			return
		end
	end
	table.insert(damageModifiers, modifier)
end

--[[
	Everything an attacker could hit inside a radius — players first, then whatever the
	registered providers own.

	The single-target sweeps above return the nearest and stop; an area attack needs all
	of them, so this is the same walk with the "keep the best" replaced by "keep them
	all". Deliberately not written in terms of nearestLivingTarget: calling that in a
	loop and excluding what it already returned is quadratic and, worse, gets the
	exclusion wrong the moment two entities share a position.

	Liveness and distance are the only rules applied here. Safe zones, immortality and
	the stat-based defenses stay where they have always been, in ApplyDamage, so an
	area attack cannot accidentally acquire a weaker rule set than a punch.
]]
function CombatService:GetTargetsInRadius(
	attacker: Player,
	origin: Vector3,
	radius: number
): { Types.CombatTarget }
	local found: { Types.CombatTarget } = {}
	if not Formulas.IsFinite(radius) or radius <= 0 then
		return found
	end

	for _, candidate in Players:GetPlayers() do
		if candidate == attacker then
			continue
		end
		local character, _, root = getLivingParts(candidate)
		if character == nil or root == nil then
			continue
		end
		if (origin - root.Position).Magnitude > radius then
			continue
		end
		table.insert(found, {
			Kind = "Player" :: "Player",
			Player = candidate,
			Model = character,
			Root = root,
		})
	end

	for _, provider in targetProviders do
		local findAll = provider.FindAllInRadius
		if findAll ~= nil then
			for _, entity in findAll(origin, radius, attacker) do
				table.insert(found, {
					Kind = "Entity" :: "Entity",
					Player = nil,
					Model = entity.Model,
					Root = entity.Root,
				})
			end
		else
			local model, root = provider.FindNearest(origin, radius, attacker)
			if model ~= nil and root ~= nil then
				table.insert(found, {
					Kind = "Entity" :: "Entity",
					Player = nil,
					Model = model,
					Root = root,
				})
			end
		end
	end

	return found
end

--[[
	Launches a target. The game's only impact physics.

	Driven with a short-lived LinearVelocity, the same mechanism FlightService and the
	client dash already use, rather than with a legacy BodyVelocity or a direct
	AssemblyLinearVelocity write: the constraint expires on its own timer, so a launch
	that is interrupted by a respawn, a death or a disconnect cleans itself up instead
	of leaving a player permanently sliding.

	Refuses to move anyone the rest of combat refuses to touch — a safe-zone or immortal
	player is not shoved around, because a knockback that ignored the barrier would be a
	way to push somebody out of it.

	Deliberately does NOT dismount a training player. Only death dismounts, which is the
	rule the whole PvP loop is built on: an attacker has to commit to a kill to break a
	set, and a slam that scattered a room full of people off their machines would undo
	that in one button.
]]
function CombatService:ApplyKnockback(target: Types.CombatTarget?, direction: Vector3, speed: number)
	if target == nil or not Formulas.IsFinite(speed) or speed <= 0 then
		return
	end

	local victim = target.Player
	if victim ~= nil then
		if self:IsInSafeZone(victim) or self:IsImmortal(victim) then
			return
		end
	end

	local root = target.Root
	if root.Parent == nil or root.Anchored then
		return
	end

	-- A launch with no horizontal component is somebody standing exactly on the
	-- epicentre. Straight up is the honest answer, and normalising a zero vector is not.
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local horizontal = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
	local launch = (horizontal * (1 - Formulas.KNOCKBACK_LIFT) + Vector3.yAxis * Formulas.KNOCKBACK_LIFT).Unit
		* speed

	local attachment = Instance.new("Attachment")
	attachment.Name = "KnockbackAttachment"
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "Knockback"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = launch
	velocity.Parent = root

	task.delay(KNOCKBACK_SECONDS, function()
		velocity:Destroy()
		attachment:Destroy()
	end)
end

--[[
	Damage from a player to whatever they actually hit.

	Abilities call this rather than ApplyDamage, so an ability never has to learn what
	kinds of combatant exist. Player targets fall straight through to ApplyDamage with
	its full PvP rule set intact; everything else is routed to the provider that owns it.
]]
function CombatService:ApplyDamageToTarget(
	attacker: Player,
	target: Types.CombatTarget?,
	rawDamage: number
): number
	if target == nil then
		return 0
	end

	if target.Kind == "Player" then
		local victim = target.Player
		if victim == nil then
			return 0
		end
		return self:ApplyDamage(attacker, victim, rawDamage)
	end

	if not Formulas.IsFinite(rawDamage) or rawDamage <= 0 then
		return 0
	end

	-- A player swinging from inside a safe zone hits nothing, mobs included. Otherwise
	-- the barrier would be a free turret position.
	if self:IsInSafeZone(attacker) then
		return 0
	end

	for _, provider in targetProviders do
		if provider.Owns(target.Model) then
			local damage, killed = provider.ApplyDamage(attacker, target.Model, rawDamage)
			if damage > 0 then
				Net.Event("CombatFeedback"):FireClient(attacker, {
					Kind = "Hit",
					Damage = damage,
					Blocked = 0,
					Reflected = 0,
					IsReflection = false,
					Victim = target.Model.Name,
				})
			end
			if killed then
				CombatService.EntityKilled:Fire(target.Model, attacker)
			end
			return damage
		end
	end

	return 0
end

--[[
	Damage to a player from something that is not a player — a mob, and later anything
	else the world can do to you.

	It reuses every defensive rule that matters (safe zones, immortality, Back's block
	and the flight grounding) but must never touch kill bookkeeping: there is no killer
	Player to credit, and PlayerKilled's seven listeners all assume there is. Deaths are
	counted here directly so being killed by a goblin is not invisible to the profile.

	Core reflection is deliberately not applied. Reflecting onto an entity would need a
	damage path in the opposite direction for no gameplay gain.
]]
function CombatService:ApplyEnvironmentDamage(sourceName: string, victim: Player, rawDamage: number): number
	if not Formulas.IsFinite(rawDamage) or rawDamage <= 0 then
		return 0
	end

	local _, humanoid, _ = getLivingParts(victim)
	if humanoid == nil then
		return 0
	end

	if self:IsInSafeZone(victim) or self:IsImmortal(victim) then
		return 0
	end

	local breakdown = Formulas.ResolveDamage(
		rawDamage,
		StatService:GetStat(victim, "Back"),
		StatService:GetStat(victim, "Core"),
		0
	)
	local damage = breakdown.Damage
	-- The same last word the player-versus-player path gives a modifier. A guard that
	-- stopped a punch but not a goblin would be a rule the player has no way to learn.
	local blockedDamage = breakdown.Blocked
	for _, modifier in damageModifiers do
		local reduced = modifier.Apply(victim, nil, damage)
		if Formulas.IsFinite(reduced) and reduced < damage then
			local absorbed = damage - math.max(reduced, 0)
			blockedDamage += absorbed
			damage -= absorbed
		end
	end
	if damage <= 0 then
		return 0
	end

	humanoid:TakeDamage(damage)
	local isKill = humanoid.Health <= 0
	FlightService:Ground(victim)

	Net.Event("CombatFeedback"):FireClient(victim, {
		Kind = "Hurt",
		Damage = damage,
		Blocked = blockedDamage,
		Reflected = 0,
		IsReflection = false,
		Attacker = sourceName,
	})

	if isKill then
		local data = DataService:GetData(victim)
		if data ~= nil then
			data.Deaths += 1
			DataService:MarkDirty(victim)
		end
		Net.Event("Notify"):FireClient(victim, `{sourceName} knocked you out.`)
	end

	return damage
end

function CombatService:ApplyDamage(
	attacker: Player,
	victim: Player,
	rawDamage: number,
	isRetaliation: boolean?
): number
	if attacker == victim or not Formulas.IsFinite(rawDamage) or rawDamage <= 0 then
		return 0
	end

	local _, humanoid, _ = getLivingParts(victim)
	if humanoid == nil then
		return 0
	end

	if self:IsInSafeZone(victim) or self:IsInSafeZone(attacker) then
		return 0
	end

	if self:IsImmortal(victim) then
		Net.Event("CombatFeedback"):FireClient(attacker, {
			Kind = "Blocked",
			Reason = "That player is immortal.",
		})
		return 0
	end

	local attackerArms = StatService:GetStat(attacker, "Arms")
	local breakdown = if isRetaliation
		then {
			Damage = rawDamage,
			Blocked = 0,
			Reflected = 0,
			BlockRate = 0,
			ReflectionRate = 0,
		}
		else Formulas.ResolveDamage(
			rawDamage,
			StatService:GetStat(victim, "Back"),
			StatService:GetStat(victim, "Core"),
			attackerArms
		)
	local damage = breakdown.Damage
	local blockedDamage = breakdown.Blocked
	local reflectedDamage = breakdown.Reflected

	-- What the victim is doing gets the last word, after what the victim has trained.
	-- Skipped for retaliation for the same reason Back and Core are: a Core counter is
	-- already the defense resolving, and letting a guard also eat the counter would
	-- reduce the attacker's punishment for hitting somebody they cannot hurt.
	--
	-- Anything a modifier removes is reported as Blocked rather than as a fourth
	-- number, so the existing feedback payload, the damage-number tint and the HUD all
	-- keep working unchanged: from the player's side a stopped hit is a stopped hit.
	if not isRetaliation then
		for _, modifier in damageModifiers do
			local reduced = modifier.Apply(victim, attacker, damage)
			if Formulas.IsFinite(reduced) and reduced < damage then
				local absorbed = damage - math.max(reduced, 0)
				blockedDamage += absorbed
				damage -= absorbed
			end
		end
	end

	if damage > 0 then
		humanoid:TakeDamage(damage)
	end
	local isKill = humanoid.Health <= 0

	-- Training players stay on their machine when hit — damage accumulates but they
	-- keep training until they die. Only death dismounts them (handled by
	-- TrainingService's humanoid.Died listener). This makes the attacker commit to
	-- a full kill rather than cheaply disrupting every set they walk past.

	-- Only actual damage grounds a flying player. A full block or full reflection is a
	-- successful defense, not a hidden movement debuff.
	if damage > 0 then
		FlightService:Ground(victim)
	end

	Net.Event("CombatFeedback"):FireClient(attacker, {
		Kind = "Hit",
		Damage = damage,
		Blocked = blockedDamage,
		Reflected = reflectedDamage,
		IsReflection = isRetaliation == true,
		Victim = victim.Name,
	})
	Net.Event("CombatFeedback"):FireClient(victim, {
		Kind = "Hurt",
		Damage = damage,
		Blocked = blockedDamage,
		Reflected = reflectedDamage,
		IsReflection = isRetaliation == true,
		Attacker = attacker.Name,
	})

	if damage > 0 then
		CombatService.DamageDealt:Fire(victim, attacker, damage, isKill)
	end

	if isKill then
		self:_recordKill(attacker, victim)
	end

	-- Reflection is calculated before Back and returned even when the remaining hit
	-- also kills the defender. That allows the dramatic SPTS-style trade where a glass
	-- cannon kills a Core specialist and falls to the reflected blow at the same time.
	if not isRetaliation and reflectedDamage > 0 then
		self:ApplyDamage(victim, attacker, reflectedDamage, true)
	end

	return damage
end

--[[
	True when this killer already knocked this victim out recently. Used to withhold
	rewards from someone camping a single player, without preventing the kill itself.
]]
function CombatService:IsRepeatKill(killer: Player, victim: Player): boolean
	local byKiller = recentKills[victim]
	if byKiller == nil then
		return false
	end

	local lastAt = byKiller[killer]
	return lastAt ~= nil and (os.clock() - lastAt) < REPEAT_KILL_WINDOW
end

function CombatService:_recordKill(killer: Player, victim: Player)
	local isRepeat = self:IsRepeatKill(killer, victim)

	local byKiller = recentKills[victim]
	if byKiller == nil then
		byKiller = {}
		recentKills[victim] = byKiller
	end
	byKiller[killer] = os.clock()

	DataService:Update(killer, function(data: Types.ProfileData)
		data.Kills += 1
	end)

	DataService:Update(victim, function(data: Types.ProfileData)
		-- Deaths are recorded, but nothing is taken away. Dying costs the combo and
		-- the respawn timer, and that is the whole penalty by design.
		data.Deaths += 1
	end)

	CombatService.PlayerKilled:Fire(victim, killer, isRepeat)

	Net.Event("Notify"):FireClient(victim, `{killer.Name} knocked you out.`)

	if isRepeat then
		Net.Event("Notify"):FireClient(killer, `{victim.Name} again — no reward for farming.`)
	else
		Net.Event("Notify"):FireClient(killer, `You knocked out {victim.Name}.`)
	end
end

--[[
	Fires an ability for a player. Every check the client could lie about — cooldown,
	stamina, range, target liveness — is recomputed here.
]]
--[[
	Runs an ability, or says why not.

	The third return is whether the refusal is worth telling the player about. Some are:
	a safe zone or a barrier is a rule they can act on. Most are not — "not ready yet"
	and "no target" are the ordinary texture of holding a mouse button down, and since
	the punch moved onto left-click the client sends one of those on most clicks. Toasted,
	they buried the screen in a stack of "Not ready yet." saying nothing the cooldown had
	not already said by refusing.
]]
function CombatService:Activate(
	attacker: Player,
	abilityId: Types.AbilityId,
	target: Player?
): (boolean, string?, boolean?)
	local ability = abilities[abilityId]
	if ability == nil then
		return false, "Unknown ability."
	end

	local attackerCharacter, _, attackerRoot = getLivingParts(attacker)
	if attackerCharacter == nil or attackerRoot == nil then
		return false, "You cannot attack right now."
	end

	local playerCooldowns = cooldowns[attacker]
	if playerCooldowns == nil then
		playerCooldowns = {}
		cooldowns[attacker] = playerCooldowns
	end

	local now = os.clock()
	local readyAt = playerCooldowns[abilityId]
	if readyAt ~= nil and now < readyAt then
		return false, "Not ready yet.", true
	end

	local targetCharacter: Model? = nil
	local targetRoot: BasePart? = nil

	if target ~= nil then
		targetCharacter, _, targetRoot = getLivingParts(target)
	end

	-- Range is checked whenever a target was named, not only when the ability demands
	-- one. An ability that can swing at nothing still must not reach across the map
	-- because its caller passed somebody far away, and leaving that to each ability
	-- would put a security check in the one place it is easy to forget.
	if target ~= nil and targetRoot ~= nil then
		if (attackerRoot.Position - targetRoot.Position).Magnitude > ability.Range * RANGE_TOLERANCE then
			targetRoot = nil
		end
	end

	-- A target that is dead, gone, or out of reach is no target. For an ability that
	-- requires one this is a rejection; for one that does not, it is simply a miss,
	-- and the ability is run with nothing to hit.
	if targetRoot == nil then
		target = nil
		targetCharacter = nil
	end

	local combatTarget: Types.CombatTarget? = nil

	if target == nil and ability.AutoTarget == true then
		target, targetCharacter, targetRoot =
			nearestLivingTarget(attacker, attackerRoot.Position, ability.Range * RANGE_TOLERANCE)

		-- Only look for a mob once no player is in reach. The client never names a mob
		-- — it still sends a Player or nil — so this is the entire path by which a
		-- non-player target is ever selected, and it costs the client nothing.
		if target == nil then
			local entityModel, entityRoot =
				nearestEntityTarget(attacker, attackerRoot.Position, ability.Range * RANGE_TOLERANCE)
			if entityModel ~= nil and entityRoot ~= nil then
				combatTarget = {
					Kind = "Entity",
					Player = nil,
					Model = entityModel,
					Root = entityRoot,
				}
			end
		end
	end

	if target ~= nil and targetCharacter ~= nil and targetRoot ~= nil then
		combatTarget = {
			Kind = "Player",
			Player = target,
			Model = targetCharacter,
			Root = targetRoot,
		}
	end

	if ability.RequiresTarget and combatTarget == nil then
		return false, "No target.", true
	end

	local context: Types.AbilityContext = {
		Attacker = attacker,
		AttackerCharacter = attackerCharacter,
		AttackerRoot = attackerRoot,
		Target = target,
		TargetCharacter = targetCharacter,
		TargetRoot = targetRoot,
		CombatTarget = combatTarget,
	}

	if ability.Validate ~= nil then
		local allowed, reason = ability.Validate(context)
		if not allowed then
			return false, reason or "You cannot do that."
		end
	end

	playerCooldowns[abilityId] = now + ability.Cooldown
	ability.Execute(context, self)

	return true, nil
end

--[[
	Base damage for an attacker before ability multipliers and falloff.
	Exposed so abilities never reimplement the stat curve.
]]
function CombatService:GetBaseDamage(player: Player): number
	return Formulas.AttackDamage(StatService:GetStat(player, "Arms"))
end

--[[
	One of a player's five stats.

	A passthrough to StatService, and the reason it exists is dependency direction. An
	ability is a file dropped into a folder; it should describe a move using what
	CombatService hands it, not go looking through the service Loader for a second
	system. GetBaseDamage already covers the common case of "how hard does this player
	hit"; abilities that resolve a radius from Legs or a launch from the victim's Back
	need the raw numbers, and this keeps that from becoming a second import in every
	ability file.
]]
function CombatService:GetStat(player: Player, statId: string): number
	return StatService:GetStat(player, statId)
end

--[[
	Pushes stat-derived health and walkspeed onto a living character. Growing Chest
	preserves missing health rather than health percentage: +1 Chest is therefore
	exactly +10 current and max health, whether the player is full or injured.
]]
function CombatService:_applyVitals(player: Player)
	local _, humanoid, _ = getLivingParts(player)
	if humanoid == nil then
		return
	end

	local maxHealth = Formulas.MaxHealth(StatService:GetStat(player, "Chest"))
	if math.abs(humanoid.MaxHealth - maxHealth) > 0.01 then
		local missingHealth = math.max(0, humanoid.MaxHealth - humanoid.Health)
		humanoid.MaxHealth = maxHealth
		humanoid.Health = math.clamp(maxHealth - missingHealth, 1, maxHealth)
	end

	local legs = StatService:GetStat(player, "Legs")
	local character = player.Character
	local training = character ~= nil and character:GetAttribute("TrainingPose") ~= nil
	local walkSpeed = if training
		then 0
		else if sprinting[player] == true then Formulas.SprintSpeed(legs) else Formulas.WalkSpeed(legs)
	if math.abs(humanoid.WalkSpeed - walkSpeed) > 0.01 then
		humanoid.WalkSpeed = walkSpeed
	end
end

function CombatService:Start()
	-- A sprint is a persistent toggle. Training temporarily forces WalkSpeed to zero,
	-- but leaving a machine must reveal the same toggle state immediately; restoring
	-- the numeric pre-mount speed made the player click Run twice after every set.
	TrainingService.TrainingChanged:Connect(function(player: Player)
		self:_applyVitals(player)
	end)

	Net.BindEvent("SprintChanged", 8, function(player: Player, wantsSprint: any)
		if type(wantsSprint) ~= "boolean" then
			return
		end
		sprinting[player] = wantsSprint
		self:_applyVitals(player)
	end)

	-- Comfortably above the fastest ability cooldown, so honest play never trips it.
	Net.BindEvent("AbilityActivate", 8, function(player: Player, abilityId: any, target: any)
		if type(abilityId) ~= "string" then
			return
		end
		if target ~= nil and not (typeof(target) == "Instance" and target:IsA("Player")) then
			return
		end

		local ok, reason, quiet = self:Activate(player, abilityId, target)
		if not ok and reason ~= nil and not quiet then
			Net.Event("CombatFeedback"):FireClient(player, { Kind = "Rejected", Reason = reason })
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			cooldowns[player] = {}
			sprinting[player] = false
			-- Wait a beat for the Humanoid to finish setting itself up.
			task.defer(function()
				self:_applyVitals(player)
			end)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		cooldowns[player] = nil
		sprinting[player] = nil
		recentKills[player] = nil
		for _, byKiller in recentKills do
			byKiller[player] = nil
		end
	end)

	-- Apply visible effects in the same server update that changed their raw muscle.
	-- The old one-second polling delay made several quarter-second manual gains appear
	-- as one unrelated health jump, even though the stored Chest value was correct.
	StatService.StatChanged:Connect(function(player: Player, statId: string)
		if statId == "Chest" or statId == "Legs" then
			self:_applyVitals(player)
		end
	end)

	-- Keep a slow reconciliation pass for character scripts or Roblox systems that
	-- overwrite the properties independently of a stat change.
	task.spawn(function()
		while true do
			task.wait(VITALS_REFRESH_SECONDS)
			for _, player in Players:GetPlayers() do
				self:_applyVitals(player)
			end
		end
	end)
end

return CombatService
