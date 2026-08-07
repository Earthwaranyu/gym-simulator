--!strict
--[[
	MovementConfig — the walk-run-fly ladder, as data.

	Walking is the floor, running is Legs (see Formulas.WalkSpeed), and flying is
	bought with total power. The map is built so the three rungs and the tier ladder
	are the same climb: the first three platforms stand on the ground, and everything
	past them floats higher and higher, so unlocking flight is what opens the back
	half of the world.

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

-- Studs per second, level flight. Roughly twice a maxed runner, because the outer
-- tiers are hundreds of studs up and nobody should climb that at walking pace.
MovementConfig.FLIGHT_SPEED = 220
-- How fast the flier settles into a new direction. Low enough to feel like a body
-- with mass rather than a camera.
MovementConfig.FLIGHT_ACCELERATION = 14
-- Vertical speed from the ascend/descend keys.
MovementConfig.FLIGHT_CLIMB_SPEED = 130

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
