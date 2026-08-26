# The recognizer's own corpus for now is the authored template set plus
# hand-made distortions of it. That is a weak corpus and is meant to be:
# Task 11 replaces it with recorded human clouds. What it CAN prove today is
# that the pipeline is sane — a template classifies as itself, a distorted
# template still classifies as itself, and noise is refused rather than
# guessed at.

def cell_strokes(subpaths, cell = 10, box = 100)
  # Map a 100x100 authoring box onto a real cell, so the recognizer is
  # exercised on the panel coordinates it will actually see.
  x, y, w, h = Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(cell),
                                        Redoku::Sudoku::Grid.row_of(cell))
  mapped = subpaths.map do |sub|
    sub.map { |px, py| [x + px * w / box, y + py * h / box] }
  end
  [{ color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
     subpaths: mapped }]
end

def jitter(subpaths, dx, dy, scale_num, scale_den)
  subpaths.map do |sub|
    sub.map do |px, py|
      [(px * scale_num / scale_den) + dx, (py * scale_num / scale_den) + dy]
    end
  end
end

assert('resample returns exactly n points however many subpaths there were') do
  s = cell_strokes([[[10, 10], [90, 10]], [[10, 90], [90, 90]]])
  pts = Redoku::Recognizer.resample(s, 32)
  assert_equal 32, pts.size
  pts.each { |p| assert_equal 2, p.size }
end

assert('features is a fixed-length integer vector') do
  a = Redoku::Recognizer.features(cell_strokes([[[10, 10], [90, 90]]]))
  b = Redoku::Recognizer.features(cell_strokes([[[50, 8], [50, 92]]]))
  assert_equal a.size, b.size
  a.each { |v| assert_true v.is_a?(Integer) }
  assert_false a == b   # different shapes must not collide
end

assert('every authored template classifies as its own digit') do
  Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
    got, conf = Redoku::Recognizer.read(cell_strokes(subpaths))
    assert_equal digit, got, "template #{i} (a #{digit}) read as #{got.inspect}"
    assert_true conf > 0
  end
end

assert('a shifted and scaled template still classifies as its digit') do
  # Translation and uniform scale invariance: the player does not write in
  # the middle of the cell at a fixed size.
  Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
    moved = jitter(subpaths, 6, -4, 9, 10)
    got, = Redoku::Recognizer.read(cell_strokes(moved))
    assert_equal digit, got, "template #{i} (a #{digit}) moved read as #{got.inspect}"
  end
end

assert('1 and 7 are not confused, which is what aspect ratio is for') do
  one   = [[[50, 8], [50, 92]]]
  seven = [[[16, 12], [84, 12], [40, 92]]]
  assert_equal 1, Redoku::Recognizer.read(cell_strokes(one))[0]
  assert_equal 7, Redoku::Recognizer.read(cell_strokes(seven))[0]
end

assert('scribble is refused rather than guessed at') do
  # Spec §5: the thresholds err toward nil, because a guess that happens to
  # match the solution is a silent false win.
  scribble = [[[10, 10], [90, 90], [10, 90], [90, 10], [10, 50], [90, 50],
               [50, 10], [50, 90], [20, 20], [80, 80]]]
  got, = Redoku::Recognizer.read(cell_strokes(scribble))
  assert_nil got
end

assert('ink below the dot guard is refused') do
  tiny = [{ color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
            subpaths: [[[300, 400], [302, 401]]] }]
  assert_nil Redoku::Recognizer.read(tiny)[0]
end

assert('no strokes at all reads as nil, not as a crash') do
  assert_nil Redoku::Recognizer.read([])[0]
  assert_nil Redoku::Recognizer.read(nil)[0]
end

assert('the template table resolves lazily, not at load time') do
  # mrblib loads sorted: recognizer.rb comes before sudoku/grid.rb and
  # templates.rb, so a constant built at load would raise. The suite running
  # at all is half the proof; this pins the other half.
  assert_false Redoku::Recognizer.constants.include?(:TEMPLATE_FEATURES)
  assert_true Redoku::Recognizer.template_features.size > 0
  # Same object on the second call — memoised, not rebuilt per read().
  assert_true Redoku::Recognizer.template_features
                .equal?(Redoku::Recognizer.template_features)
end

assert('MEASURE: stage-1 accuracy and cost over the authored corpus') do
  # Not a pass/fail gate — the gate is spec §5's bar, judged by a human
  # reading these numbers. Printed so they reach the ledger.
  right = 0
  refused = 0
  total = 0
  false_pass = 0
  [[0, 0, 10, 10], [6, -4, 9, 10], [-5, 5, 11, 10], [3, 3, 10, 10]].each do |dx, dy, sn, sd|
    Redoku::Templates::AUTHORED.each do |digit, subpaths|
      total += 1
      got, = Redoku::Recognizer.read(cell_strokes(jitter(subpaths, dx, dy, sn, sd)))
      if got == digit
        right += 1
      elsif got.nil?
        refused += 1
      else
        false_pass += 1
      end
    end
  end
  puts "STAGE1 total=#{total} right=#{right} refused=#{refused} " \
       "misread=#{false_pass} accuracy=#{right * 100 / total}%"
  assert_true total > 0
end
