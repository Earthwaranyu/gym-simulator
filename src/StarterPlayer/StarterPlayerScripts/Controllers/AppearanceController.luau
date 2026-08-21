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
	  * **The face**, a SurfaceGui of Frames from FaceConfig. It hangs on its own thin
	    canvas part a hair in front of the head rather than on the head itself,
	    because BodyMeshController welds a generated mesh head over the stock one and
	    a decal on the part underneath would be inside it.

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

-- How far in front of the head the face canvas floats, as a fraction of head depth.
-- Enough to clear the mesh head, little enough that it never reads as detached.
local FACE_LIFT = 0.02

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

	-- A flat, invisible canvas. Sized to the head's front face so the fractions in
	-- FaceConfig land where the config says they do.
	local canvas = Instance.new("Part")
	canvas.Name = "FaceCanvas"
	canvas.Size = Vector3.new(size.X, size.Y, 0.05)
	canvas.Transparency = 1
	canvas.Anchored = false
	canvas.CanCollide = false
	canvas.CanQuery = false
	canvas.CanTouch = false
	canvas.Massless = true
	canvas.CastShadow = false
	canvas.Parent = folder

	-- The head faces -Z, so the canvas sits just beyond that face.
	weldTo(head, canvas, CFrame.new(0, 0, -(size.Z * 0.5 + size.Z * FACE_LIFT)))

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Back
	gui.AlwaysOnTop = false
	gui.LightInfluence = 1
	gui.PixelsPerStud = 96
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.Adornee = canvas
	gui.Parent = canvas

	for index, feature in face.Features do
		local frame = Instance.new("Frame")
		frame.Name = `Feature{index}`
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Config x runs right-to-left from the viewer's side of the face; the GUI is
		-- on the back face of the canvas, which flips it back the right way round.
		frame.Position = UDim2.fromScale(0.5 + feature.Pos.X, 0.5 - feature.Pos.Y)
		frame.Size = UDim2.fromScale(feature.Size.X, feature.Size.Y)
		frame.Rotation = feature.Rotation or 0
		frame.BackgroundColor3 = feature.Color or FaceConfig.Ink
		frame.BorderSizePixel = 0
		frame.Parent = gui

		if feature.Shape == "Ellipse" then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = frame
		end
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
