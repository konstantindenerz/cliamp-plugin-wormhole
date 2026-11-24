// Package test runs wormhole.lua in the Lua VM that cliamp uses, with
// stand-ins for the plugin and cliamp tables.
package test

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"hash/fnv"
	"math"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	lua "github.com/yuin/gopher-lua"
)

var update = flag.Bool("update", false, "rewrite testdata/frames.txt")

const (
	source = "../wormhole.lua"
	golden = "testdata/frames.txt"
	tick   = 0.05 // s between two ticks of cliamp
)

// peek lets a test read the state that the plugin keeps to itself.
const peek = `
function __peek() return s.lastKick, s.beat, s.sure, s.speed, s.travel end
`

// host stands in for cliamp: a sandboxed VM with the plugin loaded.
type host struct {
	t      testing.TB
	L      *lua.LState
	meta   *lua.LTable // what the plugin passed to plugin.register
	plugin *lua.LTable // what it got back
	clock  float64     // os.clock, in seconds
	status string      // cliamp.player.state
	frame  int
}

// load runs the plugin file. config is its section of config.toml.
func load(t testing.TB, config map[string]string) *host {
	t.Helper()
	src, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	h := &host{t: t, L: lua.NewState(), status: "playing"}
	t.Cleanup(h.L.Close)
	L := h.L

	// What cliamp takes away from a plugin.
	for _, name := range []string{"dofile", "loadfile", "load", "loadstring", "require", "module", "package", "debug", "io"} {
		L.SetGlobal(name, lua.LNil)
	}
	L.SetGlobal("print", L.NewFunction(func(*lua.LState) int { return 0 }))
	system := L.GetGlobal("os").(*lua.LTable)
	for _, name := range []string{"execute", "remove", "rename", "exit", "setlocale", "tmpname"} {
		system.RawSetString(name, lua.LNil)
	}
	system.RawSetString("clock", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LNumber(h.clock))
		return 1
	}))

	player := L.NewTable()
	player.RawSetString("state", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LString(h.status))
		return 1
	}))
	cliamp := L.NewTable()
	cliamp.RawSetString("player", player)
	L.SetGlobal("cliamp", cliamp)

	register := L.NewTable()
	register.RawSetString("register", L.NewFunction(func(L *lua.LState) int {
		h.meta = L.CheckTable(1)
		h.plugin = L.NewTable()
		h.plugin.RawSetString("config", L.NewFunction(func(L *lua.LState) int {
			if value, ok := config[L.CheckString(2)]; ok {
				L.Push(lua.LString(value))
			} else {
				L.Push(lua.LNil)
			}
			return 1
		}))
		L.Push(h.plugin)
		return 1
	}))
	L.SetGlobal("plugin", register)

	if err := L.DoString(string(src) + peek); err != nil {
		t.Fatalf("load: %v", err)
	}
	if h.plugin == nil {
		t.Fatal("the plugin did not register")
	}
	return h
}

