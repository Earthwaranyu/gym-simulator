--!strict
--[[
	QuestCycleConfig — how the three-step quest rotation grows.

	The whole quest system is one loop: train the upper body, train the lower body,
	kill monsters, repeat forever. That works only if the numbers keep pace with a game
	whose stats reach the trillions, so goals and rewards both scale with the loop
	number rather than sitting still.

	Growth is geometric but far gentler than stat growth, which is deliberate. Stats
	multiply by zone (x1 to x64) and by token multipliers on top; if quest goals grew at
	that rate they would be impossible, and if they were flat they would be free after
	an hour. Growing at 1.6x a loop means an early rotation takes a few minutes and a
	very late one takes a session, which is the pacing a repeating quest wants.

	The kill step grows more slowly than the training steps, because a kill costs travel
	and a fight rather than time on a machine. Twelve goblins is a chore; the curve is
	tuned so it reaches that only after many rotations.
]]

local QuestCycleConfig = {}

export type StepKind = "Upper" | "Lower" | "Mobs"

-- What loop zero asks for.
local BASE_GOAL: { [StepKind]: number } = {
	Upper = 500,
	Lower = 500,
	Mobs = 5,
}

-- Multiplier applied per completed rotation.
local GOAL_GROWTH: { [StepKind]: number } = {
	Upper = 1.6,
	Lower = 1.6,
	Mobs = 1.25,
}

-- Tokens paid by the first rotation's steps, and how that grows. Rewards grow more
-- slowly than goals on purpose: the cycle is a steady trickle beside idle accrual, not
-- a replacement for it.
local BASE_REWARD = 10
local REWARD_GROWTH = 1.35
-- Past this many rotations the curves stop compounding. Without it a player deep into
-- the loop count would face goals that overflow anything readable, and rewards that
-- dwarf every other source in the game.
local MAX_SCALED_LOOP = 40

local function scaled(base: number, growth: number, loop: number): number
	local capped = math.clamp(math.floor(loop), 0, MAX_SCALED_LOOP)
	return math.floor(base * growth ^ capped)
end

--[[
	How much of a step is needed on a given zero-based loop.
]]
function QuestCycleConfig.Goal(kind: StepKind, loop: number): number
	return math.max(1, scaled(BASE_GOAL[kind], GOAL_GROWTH[kind], loop))
end

--[[
	Tokens paid for finishing any step on a given zero-based loop.
]]
function QuestCycleConfig.Reward(loop: number): number
	return math.max(1, scaled(BASE_REWARD, REWARD_GROWTH, loop))
end

function QuestCycleConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	check(QuestCycleConfig.Goal("Upper", 0) == 500, "loop zero asks for the base upper-body goal")
	check(QuestCycleConfig.Goal("Mobs", 0) == 5, "loop zero asks for five kills")
	check(QuestCycleConfig.Reward(0) == 10, "loop zero pays the base reward")

	check(
		QuestCycleConfig.Goal("Upper", 1) > QuestCycleConfig.Goal("Upper", 0),
		"goals grow between rotations"
	)
	check(QuestCycleConfig.Reward(1) > QuestCycleConfig.Reward(0), "rewards grow between rotations")
	check(
		QuestCycleConfig.Goal("Mobs", 5) < QuestCycleConfig.Goal("Upper", 5),
		"the kill step stays a smaller number than the training steps"
	)

	-- The cap is what keeps a very long-lived save from producing unreadable numbers.
	check(
		QuestCycleConfig.Goal("Upper", MAX_SCALED_LOOP)
			== QuestCycleConfig.Goal("Upper", MAX_SCALED_LOOP + 25),
		"goals stop compounding past the cap"
	)
	check(
		QuestCycleConfig.Reward(MAX_SCALED_LOOP) == QuestCycleConfig.Reward(MAX_SCALED_LOOP + 25),
		"rewards stop compounding past the cap"
	)

	-- Negative or fractional loop counts can only come from a corrupt save, and must
	-- degrade to the base goal rather than to zero or an error.
	check(QuestCycleConfig.Goal("Lower", -3) == 500, "a negative loop count clamps to the base goal")

	return failures
end

return QuestCycleConfig
