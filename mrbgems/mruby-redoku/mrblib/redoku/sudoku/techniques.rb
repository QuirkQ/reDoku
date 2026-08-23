module Redoku
  module Sudoku
    # A solver that only does what a person would do, and exists for one
    # purpose: rating. It never guesses and never searches, so when it stalls
    # the puzzle needs more than the five rules below — and that stall is
    # exactly what makes a puzzle "hard" (see Rater).
    #
    # THE SHAPE, and it is the part worth understanding before editing:
    #
    # Two of the five rules WRITE a digit (the singles). Three only ELIMINATE
    # candidates (the pairs and pointing). That difference drives everything:
    #
    #   - Candidates live in a `cand` array of 81 masks and are maintained
    #     INCREMENTALLY: writing a digit clears that cell's mask and strips
    #     the digit from its 20 peers, and nothing else is touched. Two
    #     earlier designs did worse. Rebuilding every pass threw every
    #     elimination away the moment it was made, so a pair was rediscovered
    #     for ever and the loop never ended. Rebuilding after each write
    #     terminated, but still discarded all accumulated eliminations at
    #     every write — 1620 peer lookups to reconstruct what 20 updates
    #     would have preserved, which measured 37 ms per solve against the
    #     search solver's 1 ms and put this class out of reach of the rating
    #     path it exists to serve.
    #
    #     Keeping eliminations across writes is sound, because an elimination
    #     only ever removes a candidate that provably cannot be there, and a
    #     write cannot make it possible again. It is also what a person does:
    #     you do not forget that a cell cannot be a 7 just because you filled
    #     in a different cell. Being strictly stronger, it can make `hardest`
    #     come out EASIER than the rebuilding version did — it never makes it
    #     harder — because a deduction kept is a deduction not re-derived.
    #
    #   - Every elimination rule returns true ONLY if a mask actually shrank.
    #     That is the termination argument, and it is why the "does not fire
    #     when there is nothing to eliminate" cases are tested as carefully
    #     as the firing ones: masks only ever lose bits, there are 81 * 9 of
    #     them, and there are at most 81 writes, so the loop is bounded.
    #
    # The rules are tried cheapest-first and the loop restarts from the top
    # after every step, so a single opened up by a pointing pair is found by
    # the cheap rule rather than credited to the expensive one. An
    # elimination therefore only ever fires when no single was available,
    # which is what makes `hardest` mean "was genuinely needed" rather than
    # "happened to be tried".
    class Techniques
      ORDER = [:naked_single, :hidden_single, :naked_pair, :hidden_pair,
               :pointing].freeze

      # Bounded well above the real worst case (81 writes plus 729 possible
      # bit removals). Reaching it means a rule is claiming progress it did
      # not make. It BREAKS rather than raises: this runs inside puzzle
      # generation, and the cost of the safety net firing should be a puzzle
      # rated harder than it really is, never a game that dies mid-tap.
      MAX_PASSES = 4000

      def self.solve(values)
        work = values.dup
        cand = candidate_grid(work)
        hardest = nil
        counts = {}
        passes = 0

        while passes < MAX_PASSES
          passes += 1

          i = find_naked_single(cand)
          if i
            place(work, cand, i, Grid::BIT_LIST[cand[i]][0])
            hardest = harder(hardest, :naked_single)
            tally(counts, :naked_single)
            next
          end

          spot = find_hidden_single(cand)
          if spot
            place(work, cand, spot[0], spot[1])
            hardest = harder(hardest, :hidden_single)
            tally(counts, :hidden_single)
            next
          end

          # The eliminators mutate `cand` in place and write no digit. They
          # are kept in the loop rather than run to exhaustion so that the
          # cheap writing rules get another look after each one.
          if naked_pair(cand)
            hardest = harder(hardest, :naked_pair)
            tally(counts, :naked_pair)
            next
          end
          if hidden_pair(cand)
            hardest = harder(hardest, :hidden_pair)
            tally(counts, :hidden_pair)
            next
          end
          if pointing(cand)
            hardest = harder(hardest, :pointing)
            tally(counts, :pointing)
            next
          end

          break # nothing applies: stalled, and that is an answer
        end

        { values: work, solved: Grid.complete?(work), hardest: hardest,
          counts: counts }
      end

      # HOW OFTEN each rule was needed, not just which was hardest. The
      # difference matters for rating: a board that needs one pointing pair
      # and a board that needs nine of them are not the same puzzle, and
      # `hardest` calls them both ":pointing". Keyed by technique, absent
      # rather than zero when a rule never fired -- callers weight the keys
      # they find, so a rule added to ORDER cannot silently read as "used 0
      # times" when the real answer is "never looked for".
      def self.tally(counts, name)
        counts.store(name, (counts[name] || 0) + 1)
        counts
      end

      # -1 for nil, so any real technique outranks "nothing needed yet".
      def self.rank(name)
        name.nil? ? -1 : ORDER.index(name)
      end

      def self.harder(a, b)
        rank(a) >= rank(b) ? a : b
      end

      # Write `d` at `i` and keep the candidate grid true, in 21 updates
      # rather than a fresh 81-cell rebuild: the cell itself holds nothing
      # more, and no peer may hold that digit any longer. Every other mask is
      # left exactly as it was, which is what preserves the eliminations the
      # pair and pointing rules paid for.
      #
      # Stripping the bit from a peer that is already FILLED is harmless: a
      # filled cell's mask is 0, so there is nothing to clear.
      def self.place(work, cand, i, d)
        work[i] = d
        cand[i] = 0
        bit = 1 << d
        Grid::PEERS[i].each { |j| cand[j] &= ~bit }
        self
      end

      # 81 masks. A FILLED cell gets 0, not its candidates: that is what lets
      # every rule below treat "mask is zero" as "not my business" without
      # consulting the board, and it is why an already-placed digit can never
      # be counted as a home for itself.
      #
      # Only used to seed the grid now; `place` maintains it from there.
      def self.candidate_grid(work)
        cand = []
        Grid::CELLS.times do |i|
          cand << (work[i] == 0 ? Grid.candidates(work, i) : 0)
        end
        cand
      end

      # An empty cell with exactly one candidate. Returns the index or nil.
      def self.find_naked_single(cand)
        Grid::CELLS.times do |i|
          return i if Grid.count_bits(cand[i]) == 1
        end
        nil
      end

      # A digit with exactly one possible home in some unit. Returns
      # [index, digit] or nil.
      #
      # A digit already placed in the unit cannot produce a false positive:
      # its cell's mask is 0, and every other cell in the unit is its peer,
      # so no cell in the unit still offers it. The count comes out 0.
      def self.find_hidden_single(cand)
        Grid::UNITS.each do |unit|
          d = 1
          while d <= 9
            bit = 1 << d
            spot = nil
            many = false
            unit.each do |i|
              next if (cand[i] & bit) == 0
              if spot.nil?
                spot = i
              else
                many = true
              end
            end
            return [spot, d] if !many && !spot.nil?
            d += 1
          end
        end
        nil
      end

      # Two cells in one unit sharing the same two candidates own that pair,
      # so no other cell in the unit may use either digit.
      def self.naked_pair(cand)
        Grid::UNITS.each do |unit|
          unit.each do |a|
            next unless Grid.count_bits(cand[a]) == 2
            unit.each do |b|
              next if b <= a
              next unless cand[b] == cand[a]
              changed = false
              unit.each do |i|
                next if i == a || i == b
                next if (cand[i] & cand[a]) == 0
                cand[i] &= ~cand[a]
                changed = true
              end
              return true if changed
            end
          end
        end
        false
      end

      # The mirror image. If two digits in a unit have the SAME two possible
      # homes, those two cells hold nothing but those two digits.
      #
      # Note the shape: the two digits' home lists must each be exactly those
      # two cells. Testing the union of the pair's bits instead would match
      # any two cells that between them offer either digit, which is a
      # different and wrong rule.
      def self.hidden_pair(cand)
        Grid::UNITS.each do |unit|
          d1 = 1
          while d1 <= 9
            homes1 = homes_of(cand, unit, d1)
            if homes1.size == 2
              d2 = d1 + 1
              while d2 <= 9
                if homes_of(cand, unit, d2) == homes1
                  pair = (1 << d1) | (1 << d2)
                  a = homes1[0]
                  b = homes1[1]
                  # Only progress if there is something to remove; claiming
                  # it otherwise is how the loop stops terminating.
                  if (cand[a] & ~pair) != 0 || (cand[b] & ~pair) != 0
                    cand[a] &= pair
                    cand[b] &= pair
                    return true
                  end
                end
                d2 += 1
              end
            end
            d1 += 1
          end
        end
        false
      end

      def self.homes_of(cand, unit, digit)
        bit = 1 << digit
        out = []
        unit.each { |i| out << i if (cand[i] & bit) != 0 }
        out
      end

      # Box/line interaction, both directions, which is what PLAN.md §7 calls
      # "pointing pair/box-line":
      #
      #   POINTING — if every home for a digit inside a box shares one line,
      #   the digit is on that line inside the box, so it is nowhere else on
      #   that line.
      #
      #   BOX-LINE — if every home for a digit along a line sits inside one
      #   box, the digit is in that box on that line, so it is nowhere else
      #   in the box.
      def self.pointing(cand)
        Grid::BOXES.each do |box|
          d = 1
          while d <= 9
            homes = homes_of(cand, box, d)
            if homes.size >= 2
              line = shared_line(homes, true)
              return true if line && strip(cand, Grid::ROWS[line], homes, d)
              line = shared_line(homes, false)
              return true if line && strip(cand, Grid::COLS[line], homes, d)
            end
            d += 1
          end
        end

        Grid::ROWS.each { |row| return true if box_line(cand, row) }
        Grid::COLS.each { |col| return true if box_line(cand, col) }
        false
      end

      def self.box_line(cand, line)
        d = 1
        while d <= 9
          homes = homes_of(cand, line, d)
          if homes.size >= 2
            box = shared_box(homes)
            return true if box && strip(cand, Grid::BOXES[box], homes, d)
          end
          d += 1
        end
        false
      end

      # The row (or column) every one of these cells is on, or nil if they
      # are not all on one.
      def self.shared_line(cells, by_row)
        first = by_row ? Grid.row_of(cells[0]) : Grid.col_of(cells[0])
        cells.each do |i|
          got = by_row ? Grid.row_of(i) : Grid.col_of(i)
          return nil if got != first
        end
        first
      end

      def self.shared_box(cells)
        first = Grid.box_of(cells[0])
        cells.each { |i| return nil if Grid.box_of(i) != first }
        first
      end

      # Clear `digit` from every cell of `unit` that is not one of `keep`.
      # True only if a mask actually changed.
      def self.strip(cand, unit, keep, digit)
        bit = 1 << digit
        changed = false
        unit.each do |i|
          next if keep.include?(i)
          next if (cand[i] & bit) == 0
          cand[i] &= ~bit
          changed = true
        end
        changed
      end
    end
  end
end
