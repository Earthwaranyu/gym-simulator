--!strict
--[[
	CombatService — server-authoritative PvP, and the reason this game exists.

	Players can attack each other anywhere except tagged SafeZone volumes, including
	while their victim is mid-set at a machine. Landing a hit on someone who is
	training breaks their combo and drains their stamina, which is the whole hook:
	killing a trainer is annoying by design, but it never costs them saved progress.

	Abilities live in the Abilities/ folder next to this file and are discovered at
	startup. Because the Loader does not descend into a ModuleScript's children, they
	are ours to load, not systems in their own right. Adding an attack is one new file
	implementing Types.Ability — there is no registry list here to extend and no
	`if abilityId == "Punch"` anywhere.

	Damage always passes through PowerGapFalloff. That is load-bearing, not cosmetic:
	raw damage at trillion-scale stats exceeds a fresh player's entire health pool, so
	skipping falloff would let a maxed player one-shot beginners.
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
-- How often stat-derived health and speed are re-applied to living characters.
local VITALS_REFRESH_SECONDS = 1
-- Generosity on the client's claimed range, to absorb latency.
local RANGE_TOLERANCE = 1.35

local CombatService = {
	Name = "CombatService",
	Priority = 30,
}

local abilities: { [Types.AbilityId]: Types.Ability } = {}
local cooldowns: { [Player]: { [Types.AbilityId]: number } } = {}
-- victim -> killer -> os.clock() of the last kill, for the repeat-farm check.
local recentKills: { [Player]: { [Player]: number } } = {}

local DataService: any = nil
local StatService: any = nil
local TrainingService: any = nil

-- (victim, attacker, damage, isKill)
CombatService.DamageDealt = Signal.new()
-- (victim, killer, isRepeatKill) — isRepeatKill is true when the same killer already
-- knocked this victim out inside REPEAT_KILL_WINDOW. Listeners that hand out rewards
-- must skip those; the kill itself still counts and still annoys the victim.
CombatService.PlayerKilled = Signal.new()

function CombatService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
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

--[[
	Applies damage from one player to another, with every PvP rule in one place:
	safe zones, immortality, power-gap falloff, and the training interrupt.

	Returns the damage actually dealt, which is zero for any blocked hit.
]]
function CombatService:ApplyDamage(attacker: Player, victim: Player, rawDamage: number): number
	if attacker == victim or rawDamage <= 0 then
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

	local falloff =
		Formulas.PowerGapFalloff(StatService:GetTotalPower(attacker), StatService:GetTotalPower(victim))
	local damage = rawDamage * falloff

	humanoid:TakeDamage(damage)
	local isKill = humanoid.Health <= 0

	-- The hook. Training is automatic and costs nothing, so knocking the victim off
	-- the machine and resetting their combo is the entire penalty for being attacked
	-- mid-set — and the entire reason attacking a trainer is worth doing.
	if TrainingService:IsTraining(victim) then
		TrainingService:Interrupt(victim)
	end

	Net.Event("CombatFeedback"):FireClient(attacker, { Kind = "Hit", Damage = damage, Victim = victim.Name })
	Net.Event("CombatFeedback")
		:FireClient(victim, { Kind = "Hurt", Damage = damage, Attacker = attacker.Name })

	CombatService.DamageDealt:Fire(victim, attacker, damage, isKill)

	if isKill then
		self:_recordKill(attacker, victim)
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
function CombatService:Activate(
	attacker: Player,
	abilityId: Types.AbilityId,
	target: Player?
): (boolean, string?)
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
		return false, "Not ready yet."
	end

	local targetCharacter: Model? = nil
	local targetRoot: BasePart? = nil

	if target ~= nil then
		targetCharacter, _, targetRoot = getLivingParts(target)
	end

	if ability.RequiresTarget then
		if target == nil or targetRoot == nil then
			return false, "No target."
		end
		if (attackerRoot.Position - targetRoot.Position).Magnitude > ability.Range * RANGE_TOLERANCE then
			return false, "Too far away."
		end
	end

	local context: Types.AbilityContext = {
		Attacker = attacker,
		AttackerCharacter = attackerCharacter,
		AttackerRoot = attackerRoot,
		Target = target,
		TargetCharacter = targetCharacter,
		TargetRoot = targetRoot,
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
	return Formulas.AttackDamage(StatService:GetStat(player, "Arms"), StatService:GetStat(player, "Chest"))
end

--[[
	Pushes stat-derived health and walkspeed onto a living character, preserving the
	current health ratio so growing your Core heals proportionally rather than
	leaving you at a sliver of a bigger bar.
]]
function CombatService:_applyVitals(player: Player)
	local _, humanoid, _ = getLivingParts(player)
	if humanoid == nil then
		return
	end

	local maxHealth = Formulas.MaxHealth(StatService:GetStat(player, "Core"))
	if math.abs(humanoid.MaxHealth - maxHealth) > 0.01 then
		local ratio = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
		humanoid.MaxHealth = maxHealth
		humanoid.Health = math.clamp(ratio * maxHealth, 1, maxHealth)
	end

	local walkSpeed = Formulas.WalkSpeed(StatService:GetStat(player, "Legs"))
	if math.abs(humanoid.WalkSpeed - walkSpeed) > 0.01 then
		humanoid.WalkSpeed = walkSpeed
	end
end

function CombatService:Start()
	Net.Event("AbilityActivate").OnServerEvent:Connect(function(player: Player, abilityId: any, target: any)
		if type(abilityId) ~= "string" then
			return
		end
		if target ~= nil and not (typeof(target) == "Instance" and target:IsA("Player")) then
			return
		end

		local ok, reason = self:Activate(player, abilityId, target)
		if not ok and reason ~= nil then
			Net.Event("CombatFeedback"):FireClient(player, { Kind = "Rejected", Reason = reason })
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			cooldowns[player] = {}
			-- Wait a beat for the Humanoid to finish setting itself up.
			task.defer(function()
				self:_applyVitals(player)
			end)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		cooldowns[player] = nil
		recentKills[player] = nil
		for _, byKiller in recentKills do
			byKiller[player] = nil
		end
	end)

	-- Stats change constantly while training, so vitals are refreshed on a slow timer
	-- rather than on every StatChanged, which would fire several times a second.
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
