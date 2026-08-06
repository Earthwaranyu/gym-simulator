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
]]
export type TrainingState = {
	StationId: EquipmentId?,
	Combo: number,
	Stamina: number,
	MaxStamina: number,
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

-- Key meaning "applies to every stat" inside Modifier.Multipliers.
Types.ALL_STATS = "*" :: StatId

return Types
