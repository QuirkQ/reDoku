assert('Rater maps technique AND clue count onto a tier') do
  r = Redoku::Sudoku::Rater
  floor = r::EASY_MIN_CLUES
  # Driven directly, so the tier boundaries are pinned independently of what
  # any particular fixture happens to need.
  #
  # Both signals matter, which is the whole point of this mapping: PLAN.md §7
  # defines easy as "singles only AND >= 36 clues", not as "singles only".
  assert_equal(:easy, r.tier_for(nil, floor))
  assert_equal(:easy, r.tier_for(:naked_single, floor))
  assert_equal(:easy, r.tier_for(:hidden_single, 81))
  # Singles only, but too few clues to be easy.
  assert_equal(:medium, r.tier_for(:naked_single, floor - 1))
  assert_equal(:medium, r.tier_for(nil, 30))
  # An elimination was needed, so no clue count makes it easy.
  assert_equal(:medium, r.tier_for(:naked_pair, 81))
  assert_equal(:medium, r.tier_for(:hidden_pair, floor))
  assert_equal(:medium, r.tier_for(:pointing, 81))

  # Every technique the solver knows maps to a real tier. A rule added to
  # ORDER without a home here would silently rate as medium.
  Redoku::Sudoku::Techniques::ORDER.each do |name|
    assert_true r::TIERS.include?(r.tier_for(name, 40))
  end
end

assert('Rater.singles_only? treats an untouched board as singles') do
  r = Redoku::Sudoku::Rater
  assert_true r.singles_only?(nil)
  assert_true r.singles_only?(:naked_single)
  assert_true r.singles_only?(:hidden_single)
  assert_false r.singles_only?(:naked_pair)
  assert_false r.singles_only?(:hidden_pair)
  assert_false r.singles_only?(:pointing)
end

assert('Rater.clue_count counts the filled cells') do
  r = Redoku::Sudoku::Rater
  assert_equal(81, r.clue_count(solved_values))
  assert_equal(79, r.clue_count(values_of(EASY_81)))
  assert_equal(75, r.clue_count(values_of(UNIQUE_81)))
  assert_equal(3, r.clue_count(values_of(MULTI_81)))
  assert_equal(0, r.clue_count(Array.new(81, 0)))
end

assert('Rater calls a generously clued singles board easy') do
  r = Redoku::Sudoku::Rater
  # 79 and 75 clues, both singles-only.
  assert_equal(:easy, r.rate(values_of(EASY_81)))
  assert_equal(:easy, r.rate(values_of(UNIQUE_81)))
  # A finished board needed nothing at all, which is the easy end.
  assert_equal(:easy, r.rate(solved_values))
end

assert('Rater calls a board the techniques cannot finish hard') do
  r = Redoku::Sudoku::Rater
  # The technique solver stalls on MULTI_81, so a person would have to
  # guess. That is the definition of hard here.
  assert_equal(:hard, r.rate(values_of(MULTI_81)))
  assert_equal(:hard, r.rate(Array.new(81, 0)))
end

assert('Rater tiers are ordered and total') do
  r = Redoku::Sudoku::Rater
  assert_equal([:easy, :medium, :hard], r::TIERS)
  # Every board gets one of the tiers -- rate never returns nil.
  [SOLVED_81, EASY_81, UNIQUE_81, MULTI_81].each do |board|
    assert_true r::TIERS.include?(r.rate(values_of(board)))
  end
end

assert('Rater does not mutate the board it rates') do
  values = values_of(EASY_81)
  before = values.dup
  Redoku::Sudoku::Rater.rate(values)
  assert_equal(before, values)
end
