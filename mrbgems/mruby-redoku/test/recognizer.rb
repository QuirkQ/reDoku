# The recognizer's own corpus for now is the authored template set plus
# hand-made distortions of it. That is a weak corpus and is meant to be:
# Task 11 replaces it with recorded human clouds. What it CAN prove today is
# that the pipeline is sane — a template classifies as itself, a distorted
# template still classifies as itself, and noise is refused rather than
# guessed at.
#
# ONE DISTORTION IS NOT OPTIONAL, and this file used to be missing it: the
# templates are 2-to-9-vertex polylines and real ink is HUNDREDS of samples
# along a path, so a test that only ever feeds `cell_strokes(subpaths)` never
# once asks the recognizer a question in the currency the game hands it.
# Every assertion below that matters is therefore run through `pen_sampled`
# as well. It is what caught the 2026-08-28 accuracy report: comparing
# templates against templates, both sides went through the same broken
# resampling step, every template matched itself at d=0, and this file
# measured 100% on a pipeline that refused a third of the same shapes when
# they arrived from a pen.

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

# One stroke, in panel coordinates, holding a 100x100 authoring polyline as a
# PEN would have delivered it: a sample about every PEN_STEP px along the
# path, each displaced by up to `tremor` px on each axis, and every coordinate
# an integer panel pixel at the end. That is what App#note_ink records — every
# sample it is handed, with no decimation anywhere between the pen and
# Recognizer.read — so a real stroke's subpath is a dense integer polyline,
# not the handful of vertices a template is authored as.
#
# WHY THE BOX IS 1400 AND NOT 100: it makes one authoring unit exactly a tenth
# of a panel pixel (140 px cell / 1400), so a step and a tremor can be stated
# in PIXELS, which is the unit both actually have. The integer truncation into
# panel pixels then happens in cell_strokes' own mapping, where real ink's
# quantisation happens too — and quantisation is half of what the tremor is
# testing, since a near-vertical stroke's dx is quantisation noise and nothing
# else.
#
# `seed` runs through Redoku::Rng, so a failure here is reproducible rather
# than a story — the same reason generation is seeded (rng.rb).
PEN_BOX = 1400
PEN_UNIT = PEN_BOX / 100      # authoring units per authored unit
PEN_PX = PEN_BOX / 140        # authoring units per panel pixel
PEN_STEP = 3                  # px between samples

def pen_strokes(subpaths, cell = 10, tremor: 0, seed: 1)
  rng = Redoku::Rng.new(seed)
  span = 2 * tremor * PEN_PX + 1
  out = []
  subpaths.each do |sub|
    pts = []
    i = 0
    while i < sub.size
      b = [sub[i][0] * PEN_UNIT, sub[i][1] * PEN_UNIT]
      if i == 0
        pts << b
      else
        a = [sub[i - 1][0] * PEN_UNIT, sub[i - 1][1] * PEN_UNIT]
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        n = Math.sqrt(dx * dx + dy * dy).to_i / (PEN_STEP * PEN_PX)
        n = 1 if n < 1
        k = 1
        while k <= n
          pts << [a[0] + dx * k / n, a[1] + dy * k / n]
          k += 1
        end
      end
      i += 1
    end
    if tremor > 0
      pts = pts.map do |px, py|
        [px + rng.next_int(span) - tremor * PEN_PX,
         py + rng.next_int(span) - tremor * PEN_PX]
      end
    end
    out << pts
  end
  cell_strokes(out, cell, PEN_BOX)
end

assert('resample returns exactly n points however many subpaths there were') do
  s = cell_strokes([[[10, 10], [90, 10]], [[10, 90], [90, 90]]])
  pts = Redoku::Recognizer.resample(s, 32)
  assert_equal 32, pts.size
  pts.each { |p| assert_equal 2, p.size }
end

assert('resample spreads its points ALONG the path, not piled at one vertex') do
  # THE 2026-08-28 BUG, pinned at the level it happened. resample used to pick
  # its n points by INDEX out of the vertex list, so a 2-point line "resampled"
  # to 32 points returned the first vertex 31 times and the second once. Every
  # feature downstream is computed from these points — the 4x4 density boxes
  # above all — so a template's vector described where its VERTICES were and
  # live ink's described where its PATH was, and the two never matched.
  #
  # A single straight line is the whole test: there is exactly one right
  # answer for "32 points along it", and index-picking gets it maximally
  # wrong.
  pts = Redoku::Recognizer.resample(cell_strokes([[[50, 8], [50, 92]]]), 32)
  assert_equal 32, pts.size
  # Ends at the ends: normalisation puts the bounding box at 0..255.
  assert_equal 0, pts[0][1]
  assert_equal 255, pts[31][1]
  # The middle point in the middle. Under index picking it sat at 0.
  assert_true (pts[16][1] - 128).abs <= 16, "midpoint y was #{pts[16][1]}"
  # And no point repeats its predecessor, which is what "piled at one vertex"
  # looks like: 31 of these 32 were identical before.
  i = 1
  while i < pts.size
    assert_false pts[i] == pts[i - 1], "points #{i - 1} and #{i} are identical"
    i += 1
  end
