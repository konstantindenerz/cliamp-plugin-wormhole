-- Wormhole: a wireframe tunnel in Braille dots. Rings leave the mouth in the
-- middle, one per kick when the beat is steady, and grow past the edges.
-- Kick, snare and hi-hat each set off an effect.

local p = plugin.register({
    name = "wormhole",
    type = "visualizer",
    version = "1.0.0",
    description = "Wireframe tunnel that flies one ring per beat",
})

local abs, floor, max, min = math.abs, math.floor, math.max, math.min
local sin, cos, acos, exp, pi = math.sin, math.cos, math.acos, math.exp, math.pi

local BANDS = 10

-- The tunnel moves in steps of TICK seconds, however often cliamp draws.
local TICK = 0.025

local RINGS = 10
-- A ring shows at the mouth this many ring spacings after it starts.
local ENTRY = 1.5
local SHAPES = RINGS + 2 -- rings that keep their band levels
local FORMS = 4 -- cross-sections: circle, hexagon, square, star
local QUIET = 0.5 -- s of silence before the tunnel stops and holds its bend and twist
local SPARKS = 18
local WAVES = 4

-- Cell tiers, low to high; a cell shows the highest one drawn into it.
local DIM, TEXT, BEAT, HOT = 1, 2, 3, 4

-- Colors ----------------------------------------------------------------

local RESET = "\27[0m"

