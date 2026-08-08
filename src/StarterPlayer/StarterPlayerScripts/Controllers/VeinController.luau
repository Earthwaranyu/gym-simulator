--!strict
--[[
	VeinController — the detail that turns "big" into "conditioned".

	Size alone reads as inflated. What makes a physique look earned is surface detail,
	and the cheapest honest version of that is vascularity: a few raised cords on the
	arms and chest that are not there on a beginner and are unmissable on someone who
	has trained for hours.

	They are thin cylinders welded to the limb, built from primitives like everything
	else in this project — no uploaded texture, no mesh, no SurfaceAppearance. Layout
	lives in `PhysiqueConfig.VEINS`; adding one is a row there.

	Two things keep this cheap:

	  * **They only exist above a threshold.** A lean character has no vein parts at
	    all, not invisible ones, so the common case costs nothing.
	  * **They are repositioned only when the limb's size actually changes.** Muscle
	    growth is smoothed over seconds and stops entirely between sets, so a per-frame
	    refit would be recomputing the same offsets thousands of times for nothing.

	Purely cosmetic and entirely client-side: nothing here replicates, and a client
	that skips it sees the same body at the same size.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Formulas = require(ReplicatedStorage.Modules.Formulas)
local PhysiqueConfig = require(ReplicatedStorage.Modules.PhysiqueConfig)

local VeinController = {
	Name = "VeinController",
	-- After MuscleController, so a vein is fitted to the size the limb just reached.
	Priority = 41,
}

local FOLDER_NAME = "MuscleScales"
local VEIN_FOLDER = "Veins"
-- Rebuilding on every micro-change would fight the growth smoothing. A limb has to
-- move this fraction of its size before its veins are re-seated.
local REFIT_EPSILON = 0.01
local REFRESH_SECONDS = 0.25

local VEIN_COLOR =
	Color3.fromRGB(PhysiqueConfig.VEIN_COLOR.R, PhysiqueConfig.VEIN_COLOR.G, PhysiqueConfig.VEIN_COLOR.B)

type Entry = {
	part: Part,
	weld: Weld,
	vein: PhysiqueConfig.Vein,
	fittedTo: Vector3,
}

local entries: { [Model]: { Entry } } = {}

local function veinFolder(character: Model): Folder
	local existing = character:FindFirstChild(VEIN_FOLDER)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = VEIN_FOLDER
	folder.Parent = character
	return folder
end

--[[
	The largest scale any of a character's parts has reached.

	One number for the whole body rather than per limb: veins appearing on the arms of
	someone who has only trained legs would be odd, but so would arms that are visibly
	huge and completely smooth. Overall condition is the honest reading.
]]
local function peakScale(character: Model): number
	local folder = character:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		return 1
	end

	local peak = 1
	for _, value in folder:GetChildren() do
		if value:IsA("NumberValue") and value.Value > peak then
			peak = value.Value
		end
	end
	return math.clamp(peak, 1, Formulas.MAX_MUSCLE_SCALE)
end

--[[
	Places one vein against its limb's current size. Offsets are fractions of the part,
	so a vein tracks the surface as the limb thickens instead of sinking into it.
]]
local function fit(entry: Entry, limb: BasePart)
	local vein = entry.vein
	local size = limb.Size

	-- Just proud of the surface. Sitting flush lets z-fighting flicker along its
	-- length, which is far more noticeable than the vein itself.
	local offset = Vector3.new(vein.OffsetX * size.X, vein.OffsetY * size.Y, vein.OffsetZ * size.Z)
	local outward = Vector3.new(math.sign(vein.OffsetX) * 0.02, 0, math.sign(vein.OffsetZ) * 0.02)

	entry.part.Size = Vector3.new(
		math.max(0.05, vein.Thickness * math.min(size.X, size.Z)),
		math.max(0.1, vein.Length * size.Y),
		math.max(0.05, vein.Thickness * math.min(size.X, size.Z))
	)
	entry.weld.C0 = CFrame.new(offset + outward) * CFrame.Angles(0, 0, math.rad(vein.Twist))
	entry.fittedTo = size
end

local function build(character: Model)
	if entries[character] ~= nil then
		return
	end

	local folder = veinFolder(character)
	local built: { Entry } = {}

	for _, vein in PhysiqueConfig.VEINS do
		local limb = character:FindFirstChild(vein.Part)
		if limb == nil or not limb:IsA("BasePart") then
			continue
		end

		local part = Instance.new("Part")
		part.Name = "Vein"
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Massless = true
		part.Color = VEIN_COLOR
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 1
		part.Size = Vector3.new(0.1, 0.4, 0.1)
		part.CFrame = limb.CFrame
		part.Parent = folder

		-- A cylinder's length runs along X, so it is turned to lie along the limb.
		local weld = Instance.new("Weld")
		weld.Part0 = limb
		weld.Part1 = part
		weld.C1 = CFrame.Angles(0, 0, math.rad(90))
		weld.Parent = part

		local entry: Entry = { part = part, weld = weld, vein = vein, fittedTo = Vector3.zero }
		fit(entry, limb)
		table.insert(built, entry)
	end

	entries[character] = built
end

local function clear(character: Model)
	local built = entries[character]
	if built == nil then
		return
	end
	for _, entry in built do
		entry.part:Destroy()
	end
	entries[character] = nil

	local folder = character:FindFirstChild(VEIN_FOLDER)
	if folder ~= nil then
		folder:Destroy()
	end
end

local function refresh(character: Model): ...any
	local strength = PhysiqueConfig.VeinStrength(peakScale(character))

	if strength <= 0 then
		clear(character)
		return
	end

	build(character)

	local built = entries[character]
	if built == nil then
		return
	end

	local transparency = 1 - (1 - PhysiqueConfig.VEIN_MIN_TRANSPARENCY) * strength

	for _, entry in built do
		local limb = character:FindFirstChild(entry.vein.Part)
		if limb == nil or not limb:IsA("BasePart") then
			continue
		end

		entry.part.Transparency = transparency

		-- Only re-seat when the limb has actually moved. Growth is smoothed over
		-- seconds and stops between sets, so most refreshes do nothing at all.
		if (limb.Size - entry.fittedTo).Magnitude > REFIT_EPSILON then
			fit(entry, limb)
		end
	end
end

function VeinController:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character ~= nil then
			clear(character)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)

			for _, player in Players:GetPlayers() do
				local character = player.Character
				if character ~= nil and character.Parent ~= nil then
					-- Cosmetic: a failure here must never stop the loop for everyone.
					local ok, err = pcall(refresh, character)
					if not ok and RunService:IsStudio() then
						warn(`[VeinController] {err}`)
					end
				end
			end

			-- Characters that died or streamed out.
			for character in entries do
				if character.Parent == nil then
					entries[character] = nil
				end
			end
		end
	end)
end

return VeinController
