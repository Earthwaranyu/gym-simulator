--!strict
--[[
	ProfileTemplate — the default shape of a saved player profile.

	ProfileStore:Reconcile() fills any missing top-level key from this table, so adding
	a scalar field here is enough for existing saves to pick it up on next load. Only
	changes that need existing values *transformed* require a migration step — see
	Core/_Migrations.luau.

	Note that Stats and MultiplierLevels start empty rather than listing the five stats.
	That is deliberate: StatService treats a missing entry as zero, so adding a sixth
	stat to StatConfig needs no template change and no migration. Reconcile only fills
	top-level keys anyway, so pre-seeding them would not reach existing saves.

	ProfileStore forbids these in saved data: Instances, userdata (Vector3, Color3,
	CFrame), functions, mixed tables, and numeric tables with gaps.
]]

local Types = require(script.Parent.Types)

-- Bump alongside a new entry in Core/_Migrations.luau.
local SCHEMA_VERSION = 1

local ProfileTemplate: Types.ProfileData = {
	SchemaVersion = SCHEMA_VERSION,

	Stats = {},
	MultiplierLevels = {},

	Tokens = 0,
	Cash = 0,

	OwnedEquipment = {},
	QuestProgress = {},
	QuestCompletions = {},
	PurchaseHistory = {},

	Reputation = 0,

	ImmortalUntil = 0,
	VipLastClaimDay = "",

	Kills = 0,
	Deaths = 0,

	TotalPlaytime = 0,

	Settings = {
		MusicEnabled = true,
		SfxEnabled = true,
	},
}

return ProfileTemplate
