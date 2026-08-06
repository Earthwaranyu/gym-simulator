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

	-- Spent on multiplier upgrades. Earned by playtime in a gym zone, and by quests.
	Tokens: number,
	-- Spent in the shop. Earned from reps and kills. Distinct from Tokens on purpose.
	Cash: number,

	OwnedEquipment: { [EquipmentId]: boolean },
	QuestProgress: { [QuestId]: number },
	-- Quest id -> the UTC day it was last completed, or "once" for one-shot quests.
	-- Daily quests compare this against today to decide whether to reset progress.
	QuestCompletions: { [QuestId]: string },

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

	TotalPlaytime: number,

	Settings: {
		MusicEnabled: boolean,
		SfxEnabled: boolean,
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
	Target: Player?,
	TargetCharacter: Model?,
	TargetRoot: BasePart?,
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
export type Product = {
	Id: string,
	Kind: "DevProduct" | "Gamepass",
	AssetId: number,
	DisplayName: string,
	Description: string,
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
export type Quest = {
	Id: QuestId,
	DisplayName: string,
	Description: string,
	-- Progress needed to complete.
	Goal: number,
	TokenReward: number,
	-- "Once" never resets; "Daily" resets at UTC midnight.
	Repeat: "Once" | "Daily",
	-- Returns ...any rather than () for the same reason as Loader's System.Init: with
	-- a () return, pcall's result arity is 1 and the error string cannot be captured.
	Track: (report: (Player, number) -> ()) -> ...any,
}

-- Key meaning "applies to every stat" inside Modifier.Multipliers.
Types.ALL_STATS = "*" :: StatId

return Types
