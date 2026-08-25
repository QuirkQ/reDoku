assert('Rater.points weights each use and discounts repeats') do
  r = Redoku::Sudoku::Rater
  # One use of a rule costs its full weight.
  assert_equal(r::WEIGHT[:naked_single], r.points({ naked_single: 1 }))
  assert_equal(r::WEIGHT[:x_wing], r.points({ x_wing: 1 }))

  # A repeat costs the discounted rate, not the full one. Derived from the
  # constants rather than written in as a literal, so the assertion follows
  # the premium if it is ever retuned.
  w = r::WEIGHT[:pointing]
  expected = w + ((1 * w * r::REPEAT_NUM) / r::REPEAT_DEN)
  assert_equal(expected, r.points({ pointing: 2 }))
  assert_true r.points({ pointing: 2 }) < 2 * w  # genuinely a discount
  assert_true r.points({ pointing: 2 }) > w      # but still costs something

  # Rules add up independently.
  assert_equal(r::WEIGHT[:naked_single] + r::WEIGHT[:hidden_single],
               r.points({ naked_single: 1, hidden_single: 1 }))

  # An empty log is free -- a board that needed nothing scores nothing.
  assert_equal(0, r.points({}))
end

assert('Rater.points charges an unweighted technique as the hardest, not as free') do
  r = Redoku::Sudoku::Rater
  # A rule added to Techniques::ORDER but forgotten in WEIGHT must not be
  # silently free: that is a difficulty that quietly stopped counting, and no
  # other test would notice. It must not raise either -- this runs inside
  # generation, and a puzzle rated too hard beats a game that dies mid-tap.
  assert_equal(r::UNKNOWN_WEIGHT, r.points({ some_future_rule: 1 }))
  assert_true r::UNKNOWN_WEIGHT > r::WEIGHT[:naked_single]
end

assert('Rater weights rank locked candidates below the pairs') do
  r = Redoku::Sudoku::Rater
  # Both published graders agree on this and an earlier version of ours had it
  # backwards, ranking pointing as the hardest of the eliminators. HoDoKu:
  # locked candidates 50, naked pair 60, hidden pair 70. Sudoku Explainer:
  # pointing 2.6, naked pair 3.0, hidden pair 3.4.
  assert_true r::WEIGHT[:pointing] < r::WEIGHT[:naked_pair]
  assert_true r::WEIGHT[:naked_pair] < r::WEIGHT[:hidden_pair]
  # And the singles are cheaper than every eliminator.
  assert_true r::WEIGHT[:naked_single] < r::WEIGHT[:pointing]
  assert_true r::WEIGHT[:hidden_single] < r::WEIGHT[:pointing]
  # The XY-wing is the dearest rule we implement and the X-wing the next
  # dearest -- the two that reason beyond a single unit, in the order both
  # published graders put them (HoDoKu 140 then 160, Sudoku Explainer 3.2 then
  # 4.2). The loop is what actually pins "dearest"; naming the runner-up as
  # well is what stops a new rule being slotted in above X-wing unnoticed.
  r::WEIGHT.each_key do |name|
    assert_true r::WEIGHT[name] <= r::WEIGHT[:xy_wing]
  end
  assert_true r::WEIGHT[:x_wing] < r::WEIGHT[:xy_wing]
  r::WEIGHT.each_key do |name|
    next if name == :xy_wing
    assert_true r::WEIGHT[name] <= r::WEIGHT[:x_wing]
  end
  # An unweighted rule must still be charged as the dearest KNOWN one, which
  # is a claim about this table rather than about whatever number
  # UNKNOWN_WEIGHT happens to hold today.
  r::WEIGHT.each_key do |name|
    assert_true r::WEIGHT[name] <= r::UNKNOWN_WEIGHT
  end
end

assert('Rater has five rungs, named so the font can print them') do
  r = Redoku::Sudoku::Rater
  assert_equal([:easy, :medium, :hard, :expert, :master], r::TIERS)
  # Font::GLYPHS holds A-Z 0-9 space - : . and NOTHING else, and Font.draw
  # silently draws nothing for a missing glyph while still advancing the
  # cursor -- so :very_hard would print as "VERY", a gap, "HARD", with no
  # error anywhere and no test to catch it. Every rung name is checked against
  # the real glyph table, which is the only thing that can settle it.
  r::TIERS.each do |tier|
    tier.to_s.upcase.each_char do |ch|
      assert_true Redoku::Font::GLYPHS.has_key?(ch)
    end
  end
