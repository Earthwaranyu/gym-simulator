--!strict
--[[
	AppearanceController — draws the hair and face the server chose for every player.

	The server decides (AppearanceService writes HairId and FaceId as attributes on
	the character) and the client draws. That split is the same one MuscleService and
	MuscleController already use for muscle scale, and it is here for the same reason:
	a hairstyle is a dozen decorative parts per player, and none of them need to exist
	on the server, be replicated, collide, or be trusted. Delete this controller and
	the game still plays — everyone is just bald.

	Two things are drawn:

	  * **Hair**, primitives from HairConfig welded to the head. Sizes and offsets in
	    that config are fractions of the head, multiplied out here, so one style fits
	    a newbie and a player whose Chest broke a trillion.
	  * **The face**, thin primitives from FaceConfig stuck to the front of the skull.
	    It was a SurfaceGui first, and that shipped invisible: the GUI faced into the
	    head, so what everyone saw was Roblox's stock decal, identical on every player
	    and for every expression. Geometry cannot face the wrong way.

	The head measurement comes from that generated piece when it is there and from the
	stock Head when it is not, so hair sits on the head the player can actually see.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FaceConfig = require(ReplicatedStorage.Modules.FaceConfig)
local HairConfig = require(ReplicatedStorage.Modules.HairConfig)

local AppearanceController = {
	Name = "AppearanceController",
	-- After BodyMeshController (43): the generated head has to be welded on before
	-- we can measure against it.
	Priority = 45,
}

local FOLDER_NAME = "GeneratedAppearance"
local BODY_FOLDER = "GeneratedBody"
local HAIR_ATTRIBUTE = "HairId"
local FACE_ATTRIBUTE = "FaceId"

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
}

local function shade(color: Color3, amount: number?): Color3
	local value = amount or 0
	if value == 0 then
		return color
	end
	local target = if value > 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
	return color:Lerp(target, math.abs(value))
end

--[[
	The head as the player sees it. BodyMeshController's generated piece is welded at
	identity over the stock part but carries its own size, so measuring the stock Head
	alone would bury a hairstyle inside a larger sculpted skull.
]]
local function headSize(character: Model, head: BasePart): Vector3
	local body = character:FindFirstChild(BODY_FOLDER)
	if body ~= nil then
		local piece = body:FindFirstChild("Head")
		if piece ~= nil and piece:IsA("BasePart") then
			return piece.Size
		end
	end
	return head.Size
end

local function weldTo(head: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = head.CFrame * offset

	local weld = Instance.new("Weld")
	weld.Name = "AppearanceWeld"
	weld.Part0 = head
	weld.Part1 = part
	weld.C0 = offset
	weld.C1 = CFrame.identity
	weld.Parent = part
end

local function buildHair(character: Model, head: BasePart, folder: Folder)
	local style = HairConfig.Get(character:GetAttribute(HAIR_ATTRIBUTE) :: string?)
	local size = headSize(character, head)

	for index, piece in style.Pieces do
		-- A wedge is a different class rather than a Shape, so the instance is chosen
		-- before anything is set on it.
		local part: BasePart
		if piece.Shape == "Wedge" then
			part = Instance.new("WedgePart")
		else
			local block = Instance.new("Part")
			block.Shape = SHAPES[piece.Shape] or Enum.PartType.Block
			part = block
		end

		part.Name = `Hair{index}`
		part.Size = size * piece.Size
		part.Color = shade(style.Color, piece.Shade)
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false

		local rotation = piece.Rotation or Vector3.zero
		local offset = CFrame.new(size * piece.Offset)
			* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))

		part.Parent = folder
		weldTo(head, part, offset)
	end
end

local function buildFace(character: Model, head: BasePart, folder: Folder)
	local face = FaceConfig.Get(character:GetAttribute(FACE_ATTRIBUTE) :: string?)
	if #face.Features == 0 then
		return
	end

	local size = headSize(character, head)
	local depth = size.Z * FaceConfig.DEPTH
	-- Features sit on the front skin of the skull and stand out by their own depth, so
	-- the flat face of every one of them is flush with the head rather than sunk in it.
	local front = -(size.Z * 0.5)

	for index, feature in face.Features do
		local width = size.X * feature.Size.X
		local height = size.Y * feature.Size.Y

		local part = Instance.new("Part")
		part.Name = `Face{index}`

		if feature.Shape == "Ellipse" then
			--[[
				A Roblox cylinder's flat ends face along its **X** axis, not its Z. An
				eye disc therefore has to be built lying on its side and turned to face
				forward; sizing it as though the circle were in XY gives a sliver seen
				edge-on, which is the exact mistake the original muscle shells made.
			]]
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(depth, height, width)
		else
			part.Shape = Enum.PartType.Block
			part.Size = Vector3.new(width, height, depth)
		end

		part.Color = feature.Color or FaceConfig.Ink
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false

		-- Rotation is a roll about the axis pointing out of the face, so a brow tilts
		-- in the plane the player is looking at. The cylinder's quarter turn is applied
		-- after it, or the roll would spin the disc about the wrong axis entirely.
		local offset = CFrame.new(size.X * feature.Pos.X, size.Y * feature.Pos.Y, front)
			* CFrame.Angles(0, 0, math.rad(-(feature.Rotation or 0)))
		if feature.Shape == "Ellipse" then
			offset = offset * CFrame.Angles(0, math.rad(90), 0)
		end

		part.Parent = folder
		weldTo(head, part, offset)
	end
end

local function clear(character: Model)
	local folder = character:FindFirstChild(FOLDER_NAME)
	if folder ~= nil then
		folder:Destroy()
	end
end

local function render(character: Model)
	if character.Parent == nil then
		return
	end
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end

	clear(character)

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = character

	buildHair(character, head, folder)
	buildFace(character, head, folder)
end

--[[
	Rebuilds this character from scratch whenever the server changes either id.

	Tearing the whole folder down for a hair change is not thrift lost: a style is
	under a dozen parts, changes happen when a player presses a button in a menu, and
	the alternative is diffing two lists of primitives for no gain anyone can see.
]]
local function watch(player: Player)
	local function onCharacter(character: Model)
		if character:WaitForChild("Humanoid", 10) == nil then
			return
		end
		-- BodyMeshController waits a beat for the rig to assemble before it dresses;
		-- measuring the generated head means waiting for it to exist.
		task.wait(0.4)

		render(character)
		character:GetAttributeChangedSignal(HAIR_ATTRIBUTE):Connect(function()
			render(character)
		end)
		character:GetAttributeChangedSignal(FACE_ATTRIBUTE):Connect(function()
			render(character)
		end)
	end

	if player.Character ~= nil then
		task.spawn(onCharacter, player.Character :: Model)
	end
	player.CharacterAdded:Connect(function(character: Model)
		task.spawn(onCharacter, character)
	end)
	player.CharacterRemoving:Connect(clear)
end

--[[
	Draws one character immediately with ids supplied by the caller rather than by the
	server. The customizer previews a choice on the live body before it is committed;
	the next attribute change from the server puts everything back in charge.
]]
function AppearanceController:Preview(character: Model, hairId: string, faceId: string)
	-- Writing the attributes rather than rendering directly means the redraw goes
	-- through exactly the same path a server change does. A client-side attribute
	-- write does not replicate, so nobody else sees an uncommitted choice.
	character:SetAttribute(HAIR_ATTRIBUTE, hairId)
	character:SetAttribute(FACE_ATTRIBUTE, faceId)
end

function AppearanceController:Start()
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
end

return AppearanceController
