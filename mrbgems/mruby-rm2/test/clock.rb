assert('RM2.monotonic_ms counts milliseconds forward') do
  t0 = RM2.monotonic_ms
  assert_true t0 >= 0, "first reading was #{t0}: the epoch is the first call"
  # RM2::Input.wait with nothing to watch is this gem's sleep primitive
  # (poll(NULL, 0, ms) — see input.c), so this measures the clock against a
  # real interval without pulling Time into the assertion.
  assert_false RM2::Input.wait([], 50)
  t1 = RM2.monotonic_ms
  assert_true t1 - t0 >= 45, "moved #{t1 - t0} ms across a 50 ms wait"
  assert_true t1 - t0 < 5000, "moved #{t1 - t0} ms across a 50 ms wait"
  # Never backwards, which is the whole reason this is not Time.now: a wall
  # clock steps, and a cooldown measured against one can stall or vanish.
  assert_true RM2.monotonic_ms >= t1
end
