--!strict
--[[
	SoundBus — the mixing desk, built once and shared.

	Every Sound in the game plays on one of four buses hanging off a single Master:

	    Master ─┬─ Music      the soundtrack
	            ├─ Ambience   the world bed
	            ├─ Sfx        everything that happens in the world
	            └─ Ui         menus, and feedback about you rather than about the world

	## Why the buses are worth having

	Volume control is the boring half. The real reason is that a bus can be *ducked*. A
	`CompressorSoundEffect` whose `SideChain` points at `Sfx` sits on `Music` and
	`Ambience`, so the instant a punch lands the music steps back on its own and comes
	up again when the fight stops. Nothing has to script it, nothing has to know a fight
	is happening, and no sound has to be made louder to be heard over another. The
	alternative — turning combat up until it wins — makes a mix loud, not clear.

	The `EqualizerSoundEffect` on `Music` does the same job in frequency rather than in
	time: it gives up the low-mids permanently so impacts have somewhere to sit. Music
	loses almost nothing anybody notices; punches gain the part of the spectrum that
	makes them read as heavy.

	## Why this is code and not `default.project.json`

	The lighting stack next door *is* declared in Rojo, and this deliberately is not.
	Both the bus tree and the sidechain are **instance references** — `SoundGroup.SoundGroup`
	and `CompressorSoundEffect.SideChain` point at other instances — and a Rojo project
	file cannot express a reference to a sibling it also creates. Building it here keeps
	the wiring in one readable place instead of splitting it between a JSON file that can
	declare the boxes and a script that has to connect them anyway.

	`Ensure` is idempotent and take-or-create: it adopts anything already present rather
	than replacing it, so a saved place file that happens to contain a `Master` group does
	not end up with two.
]]

local SoundService = game:GetService("SoundService")

local SoundBus = {}

-- Sfx is the loudest thing that ever plays, so it sits at unity and everything else is
-- placed relative to it. Music sits well under: it is the floor of the mix, not the point.
local DEFAULTS: { [string]: number } = {
	Master = 1,
	Music = 0.45,
	Ambience = 0.3,
	Sfx = 1,
	Ui = 0.8,
}

local CHILDREN = { "Music", "Ambience", "Sfx", "Ui" }

-- How hard the music gets pushed down when the world makes a noise, and how fast it
-- recovers. A long release stops the music pumping on every jab of a fast exchange.
local DUCK_THRESHOLD = -22
local DUCK_RATIO = 5
local DUCK_ATTACK = 0.08
local DUCK_RELEASE = 0.65

local built = false

local function ensure(className: string, name: string, parent: Instance): Instance
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA(className) then
		return existing
	end
	if existing ~= nil then
		existing:Destroy()
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = parent
	return created
end

--[[
	Builds the tree if it is not there yet. Safe to call from anywhere, any number of
	times, from any controller that wants a bus.
]]
function SoundBus.Ensure()
	if built then
		return
	end
	built = true

	local master = ensure("SoundGroup", "Master", SoundService) :: SoundGroup
	master.Volume = DEFAULTS.Master

	for _, name in CHILDREN do
		local group = ensure("SoundGroup", name, SoundService) :: SoundGroup
		group.Volume = DEFAULTS[name]
		-- Cast: SoundGroup nests inside another SoundGroup, but the generated API types
		-- do not describe the property on the class itself.
		local nested: any = group
		nested.SoundGroup = master
	end

	local sfx = SoundService:FindFirstChild("Sfx") :: SoundGroup

	for _, name in { "Music", "Ambience" } do
		local group = SoundService:FindFirstChild(name) :: SoundGroup
		local duck = ensure("CompressorSoundEffect", "DuckUnderSfx", group) :: CompressorSoundEffect
		duck.Threshold = DUCK_THRESHOLD
		duck.Ratio = DUCK_RATIO
		duck.Attack = DUCK_ATTACK
		duck.Release = DUCK_RELEASE
		duck.SideChain = sfx
	end

	-- Carve the impact range out of the music rather than turning the music down.
	local music = SoundService:FindFirstChild("Music") :: SoundGroup
	local eq = ensure("EqualizerSoundEffect", "MakeRoomForImpacts", music) :: EqualizerSoundEffect
	eq.LowGain = -6
	eq.MidGain = -1
	eq.HighGain = 0
end

--[[
	The bus of the given name, building the desk first if needed. Falls back to Master
	for an unknown name: a sound on the wrong bus is a mixing problem, a sound that
	refuses to play is a bug report.
]]
function SoundBus.Get(name: string?): SoundGroup
	SoundBus.Ensure()
	local wanted = name or "Sfx"
	local group = SoundService:FindFirstChild(wanted)
	if group ~= nil and group:IsA("SoundGroup") then
		return group
	end
	return SoundService:FindFirstChild("Master") :: SoundGroup
end

--[[
	Applies the player's saved volumes. Values are 0-1; the stored defaults are the
	ceiling, so a slider at maximum is the mix as authored rather than louder than it.
]]
function SoundBus.SetVolumes(master: number, music: number, sfx: number)
	SoundBus.Ensure()
	local function set(name: string, scale: number)
		local group = SoundService:FindFirstChild(name)
		if group ~= nil and group:IsA("SoundGroup") then
			group.Volume = DEFAULTS[name] * math.clamp(scale, 0, 1)
		end
	end
	set("Master", master)
	set("Music", music)
	set("Ambience", music)
	set("Sfx", sfx)
	set("Ui", sfx)
end

return SoundBus
