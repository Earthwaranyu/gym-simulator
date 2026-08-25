--!strict
--[[
	Types — shared type definitions for both realms.

	Deliberate choice: StatId is `string`, not a union of the five stat names. A union
	would make Types.luau a second source of truth that has to be edited every time a
	stat is added, which is exactly what the open/closed rule forbids. StatConfig is
	the only place stats are declared, and it validates ids at runtime instead.

	Same reasoning applies to EquipmentId, AbilityId, and QuestId.
]]

local Types = {}

export type StatId = string
export type EquipmentId = string
export type AbilityId = string
export type QuestId = string

-- Stat name -> raw value. Values run into the trillions; format with NumberFormat.
export type StatMap = { [StatId]: number }

-- Stat name -> how many multiplier upgrades have been bought for it.
export type MultiplierMap = { [StatId]: number }

--[[
	The shape persisted per player. Every field must have a default in ProfileTemplate,
	and every added field needs a migration entry so existing saves pick it up.
]]
export type ProfileData = {
	SchemaVersion: number,

	Stats: StatMap,
	MultiplierLevels: MultiplierMap,
	-- Permanent ordered physique level. Transforming costs Fight Tokens and requires
	-- Power. Progress survives even though the visible body begins lean again.
	MuscleClassLevel: number,
	-- Lifetime stat totals captured when the current physique was unlocked. Visible
	-- muscle growth uses Stats - this baseline, so a transformation can return the
	-- avatar to a lean shape without deleting any combat or progression stats.
	PhysiqueStatBaselines: StatMap,

	-- Spent on multiplier upgrades. Earned by playtime in a gym zone, and by quests.
	Tokens: number,
	-- Spent on physique transformations. One is earned for a rewarded direct or
	-- reflected knockout; repeat-farmed knockouts pay none.
	FightTokens: number,

	OwnedEquipment: { [EquipmentId]: boolean },
	QuestProgress: { [QuestId]: number },
	-- Which step of the repeating quest cycle is active, as a 0-based counter that
	-- only ever increases. The active quest is cycle[(index % #cycle) + 1], so the
	-- rotation survives a quest being added or removed between releases.
	QuestCycleIndex: number,
	-- How many full rotations are finished. Goals and rewards grow with this.
	QuestCycleLoop: number,

	-- Roblox PurchaseId -> true for every receipt already granted. Roblox retries
	-- ProcessReceipt until it is acknowledged, so without this a network blip would
	-- hand out the same product twice.
	PurchaseHistory: { [string]: boolean },

	-- Signed score. Negative trends Criminal, positive trends Hero; ReputationConfig
	-- maps ranges to tier names so the bands can be retuned without a migration.
	Reputation: number,

	-- os.time() at which purchased PvP immunity lapses. 0 means never bought one.
	ImmortalUntil: number,
	-- os.date "%Y-%m-%d" of the last VIP daily potion claim. Empty means never claimed.
	VipLastClaimDay: string,

	Kills: number,
	Deaths: number,
	KillsByReputation: { [string]: number },

	TotalPlaytime: number,

	-- Zone id -> the last manually selected load in kg. Sparse: the district's
	-- lightest load is used until a player chooses another one.
	SelectedWeights: { [string]: number },
	-- Convenience preference. It only takes effect while the Auto Load gamepass is
	-- currently owned; keeping the preference means a returning owner stays opted in.
	AutoLoadEnabled: boolean,
	-- One power-earned title selected for the overhead nameplate.
	SelectedTitleId: string,

	-- Ids into AppearanceConfig/HairConfig/FaceConfig. Chosen is false only for a
	-- player who has never completed the first-join customizer.
	Appearance: {
		SkinId: string,
		PantId: string,
		HairId: string,
		FaceId: string,
		Chosen: boolean,
	},

	-- Volumes are 0-100 because that is what a slider shows. Zero is the mute that the
	-- MusicEnabled/SfxEnabled booleans used to be; see _Migrations for the conversion.
	Settings: {
		MasterVolume: number,
		MusicVolume: number,
		SfxVolume: number,
	},
}

--[[
	The read-only view replicated to the owning client. Currently the whole profile;
	kept as a separate alias so server-only fields can be withheld later without
	touching every consumer.
]]
export type ProfileView = ProfileData

--[[
	What a player is currently doing at a training station. Nil StationId means idle.

	StaggerSeconds is how long they are locked off machines after being hit, measured
	at the moment the state was sent — the client counts it down locally rather than
	the server streaming a timer.
]]
export type TrainingState = {
	StationId: EquipmentId?,
	Combo: number,
	StaggerSeconds: number,
	ZoneId: string?,
	WeightKg: number,
	MinWeightKg: number,
	MaxWeightKg: number,
	StepWeightKg: number,
	RecommendedWeightKg: number,
	WeightMultiplier: number,
	RequiredStat: number,
	AutoLoadEnabled: boolean,
	HasAutoLoad: boolean,
}

-- One completed training rep after every server-side modifier and stat cap has been
-- applied. Rep durations vary; PerSecond stays explicit so feedback never reconstructs
-- the multiplier stack or cadence locally.
export type TrainingGain = {
	StatId: StatId,
	Amount: number,
	PerSecond: number,
	-- Zero/zero for manual training. Machine training fills these so the popup can
	-- explain exactly when the uninterrupted-set bonus turns on.
	Combo: number,
	ComboGoal: number,
	ComboMultiplier: number,
}

--[[
	A source of stat multiplication. Everything that boosts gains — token upgrades,
	gamepasses, timed supplements, event buffs — registers as one of these rather
	than special-casing the gain formula.
]]
export type Modifier = {
	Id: string,
	-- Multiplier applied to gains. 2.0 doubles. Return per-stat via StatId, or use
	-- "*" as the key to apply to every stat.
	Multipliers: { [StatId]: number },
	-- os.time() at which this expires. Nil means permanent.
	ExpiresAt: number?,
}

--[[
	What an ability receives when it fires. The server resolves every field before
	calling Execute, so abilities never have to re-validate that a character exists.
]]
export type AbilityContext = {
	Attacker: Player,
	AttackerCharacter: Model,
	AttackerRoot: BasePart,
	-- Nil whenever the thing being hit is not a player. Kept for abilities written
	-- before non-player combatants existed; new code should read CombatTarget.
	Target: Player?,
	TargetCharacter: Model?,
	TargetRoot: BasePart?,
	-- The resolved target of any kind. Nil only when the swing hit nothing at all.
	CombatTarget: CombatTarget?,
}

--[[
	The contract every ability module implements. Dropping a file into
	CombatService/Abilities/ that returns one of these registers a new attack — there
	is no list to append to and no branch in CombatService to extend.
]]
export type Ability = {
	Id: AbilityId,
	DisplayName: string,
	-- Seconds before this ability can be used again. With stamina removed, this is the
	-- only thing rate-limiting an ability.
	Cooldown: number,
	-- Max studs between attacker and target.
	Range: number,
	-- Scales the stat-derived base damage from Formulas.AttackDamage.
	DamageMultiplier: number,
	-- When true the server refuses to fire without a living target in range.
	RequiresTarget: boolean,
	-- When true, an omitted/dead client target is replaced by the nearest living player
	-- in range. Close combat uses this so camera aim is never a hidden hit requirement.
	AutoTarget: boolean?,
	-- Optional extra gate. Return false plus a player-facing reason to block.
	Validate: ((AbilityContext) -> (boolean, string?))?,
	-- Second argument is CombatService; typed loosely to avoid a circular reference.
	Execute: (AbilityContext, any) -> (),
}

--[[
	The contract every purchasable implements. Modules in PurchaseService/Products/ that
	return one of these register themselves — adding a product is a new file, never a
	branch in the receipt handler.

	AssetId must be filled in from the Roblox Creator Dashboard. A product left at 0 is
	skipped at load with a warning rather than silently matching receipt id 0.
]]
--[[
	Whatever an ability ended up aimed at.

	Kind discriminates rather than a nil check on Player, because a mob and a player
	both have a Model and a Root and the difference has to survive being passed around.
	AbilityContext keeps its original `Target: Player?` field alongside this, so every
	consumer written before mobs existed still type-checks and still sees nil when the
	thing being hit is not a player.
]]
export type CombatTarget = {
	Kind: "Player" | "Entity",
	Player: Player?,
	Model: Model,
	Root: BasePart,
}

export type Product = {
	Id: string,
	Kind: "DevProduct" | "Gamepass",
	AssetId: number,
	DisplayName: string,
	Description: string,
	-- Fallback only. The shop shows the Creator Dashboard price, read at runtime by
	-- PurchaseService/ProductInfo; this is what it falls back to when that call fails.
	RobuxPrice: number,
	-- DevProducts: called once per purchase, after the receipt is confirmed new.
	-- Gamepasses: called on join and immediately on purchase. Must be idempotent.
	Grant: (Player) -> boolean,
}

--[[
	The contract every quest module implements. Modules in QuestService/Quests/ that
	return one of these register themselves.

	Track is called once at startup with a callback the quest uses to report progress.
	Each quest wires its own listener, so the quest engine never needs to know what
	kinds of objective exist — adding "win 5 fights" is a new file, not a new branch.
]]
-- What kind of objective a quest is, so the tracker can tell training from fighting.
export type QuestCategory = "Stat" | "Combat"

export type Quest = {
	Id: QuestId,
	DisplayName: string,
	Description: string,
	-- Defaults to "Stat" when a quest omits it.
	Category: QuestCategory?,
	-- Position in the repeating rotation, unique across all quests. The cycle advances
	-- one step at a time and wraps, so this is the whole ordering.
	CycleOrder: number,
	-- Progress and payout for a given loop number, zero-based. They are functions
	-- rather than constants because stats scale exponentially: a goal that is right on
	-- the first rotation is trivial by the tenth.
	GoalAt: (loop: number) -> number,
	RewardAt: (loop: number) -> number,
	-- Returns ...any rather than () for the same reason as Loader's System.Init: with
	-- a () return, pcall's result arity is 1 and the error string cannot be captured.
	--
	-- Every quest's listener is live from startup, including the two that are not the
	-- active step. QuestService discards reports from inactive quests, so a quest never
	-- has to know whether it is currently the one being asked for.
	Track: (report: (Player, number) -> ()) -> ...any,
}

-- Key meaning "applies to every stat" inside Modifier.Multipliers.
Types.ALL_STATS = "*" :: StatId

return Types
