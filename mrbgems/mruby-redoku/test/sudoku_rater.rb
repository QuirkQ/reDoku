assert('Rater.points weights each use and discounts repeats') do
  r = Redoku::Sudoku::Rater
  # One use of a rule costs its full weight.
  assert_equal(r::WEIGHT[:naked_single], r.points({ naked_single: 1 }))
  assert_equal(r::WEIGHT[:x_wing], r.points({ x_wing: 1 }))

  # A repeat costs the discounted rate, not the full one. Derived from the
  # constants rather than written in as a literal, so the assertion follows
  # the premium if it is ever retuned.
  w = r::WEIGHT[:pointing]
  expected = w + ((1 * w * r::REPEAT_NUM) / r::REPEAT_DEN)
  assert_equal(expected, r.points({ pointing: 2 }))
  assert_true r.points({ pointing: 2 }) < 2 * w  # genuinely a discount
  assert_true r.points({ pointing: 2 }) > w      # but still costs something

  # Rules add up independently.
  assert_equal(r::WEIGHT[:naked_single] + r::WEIGHT[:hidden_single],
               r.points({ naked_single: 1, hidden_single: 1 }))

  # An empty log is free -- a board that needed nothing scores nothing.
  assert_equal(0, r.points({}))
end

assert('Rater.points charges an unweighted technique as the hardest, not as free') do
  r = Redoku::Sudoku::Rater
  # A rule added to Techniques::ORDER but forgotten in WEIGHT must not be
  # silently free: that is a difficulty that quietly stopped counting, and no
  # other test would notice. It must not raise either -- this runs inside
  # generation, and a puzzle rated too hard beats a game that dies mid-tap.
  assert_equal(r::UNKNOWN_WEIGHT, r.points({ some_future_rule: 1 }))
  assert_true r::UNKNOWN_WEIGHT > r::WEIGHT[:naked_single]
end

assert('Rater weights rank locked candidates below the pairs') do
  r = Redoku::Sudoku::Rater
  # Both published graders agree on this and an earlier version of ours had it
  # backwards, ranking pointing as the hardest of the eliminators. HoDoKu:
  # locked candidates 50, naked pair 60, hidden pair 70. Sudoku Explainer:
  # pointing 2.6, naked pair 3.0, hidden pair 3.4.
  assert_true r::WEIGHT[:pointing] < r::WEIGHT[:naked_pair]
  assert_true r::WEIGHT[:naked_pair] < r::WEIGHT[:hidden_pair]
  # And the singles are cheaper than every eliminator.
  assert_true r::WEIGHT[:naked_single] < r::WEIGHT[:pointing]
  assert_true r::WEIGHT[:hidden_single] < r::WEIGHT[:pointing]
  # X-wing is the dearest rule we implement.
  r::WEIGHT.each_key do |name|
    assert_true r::WEIGHT[name] <= r::WEIGHT[:x_wing]
  end
end

assert('Rater bands tile the whole score range with no gap or overlap') do
  r = Redoku::Sudoku::Rater
  # The tier table is meant to be data-driven so that adding levels is a
  # change to CEILING and TIERS alone. This pins the derivation rather than
  # the current three values: every band starts exactly one point above the
  # previous band's ceiling, the first starts at zero, and the last is open.
  assert_equal(r::TIERS.size, r::CEILING.size)
  assert_equal(0, r.band(r::TIERS[0])[0])
  i = 1
  while i < r::TIERS.size
    assert_equal(r::CEILING[i - 1] + 1, r.band(r::TIERS[i])[0])
    i += 1
  end
  assert_nil r.band(r::TIERS[r::TIERS.size - 1])[1]
  # Ceilings ascend, or the bands would not be ordered by difficulty at all.
  i = 1
  while i < r::CEILING.size - 1
    assert_true r::CEILING[i] > r::CEILING[i - 1]
    i += 1
  end
  # An unknown tier has no band rather than a wrong one.
  assert_nil r.band(:nonexistent)
end

assert('Rater.band_for places a score in exactly one band') do
  r = Redoku::Sudoku::Rater
  easy = r::TIERS[0]
  hardest = r::TIERS[r::TIERS.size - 1]
  assert_equal(easy, r.band_for(0))
  assert_equal(easy, r.band_for(r::CEILING[0]))
  # One point over the edge is the next band up -- the edges are exact here,
  # and the tolerance lives in accepts? instead.
  assert_equal(r::TIERS[1], r.band_for(r::CEILING[0] + 1))
  # Nothing is too hard for the top band.
  assert_equal(hardest, r.band_for(1_000_000))
end