-- A color is a palette index (0-255) or "#rrggbb". The defaults are the
-- terminal's own gray, white, yellow and red.
local function sgr(value, fallback)
    local hex = value and value:match("^%s*#(%x%x%x%x%x%x)")
    if hex then
        return string.format("\27[38;2;%d;%d;%dm",
            tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
    end
    local n = tonumber(value and value:match("^%s*(%d+)") or "") or fallback
    if n < 8 then
        return "\27[" .. (30 + n) .. "m"
    elseif n < 16 then
        return "\27[" .. (82 + n) .. "m"
    end
    return "\27[38;5;" .. min(n, 255) .. "m"
end

-- conf reads a key of [plugins.wormhole] in config.toml.
local function conf(key)
    local value = p:config(key)
    return type(value) == "string" and value or nil
end

local COLOR = {
    [DIM] = sgr(conf("dim"), 7),
    [TEXT] = sgr(conf("text"), 15),
    [BEAT] = sgr(conf("beat"), 11),
    [HOT] = sgr(conf("hot"), 9),
}

-- cliamp hands a plugin the sound a little before it is heard. The tunnel
-- waits this long, in ticks, so a kick shows when it sounds.
local DELAY = tonumber((conf("delay_ms") or ""):match("^%s*(%d+)") or "") or 0
DELAY = min(40, floor(DELAY / (TICK * 1000) + 0.5))

-- State -----------------------------------------------------------------

local s

local function filled(n, v)
    local t = {}
    for i = 1, n do
        t[i] = v
    end
    return t
end

local function reset()
    s = {
        travel = 0, -- laps
        speed = 0, -- laps/s
        loud = 0,
        clock = 0, -- playback seconds, frozen while paused
        bendPhase = 0,
        twist = 0,
        playing = false,
        deaf = 0, -- s left without hits
        hasPrev = false,
        -- Tempo: kick gaps and beat period in s (0 = none yet), confidence 0..1.
        counted = 0,
        lastKick = -math.huge,
        beat = 0,
        sure = 0,
        spiral = 0,
        tone = 0,
        toneLo = 1,
        toneHi = 0,
        form = 0,
        formShift = 0,
        jump = 0,
        fastE = 0,
        slowE = 0,
        warpAt = -math.huge,
        warp = 0,
        starTravel = 0,
        heard = 0, -- s of music since the last silence
        quiet = QUIET, -- s of silence
        nextWave = 1,
        rock = 0,
        rockTo = 0,
        rockSide = 1,
        struck = 0, -- sparks so far, also seeds the next spark's position
        born = floor(-ENTRY),
        lo = filled(BANDS, 1), -- start wide open
        hi = filled(BANDS, 0),
        glow = filled(BANDS, 0), -- live band levels
        prev = filled(BANDS, 0),
        typical = { 0, 0, 0 }, -- recent hit ratios
        gaps = {},
        waves = {},
        sparks = {},
        shapes = {}, -- the glow each ring had at the mouth
        heldBands = {}, -- the bands of the last DELAY ticks
        held = 0,
        lateBands = filled(BANDS, 0),
        lastBands = filled(BANDS, 0), -- the bands of the frame before
        midBands = filled(BANDS, 0),
        -- Kick, snare, hi-hat: a sudden rise across a share of the bands,
        -- judged against how much they usually rise. Gaps in ticks: at most
        -- 240 kicks a minute.
        onsets = {
            { from = 1, to = 3, k = 2.0, floor = 0.05, gap = 10 },
            { from = 4, to = 6, k = 2.0, floor = 0.04, gap = 8 },
            { from = 7, to = 10, k = 1.8, floor = 0.025, gap = 6 },
        },
    }
    for _, o in ipairs(s.onsets) do
        o.mean, o.dev, o.since = 0.03, 0.02, o.gap
    end
    for i = 1, WAVES do
        s.waves[i] = { at = 0, strength = 0 } -- strength 0 = unused
    end
    for i = 1, SPARKS do
        s.sparks[i] = { angle = 0, z = 0, at = -math.huge, travel = 0 }
    end
    for i = 0, SHAPES - 1 do
        s.shapes[i] = filled(BANDS, 0)
    end
    for i = 1, DELAY do
        s.heldBands[i] = filled(BANDS, 0)
    end
end

reset()

-- A fixed pseudo-random value in [0, 1) for item i, a different one per slot.
local function hash(i, slot)
    local x = sin(i * 12.9898 + slot * 78.233) * 43758.5453
    return x - floor(x)
end

local function round(x)
    if x < 0 then
        return -floor(0.5 - x)
    end
    return floor(x + 0.5)
end

-- Music ------------------------------------------------------------------

-- play runs the ticks of a frame of playback, rest one tick of a pause.
local play, rest

do
    -- Speed in laps/s (one lap = tunnel depth). Top speed keeps a frame under
    -- 1/4 ring spacing, or the rings seem to run backwards.
    local CRUISE = 0.15
    local LOUD_GAIN = 0.1
    local TOP_SPEED = 0.45

    -- Tempo: median of the last kick gaps, folded into 60..180 BPM.
    local GAPS = 8
    local FOLD_SLACK = TICK -- a kick lands a tick early or late
    local SURE_STEP = 0.25
    local SURE_WAIT = 2.0 -- s without a kick before the confidence fades
    local LOCK = 0.3 -- speed change per ring of phase error
    local LOCK_MAX = 0.15
    local TWIST_BEAT = 0.06 -- rad/s of wall rotation per beat/s
    local SPIRAL = 0.04 -- rad per unit of 1/z, per beat/s

    -- How fast the far end bends and the wall turns.
    local BEND_RATE = 0.08
    local BEND_LOUD = 0.25
    local TWIST = 0.05
    local TWIST_LOUD = 0.15

    -- The cross-section follows the tone against its recent range.
    local TONE_RELAX = 0.01
    local TONE_SPAN = 0.05

    -- Hyperspace: the short energy average jumps above the long one.
    local DROP_RATIO = 1.5
    local DROP_FLOOR = 0.12
    local DROP_GAP = 8.0 -- s between drops
    local DROP_WARM = 4.0 -- s of music before a drop counts
    local SILENCE = 0.02
    local DEAF = 0.3 -- s without hits while the bands rise again after a break
    local WARP_RISE = 0.15
    local WARP_FADE = 0.6
    local WARP_LIFE = 2.5
    local STAR_RATE = 3.0 -- laps/s of the star field at full warp

    -- A hit as strong as the recent ones gets this strength.
    local HIT_TYPICAL = 0.6
    -- Snare: rock the wall, alternating sides.
    local ROCK = 0.1
    -- Hi-hat: sparks in the top third of the wall, where the rings show the
    -- treble.
    local SPARK_HIT = 6
    local SPARK_NEAR = 0.2
    local SPARK_FAR = 0.5
    local SPARK_ARC = 2 * pi / 3

    -- Per-band min/max tracking.
    local BAND_RELAX = 0.08
    local BAND_SPAN = 0.12

    -- Share of the way to the target that one tick covers at rate r per second.
    local function per_tick(r)
        return 1 - exp(-r * TICK)
    end

    local K_SPEED, K_FALL, K_LOUD = per_tick(2.0), per_tick(2.5), per_tick(1.5)
    local K_GLOW_UP, K_GLOW_DOWN = per_tick(12), per_tick(6)
    local K_ROCK, K_SPIRAL = per_tick(14), per_tick(0.5)
    local K_TONE, K_FORM, K_SHIFT = per_tick(1), per_tick(0.4), per_tick(3)
    local K_FAST, K_SLOW = per_tick(4.0), per_tick(0.15)

    -- levels tracks each band against its own recent range and returns the
    -- overall loudness, 0..1.
    local function levels(bands)
        local lo, hi, glow = s.lo, s.hi, s.glow
        local loud = 0
        for i = 1, BANDS do
            local b = bands[i]
            hi[i] = max(b, hi[i] - BAND_RELAX * TICK)
            lo[i] = min(b, lo[i] + BAND_RELAX * TICK)
            local level = (b - lo[i]) / max(hi[i] - lo[i], BAND_SPAN)
            local g = glow[i]
            glow[i] = g + (level - g) * (level > g and K_GLOW_UP or K_GLOW_DOWN)
            loud = loud + level / BANDS
        end
        return loud
    end

    local function kick(strength)
        local wave = s.waves[s.nextWave]
        wave.at, wave.strength = s.clock, strength
        s.nextWave = s.nextWave % WAVES + 1

        local gap = s.clock - s.lastKick
        s.lastKick = s.clock
        if gap < 0.25 or gap > 2 then
            return -- no beat
        end
        -- Fold into 60..180 BPM.
        while gap < 60 / 180 - FOLD_SLACK do
            gap = gap * 2
        end
        while gap > 1 do
            gap = gap / 2
        end
        -- Confidence grows only while the kicks agree with the tempo.
        if s.beat == 0 or abs(gap - s.beat) < 0.1 * s.beat then
            s.sure = min(1, s.sure + SURE_STEP)
        else
            s.sure = max(0, s.sure - SURE_STEP / 2)
        end
        s.gaps[s.counted % GAPS + 1] = gap
        s.counted = s.counted + 1
        local sorted = {}
        for i = 1, min(s.counted, GAPS) do
            sorted[i] = s.gaps[i]
        end
        table.sort(sorted)
        s.beat = sorted[floor(#sorted / 2) + 1]
    end

    -- strike throws sparks at the top of the wall, where the rings show the
    -- treble. From there they turn with the wall.
    local function strike(strength)
        for _ = 1, max(1, round(strength * SPARK_HIT)) do
            local z = SPARK_NEAR + (SPARK_FAR - SPARK_NEAR) * hash(s.struck, 1)
            local top = -pi / 2 + (hash(s.struck, 0) - 0.5) * SPARK_ARC
            local spark = s.sparks[s.struck % SPARKS + 1]
            spark.angle = top - s.twist - s.rock - s.spiral / z
            spark.z, spark.at, spark.travel = z, s.clock, s.travel
            s.struck = s.struck + 1
        end
    end

    -- hits finds kick, snare and hi-hat as rises, not levels: a louder bass
    -- floor must not hide the kicks.
    local function hits(bands)
        local prev = s.prev
        if s.hasPrev then
            for part, o in ipairs(s.onsets) do
                local rise = 0
                for i = o.from, o.to do
                    rise = rise + max(0, bands[i] - prev[i])
                end
                local threshold = max(o.mean + o.k * o.dev, o.floor)
                local hit = rise > threshold and o.since + 1 >= o.gap
                o.mean = o.mean * 0.92 + rise * 0.08
                o.dev = o.dev * 0.92 + abs(rise - o.mean) * 0.08
                o.since = hit and 0 or o.since + 1
                if hit and s.deaf <= 0 then
                    -- Judge the hit against the recent ones, or every kick looks hard.
                    local ratio, usual = rise / threshold, s.typical[part]
                    local strength = HIT_TYPICAL
                    if usual > 0 then
                        strength = min(1, HIT_TYPICAL * ratio / usual)
                        s.typical[part] = usual + (ratio - usual) * 0.2
                    else
                        s.typical[part] = ratio
                    end
                    if part == 1 then
                        kick(strength)
                    elseif part == 2 then
                        s.rockTo, s.rockSide = s.rockSide * ROCK, -s.rockSide
                    else
                        strike(strength)
                    end
                end
            end
        end
        s.hasPrev = true
        for i = 1, BANDS do
            prev[i] = bands[i]
        end
    end

    -- morph picks the cross-section from the tone, 0 for all bass to 1 for all
    -- treble, against its recent range. Near silence has no tone.
    local function morph(bands, sum)
        if sum > 1e-3 then
            local moment = 0
            for i = 1, BANDS do
                moment = moment + (i - 1) * bands[i]
            end
            local tone = moment / sum / (BANDS - 1)
            if s.toneHi < s.toneLo then
                -- The first sound sets the range.
                s.tone, s.toneLo, s.toneHi = tone, tone, tone
            end
            s.tone = s.tone + (tone - s.tone) * K_TONE
            s.toneHi = max(s.tone, s.toneHi - TONE_RELAX * TICK)
            s.toneLo = min(s.tone, s.toneLo + TONE_RELAX * TICK)
            local target = (s.tone - s.toneLo) / max(s.toneHi - s.toneLo, TONE_SPAN) * (FORMS - 1)
            s.form = s.form + (target - s.form) * K_FORM
        end
        s.formShift = s.formShift + (s.jump - s.formShift) * K_SHIFT
    end

    -- dive finds drops in the raw energy and runs the hyperspace envelope.
    local function dive(energy)
        if energy < SILENCE then
            s.heard = 0
            s.quiet = s.quiet + TICK
        else
            s.quiet = 0
            if s.heard == 0 then
                -- A track rising out of silence is no drop.
                s.fastE, s.slowE = energy, energy
            end
            s.heard = s.heard + TICK
        end
        s.fastE = s.fastE + (energy - s.fastE) * K_FAST
        -- While warming up the long average learns the level as fast as the short one.
        s.slowE = s.slowE + (energy - s.slowE) * (s.heard < DROP_WARM and K_FAST or K_SLOW)
        local drop = s.fastE > DROP_RATIO * s.slowE and s.fastE > DROP_FLOOR
        if drop and s.heard >= DROP_WARM and s.clock - s.warpAt > DROP_GAP then
            s.warpAt = s.clock
            s.jump = s.jump + 1
        end
        local age = s.clock - s.warpAt
        if age < 0 or age > WARP_LIFE then
            s.warp = 0
        elseif age < WARP_RISE then
            s.warp = age / WARP_RISE
        else
            s.warp = exp(-(age - WARP_RISE) / WARP_FADE)
        end
    end

    -- target_speed is one ring per beat when the tempo is sure, else the cruise.
    -- The tunnel stops when there is nothing to hear.
    local function target_speed()
        if s.quiet >= QUIET then
            return 0
        end
        local target = CRUISE + LOUD_GAIN * s.loud
        if s.beat > 0 then
            -- Phase error in rings: 0 when a ring reaches the mouth on the kick.
            local err = s.travel * RINGS - ENTRY - (s.clock - s.lastKick) / s.beat
            err = err - round(err)
            local lock = max(-LOCK_MAX, min(LOCK_MAX, -LOCK * err)) * (1 - s.warp)
            target = target + ((1 + lock) / (s.beat * RINGS) - target) * s.sure
        end
        return target + (TOP_SPEED - target) * s.warp
    end

    -- fly moves the tunnel on by a tick and keeps the glow of each ring that
    -- reached the mouth.
    local function fly()
        s.travel = s.travel + s.speed * TICK
        local newest = floor(s.travel * RINGS - ENTRY)
        while s.born < newest do
            s.born = s.born + 1
            local kept = s.shapes[s.born % SHAPES]
            for i = 1, BANDS do
                kept[i] = s.glow[i]
            end
        end
    end

    -- delayed swaps the bands for the ones from DELAY ticks ago.
    local function delayed(bands)
        if DELAY == 0 then
            return bands
        end
        s.held = s.held % DELAY + 1
        local slot, late = s.heldBands[s.held], s.lateBands
        for i = 1, BANDS do
            late[i], slot[i] = slot[i], bands[i]
        end
        return late
    end

    -- cliamp eases the bands and hands over where they are at the end of a
    -- frame. between gives them part of the way through it: the ease is faster
    -- up than down. after is the share of the frame gone by, span its length in s.
    local EASE_UP, EASE_DOWN = 34, 10

    local function between(bands, after, span)
        local up = (1 - exp(-EASE_UP * after * span)) / (1 - exp(-EASE_UP * span))
        local down = (1 - exp(-EASE_DOWN * after * span)) / (1 - exp(-EASE_DOWN * span))
        local from, mid = s.lastBands, s.midBands
        for i = 1, BANDS do
            local change = bands[i] - from[i]
            mid[i] = from[i] + change * (change > 0 and up or down)
        end
        return mid
    end

    -- step is one tick of playback.
    local function step(bands)
        bands = delayed(bands)
        s.loud = s.loud + (levels(bands) - s.loud) * K_LOUD
        s.clock = s.clock + TICK
        if not s.playing then
            -- The bands rise out of the break. That is no drum.
            s.hasPrev, s.deaf, s.playing = false, DEAF, true
        end
        s.deaf = max(0, s.deaf - TICK)
        hits(bands)
        s.rock = s.rock + (s.rockTo - s.rock) * K_ROCK
        if s.clock - s.lastKick > SURE_WAIT then
            s.sure = max(0, s.sure - 0.5 * TICK)
        end
        local sum = 0
        for i = 1, BANDS do
            sum = sum + bands[i]
        end
        morph(bands, sum)
        dive(sum / BANDS)

        s.speed = s.speed + (target_speed() - s.speed) * K_SPEED
        local beats = s.beat > 0 and s.sure / s.beat or 0
        s.spiral = s.spiral + (SPIRAL * beats - s.spiral) * K_SPIRAL
        if s.quiet < QUIET then
            s.bendPhase = s.bendPhase + (BEND_RATE + BEND_LOUD * s.loud) * TICK
            s.twist = s.twist + (TWIST + TWIST_LOUD * s.loud + TWIST_BEAT * beats) * TICK
        end
        s.starTravel = s.starTravel + STAR_RATE * s.warp * TICK
        fly()
    end

    -- The last tick of a frame gets its bands, the ticks before it the bands
    -- on the way there.
    function play(bands, steps)
        local last = s.lastBands
        if not s.playing then
            -- Nothing to ease from after a break.
            for i = 1, BANDS do
                last[i] = bands[i]
            end
        end
        for i = 1, steps - 1 do
            step(between(bands, i / steps, steps * TICK))
        end
        step(bands)
        for i = 1, BANDS do
            last[i] = bands[i]
        end
    end

    -- rest is one tick of a pause: the tunnel eases to a stop.
    function rest()
        s.playing = false
        s.speed = s.speed - s.speed * K_FALL
        if s.speed < 0.01 then
            s.speed = 0
        end
        fly()
    end
end

-- Drawing ----------------------------------------------------------------

local draw, resize
local coarse = 1 -- draw every dot, or only one in this many

do
    -- Tunnel size at depth 1 as a share of the panel.
    local MOUTH = 0.12
    local FAR = 0.85
    local NEAR = 0.08
    local INNER = 1 / FAR -- the same span in 1/z
    local REACH = 1 / NEAR - INNER
    local SHOWN = 0.7 -- rings fade in until this depth
    local BRIGHT = 0.45 -- rings nearer than this are bright
    local FLAT = 0.35 -- min height/width
    local BEND = 0.2 -- how far the far end bends
    -- Spectral rings: bulge by up to this share where the band was loud.
    local SPECTRAL = 0.3
    local STAR_DEPTH = 0.3

    -- Hyperspace.
    local WARP_SHOWN = 0.05
    local WARP_WIDEN = 0.25
    local WARP_SMEAR = 0.8 -- in 1/z
    local STARS = 40
    local STAR_TAIL = 4.0 -- in 1/z at full warp

    -- Bass shock wave; width in 1/z.
    local WAVE_TIME = 0.5
    local WAVE_WIDTH = 0.7
    local SWELL = 0.15
    local WAVE_LIT = 0.4
    local WAVE_HOT = 0.75

    -- Sparks.
    local SPARK_LIFE = 0.25
    local SPARK_TAIL = 0.15
    local SPARK_RUSH = 0.6
    local MAX_STREAK = 512 -- longest streak in dots

    -- The dots of a cell as Braille bits, row by row.
    local DOT = { 1, 8, 2, 16, 4, 32, 64, 128 }

    local GLYPH = {}
    -- HAS[mask * 8 + k] tells whether a cell with these dots has dot k.
    local HAS = {}
    for mask = 0, 255 do
        GLYPH[mask] = string.char(0xE2, 0xA0 + floor(mask / 64), 0x80 + mask % 64)
        for k, bit in ipairs(DOT) do
            HAS[mask * 8 + k] = mask % (2 * bit) >= bit
        end
    end

    local ZERO = filled(BANDS, 0)

    -- The narrowest point of each cross-section.
    local SLIM = { [0] = 1, cos(pi / 6), cos(pi / 4), 1 / (1 + 2 * STAR_DEPTH) }
    local SEG = { 2 * pi / 6, 2 * pi / 4 } -- the side of the hexagon and of the square, as an angle

    -- One entry per character cell: its dots and its tier.
    local bits, tiers = {}, {}
    -- Where dot column x and dot row y fall: the cell, and the dot in it.
    local COL, SIDE, ROW, LINE = {}, {}, {}, {}
    local out, joined = {}, {}
    local PIECE = 1000

    -- The frame that draw works on.
    local w, h, cols
    local halfW, halfH, rx, ry, bendX, bendY
    local formI, formF
    local slimmest -- the smallest radius of the outline, a little under
    local travel, twist, rock, spiral, warp, born
    local glow, shapes
    local fronts, strengths, nfronts = {}, {}, 0

    function resize(rows, columns)
        cols, w, h = columns, columns * 2, rows * 4
        for x = 0, w - 1 do
            COL[x], SIDE[x] = floor(x / 2), x % 2
        end
        for y = 0, h - 1 do
            ROW[y], LINE[y] = floor(y / 4) * cols + 1, y % 4 * 2 + 1
        end
    end

    -- dot sets the dot that holds the point. It rounds down, so a point just off
    -- the left or top edge stays off the panel.
    local function dot(x, y, tier)
        if not (x >= 0 and x < w and y >= 0 and y < h) then
            return
        end
        local xi, yi = floor(x), floor(y)
        local c, k = ROW[yi] + COL[xi], LINE[yi] + SIDE[xi]
        local mask = bits[c]
        if not HAS[mask * 8 + k] then
            bits[c] = mask + DOT[k]
        end
        if tier > tiers[c] then
            tiers[c] = tier
        end
    end

    -- The radius of one cross-section at wall angle a, at most 1. A polygon has
    -- its corners at 1.
    local function radius(kind, a)
        if kind == 1 or kind == 2 then
            local seg = SEG[kind]
            return SLIM[kind] / cos(a - seg * floor(a / seg) - seg / 2)
        elseif kind == 3 then
            return 1 / (1 + STAR_DEPTH * (1 - cos(5 * a)))
        end
        return 1
    end

    -- outline is the radius of the current shape mixed with the next one.
    local function outline(a)
        local cur = radius(formI, a)
        if formF == 0 then
            return cur
        end
        return cur + (radius((formI + 1) % FORMS, a) - cur) * formF
    end

    -- The band levels that ring took along; the live ones before the mouth, none
    -- once it is long gone.
    local function ring_levels(nth)
        if nth <= born - SHAPES then
            return ZERO
        elseif nth <= born then
            return shapes[nth % SHAPES]
        end
        return glow
    end

    -- bulge is how loud the wall was at band position u, 0 for the lowest band
    -- to BANDS-1 for the highest, between the levels of two rings.
    local function bulge(here, beyond, mix, u)
        local band = min(floor(u), BANDS - 2)
        local up = u - band
        local level = here[band + 1] * (1 - up) + here[band + 2] * up
        return level + (beyond[band + 1] * (1 - up) + beyond[band + 2] * up - level) * mix
    end

    -- swell is how much the shock waves widen the tunnel at depth z.
    local function swell(z)
        local share = 0
        for i = 1, nfronts do
            local off = (1 / z - fronts[i]) / WAVE_WIDTH
            share = max(share, strengths[i] * exp(-off * off))
        end
        return SWELL * share
    end

    -- at maps wall angle a and depth z to a screen dot. The spiral turns the wall
    -- more the nearer it is. The wall bulges where its ring was loud: bass at the
    -- bottom, treble at the top.
    local function at(a, z, scale)
        local sine, cosine = sin(a + spiral / z), cos(a + spiral / z)
        local n = (z - 1 + travel) * RINGS
        local nth = floor(n)
        local u = acos(sine) / pi * (BANDS - 1)
        local loud = bulge(ring_levels(nth), ring_levels(nth + 1), n - nth, u)
        local grow = scale * outline(a) * (1 + SPECTRAL * loud) / z
        local x = halfW * (1 + bendX * z * z) + rx * cosine * grow
        return x, halfH * (1 + bendY * z * z) + ry * sine * grow
    end

    -- streak draws a line whose first third is tier head and the rest tier tail.
    -- Capped, so a wild projection stays cheap.
    local function streak(x0, y0, x1, y1, head, tail)
        local span = max(abs(x1 - x0), abs(y1 - y0))
        if not (span < math.huge) then
            return
        end
        local steps = min(MAX_STREAK, floor(span) + 1)
        for i = 0, steps do
            local t = i / steps
            dot(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 3 * i < steps and head or tail)
        end
    end

    -- ring draws the fraction shown of the ring at depth z. In hyperspace every
    -- few dots smear back towards the mouth.
    local function ring(z, shown, tier)
        local scale = 1 + swell(z)
        local points = floor(2 * pi * max(rx, ry) * scale * (1 + SPECTRAL) / z) + 8
        points = max(8, floor(points / coarse))
        local smears = warp > WARP_SHOWN
        local smear = 1 / max(INNER, 1 / z - WARP_SMEAR * warp)
        local every = max(1, floor(points / 16))

        -- What the dots of a ring share.
        local cx, cy = halfW * (1 + bendX * z * z), halfH * (1 + bendY * z * z)
        local n = (z - 1 + travel) * RINGS
        local nth = floor(n)
        local here, beyond, mix = ring_levels(nth), ring_levels(nth + 1), n - nth
        local turn = spiral / z

        -- Most of a near ring is off the panel: a dot cannot show where even the
        -- smallest radius it may have is outside. A running rotation finds those
        -- dots without a sine for each.
        local least = scale * slimmest / z
        local left, right = -cx / (rx * least), (w - cx) / (rx * least)
        local top, bottom = -cy / (ry * least), (h - cy) / (ry * least)
        local step = 2 * pi / points
        local cstep, sstep = cos(step), sin(step)
        local c, sn = cos(twist + rock + turn), sin(twist + rock + turn)
        -- The 7 spreads the dots that show around the ring: dot i shows when
        -- i * 7 % points is below the quota.
        local spread, quota = 0, shown * points
        for i = 0, points - 1 do
            if spread < quota then
                local smeared = smears and i % every == 0
                if smeared or (c > left and c < right and sn > top and sn < bottom) then
                    local a = 2 * pi * i / points + twist + rock
                    local sine, cosine = sin(a + turn), cos(a + turn)
                    local loud = bulge(here, beyond, mix, acos(sine) / pi * (BANDS - 1))
                    local grow = scale * outline(a) * (1 + SPECTRAL * loud) / z
                    local x, y = cx + rx * cosine * grow, cy + ry * sine * grow
                    if smeared then
                        local x1, y1 = at(a, smear, scale)
                        streak(x, y, x1, y1, tier, tier)
                    else
                        dot(x, y, tier)
                    end
                end
            end
            spread = spread + 7
            if spread >= points then
                spread = spread - points
            end
            c, sn = c * cstep - sn * sstep, sn * cstep + c * sstep
        end
    end

    -- aim sets up the projection of the frame.
    local function aim()
        travel, twist, rock, spiral = s.travel, s.twist, s.rock, s.spiral
        warp, born, glow, shapes = s.warp, s.born, s.glow, s.shapes
        halfW, halfH = w / 2, h / 2
        local tunnelH = max(halfH, FLAT * halfW)
        -- At least 5 dots, or the far rings merge in short panels.
        local mouth = max(MOUTH, 5 / tunnelH) * (1 + WARP_WIDEN * warp)
        rx, ry = mouth * halfW, mouth * tunnelH
        local reach = BEND * (1 + 0.5 * s.loud)
        bendX, bendY = reach * sin(s.bendPhase), 0.6 * reach * sin(0.7 * s.bendPhase)
        local form = (s.form + s.formShift) % FORMS
        formI, formF = floor(form), form - floor(form)
        slimmest = SLIM[formI] or 1
        if formF > 0 then
            slimmest = min(slimmest, SLIM[(formI + 1) % FORMS])
        end
        slimmest = slimmest * (1 - 1e-6)

        nfronts = 0
        for _, wave in ipairs(s.waves) do
            local age = s.clock - wave.at
            if wave.strength ~= 0 and age >= 0 and age <= WAVE_TIME then
                nfronts = nfronts + 1
                fronts[nfronts] = INNER + REACH * age / WAVE_TIME
                strengths[nfronts] = wave.strength
            end
        end
    end

    -- One wall line per 4 dot rows. Step evenly in 1/z so the dots are evenly
    -- spaced.
    local function walls(rows)
        local lines = max(8, min(16, rows))
        for line = 0, lines - 1 do
            local a = 2 * pi * line / lines + twist + rock
            local x0, y0 = at(a, FAR, 1)
            local x1, y1 = at(a, NEAR, 1)
            local steps = max(1, floor((floor(max(abs(x1 - x0), abs(y1 - y0))) + 1) / coarse))
            local wide = outline(a)
            -- Without a spiral the line is straight.
            local sine, cosine = sin(a), cos(a)
            local u = acos(sine) / pi * (BANDS - 1)
            for i = 0, steps do
                local z = 1 / (INNER + REACH * (i / steps))
                if spiral ~= 0 then
                    sine, cosine = sin(a + spiral / z), cos(a + spiral / z)
                    u = acos(sine) / pi * (BANDS - 1)
                end
                local cx, cy = halfW * (1 + bendX * z * z), halfH * (1 + bendY * z * z)
                -- The nearest the dot can be to the center. Past the edge there,
                -- it is off the panel for sure.
                local least = wide * (1 - 1e-6) / z
                local x, y = cx + rx * cosine * least, cy + ry * sine * least
                if x >= 0 and x < w and y >= 0 and y < h then
                    local n = (z - 1 + travel) * RINGS
                    local nth = floor(n)
                    local loud = bulge(ring_levels(nth), ring_levels(nth + 1), n - nth, u)
                    local grow = (1 + swell(z)) * wide * (1 + SPECTRAL * loud) / z
                    dot(cx + rx * cosine * grow, cy + ry * sine * grow, DIM)
                end
            end
        end
    end

    -- Ring n enters at the mouth when travel reaches n/RINGS. A wave front is a
    -- ring of its own.
    local function rings()
        local newest = floor(travel * RINGS)
        for nth = newest - RINGS + 1, newest do
            local z = 1 - travel + nth / RINGS
            if z <= FAR and z >= NEAR then
                local lift = swell(z)
                local tier = DIM
                if lift > WAVE_HOT * SWELL then
                    tier = HOT
                elseif lift > WAVE_LIT * SWELL or warp > 0.5 then
                    tier = BEAT
                elseif z < BRIGHT then
                    tier = TEXT
                end
                -- Fade in at the mouth.
                ring(z, max(0, min(1, (FAR - z) / (FAR - SHOWN))), tier)
            end
        end
        for i = 1, nfronts do
            ring(1 / fronts[i], 1, strengths[i] >= WAVE_HOT and HOT or BEAT)
        end
    end

    local function sparks()
        for _, spark in ipairs(s.sparks) do
            local age = s.clock - spark.at
            local head = spark.z - (travel - spark.travel) - SPARK_RUSH * age
            if age <= SPARK_LIFE and head >= NEAR then
                local a = spark.angle + twist + rock
                local tail = head + SPARK_TAIL
                local x0, y0 = at(a, head, 1 + swell(head))
                local x1, y1 = at(a, tail, 1 + swell(tail))
                streak(x0, y0, x1, y1, TEXT, BEAT)
            end
        end
    end

    -- Star streaks in hyperspace.
    local function stars()
        for i = 0, STARS - 1 do
            local head = INNER + REACH * ((hash(i, 2) + s.starTravel) % 1)
            local tail = max(INNER, head - STAR_TAIL * warp)
            local a = 2 * pi * hash(i, 3) + twist
            local scale = 0.4 + 0.5 * hash(i, 4)
            local x0, y0 = at(a, 1 / head, scale)
            local x1, y1 = at(a, 1 / tail, scale)
            streak(x0, y0, x1, y1, HOT, BEAT)
        end
    end

    -- text packs the cells into lines of colored Braille. A blank cell joins the
    -- color that runs: it paints nothing. The Lua stack limits how many strings
    -- one concat can take, so the frame is joined in pieces.
    local function text(rows)
        local n, c, pieces = 0, 0, 0
        for row = 1, rows do
            local tier = 0
            for _ = 1, cols do
                c = c + 1
                local t = tiers[c]
                if t ~= 0 and t ~= tier then
                    if tier ~= 0 then
                        n = n + 1
                        out[n] = RESET
                    end
                    n = n + 1
                    out[n] = COLOR[t]
                    tier = t
                end
                n = n + 1
                out[n] = GLYPH[bits[c]]
                if n >= PIECE then
                    pieces = pieces + 1
                    joined[pieces] = table.concat(out, "", 1, n)
                    n = 0
                end
            end
            if tier ~= 0 then
                n = n + 1
                out[n] = RESET
            end
            if row < rows then
                n = n + 1
                out[n] = "\n"
            end
        end
        pieces = pieces + 1
        joined[pieces] = table.concat(out, "", 1, n)
        return table.concat(joined, "", 1, pieces)
    end

    function draw(rows)
        for i = 1, rows * cols do
            bits[i], tiers[i] = 0, 0
        end
        aim()
        walls(rows)
        rings()
        sparks()
        if warp > WARP_SHOWN then
            stars()
        end
        return text(rows)
    end
end

-- Plugin -----------------------------------------------------------------

local FRAME = 0.05 -- what a draw is worth when the clock is no help
local MAX_GAP = 0.25 -- a longer wait between draws is a break, not a slow frame
local MAX_STEPS = 4
local DRAW_GAP = 0.04 -- s between two draws while the music plays

-- cliamp gives a draw 50 ms and keeps the old frame when it takes longer.
-- Two draws in a row slower than SLOW seconds set fewer dots from then on, a
-- swift one more again.
local SLOW, SWIFT = 0.04, 0.015
local MAX_COARSE = 4

local lastAt, lastFrame, owed = nil, nil, 0
local shown, shownRows, shownCols
local dirty, drawing, drawnAt, slow = true, false, 0, 0

function p:init()
    reset()
    lastAt, lastFrame, owed, dirty = nil, nil, 0, true
end

function p:render(bands, frame, rows, columns)
    rows, columns = floor(rows), floor(columns)
    if rows < 1 or columns < 1 then
        return ""
    end

    local now = os.clock()
    local status = cliamp.player.state()
    local flying = s.speed ~= 0
    if status == "stopped" then
        dirty = dirty or flying
        s.speed, s.playing, lastAt = 0, false, nil
    elseif status == "paused" or frame ~= lastFrame then
        -- cliamp also draws between its ticks, on a key press for one. The
        -- bands are new only when the frame is; a pause holds the frame.
        local dt = lastAt and now - lastAt or FRAME
        if dt <= 0 or dt > MAX_GAP then
            dt = FRAME
            if status == "paused" then
                s.speed = 0 -- the ticks of a pause thin out before the tunnel is at rest
            end
            s.playing = false
        end
        lastAt, lastFrame = now, frame
        owed = owed + dt
        local steps = min(MAX_STEPS, floor((owed + 1e-6) / TICK))
        owed = owed - steps * TICK
        if owed > TICK then
            owed = 0
        end
        if status == "paused" then
            for _ = 1, steps do
                rest()
            end
        elseif steps > 0 then
            play(bands, steps)
        end
        dirty = dirty or steps > 0 and (flying or status ~= "paused")
    end

    if rows ~= shownRows or columns ~= shownCols then
        resize(rows, columns)
        shown, shownRows, shownCols = nil, rows, columns
    end
    -- cliamp shows 20 frames a second, so a frame drawn sooner is wasted.
    if not shown or dirty and (now - drawnAt > DRAW_GAP or status ~= "playing") then
        if drawing then
            coarse = min(MAX_COARSE, coarse + 1) -- cliamp cut the last draw short
        end
        drawing = true
        shown = draw(rows)
        drawing = false
        local took = os.clock() - now
        slow = took > SLOW and slow + 1 or 0
        if slow > 1 and coarse < MAX_COARSE then
            coarse, slow = coarse + 1, 0
        elseif took < SWIFT and coarse > 1 then
            coarse = coarse - 1
        end
        dirty, drawnAt = false, now
    end
    return shown
end
