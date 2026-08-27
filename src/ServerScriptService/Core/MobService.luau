--!strict
--[[
	MobService — the monsters, their spawns, and the thing that makes them chase you.

	Two kinds of site, both authored as invisible tagged markers in the generated world
	(see mob_sites in scripts/build_gym.py):

	  * A mob field per tier, kept populated with a fixed number of thieves that respawn
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
	thief is. Rewards are not paid here either: this fires MobKilled and the services
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
local BodyLoftConfig = require(ReplicatedStorage.Modules.BodyLoftConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Announce = require(ReplicatedStorage.Modules.Announce)
local MobRigConfig = require(ReplicatedStorage.Modules.MobRigConfig)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

-- The AI runs on a shared timer rather than per-mob and rather than every frame.
-- Four ticks a second is enough for a walking melee chase and is roughly a fifteenth
-- of the work a RenderStepped-style loop over forty Humanoids would cost.
-- The two strikes a monster plays, both defined in StrikeConfig alongside the player's.
local SWING_STRIKE = "MobSwing"
local ULTIMATE_STRIKE = "MobUltimate"

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
	-- Boss only: when the heavy may next be attempted, and whether one is mid-windup.
	NextUltimateAt: number?,
	Charging: boolean?,
}

local live: { [Model]: Live } = {}
--[[
	When each killed mob's slot is allowed to refill, keyed by mob id.

	`_maintainFields` counts *living* mobs and tops the field back up to Population,
	and a corpse has zero health — so a kill freed its slot on the very next AI tick,
	a quarter of a second later. `RespawnSeconds` has been sitting in MobConfig since
	the beginning read by nothing, which made a mob field a conveyor belt for anyone
	able to clear it faster than they could walk between spawns.

	A kill parks a timestamp here; the field treats that as an occupied slot until it
	matures. Timers keep maturing while a field is asleep, so walking back into range
	still finds it full, which is the behaviour the wake radius always intended.
]]
-- The top of BodyLoftBuilder's 1..2.2 girth range.
local BRUTE_SCALE = 2.2

-- How cut the boss is. 1 is a player; BodyLoftConfig clamps the ceiling.
local BRUTE_LEANNESS = 1.7

-- How much bigger the boss rig is than the loft's bind pose. Must match the Scale on
-- the boss rows in MobConfig, or the dressed body will not line up with its own joints.
local BRUTE_RIG_SCALE = 2.1

local respawnAt: { [string]: { number } } = {}
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
	interpreter — which is what lets a thief and a brute be two tables rather than two
	code paths, and what makes redesigning one an edit to a config.

	The rig is jointed with Motor6Ds carrying the stock R15 joint names, so every pose,
	gait and strike the player already has addresses a mob correctly. It used to be
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
	--[[
		A loft-dressed mob stands by its mesh, not by its skeleton.

		`lowest` measures the primitive rig, and for a brute that is the bottom of a
		shin capsule's ball cap — 6.7 studs under the root at scale 2.1. The generated
		body is not that tall: its geometry stops 4.05 under the root, because the loft's
		legs do not reach all the way down to the foot bone its skeleton names. Standing
		the rig on its own lowest part therefore hangs the visible body two and a half
		studs in the air, and since the rig is hidden once the body is on, all a player
		sees is a boss floating.

		So a dressed mob's hip height comes from the body instead. The ratio is measured
		off a live player wearing the same mesh: root 1.199 studs over the floor with a
		half-height of 1.93, which leaves the body's lowest point 0.731 under the floor —
		feet planted rather than resting on the surface. Everything in the loft scales
		linearly, so one number covers every size:

			rootAboveGround = (1.93 - 0.731) * scale
			hipHeight       = rootAboveGround - RootSize.Y / 2 * scale

		Undressed, the mob falls back to the measured rig, which is what the fallback
		wants: no mesh, so the skeleton is the thing standing on the floor.
	]]
	if definition.Kind == "Boss" then
		--[[
			Stand on whichever reaches lower: the generated body, or the rig underneath.

			Both exist at once. The loft hides the rig's limbs but keeps its head, hands
			and feet, and the two do not end at the same height — the loft stops at the
			ankle 2.86 under the root, while the brute's rig foot reaches 6.36 under it
			at this scale. Standing on either one alone buries the other, and a boss with
			its shins in the pavement is what shipped: a hand-measured 1.199 that was
			never tied to the geometry it described, so every change to a leg ring left it
			further out and nothing said so.

			`lowest` is measured from the real rig parts a few lines above; the loft's
			drop is derived from its rings. Taking the deeper of the two means neither can
			end up underground, whichever one is on screen.
		]]
		local loftDrop = BodyLoftConfig.Drop() * scale
		local rigDrop = -lowest
		humanoid.HipHeight = math.max(0, math.max(loftDrop, rigDrop) - rig.RootSize.Y / 2 * scale)
	else
		-- Measured, not assumed: the drop from the root's underside to the lowest thing on
		-- the body. A hard-coded value was only ever right for one set of leg offsets, and
		-- was three studs wrong on a boss.
		humanoid.HipHeight = math.max(0, -(rig.RootSize.Y / 2 * scale) - lowest)
	end
	humanoid.MaxHealth = definition.Health
	humanoid.Health = definition.Health
	humanoid.WalkSpeed = definition.WalkSpeed
	humanoid.DisplayName = definition.DisplayName
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, bones.UpperTorso or root
end

--[[
	Marks a boss to be dressed in the generated body, and says how muscular.

	The numbers are the same shape MuscleService writes into a player's character —
	a MuscleProgress folder of 0..1 per stat and a MuscleScales folder of per-part
	growth — because BodyLoftController reads a Model, not a Player. Giving a mob the
	same two folders is the whole integration; nothing in that controller had to learn
	what a mob is.

	Everything is at the ceiling. A boss is what the player is training to become, so
	it should look like the top of the ladder rather than a stage along it.

	Only bosses. A client holds seven or eight EditableMesh instances at once and each
	dressed body costs one, so a field of six thieves would spend the budget the
	players' own bodies need. Thieves stay primitives by design, not by omission.
]]
local function dressAsBrute(model: Model)
	local progress = Instance.new("Folder")
	progress.Name = "MuscleProgress"
	for _, stat in StatConfig.List do
		local value = Instance.new("NumberValue")
		value.Name = stat.Id
		value.Value = 1
		value.Parent = progress
	end
	progress.Parent = model

	local scales = Instance.new("Folder")
	scales.Name = "MuscleScales"
	for _, bone in BodyLoftConfig.BONES do
		if scales:FindFirstChild(bone.Part) == nil then
			local value = Instance.new("NumberValue")
			value.Name = bone.Part
			-- Hands and feet are absent from every stat's BodyScales, so a player never
			-- grows them past 1. Inflating them here rounded off the two parts that
			-- most need to stay crisp.
			local extremity = string.find(bone.Part, "Hand") ~= nil or string.find(bone.Part, "Foot") ~= nil
			value.Value = if extremity then 1 else BRUTE_SCALE
			value.Parent = scales
		end
	end
	scales.Parent = model

	-- The rig is built at the row's Scale; the loft bind pose is not. Telling the
	-- client which is which is the difference between a boss and a pile of limbs.
	model:SetAttribute("LoftScale", BRUTE_RIG_SCALE)
	-- Cut well past anything training produces. Size alone reads as bulk; this is what
	-- makes the boss look like the ceiling rather than a heavier player.
	model:SetAttribute(BodyLoftConfig.LEANNESS_ATTRIBUTE, BRUTE_LEANNESS)
	CollectionService:AddTag(model, BodyLoftConfig.MOB_TAG)
end

function MobService:_spawn(definition: MobConfig.Mob, home: Vector3, radius: number, at: Vector3): Model
	local model, humanoid, _ = buildMob(definition)
	model:SetAttribute(MobConfig.ID_ATTRIBUTE, definition.Id)
	model:SetAttribute(MobConfig.ZONE_ATTRIBUTE, definition.ZoneId)
	CollectionService:AddTag(model, MobConfig.MOB_TAG)

	if definition.Kind == "Boss" then
		dressAsBrute(model)
	end

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
		-- Thieves keep last-hit credit and carry no table: they die in a punch or two,
		-- so every contributor would clear any threshold and the bookkeeping would buy
		-- nothing.
		Damage = if definition.Kind == "Boss" then {} else nil,
		Returning = false,
		-- Not available the instant a boss rises: a player who arrives to an immediate
		-- unavoidable slam has not been given the fight, only the damage.
		NextUltimateAt = if definition.Kind == "Boss"
			then os.clock() + (definition.UltimateCooldown or 0)
			else nil,
		Charging = false,
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
	invisible to a mob: letting them aggro would pile every thief against a barrier
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

--[[
	Tells every client that this monster swung, and which swing it was.

	The same channel the player's three abilities use: two attributes on the model, read
	independently by the body, the effects and the flinch. Nothing but "it swung, at this
	moment" crosses the wire, because every machine already has StrikeConfig.
]]
local function stampStrike(model: Model, strikeId: string)
	model:SetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE, strikeId)
	model:SetAttribute(StrikeConfig.STRIKE_ATTRIBUTE, workspace:GetServerTimeNow())
end

--[[
	The boss's heavy: a telegraphed shockwave that anybody standing in it eats.

	Damage is applied AFTER the wind-up and only to whoever is still inside the radius,
	which is the entire point — the animation raises both arms overhead for well over a
	second, and walking out during that window costs nothing. A boss that simply hit
	harder would be a bigger thief; one you have to read turns the fight into something
	with a rhythm.

	Falloff is Formulas.SlamFalloff, the same curve the player's own Ground Slam uses, so
	the two read identically from either end.
]]
function MobService:_ultimate(model: Model, record: Live, now: number)
	local definition = record.Definition
	local radius = definition.UltimateRadius or 0
	local windup = definition.UltimateWindup or 0
	if radius <= 0 then
		return
	end

	record.NextUltimateAt = now + (definition.UltimateCooldown or 0)
	record.Charging = true
	stampStrike(model, ULTIMATE_STRIKE)

	task.delay(windup, function()
		record.Charging = false
		-- Everything can have changed across a second and a third of real time: the boss
		-- may be dead, despawned, or have been dragged home by its leash.
		if live[model] == nil or model.Parent == nil or record.Humanoid.Health <= 0 then
			return
		end

		local epicentre = record.Root.Position
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			if root == nil or not root:IsA("BasePart") then
				continue
			end
			local offset = (root.Position - epicentre).Magnitude
			local falloff = Formulas.SlamFalloff(offset, radius)
			if falloff <= 0 then
				continue
			end
			CombatService:ApplyEnvironmentDamage(
				definition.DisplayName,
				player,
				definition.Damage * (definition.UltimateMultiplier or 1) * falloff,
				definition.AttackStat
			)
		end
	end)
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

		-- Mid-windup the boss is committed. Letting it throw an ordinary swing out of
		-- the middle of its own heavy would make the telegraph a lie.
		if record.Charging then
			continue
		end

		local nextUltimate = record.NextUltimateAt
		if nextUltimate ~= nil and now >= nextUltimate then
			self:_ultimate(model, record, now)
			continue
		end

		if now >= record.NextAttackAt then
			record.NextAttackAt = now + definition.AttackCooldown
			stampStrike(model, SWING_STRIKE)
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

--[[
	How many of a field's slots are still cooling down, dropping any that have matured.

	Pure, and exposed rather than local, because it cannot be exercised through the
	game: a mob only queues a respawn when `_damage` kills it, so a test that sets
	`Humanoid.Health = 0` from a console bypasses the whole path — no respawn is
	queued, no corpse is cleaned up, and the field refills instantly, which looks
	exactly like this function being broken. It is not, and proving that needs to be
	possible without landing a real punch.

	Maturing here rather than on a timer means a field asleep for ten minutes settles
	its entire backlog the first time somebody walks back into range.
]]
function MobService.CoolingSlots(queue: { number }?, now: number): number
	if queue == nil then
		return 0
	end
	local index = 1
	while index <= #queue do
		if now >= queue[index] then
			table.remove(queue, index)
		else
			index += 1
		end
	end
	return #queue
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

		-- Slots still cooling down count as occupied.
		local waiting = MobService.CoolingSlots(respawnAt[definition.Id], os.clock())

		for _ = alive + waiting + 1, population do
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

		-- Chat, not a toast. A boss rising is news for the whole server, and a player
		-- who was mid-set when it happened can still scroll back and read it.
		Announce.Broadcast(`{site.Mob.DisplayName} has risen. Find the arena.`)
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
	in CombatService has to know a mob has a Humanoid.
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

		if definition.Kind ~= "Boss" then
			local cooldown = definition.RespawnSeconds
			if cooldown ~= nil and cooldown > 0 then
				local queue = respawnAt[definition.Id]
				if queue == nil then
					queue = {}
					respawnAt[definition.Id] = queue
				end
				table.insert(queue, os.clock() + cooldown)
			end
		end

		-- Leave the corpse for a beat so the kill reads, then clear it. The respawn
		-- loop counts living mobs and cooling slots, so the field refills on its own
		-- schedule rather than the moment the health hits zero.
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
