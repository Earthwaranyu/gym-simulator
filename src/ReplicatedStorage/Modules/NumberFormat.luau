--!strict
--[[
	NumberFormat — abbreviates the huge stat values this game deals in.

	Stats climb into the billions and trillions and well past, so raw numbers are
	unreadable in UI. Format() turns 1_250_000_000 into "1.25B".

	Precision note: Luau numbers are f64, exact only up to 2^53 (~9.0e15). Past that,
	values are approximations — fine for display, which is all this module is for.
	Never round-trip a stat through Format() and back.

	Adding headroom means appending to SUFFIXES. Nothing else changes.
]]

local NumberFormat = {}

-- Index n covers 1000^(n+1). Standard simulator short-scale abbreviations.
local SUFFIXES: { string } = {
	"K", -- 1e3   thousand
	"M", -- 1e6   million
	"B", -- 1e9   billion
	"T", -- 1e12  trillion
	"Qd", -- 1e15  quadrillion
	"Qn", -- 1e18  quintillion
	"Sx", -- 1e21  sextillion
	"Sp", -- 1e24  septillion
	"Oc", -- 1e27  octillion
	"No", -- 1e30  nonillion
	"Dc", -- 1e33  decillion
	"UDc", -- 1e36  undecillion
	"DDc", -- 1e39  duodecillion
	"TDc", -- 1e42  tredecillion
	"QaDc", -- 1e45  quattuordecillion
	"QnDc", -- 1e48  quindecillion
	"SxDc", -- 1e51  sexdecillion
	"SpDc", -- 1e54  septendecillion
	"OcDc", -- 1e57  octodecillion
	"NoDc", -- 1e60  novemdecillion
	"Vg", -- 1e63  vigintillion
}

local THRESHOLD = 1000

--[[
	Trims trailing zeros so we show "1.2K" rather than "1.20K", but keep "1.25K".
]]
local function trim(text: string): string
	if not text:find("%.") then
		return text
	end
	text = text:gsub("0+$", "")
	text = text:gsub("%.$", "")
	return text
end

--[[
	Abbreviates a number for display: 1250 -> "1.25K", 1.5e12 -> "1.5T".

	`decimals` defaults to 2. Values below 1000 are shown whole, since fractional
	reps and stats are noise to the player.
]]
function NumberFormat.Format(value: number, decimals: number?): string
	if value ~= value then
		return "NaN"
	end
	if value == math.huge then
		return "∞"
	end
	if value == -math.huge then
		return "-∞"
	end

	local sign = if value < 0 then "-" else ""
	local magnitude = math.abs(value)

	if magnitude < THRESHOLD then
		return sign .. tostring(math.floor(magnitude))
	end

	local places = decimals or 2
	local tier = math.floor(math.log(magnitude, THRESHOLD))
	tier = math.clamp(tier, 1, #SUFFIXES)

	local scaled = magnitude / THRESHOLD ^ tier

	-- Round first, then check: 999_999 scales to 999.999, which only reaches the next
	-- tier once rounded. Without this it renders "1000K" instead of "1M". The same
	-- promotion also absorbs log() drift on exact powers (log(1e9, 1000) = 2.999...).
	local rounded = tonumber(string.format(`%.{places}f`, scaled)) :: number
	if rounded >= THRESHOLD and tier < #SUFFIXES then
		tier += 1
		scaled = magnitude / THRESHOLD ^ tier
	end

	local mantissa = trim(string.format(`%.{places}f`, scaled))
	return `{sign}{mantissa}{SUFFIXES[tier]}`
end

--[[
	Full number with thousands separators: 1234567 -> "1,234,567".
	For tooltips and detail panels where the exact figure matters.
]]
function NumberFormat.Comma(value: number): string
	local sign = if value < 0 then "-" else ""
	local whole = tostring(math.floor(math.abs(value)))

	local formatted = whole
	while true do
		local replaced: number
		formatted, replaced = formatted:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end

	return sign .. formatted
end

--[[
	"1.25B / 4B" style pairs for progress rows.
]]
function NumberFormat.Ratio(current: number, goal: number): string
	return `{NumberFormat.Format(current)} / {NumberFormat.Format(goal)}`
end

--[[
	Seconds as mm:ss (or h:mm:ss past an hour) for cooldowns and boost timers.
]]
function NumberFormat.Duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours = seconds // 3600
	local minutes = (seconds % 3600) // 60
	local secs = seconds % 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

--[[
	Self-test, run from the server bootstrap in Studio only. Returns the list of
	failures so a caller can decide how loud to be about them.
]]
function NumberFormat.RunSelfTest(): { string }
	local failures: { string } = {}

	local function expect(label: string, got: string, want: string)
		if got ~= want then
			table.insert(failures, `{label}: got "{got}", expected "{want}"`)
		end
	end

	expect("zero", NumberFormat.Format(0), "0")
	expect("sub-thousand", NumberFormat.Format(999), "999")
	expect("floors fractions", NumberFormat.Format(12.7), "12")
	expect("exact thousand", NumberFormat.Format(1000), "1K")
	expect("trims zeros", NumberFormat.Format(1200), "1.2K")
	expect("keeps precision", NumberFormat.Format(1250), "1.25K")
	expect("million", NumberFormat.Format(5.5e6), "5.5M")
	expect("billion", NumberFormat.Format(1.25e9), "1.25B")
	expect("trillion", NumberFormat.Format(9.99e12), "9.99T")
	expect("quadrillion", NumberFormat.Format(3e15), "3Qd")
	expect("negative", NumberFormat.Format(-2500), "-2.5K")
	expect("tier boundary rounds up", NumberFormat.Format(999999), "1M")
	expect("exact power of 1000", NumberFormat.Format(1e9), "1B")
	expect("decimals arg", NumberFormat.Format(1234, 1), "1.2K")
	expect("top of table", NumberFormat.Format(1e63), "1Vg")

	expect("comma", NumberFormat.Comma(1234567), "1,234,567")
	expect("comma small", NumberFormat.Comma(999), "999")
	expect("comma negative", NumberFormat.Comma(-45678), "-45,678")

	expect("duration", NumberFormat.Duration(75), "1:15")
	expect("duration hours", NumberFormat.Duration(3725), "1:02:05")

	return failures
end

return NumberFormat
