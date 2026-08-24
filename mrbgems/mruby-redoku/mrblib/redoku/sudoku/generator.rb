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
    # merely correct. The first board OF THE REQUESTED TIER is returned, so an
    # easy request usually costs one rating and only a request for an upper
    # rung pays for the whole window -- and the board it returns has the most
    # clues of any that would have done, which is the one that looks most like
    # the puzzle it claims to be.
    #
    # CLUE COUNT IS A GUARD RAIL, NOT A TARGET, which is a change from how
    # this worked before. Earlier versions sampled a clue count per tier and
    # dug to it, and the difficulty was whatever fell out; that fails because
    # clue count is a weak predictor -- measured here, 26-clue boards ran from
    # needing no guesses at all to needing more than most people want. Now the
    # TIER decides when to stop -- which since the demand rework means what the
    # board logically DEMANDS, with the score separating only the bottom two
    # rungs -- and the clue count is only a floor nothing may dig past. In
    # practice the floor is never the binding constraint:
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

      # Walk the chain from the shallow end and return the first board whose
      # tier IS the requested one, as [puzzle, measurement].
      #
      # If nothing on this chain is that tier -- and that happens often, more
      # often now that the upper rungs are gated on what a board demands
      # rather than on how long it is -- the nearest REAL tier comes back
      # instead, and `generate` decides whether to spend another attempt on a
      # fresh board.
      #
      # [nil, nil] IS A POSSIBLE ANSWER, which it was not before: if every
      # board in the window is a reject (our rules cannot finish it), there is
      # no candidate to settle for. Rejects crowd the chain floor -- measured,
      # 109 of 500 chain FLOORS are rejects against 199 of 4852 boards overall
      # -- so this is a real case rather than a defensive one, and `generate`
      # skips such an attempt.
      def self.dig(solution, tier, rng)
        chain = dig_chain(solution, rng)
        removals = chain[0]
        clues_after = chain[1]

        k = first_usable(clues_after)
        last = removals.size
        budget = MEASURE_BUDGET
        best = nil
        best_board = nil

        while k <= last && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1

          # EXACT TIER MATCH, not a score band. With a discrete class deciding
          # the tier there is no near miss to forgive, so the two-tier
          # strict/tolerant accept that CEILING needed is gone: it was solving
          # a problem that only exists when a continuous score decides a
          # discrete tier.
          return [board, m] if m[:tier] == tier

          # A reject is not a candidate for anything. It is not a hard puzzle,
          # it is not a puzzle: our rules cannot finish it, so a player would
          # have to guess.
          if !m[:tier].nil? && (best.nil? || closer?(m, best, tier))
            best = m
            best_board = board
          end
          k += 1
        end

        [best_board, best]
      end

      # Is `a` a better answer than `b` for this request? Tier distance alone
      # now: the score cannot separate two candidates in different demand
      # classes in any way that means anything (a chain yields at most one or
      # two boards of any non-singles class), and inside :singles the tier
      # already carries the score's one distinction. Equal is not closer, so
      # the first candidate found wins a tie and the search stays
      # deterministic.
      def self.closer?(a, b, tier)
        tier_distance(a[:tier], tier) < tier_distance(b[:tier], tier)
      end

      # How many rungs apart two tiers are. A reject or an unknown name is
      # further away than any real tier, so it never wins.
      def self.tier_distance(got, wanted)
        gi = Rater.rank(got)
        wi = Rater.rank(wanted)
        return Rater::TIERS.size if gi < 0 || wi < 0
        gi >= wi ? gi - wi : wi - gi
      end

      # Try until a board of the requested tier is found, then stop. If none is
      # inside the budget, keep the attempt that came CLOSEST rather than
      # inventing one: an honest `tier:` in the reply beats a lie or a crash,
      # and the caller decides what to do about the miss.
      #
      # NIL IS NOW POSSIBLE, and that is a deliberate contract change rather
      # than a hole. It means no attempt found a single board our eight rules
      # can finish, so there is nothing to hand back that a player could solve
      # without guessing -- and under the no-guessing rule a board we cannot
      # finish is a REJECT, not a hard puzzle. App#fill_board already guards
      # for it (an unchanged board beats a wiped one); Task 4's progress bar
      # and Task 5's retry semantics are what turn it into something the player
      # sees.
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
            demand: m[:demand],
            score: m[:score],
            hardest: m[:hardest],
            counts: m[:counts],
            clues: Rater.clue_count(puzzle)
          }
          # Strict here too, and for the same reason it is strict inside `dig`:
          # while attempts remain, a fresh board is worth more than settling
          # for the nearest rung this chain happened to offer.
          return candidate if m[:tier] == tier
          best = candidate if best.nil? || closer?(candidate, best, tier)
        end
        best
      end
    end
  end
end
