--!strict
--[[
	EquipmentConfig — every training machine in the game.

	Adding a machine is one entry here plus a model in Studio. No code changes: the
	server binds behaviour by CollectionService tag, and the client reads the same
	config for its labels and poses.

	Placing a machine in Studio:
	  1. Build the model (scripts/build_gym.py generates the ones that ship).
	  2. Tag it "TrainingStation" (CollectionService).
	 3. Set a string attribute "EquipmentId" to one of the ids below.
	 4. Set a unique string attribute "TravelId" if it should appear on the map.
	 5. Give it at least one part named "TrainAnchor".

	A single shared tag plus an attribute — rather than a tag per machine — means new
	equipment never needs a new tag registered anywhere.

	The parts a station model is expected to contain:

	  * TrainAnchor (required, one or more). Each is one training spot, and its
	    CFrame is used verbatim as the player's HumanoidRootPart CFrame. That is the
	    whole contract: the anchor decides where a player stands and how they are
	    oriented, so a bench lays them on their back and a bar leaves them hanging,
	    with no per-machine code. More than one anchor means more than one player can
	    use the machine at once.
	  * HeldBoth / HeldRight / HeldLeft (optional). Weights the lifter picks up. Put
	    them beside a TrainAnchor — inside a "Spot" model holding both — and while
	    somebody trains on that anchor the part tracks their hands: HeldBoth spans
	    both (a barbell), HeldRight and HeldLeft take one each (dumbbells). Author
	    them where they belong at rest, racked or on the shelf, because that is where
	    they sit whenever the spot is empty. Without this a lifter mimes the exercise
	    under a weight that never moves.
	  * TrainExit (optional). Where a player is put down when they leave. Without
	    one they stand up where they trained, which on some machines means standing
	    inside it.
	  * Base (optional). The part billboards adorn and the prompt hangs off. Falls
	    back to any part in the model, which is fine but can pick an odd one.
]]

local Types = require(script.Parent.Types)

export type EquipmentDefinition = {
	Id: Types.EquipmentId,
	DisplayName: string,
	-- Which body-part family this machine belongs to. Variants share a family even
	-- though each keeps its own id, geometry, pace, and procedural pose.
	ExerciseFamily: Types.StatId,
	-- Which stat reps on this machine train.
	StatId: Types.StatId,
	-- Stat awarded per rep before multipliers. Tiers scale this exponentially, which
	-- is where the billions and trillions actually come from.
	BaseGain: number,
	-- Seconds between reps. Also the period of one cycle of the pose below, so the
	-- animation and the stat ticks stay in step without being wired together.
	RepInterval: number,
	-- Total power needed before this machine can be used. 0 is the starter machine.
	UnlockPower: number,
	-- Which PoseConfig entry plays while training here. Poses are shared: an incline
	-- bench and a flat bench can both press.
	PoseId: string,
	-- Verb shown on the proximity prompt, e.g. "Bench" -> "Hold E to Bench".
	ActionText: string,
}

-- The shared tag every station carries.
local STATION_TAG = "TrainingStation"
-- The attribute naming which definition a tagged model uses.
local ID_ATTRIBUTE = "EquipmentId"
-- Unique map/travel destination id on generated stations.
local TRAVEL_ATTRIBUTE = "TravelId"

-- Names the server looks for inside a station model.
local ANCHOR_NAME = "TrainAnchor"
local EXIT_NAME = "TrainExit"
local BASE_NAME = "Base"

-- Weights that follow a lifter's hands, found beside the anchor they belong to.
-- Keyed by which hand carries them, which is all the client needs to place them.
local HELD_NAMES: { [string]: string } = {
	Both = "HeldBoth",
	Right = "HeldRight",
	Left = "HeldLeft",
}

-- ObjectValue the server puts in a training character, pointing at the anchor they
-- are on. Held props hang off that anchor, and an ObjectValue is used because an
-- attribute cannot hold an instance reference.
local ANCHOR_VALUE_NAME = "TrainingAnchor"

-- Attributes the server writes back onto a station so clients can label it
-- without asking. Set on the model, so they replicate like any other attribute.
local OCCUPANCY_ATTRIBUTE = "TrainingOccupancy"
local CAPACITY_ATTRIBUTE = "TrainingCapacity"

