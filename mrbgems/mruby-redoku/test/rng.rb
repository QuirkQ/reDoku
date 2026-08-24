assert('Rng matches the published Park-Miller sequence') do
  # The point of this assertion is that it checks against an EXTERNAL
  # reference rather than against our own output. Park-Miller (the "minimal
  # standard" generator, a = 16807, m = 2**31 - 1) seeded with 1 produces a
  # sequence that is documented in the literature, so if Schrage's
  # decomposition below is implemented wrongly this fails against a number
  # nobody here chose.
  r = Redoku::Rng.new(1)
  assert_equal 16807, r.next_raw
  assert_equal 282475249, r.next_raw
  assert_equal 1622650073, r.next_raw
  assert_equal 984943658, r.next_raw
  assert_equal 1144108930, r.next_raw
  assert_equal 470211272, r.next_raw
  assert_equal 101027544, r.next_raw
  assert_equal 1457850878, r.next_raw
  assert_equal 1458777923, r.next_raw
  assert_equal 2007237709, r.next_raw

  # The classic conformance check: the 10000th value from seed 1.
  r2 = Redoku::Rng.new(1)
  v = 0
  10000.times { v = r2.next_raw }
  assert_equal 1043618065, v
end

assert('Rng never leaves the 31-bit range that 32-bit mrb_int allows') do
  # This is the property the whole design exists for. mrb_int is 32-bit
  # SIGNED on the armv7 device (mruby's mrbconf.h defines MRB_INT32 whenever
  # the architecture is 32-bit), so a generator whose state or intermediates
  # exceed 2**31 - 1 works on the 64-bit host and breaks on the tablet.
  # Schrage's decomposition keeps every intermediate under the limit; this
  # checks the observable half of that.
  limit = 2147483647
  r = Redoku::Rng.new(12345)
  2000.times do
    v = r.next_raw
    assert_true v >= 1
    assert_true v <= limit
  end
  # And a hostile seed cannot push it out of range either.
  [0, 1, -1, -99999, limit, limit - 1].each do |seed|
    s = Redoku::Rng.new(seed)
    50.times do
      v = s.next_raw
      assert_true v >= 1 && v <= limit
    end
  end
end

assert('Rng is deterministic for a seed and varies across seeds') do
  a = Redoku::Rng.new(12345)
  b = Redoku::Rng.new(12345)
  10.times { assert_equal a.next_int(1000), b.next_int(1000) }

  c = Redoku::Rng.new(999)
  d = Redoku::Rng.new(12345)
  first = []
  second = []
  10.times { first << c.next_int(1000) }
  10.times { second << d.next_int(1000) }
  assert_false first == second
end

assert('Rng.next_int stays inside its bound and spreads over it') do
  r = Redoku::Rng.new(7)
  200.times do
    n = r.next_int(10)
    assert_true n >= 0
    assert_true n < 10
  end

  # The degenerate bounds must not divide by zero or loop.
  assert_equal 0, r.next_int(1)
  assert_equal 0, r.next_int(0)
  assert_equal 0, r.next_int(-5)

  # Every bucket of a small range should appear. A generator stuck on one
  # value passes the bounds check above and is still useless.
  seen = {}
  r2 = Redoku::Rng.new(3)
  300.times { seen.store(r2.next_int(5), true) }
  assert_equal 5, seen.keys.size

  # Nine buckets too, since picking one of nine digits is what this is for.
  seen9 = {}
  r3 = Redoku::Rng.new(31)
  600.times { seen9.store(r3.next_int(9), true) }
  assert_equal 9, seen9.keys.size
end

assert('Rng.shuffle permutes without losing or duplicating elements') do
  source = []
  20.times { |i| source << i }
  r = Redoku::Rng.new(42)
  out = r.shuffle(source)

  assert_equal source.size, out.size
  assert_equal source, out.sort   # same multiset, so nothing lost or doubled
  assert_false source == out      # and actually reordered

  # The input is not mutated: callers shuffle constants like Grid::UNITS.
  assert_equal 20, source.size
  assert_equal 0, source[0]
  assert_equal 19, source[19]

  # Same seed, same permutation; different seed, different one.
  assert_equal r_shuffle_with_seed(source, 5), r_shuffle_with_seed(source, 5)
  assert_false r_shuffle_with_seed(source, 5) == r_shuffle_with_seed(source, 6)

  # Degenerate sizes are permutations too, not crashes.
  assert_equal [], Redoku::Rng.new(1).shuffle([])
  assert_equal [9], Redoku::Rng.new(1).shuffle([9])
end

assert('Rng.shuffle reaches many different permutations') do
  # Fisher-Yates walked the wrong way, or drawing from the wrong sub-range,
  # yields a shuffle that is technically a permutation but visits only a
  # handful of them. Sample the first element over many seeds: with a fair
  # shuffle of nine items every position should show up.
  seen = {}
  source = [1, 2, 3, 4, 5, 6, 7, 8, 9]
  200.times { |s| seen.store(Redoku::Rng.new(s + 1).shuffle(source)[0], true) }
  assert_equal 9, seen.keys.size
end

assert('Rng.clock_seed mixes both halves of the clock') do
  r = Redoku::Rng
  # Sensitive to the sub-second half: two launches in the same second must
  # not share a puzzle.
  assert_false r.clock_seed(1_700_000_000, 0) == r.clock_seed(1_700_000_000, 1)
  # And to the seconds half.
  assert_false r.clock_seed(1_700_000_000, 5) == r.clock_seed(1_700_000_001, 5)
  # It must stay inside a 32-bit SIGNED mrb_int, which is what the device
  # has. A seed that overflows into Float promotion there would degrade
  # puzzle variety on hardware while passing every host test.
  assert_true r.clock_seed(1_700_000_000, 999_999) < 1073741824
  assert_true r.clock_seed(1_700_000_000, 999_999) >= 0
end

assert('Rng seeded from a clock-sized value still spreads its draws') do
  # Until now Rng only ever saw small test seeds. From here it receives a
  # ~1.7e9 clock seed on a device whose mrb_int is 32-bit signed, so drive
  # it from a realistic seed and check it has not degenerated.
  r = Redoku::Rng.new(Redoku::Rng.clock_seed(1_700_000_000, 123_456))
  seen = {}
  300.times { seen.store(r.next_int(5), true) }
  assert_equal 5, seen.keys.size
  200.times do
    n = r.next_int(10)
    assert_true n >= 0
    assert_true n < 10
  end
end

assert('Rng.from_clock reads the clock exactly once') do
  # One reading, not two: `Time.now.to_i ^ Time.now.usec` can straddle a
  # second boundary and mix a fresh microsecond into a stale second.
  probe = OneShotClock.new(1_700_000_000, 424_242)
  rng = Redoku::Rng.from_clock(probe)
  assert_equal 1, probe.reads
  assert_equal Redoku::Rng.clock_seed(1_700_000_000, 424_242),
               probe.seed_seen
  assert_false rng.nil?
end
