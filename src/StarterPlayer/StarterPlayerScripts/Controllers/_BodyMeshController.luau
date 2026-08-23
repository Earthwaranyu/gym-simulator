--!strict
--[[
	BodyMeshController — dresses every character in the generated body mesh.

	The stock R15 parts stay exactly where they are and keep doing their job: they
	are the rig, the joints, the hitboxes and the thing animations move. They are
	simply made invisible, and a cut piece of the generated body is welded over
	each one. Nothing here is replicated and nothing here is authoritative; delete
	this controller and the game still plays, it just looks like blocks again.

	Why the stock parts are hidden the way they are:

	`LocalTransparencyModifier` is the only per-client way to hide a body part, and
	Roblox's own character and camera code writes it every frame (it is what fades
	your own body in first person). The muscle-shell system this replaces set it on
	a 0.1 second poll, which is why the bare R15 torso rectangle stayed visible
	through the shells no matter how the shells were tuned. It has to be reasserted
	every frame, from RenderStepped, or it does not stick.

	Known limitation, deliberately taken for now: the body is fitted once, with a
	single uniform scale, and is not refitted as stats grow. `MuscleController`
	still grows the R15 parts underneath, so hitboxes and reach continue to scale
	with stats, but the visible mesh keeps the size it was dressed at.

	The groundwork for fixing that is already here rather than pending: every piece
	is centred on its own geometry, so each one can be scaled independently without
	distorting. Per-limb growth is a matter of re-running the fit against each
	limb's live size on a poll, in this file alone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BodyMeshBuilder = require(ReplicatedStorage.Modules.BodyMeshBuilder)
local BodyMeshConfig = require(ReplicatedStorage.Modules.BodyMeshConfig)

local BodyMeshController = {
	Name = "BodyMeshController",
	-- After MuscleController (40) has sized the real body, so the fit is measured
	-- against the body as the player actually sees it.
	Priority = 43,
}

local FOLDER_NAME = "GeneratedBody"

type Dressed = {
	-- The stock parts to keep invisible, refreshed every frame.
	hidden: { BasePart },
	parts: { MeshPart },
}

local dressed: { [Model]: Dressed } = {}

--[[
	Fits the cut body onto one character.

	Every piece keeps the coordinates it had inside the uncut sculpt, so the whole
	body reassembles when all fourteen parts share one CFrame. That shared frame is
	the character's own bounding box centre, and the scale is whatever makes the
	sculpt as tall as the character. Each piece is then welded to the R15 part it
	covers, capturing the offset while the character stands in its rest pose — so
	once the animation starts moving joints, each piece rides its own limb.
]]
local function dress(character: Model): boolean
	local template = BodyMeshBuilder.Build()
	if template == nil then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	local existing = character:FindFirstChild(FOLDER_NAME)
	if existing ~= nil then
		existing:Destroy()
	end

	local _, characterSize = character:GetBoundingBox()

	--[[
		Fit the sculpt to the character from the feet to the neck, not over the whole
		bounding box. The cut discards the sculpt's head because the game keeps the
		stock R15 one, so matching total heights would squash the body by exactly the
		height of the head it no longer has.
	]]
	local head = character:FindFirstChild("Head")
	local headHeight = if head ~= nil and head:IsA("BasePart") then head.Size.Y else 0
	local sourceBodyHeight = BodyMeshConfig.NECK - BodyMeshConfig.SOURCE_MIN_Y
	local scale = (characterSize.Y - headHeight) / sourceBodyHeight

	--[[
		Reshape the rig to the sculpt before fitting anything to it.

		The two disagree sharply about what a body is shaped like. Measured, the
		sculpt is torso 2.98 to legs 2.18; stock R15 is torso 2.0 to legs 2.71 — a
		realistic figure against a stylised one, with the ratio inverted. Fitting the
		sculpt onto the stock rig leaves the mesh arms sitting almost a stud inboard
		of the rig's arms, and no amount of scaling fixes that because the error is
		in the proportions, not the size. Stretching each piece onto its stock limb
		instead squashes the sculpt back into a box and throws away the definition
		that made it worth generating.

		So the rig gives, not the mesh. Each R15 part is told what size it should
		consider its own, taken from the piece of sculpt that covers it, and
		`MuscleController` grows it from there. The rig stays a rig — same joints,
		same animations, same parts — it just has the sculpt's build.

		Nothing here is authoritative: these are the client's cosmetic sizes, which
		is already how `MuscleController` works. Server hitboxes are untouched.
	]]
	for _, partName in BodyMeshConfig.PART_NAMES do
		local source = template:FindFirstChild(partName)
		local limb = character:FindFirstChild(partName)
		if source ~= nil and source:IsA("MeshPart") and limb ~= nil and limb:IsA("BasePart") then
			local wanted = source.Size * scale
			local stock = limb.Size
			limb:SetAttribute(
				"RigProportion",
				Vector3.new(wanted.X / stock.X, wanted.Y / stock.Y, wanted.Z / stock.Z)
			)
		end
	end

	--[[
		Tell every joint where the sculpt puts it.

		Reshaping the parts is only half of it. A Motor6D's offset decides where a
		limb actually hangs, and `MuscleController` can only re-seat it by scaling
		R15's own offset — which keeps the arms proportionally where R15 hung them,
		about eight tenths of a stud outboard of where the sculpt carries them. No
		amount of resizing closes that, because it is a placement error.

		Each offset is simply the gap between the two pieces' centres inside the
		uncut body, scaled onto the character. C1 is left at identity so the whole
		offset lives on C0, which keeps the arithmetic here reversible by eye.

		The neck and the root are skipped deliberately: their parts (Head and
		HumanoidRootPart) have no sculpt piece, so they keep R15's offsets and the
		body continues to hang off the root exactly as before.
	]]
	local function offsetOf(partName: string): Vector3?
		local source = template:FindFirstChild(partName)
		if source == nil or not source:IsA("MeshPart") then
			return nil
		end
		local offset = source:GetAttribute("BodyOffset")
		return if typeof(offset) == "Vector3" then offset else nil
	end

	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("Motor6D") then
			continue
		end
		local part0, part1 = descendant.Part0, descendant.Part1
		if part0 == nil or part1 == nil then
			continue
		end
		local parentOffset = offsetOf(part0.Name)
		local childOffset = offsetOf(part1.Name)
		if parentOffset == nil or childOffset == nil then
			continue
		end
		descendant:SetAttribute("RigBaseC0", CFrame.new((childOffset - parentOffset) * scale))
		descendant:SetAttribute("RigBaseC1", CFrame.identity)
	end

	--[[
		Let the rig finish changing shape before measuring it.

		`MuscleController` eases parts toward their target rather than snapping, and
		re-seats the joints as it goes, so the limbs are still moving for a moment
		after the proportions are set. Every weld below captures where a limb *is*,
		so measuring mid-ease welds the body to a pose the rig is about to leave.
	]]
	local deadline = os.clock() + 2
	local settledFor = 0
	local previous: { [BasePart]: Vector3? } = {}
	repeat
		task.wait(0.05)
		local moved = false
		for _, partName in BodyMeshConfig.PART_NAMES do
			local limb = character:FindFirstChild(partName)
			if limb ~= nil and limb:IsA("BasePart") then
				local was = previous[limb]
				if was == nil or (limb.Size - was).Magnitude > 0.001 then
					moved = true
				end
				previous[limb] = limb.Size
			end
		end
		settledFor = if moved then 0 else settledFor + 0.05
	until settledFor >= 0.2 or os.clock() > deadline or character.Parent == nil

	if character.Parent == nil then
		return false
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local hidden: { BasePart } = {}
	local parts: { MeshPart } = {}

	for _, partName in BodyMeshConfig.PART_NAMES do
		local source = template:FindFirstChild(partName)
		local limb = character:FindFirstChild(partName)
		if source == nil or not source:IsA("MeshPart") then
			continue
		end
		if limb == nil or not limb:IsA("BasePart") then
			continue
		end

		--[[
			Straight onto the limb, with nothing to line up.

			Once the joints carry the sculpt's own offsets, each R15 part sits exactly
			where that piece of sculpt sits, and both are centred on the same point.
			So the piece simply *is* the limb: same frame, identity weld. This used to
			be a measured offset against a whole-body fit, which is precisely the thing
			that left the arms astray.
		]]
		local piece = source:Clone()
		-- The stored template is anchored so it sits still in the place file; a
		-- piece welded to a moving limb must not be.
		piece.Anchored = false
		piece.CanCollide = false
		piece.CanQuery = false
		piece.CanTouch = false
		piece.Massless = true
		piece.Size = source.Size * scale
		piece.CFrame = limb.CFrame
		piece.Color = limb.Color
		piece.Parent = folder

		local weld = Instance.new("Weld")
		weld.Name = "BodyMeshWeld"
		weld.Part0 = limb
		weld.Part1 = piece
		weld.C0 = CFrame.identity
		weld.C1 = CFrame.identity
		weld.Parent = piece

		table.insert(parts, piece)
		table.insert(hidden, limb)
	end

	if #parts == 0 then
		folder:Destroy()
		return false
	end

	folder.Parent = character
	dressed[character] = { hidden = hidden, parts = parts }
	return true
end

local function undress(character: Model)
	local entry = dressed[character]
	if entry ~= nil then
		for _, part in entry.hidden do
			if part.Parent ~= nil then
				part.LocalTransparencyModifier = 0
			end
		end
	end
	dressed[character] = nil
	local folder = character:FindFirstChild(FOLDER_NAME)
	if folder ~= nil then
		folder:Destroy()
	end
end

local function watch(player: Player)
	local function onCharacter(character: Model)
		-- The rig arrives a part at a time; wait for the humanoid to have assembled
		-- it or the bounding box measures a half-built body.
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid == nil then
			return
		end
		task.wait(0.25)
		if character.Parent == nil then
			return
		end
		if not dress(character) then
			warn(`BodyMeshController: could not dress {player.Name}`)
		end
	end

	if player.Character ~= nil then
		task.spawn(onCharacter, player.Character :: Model)
	end
	player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacter, character)
	end)
	player.CharacterRemoving:Connect(undress)
end

function BodyMeshController:Start()
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player: Player)
		if player.Character ~= nil then
			undress(player.Character)
		end
	end)

	-- Reasserted every frame: see the note at the top of the file.
	RunService.RenderStepped:Connect(function()
		for character, entry in dressed do
			if character.Parent == nil then
				dressed[character] = nil
				continue
			end
			for _, part in entry.hidden do
				part.LocalTransparencyModifier = 1
			end
		end
	end)
end

return BodyMeshController