-- How long E must be held to mount. Long enough that it is a deliberate act and
-- not something you trip over walking past; short enough not to feel sticky.
local PROMPT_HOLD_SECONDS = 0.45
-- How close a player must be for the prompt to appear and to fire.
local PROMPT_DISTANCE = 14

local definitions: { EquipmentDefinition } = {
	{
		Id = "BenchPress",
		DisplayName = "Bench Press",
		ExerciseFamily = "Chest",
		StatId = "Chest",
		BaseGain = 10,
		RepInterval = 0.9,
		UnlockPower = 0,
		PoseId = "BenchPress",
		ActionText = "Bench",
	},
	{
		Id = "Dumbbells",
		DisplayName = "Dumbbell Rack",
		ExerciseFamily = "Arms",
		StatId = "Arms",
		BaseGain = 8,
		RepInterval = 0.7,
		UnlockPower = 0,
		PoseId = "Curl",
		ActionText = "Curl",
	},
	{
		Id = "PullUpBar",
		DisplayName = "Pull-Up Bar",
		ExerciseFamily = "Back",
		StatId = "Back",
		BaseGain = 12,
		RepInterval = 1.1,
		UnlockPower = 0,
		PoseId = "PullUp",
		ActionText = "Pull Up",
	},
	{
		Id = "SitUpBench",
		DisplayName = "Ab Bench",
		ExerciseFamily = "Core",
		StatId = "Core",
		BaseGain = 9,
		RepInterval = 0.8,
		UnlockPower = 0,
		PoseId = "SitUp",
		ActionText = "Sit Up",
	},
	{
		Id = "Treadmill",
		DisplayName = "Treadmill",
		ExerciseFamily = "Legs",
		StatId = "Legs",
		BaseGain = 5.5,
		RepInterval = 0.5,
		UnlockPower = 0,
		PoseId = "Run",
		ActionText = "Run",
	},
	{
		Id = "BarbellCurl",
		DisplayName = "Barbell Curl Rack",
		ExerciseFamily = "Arms",
		StatId = "Arms",
		BaseGain = 10.25,
		RepInterval = 0.9,
		UnlockPower = 0,
		PoseId = "BarbellCurl",
		ActionText = "Curl",
	},
	{
		Id = "TricepsPushdown",
		DisplayName = "Triceps Pushdown",
		ExerciseFamily = "Arms",
		StatId = "Arms",
		BaseGain = 9.15,
		RepInterval = 0.8,
		UnlockPower = 0,
		PoseId = "TricepsPushdown",
		ActionText = "Push Down",
	},
	{
		Id = "InclinePress",
		DisplayName = "Incline Dumbbell Press",
		ExerciseFamily = "Chest",
		StatId = "Chest",
		BaseGain = 11.1,
		RepInterval = 1,
		UnlockPower = 0,
		PoseId = "InclinePress",
		ActionText = "Press",
	},
	{
		Id = "PecDeck",
		DisplayName = "Pec Deck",
		ExerciseFamily = "Chest",
		StatId = "Chest",
		BaseGain = 9.45,
		RepInterval = 0.85,
		UnlockPower = 0,
		PoseId = "PecDeck",
		ActionText = "Fly",
	},
	{
		Id = "SeatedRow",
		DisplayName = "Seated Cable Row",
		ExerciseFamily = "Back",
		StatId = "Back",
		BaseGain = 10.9,
		RepInterval = 1,
		UnlockPower = 0,
		PoseId = "SeatedRow",
		ActionText = "Row",
	},
	{
		Id = "LatPulldown",
		DisplayName = "Lat Pulldown",
		ExerciseFamily = "Back",
		StatId = "Back",
		BaseGain = 11.45,
		RepInterval = 1.05,
		UnlockPower = 0,
		PoseId = "LatPulldown",
		ActionText = "Pull Down",
	},
	{
		Id = "KneeRaise",
		DisplayName = "Captain's Chair",
		ExerciseFamily = "Core",
		StatId = "Core",
		BaseGain = 10.7,
		RepInterval = 0.95,
		UnlockPower = 0,
		PoseId = "KneeRaise",
		ActionText = "Raise Knees",
	},
	{
		Id = "TorsoTwist",
		DisplayName = "Torso Rotation",
		ExerciseFamily = "Core",
		StatId = "Core",
		BaseGain = 8.45,
		RepInterval = 0.75,
		UnlockPower = 0,
		PoseId = "TorsoTwist",
		ActionText = "Twist",
	},
	{
		Id = "SquatRack",
		DisplayName = "Squat Rack",
		ExerciseFamily = "Legs",
		StatId = "Legs",
		BaseGain = 12.1,
		RepInterval = 1.1,
		UnlockPower = 0,
		PoseId = "SquatRack",
		ActionText = "Squat",
	},
	{
		Id = "LegPress",
		DisplayName = "Seated Leg Press",
		ExerciseFamily = "Legs",
		StatId = "Legs",
		BaseGain = 11,
		RepInterval = 1,
		UnlockPower = 0,
		PoseId = "LegPress",
		ActionText = "Leg Press",
	},
}

