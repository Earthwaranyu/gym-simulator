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
-- Keep these values ten studs inside the generated WorldBoundary. The current
-- coastal city is offset from the origin, so clamping around (0, 0) creates an
-- invisible wall through the middle of the map and snaps valid fast-travel
-- arrivals back into the old world footprint.
MovementConfig.FLIGHT_WORLD_CENTER_X = 7600
MovementConfig.FLIGHT_WORLD_CENTER_Z = -4000
MovementConfig.FLIGHT_WORLD_HALF_WIDTH = 8790
MovementConfig.FLIGHT_WORLD_HALF_DEPTH = 5790

-- Seconds after taking a hit before a player may take off again. The same span as
-- TrainingService's stagger, so one punch buys an attacker one window in which the
-- victim can neither train nor escape.
MovementConfig.FLIGHT_COMBAT_LOCK = 3

-- Attribute the server writes on a character: true only while that player is
-- allowed to be in the air. The client refuses to fly without it, and it is
-- recomputed on power, on damage, and on mounting a machine.
MovementConfig.FLIGHT_ATTRIBUTE = "FlightAllowed"

-- C is the dash. It used to be Q, which was the most comfortable key left next to
-- WASD — and that is exactly why the abilities took it: Ground Slam is pressed in a
-- fight several times a minute and dash, being a movement move, is pressed with the
-- hand already resting there either way. C is the next key over and stays reachable
-- without leaving WASD.
--
-- Flight has no key of its own: double-tapping jump both takes off and lands, which
-- is the gesture players try first anyway. E is mount, M is the menu, Tab is the
-- player list, and Q/R/F are the three combat abilities in AbilityConfig.
MovementConfig.DASH_KEY = Enum.KeyCode.C
MovementConfig.ASCEND_KEY = Enum.KeyCode.Space
-- Shift toggles the ground sprint: press once to run, again to stop. Held sprint is
-- the usual convention, but this game expects a player to cross a whole archipelago
-- on foot, and a key held down for minutes at a time is a thumb cramp rather than a
-- control. Control descends in flight so the two actions do not fight over one input
-- when a player takes off during a run.
MovementConfig.SPRINT_KEY = Enum.KeyCode.LeftShift
MovementConfig.DESCEND_KEY = Enum.KeyCode.LeftControl

-- Double-tapping jump takes off and double-tapping again lands, which is the gesture
-- most flight games use and the one players try before reading any control list. Long
-- enough that a deliberate double-tap lands inside it, short enough that two ordinary
-- jumps in a row do not.
MovementConfig.DOUBLE_TAP_SECONDS = 0.32

-- The longest a press may be held and still count as a *tap*.
--
-- This is what lets the same key both land the player and climb. In the air, Space
-- held is the ascend control, and a player pumping it to gain height must not fall
-- out of the sky for it. A climb is a hold; a landing gesture is two quick taps. Only
-- a press shorter than this arms the second half of a double-tap.
MovementConfig.TAP_HOLD_SECONDS = 0.2

-- The dash: a short flat burst in whatever direction you are already asking for.
--
-- Speed is a flat number rather than Legs-scaled on purpose. Sprint and flight are
-- both paced by Legs, so they are the stat's reward; a dash is a fixed escape and a
-- fixed gap-closer, and one that got longer as the attacker trained would make the
-- PvP hook worse the further into the game you got.
MovementConfig.DASH_SPEED = 78
MovementConfig.DASH_SECONDS = 0.22
MovementConfig.DASH_COOLDOWN = 1.1
-- A dash that only went where you were already walking would be useless standing
-- still, so a still player dashes the way they are facing.
--
-- Dash reuses the flight permission attribute rather than inventing its own. The
-- reasons a player may not fly are the same reasons they may not dash: they are
-- bolted to a machine, or they have just been hit. Being punched grounding you is
-- the whole reason the training interrupt costs the victim anything, and a dash
-- would be a way out of it.

-- How hard the flier is held upright and pointed where it is going. High enough that
-- a collision cannot start the rig tumbling, which is what PlatformStand alone allows:
-- with the humanoid's own stabilisation off and nothing replacing it, a clipped corner
-- sets the character spinning and nothing ever damps it out.
MovementConfig.FLIGHT_ORIENT_RESPONSIVENESS = 40

-- How fast the bank angle chases the turn it is reacting to. Much slower than
-- FLIGHT_ORIENT_RESPONSIVENESS above, and deliberately so: the heading should snap to
-- where the player is pointing, while the roll into and out of a turn is the part the
-- eye reads as weight. Matching the two makes the body twitch on every camera nudge.
MovementConfig.FLIGHT_BANK_RESPONSIVENESS = 5

return MovementConfig