end

assert('Rater demand classes tile the tier ladder with no gap or overlap') do
  r = Redoku::Sudoku::Rater
  # The ladder is meant to be data: adding a rung is an edit to TIERS,
  # DEMAND_RANGE and DEMAND_EDGES and nothing else. This pins the DERIVATION
  # rather than today's five values.
  assert_equal(r::DEMAND_SETS.size, r::DEMANDS.size)
  assert_equal(r::DEMANDS.size, r::DEMAND_RANGE.size)

  # Each class owns a contiguous run of tiers; the runs abut, start at 0 and
  # finish at the top rung. A gap would make a tier unreachable; an overlap
  # would make a board's tier ambiguous.
  expected_first = 0
  r::DEMANDS.each do |demand|
    range = r::DEMAND_RANGE[demand]
    assert_false range.nil?
    assert_equal(expected_first, range[0])
    assert_true range[1] >= range[0]
    expected_first = range[1] + 1
  end
  assert_equal(r::TIERS.size, expected_first)

  # A class of width w needs exactly w-1 score edges: one boundary fewer than
  # the rungs it spans. Absent means none, which is what every class but
  # :singles has.
  r::DEMANDS.each do |demand|
    range = r::DEMAND_RANGE[demand]
    edges = r::DEMAND_EDGES[demand] || []
    assert_equal(range[1] - range[0], edges.size)
    i = 1
    while i < edges.size
      assert_true edges[i] > edges[i - 1]
      i += 1
    end
  end

  # Only :singles is allowed to consult the score at all. That is the whole
  # fix: today's TECHNIQUE_FLOOR could only ever RAISE a tier, so a big enough
  # score promoted a singles-only board to the top -- measured, 55% of :hard
  # boards. A class whose range is one tier wide cannot be promoted by volume.
  assert_equal([140], r::DEMAND_EDGES[:singles])
  assert_equal(1, r::DEMAND_RANGE[:singles][1] - r::DEMAND_RANGE[:singles][0])
end

assert('Rater demand sets are nested and cover exactly ORDER') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques
  # DEFINED BY MEMBERSHIP, NOT BY INDEX, and this test is the guard rail on
  # that. ORDER puts naked_triple AHEAD of hidden_pair for readability, so a
  # ladder keyed on ORDER POSITIONS -- one rung per rule -- would let that
  # cosmetic choice decide a tier, and it measured badly: the per-rule prefix
  # ladder found 0 X-wing boards in 1467 where these four sets find 10 in 4852,
  # because it filed them under "pair".
  i = 1
  while i < r::DEMAND_SETS.size
    r::DEMAND_SETS[i - 1].each do |name|
      assert_true r::DEMAND_SETS[i].include?(name)
    end
    assert_true r::DEMAND_SETS[i].size > r::DEMAND_SETS[i - 1].size
    i += 1
  end

  # The strongest set is ORDER, spelled out rather than referenced: rater.rb
  # loads BEFORE techniques.rb (mrblib sorts full paths), so naming
  # Techniques::ORDER in a constant expression would take the gem down at
  # load. This assertion is what keeps the copy honest.
  top = r::DEMAND_SETS[r::DEMAND_SETS.size - 1]
  assert_equal(t::ORDER.size, top.size)
  t::ORDER.each { |name| assert_true top.include?(name) }

  # Every rule knows which class it belongs to, and it is the WEAKEST class
  # that contains it.
  t::ORDER.each do |name|
    level = r::RULE_LEVEL[name]
    assert_false level.nil?
    assert_true r::DEMAND_SETS[level].include?(name)
    assert_false r::DEMAND_SETS[level - 1].include?(name) if level > 0
  end
  # Triples sit with the PAIRS and are not a rung of their own. Boards that
  # genuinely require a triple turned up on 1 chain in 500; boards requiring an
  # X-wing on 10 in 500, ten times more common, because the subset rules all
  # narrow toward the same fixed point while X-wing reasons across two units.
  assert_equal(r::RULE_LEVEL[:naked_pair], r::RULE_LEVEL[:naked_triple])
  assert_equal(r::RULE_LEVEL[:naked_pair], r::RULE_LEVEL[:hidden_triple])
  assert_true r::RULE_LEVEL[:x_wing] > r::RULE_LEVEL[:hidden_triple]
  # THE XY-WING SHARES THE X-WING'S RUNG rather than adding a sixth. That is
  # the whole reason it was added: the top rung asked for an X-wing and
  # X-wing-requiring boards turned up on about 2% of dig chains, so MASTER was
  # a 1-in-50 lottery costing 6961 ms at the median. Widening the top set to
  # "an X-wing OR an XY-wing" fixes availability without moving any boundary,
  # and it keeps the ladder at five rungs -- which is what TIERS, DEMAND_RANGE
  # and the header layout are all sized for.
  assert_equal(r::RULE_LEVEL[:x_wing], r::RULE_LEVEL[:xy_wing])
  assert_equal(r::DEMANDS.size - 1, r::RULE_LEVEL[:xy_wing])
