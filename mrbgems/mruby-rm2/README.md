# mruby-rm2

mruby client for the [rM2-stuff](https://github.com/timower/rM2-stuff)
`rm2fb` display server on the reMarkable 2.

```ruby
d = RM2::Display.open               # or .open("/path/to/rm2fb.sock")
d.fill_rect(0, 0, d.width, d.height, 255)      # white; gray is 0..255
d.fill_rect(100, 100, 200, 200, 0)             # black square
d.update(0, 0, d.width, d.height,
         waveform: RM2::GC16, flags: RM2::SYNC) # flush to the panel
d.pixel(100, 100)  # => 0x0000 (RGB565 readback)
d.close
```

Waveforms: `RM2::DU` (fast pen ink), `RM2::GL16` (UI), `RM2::GC16` (full,
flashing refresh), `RM2::A2`. Flags: `RM2::SYNC`, `RM2::FAST_DRAW`.
`#update` returns the server's ack — `false` means another client is front
and the update was dropped.

Tests run against a fake protocol server (`test/fake_server.c`, forked by
mrbtest via the `mrb_mruby_rm2_gem_test` hook) — see `test/display.rb`.
Protocol reference: `PLAN.md` §3 in the repo root.
