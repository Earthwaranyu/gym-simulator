--!strict
--[[
	MovementConfig — the walk-run-fly ladder, as data.

	Walking is the floor, running is Legs (Formulas.WalkSpeed), and flying is bought
	with total power and then *also* paced by Legs (Formulas.FlightSpeed). The map is
	built so the three rungs and the tier ladder are the same climb: the first three
	districts stand on the ground, and everything past them floats higher and higher,
	so unlocking flight is what opens the back half of the world.

	Note the split: total power decides WHETHER you fly, Legs decides HOW FAST. The
	gate is matched to how high the districts float and belongs to the map; the speed
	is a stat and belongs to the player.

	Flight is deliberately not free of the game's rules. A player who could take off
	the instant a fight started would make the training interrupt meaningless — being
	knocked off a machine only costs something if the attacker can follow up. So
	taking a hit grounds you for a few seconds, and you cannot fly while locked to a
	machine.
]]

local MovementConfig = {}

-- Total power before a player may fly at all. Sits just under the fourth tier's
-- gate, so flight arrives exactly when the platforms start leaving the ground.
MovementConfig.FLIGHT_POWER = 8e6

-- How fast the flier settles into a new direction. Low enough to feel like a body
-- with mass rather than a camera.
MovementConfig.FLIGHT_ACCELERATION = 14
-- Vertical speed as a share of level flight. Climbing used to be a flat 130
-- against a flat 220; keeping it a ratio means it follows Legs along with
-- everything else instead of becoming the slow part of flying for a maxed player.
MovementConfig.FLIGHT_CLIMB_RATIO = 130 / 220

-- Seconds after taking a hit before a player may take off again. The same span as
-- TrainingService's stagger, so one punch buys an attacker one window in which the
-- victim can neither train nor escape.
MovementConfig.FLIGHT_COMBAT_LOCK = 3

-- Attribute the server writes on a character: true only while that player is
-- allowed to be in the air. The client refuses to fly without it, and it is
-- recomputed on power, on damage, and on mounting a machine.
MovementConfig.FLIGHT_ATTRIBUTE = "FlightAllowed"

-- Q, because F is Punch, E is mount, M is the menu and Tab is the player list.
MovementConfig.TOGGLE_KEY = Enum.KeyCode.Q
MovementConfig.ASCEND_KEY = Enum.KeyCode.Space
MovementConfig.DESCEND_KEY = Enum.KeyCode.LeftShift

return MovementConfig
