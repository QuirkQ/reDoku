module Redoku
  module Sudoku
    # Puzzle construction: fill a board at random, punch rotationally
    # symmetric holes in it for as long as it stays uniquely solvable, then
    # pick the point along that sequence of holes where the puzzle is as hard
    # as was asked for.
    #
    # THE SHAPE, and it is worth understanding before editing, because the
    # obvious version is much slower:
    #
    # Digging and rating are SEPARATED. One pass digs as deep as uniqueness
    # allows, keeping the list of removals it made but never rating anything;
    # that costs about 74 ms. Rating is 12 ms a board, so rating after every
    # removal would cost more than the dig itself, several times over. The
    # removal list is then treated as what it is: a CHAIN of boards from 81
    # clues down to the floor, walked from the shallow end until one is hard
    # enough, and the first such board is the answer.
    #
    # WALKED, NOT HALVED, and both halves of that were measured before being
    # believed. The chain is short -- 26 or 27 removals, of which the shallow
    # end is unusable because a board with more than MAX_CLUES clues is not a
    # puzzle -- so the searchable window is only seven to nine boards, and
    # halving eight items saves nothing worth having. Worse, halving would be
    # WRONG: the score is not monotone along the chain. One measured chain runs
    # 223, then 188, then 274 as clues come out, because a removal can turn a
    # hidden single worth 14 points into a naked single worth 4. A halving
    # search assumes what that dip disproves.
    #
    # Walking from the SHALLOW end is what makes this affordable rather than
    # merely correct. The first acceptable board is returned, so an easy
    # request usually costs one rating and only a hard request pays for the
    # whole window -- and the board it returns has the most clues of any that
    # would have done, which is the one that looks most like the puzzle it
    # claims to be.
    #
    # CLUE COUNT IS A GUARD RAIL, NOT A TARGET, which is a change from how
    # this worked before. Earlier versions sampled a clue count per tier and
    # dug to it, and the difficulty was whatever fell out; that fails because
    # clue count is a weak predictor -- measured here, 26-clue boards ran from
    # needing no guesses at all to needing more than most people want. Now the
    # SCORE decides when to stop and the clue count is only a floor nothing
    # may dig past. In practice the floor is never the binding constraint:
    # uniqueness under 180-degree symmetry stops the dig at 25 to 29 clues on
    # its own, measured over 20 boards, and a second and fourth pass over the
    # blocked pairs removed nothing further.
    class Generator
      # A floor no dig may pass, well below where symmetry actually stops it
      # (25-29 clues measured). It exists to bound the loop rather than to
      # shape difficulty, and if it ever starts binding, that is a finding
      # about the dig and not a knob to turn. The theoretical minimum for a
      # uniquely-solvable sudoku is 17, and 18 with rotational symmetry.
      MIN_CLUES = 22

      # The other guard rail, and this one really does bind. Nothing may be
      # offered as a puzzle with more clues than this, however the score comes
      # out. Without it the search happily accepts the shallowest board that
      # scores inside the easy band -- and the shallowest board on the chain is
      # the COMPLETE SOLUTION, which scores zero and sits comfortably inside
      # it. An easy puzzle is still a puzzle.
      #
      # 45 is the top of PLAN.md §7's easy clue band, and the measured score at
      # 45 clues is about 97, which is inside the easy band with room to spare.
      MAX_CLUES = 45

      # A ceiling on ratings per attempt, so one attempt's cost is bounded no
      # matter how long a chain turns out to be. The measured window between
      # MAX_CLUES and the uniqueness floor is seven to nine boards, so this is
      # not normally what stops the walk -- running out of chain is.
      MEASURE_BUDGET = 12

      # Attempts before settling for the closest board found. Real cap, real
      # give-up value: see `generate`.
      DEFAULT_ATTEMPTS = 6

      # A full valid board. Solving a wholly empty grid with a shuffled digit
      # order is the standard trick: every branch is wide open, so the search
      # barely backtracks.
      def self.full_board(rng)
        Solver.solve(Array.new(Grid::CELLS, 0), rng)
      end

      # Rotationally symmetric groups: cell i pairs with 80 - i, the
      # 180-degree rotation of the board. Cell 40 is the centre and pairs with
      # itself. Listing each pair once (i < 80 - i) plus the centre gives 40
      # pairs + 1 = 41 groups covering all 81 cells exactly once.
      def self.dig_order(rng)
        pairs = []
        Grid::CELLS.times do |i|
          partner = 80 - i
          pairs << [i, partner] if i < partner
        end
        pairs << [40, 40]
        rng.shuffle(pairs)
      end

      # Dig as deep as uniqueness allows, and report the removals that stuck.
      # Greedy and single-pass over a shuffled order: a group that cannot come
      # out now is skipped and never revisited. That is not a corner cut -- a
      # second and a fourth pass over the blocked groups were measured and
      # removed nothing more, because a pair blocked by uniqueness stays
      # blocked once its neighbours are already gone.
      #
      # Returns [removals, clues_after]. Each removals entry is the [a, b]
      # group that came out, in the order it came out, so `board_at` can
      # reconstruct any point along the chain; clues_after[k] is the clue count
      # after k removals, so the guard rails can be applied without rebuilding
      # and recounting a board to find out where they fall.
      def self.dig_chain(solution, rng)
        puzzle = solution.dup
        clues = Grid::CELLS
        removals = []
        clues_after = [clues]

        dig_order(rng).each do |pair|
          a = pair[0]
          b = pair[1]
          removing = a == b ? 1 : 2
          # `next`, not `break`: the groups are shuffled, so a pair that would
          # overshoot the floor may be followed by the centre cell, which is
          # half the size and may still fit.
          next if clues - removing < MIN_CLUES

          keep_a = puzzle[a]
          keep_b = puzzle[b]
          puzzle[a] = 0
          puzzle[b] = 0
          unless Solver.unique?(puzzle)
            # Restored as a whole, which is what keeps the board rotationally
            # symmetric even where uniqueness blocked a cut.
            puzzle[a] = keep_a
            puzzle[b] = keep_b
            next
          end

          clues -= removing
          removals << pair
          clues_after << clues
        end

        [removals, clues_after]
      end

      # The shallowest point on the chain that MAX_CLUES allows: the first k
      # whose board has few enough clues to be offered as a puzzle at all.
      def self.first_usable(clues_after)
        k = 0
        while k < clues_after.size
          return k if clues_after[k] <= MAX_CLUES
          k += 1
        end
        clues_after.size - 1
      end

      # The board after the first `k` removals. Rebuilt from the solution
      # rather than held as 40 separate boards, which costs one 81-element
      # copy and k writes -- far less than the rating it is about to feed.
      def self.board_at(solution, removals, k)
        puzzle = solution.dup
        i = 0
        while i < k
          pair = removals[i]
          puzzle[pair[0]] = 0
          puzzle[pair[1]] = 0
          i += 1
        end
        puzzle
      end

      # Walk the chain from the shallow end and return the first board the
      # requested tier accepts, as [puzzle, measurement].
      #
      # If nothing on this chain is acceptable -- and that happens, one
      # measured solution in four produced no board harder than easy anywhere
      # along its whole chain -- the nearest miss comes back instead, and
      # `generate` decides whether to spend another attempt on a fresh board.
      def self.dig(solution, tier, rng)
        chain = dig_chain(solution, rng)
        removals = chain[0]
        clues_after = chain[1]

        k = first_usable(clues_after)
        last = removals.size
        budget = MEASURE_BUDGET
        best = nil
        best_board = nil
        near = nil
        near_board = nil

        while k <= last && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1

          # Squarely in the requested band: done, and this is the shallowest
          # such board because the walk started shallow.
          return [board, m] if Rater.in_band?(tier, m[:score])

          # Near enough to settle for, if nothing better turns up. Held back
          # rather than returned, because a board further down the chain may
          # still land in the band properly -- see Rater.accepts? for what
          # went wrong when the tolerant test drove the walk directly.
          if Rater.accepts?(tier, m[:score]) && (near.nil? || closer?(m, near, tier))
            near = m
            near_board = board
          end

          if best.nil? || closer?(m, best, tier)
            best = m
            best_board = board
          end
          k += 1
        end

        return [near_board, near] unless near.nil?
        [best_board, best]
      end

      # Is `a` a better answer than `b` for this request? Tier distance first,
      # then score distance from the band, so two candidates in the same wrong
      # tier are separated by which is nearer to being right.
      def self.closer?(a, b, tier)
        da = tier_distance(a[:tier], tier)
        db = tier_distance(b[:tier], tier)
        return true if da < db
        return false if da > db
        score_distance(a[:score], tier) < score_distance(b[:score], tier)
      end

      def self.tier_distance(got, wanted)
        gi = Rater::TIERS.index(got)
        wi = Rater::TIERS.index(wanted)
        return Rater::TIERS.size if gi.nil? || wi.nil?
        gi >= wi ? gi - wi : wi - gi
      end

      # How far a score sits outside a tier's band; 0 when inside.
      def self.score_distance(score, tier)
        range = Rater.band(tier)
        return 0 if range.nil?
        return range[0] - score if score < range[0]
        return 0 if range[1].nil? || score <= range[1]
        score - range[1]
      end

      # Try until a board is accepted, then stop. If none is inside the budget,
      # keep the attempt that came CLOSEST rather than returning nil: the game
      # always has a board to draw, and an honest `tier:` in the reply beats a
      # lie or a crash. The header then says what the player actually got.
      #
      # A real attempt cap, and this is worth stating because every one of the
      # five reference implementations read for this design got it wrong --
      # sudoku.js recurses on failure with no cap (and silently drops its
      # `unique` flag on the way), sudoku-core has three separate uncapped
      # retry loops, and super-sudoku counts attempts only to log them. A
      # generator that cannot fail is a generator that can hang, and this one
      # runs behind a splash screen on a device with a physical power button as
      # its only escape.
      def self.generate(tier, rng, attempts = DEFAULT_ATTEMPTS)
        best = nil
        attempts.times do
          solution = full_board(rng)
          out = dig(solution, tier, rng)
          puzzle = out[0]
          m = out[1]
          next if puzzle.nil?

          candidate = {
            grid: Grid.new(puzzle),
            solution: solution,
            tier: m[:tier],
            score: m[:score],
            guesses: m[:guesses],
            hardest: m[:hardest],
            counts: m[:counts],
            clues: Rater.clue_count(puzzle)
          }
          # Strict here too, and for the same reason it is strict inside `dig`:
          # while attempts remain, a fresh board is worth more than settling.
          # The tolerance still decides the outcome, just at the end -- a
          # tolerated board beats every other near miss on `closer?`, so if the
          # attempts run out that is what comes back.
          return candidate if Rater.in_band?(tier, m[:score])
          best = candidate if best.nil? || closer?(candidate, best, tier)
        end
        best
      end
    end
  end
end
