--!strict
--[[
	AppearanceService — one body for everybody.

	This is a game about a body changing shape. That only reads if the shape is the
	only thing that differs: next to a player wearing a bulky hat, a cape and a
	dominus, three trillion Chest is invisible. So nobody wears anything. Everyone is
	the same untextured rig in the same skin tone with the same shorts, and the only
	thing that distinguishes two players is what they have trained.

	`StarterPlayer.LoadCharacterAppearance` is false (see `default.project.json`), so
	Roblox never applies the player's own avatar in the first place. This file is the
	second half of that: it strips anything that still arrives, and paints the uniform.

	**The shorts are body colour, not clothing.** R15's UpperLeg parts are exactly the
	area shorts cover, so colouring them dark reads as shorts from every angle, needs
	no uploaded texture (the project allows none), costs no extra instances, and — the
	part that matters here — grows automatically with Legs, because it *is* the leg.
	A welded shorts part would have to be resized in lockstep with muscle scaling and
	would clip the first time it fell behind.
]]

local Players = game:GetService("Players")

local AppearanceService = {
	Name = "AppearanceService",
	-- Before MuscleService: the body should be uniform before anything starts
	-- resizing it.
	Priority = 15,
}

-- One skin tone for every player. Deliberately mid-range: a very light or very dark
-- uniform loses the shading that makes a swollen limb read as swollen.
local SKIN = Color3.fromRGB(204, 172, 137)
-- The shorts. Dark enough to separate from any skin tone at a glance.
local SHORTS = Color3.fromRGB(38, 42, 52)

-- Everything that would make one player look different from another.
local WORN_CLASSES = {
	"Shirt",
	"Pants",
	"ShirtGraphic",
	"CharacterMesh",
	"Accessory",
	"Hat",
}

local function strip(character: Model)
	for _, descendant in character:GetDescendants() do
		for _, className in WORN_CLASSES do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
end

--[[
	Paints the uniform. BodyColors rather than per-part Color so that a part replaced
	by Roblox later (a limb re-added after a state change) still comes back uniform.
]]
local function paint(character: Model)
	local existing = character:FindFirstChildOfClass("BodyColors")
	local body: BodyColors
	if existing ~= nil then
		body = existing
	else
		body = Instance.new("BodyColors")
		body.Parent = character
	end

	body.HeadColor3 = SKIN
	body.TorsoColor3 = SKIN
	body.LeftArmColor3 = SKIN
	body.RightArmColor3 = SKIN
	body.LeftLegColor3 = SHORTS
	body.RightLegColor3 = SHORTS

	-- BodyColors' Leg entries cover the whole leg on R15, so the lower legs have to be
	-- painted back to skin individually. That split — dark thigh, bare shin — is what
	-- makes it read as shorts rather than as trousers.
	for _, name in { "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" } do
		local part = character:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			part.Color = SKIN
		end
	end
end

local function apply(character: Model)
	strip(character)
	paint(character)

	-- Anything that arrives late — Roblox occasionally applies an accessory a frame
	-- or two after CharacterAdded — gets the same treatment.
	character.DescendantAdded:Connect(function(descendant: Instance)
		for _, className in WORN_CLASSES do
			if descendant:IsA(className) then
				descendant:Destroy()
				return
			end
		end
	end)
end

function AppearanceService:Start()
	local function bind(player: Player)
		if player.Character ~= nil then
			apply(player.Character)
		end
		player.CharacterAppearanceLoaded:Connect(apply)
		player.CharacterAdded:Connect(apply)
	end

	for _, player in Players:GetPlayers() do
		bind(player)
	end
	Players.PlayerAdded:Connect(bind)
end

return AppearanceService
