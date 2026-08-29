--!strict
--[[
	MuscleDefinitionController — sculpts readable anatomy onto the scaled R15 body.

	MuscleController owns the safe silhouette of the *rig*. This controller replaces
	what that rig looks like, in three layers that MuscleDefinitionConfig keeps
	separate on purpose:

	  Shells   overlapping segments that make a limb one continuous tapered mass
	           instead of a stack of blocks. The stock part stays underneath as the
	           real rig and hitbox, faded out locally.
	  Features muscle bellies, buried under the shell surface up to their `Emerge`
	           fraction. They read as a tonal step and a soft edge, never a lump.
	  Lines    ab separations, linea alba, the pec split — very flat slivers buried
	           almost entirely in the shell, which is how the reference art actually
	           gets definition onto a smooth body.

	Nothing here authors a burial depth. A feature says which shell covers it and which
	face it is on, and this file derives where its centre must go from the shell's live
	girth. That is the whole reason the previous version's bellies stuck half out of the
	body: they were positioned at a fixed fraction of the *rig* part, which the shells
	had since grown past.

	All parts are local, massless, non-collidable primitives. They affect neither combat
	nor replication and disappear immediately when a transformation resets progress.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MuscleDefinitionConfig = require(ReplicatedStorage.Modules.MuscleDefinitionConfig)

local MuscleDefinitionController = {
	Name = "MuscleDefinitionController",
	-- After MuscleController has moved the real body and after veins have read it.
	Priority = 42,
}

local PROGRESS_FOLDER_NAME = "MuscleProgress"
local DEFINITION_FOLDER_NAME = MuscleDefinitionConfig.DEFINITION_FOLDER_NAME
-- The generated body, when it is available, replaces this whole layer. Both systems
-- write LocalTransparencyModifier on the same rig parts, so whichever one owns the
-- body has to own it alone; otherwise the shells float over an invisible rig.
--
-- This layer is now the FALLBACK rather than the default. BodyLoftController dresses
-- a character in one skinned mesh when it can, and cannot when the client has run out
-- of EditableMesh instances — a real condition on a busy server, not a bug — at which
-- point these primitives are what the player sees.
-- Set by BodyLoftController only once its body has survived a frame. Keying off the
-- part's mere existence is what let a built-but-invisible body silence this fallback
-- and leave the player as a floating head.
local LOFT_ACTIVE_ATTRIBUTE = "BodyLoftActive"
local SCULPT_FOLDER_NAME = "GeneratedBody"
local REFRESH_SECONDS = 0.1
local REFIT_EPSILON = 0.005
-- Where the game's skin and shorts colours can be read off the live character.
-- AppearanceService paints these through BodyColors, so the rig is the source of
-- truth and no second copy of the palette is needed here.
local SLOT_SOURCE: { [string]: string } = { Skin = "UpperTorso", Pants = "LeftUpperLeg" }

type Entry = {
	part: Part,
	weld: Weld,
	feature: any,
	fittedTo: Vector3,
	fittedStrength: number,
}

local entries: { [Model]: { [string]: Entry } } = {}
local shellEntries: { [Model]: { [string]: Entry } } = {}
local lineEntries: { [Model]: { [string]: Entry } } = {}
local fadedParts: { [Model]: { [BasePart]: boolean } } = {}

local function vector(spec: MuscleDefinitionConfig.VectorSpec): Vector3
	return Vector3.new(spec.X, spec.Y, spec.Z)
end

local function definitionFolder(character: Model): Folder
	local existing = character:FindFirstChild(DEFINITION_FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = DEFINITION_FOLDER_NAME
	folder.Parent = character
	return folder
end

local function shade(color: Color3, amount: number): Color3
	if amount >= 0 then
		return color:Lerp(Color3.new(0, 0, 0), math.clamp(amount, 0, 0.65))
	end
	return color:Lerp(Color3.new(1, 1, 1), math.clamp(-amount, 0, 0.35))
end

local function partSize(character: Model, name: string, fallback: Vector3): Vector3
	local part = character:FindFirstChild(name)
	if part ~= nil and part:IsA("BasePart") then
		return part.Size
	end
	return fallback
end

local function slotColor(character: Model, slot: string, fallback: Color3): Color3
	local source = SLOT_SOURCE[slot]
	if source ~= nil then
		local part = character:FindFirstChild(source)
		if part ~= nil and part:IsA("BasePart") then
			return part.Color
		end
	end
	return fallback
end

local function fitShell(entry: Entry, limb: BasePart, girth: Vector3)
	local shell = entry.feature
	local limbSize = limb.Size
	entry.part.Size = Vector3.new(
		math.max(0.04, girth.X * shell.Width),
		math.max(0.04, limbSize.Y * shell.Length),
		math.max(0.04, girth.Z * shell.Depth)
	)
	entry.weld.C0 = CFrame.new(0, limbSize.Y * shell.OffsetY, 0)
	entry.fittedTo = limbSize
end

--[[
	Places a belly against the surface of the shell covering it.

	`Offset` supplies only the two tangential coordinates; the third is derived, so
	"how far out does this stick" is not a number anyone can typo. Sizes are measured
	against the shell's girth reference rather than the belly's own parent, for the
	same reason the shells are: an upper and a lower arm grow at different rates, and
	a bicep sized against the wrong one drifts off the surface as the player trains.
]]
local function fitFeature(entry: Entry, limb: BasePart, girth: Vector3, cover: any, strength: number)
	local feature = entry.feature
	local limbSize = limb.Size
	local emergence = 0.55 + 0.45 * strength
	local size = Vector3.new(
		math.max(0.04, girth.X * feature.Size.X * emergence),
		math.max(0.04, limbSize.Y * feature.Size.Y * emergence),
		math.max(0.04, girth.Z * feature.Size.Z * emergence)
	)
	entry.part.Size = size

	local tangent = vector(feature.Offset) * Vector3.new(girth.X, limbSize.Y, girth.Z)
	local x, y, z = tangent.X, tangent.Y, tangent.Z
	local face = feature.Face
	if face == "Front" or face == "Back" then
		local sign = if face == "Front" then -1 else 1
		z = sign * MuscleDefinitionConfig.BurialOffset(girth.Z * cover.Depth * 0.5, size.Z, feature.Emerge)
	elseif face == "Outward" then
		local sign = if feature.Side == "Left" then -1 else 1
		x = sign * MuscleDefinitionConfig.BurialOffset(girth.X * cover.Width * 0.5, size.X, feature.Emerge)
	else
		local top = limbSize.Y * (cover.OffsetY + cover.Length * 0.5)
		y = MuscleDefinitionConfig.BurialOffset(top, size.Y, feature.Emerge)
	end

	local rotation = feature.Rotation
	entry.weld.C0 = CFrame.new(x, y, z)
		* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
	entry.fittedTo = limbSize
	entry.fittedStrength = strength
end

local function build(character: Model, feature: any, limb: BasePart, statId: string?): Entry
	local part = Instance.new("Part")
	part.Name = feature.Id
	-- Every contour is a Ball unless it is explicitly a Block. Cylinder is gone on
	-- purpose: its axis runs left-right, which is what turned the abs and pecs into a
	-- row of horizontal pipes across the chest.
	part.Shape = if feature.Shape == "Block" then Enum.PartType.Block else Enum.PartType.Ball
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.Massless = true
	part.Material = Enum.Material.SmoothPlastic
	if statId ~= nil then
		part:SetAttribute(MuscleDefinitionConfig.FEATURE_STAT_ATTRIBUTE, statId)
	end
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.CFrame = limb.CFrame
	part.Parent = definitionFolder(character)

	local weld = Instance.new("Weld")
	weld.Name = "DefinitionWeld"
	weld.Part0 = limb
	weld.Part1 = part
	weld.C1 = CFrame.identity
	weld.Parent = part

	return {
		part = part,
		weld = weld,
		feature = feature,
		fittedTo = Vector3.zero,
		fittedStrength = -1,
	}
end

--[[
	Places a crease against the shell surface. Same burial rule as a belly, with the
	emergence turned right down, so a line follows the curve of a rounded torso instead
	of cutting across it the way a flat SurfaceGui would.
]]
local function fitLine(entry: Entry, limb: BasePart, girth: Vector3, cover: any, strength: number)
	local line = entry.feature
	local limbSize = limb.Size
	local size = Vector3.new(
		math.max(0.02, girth.X * line.Width),
		math.max(0.02, limbSize.Y * line.Height * strength),
		math.max(0.02, girth.Z * line.Depth)
	)
	entry.part.Size = size

	local z = -MuscleDefinitionConfig.BurialOffset(girth.Z * cover.Depth * 0.5, size.Z, line.Emerge)
	entry.weld.C0 = CFrame.new(girth.X * line.X, limbSize.Y * line.Y, z)
		* CFrame.Angles(0, 0, math.rad(line.Rotation))
	entry.fittedTo = limbSize
	entry.fittedStrength = strength
end

local function restorePart(character: Model, part: BasePart)
	part.LocalTransparencyModifier = 0
	local characterParts = fadedParts[character]
	if characterParts ~= nil then
		characterParts[part] = nil
	end
end

local function remove(character: Model, id: string)
	local characterEntries = entries[character]
	if characterEntries == nil then
		return
	end
	local entry = characterEntries[id]
	if entry ~= nil then
		entry.part:Destroy()
		characterEntries[id] = nil
	end
end

local function clear(character: Model)
	local characterEntries = entries[character]
	if characterEntries ~= nil then
		for _, entry in characterEntries do
			entry.part:Destroy()
		end
	end
	entries[character] = nil
	local characterShells = shellEntries[character]
	if characterShells ~= nil then
		for _, entry in characterShells do
			entry.part:Destroy()
		end
	end
	shellEntries[character] = nil
	local characterLines = lineEntries[character]
	if characterLines ~= nil then
		for _, entry in characterLines do
			entry.part:Destroy()
		end
	end
	lineEntries[character] = nil
	local characterParts = fadedParts[character]
	if characterParts ~= nil then
		for part in characterParts do
			if part.Parent ~= nil then
				part.LocalTransparencyModifier = 0
			end
		end
	end
	fadedParts[character] = nil
	local folder = character:FindFirstChild(DEFINITION_FOLDER_NAME)
	if folder ~= nil then
		folder:Destroy()
	end
end

local function removeShell(character: Model, id: string, hidePartName: string)
	local characterShells = shellEntries[character]
	if characterShells ~= nil then
		local entry = characterShells[id]
		if entry ~= nil then
			entry.part:Destroy()
			characterShells[id] = nil
		end
	end
	local hidden = character:FindFirstChild(hidePartName)
	if hidden ~= nil and hidden:IsA("BasePart") then
		restorePart(character, hidden)
	end
end

local function refresh(character: Model)
	local progressFolder = character:FindFirstChild(PROGRESS_FOLDER_NAME)
	if progressFolder == nil or not progressFolder:IsA("Folder") then
		clear(character)
		return
	end
	if
		character:FindFirstChild(SCULPT_FOLDER_NAME) ~= nil
		or character:GetAttribute(LOFT_ACTIVE_ATTRIBUTE) == true
	then
		clear(character)
		return
	end

	local characterEntries = entries[character]
	if characterEntries == nil then
		characterEntries = {}
		entries[character] = characterEntries
	end
	local characterShells = shellEntries[character]
	if characterShells == nil then
		characterShells = {}
		shellEntries[character] = characterShells
	end
	local characterLines = lineEntries[character]
	if characterLines == nil then
		characterLines = {}
		lineEntries[character] = characterLines
	end
	local characterParts = fadedParts[character]
	if characterParts == nil then
		characterParts = {}
		fadedParts[character] = characterParts
	end

	local progressByStat: { [string]: number } = {}
	for _, value in progressFolder:GetChildren() do
		if value:IsA("NumberValue") then
			progressByStat[value.Name] = value.Value
		end
	end

	-- Replace the visible R15 blocks with the configured tapered torso and continuous
	-- limb masses before laying individual muscle bellies over them. The stock parts
	-- remain underneath as the real rig.
	for _, shell in MuscleDefinitionConfig.Shells do
		local strength = MuscleDefinitionConfig.ShellStrength(shell, progressByStat)
		if strength <= 0 then
			removeShell(character, shell.Id, shell.HidePart)
			continue
		end

		local limb = character:FindFirstChild(shell.Part)
		local hidden = character:FindFirstChild(shell.HidePart)
		if limb == nil or not limb:IsA("BasePart") or hidden == nil or not hidden:IsA("BasePart") then
			removeShell(character, shell.Id, shell.HidePart)
			continue
		end

		local entry = characterShells[shell.Id]
		if entry == nil then
			entry = build(character, shell, limb, nil)
			entry.part:SetAttribute(
				MuscleDefinitionConfig.SHELL_STATS_ATTRIBUTE,
				table.concat(shell.StatIds, ",")
			)
			characterShells[shell.Id] = entry
		end
		entry.part.Color = shade(slotColor(character, shell.ClothingSlot, limb.Color), shell.Shade)
		entry.part.Transparency = 1 - strength
		hidden.LocalTransparencyModifier = strength
		characterParts[hidden] = true
		if (limb.Size - entry.fittedTo).Magnitude > REFIT_EPSILON then
			fitShell(entry, limb, partSize(character, shell.GirthPart, limb.Size))
		end
	end

	for _, feature in MuscleDefinitionConfig.List do
		local progress = progressByStat[feature.StatId] or 0
		local strength = MuscleDefinitionConfig.Strength(feature, progress)

		if strength <= 0 then
			remove(character, feature.Id)
			continue
		end

		local limb = character:FindFirstChild(feature.Part)
		local cover = MuscleDefinitionConfig.ShellsById[feature.CoverShell]
		if limb == nil or not limb:IsA("BasePart") or cover == nil then
			remove(character, feature.Id)
			continue
		end

		local entry = characterEntries[feature.Id]
		if entry == nil then
			entry = build(character, feature, limb, feature.StatId)
			characterEntries[feature.Id] = entry
		end

		entry.part.Color = shade(slotColor(character, cover.ClothingSlot, limb.Color), feature.Shade)
		entry.part.Transparency = 1 - 0.92 * strength
		if
			(limb.Size - entry.fittedTo).Magnitude > REFIT_EPSILON
			or math.abs(strength - entry.fittedStrength) > 0.01
		then
			fitFeature(entry, limb, partSize(character, cover.GirthPart, limb.Size), cover, strength)
		end
	end

	for _, line in MuscleDefinitionConfig.Lines do
		local strength = MuscleDefinitionConfig.LineStrength(line, progressByStat[line.StatId] or 0)
		local limb = character:FindFirstChild(line.Part)
		local cover = MuscleDefinitionConfig.ShellsById[line.Shell]
		local host = characterShells[line.Shell]
		local entry = characterLines[line.Id]
		-- A crease is only ever a shadow on a shell, so it comes and goes with one.
		if strength <= 0 or host == nil or cover == nil or limb == nil or not limb:IsA("BasePart") then
			if entry ~= nil then
				entry.part:Destroy()
				characterLines[line.Id] = nil
			end
			continue
		end
		if entry == nil then
			entry = build(character, line, limb, line.StatId)
			characterLines[line.Id] = entry
		end
		entry.part.Color = shade(host.part.Color, line.Shade)
		entry.part.Transparency = 1 - line.Opacity * strength * (1 - host.part.Transparency)
		if
			(limb.Size - entry.fittedTo).Magnitude > REFIT_EPSILON
			or math.abs(strength - entry.fittedStrength) > 0.01
		then
			fitLine(entry, limb, partSize(character, cover.GirthPart, limb.Size), cover, strength)
		end
	end
end

function MuscleDefinitionController:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		if player.Character ~= nil then
			clear(player.Character)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				if character ~= nil and character.Parent ~= nil then
					refresh(character)
				end
			end
			for character in entries do
				if character.Parent == nil then
					entries[character] = nil
					shellEntries[character] = nil
					lineEntries[character] = nil
					fadedParts[character] = nil
				end
			end
		end
	end)
end

return MuscleDefinitionController
