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
    # clues down to the floor, walked from ONE OF ITS TWO ENDS until a board of
    # the requested tier turns up.
    #
    # WALKED, NOT HALVED, and both halves of that were measured before being
    # believed. The chain is short -- 26 to 29 removals, of which the shallow
    # end is unusable because a board with more than MAX_CLUES clues is not a
    # puzzle -- so the searchable window is only 8 to 12 boards (p50 10 over 60
    # chains), and halving ten items saves nothing worth having. Worse, halving
    # would be WRONG: the score is not monotone along the chain. One measured
    # chain runs 223, then 188, then 274 as clues come out, because a removal
    # can turn a hidden single worth 14 points into a naked single worth 4. A
    # halving search assumes what that dip disproves.
    #
    # WHICH END DEPENDS ON THE RUNG, and getting that wrong was the whole of
    # the owner's "too easy" complaint about MEDIUM. Every rung used to walk
    # from the shallow end and take the first board that qualified, so every
    # tier shipped the most-clued board that barely passed -- the easy edge of
    # its own tier.
    #
    # Both walks were then run against the SAME 60 chains, and on the 48 where
    # each of them finds a MEDIUM board, walking from the deep end removes 4
    # clues at the median (up to 10, mean 3) and adds 37 points of work at the
    # median (up to 131). The design's own measurement over 40 chains adds that
    # it upgrades the DEMAND CLASS on 17 of 39 -- which is a fact about the
    # upper rungs rather than about MEDIUM, where both walks land inside
    # :singles by definition and only the score can move.
    #
    # AND IT COSTS NOTHING, because the chain is already dug: it is the same
    # work in the other direction. Measured, it costs LESS -- a MEDIUM request
    # is 63 ms at the median now against about 90 ms before, because the floor
    # is already MEDIUM on 202 chains in 300 and one classification ends the
    # search.
    #
    # EASY keeps the shallow walk, alone, because there the bias is a FEATURE:
    # the shallow end of a chain is 44-45 clues and the deep end 33-34, and a
    # first-rung puzzle should look generously clued. See WALK_SHALLOW.
    #
    # THE DEEP WALK IS ALSO THE CHEAP ONE, which is not obvious. A board's
    # demand class never decreases as clues come out (0 decreases in 527
    # measured adjacent steps, and restoring givens can only remove
    # candidates), so the hardest board on a chain is its FLOOR -- one
    # classification of the floor is enough to dismiss a whole chain that
    # cannot serve the request. Only a chain that can actually serve it pays
    # for a walk. See deep_walk, hard_end and rescue_floor.
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

      # A ceiling on ratings per CHAIN WALK, so one attempt's cost is bounded
      # however long a chain turns out to be. Raised from 12 to 16: the
      # measured window between MAX_CLUES and the uniqueness floor is 8 to 12
      # boards (the design's n=60; 8 to 11, p50 10, on the 34 chains
      # re-measured for this change) and 0 of 40 chains ever exceeded 12, so
      # this never binds -- which is exactly why raising it is free, and worth
      # doing now that the walk can start at either end. It does NOT bound the
      # floor neighbourhood, which is bounded by the chain's own length (at
      # most 41 groups, measured 26-29).
      MEASURE_BUDGET = 16

      # ATTEMPTS PER RUNG, and they are tier-dependent for the first time,
      # because the rungs differ in rarity by two orders of magnitude: a chain
      # can serve EASY 100% of the time and MASTER 2% of the time (500 chains:
      # 500 / 446 / 70 / 43 / 10). One number cannot be right for both.
      #
      # The caps come from a 500-chain bootstrap in the design, which PROJECTED
      # 100/100/100/99/94% hit rates. What the shipped code actually does,
      # measured through `generate` at these caps on the host (10 draws per
      # rung, seeds 910-919, median / mean / max ms):
      #   easy    10/10     59 /    64 /   123 ms
      #   medium  10/10     63 /    77 /   180 ms
      #   hard    10/10   1006 /  1086 /  2178 ms
      #   expert  10/10   2202 /  2517 /  5530 ms
      #   master  10/10   6961 /  7207 / 18774 ms
      #
      # A separate 5-draw run on seeds 900-904 hit 5/5 on the first four rungs
      # and 2/5 on MASTER, and each of the three misses burned the whole
      # 150-attempt cap for 17.3 to 21.4 s. So 12 of 15 measured MASTER
      # requests were served, against the projected 94%, and a MISS -- not a
      # hit -- is what sets the worst case: about 21 s on the host.
      #
      # The rarity behind that, measured over 300 fresh chains as the class of
      # the chain's HARD END, which is what a request is served from:
      #   easy 8, medium 237, hard 40, expert 11, master 4, reject 0
      # so MEDIUM-or-harder is available on 292 chains in 300, HARD-or-harder
      # on 55, EXPERT-or-harder on 15 and MASTER on 4 (1.3%, against the
      # design's 2%). The caps are set against those odds, not against a
      # per-request success target.
      #
      # MASTER'S MISSES ARE NOT A FAILURE, because App never stops asking
      # (decision 4): a miss retries with a FRESH solution, which resets the
      # odds, so the expected cost is a little over one round rather than
      # 1/(1-p). The tail is real, and it is what the progress bar is for.
      #
      # Adding a rung means adding an entry here. That is a real obligation the
      # three-tier design did not have, and it is unavoidable.
      #
      # RE-MEASURED AFTER xy_wing JOINED THE TOP RULE SET, 40 draws per rung on
      # identical seeds (910-924 and 3000-3024), old engine reproduced in the
      # same binary by making xy_wing decline:
      #
      #   hard    100% -> 100%    864 ->  1073 ms p50   (+24%)
      #   expert   97% ->  95%   1094 ->  1412 ms p50   (+29%)
      #   master   80% -> 100% 10794 ->  1206 ms p50    (-89%)
      #
      # MASTER is the point of the change and it is 9x faster with no miss
      # left. The middle rungs got dearer, and the cause is NOT the rule's own
      # cost -- Rater.measure is only 8% dearer per board (9439 -> 10207 us
      # over the same 1123 floors and neighbours), of which the extra is one
      # confirming solve on the 26 boards that used to reject. It splits in
      # two, both measured:
      #
      #   MORE ATTEMPTS (hard 7.5 -> 8.5 mean, expert 11.8 -> 13.6). Chains
      #   whose hard end matches the request one-for-one got rarer, because
      #   boards moved UP: over 300 chains the hard-end class went singles
      #   234 -> 214, locked 41 -> 31, subset 23 -> 15, top 2 -> 40. That is
      #   the ladder classifying more boards correctly, not a defect -- the
      #   middle rungs are genuinely rarer now -- so there is nothing here to
      #   fix without redefining what those rungs mean.
      #
      #   DEARER ATTEMPTS (hard 139 -> 148 ms, expert 144 -> 166). The 8% per
      #   board, plus walk_up running on far more chains: for a :hard request
      #   it went from 25 chains in 300 to 55, and it costs up to
      #   MEASURE_BUDGET classifications where a match costs one.
      #
      # The one lever left un-pulled, recorded rather than taken: walk_up
      # scans linearly, and for :hard, :expert and :master the tier IS the
      # demand class, which is monotone along the chain -- so those three
      # could BISECT and pay about 4 classifications instead of 16. It is not
      # done here because the class comment's "WALKED, NOT HALVED" rejects
      # halving on the grounds that the SCORE is not monotone, and that
      # objection is live for :medium, which shares the same walk. Splitting
      # the walk by rung needs its own measurement and its own review.
      ATTEMPTS = { easy: 6, medium: 12, hard: 60, expert: 60,
                   master: 150 }.freeze

      # For a tier ATTEMPTS does not know. nil.times is a crash, and this runs
      # behind a splash on a device whose only escape is the power button.
      DEFAULT_ATTEMPTS = 12

      # Which end of the chain each rung walks from. EASY walks from the
      # SHALLOW end because a first-rung puzzle should look generously clued --
      # measured, the shallowest board MAX_CLUES allows was 44 or 45 clues on
      # every one of 34 chains checked, and it was rung 1 on all of them.
      # Every other rung walks from the DEEP end, which is the fix for the
      # shallow-end bias: worth 4 clues and 37 points at the median for MEDIUM
      # (48 chains), and it costs NOTHING, because the chain is already dug.
      # See the class comment for the full measurement.
      #
      # ONE NAME, NOT A LIST, and that is a judgement rather than an accident.
      # A second shallow rung would be a second tier that ships its easy edge,
      # which is the defect this task exists to remove; if one is ever wanted,
      # this becomes a Set and the `==` in `dig` becomes `include?`.
      WALK_SHALLOW = :easy

      def self.attempts_for(tier)
        ATTEMPTS[tier] || DEFAULT_ATTEMPTS
      end

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

      # One attempt: dig a chain, then walk it from whichever end this rung
      # wants. Returns [board, measurement], or [nil, nil] if this chain has no
      # board our rules can finish at all.
      #
      # [nil, nil] IS A POSSIBLE ANSWER, which it was not before the demand
      # rework: if every board the walk can reach is a reject (our rules cannot
      # finish it), there is no candidate to settle for. Rejects crowd the
      # chain floor -- measured, 109 of 500 chain FLOORS are rejects against
      # 199 of 4852 boards overall -- which is why the deep walk has a rescue
      # and a fallback behind it rather than writing such a chain off.
      def self.dig(solution, tier, rng)
        chain = dig_chain(solution, rng)
        removals = chain[0]
        clues_after = chain[1]
        if tier == WALK_SHALLOW
          shallow_walk(solution, removals, clues_after, tier)
        else
          deep_walk(solution, removals, clues_after, tier)
        end
      end

      # From the first board MAX_CLUES allows, deeper, and stop at the first
      # board of the requested tier -- so the answer has the MOST clues of any
      # that would have done. EASY's walk, and only EASY's: going deep here
      # would ship 33-clue "easy" puzzles.
      #
      # EXACT TIER MATCH, not a score band. With a discrete class deciding the
      # tier there is no near miss to forgive, so the two-tier strict/tolerant
      # accept that CEILING needed is gone: it was solving a problem that only
      # exists when a continuous score decides a discrete tier.
      def self.shallow_walk(solution, removals, clues_after, tier)
        k = first_usable(clues_after)
        budget = MEASURE_BUDGET
        best = nil
        best_board = nil
        while k <= removals.size && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1
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

      # From the hard end. THE MONOTONE DISMISSAL IS WHAT MAKES THIS
      # AFFORDABLE: because a board's class never decreases as clues come out,
      # the hardest board on a chain is its floor -- so if the floor is easier
      # than the request, no board on this chain can serve it and the attempt
      # is over after ONE classification (p50 9 ms on top of the 47 ms dig).
      # Only a chain that can actually serve the request pays for a walk.
      def self.deep_walk(solution, removals, clues_after, tier)
        out = hard_end(solution, removals, tier)
        board = out[0]
        m = out[1]
        # Nothing our rules can finish at the deep end, floor OR neighbourhood.
        # Fall back to the shallow end rather than writing the chain off: design
        # 6.4's fallback, and it costs one classification on a path not observed
        # in 500 chains. See shallow_fallback.
        return shallow_fallback(solution, removals, clues_after) if m.nil?
        return [board, m] if m[:tier] == tier
        # Dismissed: too easy. The board still comes back as a fallback
        # candidate -- it is a real puzzle, just an easier one, and `generate`
        # would rather hand back an honest easier board than nothing.
        #
        # WHAT LICENSES DISMISSING A WHOLE CHAIN ON ONE BOARD, and it is worth
        # being precise because the board in hand is not always ON the chain.
        #
        #   - If the floor was solvable, `board` IS the floor and monotonicity
        #     settles it: every shallower board has more givens, so it is
        #     solved by every rule set that solves the floor.
        #   - If the floor rejected, `board` is a RESCUE, a sibling with the
        #     floor's givens plus one group, and monotonicity says nothing
        #     about the chain directly. It is still sound WHENEVER the board
        #     one step above the floor is solvable, because that board is
        #     itself one of the neighbours rescue_floor considered (restoring
        #     the LAST removal is exactly board_at(k = size - 1)), so the
        #     rescue is at least as hard as it, and it dominates everything
        #     shallower.
        #
        #     THAT LEANS ON THE RESCUE BEING THE HARDEST NEIGHBOUR, which
        #     since the request-first change it is only when NO neighbour
        #     matched the request. That is exactly the case this line runs in:
        #     a rescue that matched the request was returned by the `==` above
        #     and never reaches here, so on this line the rescue is still the
        #     neighbourhood's ceiling and the argument is untouched. See
        #     rescue_floor.
        #   - The gap is the case where the floor AND the board above it both
        #     reject. Then the deepest solvable board on the chain need not be
        #     inside the neighbourhood at all, and nothing bounds it. Measured,
        #     that case is COMMON -- 41 of 300 chains -- so this is a real gap
        #     and not a corner: it is named here rather than papered over.
        #
        # It is a RECALL gap, never a correctness one. The worst it can do is
        # dismiss a chain that could have served the request, costing one more
        # attempt; every tier reported is still measured on the board handed
        # back, so nothing is ever mislabelled. And measured exhaustively
        # against the max over the whole window plus the whole neighbourhood,
        # hard_end lost nothing on 300 of 300 chains -- so the gap is a
        # theoretical one that the corpus does not exhibit.
        return [board, m] if Rater.rank(m[:tier]) < Rater.rank(tier)
        # The hard end is HARDER than asked, so a shallower board may be
        # exactly right. Walk back up and take the DEEPEST match.
        up = walk_up(solution, removals, clues_after, tier)
        up[1].nil? ? [board, m] : up
      end

      # The board this chain's deep end can offer for `tier`: its floor, or --
      # if the floor is a board our rules cannot finish -- a rescue from the
      # floor's neighbourhood. [nil, nil] if there is no such board.
      #
      # `tier` is only ever a PREFERENCE, and only reaches the rescue path: a
      # solvable floor is returned with whatever class it has, because
      # monotonicity says it is the hardest board on the chain and the caller
      # needs that fact more than it needs a match. See rescue_floor for what
      # the preference does and why it is not simply "the hardest".
      def self.hard_end(solution, removals, tier)
        floor = board_at(solution, removals, removals.size)
        m = Rater.measure(floor)
        return [floor, m] unless m[:tier].nil?
        rescue_floor(solution, removals, floor, tier)
      end

      # A REJECTED FLOOR IS NOT A WASTED DIG. Restore any single removed group
      # and the result is a different, legal puzzle:
      #
      #   - still 180-degree symmetric, because a whole group goes back, never
      #     half of one;
      #   - still uniquely solvable, FOR FREE AND PROVABLY -- the restored
      #     givens come from the same solution, so the neighbour's solution set
      #     is a subset of the floor's, and the floor was unique. NO
      #     Solver.unique? CALL IS NEEDED, which is what makes this cheap: one
      #     Techniques.solve per neighbour instead of a search each.
      #
      # There are 26-29 such neighbours per floor and classifying all of them
      # costs 152-325 ms (p50 194). 22% of chain floors reject, so this runs on
      # about one attempt in five -- and it is where the hard rungs come from:
      # of 10 MASTER boards found in 500 chains, 7 came from a stalled floor's
      # neighbourhood and only 3 from a floor that was directly solvable.
      # Without the rescue the top rung is not merely expensive, it is three
      # times rarer.
      #
      # Measured again for this change over 300 fresh chains: 67 floors
      # rejected (22%, matching the design's 109 in 500) and every one of them
      # was rescued -- 0 chains needed the shallow fallback.
      #
      # The board handed back is OFF THE CHAIN, which is worth keeping in mind
      # when reading deep_walk: it is a sibling of the floor, not a point on
      # the sequence dig_chain reported, so walk_up cannot refine it and the
      # monotone argument does not reach it directly. EXACTLY ONE neighbour is
      # on the chain -- restoring the last removal gives board_at(size - 1) --
      # and that one is what carries deep_walk's dismissal argument as far as
      # it goes. See there.
      #
      # WHICH NEIGHBOUR: THE REQUESTED TIER FIRST, THE HARDEST ONLY AS A
      # FALLBACK. This method used to answer the hardest neighbour whatever was
      # asked for, and that was a latent mismatch rather than a design: the
      # search wants a board of tier T, and "hardest" only happens to be that
      # while the neighbourhood's ceiling IS T. Adding xy_wing made the
      # mismatch visible -- neighbours that used to reject began classifying in
      # the TOP demand class, so a neighbourhood whose ceiling was :expert
      # started holding a :master, and a request for :expert got handed the
      # :master, which deep_walk cannot return. It then paid up to
      # MEASURE_BUDGET classifications in walk_up to find on the chain what the
      # neighbourhood was already holding.
      #
      # THIS IS A CORRECTNESS CHANGE, NOT A SPEED ONE, and that is worth
      # stating plainly because it was first written believing the opposite.
      # Measured over 40 draws per rung on identical seeds, preferring the
      # match moved generation cost by NOTHING: :hard 1066 -> 1073 ms p50,
      # :expert 1402 -> 1412, :master 1196 -> 1206, with attempts-per-request
      # and ms-per-attempt both unchanged to the digit. The reason is that this
      # path is only reached when a floor REJECTS (about 21% of chains) AND the
      # neighbourhood ceiling has risen above the request, which is roughly 8%
      # of attempts, and it saves walk_up's 16 classifications out of an
      # attempt that already spent 27 on the neighbourhood. So keep it for what
      # it does do -- hand back a board of the tier that was asked for, and
      # stop the mismatch growing the next time the rule set does -- and see
      # ATTEMPTS for where the middle-rung cost actually went.
      #
      # THE FALLBACK IS NOT A CONVENIENCE, it is what keeps deep_walk's
      # dismissal sound. deep_walk writes off a whole chain when the hard end
      # is EASIER than the request, and that is only licensed if the board it
      # dismisses on is the hardest available. So the two cases divide exactly
      # as they must: a match is returned and deep_walk never reaches the
      # dismissal, and when there is no match the answer is the hardest
      # neighbour, which is precisely the case the dismissal argument covers.
      #
      # Among several neighbours of the requested tier, `harder?` picks the
      # highest-scoring one -- same tie-break as the ceiling search, and the
      # same reason the walks run from the deep end: a tier should not ship its
      # easy edge.
      def self.rescue_floor(solution, removals, floor, tier)
        best = nil
        best_board = nil
        match = nil
        match_board = nil
        removals.each do |pair|
          board = floor.dup
          board[pair[0]] = solution[pair[0]]
          board[pair[1]] = solution[pair[1]]
          m = Rater.measure(board)
          next if m[:tier].nil?
          if m[:tier] == tier && (match.nil? || harder?(m, match))
            match = m
            match_board = board
          end
          next unless best.nil? || harder?(m, best)
          best = m
          best_board = board
        end
        match.nil? ? [best_board, best] : [match_board, match]
      end

      # THE LAST RESORT ON A CHAIN, and the reason `generate` almost never
      # answers nil: the shallowest board MAX_CLUES allows, classified once.
      # That board was rung 1 on 500 of 500 measured chains, so a chain has to
      # be pathological at BOTH ends before it yields nothing at all.
      #
      # design 6.4 put this fallback on every dismissed attempt. It is here
      # instead, on the much rarer path where hard_end found nothing, and that
      # is a DEVIATION worth naming rather than a simplification. The reason is
      # that the version in 6.4 pays for it far more often for far less: a
      # chain dismissed as TOO EASY already has a real board to offer -- its
      # own hard end -- and deep_walk hands that back as the fallback candidate
      # (see above), which is both a better board and free. Classifying the
      # shallow end as well would add a second p50 9 ms classification to the
      # attempt that the monotone dismissal exists to make cost ONE, and at
      # :master's 150 attempts that is about 1.4 s added to a 4.7 s p50 for a
      # strictly worse candidate. So the fallback survives, on the path that
      # actually needs it.
      def self.shallow_fallback(solution, removals, clues_after)
        k = first_usable(clues_after)
        return [nil, nil] if k > removals.size
        board = board_at(solution, removals, k)
        m = Rater.measure(board)
        m[:tier].nil? ? [nil, nil] : [board, m]
      end

      # Harder tier first, then higher score, so the pick is deterministic
      # rather than order-dependent among equals.
      def self.harder?(a, b)
        ra = Rater.rank(a[:tier])
        rb = Rater.rank(b[:tier])
        return true if ra > rb
        return false if ra < rb
        a[:score] > b[:score]
      end

      # From one board above the floor back toward the shallow end, the FIRST
      # board of the requested tier -- which is the DEEPEST such board, because
      # the walk starts at the floor. The floor itself was already measured by
      # hard_end, so this starts one step shallower.
      def self.walk_up(solution, removals, clues_after, tier)
        k = removals.size - 1
        first = first_usable(clues_after)
        budget = MEASURE_BUDGET
        while k >= first && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1
          return [board, m] if m[:tier] == tier
          k -= 1
        end
        [nil, nil]
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

      # Try until a board of the requested tier turns up, then stop. If none is
      # inside the budget, keep the attempt that came CLOSEST rather than
      # inventing one: an honest `tier:` in the reply beats a lie or a crash,
      # and the caller decides what to do about the miss.
      #
      # THE NIL CONTRACT, stated here because it used to be an undocumented
      # invariant spread over four methods in two files: this returns nil ONLY
      # if no attempt produced a single logically solvable board anywhere. For
      # one attempt that means its chain floor rejected AND all ~27 of the
      # floor's one-group neighbours rejected AND the shallowest board
      # MAX_CLUES allows rejected too (shallow_fallback) -- three independent
      # failures, none of the first two observed in 500 chains and the third
      # observed 0 times in 500. Then that has to happen `attempts` times in a
      # row. IT IS STILL POSSIBLE, SO THE CALLER MUST HANDLE IT
      # (App#fill_board does).
      #
      # If the tier is missed but a real board was found, that board comes back
      # with the tier it ACTUALLY achieved. The caller decides whether to ask
      # again -- and it does, without limit, which is why there is no fallback
      # to an easier tier and never a wrong label (decision 4).
      #
      # A real attempt cap, and it is worth restating because every one of the
      # five reference implementations read for this design got it wrong:
      # sudoku.js recurses on failure with no cap (and silently drops its
      # `unique` flag on the way), sudoku-core has three separate uncapped
      # retry loops, and super-sudoku counts attempts only to log them. A
      # generator that cannot fail is a generator that can hang, and this one
      # runs behind a splash screen on a device with a physical power button as
      # its only escape. The unbounded part of the search lives in App, where
      # the progress bar can show it happening.
      #
      # THE BLOCK reports progress: it fires once per COMPLETED attempt with
      # (done, total), both Integers, `done` counting completed attempts and
      # `total` the cap. A block rather than a callable, because block-passing
      # is core mruby and mruby-method -- the Method class -- is one of the
      # gems this gem does not declare. It fires after the attempt's
      # classification work and BEFORE the early return, so a generation that
      # succeeds on its first attempt still reports once.
      def self.generate(tier, rng, attempts = nil)
        attempts = attempts_for(tier) if attempts.nil?
        best = nil
        i = 0
        while i < attempts
          i += 1
          solution = full_board(rng)
          out = dig(solution, tier, rng)
          puzzle = out[0]
          m = out[1]

          candidate = nil
          unless m.nil?
            candidate = {
              grid: Grid.new(puzzle),
              solution: solution,
              tier: m[:tier],
              demand: m[:demand],
              score: m[:score],
              hardest: m[:hardest],
              counts: m[:counts],
              clues: Rater.clue_count(puzzle),
              # The attempt this board came from, not the total spent: a caller
              # that wants the total counts the block's reports, which is the
              # only figure that survives a retry.
              attempts: i
            }
          end

          yield(i, attempts) if block_given?
          # Strict here too, and for the same reason it is strict inside the
          # walks: while attempts remain, a fresh board is worth more than
          # settling for the nearest rung this chain happened to offer.
          return candidate if candidate && candidate[:tier] == tier
          if candidate && (best.nil? || closer?(candidate, best, tier))
            best = candidate
          end
        end
        best
      end
    end
  end
end