end

assert('a template read the way the PEN delivers it is still its own digit') do
  # Same shapes as the assertion below, same vertices, sampled every ~3 px the
  # way the digitizer does. 14 of these 21 failed before the resampling fix —
  # 7 refused outright — which is the whole of "the recognition is really
  # weak" as reported on 2026-08-28.
  Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
    got, conf = Redoku::Recognizer.read(pen_strokes(subpaths))
    assert_equal digit, got,
                 "template #{i} (a #{digit}) pen-sampled read as #{got.inspect}"
    assert_true conf > 0
  end
end

assert('hand tremor does not decide the verdict') do
  # Ink arrives as integer panel pixels, so a near-vertical stroke's dx is
  # quantisation noise and its SIGN flips on about half the steps. That is
  # what Recognizer::TURN_MIN exists for: without it a tremored 1 scored 204
  # on the reversals feature against its template's 0, spending four times
  # the whole ACCEPT_MAX budget on noise, and 8 of these 21 refused.
  [20260828, 7, 99].each do |seed|
    Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
      got, = Redoku::Recognizer.read(pen_strokes(subpaths, tremor: 2,
                                                           seed: seed))
      assert_equal digit, got,
                   "template #{i} (a #{digit}) with tremor (seed #{seed}) " \
                   "read as #{got.inspect}"
    end
  end
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
  # And refused when a PEN draws it, which is the only way it ever arrives.
  # This is the assertion that stops the accuracy fix from being made by
  # loosening the bar: Recognizer::TURN_MIN keeps the turn-count feature that
  # separates a scribble from a digit, and dropping the feature instead (which
  # reaches the same accuracy on real digits) makes this read as a 2.
  assert_nil Redoku::Recognizer.read(pen_strokes(scribble))[0]
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

# The corpus walk both MEASURE lines share: the four jitter variants over
# every authored template, counted three ways. The block turns one template's
# polyline into the strokes to read, and receives the variant index so a
# caller can vary a seed with it.
def measure_corpus(label)
  right = 0
  refused = 0
  misread = 0
  [[0, 0, 10, 10], [6, -4, 9, 10], [-5, 5, 11, 10], [3, 3, 10, 10]]
    .each_with_index do |(dx, dy, sn, sd), variant|
    Redoku::Templates::AUTHORED.each do |digit, subpaths|
      got, = Redoku::Recognizer.read(
        yield(jitter(subpaths, dx, dy, sn, sd), variant)
      )
      if got == digit
        right += 1
      elsif got.nil?
        refused += 1
      else
        misread += 1
      end
    end
  end
  total = right + refused + misread
  puts "STAGE1 #{label} total=#{total} right=#{right} refused=#{refused} " \
       "misread=#{misread} accuracy=#{right * 100 / total}%"
  total
end

assert('MEASURE: stage-1 accuracy and cost over the authored corpus') do
  # Not a pass/fail gate — the gate is spec §5's bar, judged by a human
  # reading these numbers. Printed so they reach the ledger.
  #
  # TWO LINES, and the second is the one to read. The VERTICES line is what
  # this block used to print alone, and it said 100% on 2026-08-26 while the
  # recognizer was refusing a third of the same shapes off a pen: templates
  # compared against templates go through every step of the pipeline
  # identically, so that number cannot fall however broken the pipeline is.
  # The PEN line asks the question the game asks. Keep both — the vertices
  # line still catches a template that no longer matches itself — but never
  # quote the first one as accuracy again.
  n = measure_corpus('vertices') { |sp, _v| cell_strokes(sp) }
  # A different tremor seed per jitter variant, so the four blocks are four
  # hands rather than the same displacement applied four times.
  measure_corpus('pen     ') do |sp, v|
    pen_strokes(sp, tremor: 2, seed: 20260828 + v)
  end
  assert_true n > 0
end
