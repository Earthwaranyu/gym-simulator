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
local MobRigConfig = require(ReplicatedStorage.Modules.MobRigConfig)

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
	-- Walking back to Home after breaking leash, and healing when it gets there.
	Returning: boolean?,
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
	A monster, assembled from its rig.

	Every part, joint and ornament is described in MobRigConfig; this walks that
	description and builds it. The shape of the thing is data, and this is the
	interpreter — which is what lets a goblin and a boss be two tables rather than two
	code paths, and what makes redesigning one an edit to a config.

	The rig is jointed with Motor6Ds carrying the stock R15 joint names, so every pose,
	gait and strike the player already has addresses a goblin correctly. It used to be
	WeldConstraints, which is why monsters could not animate at all: a weld has nothing
	to rotate.

	No Animator is created. The player rig has one because Roblox's Animate script needs
	it for jump, fall and climb; a monster has no stock clips to preserve, and an Animator
	with nothing playing zeroes Transform every frame — which would fight the controller
	that is the only thing posing this body.
]]
local function shapeOf(kind: MobRigConfig.Shape): (string, Enum.PartType?)
	if kind == "Wedge" then
		return "WedgePart", nil
	elseif kind == "Ball" then
		return "Part", Enum.PartType.Ball
	elseif kind == "Cylinder" then
		return "Part", Enum.PartType.Cylinder
	end
	return "Part", Enum.PartType.Block
end

local function makePart(
	name: string,
	kind: MobRigConfig.Shape,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): BasePart
	local class, partType = shapeOf(kind)
	local piece = Instance.new(class) :: BasePart
	piece.Name = name
	piece.Size = size
	piece.Color = color
	piece.Material = material or MobRigConfig.DefaultMaterial
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.Massless = true
	piece.TopSurface = Enum.SurfaceType.Smooth
	piece.BottomSurface = Enum.SurfaceType.Smooth
	if partType ~= nil and piece:IsA("Part") then
		piece.Shape = partType
	end
	return piece
end

local function weldTo(parent: BasePart, child: BasePart, offset: CFrame)
	-- A Weld rather than a WeldConstraint, so the offset and the rotation live in the
	-- joint. WeldConstraint freezes whatever relative CFrame the parts happen to have,
	-- which means every ornament would need placing before it could be attached.
	local weld = Instance.new("Weld")
	weld.Part0 = parent
	weld.Part1 = child
	weld.C0 = offset
	weld.Parent = parent
	child.CFrame = parent.CFrame * offset
end

local function buildMob(definition: MobConfig.Mob): (Model, Humanoid, BasePart)
	local scale = definition.Scale
	local rig = MobRigConfig.ForKind(definition.Kind)
	local skin = definition.Color

	local model = Instance.new("Model")
	model.Name = definition.Id

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = rig.RootSize * scale
	root.Transparency = 1
	-- The only collidable part, so the body walks as one piece rather than catching an
	-- ear on the terrain.
	root.CanCollide = true
	root.CanQuery = false
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local bones: { [string]: BasePart? } = { HumanoidRootPart = root }
	local restAt: { [string]: CFrame? } = { HumanoidRootPart = CFrame.identity }
	-- The lowest point any part reaches, in root space. HipHeight comes from this rather
	-- than a hard-coded constant, so redesigning the legs cannot leave the body sunk
	-- into the floor or hovering above it.
	local lowest = -rig.RootSize.Y / 2 * scale

	local function reach(at: CFrame, size: Vector3)
		lowest = math.min(lowest, at.Position.Y - size.Y / 2)
	end

	for _, bone in rig.Bones do
		local piece = makePart(
			bone.Name,
			bone.Shape,
			bone.Size * scale,
			MobRigConfig.Shade(skin, bone.Shade),
			bone.Material
		)
		piece.Transparency = bone.Transparency or 0
		piece.Parent = model
		bones[bone.Name] = piece
	end

	for _, joint in rig.Joints do
		local parent = bones[joint.Part0]
		local child = bones[joint.Part1]
		if parent == nil or child == nil then
			continue
		end

		local c0 = CFrame.new(joint.C0 * scale)
		local c1 = CFrame.new(joint.C1 * scale)
		local rest = (restAt[joint.Part0] or CFrame.identity) * c0 * c1:Inverse()
		restAt[joint.Part1] = rest
		child.CFrame = rest

		local motor = Instance.new("Motor6D")
		motor.Name = joint.Name
		motor.Part0 = parent
		motor.Part1 = child
		motor.C0 = c0
		motor.C1 = c1
		motor.Parent = parent
	end

	for _, bone in rig.Bones do
		local at = restAt[bone.Name]
		if at ~= nil then
			reach(at, bone.Size * scale)
		end
		-- A capsule is a block with a ball on each end. A cylinder would need rotating
		-- ninety degrees to stand up, which would take the joint's own axes with it;
		-- capping a block keeps joint space upright and still reads as flesh rather than
		-- as a plank. The technique is MuscleIcons'.
		local piece = bones[bone.Name]
		if bone.Shape == "Capsule" and piece ~= nil then
			local size = bone.Size * scale
			local cap = Vector3.new(size.X, size.X, size.Z)
			for _, side in { 1, -1 } do
				local ball = makePart(
					`{bone.Name}Cap`,
					"Ball",
					cap,
					MobRigConfig.Shade(skin, bone.Shade),
					bone.Material
				)
				ball.Parent = model
				weldTo(piece, ball, CFrame.new(0, size.Y / 2 * side, 0))
				if at ~= nil then
					reach(at * CFrame.new(0, size.Y / 2 * side, 0), cap)
				end
			end
		end
	end

	for _, decor in rig.Decor do
		local parent = bones[decor.Parent]
		if parent == nil then
			continue
		end
		local piece = makePart(
			decor.Name,
			decor.Shape,
			decor.Size * scale,
			MobRigConfig.Shade(skin, decor.Shade),
			decor.Material
		)
		piece.Parent = model

		local rotation = decor.Rotation or Vector3.zero
		local offset = CFrame.new(decor.Offset * scale)
			* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
		weldTo(parent, piece, offset)

		local at = restAt[decor.Parent]
		if at ~= nil then
			reach(at * offset, decor.Size * scale)
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	-- Measured, not assumed: the drop from the root's underside to the lowest thing on
	-- the body. A hard-coded value was only ever right for one set of leg offsets, and
	-- was three studs wrong on a boss.
	humanoid.HipHeight = math.max(0, -(rig.RootSize.Y / 2 * scale) - lowest)
	humanoid.MaxHealth = definition.Health
	humanoid.Health = definition.Health
	humanoid.WalkSpeed = definition.WalkSpeed
	humanoid.DisplayName = definition.DisplayName
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, bones.UpperTorso or root
end

