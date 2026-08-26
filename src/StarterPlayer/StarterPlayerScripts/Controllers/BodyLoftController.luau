--!strict
--[[
	BodyLoftController — dresses characters in the generated skinned body.

	The body is one skinned MeshPart built by `BodyLoftBuilder`, driven by Bone
	instances that follow the stock R15 rig. The rig itself is untouched and stays
	underneath as the real joints, hitboxes and reach; it is only made invisible.
	Combat, training and animation all keep talking to the same parts they always did.

	Why bones rather than a mesh per limb: a Play client permits only seven or eight
	EditableMesh instances at once, so one mesh per body is the only shape that fits.
	The happy consequence is that there are no joint seams to hide, because there are
	no joints in the geometry — one surface bends across the elbow.

	This controller stands down completely if anything goes wrong, leaving
	`MuscleDefinitionController`'s primitive body in place. That fallback is not
	decoration: `CreateEditableMesh` returns nil rather than erroring when the cap is
	reached, and on a busy server some clients will hit it.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BodyLoftBuilder = require(ReplicatedStorage.Modules.BodyLoftBuilder)
local BodyLoftConfig = require(ReplicatedStorage.Modules.BodyLoftConfig)

local BodyLoftController = {
	Name = "BodyLoftController",
	-- After MuscleController (40) has moved the real rig this frame.
	Priority = 41,
}

local PROGRESS_FOLDER_NAME = "MuscleProgress"
-- Per-part growth, published by MuscleService alongside progress. The mesh follows
-- it so the visible body matches its own hitboxes; without it the mesh sat at base
-- proportions while the rig underneath grew.
local SCALES_FOLDER_NAME = "MuscleScales"
--[[
	The flag MuscleDefinitionController stands down on.

	It is deliberately NOT "a part named Body exists". That was the earlier gate, and
	it disarmed the fallback in exactly the case the fallback exists for: a body that
	was built but never rendered silenced the primitive shells, and the player stood
	there as a floating head with the rig hidden behind nothing. The attribute is set
	only once the body has survived a frame, and cleared the moment it has not.
]]
local ACTIVE_ATTRIBUTE = "BodyLoftActive"
--[[
	How much larger than the loft's bind pose a rig is, read off the model.

	BodyLoftConfig.BONES is an absolute bind pose in studs — shoulders at x +/- 1.5 —
	and `follow` hands each bone the difference between where its limb is now and where
	that bind says it should be. A rig built at another scale therefore hands every bone
	a large constant translation, and the body arrives in pieces: arms floating off the
	shoulders, the head adrift. Bosses are built at 2.1.

	The fix is to render the mesh at the rig's scale and then express the bone deltas in
	that scaled space, which is what `rigScale` is for. A player has no attribute and
	scale 1, so nothing about the player path changes.
]]
local SCALE_ATTRIBUTE = "LoftScale"

--[[
	How cut this body is. A player has no attribute and gets the default, so nothing
	about the player path changes; MobService sets it on bosses.
]]
local function leannessOf(character: Model): number
	return BodyLoftConfig.Leanness(tonumber(character:GetAttribute(BodyLoftConfig.LEANNESS_ATTRIBUTE)))
end

local function rigScaleOf(character: Model): number
	local scale = tonumber(character:GetAttribute(SCALE_ATTRIBUTE))
	if scale == nil or scale <= 0 then
		return 1
	end
	return scale
end
-- Growth is continuous but rebuilding is not free, so progress is rounded to steps.
-- Twenty-four is fine enough that a step is invisible and coarse enough that a long
-- training session rebuilds a couple of dozen times, not every frame.
local PROGRESS_STEPS = 24

type Dressed = {
	part: MeshPart,
	mesh: EditableMesh,
	bones: { [string]: Bone },
	-- Bind CFrame of each bone relative to the root, inverted once at dress time.
	bindInverse: { [string]: CFrame },
	steps: { [string]: number },
	scaleSteps: { [string]: number },
	-- What the body was painted with. Compared each tick so that changing skin or
	-- shorts in the creator repaints it: the colours are baked into the mesh as
	-- vertex colours, so there is nothing to tint afterwards, only a rebuild.
	palette: BodyLoftBuilder.Palette,
	detail: string,
	-- How much bigger this rig is than the loft's bind pose. 1 for a player.
	rigScale: number,
	-- Baked into the mesh and the texture, so a change has to rebuild both.
	leanness: number,
	hidden: { BasePart },
	-- Set once the body has survived a frame. Until then the rig stays visible.
	proven: boolean,
}

local dressed: { [Model]: Dressed } = {}
local building: { [Model]: boolean } = {}

local function quantise(value: number): number
	return math.floor(math.clamp(value, 0, 1) * PROGRESS_STEPS + 0.5)
end

local function numbersIn(character: Model, folderName: string): { [string]: number }?
	local folder = character:FindFirstChild(folderName)
	if folder == nil or not folder:IsA("Folder") then
		return nil
	end
	local out: { [string]: number } = {}
	for _, value in folder:GetChildren() do
		if value:IsA("NumberValue") then
			out[value.Name] = value.Value
		end
	end
	return out
end

local function progressOf(character: Model): { [string]: number }?
	local folder = character:FindFirstChild(PROGRESS_FOLDER_NAME)
	if folder == nil or not folder:IsA("Folder") then
		return nil
	end
	local out: { [string]: number } = {}
	for _, value in folder:GetChildren() do
		if value:IsA("NumberValue") then
			out[value.Name] = value.Value
		end
	end
	return out
end

--[[
	Skin and shorts come off the live rig rather than from a config, because
	AppearanceService already paints them there through BodyColors — UpperTorso is
	skin, UpperLeg is the shorts. Reading the rig means a player changing their
	appearance needs no notification path to reach this file.
]]
local function paletteOf(character: Model): BodyLoftBuilder.Palette
	local skin = Color3.fromRGB(234, 219, 200)
	local pants = Color3.fromRGB(40, 44, 56)
	local torso = character:FindFirstChild("UpperTorso")
	if torso ~= nil and torso:IsA("BasePart") then
		skin = torso.Color
	end
	local leg = character:FindFirstChild("LeftUpperLeg")
	if leg ~= nil and leg:IsA("BasePart") then
		pants = leg.Color
	end
	return { Skin = skin, Pants = pants }
end

local function detailFor(character: Model): string?
	local camera = workspace.CurrentCamera
	local root = character:FindFirstChild("HumanoidRootPart")
	if camera == nil or root == nil or not root:IsA("BasePart") then
		return nil
	end
	local distance = (camera.CFrame.Position - root.Position).Magnitude
	if distance <= BodyLoftConfig.DETAIL.Near.MaxDistance then
		return "Near"
	elseif distance <= BodyLoftConfig.DETAIL.Mid.MaxDistance then
		return "Mid"
	end
	-- Far away the stock rig is indistinguishable and costs nothing.
	return nil
end

local function undress(character: Model)
	local entry = dressed[character]
	if entry == nil then
		return
	end
	dressed[character] = nil
	character:SetAttribute(ACTIVE_ATTRIBUTE, nil)
	-- Show the rig again before anything else can fail. Whatever went wrong, the
	-- player having a body is not negotiable.
	for _, part in entry.hidden do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = 0
		end
	end
	entry.part:Destroy()
	-- Only after the part is gone: the part renders nothing without its mesh.
	entry.mesh:Destroy()
end

local function dress(
	character: Model,
	progress: { [string]: number },
	scales: { [string]: number },
	detailName: string
): boolean
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local detail = (BodyLoftConfig.DETAIL :: any)[detailName]
	local palette = paletteOf(character)
	local leanness = leannessOf(character)
	local built = BodyLoftBuilder.Build(progress, detail, palette, scales, leanness)
	if built == nil then
		return false
	end

	local rigScale = rigScaleOf(character)

	local bones: { [string]: Bone } = {}
	local bindInverse: { [string]: CFrame } = {}
	local rootBone: Bone? = nil
	for _, definition in BodyLoftConfig.BONES do
		local bone = Instance.new("Bone")
		bone.Name = definition.Name
		--[[
			The Bone itself stays at the unscaled bind, because that is the pose the
			mesh's skin weights were baked against — move it and every vertex is
			displaced before a single frame runs.

			`bindInverse` is a different question. It is measured against the *rig*,
			whose limbs rest at `rigScale` times these coordinates, so it has to be
			scaled or the delta is not zero when the boss is standing still. That
			non-zero rest pose is what folded the first attempt into a lump.
		]]
		bone.CFrame = CFrame.new(definition.X, definition.Y, definition.Z)
		bones[definition.Name] = bone
		bindInverse[definition.Name] =
			CFrame.new(definition.X * rigScale, definition.Y * rigScale, definition.Z * rigScale):Inverse()
		if definition.Name == "Root" then
			rootBone = bone
		end
	end
	for _, definition in BodyLoftConfig.BONES do
		bones[definition.Name].Parent = if definition.Name == "Root" then built.Part else rootBone
	end

	--[[
		Work out what to hide BEFORE the body joins the character.

		Collected afterwards, the loop below sweeps up the generated body itself — it
		is a BasePart, it is not the head, it is not the root — so the body dutifully
		set its own LocalTransparencyModifier to 1 every frame and hid the thing it
		had just built. Everything else reported success, which made it look like a
		rendering failure for a long time.
	]]
	local hidden: { BasePart } = {}
	for _, descendant in character:GetChildren() do
		-- The head keeps its stock part: it carries the face, the hair and the
		-- nameplate, and nothing here generates one.
		if descendant:IsA("BasePart") and descendant.Name ~= "Head" and descendant ~= root then
			table.insert(hidden, descendant)
		end
	end

	if rigScale ~= 1 then
		-- Scales the geometry and the bone space with it, so the skeleton keeps
		-- lining up with the mesh it drives.
		built.Part.Size *= rigScale
	end

	built.Part.CFrame = root.CFrame
	built.Part.Parent = character

	--[[
		The body is welded to the root rather than CFramed into place each frame.

		That is not an optimisation. An unanchored, unwelded BasePart parented into a
		character is culled within a second or two — replication removes it — so a
		CFrame-chased body silently disappears while every line of code that built it
		reports success. Welding also means the body moves with the character in the
		same physics step instead of trailing it by a frame.
	]]
	local weld = Instance.new("Weld")
	weld.Name = "BodyLoftWeld"
	weld.Part0 = root
	weld.Part1 = built.Part
	weld.C0 = CFrame.identity
	weld.C1 = CFrame.identity
	weld.Parent = built.Part

	local steps: { [string]: number } = {}
	for statId, value in progress do
		steps[statId] = quantise(value)
	end
	-- Scale runs 1..2.2, so it is quantised against that span rather than 0..1.
	local scaleSteps: { [string]: number } = {}
	for partName, value in scales do
		scaleSteps[partName] = math.floor((value - 1) / 1.2 * PROGRESS_STEPS + 0.5)
	end

	dressed[character] = {
		part = built.Part,
		mesh = built.Mesh,
		bones = bones,
		bindInverse = bindInverse,
		steps = steps,
		scaleSteps = scaleSteps,
		palette = palette,
		detail = detailName,
		rigScale = rigScale,
		leanness = leanness,
		hidden = hidden,
		proven = false,
	}
	return true
end

--[[
	Drives the skeleton from the rig, every frame.

	Because the hierarchy is flat, a bone's transform is simply the difference between
	where its R15 part is now and where the bind pose said it would be, both measured
	against the root. Nothing accumulates, so a bad value on one limb cannot drag the
	rest of the body with it.
]]
local function follow(character: Model, entry: Dressed)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	-- The body can be taken away underneath us — replication culls a part that is
	-- not welded, and a respawn takes the whole character. Neither is an error worth
	-- logging, but both must put the rig back rather than leave it hidden.
	if entry.part.Parent == nil then
		undress(character)
		return
	end
	-- The weld keeps the part on the root; only the skeleton needs driving here.
	local inverseRoot = root.CFrame:Inverse()
	for _, definition in BodyLoftConfig.BONES do
		local bone = entry.bones[definition.Name]
		if not bone or definition.Name == "Root" then
			continue
		end
		local limb = character:FindFirstChild(definition.Part)
		if limb ~= nil and limb:IsA("BasePart") then
			local delta = entry.bindInverse[definition.Name] * (inverseRoot * limb.CFrame)
			if entry.rigScale ~= 1 then
				-- The limb offsets are world studs on a rig that is `rigScale` times
				-- the bind, but bone space is scaled by the part, so a stud here is
				-- already `rigScale` studs on screen. Divide, or every joint travels
				-- that much too far and the body comes apart.
				local x, y, z = delta.Position.X, delta.Position.Y, delta.Position.Z
				delta = CFrame.new(x / entry.rigScale, y / entry.rigScale, z / entry.rigScale)
					* (delta - delta.Position)
			end
			bone.Transform = delta
		end
	end
	-- One frame's grace before the rig is hidden. The body has now been parented and
	-- welded for a whole frame without being culled, which is the only evidence
	-- available on the client that it is really there.
	if not entry.proven then
		entry.proven = true
		character:SetAttribute(ACTIVE_ATTRIBUTE, true)
		return
	end
	for _, part in entry.hidden do
		-- The identity guard is not redundant with collecting the list before the
		-- body is parented: it is the thing that stops this class of bug returning if
		-- anyone reorders dress() later.
		if part.Parent ~= nil and part ~= entry.part then
			-- Every frame, not on a poll. A 0.1s poll is what left the bare R15 torso
			-- showing through the old muscle shells.
			part.LocalTransparencyModifier = 1
		end
	end
end

local function refresh(character: Model)
	if building[character] then
		return
	end
	local progress = progressOf(character)
	local scales = numbersIn(character, SCALES_FOLDER_NAME)
	local wanted = if progress == nil or scales == nil then nil else detailFor(character)
	local entry = dressed[character]

	if progress == nil or scales == nil or wanted == nil then
		if entry ~= nil then
			undress(character)
		end
		return
	end

	if entry ~= nil then
		local palette = paletteOf(character)
		local stale = entry.detail ~= wanted
			or palette.Skin ~= entry.palette.Skin
			or palette.Pants ~= entry.palette.Pants
			or leannessOf(character) ~= entry.leanness
		if not stale then
			for statId, value in progress do
				if quantise(value) ~= entry.steps[statId] then
					stale = true
					break
				end
			end
		end
		if not stale then
			for partName, value in scales do
				if math.floor((value - 1) / 1.2 * PROGRESS_STEPS + 0.5) ~= entry.scaleSteps[partName] then
					stale = true
					break
				end
			end
		end
		if not stale then
			return
		end
	end

	building[character] = true
	local previous = dressed[character]
	-- Free the old mesh before allocating the new one: the cap is on instances alive
	-- at once, so holding both for even a moment can be the allocation that fails.
	if previous ~= nil then
		undress(character)
	end
	local ok = dress(character, progress, scales, wanted)
	building[character] = nil
	if not ok then
		-- Leave the rig visible; MuscleDefinitionController takes it from here.
		return
	end
end

function BodyLoftController:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		if player.Character ~= nil then
			undress(player.Character)
		end
	end)

	RunService.RenderStepped:Connect(function()
		for character, entry in dressed do
			if character.Parent == nil then
				dressed[character] = nil
			else
				follow(character, entry)
			end
		end
	end)

	--[[
		Everything this controller drives: every player's character, plus any model
		tagged for a loft body. MobService tags bosses.

		A mob needs no special case anywhere below. `dress`, `progressOf`, `paletteOf`
		and `follow` all read a Model and a rig, never a Player, so a boss carrying the
		same MuscleProgress and MuscleScales folders a character carries is dressed by
		the same code — which is why bosses cost this file a list and not a branch.
	]]
	local function driven(): { Model }
		local models: { Model } = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character ~= nil and character.Parent ~= nil then
				table.insert(models, character)
			end
		end
		--[[
			Players first, deliberately.

			`CreateEditableMesh` returns nil once the cap is reached, so whatever is
			refreshed last is what goes without a body. A boss losing its mesh and
			falling back to its own rig is a worse-looking boss; a player losing theirs
			is the player's own body missing, and that is not a trade worth making.
		]]
		for _, model in CollectionService:GetTagged(BodyLoftConfig.MOB_TAG) do
			if model:IsA("Model") and model.Parent ~= nil then
				table.insert(models, model)
			end
		end
		return models
	end

	task.spawn(function()
		while true do
			task.wait(0.15)
			for _, character in driven() do
				if character.Parent ~= nil then
					refresh(character)
					--[[
						Also drive the body from here, not only from RenderStepped.

						RenderStepped does not fire in a client that is not rendering —
						a backgrounded Studio, most obviously. With the skeleton and the
						rig-hiding living only there, the body and the rig were both
						visible at once whenever the window lost focus, and no state
						ever converged. Running the same pass on the slow loop costs
						fifteen bone writes and makes the system behave the same whether
						or not anyone is looking at it.
					]]
					local entry = dressed[character]
					if entry ~= nil then
						follow(character, entry)
					end
				end
			end
			for character, entry in dressed do
				if character.Parent == nil then
					dressed[character] = nil
				elseif entry.part.Parent == nil then
					-- Belt and braces: `follow` catches this first when frames are
					-- running, but RenderStepped does not fire in a backgrounded
					-- client, and a hidden rig must not outlive its replacement.
					undress(character)
				end
			end
		end
	end)
end

return BodyLoftController
