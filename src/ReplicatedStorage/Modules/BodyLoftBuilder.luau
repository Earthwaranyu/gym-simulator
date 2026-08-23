--!strict
--[[
	BodyLoftBuilder — turns BodyLoftConfig into one skinned MeshPart.

	The whole body is a single EditableMesh with a single skeleton. That is not a
	stylistic choice: a Play client permits only seven or eight EditableMesh instances
	at once, a cap on instances rather than a memory budget, so anything that splits
	the body into a piece per limb cannot render at all. The previous attempt at a
	generated body did exactly that and has never once succeeded on a client.

	Two more measured behaviours shape this file, both silent failures rather than
	errors:

	  * A MeshPart keeps a live dependency on the EditableMesh it came from. Free the
	    mesh and the part stays at the right size rendering *nothing at all* — and
	    `MeshSize` still reports the old extents, so the obvious check does not catch
	    it. The mesh is returned to the caller to hold for as long as the part lives.
	  * `CreateEditableMesh` returns nil when the cap is reached instead of throwing,
	    so every allocation is checked and a failed build hands nothing back.

	Skin weights need two calls in this order — `SetVertexBones` then
	`SetVertexBoneWeights`. Weights alone are rejected with "number of bone weights
	does not match number of bone ids", which reads like a counting mistake and is
	not one.
]]

local AssetService = game:GetService("AssetService")

local BodyLoftConfig = require(script.Parent.BodyLoftConfig)
local BodySkinPainter = require(script.Parent.BodySkinPainter)
local PhysiqueConfig = require(script.Parent.PhysiqueConfig)

local BodyLoftBuilder = {}

export type Detail = { Sides: number, Subdivisions: number }
-- A lobe resolved into body space, ready to be ray-tested.
type Placed = {
	x: number,
	y: number,
	z: number,
	r: number,
	blend: number,
	sx: number,
	sy: number,
	sz: number,
}
export type Palette = { Skin: Color3, Pants: Color3 }
-- Per-rig-part growth, straight from the character's MuscleScales folder.
export type Scales = { [string]: number }
export type Built = { Part: MeshPart, Mesh: EditableMesh }

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[[
	Expands a tube's authored cross-sections into the rings actually lofted, inserting
	`Subdivisions` interpolated rings between each authored pair. Interpolating here
	rather than authoring every ring is what lets a limb read as a curve while the
	config stays short enough for a person to tune.

	Bone influences are carried through by name and blended, so a subdivided ring
	between an elbow's two sides gets a sensible split without anyone writing it down.
]]
type Sample = {
	X: number,
	Y: number,
	Z: number,
	RX: number,
	RZ: number,
	Slot: string,
	Bones: { [string]: number },
	T: number,
}

local function influenceMap(ring: any): { [string]: number }
	local map: { [string]: number } = {}
	local total = 0
	for _, inf in ring.Bones do
		total += inf.Weight
	end
	for _, inf in ring.Bones do
		map[inf.Bone] = (map[inf.Bone] or 0) + inf.Weight / total
	end
	return map
end

local function blend(a: { [string]: number }, b: { [string]: number }, t: number): { [string]: number }
	local out: { [string]: number } = {}
	for name, w in a do
		out[name] = w * (1 - t)
	end
	for name, w in b do
		out[name] = (out[name] or 0) + w * t
	end
	return out
end

