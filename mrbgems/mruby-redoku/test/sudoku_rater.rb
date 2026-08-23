assert('Rater maps the hardest technique needed onto a tier') do
  r = Redoku::Sudoku::Rater
  # Driven directly, so the tier boundaries are pinned independently of
  # whatever any particular fixture happens to need.
  assert_equal(:easy, r.tier_for(nil))
  assert_equal(:easy, r.tier_for(:naked_single))
  assert_equal(:easy, r.tier_for(:hidden_single))
  assert_equal(:medium, r.tier_for(:naked_pair))
  assert_equal(:medium, r.tier_for(:hidden_pair))
  assert_equal(:medium, r.tier_for(:pointing))
  # Every technique the solver knows has a tier: a new rule added to ORDER
  # without a tier here would silently rate as medium, so check the mapping
  # covers exactly what exists.
  Redoku::Sudoku::Techniques::ORDER.each do |name|
    assert_true r::TIERS.include?(r.tier_for(name))
  end
end

assert('Rater calls a singles-only board easy') do
  assert_equal(:easy, Redoku::Sudoku::Rater.rate(values_of(EASY_81)))
  assert_equal(:easy, Redoku::Sudoku::Rater.rate(values_of(UNIQUE_81)))
  # A finished board needed nothing at all, which is the easy end.
  assert_equal(:easy, Redoku::Sudoku::Rater.rate(solved_values))
end

assert('Rater calls a board the techniques cannot finish hard') do
  r = Redoku::Sudoku::Rater
  # The technique solver stalls on MULTI_81, so a person would have to
  # guess. That is the definition of hard here.
  assert_equal(:hard, r.rate(values_of(MULTI_81)))
  # An empty board likewise.
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