assert('Rater.harder_tier takes the harder of two, and unknowns lose') do
  r = Redoku::Sudoku::Rater
  assert_equal(:hard, r.harder_tier(:easy, :hard))
  assert_equal(:hard, r.harder_tier(:hard, :easy))
  assert_equal(:medium, r.harder_tier(:medium, :medium))
  # A typo must not silently promote a board.
  assert_equal(:easy, r.harder_tier(:easy, :typo))
  assert_equal(:easy, r.harder_tier(:typo, :easy))
end

assert('Rater.tier_for lets a technique raise the tier but never lower it') do
  r = Redoku::Sudoku::Rater
  # This is the composition that makes the rating worth having. The score
  # alone is dominated by singles -- a board with more holes needs more of
  # them -- so without a floor from the hardest technique, one X-wing
  # disappears into forty naked singles and the rating is a clue count in
  # disguise. HoDoKu's rule, which this is: the level cannot be lower than
  # that of the hardest step, but a big enough score can push it higher.
  easy_score = 0

  # Nothing but singles: the score decides, and singles put no floor under
  # anything because every board needs them.
  assert_equal(r::TIERS[0], r.tier_for(easy_score))
  assert_equal(r::TIERS[0], r.tier_for(easy_score, :naked_single))
  assert_equal(r::TIERS[0], r.tier_for(easy_score, :hidden_single))

  # An eliminator raises a trivially-scoring board off the bottom.
  assert_equal(:medium, r.tier_for(easy_score, :pointing))
  assert_equal(:medium, r.tier_for(easy_score, :naked_pair))
  assert_equal(:hard, r.tier_for(easy_score, :x_wing))
  assert_equal(:hard, r.tier_for(easy_score, :hidden_triple))

  # But a floor never DROPS a board that scored its way up. A huge score with
  # only an easy technique needed is still hard.
  assert_equal(:hard, r.tier_for(1_000_000, :pointing))
  assert_equal(:hard, r.tier_for(1_000_000, :naked_single))
  assert_equal(:hard, r.tier_for(1_000_000))

  # Every floor in the table is a real tier, or a board could be floored to
  # nothing at all.
  r::TECHNIQUE_FLOOR.each_key do |name|
    assert_true r::TIERS.include?(r::TECHNIQUE_FLOOR[name])
  end
  # And singles are deliberately absent from it.
  assert_false r::TECHNIQUE_FLOOR.has_key?(:naked_single)
  assert_false r::TECHNIQUE_FLOOR.has_key?(:hidden_single)
end

assert('Rater.tier_for floors a stalled board short of the hardest tier') do
  r = Redoku::Sudoku::Rater
  # A stall says our eight rules ran out, which is a fact about our
  # repertoire: a competent player knows XY-wing, swordfish and colouring and
  # we implement none of them. So a stall may not be called hard on its own --
  # it is the guess points in the score that do that. What the floor does
  # guarantee is that such a board is never called EASY.
  assert_equal(r::STALL_FLOOR, r.tier_for(0, nil, true))
  assert_false r.tier_for(0, nil, true) == r::TIERS[0]
  assert_false r.tier_for(0, nil, true) == r::TIERS[r::TIERS.size - 1]
  # And a stall still cannot lower a board that scored higher.
  assert_equal(:hard, r.tier_for(1_000_000, nil, true))
end

assert('Rater.in_band? is strict and accepts? forgives, in that order') do
  r = Redoku::Sudoku::Rater
  medium = r::TIERS[1]
  range = r.band(medium)
  lo = range[0]
  hi = range[1]

  # Strict: the band and nothing but the band.
  assert_true r.in_band?(medium, lo)
  assert_true r.in_band?(medium, hi)
  assert_false r.in_band?(medium, lo - 1)
  assert_false r.in_band?(medium, hi + 1)

  # Tolerant: a near miss on either side is still acceptable.
  assert_true r.accepts?(medium, lo - 1)
  assert_true r.accepts?(medium, hi + 1)
  # But not an arbitrary distance. This is the case that was actually wrong:
  # driving the generator's walk with the tolerant test made a :medium request
  # accept boards scoring 108 against a band starting at 131, and twelve
  # requests for medium returned twelve easy boards.
  assert_false r.accepts?(medium, lo - r.slack(lo) - 1)
  assert_false r.accepts?(medium, hi + r.slack(hi) + 1)
  # Which is only meaningful if the slack is smaller than the band it guards.
  assert_true r.slack(lo) < hi - lo

  # The open-ended top band forgives nothing above it, because there is no
  # above it.
  hardest = r::TIERS[r::TIERS.size - 1]
  assert_true r.in_band?(hardest, 1_000_000)
  assert_true r.accepts?(hardest, 1_000_000)
  # An unknown tier accepts nothing.
  assert_false r.accepts?(:nonexistent, 100)
  assert_false r.in_band?(:nonexistent, 100)
end

