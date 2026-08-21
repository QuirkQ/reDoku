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
biased up-left for even widths.

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
`RM2::Input::PEN`, `RUBBER` and `TOUCH`, where `TOUCH` is evdev's
`BTN_TOUCH` — the pen tip pressed against the glass, not a finger. Only
`ABS_X`, `ABS_Y` and `ABS_PRESSURE` are decoded, so the `pt_mt` touchscreen
(which reports `ABS_MT_POSITION_X`/`_Y` instead) would yield samples with
all-zero coordinates until multitouch axes are added.

An input can hang up while still open — rm2fb restarting tears down the
uinput clones, and the kernel then reports `POLLHUP` and EOF. `wait` and
`pending_events` both set `#hung_up?` when they see it, and a hung-up input
never reports readable again, so close it and drop it from the list you pass
to `wait`. `#closed?` stays false: the fd is still yours to close.

Tests run against a fake protocol server (`test/fake_server.c`, forked by
mrbtest via the `mrb_mruby_rm2_gem_test` hook) — see `test/display.rb`.
Protocol reference: `PLAN.md` §3 in the repo root.
