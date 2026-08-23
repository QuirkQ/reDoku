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
    # not decoration: the search only ever looks at EMPTY cells, so a board
    # that already repeats a digit has nothing wrong with any empty cell and
    # would be "solved" successfully, reporting a contradiction as an answer.
    # Past the door only legal digits are written, so the invariant holds for
    # free and re-checking per node would be waste.
    #
    # CANDIDATES ARE MAINTAINED INCREMENTALLY, and that is the whole
    # performance story. The obvious version recomputes each empty cell's
    # candidates from its 20 peers every time it looks for a cell to try,
    # which is ~1600 operations per search node; digging one puzzle runs 41
    # searches of many nodes each and cost 922 ms on the build host, against
    # PLAN.md §7's few-hundred-millisecond budget on a much slower
    # Cortex-A7. Here `cand` is threaded through the recursion: `assign`
    # clears one bit from the peers it actually changed and hands back that
    # list, `unassign` puts exactly those back, and choosing a cell becomes
    # 81 table lookups. The undo list is what keeps it exact — restoring by
    # recomputation would be both slower and a chance to drift.
    #
    # Neither entry point mutates its argument.
    class Solver
      def self.solve(values, rng = nil)
        return nil unless Grid.consistent?(values)
        work = values.dup
        search(work, build_cand(work), rng) ? work : nil
      end

      # Returns min(actual solutions, limit).
      def self.count(values, limit = 2)
        return 0 unless Grid.consistent?(values)
        return 0 if limit <= 0
        work = values.dup
        tally(work, build_cand(work), limit, nil)
      end

      def self.unique?(values)
        count(values, 2) == 1
      end

      # A filled cell's entry is 0 and is never read: `pick` tests the board
      # before it touches the mask. That is what lets `assign` leave cand[i]
      # alone and `unassign` have nothing to put back for the cell itself.
      def self.build_cand(work)
        cand = []
        Grid::CELLS.times do |i|
          cand << (work[i] == 0 ? Grid.candidates(work, i) : 0)
        end
        cand
      end

      # The most constrained empty cell, or nil when the board is full.
      # Returns immediately on a cell with one candidate or none: one cannot
      # be beaten, and none means this branch is already dead, so scanning on
      # would be pure cost. The caller distinguishes those two by looking at
      # the mask.
      def self.pick(work, cand)
        best_i = nil
        best_n = 10
        i = 0
        while i < Grid::CELLS
          if work[i] == 0
            n = Grid::BIT_COUNT[cand[i]]
            return i if n <= 1
            if n < best_n
              best_n = n
              best_i = i
            end
          end
          i += 1
        end
        best_i
      end

      # Writes d at i and PROPAGATES: any peer left with a single candidate is
      # assigned too, and so on until the chain runs out. A peer left with no
      # candidate at all fails the whole branch immediately.
      #
      # Cascading rather than letting `pick` re-find each forced cell is
      # borrowed from Norvig's solver (and its JS descendant sudoku.js, whose
      # `_eliminate` does the same). It pays twice over: following the chain
      # directly costs one peer walk per forced cell instead of a fresh
      # 81-cell scan, and a contradiction is seen the moment it appears
      # rather than after the search has committed to more of the branch.
      # Measured on the generator, not assumed — see the M2 ledger.
      #
      # Returns a trail — [assigned_cells, cleared_bits] — for `unassign`, or
      # nil if the branch is dead. On nil it has ALREADY undone its own
      # partial work, so a caller that gets nil must not undo anything: the
      # cascade may have written half a dozen cells before hitting the
      # contradiction, and leaving those behind would corrupt the search.
      def self.assign(work, cand, i, d)
        cells = []
        bits = []
        if cascade(work, cand, i, d, cells, bits)
          [cells, bits]
        else
          undo(work, cand, cells, bits)
          nil
        end
      end

      def self.cascade(work, cand, i, d, cells, bits)
        queue = [i, d]
        head = 0
        while head < queue.size
          ci = queue[head]
          cd = queue[head + 1]
          head += 2
          # The same cell can be queued twice by two different peers. Already
          # holding the digit we wanted is agreement, not a conflict; holding
          # a different one is the contradiction.
          next if work[ci] == cd
          return false if work[ci] != 0
          bit = 1 << cd
          return false if (cand[ci] & bit) == 0

          work[ci] = cd
          cells << ci
          Grid::PEERS[ci].each do |j|
            next unless work[j] == 0
            next if (cand[j] & bit) == 0
            cand[j] &= ~bit
            bits << j
            bits << bit
            n = Grid::BIT_COUNT[cand[j]]
            return false if n == 0 # nothing can go here: branch is dead
            if n == 1
              queue << j
              queue << Grid::BIT_LIST[cand[j]][0]
            end
          end
        end
        true
      end

      # Exact reversal, in reverse order of application. The bit list records
      # WHICH bit was taken from which cell, so a peer that never offered the
      # digit is never handed one back — restoring by recomputation would let
      # the grid drift looser on every backtrack.
      def self.undo(work, cand, cells, bits)
        k = bits.size - 2
        while k >= 0
          cand[bits[k]] |= bits[k + 1]
          k -= 2
        end
        cells.each { |c| work[c] = 0 }
        self
      end

      def self.unassign(work, cand, trail)
        undo(work, cand, trail[0], trail[1])
      end

      # Depth-first, in place, restoring the cell on the way out so `work`
      # and `cand` are left exactly as found on a failed branch. Depth is
      # bounded by the 81 cells, so the recursion cannot run away.
      def self.search(work, cand, rng)
        i = pick(work, cand)
        return true if i.nil? # no empty cell left: solved
        digits = Grid::BIT_LIST[cand[i]]
        return false if digits.empty? # dead branch
        digits = rng.shuffle(digits) if rng
        digits.each do |d|
          trail = assign(work, cand, i, d)
          next if trail.nil? # propagation found a contradiction; nothing to undo
          return true if search(work, cand, rng)
          unassign(work, cand, trail)
        end
        false
      end

      # The same search, except it keeps going after a hit instead of
      # returning, and stops the moment `limit` solutions have been seen.
      #
      # The budget passed DOWN is the remaining one, not the original: a child
      # that may only find two more solutions must not enumerate two hundred.
      # Combined with the `found >= limit` early return, that also guarantees
      # every recursive call gets a limit of at least 1, so no child is ever
      # invoked with a budget of zero.
      def self.tally(work, cand, limit, rng)
        i = pick(work, cand)
        return 1 if i.nil? # a complete board: one solution
        digits = Grid::BIT_LIST[cand[i]]
        return 0 if digits.empty?
        digits = rng.shuffle(digits) if rng
        found = 0
        digits.each do |d|
          trail = assign(work, cand, i, d)
          next if trail.nil? # a dead branch contributes no solutions
          found += tally(work, cand, limit - found, rng)
          unassign(work, cand, trail)
          return found if found >= limit
        end
        found
      end
    end
  end
end
