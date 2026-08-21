--!strict
--[[
	MobService — the monsters, their spawns, and the thing that makes them chase you.

	Two kinds of site, both authored as invisible tagged markers in the generated world
	(see mob_sites in scripts/build_gym.py):

	  * A mob field per tier, kept populated with a fixed number of goblins that respawn
	    shortly after dying. This is where the quest cycle's kill step is served.
	  * A boss arena per tier, empty most of the time. Each tier's boss is on its own
	    thirty-minute clock, and the clocks are seeded staggered so that a boss becomes
	    available somewhere in the world every four or five minutes rather than all
	    seven arriving together and then nothing happening for half an hour.

	These are the first non-player Humanoids in the game. Everything else that looks for
	a Humanoid does it through player.Character, so nothing existing sees them — but it
	is worth knowing before adding the next `FindFirstChildOfClass("Humanoid")`.

	Combat is not implemented here. MobService registers a target provider with
	CombatService and receives damage through that; CombatService never learns what a
	goblin is. Rewards are not paid here either: this fires MobKilled and the services
	that already own each currency listen for it.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)

-- The AI runs on a shared timer rather than per-mob and rather than every frame.
-- Four ticks a second is enough for a walking melee chase and is roughly a fifteenth
-- of the work a RenderStepped-style loop over forty Humanoids would cost.
local AI_INTERVAL = 1 / 4
-- A field with nobody near it does no work at all. This is the single biggest saving:
-- on a quiet server almost every field is asleep.
local FIELD_WAKE_RADIUS = 400
-- One full boss cycle, and the seeded stagger between tiers.
local BOSS_PERIOD = 1800
--[[
	The share of a boss's health a player must deal to be paid for the kill.

	A boss is a long fight and often a shared one. Paying only the last hit turned that
	into a race to snipe the finish and gave nothing to a player who did half the work,
	which is precisely backwards for the one piece of content the game wants people to
	travel to together.

	Ten percent is low enough that genuine help always counts and high enough that
	tagging a boss once and standing back does not.
]]
local BOSS_CREDIT_FRACTION = 0.1
-- How often the boss countdown is pushed to clients while nothing else changes.
local BOSS_BROADCAST_INTERVAL = 30

local MobService = {
	Name = "MobService",
	-- After CombatService (30), whose provider registry this registers into.
	Priority = 35,
}

type Live = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Definition: MobConfig.Mob,
	Home: Vector3,
	Radius: number,
	NextAttackAt: number,
	-- Boss only: when an unfought boss gives up and leaves.
	DespawnAt: number?,
	-- Boss only: total damage each player has put into it, for shared kill credit.
	Damage: { [Player]: number }?,
}

local live: { [Model]: Live } = {}
local mobFolder: Folder
-- Zone id -> os.clock() at which that tier's boss may next appear.
local nextBossAt: { [string]: number } = {}
-- Zone id -> the live boss, so a second can never spawn on top of the first.
local liveBoss: { [string]: Model? } = {}
local lastBroadcastAt = 0

local CombatService: any = nil

-- (killer, definition)
MobService.MobKilled = Signal.new()

function MobService:Init()
	CombatService = Loader.Get("CombatService")
end

