--!strict
--[[
	MovementConfig — the walk-run-fly ladder, as data.

	Walking is the stable floor, Shift sprinting is Legs (Formulas.SprintSpeed), and
	flying is available from spawn but paced by Legs (Formulas.FlightSpeed). Walkable
	water links the bridge-free islands, while flying remains the faster route.

	Flight is deliberately not free of the game's rules. A player who could take off
	the instant a fight started would make the training interrupt meaningless — being
	knocked off a machine only costs something if the attacker can follow up. So
	taking a hit grounds you for a few seconds, and you cannot fly while locked to a
	machine.
]]

local MovementConfig = {}

-- Flight is available from the first spawn. Total power still controls progression
-- and travel destinations, while Legs controls how quickly each player flies.
MovementConfig.FLIGHT_POWER = 0

-- How fast the flier settles into a new direction. Low enough to feel like a body
-- with mass rather than a camera.
MovementConfig.FLIGHT_ACCELERATION = 14
-- Vertical movement is intentionally slower than level flight for readable landings.
MovementConfig.FLIGHT_CLIMB_RATIO = 0.62

-- The generated ocean is a solid traversal surface. Keep a flying root one standing
-- character-height above it, and inside the physical perimeter, even when the camera
-- is aimed steeply down or out of the world. The persistent collision geometry is the
-- authoritative safety net; these limits prevent the client mover from fighting it.
MovementConfig.WATER_SURFACE_Y = -7.5
MovementConfig.FLIGHT_WATER_CLEARANCE = 3
MovementConfig.FLIGHT_WORLD_HALF_WIDTH = 4790
MovementConfig.FLIGHT_WORLD_HALF_DEPTH = 4290

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
-- Shift is the ground sprint key. Control descends in flight so the two actions do
-- not fight over one input when a player takes off during a run.
MovementConfig.SPRINT_KEY = Enum.KeyCode.LeftShift
MovementConfig.DESCEND_KEY = Enum.KeyCode.LeftControl

-- Double-tapping jump also takes off, which is the gesture most flight games use and
-- the one players try before reading any control list. Long enough that a deliberate
-- double-tap lands inside it, short enough that two ordinary jumps in a row do not.
MovementConfig.DOUBLE_TAP_SECONDS = 0.32

-- How hard the flier is held upright and pointed where it is going. High enough that
-- a collision cannot start the rig tumbling, which is what PlatformStand alone allows:
-- with the humanoid's own stabilisation off and nothing replacing it, a clipped corner
-- sets the character spinning and nothing ever damps it out.
MovementConfig.FLIGHT_ORIENT_RESPONSIVENESS = 40

return MovementConfig
