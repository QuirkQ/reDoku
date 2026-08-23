module Redoku
  module Sudoku
    # Difficulty, measured as HOW MUCH WORK OF WHAT KIND a board demands of a
    # person. One number, from two measurements composed in series:
    #
    #   1. Run the human technique solver. Every rule it applies costs points,
    #      weighted by how hard that rule is to spot and to know.
    #   2. Whatever it could not finish, measure with the search solver. Those
    #      are the guesses no human technique in our repertoire can avoid, and
    #      they cost a lot each.
    #
    # THE COMPOSITION IS THE POINT. Cost is measured on the RESIDUAL board --
    # the position the technique solver stalled in -- not on the puzzle as
    # dealt. So the second number means "guessing still required after human
    # technique is exhausted" rather than "guessing a machine needs from
    # scratch", and the two measurements describe different work instead of
    # overlapping. A board the techniques finish scores no guess points at
    # all, because there is nothing left to guess about.
    #
    # WHY NOT PURE SEARCH COST, which is what this class did before: because
    # it is the worst-performing family of metrics that has been measured.
    # Pelanek (arXiv:1403.7373) correlates rating metrics against HUMAN solve
    # times over two puzzle sets, and raw backtracking cost scores r = 0.16 /
    # 0.25 -- worse than simply counting the givens (0.25 / 0.27). Technique
    # ratings score 0.70 / 0.86, and a combination of technique rating with
    # propagation-shaped measures reaches 0.84 / 0.95. Search cost is a fine
    # measure of what a COMPUTER finds hard; it is close to useless as a
    # measure of what a person finds hard, which is what a difficulty label on
    # a puzzle claims to be.
    #
    # WHY NOT PURE CLUE COUNT, which is what sudoku.js does (easy 62, medium
    # 53, hard 44 givens and no other signal): measured here, 26-clue boards
    # ranged from no guessing at all to more guessing than most people want.
    # It also needs no separate term, because it is already inside the sum: a
    # board with more holes needs more singles to fill them, so it scores
    # higher on that alone. That is why there is no clue-count rule here --
    # an earlier version had one, and it was double-counting.
    #
    # WHY COUNT USES RATHER THAN TAKE THE MAXIMUM, which is what Sudoku
    # Explainer does: because counting measures better. Pelanek's linear model
    # over how many times each technique was used scores r = 0.78 / 0.86
    # against the max-based rating's 0.70 / 0.86. It also matches intuition
    # that the max cannot express -- one X-wing in an otherwise gentle board
    # is a puzzle you finish, twenty pointing pairs is an evening -- and it is
    # what HoDoKu does in production, where the score is the plain sum over
    # every step taken.
    class Rater
      # Ordered easiest to hardest. Everything here is derived from this list
      # rather than hard-coded, so adding levels is a change to LEVELS and a
      # recalibration, not a change to any logic.
      TIERS = [:easy, :medium, :hard].freeze

      # PER-TECHNIQUE WEIGHTS, taken from HoDoKu's production rater
      # (`Options.java`, verified across three forks) because it is the only
      # published table whose scores are meant to be SUMMED, which is what we
      # do with them. Sudoku Explainer's numbers are per-move ratings designed
      # to be maximised over, so they cannot be added up and are not used
      # here, though the two tables agree closely on relative order.
      #
      # The one ordering worth flagging, because our own ORDER got it wrong
      # for a while: locked candidates (pointing/box-line) is the EASIEST of
      # the eliminators, below both pairs. HoDoKu scores it 50 against naked
      # pair 60 and hidden pair 70; Sudoku Explainer agrees (2.6 against 3.0
      # and 3.4). It is listed late in some tutorials, which is presumably how
      # it came to be treated as harder.
      #
      # Techniques our solver does not implement are still listed. They cost
      # nothing while unimplemented -- a rule that never fires never appears
      # in `counts` -- and having the weight ready is what makes adding the
      # rule a one-file change.
      WEIGHT = {
        naked_single: 4,
        hidden_single: 14,
        pointing: 50,      # locked candidates, both directions
        naked_pair: 60,
        hidden_pair: 70,
        naked_triple: 80,
        hidden_triple: 100,
        x_wing: 140
      }.freeze

      # A technique that fired but has no weight scores as the hardest known
      # rule rather than as free. Deliberately not an exception: this runs
      # inside puzzle generation, where the cost of the safety net firing
      # should be a puzzle rated too hard, never a game that dies mid-tap. But
      # deliberately not zero either -- a rule added to Techniques::ORDER and
      # forgotten here would otherwise be silently free, and no test would
      # catch a difficulty that quietly stopped counting.
      UNKNOWN_WEIGHT = 140

      # What one forced guess costs. Guessing is not a technique, it is the
      # absence of one: the player is reduced to trying a digit and unwinding
      # if it fails, which is why HoDoKu prices its own last resort
      # ("Brute Force") at 10000 against 140 for an X-wing. This is far less
      # brutal than that, because our repertoire is deliberately small -- a
      # board we cannot finish may well be solvable by a technique a good
      # player knows and we simply have not implemented, so calling every such
      # board unplayable would be wrong.
      GUESS = 120

      # The novelty premium: a technique costs full price the first time and
      # less per repeat, expressed as a fraction. Sudoku Of The Day is the one
      # published table that prices first use separately from repeats, and it
      # gives ratios in this neighbourhood throughout -- swordfish 8000 then
      # 6000, naked quad 5000 then 4000, naked pair 750 then 500. The reason
      # they give is that the first use is the hard part: "if you understand
      # the technique, then applying it again won't be quite such a hard
      # step".
      #
      # Integer arithmetic on purpose. `mrb_int` is 32-bit on the device and
      # there is no Rational, so this is a numerator over a denominator rather
      # than a float.
      REPEAT_NUM = 2
      REPEAT_DEN = 3

      # THE FLOOR A TECHNIQUE PUTS UNDER A BOARD. A puzzle that genuinely
      # needed this rule cannot be rated easier than this, whatever its score
      # adds up to.
      #
      # This is the other half of the composition, and it is not decoration --
      # without it the rating is nearly worthless, which was measured rather
      # than reasoned. The summed score is DOMINATED BY SINGLES: a 27-clue
      # board measured here scored 260, of which all 260 came from 36 naked
      # singles and 17 hidden singles, because a board with more holes needs
      # proportionally more singles to fill them. One pointing pair at 50
      # points simply disappears into that, so a score-only rating is close to
      # a clue-count rating wearing a disguise -- the exact thing the research
      # says not to build.
      #
      # HoDoKu solves it the same way and it is worth stating its rule
      # exactly, since ours is that rule: the puzzle's level "cannot be lower
      # than" the level of its hardest step, but a large enough score can push
      # it higher. So the two signals answer different questions -- the
      # hardest technique asks "what did this demand you KNOW?", the score
      # asks "how much of it was there?" -- and the tier is the harder answer.
      #
      # The assignments follow PLAN.md §7, which drew the same three lines
      # before any of this was measured: easy is "singles only", medium
      # "requires pairs/pointing", hard is where the technique solver gives up.
      # The two rules our repertoire gained last are placed above that: a
      # hidden triple and an X-wing are not what §7 meant by "pairs/pointing",
      # and HoDoKu prices them at 100 and 140 against locked candidates at 50.
      #
      # Singles are absent on purpose. They put no floor under anything --
      # they are what every board needs, so a board needing nothing else is
      # free to be easy.
      TECHNIQUE_FLOOR = {
        pointing: :medium,
        naked_pair: :medium,
        hidden_pair: :medium,
        naked_triple: :medium,
        hidden_triple: :hard,
        x_wing: :hard
      }.freeze

      # Band ceilings, easiest first, paired with TIERS. The last is nil,
      # meaning open-ended -- there is no score too high to be hard.
      #
      # CALIBRATED, not borrowed. HoDoKu's own thresholds (800 / 1000 / 1600 /
      # 1800) cannot transfer, and the reason generalises: a cost metric and
      # the propagation strength it is measured against are ONE UNIT. HoDoKu
      # scores against roughly forty techniques and we score against eight, so
      # our sums are smaller and land differently. super-sudoku learned this
      # the expensive way and left the evidence in its source -- its AC3 loop
      # is disabled at solverAC3.ts:119-126 under the comment "I initially
      # didn't count the ac3 iterations as proposed by the paper. But using
      # them now falsifies the tests", because strengthening propagation moved
      # every iteration count off its committed reference numbers. The same
      # trap is why these edges were set AFTER the technique solver gained its
      # triples and X-wing, not before.
      #
      # Measured on the build host along real dig chains, which is the
      # distribution the Generator actually draws from: scores run 97 to about
      # 137 over the shallow two-thirds of a chain, reach 170 to 275 near the
      # uniqueness floor, and jump into the thousands on the minority of boards
      # where the technique solver gives up and guessing takes over. The edges
      # are set so all three tiers are reachable from that distribution rather
      # than at round numbers: at [140, 300] the middle band was measured to be
      # nearly unreachable, because a chain tends to step from the 130s
      # straight past 300 once a stall starts costing guess points.
      CEILING = [130, 230, nil].freeze

      # ACCEPTANCE TOLERANCE, and the answer to "we need a margin of error".
      # A board whose score sits within this much of a band is accepted AS
      # that band by the generator, even though `tier_for` would name it its
      # neighbour. Overlapping bands rather than exact edges is the documented
      # practice: Sudoku Of The Day publishes deliberately overlapping bands
      # and says why -- it "allows the generator an extra bit of leeway as it
      # works to create a puzzle that's still within an acceptable range".
      #
      # TWO FORMS, EITHER OF WHICH SUFFICES, which is stolen wholesale from
      # super-sudoku (generate.ts:211-288: `rateIterationsRelative(cost) <
      # RELATIVE_DRIFT || rateCostsAbsolute(cost) < ABSOLUTE_DRIFT`). Its
      # comment explains why both are needed, and the reasoning transfers
      # exactly: a percentage is meaningless at the easy end of a metric that
      # spans two orders of magnitude, and a fixed number of points is
      # meaningless at the hard end. Our scores run from about 97 to well over
      # 10000, so the same pairing applies.
      #
      # No published grader states a tolerance figure -- these are ours, set
      # from the measured spread within a single clue count.
      TOLERANCE_POINTS = 25
      TOLERANCE_PERCENT = 15

      # Everything known about a board in one pass, because the two solvers
      # are the expensive part and no caller should pay for them twice.
      #
      #   score    the difficulty number
      #   tier     which band that score falls in
      #   guesses  decisions left after the techniques gave up (0 if solved)
      #   counts   how many times each technique was needed
      #   hardest  the hardest single technique needed, or nil
      #   solved   whether human techniques alone finished it
      def self.measure(values)
        result = Techniques.solve(values)
        guesses = result[:solved] ? 0 : Solver.cost(result[:values])
        technique_points = points(result[:counts])
        total = technique_points + (guesses * GUESS)
        {
          score: total,
          tier: tier_for(total, result[:hardest], !result[:solved]),
          guesses: guesses,
          technique_points: technique_points,
          counts: result[:counts],
          hardest: result[:hardest],
          solved: result[:solved]
        }
      end

      # The weighted sum over a technique log, novelty premium included.
      def self.points(counts)
        total = 0
        counts.each_key do |name|
          w = WEIGHT[name] || UNKNOWN_WEIGHT
          n = counts[name]
          # Full price once, then a discounted rate for each repeat.
          total += w + (((n - 1) * w * REPEAT_NUM) / REPEAT_DEN)
        end
        total
      end

      # The tier a stalled board cannot be rated below -- and deliberately NOT
      # the hardest tier, for the same reason this class no longer rates by
      # technique alone: "our eight rules ran out" is a fact about our
      # repertoire, not about the puzzle. A competent player knows XY-wing,
      # swordfish and simple colouring, none of which we implement, so a board
      # we stall on may well be one they would finish without ever guessing.
      # Calling every such board hard would be claiming our blind spot as the
      # puzzle's difficulty.
      #
      # What does the rest of the work is the `guesses` term in the score: a
      # board that really does need trial and error pays 120 points per
      # decision and climbs past the top band on its own. This floor only
      # stops such a board being called EASY, which it certainly is not.
      #
      # Also the right shape for five levels later, where flooring every stall
      # at the top would collapse the two hardest levels into one.
      STALL_FLOOR = :medium

      # The tier of a board, composed from both signals. `score` sets the
      # band; `hardest` and `stalled` can only ever raise it, never lower it.
      #
      # Disjoint by construction, so a board has exactly one tier -- the
      # tolerated overlap lives in `accepts?`, not here, because a puzzle must
      # be LABELLED with one answer even though it may be ACCEPTABLE as two.
      def self.tier_for(score, hardest = nil, stalled = false)
        tier = band_for(score)
        tier = harder_tier(tier, STALL_FLOOR) if stalled
        floor = TECHNIQUE_FLOOR[hardest]
        tier = harder_tier(tier, floor) unless floor.nil?
        tier
      end

      # The first tier whose ceiling the score does not exceed, and the
      # hardest tier if it exceeds them all.
      def self.band_for(score)
        i = 0
        while i < TIERS.size
          ceiling = CEILING[i]
          return TIERS[i] if ceiling.nil? || score <= ceiling
          i += 1
        end
        TIERS[TIERS.size - 1]
      end

      # The harder of two tier names, by position in TIERS. An unknown name
      # loses, so a typo cannot silently promote a board to hard.
      def self.harder_tier(a, b)
        ia = TIERS.index(a)
        ib = TIERS.index(b)
        return a if ib.nil?
        return b if ia.nil?
        ia >= ib ? a : b
      end

      # The score range a tier owns, as [floor, ceiling]; ceiling is nil for
      # the open-ended top tier. The floor is the previous tier's ceiling plus
      # one, so the bands tile the whole range with no gap.
      def self.band(tier)
        i = TIERS.index(tier)
        return nil if i.nil?
        # `i == 0` rather than `i.zero?`: Integer#zero? comes from
        # mruby-numeric-ext, which this gem does not declare, so it would pass
        # on the device (the binary links the whole default gembox) and crash
        # under `make test`. That asymmetry has bitten this repo before.
        floor = i == 0 ? 0 : CEILING[i - 1] + 1
        [floor, CEILING[i]]
      end

      # Would this score do, as this tier? The generator's accept test, and
      # the margin of error: TOLERANCE points of slack at each end, so a board
      # just over an edge is still usable rather than thrown away and
      # regenerated. `tier_for` remains the honest label -- this only decides
      # whether to keep looking.
      # Strictly inside the band, no indulgence. This is the test that DRIVES
      # a search: while there may still be a board that genuinely belongs in
      # the requested tier, a near miss is not good enough.
      def self.in_band?(tier, score)
        range = band(tier)
        return false if range.nil?
        return false if score < range[0]
        range[1].nil? || score <= range[1]
      end

      # Inside the band, or near enough. This is the test that GATES a result:
      # once a search has looked at everything available and found nothing
      # squarely inside, a near miss beats regenerating from scratch.
      #
      # The split matters, and getting it wrong was measured: with only this
      # tolerant test driving the walk, a :medium request accepted boards
      # scoring 108 against a band starting at 131, because the slack at the
      # low edge let through the tier below -- 12 requests for medium returned
      # 12 easy boards. The tolerance is there to forgive a board for
      # OVERSHOOTING what was asked, not to excuse the search from looking.
      def self.accepts?(tier, score)
        range = band(tier)
        return false if range.nil?
        return true if in_band?(tier, score)
        return slack(range[0]) >= range[0] - score if score < range[0]
        slack(range[1]) >= score - range[1]
      end

      # The slack allowed at a band edge: a flat number of points, or a
      # percentage of the edge, whichever is the more generous. See
      # TOLERANCE_POINTS for why it has to be both.
      def self.slack(edge)
        by_percent = (edge * TOLERANCE_PERCENT) / 100
        by_percent > TOLERANCE_POINTS ? by_percent : TOLERANCE_POINTS
      end

      def self.rate(values)
        measure(values)[:tier]
      end

      def self.score(values)
        measure(values)[:score]
      end

      def self.clue_count(values)
        n = 0
        values.each { |d| n += 1 if d != 0 }
        n
      end
    end
  end
end
