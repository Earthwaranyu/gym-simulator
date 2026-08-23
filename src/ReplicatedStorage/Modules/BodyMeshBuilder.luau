--!strict
--[[
	BodyMeshBuilder — cuts the generated body mesh into R15 parts.

	`BodyMeshConfig` says where the cuts go; this does them. In a shipped place the
	cut has already happened: `scripts/cut_body_mesh.luau` runs it once in Studio
	and leaves the parts in ReplicatedStorage.BodyRig, saved with the place, and
	`Build` simply hands those out. Cutting at runtime is a fallback for a place
	that is missing them.

	The body is dressed per client rather than by the server because
	`CreateMeshPartAsync` returns geometry with no MeshId — a runtime mesh, not an
	uploaded asset — and instances like that cannot replicate. That is the same
	shape as the muscle contours this replaces: purely cosmetic, with the stock R15
	parts left underneath as the real rig, joints and hitboxes.

	Three EditableMesh behaviours shape all of this, each a silent failure rather
	than an error, and each one measured on this project rather than assumed:

	  * A MeshPart keeps a *live dependency* on the EditableMesh it was made from.
	    Destroy that mesh, or merely let it be garbage collected, and the part is
	    still there at the right size with no geometry at all — it renders as a
	    plain block, and the body quietly turns back into rectangles. So every mesh
	    behind a finished part is retained.
	  * The limit is a cap on how many EditableMesh instances may exist at once, not
	    a memory budget: in Play a client allows **seven or eight**, and a
	    5,000-vertex mesh costs exactly as much as an empty one. Studio's edit
	    session has no such cap, which is why the fourteen pieces cut fine there and
	    can never be allocated in Play. Since they must stay allocated, per the
	    point above, fourteen pieces can never render on a client at all.

	    That is fatal to this module rather than inconvenient, and it is why
	    `_BodyMeshController` is disabled. An earlier version of this comment blamed
	    the vertex count; that was wrong, and it hid the real ceiling for a long
	    time. The replacement is `BodyLoftBuilder`, which generates the whole body
	    as ONE skinned mesh — one instance, comfortably inside the cap.
	  * When the budget runs out `CreateEditableMesh` returns nil instead of
	    throwing, and nothing reclaims what a half-finished cut already took. So the
	    source is read into plain tables and released before any piece is allocated,
	    and a failed cut hands its pieces back.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BodyMeshConfig = require(script.Parent.BodyMeshConfig)

-- Where `scripts/cut_body_mesh.luau` leaves the pre-cut body.
local PREBUILT_NAME = "BodyRig"

local BodyMeshBuilder = {}

local cached: Folder? = nil
local building = false
--[[
	The EditableMeshes the finished parts are still backed by. Nothing ever reads
	this; it exists so they are never collected. See the note in the header.
]]
local retained: { EditableMesh } = {}

-- One triangle of the source, in indices into the snapshot tables below.
type Triangle = {
	V: { number },
	N: { number }?,
}

type Snapshot = {
	Positions: { Vector3 },
	Normals: { Vector3 },
	ByRegion: { [string]: { Triangle } },
}

--[[
	Reads the whole source mesh into plain tables, keyed by the R15 part each
	triangle belongs to.

	This exists to get the source *out* of the EditableMesh budget before the
	pieces go in. It also de-duplicates: neighbouring triangles share vertices and
	normals, and copying them per-triangle would triple the data.
]]
local function snapshot(source: EditableMesh): Snapshot
	local positions: { Vector3 } = {}
	local normals: { Vector3 } = {}
	local positionOf: { [any]: number } = {}
	local normalOf: { [any]: number } = {}
	local byRegion: { [string]: { Triangle } } = {}

	for _, face in source:GetFaces() do
		local sourceVerts = source:GetFaceVertices(face)
		local p1 = source:GetPosition(sourceVerts[1])
		local p2 = source:GetPosition(sourceVerts[2])
		local p3 = source:GetPosition(sourceVerts[3])

		local centroid = (p1 + p2 + p3) / 3
		local name = BodyMeshConfig.Region(centroid.X, centroid.Y)
		if name == nil then
			continue
		end

		local verts = table.create(3)
		for i = 1, 3 do
			local old = sourceVerts[i]
			local index = positionOf[old]
			if index == nil then
				table.insert(positions, source:GetPosition(old))
				index = #positions
				positionOf[old] = index
			end
			verts[i] = index
		end

		local normalIndices: { number }? = nil
		local sourceNormals = source:GetFaceNormals(face)
		if sourceNormals ~= nil then
			local collected: { number } = table.create(3)
			local complete = true
			for i = 1, 3 do
				local old = sourceNormals[i]
				local index = normalOf[old]
				if index == nil then
					local normal = source:GetNormal(old)
					if normal == nil then
						-- One missing normal only costs this triangle its smooth
						-- shading, so drop it rather than the whole piece.
						complete = false
						break
					end
					table.insert(normals, normal)
					index = #normals
					normalOf[old] = index
				end
				collected[i] = index
			end
			if complete then
				normalIndices = collected
			end
		end

		local bucket = byRegion[name]
		if bucket == nil then
			bucket = {}
			byRegion[name] = bucket
		end
		table.insert(bucket, { V = verts, N = normalIndices })
	end

	return { Positions = positions, Normals = normals, ByRegion = byRegion }
end

--[[
	Builds one piece from the snapshot, moved so it is centred on its own origin.

	The recentring is what makes the pieces usable. Straight out of the cut, every
	piece keeps its coordinates from the whole body, so its geometry sits far away
	from the part's own centre — a foot's vertices are nearly three studs below it.
	A MeshPart in that state renders correctly only at its natural size: changing
	Size scales the geometry about the part centre, and geometry that far off
	centre does not shrink, it flies apart. Subtracting the piece's own centre here
	means Size behaves normally afterwards, which is also what lets each limb be
	scaled independently as its stat grows.

	Carrying the normals across is not an optimisation: without them each piece
	renders faceted, and the cut lines read as damage rather than as joints.
]]
local function buildRegion(data: Snapshot, triangles: { Triangle }, centre: Vector3): EditableMesh
	local mesh = AssetService:CreateEditableMesh()
	if mesh == nil then
		-- Returns nil rather than throwing when the budget is gone, so say what
		-- actually happened instead of failing on the next line.
		error("out of EditableMesh memory budget while cutting the body", 0)
	end

	local vertexMap: { [number]: any } = {}
	local normalMap: { [number]: any } = {}

	for _, triangle in triangles do
		local verts = table.create(3)
		for i = 1, 3 do
			local index = triangle.V[i]
			if vertexMap[index] == nil then
				vertexMap[index] = mesh:AddVertex(data.Positions[index] - centre)
			end
			verts[i] = vertexMap[index]
		end

		local face = mesh:AddTriangle(verts[1], verts[2], verts[3])

		local normalIndices = triangle.N
		if normalIndices ~= nil then
			local collected = table.create(3)
			for i = 1, 3 do
				local index = normalIndices[i]
				if normalMap[index] == nil then
					normalMap[index] = mesh:AddNormal(data.Normals[index])
				end
				collected[i] = normalMap[index]
			end
			-- Tolerated rather than required: a source without per-face normals
			-- still cuts, it just shades flat.
			pcall(function()
				mesh:SetFaceNormals(face, collected)
			end)
		end
	end

	return mesh
end

--[[
	Cuts the source asset into a fresh Folder of fourteen MeshParts.

	Throws rather than returning nil, so the caller sees why. Run from Studio by
	`scripts/cut_body_mesh.luau`, which parents the result into ReplicatedStorage
	to be saved with the place; `Build` calls it only as a fallback.
]]
function BodyMeshBuilder.Cut(): Folder
	local source = AssetService:CreateEditableMeshAsync(Content.fromAssetId(BodyMeshConfig.SOURCE_ASSET_ID))
	local data = snapshot(source)
	-- Freed before a single piece is allocated: see the header. Everything the
	-- pieces need is now in `data`.
	source:Destroy()

	local folder = Instance.new("Folder")
	folder.Name = "BodyMeshTemplate"

	for name, triangles in data.ByRegion do
		-- Where this piece sits inside the whole body. Removed from the geometry so
		-- the part scales sanely, and recorded so the body can be put back together
		-- around it.
		local min = Vector3.new(math.huge, math.huge, math.huge)
		local max = -min
		for _, triangle in triangles do
			for i = 1, 3 do
				local p = data.Positions[triangle.V[i]]
				min = min:Min(p)
				max = max:Max(p)
			end
		end
		local centre = (min + max) / 2

		local mesh = buildRegion(data, triangles, centre)
		local part = AssetService:CreateMeshPartAsync(
			Content.fromObject(mesh),
			-- Box collision keeps hitboxes identical to the rectangles these cover,
			-- so nothing about combat changes with the model.
			{ CollisionFidelity = Enum.CollisionFidelity.Box }
		)
		table.insert(retained, mesh)

		part.Name = name
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = true
		part.Material = Enum.Material.SmoothPlastic
		part:SetAttribute("BodyOffset", centre)
		part.Parent = folder
	end

	return folder
end

--[[
	The fourteen cut parts, as a Folder of MeshParts named for their R15 slots.

	Returns nil if the source asset cannot be read — the caller is expected to
	leave the stock body alone in that case rather than showing a half-built one.
]]
function BodyMeshBuilder.Build(): Folder?
	if cached ~= nil then
		return cached
	end

	--[[
		Prefer a body that was cut ahead of time.

		EditableMesh draws on a memory budget that is far smaller on a game client
		than in Studio's edit session: fourteen retained pieces build without
		complaint in Edit and cannot be allocated at all in Play. Since a MeshPart
		keeps a live dependency on its EditableMesh, "build fourteen and keep them"
		is exactly the shape the client cannot afford, so cutting at runtime is not
		something a player's machine can be relied on to do.

		`scripts/cut_body_mesh.luau` performs the cut once in Studio and leaves the
		result in ReplicatedStorage.BodyRig, which is saved with the place. That is
		the path players take. The runtime cut below stays as a fallback for a place
		where the pre-cut body is missing — it is better to spend the budget and
		maybe fail than to silently put everyone back in blocks.
	]]
	local prebuilt = ReplicatedStorage:FindFirstChild(PREBUILT_NAME)
	if prebuilt ~= nil and #prebuilt:GetChildren() > 0 then
		cached = prebuilt :: Folder
		return cached
	end
	-- Two characters spawning in the same frame must not both start cutting.
	if building then
		repeat
			task.wait()
		until not building
		return cached
	end
	building = true

	local ok, result = pcall(function(): Folder
		return BodyMeshBuilder.Cut()
	end)

	building = false

	if not ok then
		--[[
			Hand back the pieces that were built before the failure.

			Without this a half-finished cut keeps its meshes referenced forever, and
			since the budget those come out of is not reclaimed by anything else, one
			failed attempt makes every later attempt fail too — the session never
			recovers, which reads as the code being broken rather than the first
			attempt having been unlucky.
		]]
		for _, mesh in retained do
			mesh:Destroy()
		end
		table.clear(retained)
		warn(`BodyMeshBuilder: could not cut the body mesh ({result})`)
		return nil
	end

	cached = result :: Folder
	return cached
end

--[[
	The size of the uncut body, for scaling it onto a character.
]]
function BodyMeshBuilder.SourceHeight(): number
	return BodyMeshConfig.SOURCE_MAX_Y - BodyMeshConfig.SOURCE_MIN_Y
end

return BodyMeshBuilder
