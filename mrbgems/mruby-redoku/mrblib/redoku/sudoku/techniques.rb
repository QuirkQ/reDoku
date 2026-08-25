module Redoku
  module Sudoku
    # A solver that only does what a person would do, and exists for one
    # purpose: rating. It never guesses and never searches, so when it stalls
    # the puzzle needs more than the nine rules below — and that stall is
    # exactly what makes a puzzle "hard" (see Rater).
    #
    # THE SHAPE, and it is the part worth understanding before editing:
    #
    # Two of the nine rules WRITE a digit (the singles). The other seven only
    # ELIMINATE candidates (pointing/box-line, the two pairs, the two triples,
    # the X-wing and the XY-wing). That difference drives everything:
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
      # Cheapest first, and load-bearing twice over: this is both the order
      # the loop TRIES the rules in and the scale `hardest` is measured on, so
      # moving a name changes what puzzles get called hard.
      #
      # The ranking follows the two published graders, which agree with each
      # other. Sudoku Explainer: pointing 2.6, claiming 2.8, naked pair 3.0,
      # hidden pair 3.4. HoDoKu: locked candidates 50, naked pair 60, hidden
      # pair 70, naked triple 80, hidden triple 100, X-wing 140. Both rank
      # locked candidates as the EASIEST of the eliminators, which is why
      # `pointing` sits ahead of the pairs — an earlier version had it last,
      # ranked as the hardest, against both of them.
      #
      # ONE DELIBERATE DEPARTURE: HoDoKu scores naked triple (80) above hidden
      # pair (70), so its strict numeric order would read `naked_pair,
      # hidden_pair, naked_triple, hidden_triple`. The naked and hidden forms
      # of one size are kept adjacent instead, because each is the other's
      # mirror image and splitting the pairs apart makes both harder to read.
      # What that costs: a board where either rule would do gets credited the
      # naked triple, so it rates one notch easier than HoDoKu would call it.
      #
      # XY-WING GOES LAST, which both graders agree with: HoDoKu 160 against
      # X-wing's 140, Sudoku Explainer 4.2 against 3.2. It is the only rule
      # here that CHAINS -- two deductions linked through a third cell rather
      # than one pattern inside one or two units -- and last is also where it
      # has to be for Rater's demand ladder to stay sound, since every
      # DEMAND_SET must remain a contiguous prefix of this list.
      ORDER = [:naked_single, :hidden_single, :pointing, :naked_pair,
               :naked_triple, :hidden_pair, :hidden_triple, :x_wing,
               :xy_wing].freeze

      # A bit per rule, in ORDER's positions. This is how a caller asks for a
      # solve with a RESTRICTED repertoire, which is what Rater's demand
      # classifier needs: "is this board finished by singles alone?" is a
      # question about a rule SET, and the answer cannot be read off a single
      # solve (see Rater::DEMAND_SETS).
      #
      # Derived from ORDER rather than written out, so a rule added to ORDER
      # gets a bit automatically. Built by a method called from the class body,
      # the house pattern Grid.build_rows and Grid.build_peers already use:
      # a constant that raises while building takes the whole gem down at load
      # and every other suite with it, so the building code wants to be plain.
      # (Object#tap would read better as a one-liner and is genuinely absent --
      # mruby-object-ext is one of the gems this gem still does not declare.)
      def self.build_rule_bits
        bits = {}
        i = 0
        while i < ORDER.size
          bits.store(ORDER[i], 1 << i)
          i += 1
        end
        bits
      end
      RULE_BIT = build_rule_bits.freeze

      # Every rule. The default for `solve`, so today's one-argument callers
      # are unaffected.
      ALL_RULES = (1 << ORDER.size) - 1

      # The mask for a list of rule names. An unknown name contributes
      # nothing, deliberately: this runs inside generation and the safety net
      # firing should make a board look HARDER (a weaker set fails, so the
      # demand class rises) rather than kill the game. Rater's tables are
      # pinned against ORDER by a test, which is where a typo is caught.
      def self.mask_of(rules)
        m = 0
        rules.each do |name|
          bit = RULE_BIT[name]
          m |= bit if bit
        end
        m
      end

      # Does this set of rules finish this board? One solve, no search, no
      # guessing. A set containing no WRITING rule (neither single) can never
      # finish an unfinished board however much it eliminates.
      def self.solves?(values, rules)
        solve(values, mask_of(rules))[:solved]
      end

      # Bounded well above the real worst case (81 writes plus 729 possible
      # bit removals). Reaching it means a rule is claiming progress it did
      # not make. It BREAKS rather than raises: this runs inside puzzle
      # generation, and the cost of the safety net firing should be a puzzle
      # rated harder than it really is, never a game that dies mid-tap.
      MAX_PASSES = 4000

      # `rules` restricts the repertoire to a mask of RULE_BIT bits. The
      # default is every rule, so a one-argument call is exactly what it was.
      #
      # WHY A MASK AND NOT A DISPATCH TABLE. Object#send IS available (this
      # gem declares mruby-metaprog since 18cc2f5), so the old reason for this
      # shape is gone -- but the shape is right anyway, on two grounds that do
      # not expire. A table of Method objects still needs the Method class,
      # and mruby-method is one of the gems this gem does not declare. And
      # SPEED: this loop is the hot path of the whole engine -- Rater.measure
      # calls it once per board, the generator measures up to 16 boards per
      # chain walk plus a ~27-board floor neighbourhood, and :master runs 150
      # of those. Nine guarded ifs cost one bitwise AND per rule per pass;
      # nine `send`s cost nine symbol dispatches per pass.
      def self.solve(values, rules = ALL_RULES)
        work = values.dup
        cand = candidate_grid(work)
        hardest = nil
        counts = {}
        passes = 0

        do_naked_single  = (rules & RULE_BIT[:naked_single]) != 0
        do_hidden_single = (rules & RULE_BIT[:hidden_single]) != 0
        do_pointing      = (rules & RULE_BIT[:pointing]) != 0
        do_naked_pair    = (rules & RULE_BIT[:naked_pair]) != 0
        do_naked_triple  = (rules & RULE_BIT[:naked_triple]) != 0
        do_hidden_pair   = (rules & RULE_BIT[:hidden_pair]) != 0
        do_hidden_triple = (rules & RULE_BIT[:hidden_triple]) != 0
        do_x_wing        = (rules & RULE_BIT[:x_wing]) != 0
        do_xy_wing       = (rules & RULE_BIT[:xy_wing]) != 0

        while passes < MAX_PASSES
          passes += 1

          if do_naked_single
            i = find_naked_single(cand)
            if i
              place(work, cand, i, Grid::BIT_LIST[cand[i]][0])
              hardest = harder(hardest, :naked_single)
              tally(counts, :naked_single)
              next
            end
          end

          if do_hidden_single
            spot = find_hidden_single(cand)
            if spot
              place(work, cand, spot[0], spot[1])
              hardest = harder(hardest, :hidden_single)
              tally(counts, :hidden_single)
              next
            end
          end

          # The eliminators mutate `cand` in place and write no digit. They
          # are kept in the loop rather than run to exhaustion so that the
          # cheap writing rules get another look after each one. They appear
          # here in ORDER, and that is not cosmetic: an expensive rule that
          # ran first would be credited for work a cheap one could have done.
          if do_pointing && pointing(cand)
            hardest = harder(hardest, :pointing)
            tally(counts, :pointing)
            next
          end
          if do_naked_pair && naked_pair(cand)
            hardest = harder(hardest, :naked_pair)
            tally(counts, :naked_pair)
            next
          end
          if do_naked_triple && naked_triple(cand)
            hardest = harder(hardest, :naked_triple)
            tally(counts, :naked_triple)
            next
          end
          if do_hidden_pair && hidden_pair(cand)
            hardest = harder(hardest, :hidden_pair)
            tally(counts, :hidden_pair)
            next
          end
          if do_hidden_triple && hidden_triple(cand)
            hardest = harder(hardest, :hidden_triple)
            tally(counts, :hidden_triple)
            next
          end
          if do_x_wing && x_wing(cand)
            hardest = harder(hardest, :x_wing)
            tally(counts, :x_wing)
            next
          end
          if do_xy_wing && xy_wing(cand)
            hardest = harder(hardest, :xy_wing)
            tally(counts, :xy_wing)
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

      # Three cells in one unit whose candidates UNION to exactly three digits
      # own those three digits between them, so no other cell in the unit may
      # use any of them.
      #
      # The members need not each show all three: two candidates is fine, and
      # allowing that is exactly what makes this stronger than naked_pair
      # rather than a slower restatement of it. {1,2} {2,3} {1,3} is a triple
      # and no pair inside it is locked.
      #
      # The eligible cells are collected FIRST rather than filtered inside
      # three nested `unit.each`es, and that is a measurement, not tidiness:
      # nine cells cubed is 729 combinations per unit and 19,683 per call,
      # while mid-solve a unit rarely has more than four or five cells down to
      # two or three candidates. Indices `ia < ib < ic` over the short list
      # then make each set of three come up once instead of six times. The
      # union-so-far test prunes what is left: a union can only grow, so once
      # two members exceed three digits no third can rescue them.
      def self.naked_triple(cand)
        Grid::UNITS.each do |unit|
          members = triple_cells(cand, unit)
          n = members.size
          ia = 0
          while ia + 2 < n
            a = members[ia]
            ib = ia + 1
            while ib + 1 < n
              b = members[ib]
              ab = cand[a] | cand[b]
              if Grid.count_bits(ab) <= 3
                ic = ib + 1
                while ic < n
                  c = members[ic]
                  triple = ab | cand[c]
                  if Grid.count_bits(triple) == 3
                    changed = false
                    unit.each do |i|
                      next if i == a || i == b || i == c
                      next if (cand[i] & triple) == 0
                      cand[i] &= ~triple
                      changed = true
                    end
                    return true if changed
                  end
                  ic += 1
                end
              end
              ib += 1
            end
            ia += 1
          end
        end
        false
      end

      # The cells of `unit` that could be part of a naked triple, in ascending
      # order because `unit` is.
      def self.triple_cells(cand, unit)
        out = []
        unit.each { |i| out << i if triple_sized?(Grid.count_bits(cand[i])) }
        out
      end

      # Two or three, which is the size a member of a triple may have: a
      # candidate count for naked_triple, a home count for hidden_triple.
      #
      # A count of ZERO is refused by the same test, which is what keeps
      # filled cells (mask 0) out of naked_triple without a separate guard. A
      # count of one is refused too, and deliberately: that cell is a naked
      # single and that digit a hidden single, so a cheaper rule owns it.
      def self.triple_sized?(n)
        n == 2 || n == 3
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

      # The triple form of the same idea, and the same trap one size up. Three
      # digits whose homes are confined to the SAME three cells fill those
      # three cells between them, so nothing else may live there.
      #
      # Note what the condition is not. "Three digits that each have three
      # homes" is the wrong rule — the mistake hidden_pair's comment already
      # warns about, and it is easier to make here because three digits with
      # three homes each look so much like an answer. The test is on the UNION:
      # the three home lists together must name exactly three cells. Each
      # digit then has two or three homes among them, never more.
      #
      # Homes are computed once per unit and the digits worth trying are
      # collected first, for naked_triple's reason: 84 digit-triples per unit
      # against nine home lists, and mid-solve most digits have four or more
      # homes and belong to no triple at all.
      def self.hidden_triple(cand)
        Grid::UNITS.each do |unit|
          digits = triple_digits(cand, unit)
          homes = digits[0]
          confined = digits[1]
          n = confined.size
          i1 = 0
          while i1 + 2 < n
            d1 = confined[i1]
            i2 = i1 + 1
            while i2 + 1 < n
              d2 = confined[i2]
              i3 = i2 + 1
              while i3 < n
                d3 = confined[i3]
                cells = union_of(homes[d1], homes[d2], homes[d3])
                if cells.size == 3
                  triple = (1 << d1) | (1 << d2) | (1 << d3)
                  changed = false
                  cells.each do |i|
                    next if (cand[i] & ~triple) == 0
                    cand[i] &= triple
                    changed = true
                  end
                  return true if changed
                end
                i3 += 1
              end
              i2 += 1
            end
            i1 += 1
          end
        end
        false
      end

      # Two things in one pass over the unit, because both want the same nine
      # home lists: `[homes, digits]`, where `homes` is indexed BY DIGIT (so
      # entry 0 is a placeholder and never read, exactly as bit 0 of a mask is
      # never read) and `digits` lists ascending only those digits confined to
      # two or three cells.
      def self.triple_digits(cand, unit)
        homes = [nil]
        confined = []
        d = 1
        while d <= 9
          list = homes_of(cand, unit, d)
          homes << list
          confined << d if triple_sized?(list.size)
          d += 1
        end
        [homes, confined]
      end

      # The cells at least one of these three lists names, each once. The
      # lists hold three cells at most, so the include? scan is cheaper than
      # anything cleverer would be.
      def self.union_of(a, b, c)
        out = []
        a.each { |i| out << i unless out.include?(i) }
        b.each { |i| out << i unless out.include?(i) }
        c.each { |i| out << i unless out.include?(i) }
        out
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

      # The first rule here that reasons across two units at once, which is
      # why it is the most expensive.
      #
      # Take a digit with exactly two homes in each of two rows, and let those
      # homes stand in the SAME two columns. The digit takes one home per row,
      # and the two cannot share a column, so whichever way round it falls the
      # digit occupies one cell in each column — inside those two rows. It is
      # therefore nowhere else in either column.
      #
      # "Same two columns" is the whole rule. Two rows with two homes each in
      # DIFFERENT column pairs say nothing at all, and a version that skips
      # the column test eliminates from four columns it has no claim on.
      def self.x_wing(cand)
        d = 1
        while d <= 9
          return true if x_wing_lines(cand, d, true)
          return true if x_wing_lines(cand, d, false)
          d += 1
        end
        false
      end

      # `by_row` true is the rule as stated: two rows, eliminating down the
      # columns. False is its transpose — two columns whose two homes share the
      # same two rows, eliminating along the rows. Both directions are real
      # patterns and a board can contain either, so neither is optional.
      #
      # Only the lines with EXACTLY TWO homes are collected, and the homes are
      # collected once per line rather than once per pair of lines. Scanning
      # pairs directly re-derives the same nine home lists up to 36 times over,
      # and two-home lines are scarce: usually none, which is what makes the
      # whole rule cheap to decline.
      def self.x_wing_lines(cand, digit, by_row)
        lines = by_row ? Grid::ROWS : Grid::COLS
        cross = by_row ? Grid::COLS : Grid::ROWS
        pairs = two_home_lines(cand, lines, digit)
        n = pairs.size
        ia = 0
        while ia + 1 < n
          first = pairs[ia]
          # homes_of walks the unit in order, so each pair comes out sorted
          # and the two can be compared position by position.
          p0 = cross_of(first[0], by_row)
          p1 = cross_of(first[1], by_row)
          ib = ia + 1
          while ib < n
            second = pairs[ib]
            if cross_of(second[0], by_row) == p0 &&
               cross_of(second[1], by_row) == p1
              keep = [first[0], first[1], second[0], second[1]]
              # Both cross-lines are cleared before answering, so one call
              # finishes the pattern rather than leaving half of it for the
              # next pass to rediscover. `||` would short-circuit the second.
              gone = strip(cand, cross[p0], keep, digit)
              gone = true if strip(cand, cross[p1], keep, digit)
              return true if gone
            end
            ib += 1
          end
          ia += 1
        end
        false
      end

      # The home PAIRS of every line in `lines` that has exactly two homes for
      # `digit`, in line order. Lines with any other number of homes are of no
      # use to an X-wing and are dropped rather than carried along as nils.
      def self.two_home_lines(cand, lines, digit)
        out = []
        a = 0
        while a < 9
          homes = homes_of(cand, lines[a], digit)
          out << homes if homes.size == 2
          a += 1
        end
        out
      end

      # Which cross-line a cell sits on: its column when we are scanning rows,
      # its row when we are scanning columns.
      def self.cross_of(i, by_row)
        by_row ? Grid.col_of(i) : Grid.row_of(i)
      end

      # THE ONLY CHAINING RULE HERE, and the only one whose three cells need
      # share no unit at all.
      #
      # A PIVOT with exactly two candidates {A,B}, and two PINCERS that are
      # both peers of the pivot and both have exactly two candidates: one is
      # {A,C}, the other {B,C}. Whichever digit the pivot turns out to be, it
      # forces one of the pincers to C -- pivot = A rules the A out of {A,C},
      # pivot = B rules the B out of {B,C} -- so AT LEAST ONE PINCER IS C. No
      # cell that sees BOTH pincers can therefore be C.
      #
      # Three parts of that are easy to get wrong, and each has a test:
      #
      #   - the pincers must take DIFFERENT digits from the pivot. Two pincers
      #     both sharing A leave the B case forcing nothing, and the deduction
      #     evaporates.
      #   - both pincers must SEE the pivot. A bi-value cell elsewhere on the
      #     board with the right digits is not a pincer; the pivot has no hold
      #     over it.
      #   - the victim must see BOTH pincers. Seeing one says nothing, since
      #     it is the other one that may be the C.
      #
      # C cannot equal A or B by construction (it is what is left of a pincer
      # after the pivot's bits are taken away), so the pivot itself never holds
      # C and needs no exclusion. Neither pincer is its own peer, so they are
      # not victims of themselves either. The pincers need not see each other.
      #
      # WHY THE SEARCH IS SHAPED THIS WAY, because the obvious version is
      # O(cells x peers x peers) with an `include?` inside it and this is the
      # hot path of the whole engine. The pivot's own PEERS list IS the
      # candidate pincer list, so walking it costs 20 iterations instead of 81
      # plus a peer test each -- and it makes "both pincers see the pivot" a
      # property of the loop rather than a condition to check. Only cells with
      # exactly two candidates open the inner loop at all, and mid-solve those
      # are scarce. What is left is a Grid::BIT_COUNT lookup and three bitwise
      # ops per peer, with no allocation anywhere in the scan.
      def self.xy_wing(cand)
        i = 0
        while i < Grid::CELLS
          pivot = cand[i]
          if Grid.count_bits(pivot) == 2
            peers = Grid::PEERS[i]
            n = peers.size
            na = 0
            while na < n
              a = peers[na]
              am = cand[a]
              # Two candidates, exactly one of them the pivot's: two 2-bit
              # masks union to 3 bits precisely when they overlap in one.
              #
              # The union test is a PERFORMANCE GUARD, not the correctness
              # one, and it is worth saying so because mutation testing
              # removed it and no assertion moved. It keeps `ac` and `ashare`
              # single bits, which is what makes the comments below true, but
              # the inner condition already refuses every peer it excludes: a
              # peer sharing NOTHING with the pivot has a two-bit `ac`, so a
              # matching `b` would need three bits; a peer equal to the pivot
              # has `ac` zero and `ashare` the whole pivot, so the only
              # matching `b` is the pivot itself and the `!=` refuses it. What
              # the guard buys is not opening the inner loop at all.
              if Grid.count_bits(am) == 2 && Grid.count_bits(am | pivot) == 3
                ac = am & ~pivot     # this pincer's C, one bit
                ashare = am & pivot  # the pivot digit it takes, one bit
                nb = na + 1
                while nb < n
                  b = peers[nb]
                  bm = cand[b]
                  # Same C, and the OTHER pivot digit. Those two conditions
                  # plus a count of two are the whole pattern: bm is then
                  # ac | (bm & pivot), and bm & pivot cannot be zero (that
                  # would leave one bit) nor both pivot bits (that would leave
                  # three), so it is exactly the pivot digit `a` did not take.
                  if Grid.count_bits(bm) == 2 && (bm & ~pivot) == ac &&
                     (bm & pivot) != ashare
                    return true if strip_seen_by_both(cand, a, b, ac)
                  end
                  nb += 1
                end
              end
              na += 1
            end
          end
          i += 1
        end
        false
      end

      # Clear `bit` from every cell that is a peer of BOTH `a` and `b`. True
      # only if a mask actually changed.
      #
      # Every such cell is cleared before answering, so one call finishes the
      # pattern rather than leaving the rest for the next pass to rediscover --
      # x_wing_lines does the same thing for its two cross-lines. The cheap
      # bit test comes first so the `include?` only runs on the handful of
      # cells that could actually be victims.
      def self.strip_seen_by_both(cand, a, b, bit)
        changed = false
        other = Grid::PEERS[b]
        Grid::PEERS[a].each do |i|
          next if (cand[i] & bit) == 0
          next unless other.include?(i)
          cand[i] &= ~bit
          changed = true
        end
        changed
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
