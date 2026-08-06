--!strict
--[[
	_Migrations — ordered schema upgrades for saved profiles.

	Underscore-prefixed so the Loader skips it: this is a helper the DataService owns,
	not a system with its own lifecycle.

	Steps[n] upgrades a profile that is *at* version n to version n+1. Version 1 means
	"original schema, no migrations run", so an empty Steps list pairs with
	SCHEMA_VERSION = 1. Apply() runs every step from the profile's stored version
	upwards, so a player away for five schema versions is walked through all five.

	You only need a step when existing values must be *transformed*. Adding a brand new
	field is handled by ProfileStore:Reconcile() against ProfileTemplate — no step needed.

	To add one:
	  1. Append a function to Steps.
	  2. Set SCHEMA_VERSION in ProfileTemplate.luau to #Steps + 1.
	  3. Never edit or reorder an existing step — live saves have already run them.
]]

local Migrations = {}

-- Each entry takes the profile data table and mutates it in place.
-- Steps[1] upgrades a version-1 profile to version 2, and so on.
local Steps: { (data: any) -> () } = {
	-- Example of what a real step looks like, kept as documentation:
	--
	-- [1] = function(data)
	--     -- v2 split the single "Power" number into per-stat values.
	--     if data.Power ~= nil then
	--         data.Stats = { Arms = data.Power / 5, Chest = data.Power / 5 }
	--         data.Power = nil
	--     end
	-- end,
}

-- A profile that has run every step sits at this version.
Migrations.CurrentVersion = #Steps + 1

--[[
	Brings a profile up to the current schema version. Returns how many steps ran, so
	the caller can log migrations without inspecting the data itself.

	A profile stamped newer than this server knows about is left alone rather than
	downgraded, which keeps a rolled-back server from corrupting newer saves.
]]
function Migrations.Apply(data: any): number
	local from = tonumber(data.SchemaVersion) or 1
	local applied = 0

	for version = from, #Steps do
		Steps[version](data)
		applied += 1
	end

	if applied > 0 then
		data.SchemaVersion = Migrations.CurrentVersion
	end

	return applied
end

return Migrations