assert('Rater.slack is the more generous of a flat and a proportional margin') do
  r = Redoku::Sudoku::Rater
  # Both forms are needed because the metric spans two orders of magnitude: a
  # percentage is meaningless at the easy end and a flat number of points is
  # meaningless at the hard end. Stolen from super-sudoku, whose accept test
  # is `relative < 20% || absolute < 3` for exactly this reason.
  assert_equal(r::TOLERANCE_POINTS, r.slack(0))       # flat form wins small
  assert_true r.slack(100_000) > r::TOLERANCE_POINTS  # proportional wins big
  assert_equal((100_000 * r::TOLERANCE_PERCENT) / 100, r.slack(100_000))
  # Monotone: a higher edge never gets less slack.
  assert_true r.slack(1000) >= r.slack(100)
end

assert('Rater.measure reports a finished board as needing nothing') do
  r = Redoku::Sudoku::Rater
  m = r.measure(solved_values)
  assert_equal(0, m[:score])
  assert_equal(0, m[:guesses])
  assert_equal(0, m[:technique_points])
  assert_equal({}, m[:counts])
  assert_nil m[:hardest]
  assert_true m[:solved]
  assert_equal(r::TIERS[0], m[:tier])
end

assert('Rater.measure adds guess points only for what techniques cannot finish') do
  r = Redoku::Sudoku::Rater
  # The two measurements compose in series: cost is taken on the RESIDUAL
  # board the technique solver stalled in, so it means "guessing still needed
  # after human technique is exhausted" rather than "guessing a machine needs
  # from scratch". A board the techniques finish therefore scores no guess
  # points at all, however much a search would have flailed on it.
  easy = r.measure(values_of(EASY_81))
  assert_true easy[:solved]
  assert_equal(0, easy[:guesses])
  assert_equal(easy[:technique_points], easy[:score])

  # MULTI_81 has three givens: no technique can force anything, so it stalls
  # immediately and the whole board is guesswork.
  multi = r.measure(values_of(MULTI_81))
  assert_false multi[:solved]
  assert_true multi[:guesses] > 0
  assert_equal(multi[:technique_points] + (multi[:guesses] * r::GUESS),
               multi[:score])
  # And it is not rated easy.
  assert_false multi[:tier] == r::TIERS[0]
end

assert('Rater.measure scores a board with more holes above one with fewer') do
  r = Redoku::Sudoku::Rater
  # Not a claim that clue count is difficulty -- it is a weak predictor and is
  # deliberately not a term in the score. It is a claim about the SUM: more
  # holes need more singles to fill them, so more work is more points. This is
  # the property that makes the score usable as a gradient by the Generator,
  # which walks a chain of ever-emptier boards looking for a target.
  few = r.measure(values_of(EASY_81))     # 79 clues
  more = r.measure(values_of(UNIQUE_81))  # 75 clues
  assert_true more[:score] > few[:score]
end

assert('Rater.rate and Rater.score agree with measure') do
  r = Redoku::Sudoku::Rater
  values = values_of(UNIQUE_81)
  m = r.measure(values)
  assert_equal(m[:tier], r.rate(values))
  assert_equal(m[:score], r.score(values))
  # Every board gets a real tier; rate never answers nil.
  [SOLVED_81, EASY_81, UNIQUE_81, MULTI_81].each do |board|
    assert_true r::TIERS.include?(r.rate(values_of(board)))
  end
  assert_true r::TIERS.include?(r.rate(Array.new(81, 0)))
end

assert('Rater is deterministic and does not mutate the board it rates') do
  r = Redoku::Sudoku::Rater
  values = values_of(EASY_81)
  before = values.dup
  first = r.measure(values)
  assert_equal(before, values)
  # Same board, same answer. The Generator steers by this number, and a rating
  # that wobbled would be steering by noise.
  second = r.measure(values)
  assert_equal(first[:score], second[:score])
  assert_equal(first[:tier], second[:tier])
end

assert('Rater.clue_count counts the filled cells') do
  r = Redoku::Sudoku::Rater
  assert_equal(81, r.clue_count(solved_values))
  assert_equal(79, r.clue_count(values_of(EASY_81)))
  assert_equal(75, r.clue_count(values_of(UNIQUE_81)))
  assert_equal(3, r.clue_count(values_of(MULTI_81)))
  assert_equal(0, r.clue_count(Array.new(81, 0)))
end

assert('Rater tiers are ordered easiest first') do
  r = Redoku::Sudoku::Rater
  assert_equal([:easy, :medium, :hard], r::TIERS)
  # Nothing may assume there are exactly three: the owner wants five levels
  # later, and everything here is derived from TIERS and CEILING so that
  # adding them is a change to those two lists plus a recalibration.
  assert_true r::TIERS.size >= 2
end
