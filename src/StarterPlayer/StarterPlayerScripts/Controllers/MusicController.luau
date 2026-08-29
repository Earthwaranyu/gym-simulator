--!strict
--[[
	MusicController — the soundtrack, and the one thing that was persisted but never built.

	A `MusicEnabled` flag sat in the profile, in the settings menu and in the save file
	since long before this file existed, wired to nothing at all. A control that does
	nothing is worse than a missing feature, because the player concludes the game is
	broken rather than unfinished. This is the consumer it was always missing; the flag
	itself is now the music volume slider.

	## How the crossfade works, and why it is not a tween

	Both tracks are created once, looped, and left **playing for the whole session**. A
	switch moves their volumes past each other; it never starts or stops a Sound. That
	costs one extra decoded stream and buys three things: the combat track is already at
	the right point in its own bar when it fades up, going back to explore does not
	restart the theme from zero, and there is no load hitch at the worst possible moment.

	The fade itself is a Heartbeat clock rather than TweenService, and that is a direct
	reading of the warning in `EffectsController:_showTrainingGain` — a tween captures its
	start value when `Play()` is called, and a second tween on the same property silently
	cancels the first. "Fade A down while fading B up, and be interrupted halfway by the
	opposite switch" is exactly the case that breaks: the interrupted track keeps whatever
	volume it happened to be at, forever. Stepping the volumes toward a target each frame
	is interruptible by construction — a new target is just a new number.

	Ambience is a third stream on its own bus, started once and never touched. It is not
	part of the crossfade because it is not a cue; it is the floor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local MusicConfig = require(ReplicatedStorage.Modules.MusicConfig)
local SoundBus = require(ReplicatedStorage.Modules.SoundBus)

local MusicController = {
	Name = "MusicController",
	Priority = 6,
}

local ProfileController: any = nil
local CombatController: any = nil

local exploreSound: Sound? = nil
local combatSound: Sound? = nil
local ambienceSound: Sound? = nil

-- os.clock() of the most recent combat event. Combat music holds until this goes stale.
local lastCombatAt = -math.huge
-- False when the music slider is at zero; silences the two tracks without stopping them,
-- so bringing the slider back up resumes rather than restarts.
local enabled = true

local function makeLooping(id: string, groupName: string): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.SoundGroup = SoundBus.Get(groupName)
	sound.Parent = SoundService
	sound:Play()
	return sound
end

--[[
	Moves `sound` toward `target` at a rate that would cover the full range in
	CROSSFADE_SECONDS, and never overshoots.

	Rate-based rather than interpolating between a captured start and end, which is what
	makes it safe to change `target` on any frame — the one property the tween version
	could not offer.
]]
local function approach(sound: Sound, target: number, delta: number)
	local step = delta / MusicConfig.CROSSFADE_SECONDS
	local difference = target - sound.Volume
	if math.abs(difference) <= step then
		sound.Volume = target
		return
	end
	sound.Volume += if difference > 0 then step else -step
end

function MusicController:Init()
	ProfileController = Loader.Get("ProfileController")
	CombatController = Loader.Get("CombatController")
	SoundBus.Ensure()
end

--[[
	Marks the player as in combat. Any hit, dealt or taken, counts: being punched by
	somebody you never saw is precisely the moment the music is for.
]]
function MusicController:NoteCombat()
	lastCombatAt = os.clock()
end

function MusicController:_readSettings()
	local data = if ProfileController ~= nil then ProfileController:Get() else nil
	if data == nil then
		return
	end
	enabled = SoundBus.ReadVolume(data.Settings, "MusicVolume", 70) > 0
end

function MusicController:Start()
	for _, failure in MusicConfig.RunSelfTest() do
		warn(`[MusicController] {failure}`)
	end

	exploreSound = makeLooping(MusicConfig.Explore.SoundId, "Music")
	combatSound = makeLooping(MusicConfig.Combat.SoundId, "Music")
	ambienceSound = makeLooping(MusicConfig.Ambience.SoundId, "Ambience")

	self:_readSettings()
	if ProfileController ~= nil then
		ProfileController.Changed:Connect(function()
			self:_readSettings()
		end)
	end

	if CombatController ~= nil and CombatController.Feedback ~= nil then
		CombatController.Feedback:Connect(function()
			self:NoteCombat()
		end)
	end

	-- Taking a hit from someone you never targeted does not go through CombatController's
	-- own feedback, so the victim side is read off the character the server stamps.
	local function watchLocal(character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return
		end
		humanoid.HealthChanged:Connect(function(health: number)
			if health < humanoid.MaxHealth then
				self:NoteCombat()
			end
		end)
	end

	local player = Players.LocalPlayer
	if player.Character ~= nil then
		watchLocal(player.Character)
	end
	player.CharacterAdded:Connect(watchLocal)

	RunService.Heartbeat:Connect(function(delta: number)
		local explore, combat, ambience = exploreSound, combatSound, ambienceSound
		if explore == nil or combat == nil or ambience == nil then
			return
		end

		local fighting = (os.clock() - lastCombatAt) < MusicConfig.COMBAT_RELEASE_SECONDS

		if not enabled then
			approach(explore, 0, delta)
			approach(combat, 0, delta)
		elseif fighting then
			approach(explore, 0, delta)
			approach(combat, MusicConfig.Combat.Volume, delta)
		else
			approach(explore, MusicConfig.Explore.Volume, delta)
			approach(combat, 0, delta)
		end

		-- Ambience follows the music toggle too. Someone who turns music off wants the
		-- game quiet, not the soundtrack swapped for a room tone.
		approach(ambience, if enabled then MusicConfig.Ambience.Volume else 0, delta)
	end)
end

return MusicController
