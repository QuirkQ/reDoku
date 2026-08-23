# mruby-rm2

mruby client for the [rM2-stuff](https://github.com/timower/rM2-stuff)
`rm2fb` display server on the reMarkable 2.

```ruby
d = RM2::Display.open               # or .open("/path/to/rm2fb.sock")
d.fill_rect(0, 0, d.width, d.height, 255)      # white; gray is 0..255
d.fill_rect(100, 100, 200, 200, 0)             # black square
d.draw_line(100, 100, 300, 400, 4, 0)          # 4px black line
d.update(0, 0, d.width, d.height,
         waveform: RM2::GC16, flags: RM2::SYNC) # flush to the panel
d.pixel(100, 100)  # => 0x0000 (RGB565 readback)
d.close
```

Waveforms: `RM2::DU` (fast pen ink), `RM2::GL16` (UI), `RM2::GC16` (full,
flashing refresh), `RM2::A2`. Flags: `RM2::SYNC`, `RM2::FAST_DRAW`.
`#update` returns the server's ack — `false` means another client is front
and the update was dropped. `fill_rect`/`update` take exclusive width/height
and clip to the panel; negative extents raise `ArgumentError`. `draw_line`
stamps a square brush of `width` px on each point of the line, centred but
biased up-left for even widths. Its `width` must be `1..65535`, and every
coordinate it is given must be within `-65535..65535` — off-panel geometry is
clipped, but a coordinate outside that range raises `ArgumentError` rather
than being clipped, because `mrb_int` is 32-bit on the device and the
difference of two far-apart endpoints wraps there. Panel coordinates are
never anywhere near the bound; arithmetic gone wrong is what reaches it.

```ruby
paths  = RM2::Input.resolve_all('Wacom I2C Digitizer')  # real node + uinput clone
inputs = paths.map { |p| d.open_input(p) }
while RM2::Input.wait(inputs, 100)
  inputs.each do |i|
    i.pending_events.each { |x, y, pressure, tools| ... }
  end
end
```

`resolve_all` is plural because the display server publishes uinput clones of
each device under the same evdev name (real pen events go to the hardware
node, TCP-injected ones to the clone), so a client that wants both opens
every match. Input fds are requested over the display connection — the
server allows one socket per PID. A sample is `[x, y, pressure, tools]` in
raw device coordinates, one per `SYN_REPORT`; `tools` is a bitmask of
`RM2::Input::PEN`, `RUBBER`, `TOUCH` and `FINGER`.

`TOUCH` is evdev's `BTN_TOUCH`: **the pen tip pressed against the glass, not
a finger.** A finger is `FINGER`, and it comes from a different device — the
`pt_mt` touchscreen, whose contacts are reported through the multitouch axes
(`ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X`/`_Y`) with no
`BTN_TOUCH` and no pressure at all. Those axes are decoded down to **one
contact**: the first to arrive sets `FINGER` and reports its position in the
sample's `x`/`y`, and further contacts are ignored until they lift and press
again. That is enough to tap a button, which is what the touchscreen is for
here; a gesture recogniser would need per-slot tracking, which this does not
do.

An input can hang up while still open — rm2fb restarting tears down the
uinput clones, and the kernel then reports `POLLHUP` and EOF. `wait` and
`pending_events` both set `#hung_up?` when they see it, and a hung-up input
never reports readable again, so close it and drop it from the list you pass
to `wait`. `#closed?` stays false: the fd is still yours to close. `wait`
leaves hung-up inputs out of its `poll`, so a list of nothing but dead ones
(or an empty list) still takes the whole timeout instead of returning at
once — a caller that has not dropped them yet gets a paced loop, not a
busy-spin.

```ruby
RM2::Control.clients        # => [{pid: 1232, active: true, name: "xochitl"}, ...]
RM2::Control.switch_to(pid) # hand the panel to another client

RM2.setup_signals           # SIGTERM/SIGINT -> RM2.terminated?, SIGCONT -> RM2.resumed?
RM2.monotonic_ms            # ms on a clock that never steps; differences only
```

The control socket is a separate `SOCK_DGRAM` RPC endpoint at
`RM2::Control::SOCKET_PATH` (`/var/run/rm2fb.control.sock`), not the display
connection, so `clients` can inspect the server without taking the screen.
Both methods take an optional path so tests can point at a fake.

Never `switch_to` away from a live display client of your own process: the
server SIGSTOPs the demoted client's whole process group, so the call would
freeze the caller. Give the screen back by closing the display and exiting.

`monotonic_ms` measures short intervals — how long ago the pen left the
glass, how long a stroke has been idle — from `CLOCK_MONOTONIC`, which a
clock correction cannot move. Its epoch is the first call, not boot, so the
count stays inside the device build's 32-bit `mrb_int`; only differences
between two readings are meaningful.

`terminated?` is sticky — once the process has been asked to quit it stays
true. `resumed?` is consumed on read: each SIGCONT is reported exactly once,
which is the cue to repaint everything rather than trust what is on the
panel. Handlers are installed without `SA_RESTART`, so a signal cuts a
blocking `RM2::Input.wait` short and the event loop gets a turn to look at
the flags. `setup_signals` also ignores SIGPIPE, so a dead server surfaces as
a `SystemCallError` from the next `#update` instead of killing the process.

Tests run against a fake protocol server (`test/fake_server.c`, forked by
mrbtest via the `mrb_mruby_rm2_gem_test` hook) — see `test/display.rb`. The
control socket has its own independent fake in the same file
(`start_control`/`stop_control`) — see `test/control.rb`.
Protocol reference: `PLAN.md` §3 in the repo root.