// draw calls render as cliamp does, under a deadline.
func (h *host) draw(bands [10]float64, rows, cols int) string {
	h.t.Helper()
	L := h.L
	levels := L.NewTable()
	for i, b := range bands {
		levels.RawSetInt(i+1, lua.LNumber(b))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	L.SetContext(ctx)
	defer L.RemoveContext()
	call := lua.P{Fn: h.plugin.RawGetString("render"), NRet: 1, Protect: true}
	if err := L.CallByParam(call, h.plugin, levels, lua.LNumber(h.frame), lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		h.t.Fatalf("render: %v", err)
	}
	out, ok := L.Get(-1).(lua.LString)
	L.Pop(1)
	if !ok {
		h.t.Fatal("render did not return a string")
	}
	return string(out)
}

// tick is one tick of cliamp, dt seconds after the last: new bands and,
// unless playback is paused, a new frame number.
func (h *host) tick(bands [10]float64, rows, cols int, dt float64) string {
	h.t.Helper()
	h.clock += dt
	if h.status != "paused" {
		h.frame++
	}
	return h.draw(bands, rows, cols)
}

// restart is what cliamp does when the mode is selected again.
func (h *host) restart(rows, cols int) {
	h.t.Helper()
	call := lua.P{Fn: h.plugin.RawGetString("init"), Protect: true}
	if err := h.L.CallByParam(call, h.plugin, lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		h.t.Fatalf("init: %v", err)
	}
}

type tunnel struct{ lastKick, beat, sure, speed, travel float64 }

func (h *host) tunnel() tunnel {
	h.t.Helper()
	L := h.L
	if err := L.CallByParam(lua.P{Fn: L.GetGlobal("__peek"), NRet: 5, Protect: true}); err != nil {
		h.t.Fatal(err)
	}
	value := func(i int) float64 { return float64(L.Get(i).(lua.LNumber)) }
	state := tunnel{value(-5), value(-4), value(-3), value(-2), value(-1)}
	L.Pop(5)
	return state
}

// music gives the bands of a track at second sec: a kick on the beat, a
// snare on every second one, hats on the off eighths. gain scales it all.
func music(bpm, sec, gain float64) [10]float64 {
	beat := 60 / bpm
	since := func(period, offset float64) float64 { return math.Mod(sec-offset+100*period, period) }
	kick := math.Exp(-since(beat, 0) / 0.08)
	snare := math.Exp(-since(2*beat, beat) / 0.06)
	hat := math.Exp(-since(beat/2, beat/4) / 0.03)
	swing := 0.85 + 0.15*math.Sin(sec*0.3)
	tilt := 0.5 + 0.5*math.Sin(sec*0.11)
	var bands [10]float64
	for i := range bands {
		switch {
		case i < 3:
			bands[i] = 0.3 + 0.55*kick
		case i < 6:
			bands[i] = 0.25 + 0.5*snare
		default:
			bands[i] = 0.15 + 0.2*tilt + 0.45*hat
		}
		bands[i] = min(1, bands[i]*swing*gain)
	}
	return bands
}

var colors = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// checkFrame fails unless out is rows lines of cols Braille cells, with
// nothing but color codes between them.
func checkFrame(t *testing.T, out string, rows, cols int) {
	t.Helper()
	lines := strings.Split(colors.ReplaceAllString(out, ""), "\n")
	if len(lines) != rows {
		t.Fatalf("%d lines, want %d", len(lines), rows)
	}
	for _, line := range lines {
		cells := []rune(line)
		if len(cells) != cols {
			t.Fatalf("a line of %d cells, want %d", len(cells), cols)
		}
		for _, cell := range cells {
			if cell < 0x2800 || cell > 0x28FF {
				t.Fatalf("%q in the frame, want Braille only", cell)
			}
		}
	}
}

func TestRegisters(t *testing.T) {
	h := load(t, nil)
	for key, want := range map[string]string{"name": "Wormhole", "type": "visualizer"} {
		if got := h.meta.RawGetString(key).String(); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
	if h.meta.RawGetString("permissions") != lua.LNil {
		t.Error("the plugin asks for permissions")
	}
	for _, name := range []string{"render", "init"} {
		if _, ok := h.plugin.RawGetString(name).(*lua.LFunction); !ok {
			t.Errorf("no %s", name)
		}
	}
}

// The VM allows 200 locals in one function, and the top level of the file is
// one. The file must stay well below that, or a small edit stops it loading.
func TestLeavesRoomForLocals(t *testing.T) {
	src, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	var more strings.Builder
	for i := range 60 {
		fmt.Fprintf(&more, "\nlocal spare%d = %d", i, i)
	}
	L := lua.NewState()
	defer L.Close()
	if _, err := L.LoadString(string(src) + more.String()); err != nil {
		t.Fatalf("60 more locals do not fit: %v", err)
	}
}

func TestFitsPanel(t *testing.T) {
	for _, size := range []struct{ cols, rows int }{{1, 1}, {2, 1}, {3, 2}, {13, 3}, {40, 1}, {76, 7}, {140, 40}, {300, 90}} {
		t.Run(fmt.Sprintf("%dx%d", size.cols, size.rows), func(t *testing.T) {
			h := load(t, nil)
			for i := range 60 {
				checkFrame(t, h.tick(music(128, float64(i)*tick, 1), size.rows, size.cols, tick), size.rows, size.cols)
			}
		})
	}
}

type step struct {
	status string
	bands  [10]float64
}

// scenes are short runs that between them show every part of the tunnel.
func scenes() map[string][]step {
	run := func(parts ...struct {
		secs   float64
		status string
		gain   float64
	}) []step {
		var steps []step
		sec := 0.0
		for _, part := range parts {
			for end := sec + part.secs; sec < end-1e-9; sec += tick {
				s := step{status: part.status}
				if part.status == "playing" {
					s.bands = music(128, sec, part.gain)
				}
				steps = append(steps, s)
			}
		}
		return steps
	}
	type part = struct {
		secs   float64
		status string
		gain   float64
	}
	return map[string][]step{
		"silence": run(part{1, "playing", 0}),
		"music":   run(part{15, "playing", 1}),
		"drop":    run(part{6, "playing", 0.25}, part{6, "playing", 1}),
		"breaks": run(part{5, "playing", 1}, part{1.5, "paused", 0}, part{3, "playing", 1},
			part{1, "stopped", 0}, part{3, "playing", 1}, part{1.5, "playing", 0}, part{2, "playing", 1}),
	}
}

// The frames were recorded while they matched the Go mode that the plugin
// was ported from, cell for cell. A hash may change only on purpose.
func TestFrames(t *testing.T) {
	want := map[string]string{}
	if file, err := os.Open(golden); err == nil {
		lines := bufio.NewScanner(file)
		for lines.Scan() {
			if key, hash, ok := strings.Cut(lines.Text(), ": "); ok {
				want[key] = hash
			}
		}
		file.Close()
	}
	var names []string
	for name := range scenes() {
		names = append(names, name)
	}
	slices.Sort(names)

	var recorded strings.Builder
	for _, name := range names {
		for _, size := range []struct{ cols, rows int }{{13, 3}, {40, 1}, {76, 7}, {140, 40}} {
			key := fmt.Sprintf("%s %dx%d", name, size.cols, size.rows)
			h := load(t, nil)
			sum := fnv.New64a()
			for _, s := range scenes()[name] {
				h.status = s.status
				sum.Write([]byte(h.tick(s.bands, size.rows, size.cols, tick)))
				sum.Write([]byte{0})
			}
			got := fmt.Sprintf("%016x", sum.Sum64())
			fmt.Fprintf(&recorded, "%s: %s\n", key, got)
			if !*update && got != want[key] {
				t.Errorf("%s: hash %s, want %s", key, got, want[key])
			}
		}
	}
	if *update {
		if err := os.WriteFile(golden, []byte(recorded.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// With a steady kick the tunnel flies one ring per beat: a tenth of a lap.
func TestFollowsTempo(t *testing.T) {
	for _, bpm := range []float64{96, 120, 128, 150, 174} {
		t.Run(fmt.Sprint(bpm), func(t *testing.T) {
			h := load(t, nil)
			mean, n := 0.0, 0
			for i := range 400 {
				h.tick(music(bpm, float64(i)*tick, 1), 7, 76, tick)
				if i >= 200 {
					mean += h.tunnel().speed
					n++
				}
			}
			state := h.tunnel()
			want := bpm / 60 / 10
			if got := mean / float64(n); state.sure != 1 || math.Abs(got-want) > 0.03*want {
				t.Fatalf("speed %.4f laps/s, tempo sure %.2f, beat %.3f s; want %.4f and 1", got, state.sure, state.beat, want)
			}
		})
	}
}

// After init the plugin is as good as freshly loaded.
func TestRestart(t *testing.T) {
	used, fresh := load(t, nil), load(t, nil)
	for i := range 300 {
		used.tick(music(150, float64(i)*tick, 1), 7, 76, tick)
	}
	used.restart(7, 76)
	for i := range 240 {
		bands := music(128, float64(i)*tick, 1)
		used.tick(bands, 7, 76, tick)
		fresh.tick(bands, 7, 76, tick)
		if a, b := used.tunnel(), fresh.tunnel(); a != b {
			t.Fatalf("tick %d after init: %+v, a fresh plugin has %+v", i, a, b)
		}
	}
}

func TestPauseAndStop(t *testing.T) {
	h := load(t, nil)
	play := func(secs float64) {
		for i := 0; float64(i)*tick < secs; i++ {
			h.tick(music(128, h.clock, 1), 7, 76, tick)
		}
	}
	play(4)
	if h.tunnel().speed == 0 {
		t.Fatal("the tunnel does not fly")
	}

	// A pause eases the tunnel to rest. cliamp holds the frame number.
	h.status = "paused"
	before := h.tunnel().speed
	h.tick([10]float64{}, 7, 76, tick)
	if speed := h.tunnel().speed; speed == 0 || speed >= before {
		t.Fatalf("speed %.3f one tick into the pause, from %.3f", speed, before)
	}
	for range 60 {
		h.tick([10]float64{}, 7, 76, tick)
	}
	rest := h.tunnel()
	still := h.tick([10]float64{}, 7, 76, tick)
	for range 5 {
		if h.tick([10]float64{}, 7, 76, tick) != still {
			t.Fatal("the tunnel moves at rest")
		}
	}
	if now := h.tunnel(); rest.speed != 0 || now.travel != rest.travel {
		t.Fatalf("speed %.3f, flew %.4f laps at rest", rest.speed, now.travel-rest.travel)
	}

	// A stop halts it at once.
	h.status = "playing"
	play(3)
	h.status = "stopped"
	h.tick([10]float64{}, 7, 76, tick)
	if speed := h.tunnel().speed; speed != 0 {
		t.Fatalf("speed %.3f after a stop", speed)
	}
}

func TestConfig(t *testing.T) {
	for _, tc := range []struct {
		name   string
		config map[string]string
		dim    string // the color code of the wall
	}{
		{"defaults", nil, "\x1b[37m"},
		{"index", map[string]string{"dim": "8", "text": "15", "beat": "200", "hot": "1"}, "\x1b[90m"},
		{"hex", map[string]string{"dim": "#102030"}, "\x1b[38;2;16;32;48m"},
		{"hex without #", map[string]string{"dim": "102030"}, "\x1b[38;2;16;32;48m"},
		{"comment after the value", map[string]string{"dim": "244  # gray"}, "\x1b[38;5;244m"},
		{"junk", map[string]string{"dim": "abc", "text": "#12", "beat": "-5", "hot": ""}, "\x1b[37m"},
		{"too big", map[string]string{"dim": "70000", "text": "99999999999"}, "\x1b[38;5;255m"},
		{"escape codes", map[string]string{"dim": "7\x1b]0;x\x07", "text": "#ffffff\x1b[2J"}, "\x1b[37m"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := load(t, tc.config)
			out := ""
			for i := range 60 {
				out = h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
			}
			if !strings.Contains(out, tc.dim) {
				t.Errorf("no %q in the frame", tc.dim)
			}
			checkFrame(t, out, 7, 76)
		})
	}
}

// cliamp v2.4.0 can tick every 16 ms. The plugin still draws at most one
// frame per 40 ms and hears the same kicks.
func TestFastTicks(t *testing.T) {
	run := func(dt float64) (kicks, draws int) {
		h := load(t, nil)
		last, lastKick := "", 0.0
		for i := 0; float64(i)*dt < 20; i++ {
			out := h.tick(music(128, float64(i)*dt, 1), 7, 76, dt)
			if out != last {
				draws++
			}
			last = out
			if at := h.tunnel().lastKick; at != lastKick && at > 0 {
				kicks++
			}
			lastKick = h.tunnel().lastKick
		}
		return kicks, draws
	}
	kicks, _ := run(tick)
	fast, draws := run(0.016)
	if draws > 20/0.04+2 {
		t.Errorf("%d draws in 20 s, want at most one per 40 ms", draws)
	}
	if fast < kicks-2 || fast > kicks+2 {
		t.Errorf("%d kicks at 16 ms ticks, %d at 50 ms", fast, kicks)
	}
}

// Five minutes of music leave no number out of range.
func TestLongRun(t *testing.T) {
	h := load(t, nil)
	for i := range 6000 {
		checkFrame(t, h.tick(music(128, float64(i)*tick, 1), 3, 20, tick), 3, 20)
	}
	state := h.tunnel()
	for _, v := range []float64{state.beat, state.sure, state.speed, state.travel} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			t.Fatalf("%+v", state)
		}
	}
	if state.sure != 1 || state.travel < 50 {
		t.Fatalf("after five minutes: %+v", state)
	}
}
