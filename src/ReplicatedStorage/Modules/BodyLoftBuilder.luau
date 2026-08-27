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
	Cinch: number,
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
				Cinch = lerp(a.Cinch or 0, b.Cinch or 0, t),
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
		Cinch = last.Cinch or 0,
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
	scales: Scales,
	-- How cut the body is, independently of how big. 1 is a player; see BodyLoftConfig.
	rawLeanness: number?
): Built?
	local leanness = BodyLoftConfig.Leanness(rawLeanness)
	-- How far along the whole physique is, used for the things that are not any one
	-- muscle: the waist's cinch and which crease stage the texture is painted at.
	local taper = 0
	for _, value in progressByStat do
		taper = math.max(taper, value)
	end
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
			A shadow following the surface relief: how far this vertex ended up from the
			plain tube it would have been without any muscle. Zero on flat skin and on a
			lobe, negative inside a groove, so the channels between muscles fall into
			shadow while the muscles themselves are left to the world's lighting.

			This used to be described as "deliberately gentle… the painted texture
			carries the definition now". It was gentle by accident rather than by
			judgement — see the reach comment below — and gentle enough to be invisible.
			The texture does carry most of the definition, but a texture cannot put a
			shadow in a valley that the geometry has and the shading refuses to admit to.
		]]
		--[[
			The vertex tint is a shading multiplier, never a colour.

			It used to start from the palette, which meant the skin tone was applied
			twice — once here and once baked into the texture — and Roblox multiplies
			the two. A body picked as 236,200,168 rendered as 218,157,111 while the
			head, painted once through BodyColors, stayed correct. That is what put a
			pale face on a tan torso.

			White is the identity for that multiply, so flat skin now renders as
			exactly the texture and matches the head. Only grooves darken; see
			BodyLoftConfig.ReliefTint.
		]]
		local WHITE = Color3.new(1, 1, 1)
		local neutral = mesh:AddColor(WHITE, 1)
		local function shadeFor(relief: number, reach: number): number
			local tint = BodyLoftConfig.ReliefTint(relief, reach, leanness)
			if tint >= 1 then
				return neutral
			end
			return mesh:AddColor(WHITE:Lerp(Color3.new(0, 0, 0), 1 - tint), 1)
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
					--[[
						The fillet grows, but slower than the body does.

						Blend is the soft joint where a lobe melts into the tube, and at
						`* girth` it widened in step with the muscle — so the bigger a
						body got the more its muscles fused into one smooth mass. That is
						the same flattening the radius comment above warns about, arriving
						by a different door. A square root keeps enough growth that a
						crease never hardens into a seam at size, without letting the
						separation dissolve.
					]]
					blend = l.Blend * math.sqrt(girth),
					-- Stretch is a shape, not a size, so it rides along unscaled: the
					-- girth factor is already in the radius and applying it twice would
					-- make a lat flatten further the bigger the player got.
					sx = l.StretchX,
					sy = l.StretchY,
					sz = l.StretchZ,
				})
			end

			--[[
				The grooves on this tube, and the progress each is being grown at.

				Hoisted for the same reason `placed` is above: this used to walk every
				groove in the config once per vertex and test its tube inside the loop,
				which is five thousand vertices times the whole table. Splitting the
				muscles into their separate heads roughly doubled that table, so the
				per-vertex work stopped being negligible — a torso only ever cares
				about the torso's own grooves, and the filter belongs out here where it
				runs once instead of thirty times a ring.
			]]
			local cuts: { { Groove: BodyLoftConfig.Groove, Progress: number } } = {}
			for _, g in BodyLoftConfig.GROOVES do
				if g.Tube == tube.Id then
					table.insert(cuts, { Groove = g, Progress = progressByStat[g.StatId] or 0 })
				end
			end

			for rowIndex, sample in samples do
				local row, uvRow, posRow, pushRow = {}, {}, {}, {}
				for side = 0, sides - 1 do
					local angle = side / sides * twoPi
					local push = 0
					for _, cut in cuts do
						push += BodyLoftConfig.Displacement(cut.Groove, sample.T, angle, cut.Progress)
					end
					-- Angle 0 is the front, and the avatar faces -Z.
					local scaleX, scaleZ = ringScale(sample.Bones, scales, partOfBone)
					--[[
						The waist is the one band that gets *smaller* as the body grows.

						Everything else here multiplies girth upward, which is the whole
						point everywhere but here: a chest reads big because of what sits
						under it, and a waist that grows along with it flattens the taper
						the physique depends on. Cinch is authored per ring and driven by
						overall progress, so a beginner is never wasp-waisted and the V
						arrives with the muscle rather than ahead of it.
					]]
					local cinch = 1 - sample.Cinch * taper
					local rx = sample.RX * scaleX * cinch
					local rz = sample.RZ * scaleZ * cinch
					-- Leanness rides along with girth: a lean body cuts deeper at the
					-- same size, which is the whole difference between big and ripped.
					local grooveScale = (scaleX + scaleZ) * 0.5 * leanness
					--[[
						Every ring of a limb rides out by the same amount.

						This was once weighted by how much of the ring the limb's own
						bones carried, on the theory that holding the top rings back kept
						the shoulder joint attached. It did the opposite. A weight that
						climbs from 0.30 at the cap to 1.0 down the arm is a *gradient of
						translation*, and a gradient of translation fans the rings apart:
						at full growth the four shoulder rings were pushed out by 0.194,
						0.292, 0.421 and 0.518 studs respectively, which turned a 2.75:1
						silhouette into 4.55:1 — a horizontal shelf, which is precisely
						the plate it was meant to remove.

						Translating the whole tube uniformly preserves the authored slope
						exactly, at every size. What actually keeps the joint attached is
						that the tube's first ring now *starts inside the torso* — see the
						cap comment below and the burial check in RunSelfTest.
					]]
					local centreX = sample.X + (if sample.X < 0 then -spread else spread)
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
					--[[
						Grooves cut afterwards, so a channel bites into the muscle it
						separates instead of being swallowed by the union.

						Scaled by girth for the same reason the lobes are. Displacement
						is authored in absolute studs, so an unscaled cut stayed a
						0.18-stud nick while the chest it divides grew from 1.14 to 1.88
						— the definition washed out exactly as the muscle arrived, and a
						maxed body read as bulky rather than cut. A cut has to keep its
						proportion to the thing it separates.
					]]
					radius += push * grooveScale

					local position = Vector3.new(centreX + dirX * radius, sample.Y, sample.Z + dirZ * radius)
					local vertexId = mesh:AddVertex(position)
					row[side] = vertexId
					posRow[side] = position
					local relief = radius - baseRadius
					pushRow[side] = relief
					--[[
						Only grooves set the scale that grooves are measured against.

						This took `max(abs(relief))`, so the denominator was whatever
						moved the surface furthest *in either direction* — and on a maxed
						torso that is a lat peaking a full stud proud of the tube, while
						the deepest cut on the same body reaches a quarter of one. Every
						groove was then divided by four times its own range: the deepest
						crease on a player rendered 4.7% darker than flat skin, and the
						median groove vertex 0.02% darker, which is to say not at all.
						Deepening a groove only grew the divisor along with it, which is
						why several rounds of doing exactly that changed nothing.

						A cut is now measured against the deepest cut on its own tube.
					]]
					if relief < 0 then
						reach = math.max(reach, -relief)
					end
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
				grid[rowIndex] = row
				uvGrid[rowIndex] = uvRow
				positions[rowIndex] = posRow
				pushGrid[rowIndex] = pushRow
			end

			-- Shading needs the tube's peak relief, so it is a second pass. Skin and
			-- shorts are not consulted here at all any more: the texture owns colour.
			for rowIndex = 1, #samples do
				local colorRow = {}
				for side = 0, sides - 1 do
					colorRow[side] = shadeFor(pushGrid[rowIndex][side], reach)
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
			--[[
				A symmetric difference cannot see a one-vertex groove.

				`positions[next] - positions[prev]` is a smoothing kernel exactly one
				facet wide. At the floor of a narrow crease both walls sit at the same
				height, the two terms cancel, and the normal comes out pointing straight
				off the body — so the crease renders perfectly flat no matter how deep it
				is cut. Most grooves in this file are 0.9 to 1.4 vertices across at Hero
				detail, which is to say: most of them were invisible to the shading even
				where the mesh had them.

				So: where a vertex is a local extremum — both neighbours above it, or
				both below — take a *one-sided* difference toward the steeper of the two
				instead of spanning them. The normal then tilts into the wall, which is
				what makes a valley look like a valley. On flat surface both neighbours
				agree, the test fails, and the smooth central difference is used exactly
				as before, so nothing that already looked right changes.
			]]
			-- Both differences must clear this before a vertex counts as a trough or a
			-- ridge; below it the surface is flat and wants the smooth normal.
			local EXTREMUM = 0.02
			local function tangent(
				here: Vector3,
				prev: Vector3,
				next: Vector3,
				dp: number,
				dn: number
			): Vector3
				if dp > EXTREMUM and dn > EXTREMUM then
					-- A trough: both neighbours stand above this vertex.
					return if dn >= dp then next - here else here - prev
				elseif dp < -EXTREMUM and dn < -EXTREMUM then
					-- A ridge: both neighbours fall away from it.
					return if -dn >= -dp then next - here else here - prev
				end
				return next - prev
			end

			for rowIndex = 1, #samples do
				local normalRow = {}
				local above = positions[math.min(rowIndex + 1, #samples)]
				local below = positions[math.max(rowIndex - 1, 1)]
				local pushHere = pushGrid[rowIndex]
				local pushAbove = pushGrid[math.min(rowIndex + 1, #samples)]
				local pushBelow = pushGrid[math.max(rowIndex - 1, 1)]
				for side = 0, sides - 1 do
					local nextSide = (side + 1) % sides
					local prevSide = (side - 1 + sides) % sides
					local here = positions[rowIndex][side]
					local relief = pushHere[side]
					local alongRing = tangent(
						here,
						positions[rowIndex][prevSide],
						positions[rowIndex][nextSide],
						pushHere[prevSide] - relief,
						pushHere[nextSide] - relief
					)
					local alongTube = tangent(
						here,
						below[side],
						above[side],
						pushBelow[side] - relief,
						pushAbove[side] - relief
					)
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

			--[[
				Cap both ends so the body is closed.

				A cap is a triangle fan with every normal locked to +/-Y, so it is a
				perfectly flat disc facing straight up or straight down. At a wrist or
				ankle that is fine — it meets the stock R15 hand or foot. At a shoulder
				or hip it is only fine while it is **inside the torso**, and for a long
				time it was not: the arm's cap sat at y = 0.86 reaching out to x = 1.9 at
				full growth, while the torso had already necked in to 1.5 and collapsed
				to 0.7 above it. A horizontal disc hanging in clear air off the side of
				the shoulder is the dinner plate people kept seeing, and no amount of
				tuning the deltoid could hide it because it was not the deltoid.

				The limb tubes now begin well inside the torso, and RunSelfTest asserts
				that burial at both ends of the growth curve rather than assuming it the
				way this comment used to.
			]]
			for _, capIndex in { 1, #samples } do
				local sample = samples[capIndex]
				local capX = sample.X + (if sample.X < 0 then -spread else spread)
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
		--[[
			Plastic, not SmoothPlastic, for two reasons that agree.

			SmoothPlastic takes a hard specular highlight, and on a body covered in
			convex muscle that reads as *wet* — long glossy sweeps down the pecs and a
			patent-leather shine on the shorts, which is the opposite of the matte look
			this physique is copying. And the stock R15 head is Plastic, so the body was
			finishing differently from the face sitting on top of it.
		]]
		part.Material = Enum.Material.Plastic

		--[[
			The painted physique. A failure here is not fatal: the body still carries
			skin and shorts as vertex colours, so the player keeps a correct if plain
			body rather than none at all.
		]]
		local skin = BodySkinPainter.Get(palette, taper, leanness)
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