local EquipmentConfig = {}

EquipmentConfig.List = definitions
EquipmentConfig.STATION_TAG = STATION_TAG
EquipmentConfig.ID_ATTRIBUTE = ID_ATTRIBUTE
EquipmentConfig.TRAVEL_ATTRIBUTE = TRAVEL_ATTRIBUTE
EquipmentConfig.ANCHOR_NAME = ANCHOR_NAME
EquipmentConfig.EXIT_NAME = EXIT_NAME
EquipmentConfig.BASE_NAME = BASE_NAME
EquipmentConfig.HELD_NAMES = HELD_NAMES
EquipmentConfig.ANCHOR_VALUE_NAME = ANCHOR_VALUE_NAME
EquipmentConfig.OCCUPANCY_ATTRIBUTE = OCCUPANCY_ATTRIBUTE
EquipmentConfig.CAPACITY_ATTRIBUTE = CAPACITY_ATTRIBUTE
EquipmentConfig.PROMPT_HOLD_SECONDS = PROMPT_HOLD_SECONDS
EquipmentConfig.PROMPT_DISTANCE = PROMPT_DISTANCE

local byId: { [Types.EquipmentId]: EquipmentDefinition } = {}
for _, definition in definitions do
	if byId[definition.Id] ~= nil then
		error(`[EquipmentConfig] Duplicate equipment id "{definition.Id}"`)
	end
	byId[definition.Id] = definition
end

function EquipmentConfig.Get(equipmentId: Types.EquipmentId): EquipmentDefinition?
	return byId[equipmentId]
end

--[[
	Resolves the definition a tagged station model refers to, or nil with a reason if
	the model is misconfigured. Returning the reason lets the server log something a
	level designer can act on instead of failing silently.
]]
function EquipmentConfig.Resolve(station: Instance): (EquipmentDefinition?, string?)
	local equipmentId = station:GetAttribute(ID_ATTRIBUTE)

	if equipmentId == nil then
		return nil, `missing "{ID_ATTRIBUTE}" attribute`
	end
	if type(equipmentId) ~= "string" then
		return nil, `"{ID_ATTRIBUTE}" must be a string, got {typeof(equipmentId)}`
	end

	local definition = byId[equipmentId]
	if definition == nil then
		return nil, `no equipment defined with id "{equipmentId}"`
	end

	return definition, nil
end

--[[
	Every training spot on a station, in a stable order.

	Sorted by position rather than left in child order, because the index into this
	list is how an occupied spot is identified: if the order shifted, a player would
	be recorded as standing somewhere they are not.
]]
function EquipmentConfig.GetAnchors(station: Instance): { BasePart }
	local anchors: { BasePart } = {}

	for _, descendant in station:GetDescendants() do
		if descendant.Name == ANCHOR_NAME and descendant:IsA("BasePart") then
			table.insert(anchors, descendant)
		end
	end

	table.sort(anchors, function(a: BasePart, b: BasePart): boolean
		local pa, pb = a.Position, b.Position
		if pa.X ~= pb.X then
			return pa.X < pb.X
		end
		if pa.Y ~= pb.Y then
			return pa.Y < pb.Y
		end
		return pa.Z < pb.Z
	end)

	return anchors
end

--[[
	The part billboards and prompts attach to: the one named "Base" if the model has
	one, otherwise any part, so a hastily-built machine still works.
]]
function EquipmentConfig.GetBase(station: Instance): BasePart?
	if station:IsA("BasePart") then
		return station
	end

	local named = station:FindFirstChild(BASE_NAME)
	if named ~= nil and named:IsA("BasePart") then
		return named
	end

	if station:IsA("Model") and station.PrimaryPart ~= nil then
		return station.PrimaryPart
	end

	return station:FindFirstChildWhichIsA("BasePart", true)
end

return EquipmentConfig
