module Redoku
  module Sudoku
    # The machine solver: depth-first search over candidate bitmasks. Two
    # entry points, and the difference between them is the reason this is one
    # class rather than one method:
    #
    #   `solve` — find one solution. Used to build a full board before
    #             digging, and to keep the answer for M3's mistake checking.
    #   `count` — how many solutions are there, up to a limit. Generation
    #             calls this once per dug cell pair and only ever needs to
    #             know "exactly one, or more than one", so it stops at 2 and
    #             never counts the rest. On a nearly-empty board the true
    #             count is in the billions, so the limit is not an
    #             optimisation — it is what makes digging terminate at all.
    #
    # Both check CONSISTENCY at the door and then never again. That check is
    # not decoration: the search only ever looks at empty cells, so a board
    # that already repeats a digit has nothing wrong with any empty cell and
    # would be "solved" successfully, reporting a contradiction as an answer.
    # Once past the door the search only ever writes legal digits, so the
    # invariant holds for free and re-checking per node would be wasted work.
    #
    # Both pick the most-constrained empty cell first (minimum remaining
    # values). That single heuristic is the difference between a generator
    # that finishes inside PLAN.md §7's few-hundred-millisecond budget on the
    # Cortex-A7 and one that explores a doomed branch to depth 60 before
    # noticing.
    #
    # Neither entry point mutates its argument.
    class Solver
      def self.solve(values, rng = nil)
        return nil unless Grid.consistent?(values)
        work = values.dup
        search(work, rng) ? work : nil
      end

      # Returns min(actual solutions, limit).
      def self.count(values, limit = 2)
        return 0 unless Grid.consistent?(values)
        return 0 if limit <= 0
        tally(values.dup, limit, nil)
      end

      def self.unique?(values)
        count(values, 2) == 1
      end

      # The most constrained empty cell as [index, mask], or nil when the
      # board is full. Three behaviours the callers depend on:
      #   - returns immediately on a single-candidate cell, since nothing can
      #     beat one and scanning on would be pure cost;
      #   - reports a contradiction as a ZERO mask rather than as nil, so a
      #     caller can tell "nothing left to do" from "this branch is dead";
      #   - never considers a filled cell.
      # Public because it is the load-bearing heuristic and is tested
      # directly; `search` and `tally` are internal but left public too,
      # because `private_class_method` is not worth a compatibility risk for
      # two methods nobody outside calls.
      def self.best_cell(values)
        best_i = nil
        best_mask = 0
        best_n = 10
        i = 0
        while i < Grid::CELLS
          if values[i] == 0
            mask = Grid.candidates(values, i)
            n = Grid.count_bits(mask)
            return [i, mask] if n <= 1
            if n < best_n
              best_n = n
              best_mask = mask
              best_i = i
            end
          end
          i += 1
        end
        best_i.nil? ? nil : [best_i, best_mask]
      end

      # Depth-first, in place, restoring the cell on the way out so `work` is
      # left exactly as it was found on a failed branch. Depth is bounded by
      # the 81 cells, so the recursion cannot run away.
      def self.search(work, rng)
        cell = best_cell(work)
        return true if cell.nil? # no empty cell left: solved
        i = cell[0]
        digits = Grid.bits(cell[1])
        return false if digits.empty? # dead branch
        digits = rng.shuffle(digits) if rng
        digits.each do |d|
          work[i] = d
          return true if search(work, rng)
          work[i] = 0
        end
        false
      end

      # The same search, except it keeps going after a hit instead of
      # returning, and stops the moment `limit` solutions have been seen.
      #
      # The budget passed DOWN is the remaining one, not the original: a
      # child that may only find two more solutions must not be allowed to
      # enumerate two hundred. Combined with the `found >= limit` early
      # return, that also guarantees the recursive call always gets a limit
      # of at least 1, so no child is ever invoked with a budget of zero.
      def self.tally(work, limit, rng)
        cell = best_cell(work)
        return 1 if cell.nil? # a complete board: one solution
        i = cell[0]
        digits = Grid.bits(cell[1])
        return 0 if digits.empty?
        digits = rng.shuffle(digits) if rng
        found = 0
        digits.each do |d|
          work[i] = d
          found += tally(work, limit - found, rng)
          work[i] = 0
          return found if found >= limit
        end
        found
      end
    end
  end
end