end

assert('every demand set is a contiguous prefix of ORDER, which is what makes demand_of sound') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques
  # THE LOAD-BEARING ACCIDENT, PINNED. demand_of walks DOWN the ladder and
  # BREAKS the moment a set fails to solve the board -- which needs
  # "DEMAND_SETS[k-1] fails => DEMAND_SETS[k-2] fails", and that does NOT
  # follow from nesting alone. Adding a rule that sits EARLIER in ORDER can
  # pre-empt the rule the weaker run relied on and send the solve down a
  # different path, so "a bigger set still solves it" is not free in general.
  #
  # It IS free when every set is a contiguous prefix of ORDER, and here is the
  # argument, which is the one upper_bound already uses run backwards. Let F be
  # the rules that fired in a successful run with set S. At every state the
  # solver takes the FIRST rule in ORDER that fires, so no rule ahead of the
  # one it took fired at that state -- membership or not. Therefore any T with
  # F subset T subset ORDER takes exactly the same rule at every state, visits
  # exactly the same states, and solves. If S is a prefix and T is a longer
  # prefix then F subset S subset T, so T solves whenever S does; contrapose it
  # and the downward break is sound.
  #
  # Nothing else pins this. ORDER's own comment says its ordering is a
  # READABILITY choice and invites re-ordering, and today's boundaries happen
  # to fall at positions 2 and 7 -- either side of the naked_triple /
  # hidden_pair swap, not through it. Move one name across a boundary and the
  # break silently starts mis-classifying boards, with no other test failing.
  # So: this assertion, or delete the break from demand_of. Not neither.
  r::DEMAND_SETS.each do |set|
    set.each { |name| assert_true t::ORDER.include?(name) }
    # A prefix of length n as a SET: every one of ORDER's first n names is in
    # it, and nothing after them is. Order WITHIN the array is irrelevant --
    # mask_of ORs bits -- which is why this asks about membership, not indices.
    n = set.size
    i = 0
    while i < t::ORDER.size
      assert_equal(i < n, set.include?(t::ORDER[i]))
      i += 1
    end
    # The same property in the form the solver actually consumes, because
    # mask_of is what demand_of hands to Techniques.solve: RULE_BIT gives rule
    # k of ORDER the bit 1 << k, so a prefix of length n is the mask with its
    # bottom n bits set and nothing above them. Today: 3, 7, 127, 511. A
    # mask with a hole in it is a set that is not a prefix, and the downward
    # break in demand_of stops being sound.
    assert_equal((1 << n) - 1, t.mask_of(set))
  end
end

assert('Rater.rank orders the tiers and puts a reject below all of them') do
  r = Redoku::Sudoku::Rater
  assert_equal(0, r.rank(:easy))
  assert_equal(4, r.rank(:master))
  assert_true r.rank(:expert) > r.rank(:hard)
  # A reject and a typo both rank below every real tier, so neither can win a
  # "is this hard enough?" comparison by accident.
  assert_equal(-1, r.rank(nil))
  assert_equal(-1, r.rank(:not_a_tier))
end

