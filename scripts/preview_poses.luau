--!nocheck
--[[
	preview_poses — inspect and measure the training animations.

	**Run this in Play mode, from the command bar, with the client selected.**
	It installs `_G.PosePreview` and prints the usage below.

	Why it has to be Play mode, which cost an afternoon to learn: a pose is applied
	by writing `Transform` on the rig's joints, and current Roblox rigs join with
	AnimationConstraint rather than Motor6D. An AnimationConstraint's Transform is
	resolved by the physics step, and Edit mode does not step physics — so in Edit
	you can write every joint on a dummy, read every part back, and find that
	absolutely nothing moved. The pose is real; the world just never applies it.

	Why it exists: a pose is numbers in PoseConfig, and the only way to see one used
	to be to start the game, earn the machine, walk to it and hold E. So the poses
	were authored blind, and this found five machines where the body was through the
	floor and two where the hands never reached the bar.

	  PosePreview.mount("BenchPress")   -- put yourself on that machine, posing
	  PosePreview.release()             -- get off
	  PosePreview.measure("BenchPress") -- one machine, with numbers
	  PosePreview.audit()               -- every machine, one line each

	Accepts an EquipmentId ("BenchPress") or a TravelId ("Iron-Chest").

	What `measure` reports, and what good looks like:

	  * **handGap** — how close the nearer hand gets to the thing it should be
	    holding, at any point in the rep. Should be ~0 on a machine with a fixed
	    grip. Meaningless on the 21 machines that carry a HeldBoth/HeldRight/
	    HeldLeft prop, because those props follow the hands rather than the hands
	    reaching them; those are marked `held`.
	  * **clearance** — the lowest point of the body against the surface it should
	    be resting on. Negative is sunk into it, positive is floating above it. A
	    hand's width either way is fine; half a stud is visible.

	It mounts the way TrainingService does — PivotTo(anchor.CFrame), verbatim, then
	the two pose attributes — and the maths comes from PosePlayback, the same module
	the live controller uses. Both matter: the anchor is the pose's entire frame of
	reference, so previewing anywhere else hides the whole class of bug where the
	body and the machine disagree.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

-- Seconds to let the 0.3s blend finish before believing anything measured.
local SETTLE = 1.1
-- Seconds to watch, which must exceed one rep at the slowest RepInterval.
local WATCH = 2.0
-- Camera stands back, right and up a little in the anchor's own space, so it
-- frames the lifter from the front whichever way the machine is turned.
local CAMERA_OFFSET = Vector3.new(6, 4, 14)

-- What a hand should be able to reach on a machine with no carried weight.
local GRIP_WORDS = { "Bar", "Handle", "Grip", "Rope", "Roller", "Rung", "Wheel", "Step", "Deck" }
-- What the body should be resting on, per machine, where it is not obvious.
local SUPPORT = {
	AbWheel = "Runway",
	CableCrunch = "KneePad",
	SquatRack = "Base",
	PushUps = "Deck",
	Plank = "Mat",
	GobletSquat = "Base",
	StairClimber = "StepLow",
}

local function character()
	local player = Players.LocalPlayer
	return player.Character or player.CharacterAdded:Wait()
end

local function stations()
	local out = {}
	local gym = workspace:FindFirstChild("Gym")
	local machines = gym and gym:FindFirstChild("Machines")
	if machines == nil then
		return out
	end
	for _, model in machines:GetDescendants() do
		if model:IsA("Model") and model:GetAttribute("EquipmentId") ~= nil then
			out[model:GetAttribute("TravelId")] = model
			if out[model:GetAttribute("EquipmentId")] == nil then
				out[model:GetAttribute("EquipmentId")] = model
			end
		end
	end
	return out
end

local function anchorOf(station)
	for _, part in station:GetDescendants() do
		if part.Name == "TrainAnchor" and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

--[[
	Whether this machine hands the lifter a weight. On those, the weight is moved to
	the hands every frame, so how far the hands are from where it was racked says
	nothing about whether the pose is right.
]]
local function carriesProp(station)
	for _, name in EquipmentConfig.HELD_NAMES do
		if station:FindFirstChild(name, true) ~= nil then
			return true
		end
	end
	return false
end

local function gapTo(part, target)
	local local_ = target.CFrame:PointToObjectSpace(part.Position)
	local clamped = Vector3.new(
		math.clamp(local_.X, -target.Size.X / 2, target.Size.X / 2),
		math.clamp(local_.Y, -target.Size.Y / 2, target.Size.Y / 2),
		math.clamp(local_.Z, -target.Size.Z / 2, target.Size.Z / 2)
	)
	return (local_ - clamped).Magnitude
end

local PosePreview = {}

function PosePreview.look(id)
	local station = stations()[id]
	local anchor = station and anchorOf(station)
	if anchor == nil then
		return `no anchor for {id}`
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt((anchor.CFrame * CFrame.new(CAMERA_OFFSET)).Position, anchor.Position)
	return `looking at {id}`
end

--[[
	Stands the local character on a machine and starts its pose, exactly the way the
	server would. Streaming is requested first, because a machine on a far island is
	not on this client until something asks for it.
]]
function PosePreview.mount(id)
	local station = stations()[id]
	if station == nil then
		-- Nothing to mount to yet: ask for the region, then look again.
		return `no station "{id}" on this client — try again once it streams in`
	end
	local anchor = anchorOf(station)
	local definition = EquipmentConfig.Get(station:GetAttribute("EquipmentId"))
	local pose = PoseConfig.Get(definition.PoseId)
	if pose == nil then
		return `{definition.Id} asks for unknown pose "{definition.PoseId}"`
	end

	local char = character()
	local root = char:WaitForChild("HumanoidRootPart")
	root.Anchored = false
	char:PivotTo(anchor.CFrame)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(anchor.Position)
	end)
	task.wait(0.4)
	char:PivotTo(anchor.CFrame)
	root.Anchored = true
	char:SetAttribute(PoseConfig.INTERVAL_ATTRIBUTE, definition.RepInterval)
	char:SetAttribute(PoseConfig.POSE_ATTRIBUTE, definition.PoseId)
	PosePreview.look(id)
	return `mounted {id} — pose {pose.Id} at {definition.RepInterval}s per rep`
end

function PosePreview.release()
	local char = character()
	char:SetAttribute(PoseConfig.POSE_ATTRIBUTE, nil)
	local root = char:FindFirstChild("HumanoidRootPart")
	if root then
		root.Anchored = false
	end
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "released"
end

--[[
	Mounts a machine, watches a full rep, and reports the two numbers that say
	whether the body and the machine agree.
]]
function PosePreview.measure(id)
	local mounted = PosePreview.mount(id)
	if string.find(mounted, "no station") then
		return mounted
	end
	local station = stations()[id]
	local equipmentId = station:GetAttribute("EquipmentId")
	local char = character()

	local grips, support = {}, nil
	for _, part in station:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 0.95 then
			if part.Name == SUPPORT[equipmentId] then
				support = part
			end
			for _, word in GRIP_WORDS do
				if string.find(part.Name, word) then
					table.insert(grips, part)
					break
				end
			end
		end
	end

	task.wait(SETTLE)
	local handGap, gripName = math.huge, "-"
	local lowest, lowestPart = math.huge, "-"
	local finish = os.clock() + WATCH
	while os.clock() < finish do
		for _, hand in { "RightHand", "LeftHand" } do
			local part = char:FindFirstChild(hand)
			if part then
				for _, grip in grips do
					local gap = gapTo(part, grip)
					if gap < handGap then
						handGap, gripName = gap, grip.Name
					end
				end
			end
		end
		for _, part in char:GetDescendants() do
			if part:IsA("BasePart") then
				local bottom = part.Position.Y - part.Size.Y / 2
				if bottom < lowest then
					lowest, lowestPart = bottom, part.Name
				end
			end
		end
		RunService.Heartbeat:Wait()
	end

	local clearance = if support then lowest - (support.Position.Y + support.Size.Y / 2) else nil
	return ("%-16s handGap=%s (%s)  clearance=%s  lowest=%s"):format(
		equipmentId,
		if carriesProp(station) then "  held" else ("%6.2f"):format(handGap),
		gripName,
		if clearance then ("%+6.2f vs %s"):format(clearance, SUPPORT[equipmentId]) else "   n/a",
		lowestPart
	)
end

--[[
	Every machine in turn. Takes about three minutes and moves you around the map.
]]
function PosePreview.audit()
	local seen, ids = {}, {}
	for _, station in stations() do
		local travelId = station:GetAttribute("TravelId")
		if not seen[travelId] then
			seen[travelId] = true
			table.insert(ids, station:GetAttribute("EquipmentId"))
		end
	end
	table.sort(ids)

	local rows = {}
	for _, id in ids do
		table.insert(rows, PosePreview.measure(id))
	end
	PosePreview.release()
	table.sort(rows)
	print(table.concat(rows, "\n"))
	return `audited {#rows} machines`
end

-- The one global. A command-bar tool has nowhere else to live between runs.
-- selene: allow(global_usage)
_G.PosePreview = PosePreview

print([[PosePreview ready (Play mode only — Edit does not step physics, so poses do not apply):
  PosePreview.mount("BenchPress")    stand on the machine, posing
  PosePreview.measure("BenchPress")  one machine, with numbers
  PosePreview.audit()                every machine, one line each
  PosePreview.release()              get off]])

return PosePreview
