--!strict
--[[
	VoidService — catches anyone who falls off the world.

	The map used to sit on a 2,048-stud baseplate. It does not any more: districts
	float over nothing, which is the look the reference has and the only honest way
	to show islands. The cost is that walking off Downtown's promenade is a fall
	with no bottom, and Roblox's own answer to that — `FallenPartsDestroyHeight`
	destroys the character at -500 and the player respawns dead — is a punishment
	for a camera angle rather than for anything they did.

	So they get put back in the plaza instead. No death, no lost combo, no forfeited
	token tick: stepping off an edge is a mistake, not a play.

	The catch height is below every piece of geometry in the game — Downtown's rock
	underside reaches about -136 — and above the destroy height, so this fires first.
	A fall from Ascendant Peak at 1,530 studs still takes a while to get here, and
	that is deliberate: catching a flier the moment they dip below a district would
	make the space between islands unusable.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

local SAFE_ZONE_TAG = "SafeZone"
-- Below all geometry, above Workspace.FallenPartsDestroyHeight (-500).
local CATCH_HEIGHT = -250
-- Studs above the safe zone's floor to put them down.
local LANDING_CLEARANCE = 4
-- Checking every frame would be free, but once a quarter second is enough for
-- something that only fires on a fall of hundreds of studs.
local CHECK_INTERVAL = 0.25

local VoidService = {
	Name = "VoidService",
	Priority = 12,
}

local TrainingService: any = nil

function VoidService:Init()
	TrainingService = Loader.Get("TrainingService")
end

--[[
	Where to put someone down: the middle of the plaza's safe volume, at its floor.

	Resolved fresh each time rather than cached, because the volume is one tagged
	part in a streamed world and holding a reference to it is how you end up
	teleporting people to a destroyed instance.
]]
local function plazaLanding(): Vector3?
	for _, volume in CollectionService:GetTagged(SAFE_ZONE_TAG) do
		if volume:IsA("BasePart") then
			local floor = volume.Position.Y - volume.Size.Y / 2
			return Vector3.new(volume.Position.X, floor + LANDING_CLEARANCE, volume.Position.Z)
		end
	end
	return nil
end

function VoidService:_check()
	local landing: Vector3? = nil

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character == nil then
			continue
		end

		-- Anchored to a machine, so not falling anywhere.
		if TrainingService:IsTraining(player) then
			continue
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") or root.Position.Y > CATCH_HEIGHT then
			continue
		end

		-- Only look the plaza up once we know somebody actually fell.
		if landing == nil then
			landing = plazaLanding()
			if landing == nil then
				warn(`[VoidService] Nothing tagged "{SAFE_ZONE_TAG}"; cannot catch falls`)
				return
			end
		end

		character:PivotTo(CFrame.new(landing :: Vector3))
		Net.Event("Notify"):FireClient(player, "You fell off the world. Back to the plaza.")
	end
end

function VoidService:Start()
	local since = 0
	RunService.Heartbeat:Connect(function(delta: number)
		since += delta
		if since < CHECK_INTERVAL then
			return
		end
		since = 0
		self:_check()
	end)
end

return VoidService