--[[
	A goblin, built from primitives.

	No Toolbox models and no imported meshes anywhere in this game, so a monster is the
	same kind of part stack the NPCs are. The silhouette is doing all the work: a squat
	body, a big head and pointed ears read as "goblin" at fifty studs, which is further
	than any of the detail would.
]]
local function buildMob(definition: MobConfig.Mob): (Model, Humanoid, BasePart)
	local scale = definition.Scale
	local model = Instance.new("Model")
	model.Name = definition.Id

	local function block(name: string, size: Vector3, offset: Vector3, color: Color3): BasePart
		local piece = Instance.new("Part")
		piece.Name = name
		piece.Size = size * scale
		piece.Color = color
		piece.Material = Enum.Material.SmoothPlastic
		piece.TopSurface = Enum.SurfaceType.Smooth
		piece.BottomSurface = Enum.SurfaceType.Smooth
		piece.CanCollide = false
		piece.Massless = true
		piece.Parent = model
		piece:SetAttribute("LocalOffset", offset * scale)
		return piece
	end

	local skin = definition.Color
	local dark = skin:Lerp(Color3.new(0, 0, 0), 0.45)

	-- The root is the only collidable part, so the model walks as one body rather than
	-- catching its ears on the terrain.
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1) * scale
	root.Transparency = 1
	root.CanCollide = true
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local torso = block("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), skin)
	block("Head", Vector3.new(1.6, 1.4, 1.4), Vector3.new(0, 1.7, 0), skin)
	block("EarLeft", Vector3.new(0.9, 0.3, 0.3), Vector3.new(-1.1, 1.9, 0), dark)
	block("EarRight", Vector3.new(0.9, 0.3, 0.3), Vector3.new(1.1, 1.9, 0), dark)
	block("ArmLeft", Vector3.new(0.7, 1.6, 0.7), Vector3.new(-1.35, 0.1, 0), skin)
	block("ArmRight", Vector3.new(0.7, 1.6, 0.7), Vector3.new(1.35, 0.1, 0), skin)
	block("LegLeft", Vector3.new(0.7, 1.4, 0.7), Vector3.new(-0.5, -1.7, 0), dark)
	block("LegRight", Vector3.new(0.7, 1.4, 0.7), Vector3.new(0.5, -1.7, 0), dark)

	if definition.Kind == "Boss" then
		-- Horns, so a boss is not just a bigger goblin at a glance.
		block("HornLeft", Vector3.new(0.3, 1.1, 0.3), Vector3.new(-0.5, 2.6, 0), dark)
		block("HornRight", Vector3.new(0.3, 1.1, 0.3), Vector3.new(0.5, 2.6, 0), dark)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = definition.Health
	humanoid.Health = definition.Health
	humanoid.WalkSpeed = definition.WalkSpeed
	humanoid.DisplayName = definition.DisplayName
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, torso
end

--[[
	Welds the body to the root so the whole model moves as one rigid thing. Cheaper and
	far more predictable than motorised limbs, which nothing here needs: the mob walks
	and swings, it does not animate.
]]
local function assemble(model: Model, root: BasePart)
	for _, piece in model:GetChildren() do
		if not piece:IsA("BasePart") or piece == root then
			continue
		end
		local offset = piece:GetAttribute("LocalOffset")
		if typeof(offset) ~= "Vector3" then
			continue
		end
		piece.CFrame = root.CFrame * CFrame.new(offset)

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = piece
		weld.Parent = root
	end
end

function MobService:_spawn(definition: MobConfig.Mob, home: Vector3, radius: number, at: Vector3): Model
	local model, humanoid, _ = buildMob(definition)
	model:SetAttribute(MobConfig.ID_ATTRIBUTE, definition.Id)
	model:SetAttribute(MobConfig.ZONE_ATTRIBUTE, definition.ZoneId)
	CollectionService:AddTag(model, MobConfig.MOB_TAG)

	local root = model.PrimaryPart :: BasePart
	root.CFrame = CFrame.new(at)
	assemble(model, root)
	model.Parent = mobFolder

	live[model] = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Definition = definition,
		Home = home,
		Radius = radius,
		NextAttackAt = 0,
		DespawnAt = if definition.Kind == "Boss" and definition.DespawnSeconds ~= nil
			then os.clock() + definition.DespawnSeconds
			else nil,
		-- Goblins keep last-hit credit and carry no table: they die in a punch or two,
		-- so every contributor would clear any threshold and the bookkeeping would buy
		-- nothing.
		Damage = if definition.Kind == "Boss" then {} else nil,
	}

	return model
end

local function randomPointIn(home: Vector3, radius: number): Vector3
	local angle = math.random() * math.pi * 2
	-- sqrt keeps the distribution even across the disc instead of clustering at the
	-- centre, so a field of six does not spawn them all in a huddle.
	local distance = math.sqrt(math.random()) * radius
	return home + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

--[[
	Nearest player worth chasing. Anyone in a safe zone or holding an immortal potion is
	invisible to a mob: letting them aggro would pile every goblin against a barrier
	they cannot hit through, which looks broken and costs a permanent chase.
]]
local function nearestVictim(from: Vector3, range: number): (Player?, BasePart?, number)
	local bestPlayer: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = range

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character == nil then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
			continue
		end
		if CombatService:IsInSafeZone(player) or CombatService:IsImmortal(player) then
			continue
		end
		local distance = (from - root.Position).Magnitude
		if distance <= bestDistance then
			bestDistance = distance
			bestPlayer = player
			bestRoot = root
		end
	end

	return bestPlayer, bestRoot, bestDistance
end

function MobService:_despawn(model: Model)
	local record = live[model]
	if record ~= nil and record.Definition.Kind == "Boss" then
		liveBoss[record.Definition.ZoneId] = nil
	end
	live[model] = nil
	model:Destroy()