function MobService:_spawn(definition: MobConfig.Mob, home: Vector3, radius: number, at: Vector3): Model
	local model, humanoid, _ = buildMob(definition)
	model:SetAttribute(MobConfig.ID_ATTRIBUTE, definition.Id)
	model:SetAttribute(MobConfig.ZONE_ATTRIBUTE, definition.ZoneId)
	CollectionService:AddTag(model, MobConfig.MOB_TAG)

	local root = model.PrimaryPart :: BasePart
	-- Pivot rather than place the root alone: the body hangs off the root through
	-- joints and welds now, and moving one part of a jointed assembly leaves the rest
	-- of it standing where it was.
	model:PivotTo(CFrame.new(at))
	model.Parent = mobFolder

	-- Load-bearing, and invisible when missing.
	--
	-- The root is unanchored and the AI's only way to move this thing is a server-side
	-- Humanoid:MoveTo. Roblox hands ownership of an unanchored assembly to the nearest
	-- player within a couple of hundred studs, and from that moment the server's
	-- controller output is discarded — so the mob froze precisely when somebody walked
	-- up to it, never closed to AttackRange, and therefore never swung either. It looked
	-- exactly like an AI that was not running, with nothing in the output to say so.
	--
	-- pcall because it throws on a part that has been anchored or is already leaving.
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

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
		Returning = false,
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
		--
		-- The heal waits until it actually arrives. Healing every tick of the walk back
		-- made a boss dragged past its leash literally unkillable — it outhealed
		-- anything you could do to it on the way. Giving up and resetting is the
		-- intended behaviour; being invulnerable for the whole return trip was not.
		local fromHome = (origin - record.Home).Magnitude
		if fromHome > definition.LeashRadius then
			record.Humanoid:MoveTo(record.Home)
			record.Returning = true
			continue
		end
		if record.Returning then
			if fromHome > definition.AttackRange then
				record.Humanoid:MoveTo(record.Home)
				continue
			end
			record.Returning = false
			record.Humanoid.Health = definition.Health
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
			CombatService:ApplyEnvironmentDamage(
				definition.DisplayName,
				victim,
				definition.Damage,
				definition.AttackStat
			)
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
		-- Without this, GetTargetsInRadius falls back to FindNearest and every area
		-- attack in the game hits exactly one monster while hitting every player in
		-- the blast. Ground Slam into a pack of three killed one of them.
		FindAllInRadius = function(
			origin: Vector3,
			radius: number,
			_forPlayer: Player
		): { { Model: Model, Root: BasePart } }
			local found: { { Model: Model, Root: BasePart } } = {}

			for model, record in live do
				if record.Humanoid.Health <= 0 or model.Parent == nil then
					continue
				end
				if (origin - record.Root.Position).Magnitude <= radius then
					table.insert(found, { Model = model, Root = record.Root })
				end
			end

			return found
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
		-- Subtract rather than zero: zeroing threw away the remainder every tick and
		-- quietly ran the AI slower than the interval asks for.
		accumulator -= AI_INTERVAL

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
