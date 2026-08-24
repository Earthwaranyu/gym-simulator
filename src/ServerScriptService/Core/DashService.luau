--!strict
--[[
	DashService — stops a dashing player bulldozing everyone in their way.

	A dash is 78 studs a second of real physics, and two character assemblies that
	collide push each other. So dashing past somebody shoved them along, and dashing
	into a crowd scattered it — which is funny once and then is a way to fling players
	off machines without ever throwing a punch.

	The fix is a collision group rather than anything in the mover. Every character
	part lives in `Character`, which collides with the world and with other characters
	exactly as before; while a player is dashing, their parts move to `Dashing`, which
	collides with the world and with nothing alive. You still cannot dash through a
	wall, and you no longer carry people with you.

	It has to be the server that does it. Collision groups replicate from here, and
	the push is simulated on both players' machines — the dasher's client owns the
	dasher, the victim's client owns the victim, so a group set locally would stop the
	shove on one screen and not the other.

	The client says when it is dashing, because the client is what dashes. That is
	safe to trust here: the flag grants nothing except the ability to walk through
	people, it is cleared by a timeout the client cannot extend, and a player who
	spoofed it perfectly would gain the ability to not push anybody — which is the
	polite behaviour this file exists to enforce.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Modules.Net)
local MovementConfig = require(ReplicatedStorage.Modules.MovementConfig)

local CHARACTER_GROUP = "Character"
local DASHING_GROUP = "Dashing"

-- How long the server will honour one dash before putting the player back among the
-- solid. Comfortably longer than the burst so ordinary latency never ends it early,
-- and short enough that a client which never says "stopped" is phased for a moment
-- rather than for the round.
local MAX_DASH_SECONDS = MovementConfig.DASH_SECONDS + 0.4

-- Two dashes a second is already more than the 1.1s cooldown allows.
local DASH_BUDGET_PER_SECOND = 4

local DashService = {
	Name = "DashService",
	Priority = 36,
}

-- Bumped per player per dash, so a timeout that fires after a newer dash began does
-- not end that newer one.
local generation: { [Player]: number } = {}

local function ensureGroups()
	for _, group in { CHARACTER_GROUP, DASHING_GROUP } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- A dasher passes through the living and nothing else. Two dashers pass through
	-- each other for the same reason one passes through a stander.
	PhysicsService:CollisionGroupSetCollidable(DASHING_GROUP, CHARACTER_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(DASHING_GROUP, DASHING_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(CHARACTER_GROUP, CHARACTER_GROUP, true)
end

local function setGroup(character: Model, group: string)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = group
		end
	end
end

--[[
	Puts a character in the ordinary character group, now and for anything added later.

	Accessories and tools arrive after the character does, and a hat left in the
	default group is a part of the player that still collides while they dash.
]]
local function adopt(character: Model)
	setGroup(character, CHARACTER_GROUP)
	character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			-- Whatever the character is in right now, so a hat picked up mid-dash does
			-- not stay solid for the rest of the burst.
			local current = character:GetAttribute("CollisionGroup")
			descendant.CollisionGroup = if type(current) == "string" then current else CHARACTER_GROUP
		end
	end)
	character:SetAttribute("CollisionGroup", CHARACTER_GROUP)
end

function DashService:_setDashing(player: Player, dashing: boolean)
	local character = player.Character
	if character == nil then
		return
	end

	local group = if dashing then DASHING_GROUP else CHARACTER_GROUP
	character:SetAttribute("CollisionGroup", group)
	setGroup(character, group)

	if not dashing then
		return
	end

	generation[player] = (generation[player] or 0) + 1
	local mine = generation[player]
	task.delay(MAX_DASH_SECONDS, function()
		if generation[player] ~= mine then
			return
		end
		if player.Character == character then
			self:_setDashing(player, false)
		end
	end)
end

function DashService:Start()
	ensureGroups()

	local function track(player: Player)
		if player.Character ~= nil then
			adopt(player.Character)
		end
		player.CharacterAdded:Connect(function(character: Model)
			generation[player] = (generation[player] or 0) + 1
			adopt(character)
		end)
	end

	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player: Player)
		generation[player] = nil
	end)

	Net.BindEvent("DashChanged", DASH_BUDGET_PER_SECOND, function(player: Player, dashing: any)
		if type(dashing) ~= "boolean" then
			return
		end
		self:_setDashing(player, dashing)
	end)
end

return DashService
