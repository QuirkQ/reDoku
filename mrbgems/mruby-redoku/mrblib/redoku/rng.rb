module Redoku
  # A seeded pseudo-random generator, because `Kernel#rand` does not exist in
  # this gem's mrbtest state and borrowing `mruby-random` is not free:
  # declaring a new test dependency renumbers the generated test ireps, so
  # every contributor's incremental build stops compiling until they
  # `make clean`. That cost was paid once already in M1's fix wave A and is
  # not worth paying again for `rand`.
  #
  # Being seeded is a feature rather than a consolation. Generation is a
  # search, so a bug in it is a bug in one particular puzzle; a seed turns
  # that puzzle into a test instead of a story. It also means the host and
  # the device produce identical boards for identical seeds, which is what
  # lets a host test stand in for the device at all.
  #
  # ALGORITHM — Park-Miller ("minimal standard"), state' = 16807 * state mod
  # (2**31 - 1), implemented with SCHRAGE's decomposition. The choice is
  # driven entirely by integer width, not by statistical quality:
  #
  #   mrb_int is 32-bit SIGNED on the device. mruby's mrbconf.h defines
  #   MRB_INT32 whenever the architecture is 32-bit, and armv7 is, while the
  #   build host is 64-bit and gets MRB_INT64. So any generator whose state
  #   or intermediates exceed 2**31 - 1 works perfectly in `make test` and
  #   misbehaves on the tablet — the exact host/device split that has bitten
  #   this project repeatedly. A plain xorshift32 is out for that reason: it
  #   needs a 0xffffffff mask, and that literal alone is already larger than
  #   the device's Integer can hold.
  #
  #   Schrage's trick exists to make this multiplication overflow-free in
  #   exactly 31 bits. With q = m / a = 127773 and r = m % a = 2836, the two
  #   products are bounded by a * (q - 1) = 2_147_464_004 and r * (m / q) =
  #   47_664_652, both under 2**31 - 1 = 2_147_483_647. Nothing here can
  #   overflow on either build, and that is checked by a test rather than
  #   asserted by this comment.
  #
  # Period is 2**31 - 2 and the low bits are the weak ones, which is why
  # next_int reads from the top. Nothing here is cryptographic and nothing
  # here needs to be: it picks which cell and which digit to try first.
  class Rng
    M = 2147483647 # 2**31 - 1, prime, and exactly INT32_MAX
    A = 16807
    Q = 127773     # M / A
    R = 2836       # M % A

    # Seeds from the wall clock, which is the only varying source available:
    # Kernel#rand, srand and Random are all absent from this gem's mrbtest
    # state, and RM2.monotonic_ms cannot be used because its epoch is the
    # first call in the process (mruby-rm2's src/clock.c) — a seed default
    # would BE that first call and would return 0 on every single launch,
    # which is the identical-puzzle bug this method exists to prevent.
    #
    # `now` is a parameter so the reading can be faked in a test. It is read
    # ONCE, deliberately: two separate Time.now calls can straddle a second
    # boundary and mix a fresh microsecond into a stale second.
    def self.from_clock(now = Time.now)
      new(clock_seed(now.to_i, now.usec))
    end

    # Masked to 30 bits so the result always fits the device's 32-bit signed
    # mrb_int with room to spare, rather than relying on Float promotion.
    # XOR rather than a sum or a concatenation because both halves must
    # matter: the seconds alone repeat for a whole second, and the
    # microseconds alone repeat every second.
    def self.clock_seed(secs, usec)
      (secs ^ usec) & 0x3fffffff
    end

    # State must be in 1..M-1: zero is a fixed point of the recurrence and
    # would emit nothing but zero for ever. Any seed is accepted and folded
    # into range rather than rejected, so callers may pass a tick count or a
    # pid without checking it first. Seed 1 therefore starts at state 1,
    # which is what makes the published reference sequence testable.
    def initialize(seed = 1)
      s = seed.abs % M
      @state = s == 0 ? 1 : s
    end

    # The raw generator output, 1..M-1. Public because the conformance test
    # pins it against the published Park-Miller sequence, which is the only
    # way to check this implementation against something nobody here chose.
    def next_raw
      hi = @state / Q
      lo = @state % Q
      t = A * lo - R * hi
      @state = t > 0 ? t : t + M
      @state
    end

    # 0 <= result < n, and 0 for any n that names no range at all. Shifts
    # first because an LCG's low bits are its weakest and `% n` alone would
    # lean on precisely those; >> 10 leaves 21 bits, far more than the 9-way
    # choices this makes.
    def next_int(n)
      return 0 if n <= 1
      (next_raw >> 10) % n
    end

    # Fisher-Yates over a COPY, walked downwards so each position draws from
    # the still-untouched head. A copy because callers shuffle constants —
    # Grid::UNITS, the generator's dig order — and must not have them
    # rewritten underneath them.
    def shuffle(list)
      out = list.dup
      i = out.size - 1
      while i > 0
        j = next_int(i + 1)
        tmp = out[i]
        out[i] = out[j]
        out[j] = tmp
        i -= 1
      end
      out
    end
  end
end