end

function MobService:_step(now: number)
	for model, record in live do
		if model.Parent == nil then
			live[model] = nil
			continue
		end

		if record.Humanoid.Health <= 0 then
			continue
		end

		if record.DespawnAt ~= nil and now >= record.DespawnAt then
			-- An unfought boss leaves rather than waiting forever, so its next spawn
			-- lands on a clean arena and the timer cannot drift.
			nextBossAt[record.Definition.ZoneId] = now + BOSS_PERIOD
			self:_despawn(model)
			self:_broadcastBossState()
			continue
		end

		local definition = record.Definition
		local origin = record.Root.Position
		local victim, victimRoot, distance = nearestVictim(origin, definition.AggroRadius)

		-- Too far from home to still be defending it. Walk back and heal: this is the
		-- entire anti-kiting rule, and without it a boss can be led anywhere.
		if (origin - record.Home).Magnitude > definition.LeashRadius then
			record.Humanoid:MoveTo(record.Home)
			record.Humanoid.Health = definition.Health
			continue
		end

		if victim == nil or victimRoot == nil then
			continue
		end

		if distance > definition.AttackRange then
			record.Humanoid:MoveTo(victimRoot.Position)
			continue
		end

		-- In range: stop closing and swing on cooldown.
		record.Humanoid:MoveTo(origin)
		if now >= record.NextAttackAt then
			record.NextAttackAt = now + definition.AttackCooldown
			CombatService:ApplyEnvironmentDamage(definition.DisplayName, victim, definition.Damage)
		end
	end
end

function MobService:_broadcastBossState()
	local state: { [string]: { Alive: boolean, SecondsUntil: number } } = {}
	local now = os.clock()

	for _, site in MobConfig.Sites("Boss") do
		local zoneId = site.Mob.ZoneId
		local alive = liveBoss[zoneId] ~= nil
		state[zoneId] = {
			Alive = alive,
			SecondsUntil = if alive then 0 else math.max(0, (nextBossAt[zoneId] or now) - now),
		}
	end

	Net.Event("BossStateChanged"):FireAllClients(state)
	lastBroadcastAt = now
end

function MobService:_maintainFields()
	for _, site in MobConfig.Sites("Normal") do
		local definition = site.Mob
		local home = site.Marker.Position
		local population = definition.Population or 0

		-- Asleep unless somebody is near enough to ever see it. Respawns catch up the
		-- moment a player walks back into range.
		local _, _, distance = nearestVictim(home, FIELD_WAKE_RADIUS)
		if distance >= FIELD_WAKE_RADIUS then
			continue
		end

		local alive = 0
		for _, record in live do
			if record.Definition.Id == definition.Id and record.Humanoid.Health > 0 then
				alive += 1
			end
		end

		for _ = alive + 1, population do
			self:_spawn(
				definition,
				home,
				site.Radius,
				randomPointIn(home, site.Radius) + Vector3.new(0, 4, 0)
			)
		end
	end
end

function MobService:_maintainBosses(now: number)
	for _, site in MobConfig.Sites("Boss") do
		local zoneId = site.Mob.ZoneId
		if liveBoss[zoneId] ~= nil then
			continue
		end
		local due = nextBossAt[zoneId]
		if due == nil or now < due then
			continue
		end

		local home = site.Marker.Position
		local model = self:_spawn(site.Mob, home, site.Radius, home + Vector3.new(0, 6, 0))
		liveBoss[zoneId] = model

		for _, player in Players:GetPlayers() do
			Net.Event("Notify"):FireClient(player, `{site.Mob.DisplayName} has risen. Find the arena.`)
		end
		self:_broadcastBossState()
	end
end

--[[
	Brings a boss due immediately, for one zone or for all of them.

	Studio-only in practice — DevService is the only caller and refuses to run outside
	Studio — but it lives here rather than there because this service owns liveBoss,
	nextBossAt and the BossStateChanged broadcast. A command that parented a boss model
	behind its back would leave all three lying, and the map would show a timer counting
	down to a boss already standing in the arena.

	Returns how many actually rose, so the caller can say "already up" rather than
	silently doing nothing.
]]
function MobService:ForceBoss(zoneId: string?): number
	local before = 0
	for _, site in MobConfig.Sites("Boss") do
		if zoneId ~= nil and site.Mob.ZoneId ~= zoneId then
			continue
		end
		if liveBoss[site.Mob.ZoneId] ~= nil then
			before += 1
			continue
		end
		nextBossAt[site.Mob.ZoneId] = 0
	end

	self:_maintainBosses(os.clock())

	local risen = 0
	for _, site in MobConfig.Sites("Boss") do
		if zoneId ~= nil and site.Mob.ZoneId ~= zoneId then
			continue
		end
		if liveBoss[site.Mob.ZoneId] ~= nil then
			risen += 1
		end
	end
	return risen - before
