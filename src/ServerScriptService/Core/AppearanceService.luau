--!strict
--[[
	AppearanceService — the body a player chose, kept honest.

	This game used to put everybody in the same body on purpose: next to a player
	wearing a bulky hat, a cape and a dominus, three trillion Chest is invisible, so
	nobody wore anything and the skin colour came from the muscle class. Half of that
	still holds and always will — `strip()` below deletes every Shirt, Pants, Accessory
	and CharacterMesh that arrives, forever, and `StarterPlayer.LoadCharacterAppearance`
	is false in default.project.json so the player's own avatar never loads to begin
	with. Nothing a player owns outside this game gets to change their silhouette here.

	What changed is *colour*. Colour never carried the silhouette, and making everyone
	the same shade of their class meant two players at the same class were literally
	indistinguishable. So skin and shorts are now the player's own choice, out of
	AppearanceConfig, and muscle class is read off the shape of the body alone — which
	is the thing this game is actually about. Hair and face come from HairConfig and
	FaceConfig, both built from primitives because the asset rule allows nothing anyone
	else drew.

	**The shorts are body colour, not clothing.** R15's UpperLeg parts are exactly the
	area shorts cover, so colouring them separately reads as shorts from every angle,
	needs no uploaded texture (the project allows none), costs no extra instances, and —
	the part that matters here — grows automatically with Legs, because it *is* the leg.
	A welded shorts part would have to be resized in lockstep with muscle scaling and
	would clip the first time it fell behind.

	Hair and face are **not** built here. They are published as character attributes and
	drawn by AppearanceController on every client, the same division MuscleService uses
	for muscle scale: the server owns the decision, the client owns the instances. That
	keeps a dozen decorative parts per player out of replication entirely.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AppearanceConfig = require(ReplicatedStorage.Modules.AppearanceConfig)
local FaceConfig = require(ReplicatedStorage.Modules.FaceConfig)
local HairConfig = require(ReplicatedStorage.Modules.HairConfig)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local ProfileTemplate = require(ReplicatedStorage.Modules.ProfileTemplate)

local AppearanceService = {
	Name = "AppearanceService",
	-- Before MuscleService: the body should be painted before anything starts
	-- resizing it.
	Priority = 15,
}

-- Attribute names the client renders from. Also the flag that holds a player still
-- while they are still choosing — CombatService reads Customizing when it decides
-- what their walk speed should be.
local HAIR_ATTRIBUTE = "HairId"
local FACE_ATTRIBUTE = "FaceId"
local CUSTOMIZING_ATTRIBUTE = "Customizing"

local DataService: any = nil

-- Everything that would make one player look different from another.
--
-- Decal is in here for the stock R15 face. Leaving it on was what made every player
-- wear the same Roblox smiley no matter which expression they picked — the drawn face
-- was a second face behind it. Characters carry no other decal, so this is safe as a
-- blanket rule, and the DescendantAdded guard below keeps it from coming back.
local WORN_CLASSES = {
	"Shirt",
	"Pants",
	"ShirtGraphic",
	"CharacterMesh",
	"Accessory",
	"Hat",
	"Decal",
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
	The player's saved choice, or the template's defaults when their profile has not
	arrived yet. CharacterAdded regularly beats ProfileStore, and a character that
	waits for data is a character standing there grey; ProfileLoaded repaints.
]]
local function appearanceFor(player: Player)
	local data = DataService:GetData(player)
	if data ~= nil and type(data.Appearance) == "table" then
		return data.Appearance
	end
	return ProfileTemplate.Appearance
end

--[[
	Paints the uniform. BodyColors rather than per-part Color so that a part replaced
	by Roblox later (a limb re-added after a state change) still comes back right.
]]
local function paint(player: Player, character: Model)
	local appearance = appearanceFor(player)
	local skin = AppearanceConfig.Color(AppearanceConfig.SkinTones, appearance.SkinId)
	local pants = AppearanceConfig.Color(AppearanceConfig.PantColors, appearance.PantId)

	local existing = character:FindFirstChildOfClass("BodyColors")
	local body: BodyColors
	if existing ~= nil then
		body = existing
	else
		body = Instance.new("BodyColors")
		body.Parent = character
	end

	body.HeadColor3 = skin
	body.TorsoColor3 = skin
	body.LeftArmColor3 = skin
	body.RightArmColor3 = skin
	body.LeftLegColor3 = pants
	body.RightLegColor3 = pants

	-- BodyColors' Leg entries cover the whole leg on R15, so the lower legs have to be
	-- painted back to skin individually. That split — dark thigh, bare shin — is what
	-- makes it read as shorts rather than as trousers.
	for _, name in { "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" } do
		local part = character:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			part.Color = skin
		end
	end

	character:SetAttribute(HAIR_ATTRIBUTE, appearance.HairId)
	character:SetAttribute(FACE_ATTRIBUTE, appearance.FaceId)
end

--[[
	Holds a player in place while the first-join creator is open, and lets them go
	afterwards. Server-side on purpose: the client that owns the panel is also the
	client that could simply not open it.

	WalkSpeed is not set here. CombatService reasserts it from the Legs stat every
	tick, so a value written from this file would survive about a frame; it reads the
	Customizing attribute instead, exactly as it already does for TrainingPose.

	Jumping is disabled as a humanoid *state* rather than by zeroing JumpPower, which
	is what TrainingService does. Two systems zeroing the same number is how one of
	them ends up handing a mounted player their jump back: re-enabling the state while
	they are locked to a machine still leaves TrainingService's zero in force.
]]
local function gate(player: Player, character: Model)
	local chosen = appearanceFor(player).Chosen == true
	character:SetAttribute(CUSTOMIZING_ATTRIBUTE, not chosen)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, chosen)
	end
