module Redoku
  module Sudoku
    # Puzzle construction, in three moves: fill a board at random, punch
    # symmetric holes in it for as long as it stays uniquely solvable, then
    # check what difficulty came out and try again if it is not what was
    # asked for.
    #
    # Generate-and-test rather than construct-to-order, per PLAN.md §7,
    # because difficulty is a property of the FINISHED puzzle: there is no
    # way to steer it while digging without rating the board after every
    # removal, which costs a full technique solve each time. The price is a
    # handful of attempts, and the "generating..." splash covers it.
    class Generator
      # How many clues each tier is allowed to keep, from PLAN.md §7 (easy
      # >= 36, medium 28-35, hard 24-30). The LOW end bounds how deep
      # digging may go; the whole band matters because of how the tier is
      # actually hit:
      #
      # Digging always as deep as the floor allows would make :medium nearly
      # unreachable — a 28-clue puzzle almost always needs more than pairs,
      # so it rates :hard and the request is never satisfied. So each attempt
      # samples a target inside the band instead, and over a few attempts the
      # band gets explored. That is the knob generate-and-test needs; without
      # it two of the three tiers collapse into :hard.
      CLUE_BAND = {
        easy: [36, 45],
        medium: [28, 35],
        hard: [24, 30]
      }.freeze

      DEFAULT_ATTEMPTS = 12

      # A full valid board. Solving a wholly empty grid with a shuffled digit
      # order is the standard trick: every branch is wide open, so the search
      # barely backtracks.
      def self.full_board(rng)
        Solver.solve(Array.new(Grid::CELLS, 0), rng)
      end

      def self.target_clues(tier, rng)
        band = CLUE_BAND[tier] || CLUE_BAND[:hard]
        band[0] + rng.next_int(band[1] - band[0] + 1)
      end

      # Rotationally symmetric groups: cell i pairs with 80 - i, the
      # 180-degree rotation of the board. Cell 40 is the centre and pairs
      # with itself. Listing each pair once (i < 80 - i) plus the centre
      # gives 40 pairs + 1 = 41 groups covering all 81 cells exactly once.
      def self.dig_order(rng)
        pairs = []
        Grid::CELLS.times do |i|
          partner = 80 - i
          pairs << [i, partner] if i < partner
        end
        pairs << [40, 40]
        rng.shuffle(pairs)
      end

      # Remove groups while the puzzle stays uniquely solvable and the clue
      # count stays at or above the target. Greedy and single-pass: a group
      # that cannot come out now is skipped and never revisited, which is
      # what keeps this linear in the 41 groups rather than a search.
      #
      # `next` rather than `break` on the target check, deliberately: the
      # groups are shuffled, so a pair that would overshoot may be followed
      # by the centre cell, which is half the size and may still fit.
      def self.dig(solution, tier, rng, target = nil)
        target = target_clues(tier, rng) if target.nil?
        puzzle = solution.dup
        clues = Grid::CELLS

        dig_order(rng).each do |pair|
          a = pair[0]
          b = pair[1]
          removing = a == b ? 1 : 2
          next if clues - removing < target

          keep_a = puzzle[a]
          keep_b = puzzle[b]
          puzzle[a] = 0
          puzzle[b] = 0
          if Solver.unique?(puzzle)
            clues -= removing
          else
            # Restored as a whole, which is what keeps the board
            # rotationally symmetric even where uniqueness blocked a cut.
            puzzle[a] = keep_a
            puzzle[b] = keep_b
          end
        end
        puzzle
      end

      # True when tier `got` sits nearer `wanted` than `other` does, measured
      # along Rater::TIERS. Ties are NOT closer, so the earliest attempt at a
      # given distance is the one kept.
      def self.closer_tier?(got, wanted, other)
        distance(got, wanted) < distance(other, wanted)
      end

      def self.distance(a, b)
        (Rater::TIERS.index(a) - Rater::TIERS.index(b)).abs
      end

      # Try until the rating matches, then stop. If nothing matches inside
      # the budget, keep the attempt whose tier came CLOSEST rather than
      # returning nil: the game always has a board to draw, and an honest
      # `tier:` in the reply is better than a lie or a crash. The header then
      # says what the player actually got.
      def self.generate(tier, rng, attempts = DEFAULT_ATTEMPTS)
        best = nil
        attempts.times do
          solution = full_board(rng)
          puzzle = dig(solution, tier, rng)
          got = Rater.rate(puzzle)
          candidate = {
            grid: Grid.new(puzzle),
            solution: solution,
            tier: got
          }
          return candidate if got == tier
          if best.nil? || closer_tier?(got, tier, best[:tier])
            best = candidate
          end
        end
        best
      end
    end
  end
end