assert('Rater.tier_for lets the score speak only inside :singles') do
  r = Redoku::Sudoku::Rater
  edge = r::DEMAND_EDGES[:singles][0]
  # The owner's "long, not clever" axis, and it is deliberately the BOTTOM of
  # the ladder rather than the top: a singles-only board is easy when short and
  # medium when long, and can be neither hard nor anything above it however
  # many singles it takes.
  assert_equal(:easy, r.tier_for(:singles, 0))
  assert_equal(:easy, r.tier_for(:singles, edge))
  assert_equal(:medium, r.tier_for(:singles, edge + 1))
  assert_equal(:medium, r.tier_for(:singles, 1_000_000))

  # Above :singles the score has nothing to say: a chain yields at most one or
  # two boards of any given non-singles class, so a per-tier edge there would
  # be a threshold that never fires.
  assert_equal(:hard, r.tier_for(:locked, 0))
  assert_equal(:hard, r.tier_for(:locked, 1_000_000))
  assert_equal(:expert, r.tier_for(:subset, 0))
  assert_equal(:expert, r.tier_for(:subset, 1_000_000))
  assert_equal(:master, r.tier_for(:xwing, 0))
  assert_equal(:master, r.tier_for(:xwing, 1_000_000))

  # An unknown demand has no tier rather than a wrong one.
  assert_nil r.tier_for(:not_a_demand, 100)
end

assert('Rater.upper_bound reads the demand ceiling straight off the counts') do
  r = Redoku::Sudoku::Rater
  # FREE, and this is why the classifier costs about one solve. The solve is
  # deterministic and tries rules in a fixed order, so a rule that DECLINED at
  # every step of the all-rules run declines at every step of a run without it
  # -- the two runs visit the same states. So the board is finished by the
  # weakest DEMAND_SET containing every rule that fired, and that is a table
  # lookup over `counts`.
  assert_equal(0, r.upper_bound({}))
  assert_equal(0, r.upper_bound({ naked_single: 30, hidden_single: 4 }))
  assert_equal(1, r.upper_bound({ naked_single: 30, pointing: 1 }))
  assert_equal(2, r.upper_bound({ pointing: 2, naked_triple: 1 }))
  assert_equal(3, r.upper_bound({ naked_single: 1, x_wing: 1 }))
  # A rule added to Techniques::ORDER and forgotten in RULE_LEVEL must make a
  # board look HARDER, never free -- the UNKNOWN_WEIGHT convention.
  assert_equal(r::DEMANDS.size - 1, r.upper_bound({ some_future_rule: 1 }))
end

assert('Rater.demand_of confirms the weakest set, because firing is not needing') do
  r = Redoku::Sudoku::Rater
  # The leave-one-out result that decides the whole design: over 120 generated
  # boards, the only rule ever INDIVIDUALLY indispensable was hidden_single
  # (3 boards). Pointing, both pairs, both triples and X-wing were never
  # necessary on their own, because the eliminators are confluent -- whenever
  # one was used, some other rule reached the same fixed point. So "which rule
  # fired" cannot be the tier, and demand_of has to confirm by re-solving with
  # the weaker set.
  easy = values_of(EASY_81)
  assert_equal(:singles, r.demand_of(easy, { naked_single: 2 }))
  # Hand it counts CLAIMING an X-wing fired on a board singles can finish: the
  # upper bound says :xwing, the confirming solves walk it all the way back
  # down to :singles. This is the assertion that pins "set inclusion, then
  # confirm" rather than "the hardest rule that fired".
  assert_equal(:singles, r.demand_of(easy, { x_wing: 1 }))
  assert_equal(:singles, r.demand_of(easy, { pointing: 3, naked_pair: 1 }))
end

assert('Rater.measure reports a finished board as needing nothing') do
  r = Redoku::Sudoku::Rater
  m = r.measure(solved_values)
  assert_equal(0, m[:score])
  assert_equal({}, m[:counts])
  assert_nil m[:hardest]
  assert_true m[:solved]
  assert_equal(:singles, m[:demand])
  assert_equal(:easy, m[:tier])
end

assert('Rater.measure answers tier nil for a board our rules cannot finish') do
  r = Redoku::Sudoku::Rater
  # A CONTRACT CHANGE, and the reason every caller has to be read: today's
  # measure always named a tier, flooring a stall at :medium and letting guess
  # points push it up. Under the no-guessing rule a board the nine rules
  # cannot finish is a REJECT -- not a hard puzzle, not a puzzle at all -- and
  # nil is how it says so. 199 of 4852 chain boards (4%) are rejects, and
  # because they crowd the chain floor, 109 of 500 chain FLOORS (22%) are.
  m = r.measure(values_of(MULTI_81))
  assert_nil m[:tier]
  assert_nil m[:demand]
  assert_nil m[:score]
  assert_false m[:solved]
  # The counts of the partial solve still come back: they are what the caller
  # would log, and throwing them away would make a reject undiagnosable.
  assert_false m[:counts].nil?

  # rate and score answer nil for the same board, so no caller can turn a
  # reject into arithmetic by accident.
  assert_nil r.rate(values_of(MULTI_81))
  assert_nil r.score(values_of(MULTI_81))
  assert_nil r.rate(Array.new(81, 0))
