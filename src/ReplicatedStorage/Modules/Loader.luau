--!strict
--[[
	Loader — lifecycle bootstrapper shared by both realms.

	Requires every ModuleScript found under the registered containers, then runs a
	two-pass lifecycle: Init() on every system, then Start() on every system. The two
	passes are what let any system reach any other during Start without anyone having
	to declare a load order.

	Adding a system means dropping a file into a watched folder. This file, and every
	system already written, stay untouched — that is the open/closed rule the whole
	project is built on. There is no registration list to maintain anywhere.

	Realms get independent registries for free: a ModuleScript required from the server
	and from a client resolves to two separate module instances, so the server's
	services and a client's controllers never share this state.

	Conventions:
	  * Folders are traversed. ModuleScripts are systems.
	  * Children of a ModuleScript are NOT traversed — they belong to that module
	    (ability registries, quest definitions), not to the loader.
	  * Anything whose name starts with `_` is skipped, for helpers that live
	    alongside systems without being one.

	Usage (bootstrap script):
		Loader.AddContainer(ServerScriptService.Core)
		Loader.Ignite()

	Usage (inside a system, during Init or later — never at require time):
		local StatService = Loader.Get("StatService")
]]

local RunService = game:GetService("RunService")

export type System = {
	Name: string?,
	Priority: number?,
	Init: ((any) -> ())?,
	Start: ((any) -> ())?,
}

type Entry = {
	name: string,
	module: ModuleScript,
	system: System,
	priority: number,
}

local REALM = if RunService:IsServer() then "Server" else "Client"

local containers: { Instance } = {}
local registry: { [string]: System } = {}
local entries: { Entry } = {}
local ignited = false

local Loader = {}

local function collect(parent: Instance, out: { ModuleScript })
	for _, child in parent:GetChildren() do
		if child.Name:sub(1, 1) == "_" then
			continue
		end

		if child:IsA("ModuleScript") then
			table.insert(out, child)
		elseif child:IsA("Folder") then
			collect(child, out)
		end
	end
end

--[[
	Registers a folder whose ModuleScripts should be loaded as systems.
	Must be called before Ignite.
]]
function Loader.AddContainer(container: Instance)
	if ignited then
		error(`[Loader/{REALM}] AddContainer must be called before Ignite`, 2)
	end
	table.insert(containers, container)
end

--[[
	Returns a loaded system by name. Safe from Init onwards; calling it while a
	module is still being required will fail, because that system may not exist yet.
]]
function Loader.Get(name: string): any
	local system = registry[name]
	if system == nil then
		error(
			`[Loader/{REALM}] No system named "{name}" is registered. `
				.. `Check the file sits inside a container passed to Loader.AddContainer, `
				.. `and that you are not calling Get at require time.`,
			2
		)
	end
	return system
end

function Loader.IsIgnited(): boolean
	return ignited
end

--[[
	Loads every system, then Init()s them all, then Start()s them all.
	Init runs sequentially so ordering is deterministic; Start is spawned per system
	so a system that yields forever (a game loop) cannot stall the others.
]]
function Loader.Ignite()
	if ignited then
		error(`[Loader/{REALM}] Ignite may only be called once per realm`, 2)
	end
	ignited = true

	local modules: { ModuleScript } = {}
	for _, container in containers do
		collect(container, modules)
	end

	for _, module in modules do
		local ok, result = xpcall(require, debug.traceback, module)
		if not ok then
			error(`[Loader/{REALM}] Failed to require {module:GetFullName()}:\n{result}`)
		end

		if type(result) ~= "table" then
			error(
				`[Loader/{REALM}] {module:GetFullName()} returned {typeof(result)}, expected a table. `
					.. `Prefix the file with "_" if it is a helper rather than a system.`
			)
		end

		local system = result :: System
		local name = system.Name or module.Name

		if registry[name] ~= nil then
			error(`[Loader/{REALM}] Duplicate system name "{name}" at {module:GetFullName()}`)
		end

		system.Name = name
		registry[name] = system
		table.insert(entries, {
			name = name,
			module = module,
			system = system,
			priority = system.Priority or 0,
		})
	end

	-- Higher priority first, then alphabetical so load order never depends on
	-- filesystem enumeration order.
	table.sort(entries, function(a: Entry, b: Entry): boolean
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.name < b.name
	end)

	for _, entry in entries do
		local init = entry.system.Init
		if init then
			local ok, err = xpcall(init, debug.traceback, entry.system)
			if not ok then
				error(`[Loader/{REALM}] {entry.name}:Init() failed:\n{err}`)
			end
		end
	end

	for _, entry in entries do
		local start = entry.system.Start
		if start then
			task.spawn(function()
				local ok, err = xpcall(start, debug.traceback, entry.system)
				if not ok then
					warn(`[Loader/{REALM}] {entry.name}:Start() failed:\n{err}`)
				end
			end)
		end
	end

	print(`[Loader/{REALM}] Ignited {#entries} systems`)
end

return Loader