end

--[[
	Damage from a player, routed here by CombatService's target provider registry. This
	owns the mob's health rules, which is the whole reason the registry exists: nothing
	in CombatService has to know a goblin has a Humanoid.
]]
function MobService:_damage(attacker: Player, model: Model, damage: number): (number, boolean)
	local record = live[model]
	if record == nil or record.Humanoid.Health <= 0 then
		return 0, false
	end

	local dealt = math.min(damage, record.Humanoid.Health)
	record.Humanoid:TakeDamage(damage)
	local killed = record.Humanoid.Health <= 0

	local tally = record.Damage
	if tally ~= nil then
		tally[attacker] = (tally[attacker] or 0) + dealt
	end

	if killed then
		local definition = record.Definition

		if tally == nil then
			MobService.MobKilled:Fire(attacker, definition)
		else
			-- Everyone who put in a real share is paid in full, and the reward services
			-- scale each one by that player's own physique class. Firing per player is
			-- what keeps every listener — rewards, quests — unchanged.
			--
			-- The killer always qualifies, even below the share. Without that, eleven
			-- players each dealing nine percent could fell a boss and the game would pay
			-- nobody: the floor exists to deny a tap-and-wait, not to invent a boss that
			-- is worth nothing.
			local floor = definition.Health * BOSS_CREDIT_FRACTION
			for player, contributed in tally do
				if player.Parent == nil then
					continue
				end
				if player == attacker or contributed >= floor then
					MobService.MobKilled:Fire(player, definition)
					Net.Event("Notify"):FireClient(player, `You felled {definition.DisplayName}.`)
				else
					Net.Event("Notify")
						:FireClient(player, `{definition.DisplayName} fell without your share of the fight.`)
				end
			end
		end

		if definition.Kind == "Boss" then
			nextBossAt[definition.ZoneId] = os.clock() + BOSS_PERIOD
		end

		-- Leave the corpse for a beat so the kill reads, then clear it. The respawn
		-- loop counts living mobs, so the field refills on its own schedule.
		task.delay(3, function()
			if live[model] ~= nil then
				self:_despawn(model)
			end
		end)

		if definition.Kind == "Boss" then
			self:_broadcastBossState()
		end
	end

	return dealt, killed
end

function MobService:Start()
	mobFolder = Instance.new("Folder")
	mobFolder.Name = "Mobs"
	mobFolder.Parent = workspace

	-- Seeded staggered rather than all at once: seven bosses on one clock means half an
	-- hour of nothing followed by seven simultaneous fights nobody can attend.
	local now = os.clock()
	for index, site in MobConfig.Sites("Boss") do
		nextBossAt[site.Mob.ZoneId] = now + (index - 1) * (BOSS_PERIOD / 7) + 60
	end

	CombatService:RegisterTargetProvider({
		Id = "Mobs",
		Owns = function(model: Model): boolean
			return live[model] ~= nil
		end,
		FindNearest = function(origin: Vector3, range: number, _forPlayer: Player): (Model?, BasePart?)
			local bestModel: Model? = nil
			local bestRoot: BasePart? = nil
			local bestDistance = range

			for model, record in live do
				if record.Humanoid.Health <= 0 or model.Parent == nil then
					continue
				end
				local distance = (origin - record.Root.Position).Magnitude
				if distance <= bestDistance then
					bestDistance = distance
					bestModel = model
					bestRoot = record.Root
				end
			end

			return bestModel, bestRoot
		end,
		ApplyDamage = function(attacker: Player, model: Model, damage: number): (number, boolean)
			return self:_damage(attacker, model, damage)
		end,
	})

	local accumulator = 0
	RunService.Heartbeat:Connect(function(delta: number)
		accumulator += delta
		if accumulator < AI_INTERVAL then
			return
		end
		accumulator = 0

		local tickNow = os.clock()
		self:_maintainFields()
		self:_maintainBosses(tickNow)
		self:_step(tickNow)

		if tickNow - lastBroadcastAt >= BOSS_BROADCAST_INTERVAL then
			self:_broadcastBossState()
		end
	end)
end

return MobService