end

assert('Rater.measure scores a board with more holes above one with fewer') do
  r = Redoku::Sudoku::Rater
  # Not a claim that clue count is difficulty -- it is a weak predictor and is
  # deliberately not a term in the score. It is a claim about the SUM: more
  # holes need more singles to fill them, so more work is more points. This is
  # the property that makes the score usable as a gradient by the Generator,
  # which walks a chain of ever-emptier boards looking for a target.
  few = r.measure(values_of(EASY_81))     # 79 clues
  more = r.measure(values_of(UNIQUE_81))  # 75 clues
  assert_true more[:score] > few[:score]
end

assert('Rater.rate and Rater.score agree with measure') do
  r = Redoku::Sudoku::Rater
  values = values_of(UNIQUE_81)
  m = r.measure(values)
  assert_equal(m[:tier], r.rate(values))
  assert_equal(m[:score], r.score(values))
  # Every board our rules FINISH gets a real rung.
  [SOLVED_81, EASY_81, UNIQUE_81].each do |board|
    assert_true r::TIERS.include?(r.rate(values_of(board)))
  end
end

assert('Rater is deterministic and does not mutate the board it rates') do
  r = Redoku::Sudoku::Rater
  values = values_of(EASY_81)
  before = values.dup
  first = r.measure(values)
  assert_equal(before, values)
  # Same board, same answer. The Generator steers by this number, and a rating
  # that wobbled would be steering by noise.
  second = r.measure(values)
  assert_equal(first[:score], second[:score])
  assert_equal(first[:tier], second[:tier])
end

assert('Rater.clue_count counts the filled cells') do
  r = Redoku::Sudoku::Rater
  assert_equal(81, r.clue_count(solved_values))
  assert_equal(79, r.clue_count(values_of(EASY_81)))
  assert_equal(75, r.clue_count(values_of(UNIQUE_81)))
  assert_equal(3, r.clue_count(values_of(MULTI_81)))
  assert_equal(0, r.clue_count(Array.new(81, 0)))
end

assert('Rater classifies real boards by the weakest rule set that finishes them') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques

  # Each fixture's class is asserted from the DEFINITION first -- the weakest
  # DEMAND_SET that solves it -- so this test can fail demand_of rather than
  # agreeing with it by construction.
  locked = values_of(LOCKED_81)
  assert_false t.solves?(locked, r::DEMAND_SETS[0])
  assert_true t.solves?(locked, r::DEMAND_SETS[1])
  assert_equal(:locked, r.measure(locked)[:demand])
  assert_equal(:hard, r.measure(locked)[:tier])

  subset = values_of(PAIR_81)
  assert_false t.solves?(subset, r::DEMAND_SETS[1])
  assert_true t.solves?(subset, r::DEMAND_SETS[2])
  assert_equal(:subset, r.measure(subset)[:demand])
  assert_equal(:expert, r.measure(subset)[:tier])

  xwing = values_of(XWING_81)
  assert_false t.solves?(xwing, r::DEMAND_SETS[2])
  assert_true t.solves?(xwing, r::DEMAND_SETS[3])
  assert_equal(:xwing, r.measure(xwing)[:demand])
  assert_equal(:master, r.measure(xwing)[:tier])

  # The second board on the top rung, and the reason the rung is reachable:
  # this one needs the XY-WING, not the X-wing. Both land on :master, which is
  # the point -- widening the top SET rather than adding a sixth rung is what
  # keeps the ladder five rungs long. Measured over 300 chains, this took the
  # share of chains that can serve MASTER from 2 to 40.
  xy = values_of(XY_WING_81)
  assert_false t.solves?(xy, r::DEMAND_SETS[2])
  assert_true t.solves?(xy, r::DEMAND_SETS[3])
  assert_equal(:xwing, r.measure(xy)[:demand])
  assert_equal(:master, r.measure(xy)[:tier])

  # And the ceiling really is a ceiling: however long these boards are, none
  # of them can be promoted past its class, and no singles-only board can
  # reach any of their rungs.
  assert_equal(:medium, r.tier_for(:singles, 10_000))
end