local function sampleTube(tube: any, detail: Detail): { Sample }
	local samples: { Sample } = {}
	local rings = tube.Rings
	local maps: { { [string]: number } } = {}
	for index, r in rings do
		maps[index] = influenceMap(r)
	end
	for index = 1, #rings - 1 do
		local a, b = rings[index], rings[index + 1]
		local steps = detail.Subdivisions + 1
		for step = 0, steps - 1 do
			local t = step / steps
			table.insert(samples, {
				X = lerp(a.X, b.X, t),
				Y = lerp(a.Y, b.Y, t),
				Z = lerp(a.Z, b.Z, t),
				RX = lerp(a.RX, b.RX, t),
				RZ = lerp(a.RZ, b.RZ, t),
				-- A band is one slot or the other; there is no half-trousered ring.
				Slot = if t < 0.5 then a.Slot else b.Slot,
				Bones = blend(maps[index], maps[index + 1], t),
				T = 0,
			})
		end
	end
	local last = rings[#rings]
	table.insert(samples, {
		X = last.X,
		Y = last.Y,
		Z = last.Z,
		RX = last.RX,
		RZ = last.RZ,
		Slot = last.Slot,
		Bones = maps[#rings],
		T = 1,
	})
	for index, s in samples do
		s.T = (index - 1) / math.max(1, #samples - 1)
	end
	return samples
end

-- Roblox caps a vertex at four bone influences and rejects a fifth outright, so the
-- weakest are dropped and the survivors renormalised rather than letting the whole
-- build fail on a ring somebody over-specified.
local function topInfluences(
	bones: { [string]: number },
	boneIds: { [string]: number }
): ({ number }, { number })
	local ordered: { { name: string, weight: number } } = {}
	for name, weight in bones do
		table.insert(ordered, { name = name, weight = weight })
	end
	table.sort(ordered, function(x, y)
		return x.weight > y.weight
	end)
	local ids, weights, total = {}, {}, 0
	for index = 1, math.min(#ordered, BodyLoftConfig.MAX_INFLUENCES) do
		local entry = ordered[index]
		local id = boneIds[entry.name]
		if id ~= nil then
			table.insert(ids, id)
			table.insert(weights, entry.weight)
			total += entry.weight
		end
	end
	if total > 0 then
		for index, w in weights do
			weights[index] = w / total
		end
	end
	return ids, weights
end

--[[
	Builds the body at the given per-stat progress.

	Returns nil rather than erroring when the EditableMesh cap is reached, because
	that is a normal condition on a busy client and the caller's answer to it is to
	fall back to the primitive body, not to fail.
]]
--[[
	How much a ring grows, blended across the bones that carry it.

	The growth curve is not re-derived here. `MuscleService` publishes a scale per rig
	part and `PhysiqueConfig.AxisScale` turns it into per-axis growth — girth-led, so
	a body widens without getting taller. A ring already declares which bones carry
	it, so blending their axis scales by those same weights gives a shoulder ring split
	between torso and arm a sensible in-between with no second progression to keep in
	sync. Without this the mesh sat at base proportions while the rig underneath grew
	to a 3.3-stud chest, and a fully trained fighter looked barely bigger than a new one.
]]
local function ringScale(
	bones: { [string]: number },
	scales: Scales,
	partOfBone: { [string]: string }
): (number, number)
	local totalX, totalZ, totalWeight = 0, 0, 0
	for boneName, weight in bones do
		local partName = partOfBone[boneName]
		local scale = if partName ~= nil then scales[partName] else nil
		local x, _, z = PhysiqueConfig.AxisScale(partName or "", scale or 1)
		totalX += x * weight
		totalZ += z * weight
		totalWeight += weight
	end
	if totalWeight <= 0 then
		return 1, 1
	end
	return totalX / totalWeight, totalZ / totalWeight
end

function BodyLoftBuilder.Build(
	progressByStat: { [string]: number },
	detail: Detail,
	palette: Palette,
	scales: Scales
): Built?
	local mesh = AssetService:CreateEditableMesh()
	if mesh == nil then
		return nil
	end

	local ok, result = pcall(function(): Built
		local boneIds: { [string]: number } = {}
		for _, bone in BodyLoftConfig.BONES do
			boneIds[bone.Name] = mesh:AddBone({
				Name = bone.Name,
				CFrame = CFrame.new(bone.X, bone.Y, bone.Z),
				Virtual = false,
				-- Flat hierarchy: every bone hangs off Root, so its runtime transform
				-- is read straight from its own R15 part with nothing accumulating
				-- down a chain. See BodyLoftConfig's header.
				ParentId = if bone.Name == "Root" then nil else boneIds.Root,
			})
		end

		local sides = detail.Sides
		local twoPi = math.pi * 2
		local partOfBone: { [string]: string } = {}
		for _, bone in BodyLoftConfig.BONES do
			partOfBone[bone.Name] = bone.Part
		end
		-- How far the chest has widened, in studs of half-width. Arms ride outward on
		-- this so they clear a broad chest instead of sinking into the ribs.
		local torsoX = select(1, PhysiqueConfig.AxisScale("UpperTorso", scales.UpperTorso or 1))
		local spreadStuds = (torsoX - 1) * BodyLoftConfig.TORSO_HALF_WIDTH
		-- Skin and shorts are vertex colours rather than two parts or a texture,
		-- because the body is one mesh and one MeshPart.Color cannot be two things.
		-- AppearanceService paints the rig through BodyColors, so the caller reads
		-- the real colours off the live rig and hands them in here.
		--[[
			A light tint following the surface relief: how far this vertex ended up
			from the plain tube it would have been without any muscle. Positive on a
			lobe, negative inside a groove, so muscles catch a highlight and the
			channels between them fall into shadow.

			Deliberately gentle. The painted texture carries the definition now, and a
			strong vertex tint on top of it reads as blotching rather than muscle.
		]]
		-- Light touch: the painted texture is doing the definition now, and a strong
		-- vertex tint on top of it reads as blotches rather than muscle.
		local SHADE_DEPTH = 0.12
		local HIGHLIGHT = 0.06
		local function shadeFor(base: Color3, relief: number, reach: number): number
			if reach <= 1e-4 then
				return mesh:AddColor(base, 1)
			end
			-- -1 in the deepest groove, +1 on the highest point of a muscle.
			local t = math.clamp(relief / reach, -1, 1)
			local shaded = if t >= 0
				then base:Lerp(Color3.new(1, 1, 1), t * HIGHLIGHT)
				else base:Lerp(Color3.new(0, 0, 0), -t * SHADE_DEPTH)
			return mesh:AddColor(shaded, 1)
		end

		for _, tube in BodyLoftConfig.TUBES do
			local samples = sampleTube(tube, detail)
			--[[
				The torso is authored hips-upward and the limbs shoulder-downward,
				because that is how each reads when written down. One winding formula
				therefore produces one of them inside out, and an inside-out surface is
				backface-culled: it renders as nothing at all while every property on
				the MeshPart still looks healthy. BodyLoftConfig owns the rule and its
				self-test proves it, so the two cannot drift apart.
			]]
			local flip = BodyLoftConfig.IsAscending(tube)
			local spread = spreadStuds * tube.Spread
			local grid: { { number } } = {}
			local uvGrid: { { number } } = {}
			local normalGrid: { { number } } = {}
			local positions: { { Vector3 } } = {}
			local pushGrid: { { number } } = {}
			local colorGrid: { { number } } = {}
			local slotOfRow: { string } = {}
			local reach = 0

			--[[
				Lobe centres, resolved once per tube against the scaled geometry.

				A lobe is authored in the tube's frame — a position along it, an angle
				round it, and a fraction of the local radius — so it has to become a
				point in body space before any ray can be cast at it. Doing that here
				rather than per vertex also picks up the growth scaling and the arm
				spread for free, which is the whole reason lobes are authored in tube
				space rather than in body space.
			]]
			local placed: { Placed } = {}
			for _, l in BodyLoftConfig.LOBES do
				if l.Tube ~= tube.Id then
					continue
				end
				local lobeRadius = BodyLoftConfig.LobeRadius(l, progressByStat[l.StatId] or 0)
				if lobeRadius <= 1e-4 then
					continue
				end
				local at = math.clamp(l.T, 0, 1) * (#samples - 1) + 1
				local lower = math.clamp(math.floor(at), 1, #samples)
				local upper = math.clamp(lower + 1, 1, #samples)
				local frac = at - lower
				local a, b = samples[lower], samples[upper]
				local sx, sz = ringScale(a.Bones, scales, partOfBone)
				local rx = (a.RX + (b.RX - a.RX) * frac) * sx
				local rz = (a.RZ + (b.RZ - a.RZ) * frac) * sz
				local share = 1 - (a.Bones.UpperTorso or 0) - (a.Bones.LowerTorso or 0)
				local axisX = (a.X + (b.X - a.X) * frac)
					+ (if a.X < 0 then -spread else spread) * math.clamp(share, 0, 1)
				local axisY = a.Y + (b.Y - a.Y) * frac
				local axisZ = a.Z + (b.Z - a.Z) * frac
				local sinA, cosA = math.sin(l.Angle), math.cos(l.Angle)
				local localRadius = math.sqrt((sinA * rx) ^ 2 + (cosA * rz) ^ 2)
				-- The sphere grows with the body too, or muscles shrink relative to a
				-- widening torso and the physique flattens out at high rank.
				local girth = (sx + sz) * 0.5
				table.insert(placed, {
					x = axisX + sinA * localRadius * l.Out,
					y = axisY,
					z = axisZ - cosA * localRadius * l.Out,
					r = lobeRadius * girth,
					blend = l.Blend * girth,
					-- Stretch is a shape, not a size, so it rides along unscaled: the
					-- girth factor is already in the radius and applying it twice would
					-- make a lat flatten further the bigger the player got.
					sx = l.StretchX,
					sy = l.StretchY,
					sz = l.StretchZ,
				})
			end

			for rowIndex, sample in samples do
				local row, uvRow, posRow, pushRow = {}, {}, {}, {}
				for side = 0, sides - 1 do
					local angle = side / sides * twoPi
					local push = 0
					for _, g in BodyLoftConfig.GROOVES do
						if g.Tube == tube.Id then
							push += BodyLoftConfig.Displacement(
								g,
								sample.T,
								angle,
								progressByStat[g.StatId] or 0
							)
						end
					end
					-- Angle 0 is the front, and the avatar faces -Z.
					local scaleX, scaleZ = ringScale(sample.Bones, scales, partOfBone)
					local rx = sample.RX * scaleX
					local rz = sample.RZ * scaleZ
					--[[
						Spread only as far as the ring belongs to the limb.

						Applied flat to every ring it dragged the shoulder cap outward
						too — and that cap is skinned to the torso, so the joint got
						stretched into the flat plate visible at the shoulders. Weighting
						it by how much of the ring the limb's own bones carry leaves the
						cap on the shoulder while the arm proper rides out.
					]]
					local limbShare = 1 - (sample.Bones.UpperTorso or 0) - (sample.Bones.LowerTorso or 0)
					local centreX = sample.X
						+ (if sample.X < 0 then -spread else spread) * math.clamp(limbShare, 0, 1)
					--[[
						The surface is the smooth union of the tube and every lobe on it.

						Cast a ray outward from the axis along this vertex's direction and
						take the furthest exit from anything it meets. Where a muscle's
						sphere reaches past the tube the surface follows the sphere, so
						the muscle stands proud with a defined edge; where it does not,
						the tube is unchanged. That edge is what a Gaussian could never
						produce however large it was made.
					]]
					local dirX, dirZ = math.sin(angle), -math.cos(angle)
					local baseRadius = math.sqrt((dirX * rx) ^ 2 + (dirZ * rz) ^ 2)
					local radius = baseRadius
					for _, l in placed do
						local exit = BodyLoftConfig.RayExit(
							centreX,
							sample.Y,
							sample.Z,
							dirX,
							0,
							dirZ,
							l.x,
							l.y,
							l.z,
							l.r,
							l.sx,
							l.sy,
							l.sz
						)
						if exit ~= nil then
							radius = BodyLoftConfig.SmoothMax(exit, radius, l.blend)
						end
					end
					-- Grooves cut afterwards, so a channel bites into the muscle it
					-- separates instead of being swallowed by the union.
					radius += push

					local position = Vector3.new(centreX + dirX * radius, sample.Y, sample.Z + dirZ * radius)
					local vertexId = mesh:AddVertex(position)
					row[side] = vertexId
					posRow[side] = position
					local relief = radius - baseRadius
					pushRow[side] = relief
					reach = math.max(reach, math.abs(relief))
					-- Rotated half a turn so the front centre line lands mid-column;
					-- the wrap seam then falls down the back rather than the abs.
					local u = tube.U0 + ((side / sides + 0.5) % 1) * (tube.U1 - tube.U0)
					uvRow[side] = mesh:AddUV(Vector2.new(u, sample.T))

					local ids, weights = topInfluences(sample.Bones, boneIds)
					mesh:SetVertexBones(vertexId, ids)
					mesh:SetVertexBoneWeights(vertexId, weights)
				end
				-- The wrap quad needs a UV at the far edge of the column. Reusing side 0's
				-- UV instead runs the texture backwards across that one strip, which
				-- shows as a smeared band down the spine.
				uvRow[sides] = mesh:AddUV(Vector2.new(tube.U1, sample.T))
				slotOfRow[rowIndex] = sample.Slot
				grid[rowIndex] = row
				uvGrid[rowIndex] = uvRow
				positions[rowIndex] = posRow
				pushGrid[rowIndex] = pushRow
			end

			-- Shading needs the tube's peak displacement, so it is a second pass.
			for rowIndex = 1, #samples do
				local base = if slotOfRow[rowIndex] == "Pants" then palette.Pants else palette.Skin
				local colorRow = {}
				for side = 0, sides - 1 do
					colorRow[side] = shadeFor(base, pushGrid[rowIndex][side], reach)
				end
				colorGrid[rowIndex] = colorRow
			end

			--[[
				Normals from the surface itself rather than from the face triangles.

				Left to derive its own, the renderer gives each flat triangle one normal
				and the limb reads as a stack of cans — which is the exact look this
				whole approach exists to escape. Crossing the two surface tangents at a
				vertex gives a normal shared by every face touching it, so the shading
				runs smoothly around and along the limb.
			]]
			for rowIndex = 1, #samples do
				local normalRow = {}
				local above = positions[math.min(rowIndex + 1, #samples)]
				local below = positions[math.max(rowIndex - 1, 1)]
				for side = 0, sides - 1 do
					local nextSide = (side + 1) % sides
					local prevSide = (side - 1 + sides) % sides
					local alongRing = positions[rowIndex][nextSide] - positions[rowIndex][prevSide]
					local alongTube = above[side] - below[side]
					local normal = alongTube:Cross(alongRing)
					if normal.Magnitude < 1e-6 then
						normal = Vector3.new(positions[rowIndex][side].X, 0, positions[rowIndex][side].Z)
					end
					normal = normal.Unit
					-- Point it away from the tube's axis, whichever way the cross fell.
					local axis = Vector3.new(samples[rowIndex].X, samples[rowIndex].Y, samples[rowIndex].Z)
					if normal:Dot(positions[rowIndex][side] - axis) < 0 then
						normal = -normal
					end
					normalRow[side] = mesh:AddNormal(normal)
				end
				normalGrid[rowIndex] = normalRow
			end

			for rowIndex = 1, #samples - 1 do
				local a, b = grid[rowIndex], grid[rowIndex + 1]
				local ua, ub = uvGrid[rowIndex], uvGrid[rowIndex + 1]
				local na, nb = normalGrid[rowIndex], normalGrid[rowIndex + 1]
				local ca, cb = colorGrid[rowIndex], colorGrid[rowIndex + 1]
				for side = 0, sides - 1 do
					local next = (side + 1) % sides
					-- At the seam, step to the duplicate edge UV rather than wrapping.
					local uNext = if side == sides - 1 then sides else next
					local f1, f2
					if flip then
						f1 = mesh:AddTriangle(a[side], b[side], a[next])
						mesh:SetFaceUVs(f1, { ua[side], ub[side], ua[uNext] })
						mesh:SetFaceNormals(f1, { na[side], nb[side], na[next] })
						mesh:SetFaceColors(f1, { ca[side], cb[side], ca[next] })
						f2 = mesh:AddTriangle(a[next], b[side], b[next])
						mesh:SetFaceUVs(f2, { ua[uNext], ub[side], ub[uNext] })
						mesh:SetFaceNormals(f2, { na[next], nb[side], nb[next] })
						mesh:SetFaceColors(f2, { ca[next], cb[side], cb[next] })
					else
						f1 = mesh:AddTriangle(a[side], a[next], b[side])
						mesh:SetFaceUVs(f1, { ua[side], ua[uNext], ub[side] })
						mesh:SetFaceNormals(f1, { na[side], na[next], nb[side] })
						mesh:SetFaceColors(f1, { ca[side], ca[next], cb[side] })
						f2 = mesh:AddTriangle(a[next], b[next], b[side])
						mesh:SetFaceUVs(f2, { ua[uNext], ub[uNext], ub[side] })
						mesh:SetFaceNormals(f2, { na[next], nb[next], nb[side] })
						mesh:SetFaceColors(f2, { ca[next], cb[next], cb[side] })
					end
				end
			end

			-- Cap both ends so the body is closed. The caps at a shoulder or hip are
			-- buried inside the torso and never seen; the ones at a wrist or ankle
			-- meet the stock R15 hand and foot.
			for _, capIndex in { 1, #samples } do
				local sample = samples[capIndex]
				local capShare = 1 - (sample.Bones.UpperTorso or 0) - (sample.Bones.LowerTorso or 0)
				local capX = sample.X
					+ (if sample.X < 0 then -spread else spread) * math.clamp(capShare, 0, 1)
				local centre = mesh:AddVertex(Vector3.new(capX, sample.Y, sample.Z))
				local centreUV = mesh:AddUV(Vector2.new(0.5, sample.T))
				-- The cap faces along the tube, away from the body.
				local outward = if (capIndex == 1) ~= flip then Vector3.yAxis else -Vector3.yAxis
				local centreNormal = mesh:AddNormal(outward)
				local ids, weights = topInfluences(sample.Bones, boneIds)
				mesh:SetVertexBones(centre, ids)
				mesh:SetVertexBoneWeights(centre, weights)
				local row, uvRow = grid[capIndex], uvGrid[capIndex]
				local capColors = colorGrid[capIndex]
				local capCentreColor = capColors[0]
				for side = 0, sides - 1 do
					local next = (side + 1) % sides
					-- Wind the two caps oppositely so both face outwards, and swap
					-- them again when the tube itself runs the other way.
					local first = (capIndex == 1) ~= flip
					local f = if first
						then mesh:AddTriangle(centre, row[next], row[side])
						else mesh:AddTriangle(centre, row[side], row[next])
					if first then
						mesh:SetFaceUVs(f, { centreUV, uvRow[next], uvRow[side] })
						mesh:SetFaceNormals(f, { centreNormal, centreNormal, centreNormal })
					else
						mesh:SetFaceUVs(f, { centreUV, uvRow[side], uvRow[next] })
						mesh:SetFaceNormals(f, { centreNormal, centreNormal, centreNormal })
					end
					mesh:SetFaceColors(f, { capCentreColor, capColors[side], capColors[next] })
				end
			end
		end

		local part = AssetService:CreateMeshPartAsync(
			Content.fromObject(mesh),
			{ CollisionFidelity = Enum.CollisionFidelity.Box }
		)
		part.Name = BodyLoftConfig.PART_NAME
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = true
		part.Material = Enum.Material.SmoothPlastic

		--[[
			The painted physique. A failure here is not fatal: the body still carries
			skin and shorts as vertex colours, so the player keeps a correct if plain
			body rather than none at all.
		]]
		local overall = 0
		for _, value in progressByStat do
			overall = math.max(overall, value)
		end
		local skin = BodySkinPainter.Get(palette, overall)
		if skin ~= nil then
			part.TextureContent = Content.fromObject(skin)
		end

		return { Part = part, Mesh = mesh }
	end)

	if not ok then
		mesh:Destroy()
		warn(`BodyLoftBuilder: {result}`)
		return nil
	end
	return result :: Built
end

return BodyLoftBuilder