end

local function apply(player: Player, character: Model)
	strip(character)
	paint(player, character)
	gate(player, character)

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

function AppearanceService:Refresh(player: Player)
	local character = player.Character
	if character ~= nil then
		paint(player, character)
		gate(player, character)
	end
end

function AppearanceService:Init()
	DataService = Loader.Get("DataService")

	--[[
		One call carries the whole look, so a player never ends up saved half-way
		through a change. Every id is checked against its config: the ids are the only
		thing standing between this remote and an arbitrary write into the profile.
	]]
	Net.BindFunction("SetAppearance", 4, function(player: Player, choice: any)
		if type(choice) ~= "table" then
			return false, "Invalid appearance."
		end

		local data = DataService:GetData(player)
		if data == nil then
			return false, "Your data is still loading."
		end

		if
			not AppearanceConfig.IsValid(AppearanceConfig.SkinTones, choice.SkinId)
			or not AppearanceConfig.IsValid(AppearanceConfig.PantColors, choice.PantId)
			or not HairConfig.IsValid(choice.HairId)
			or not FaceConfig.IsValid(choice.FaceId)
		then
			return false, "That look is not available."
		end

		data.Appearance.SkinId = choice.SkinId
		data.Appearance.PantId = choice.PantId
		data.Appearance.HairId = choice.HairId
		data.Appearance.FaceId = choice.FaceId
		data.Appearance.Chosen = true

		DataService:MarkDirty(player)
		self:Refresh(player)
		return true, "Looking good."
	end)
end

function AppearanceService:Start()
	local function bind(player: Player)
		if player.Character ~= nil then
			apply(player, player.Character)
		end
		player.CharacterAppearanceLoaded:Connect(function(character: Model)
			apply(player, character)
		end)
		player.CharacterAdded:Connect(function(character: Model)
			apply(player, character)
		end)
	end

	for _, player in Players:GetPlayers() do
		bind(player)
	end
	Players.PlayerAdded:Connect(bind)
	-- CharacterAdded can run before ProfileStore finishes loading. That first pass uses
	-- the template defaults; repaint once the real choice is available.
	DataService.ProfileLoaded:Connect(function(player: Player)
		self:Refresh(player)
	end)
end

return AppearanceService
