module Redoku
  module Sudoku
    # Difficulty, measured as WHAT KIND OF THINKING a board demands and HOW
    # MUCH OF IT. Two signals, and which one decides is the whole design:
    #
    #   1. DEMAND -- the weakest set of human techniques that finishes the
    #      board (see DEMAND_SETS). A property of the puzzle's logic, not of
    #      its length, and it picks the rung.
    #   2. SCORE -- the weighted sum over every rule application the solver
    #      needed. Volume, not cleverness, and it may only separate rungs
    #      INSIDE a demand class -- which today means only the bottom two.
    #
    # WHY DEMAND DECIDES AND NOT THE SCORE, which is what this class did
    # before and what was rejected on the device. A score is a SUM, so enough
    # trivial steps add up to a hard rating without the puzzle ever requiring
    # a hard technique -- and measured, that is exactly what happened: 22 of
    # 40 boards the old rater called :hard were solvable by naked and hidden
    # singles alone, and all 40 of its :medium boards were; 94% of a
    # 4852-board dig-chain corpus was singles-only. The old TECHNIQUE_FLOOR
    # could only ever RAISE a tier, so it could not stop volume buying a
    # label. A demand class sets a CEILING as well as a floor, and that is
    # the fix.
    #
    # WHERE THE SCORE STILL SPEAKS, because the owner's playtest was clear
    # that "long, not clever" is genuinely fun at the easy end: it separates
    # :easy from :medium inside the singles class, and nothing else. That is
    # the axis moved to the BOTTOM of the ladder, where it is fun, rather than
    # left at the top, where it was wrong.
    #
    # WHY THERE IS NO GUESS TERM ANY MORE. This class used to add search cost
    # for whatever the techniques could not finish, priced at GUESS points a
    # decision. Under the no-guessing rule a board our nine rules cannot
    # finish is a REJECT -- `measure` answers tier: nil -- rather than a hard
    # puzzle, so there is nothing left for that term to price. Solver.cost
    # survives as a diagnostic with tests of its own; it is simply not called
    # from the rating path.
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
      #
      # HOW LITTLE OF THIS IS LOAD-BEARING, because a reader who does not know
      # will be needlessly careful with it. Since the demand rework the score
      # only ranks WITHIN :singles: it picks :easy against :medium and nothing
      # else, because every other class is one rung wide (see DEMAND_RANGE and
      # DEMAND_EDGES). A rule in the :locked, :subset or :advanced sets can
      # therefore never move a tier by its weight, whatever the number -- so
      # x_wing's 140 and xy_wing's 160 are here for TABLE CONSISTENCY, not for
      # behaviour. The one place a high weight still does something real is
      # Generator.harder?, which breaks ties between equal-tier rescue
      # candidates by score. Retuning these numbers is safe; deleting one is
      # not, because UNKNOWN_WEIGHT would then quietly price it.
      WEIGHT = {
        naked_single: 4,
        hidden_single: 14,
        pointing: 50,      # locked candidates, both directions
        naked_pair: 60,
        hidden_pair: 70,
        naked_triple: 80,
        hidden_triple: 100,
        x_wing: 140,
        xy_wing: 160
      }.freeze

      # A technique that fired but has no weight scores as the hardest known
      # rule rather than as free. Deliberately not an exception: this runs
      # inside puzzle generation, where the cost of the safety net firing
      # should be a puzzle rated too hard, never a game that dies mid-tap. But
      # deliberately not zero either -- a rule added to Techniques::ORDER and
      # forgotten here would otherwise be silently free, and no test would
      # catch a difficulty that quietly stopped counting.
      #
      # It tracks the dearest weight in the table, so it rose from 140 to 160
      # when xy_wing arrived. A test pins that relationship rather than the
      # number, because "the hardest known rule" is the property that matters.
      UNKNOWN_WEIGHT = 160

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

      # FIVE RUNGS, easiest first. Single upper-case words on purpose: Font's
      # glyph table holds A-Z 0-9 space - : . and nothing else, and Font.draw
      # silently draws NOTHING for a missing glyph while still advancing the
      # cursor -- so :very_hard would render as "VERY", a gap, "HARD", with no
      # error anywhere. Renderer#draw_header prints difficulty.to_s.upcase, so
      # the SYMBOL is the label.
      #
      # The header survives five names without a layout change: EXPERT and
      # MASTER are 6 characters, exactly as MEDIUM already is -- 175 px at
      # Layout::LABEL_SCALE 5, right-aligned to x = 1332, so starting at
      # x = 1157, against REDOKU ending at x = 352 at TITLE_SCALE 8.
      #
      # This is the ONLY tier list. Renderer::DIFFICULTIES used to hold a
      # second copy and was deleted in 75eb7cf for being exactly that; app.rb
      # and test/app.rb read TIERS directly. Do not reintroduce one.
      TIERS = [:easy, :medium, :hard, :expert, :master].freeze

      # THE RULE SETS THAT DEFINE THE LADDER, weakest first, each a superset of
      # the last. A board's DEMAND is the weakest of these that finishes it,
      # or nil -- a reject -- if even the strongest cannot.
      #
      # DEFINED BY MEMBERSHIP, NOT BY ORDER POSITION. ORDER lists naked_triple
      # AHEAD of hidden_pair (a readability choice recorded in techniques.rb),
      # so a ladder with one rung per ORDER position would let that cosmetic
      # ordering decide a tier -- and it measured badly: the per-rule prefix
      # ladder found 0 X-wing boards in 1467 where these four sets find 10 in
      # 4852, because it filed them under "pair". Getting that wrong does not
      # fail loudly; it silently makes the top rung unreachable.
      #
      # BUT NOTE WHAT IS ALSO TRUE, because demand_of's early break leans on
      # it: each of these four sets happens to be a CONTIGUOUS PREFIX of ORDER
      # taken as a set -- ORDER[0..1], [0..2], [0..6], [0..8]. The level
      # boundaries fall either side of the naked_triple / hidden_pair swap, not
      # through it. That is what licenses breaking out of the downward walk
      # (see demand_of), and it is an accident of where the boundaries landed,
      # so test/sudoku_rater.rb pins it explicitly. Moving a name across a
      # boundary, or re-ordering ORDER, breaks the soundness argument without
      # breaking any other test.
      #
      # TRIPLES SIT WITH THE PAIRS and are not a rung. Boards that genuinely
      # require a naked or hidden triple turned up on 1 chain in 500; boards
      # requiring an X-wing on 10 in 500, ten times more common. The subset
      # rules all narrow toward the same candidate fixed point, so a triple
      # rarely deduces anything the pairs did not (difficulty-rating.md
      # records hidden_triple never firing at all); X-wing reasons across two
      # units and is the only rule in our repertoire that adds a genuinely
      # different kind of inference.
      #
      # THE X-WING AND THE XY-WING SHARE THE TOP SET, which is a deliberate
      # widening rather than an oversight, and it is why there is no sixth
      # rung. With x_wing alone the top set was reachable on about 2% of dig
      # chains: MASTER cost 6961 ms at the median on the host, hit 80% of
      # requests at its 150-attempt cap, and each miss burned 17-21 s. The
      # owner's requirement is that the top rung need an ADVANCED technique,
      # not that it need one SPECIFIC advanced technique, so the set says "an
      # X-wing or an XY-wing" and the rarity problem goes away. The other side
      # of the same win: 22% of chain floors used to be rejects our rules
      # could not finish at all, and the XY-wing converts part of that pool
      # into certifiable top-tier boards instead of discarding it.
      #
      # THE CLASS IS CALLED :advanced, not :xwing, and the rename is the whole
      # reason to mention it. It held one rule and was named after it, which
      # stopped being true the moment it held two -- and it would have kept
      # drifting, because this is the set every further rule joins. What the
      # members have in common is not being a fish or being a wing but
      # REASONING BEYOND A SINGLE UNIT, which is what the name now says.
      # DEMANDS names are internal; TIERS supplies every label a player sees.
      #
      # The strongest set is Techniques::ORDER, SPELLED OUT rather than
      # referenced: mrblib loads in sorted-path order, so rater.rb loads
      # BEFORE techniques.rb and naming Techniques::ORDER here would raise
      # NameError at load and take the whole gem down. test/sudoku_rater.rb
      # pins this copy against ORDER, and that test is the only thing keeping
      # the two in step -- the copy is forced by the load order, so it cannot
      # be removed the way Renderer::DIFFICULTIES was.
      DEMAND_SETS = [
        [:naked_single, :hidden_single].freeze,
        [:naked_single, :hidden_single, :pointing].freeze,
        [:naked_single, :hidden_single, :pointing, :naked_pair, :hidden_pair,
         :naked_triple, :hidden_triple].freeze,
        [:naked_single, :hidden_single, :pointing, :naked_pair, :hidden_pair,
         :naked_triple, :hidden_triple, :x_wing, :xy_wing].freeze
      ].freeze

      # The name of each set, in the same order.
      DEMANDS = [:singles, :locked, :subset, :advanced].freeze

      # Which rungs a demand class may occupy, as [first, last] indices into
      # TIERS. THIS IS THE FIX. The old TECHNIQUE_FLOOR could only ever RAISE
      # a tier, so a big enough score promoted a singles-only board to the top
      # -- measured, 22 of 40 :hard boards (55%) were solvable by naked and
      # hidden singles alone, and every one of 40 :medium boards was. Here the
      # class sets a CEILING as well as a floor, so volume can no longer buy
      # cleverness.
      DEMAND_RANGE = {
        singles:  [0, 1].freeze,  # easy or medium, by score
        locked:   [2, 2].freeze,
        subset:   [3, 3].freeze,
        advanced: [4, 4].freeze
      }.freeze

      # Score edges INSIDE a class's range: exactly one fewer than the range is
      # wide, so only :singles has any. This is all that is left of the old
      # CEILING, and it is the one place the owner's "long, not clever is more
      # fun" axis lives -- deliberately at the BOTTOM of the ladder, where the
      # owner finds it fun, rather than at the top, where it was wrong.
      #
      # 140 MEASURED, not chosen for roundness. EASY boards (44-45 clues)
      # score 97-117 over 500 chains, so any edge above 117 keeps them easy;
      # the deepest singles-only board on a chain scores p50 203. The edge
      # trades MEDIUM's reachability against how long a MEDIUM has to be:
      # 120 -> reachable on 99% of chains, 140 -> 89%, 160 -> 75%, 180 -> 66%,
      # 200 -> 51%, 230 -> 29%. 140 keeps a clear gap above EASY's worst case
      # and leaves MEDIUM reachable on nine chains in ten.
      #
      # Those percentages are PER-CHAIN reachability measured under the DEEP
      # walk. They are not a hit rate for a request, and they are not evidence
      # about the shallow walk -- a request draws a fresh chain per attempt, so
      # the hit rate at a cap of 12 is far higher than 89%. Do not quote 89% as
      # "MEDIUM works nine times in ten".
      DEMAND_EDGES = { singles: [140].freeze }.freeze

      # Rule -> the index of the WEAKEST demand class that contains it. Built
      # from DEMAND_SETS walking strongest to weakest so the weakest
      # assignment wins, because the sets are nested.
      def self.build_rule_level
        table = {}
        i = DEMAND_SETS.size - 1
        while i >= 0
          DEMAND_SETS[i].each { |name| table.store(name, i) }
          i -= 1
        end
        table
      end
      RULE_LEVEL = build_rule_level.freeze

      # Everything known about a board in one pass.
      #
      #   tier     which rung, or NIL for a reject -- see below
      #   demand   the weakest rule set that finishes it, or nil
      #   score    the weighted technique sum, or nil for a reject
      #   counts   how many times each technique was needed
      #   hardest  the hardest single technique that fired, or nil
      #   solved   whether the nine rules finished it
      #
      # tier: nil means REJECT: our rules cannot finish this board, so it is
      # not a puzzle we may ship under the no-guessing rule. CALLERS MUST
      # HANDLE NIL -- this is a contract change, today's measure always named a
      # tier.
      #
      # Solver.cost and the GUESS weight have LEFT the rating path entirely. A
      # scored board is by construction one the techniques finished, so the
      # guess term was always zero on every board that still gets a score.
      # Solver.cost stays as a diagnostic (its own tests pin it) and is simply
      # not called from here. Measured saving: p50 1.2 ms, max 11.4 ms per
      # stalled board -- small, and worth saying so rather than claiming a win.
      # The expensive half of a stalled board is Techniques.solve itself, at
      # 8.6-28.1 ms, because hidden_triple and x_wing are dear to DECLINE.
      #
      # And it is NOT why `make test` got faster in the commit that made this
      # change. MEASURED, by running the new rating code with the real
      # generator still behind test/app.rb's `new_app` and then with the
      # FakeGenerator: 8.93 s against 5.41 s, where the OLD rating code with
      # the real generator was 7.01 s. So the demand ladder is about 1.9 s
      # DEARER per suite (+27%) even with Solver.cost already removed, and the
      # whole observed speedup is the FakeGenerator switch, which more than
      # covers it. demand_of buys accuracy with up to three extra solves per
      # board; do not cite this paragraph as evidence that it is cheaper.
      def self.measure(values)
        result = Techniques.solve(values)
        unless result[:solved]
          return { tier: nil, demand: nil, score: nil, counts: result[:counts],
                   hardest: result[:hardest], solved: false }
        end
        score = points(result[:counts])
        demand = demand_of(values, result[:counts])
        { tier: tier_for(demand, score), demand: demand, score: score,
          counts: result[:counts], hardest: result[:hardest], solved: true }
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

      # The weakest DEMAND_SET that finishes this board.
      #
      # PRECONDITION, AND IT IS NOT CHECKED: `counts` must come from a
      # FULL-REPERTOIRE solve of THESE SAME `values` -- that is,
      # `Techniques.solve(values)[:counts]` with no rule mask. `measure` is the
      # only production caller and satisfies it by construction; anything else
      # has to as well.
      #
      # What goes wrong otherwise is silent and one-directional. `counts` is
      # only ever read by upper_bound, so counts that CLAIM a rule the board
      # did not need cost nothing but time: the downward walk re-solves and
      # corrects them all the way back down (the test
      # 'Rater.demand_of confirms the weakest set' pins exactly that, handing
      # it a fabricated x_wing on an easy board). Counts that OMIT a rule the
      # board really did need are the hazard, because nothing re-solves
      # upward: the bound starts too low, the walk can only go down from
      # there, and the answer is a demand class too weak for the board. Pass
      # XWING_81 with `{ naked_single: 1 }` and it answers :singles -- a wrong
      # tier, with no error anywhere and no assertion to catch it. Task 3 adds
      # callers, which is why this is written down rather than left as a
      # property of the one call site.
      #
      # `counts` gives an exact upper bound for FREE (see upper_bound), and the
      # solve that produced it is one the caller needed anyway to know the
      # board is not a reject. From there, walk DOWN the ladder confirming with
      # one solve each until a set fails; the last set that succeeded is the
      # demand. Only a board where a strong rule actually fired pays for any
      # confirming solve at all.
      #
      # WHY CONFIRM AT ALL, when a rule fired: because firing is not the same
      # as being needed. The eliminators are confluent -- over 120 boards no
      # eliminator was ever INDIVIDUALLY indispensable, because whenever one
      # was used another rule reached the same fixed point. Measured: x_wing
      # fired on 17 of ~3400 boards and on all 17 it really was needed; the
      # confirming solve is kept anyway, because 17/17 is an observation about
      # a corpus and not a theorem, and the cost of being wrong is a
      # mislabelled tier.
      #
      # WHY DOWNWARD AND NOT A CASCADE OF PER-RULE TESTS: a cascade that
      # branches on "did a subset rule fire?" after confirming the subset set
      # can return :locked without ever testing whether LOCKED solves the
      # board -- the rules that fire in a RESTRICTED run are not the rules that
      # fired in the full one. Walking down tests every set it claims.
      #
      # WHY THE BREAK IS SOUND, spelled out because it is subtler than it
      # looks and nothing else in this file says it. The loop stops at the
      # first failure and reports the set below it, which needs
      #
      #     DEMAND_SETS[k-1] fails to solve  =>  DEMAND_SETS[k-2] fails too
      #
      # and THAT DOES NOT FOLLOW FROM NESTING. A superset can contain a rule
      # that sits EARLIER in ORDER than the one the smaller run took, pre-empt
      # it, and walk a different path -- so "more rules cannot hurt" needs an
      # argument, not an appeal to obviousness.
      #
      # The argument is the one upper_bound uses, run backwards. At each state
      # the solver takes the FIRST rule in ORDER that fires, so no rule ahead
      # of it fired at that state, member of the set or not. So if F is the set
      # of rules that fired in a successful run, EVERY T with
      # F subset T subset ORDER takes the same rule at every state and solves.
      # When the sets are contiguous ORDER PREFIXES, S subset T gives
      # F subset S subset T, so T solves whenever S does -- and the
      # contrapositive is exactly the implication the break needs.
      #
      # So the break is sound BECAUSE the four sets are ORDER prefixes, which
      # they are today by where the boundaries happen to land. That is pinned
      # by 'every demand set is a contiguous prefix of ORDER' in
      # test/sudoku_rater.rb. If that test is ever deleted or a boundary moves,
      # delete the `break` and walk the whole ladder instead: it costs at most
      # three extra solves on the rare board that got past upper_bound, and it
      # needs no property of ORDER at all.
      #
      # (A confluence argument would give the same conclusion for ANY nested
      # sets -- these nine rules are all sound and monotone, so their closure
      # should not depend on the order they are tried in. That is a stronger
      # claim about how nine rules interact and nothing in this repository has
      # measured it, so it is not what the code leans on.)
      #
      # Measured cost over 500 chains: 1 solve per board at p50, mean 7 per
      # chain including the neighbourhood work, max 40.
      def self.demand_of(values, counts)
        k = upper_bound(counts)
        while k > 0
          break unless Techniques.solves?(values, DEMAND_SETS[k - 1])
          k -= 1
        end
        DEMANDS[k]
      end

      # The strongest class any rule that FIRED belongs to -- an exact upper
      # bound on the demand, at no cost.
      #
      # Sound because the solve is deterministic and tries rules in a fixed
      # order: a rule that declined at every step of the all-rules run
      # declines at every step of a run without it, since the two runs visit
      # exactly the same states. So the set of rules that fired is enough to
      # finish the board, and the weakest DEMAND_SET containing all of them is
      # therefore enough too. Note this needs NOTHING about prefixes -- any
      # superset of the fired rules will do, which is why the upper bound is
      # safe even if ORDER is re-ordered. demand_of's BREAK is the part that
      # is not; see there.
      def self.upper_bound(counts)
        k = 0
        counts.each_key do |name|
          level = RULE_LEVEL[name]
          # A rule added to Techniques::ORDER and forgotten in DEMAND_SETS is
          # treated as the STRONGEST class, for UNKNOWN_WEIGHT's reason: the
          # safety net firing should make a board look harder than it is, never
          # silently free.
          level = DEMANDS.size - 1 if level.nil?
          k = level if level > k
        end
        k
      end

      # The rung a board sits on: its demand class picks the run of tiers, and
      # the score picks within that run -- which only :singles is wide enough
      # to allow. An unknown demand has no tier rather than a wrong one.
      def self.tier_for(demand, score)
        range = DEMAND_RANGE[demand]
        return nil if range.nil?
        i = range[0]
        edges = DEMAND_EDGES[demand]
        if edges
          j = 0
          while j < edges.size && score > edges[j]
            i += 1
            j += 1
          end
        end
        # Cannot happen while every class has width-1 edges (a test pins that),
        # but a table typo must not index off the end of TIERS.
        i = range[1] if i > range[1]
        TIERS[i]
      end

      # Where a tier sits on the ladder. A reject (nil) and an unknown name
      # both rank BELOW every real tier, so neither can win an "is this hard
      # enough?" comparison by accident -- which is what Generator's monotone
      # dismissal leans on.
      def self.rank(tier)
        i = TIERS.index(tier)
        i.nil? ? -1 : i
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
