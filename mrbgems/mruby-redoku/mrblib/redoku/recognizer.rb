module Redoku
  # Reads a digit out of the ink sitting in one cell. Runs in a batch when
  # the player presses CHECK — never during play (PLAN.md §6, model change
  # 2026-08-25), so this is invoked ~50 times per press rather than
  # hundreds of times per game, and it may spend a millisecond where a live
  # recognizer could not.
  #
  # NOT $P, which PLAN.md §6 specifies. $P greedy-matches with n^(1-e)
  # starts over an O(n^2) pass: at n=48 against 45 templates that is ~725k
  # point-distance evaluations per cell and ~36M per board, which is
  # seconds to minutes of interpreted mruby on a Cortex-A7 (spec §5 shows
  # the arithmetic). Stage 1 here is a feature vector compared by squared
  # distance: ~1.1k operations per cell.
  #
  # The mruby lesson from ENGINE-IMPROVEMENTS.md applies throughout: the VM
  # has inlined opcodes for arithmetic and []/[]=, but routes every bitwise
  # operator through a method send. So this file counts and indexes; it
  # never packs bits.
  module Recognizer
    POINTS  = 32          # resampled points per cell, fixed
    GRID_N  = 4           # 4x4 ink-density boxes
    DENSITY = GRID_N * GRID_N
    SHAPE   = 8           # aspect, subpaths, reversals, spread, start, end
    SIZE    = DENSITY + SHAPE

    # Set from the authored set only, and deliberately STRICT per spec §5: a
    # false '?' costs the player one rewrite, while a guess that happens to
    # match the solution is a false win they can neither see nor undo.
    #
    # BOTH ARE ON THE SCALE `distance` PRODUCES, so neither means anything
    # once that function changes — which is exactly what happened on
    # 2026-08-28 and is why ACCEPT_MAX moved with it. Re-measure both anchors
    # (the nearest junk, and where real ink lands) after any change to
    # features, resample or distance.
    ACCEPT_MAX = 350      # best squared distance must be under this
    # THE ANCHOR HAS ALWAYS BEEN ONE SHAPE: the crossing scribble (an X plus
    # a plus — what test/app.rb's scribble_in_cell draws, and the shape the
    # unreadable verdict exists for). 900 was the drafted bar and admitted it
    # at d=491 to the authored 7, which would have made '?' unreachable, so
    # the bar came down to 450 with 41 points of clearance.
    #
    # 450 became WRONG when the resampling fix landed (2026-08-28, see
    # along_path): distances collapsed by 3-6x across the board, because the
    # old index resampling was inflating every comparison. On the corrected
    # scale that same scribble sits at d=370 — inside 450 — and pen-sampled
    # authored digits sit at a median of 37, so the identical piece of
    # reasoning now gives 350, with 20 points of clearance under the
    # scribble.
    #
    # It costs nothing measurable: over 105 pen-sampled samples per regime,
    # 450 -> 350 leaves clean at 100%, ±2 px tremor at 100% and ±4 px tremor
    # at 99%, and takes the deliberately-harsh slant-plus-anisotropic-scale
    # regime from 90% to 88%. Below 350 that last regime falls away fast
    # (320 -> 84%, 300 -> 79%) and refuses no junk that 350 does not.
    #
    # MARGIN_MIN is left alone, because this scribble is not a margin case:
    # its runner-up is a 4 at d=1117, so it leads by 747 and only the
    # distance bar can refuse it. Real digits' margins are a median of 743
    # with 5% under 220 — which is the conservatism spec §5 asks for, and
    # the reason nothing in these sweeps MISREADS rather than refusing.
    MARGIN_MIN = 220      # runner-up must exceed the best by this
    # Both are still bootstrap values, and Task 11's recorded human clouds
    # are still what should set them: every number above comes from one
    # author's templates plus modelled distortion, not from a player's hand.

    # The smallest axis step `reversals` will read a DIRECTION off, in the
    # normalised 0..255 frame — anything under it is sampling noise rather
    # than a turn. See reversals for the measurement that set it and for why
    # the feature is kept with a deadband rather than dropped.
    TURN_MIN = 12

    def self.read(strokes)
      live = playable(strokes)
      return [nil, 0] if live.empty?
      want = features(live)
      return [nil, 0] unless want

      best_d = nil
      best_digit = nil
      runner_d = nil
      template_features.each do |digit, vec|
        d = distance(want, vec)
        if best_d.nil? || d < best_d
          runner_d = best_d if best_digit != digit
          best_d = d
          best_digit = digit
        elsif digit != best_digit && (runner_d.nil? || d < runner_d)
          runner_d = d
        end
      end
      return [nil, 0] if best_digit.nil?
      return [nil, 0] if best_d > ACCEPT_MAX
      return [nil, 0] if runner_d && runner_d - best_d < MARGIN_MIN

      # 0..1000, monotone in how far the best beat the bar. Reported so the
      # corpus test in Task 12 can plot accuracy against it, and so
      # --record can show it while capturing.
      conf = 1000 - (best_d * 1000 / ACCEPT_MAX)
      conf = 1 if conf < 1
      [best_digit, conf]
    end

    # Strokes worth classifying: real ink, not a knuckle. The guard is on
    # the COMBINED path so that a digit drawn as several short strokes is
    # not thrown away one stroke at a time.
    def self.playable(strokes)
      return [] unless strokes.is_a?(Array)
      total = 0
      strokes.each { |s| total += Ink.path_length(s) }
      total < Ink::MIN_PATH ? [] : strokes
    end

    # A fixed-length integer vector. Every element is scaled to 0..255 so
    # the squared distance below stays inside mruby's fixnum range on
    # 32-bit ARM even when every component disagrees maximally
    # (24 * 255^2 = 1.6M, against a +-2^30 limit).
    #
    # The last four elements are where the ink STARTS and ENDS, in the same
    # normalised frame as the density boxes. The silhouette alone cannot
    # separate a 3 from a 5 — both are S-curves of nearly the same extent,
    # and their 4x4 densities differ by less than MARGIN_MIN. The pen does
    # not lie: this authored 3 begins top-left, a 5 begins top-right, and
    # that one fact separates them by an order of magnitude. The start/end
    # are taken from the resampled cloud, so translation and scale drop out.
    def self.features(strokes)
      pts = resample(strokes, POINTS)
      return nil if pts.nil? || pts.empty?
      vec = density(pts)
      vec << aspect_of(strokes)
      sub = strokes.size * 40
      vec << (sub > 255 ? 255 : sub)
      vec << reversals(pts)
      vec << spread(pts)
      vec << pts[0][0]
      vec << pts[0][1]
      vec << pts[pts.size - 1][0]
      vec << pts[pts.size - 1][1]
      vec
    end

    # Resample the combined cloud to exactly n points, then normalise:
    # translate the bounding box to the origin and scale by its LARGER
    # side. Scaling by the larger side alone preserves aspect ratio, which
    # is what separates 1 from 7 (PLAN.md §6 says so) — a per-axis
    # normalisation would map both onto the same square.
    #
    # The near-vertical 1 is the degenerate case that needs the guard: its
    # bounding box width can be a single pixel, and dividing by it would
    # blow the shape up to nonsense.
    def self.resample(strokes, n)
      pts = along_path(strokes, n)
      return nil if pts.nil?
      min_x = min_y = max_x = max_y = nil
      pts.each do |x, y|
        if min_x.nil?
          # Not `min_x = max_x = x`: this mruby keeps the first target of a
          # chained assignment block-local, so min_x would stay nil out here.
          min_x = x
          max_x = x
          min_y = y
          max_y = y
          next
        end
        min_x = x if x < min_x
        max_x = x if x > max_x
        min_y = y if y < min_y
        max_y = y if y > max_y
      end
      w = max_x - min_x
      h = max_y - min_y
      side = w > h ? w : h
      side = 1 if side < 1
      out = []
      pts.each do |x, y|
        out << [(x - min_x) * 255 / side, (y - min_y) * 255 / side]
      end
      out
    end

    # n points spaced evenly ALONG THE DRAWN PATH — by arc length, with a
    # real interpolation between the two vertices each one falls between.
    #
    # THIS IS THE FIX FOR "recognition is really weak" (owner report,
    # 2026-08-28), and the old version is worth stating because the bug is
    # not obvious: it picked n points by INDEX out of the vertex list
    # (`flat[i * (flat.size - 1) / (n - 1)]`), on the argument that the
    # digitizer reports at a near-constant rate so index spacing approximates
    # arc length. That argument holds for pen input and fails completely for
    # the AUTHORED templates, which are 2 to 9 vertices, not hundreds of
    # samples: picking 32 points by index out of a 2-point line returns the
    # first vertex THIRTY-ONE times and the second once. So a template's
    # feature vector was a histogram of its vertices, while live ink's was a
    # histogram of its path, and the two are not comparable — the authored
    # `1` scored d=2032 against the same straight line sampled the way a pen
    # samples it, 4.5x over ACCEPT_MAX, for an IDENTICAL shape.
    #
    # Measured on the host (mrbgems/mruby-redoku/test/recognizer.rb's
    # pen-sampled sweeps, and see the MEASURE block for the running numbers):
    # authored templates delivered as pen samples read 14/21 before this and
    # 21/21 after. The suite could not see it because the corpus WAS the
    # templates: both sides of every comparison went through the same broken
    # step, so every template matched itself at d=0 and the file measured
    # 100%. The tests added with this fix feed pen-sampled ink for exactly
    # that reason.
    #
    # `spread_evenly` (the old name) is gone rather than kept alongside: it
    # had one caller and its comment named this upgrade as the thing to do
    # "if Task 11's accuracy falls short", which is what happened.
    #
    # SUBPATH GAPS ARE NOT PATH. Only within-subpath segments become
    # segments here, so a digit written as two strokes never receives sample
    # points along the pen-up jump between them — the same rule
    # Ink.path_length states ("bridging it would invent travel the pen never
    # made"). It also subsumes the old dedup pass: a release packet repeats
    # the last position (App#end_stroke), which is a zero-length segment, and
    # `len > 0` drops it.
    #
    # Cost: one Math.sqrt per input segment, the same pass `playable` already
    # runs through Ink.path_length, plus two multiplies and a divide per
    # output point. Against ~1.1k operations per cell (PLAN.md §6) that is
    # noise, and it buys the accuracy above.
    def self.along_path(strokes, n)
      segs = []
      total = 0
      strokes.each do |s|
        s[:subpaths].each do |sub|
          i = 1
          while i < sub.size
            a = sub[i - 1]
            b = sub[i]
            dx = b[0] - a[0]
            dy = b[1] - a[1]
            len = Math.sqrt(dx * dx + dy * dy).to_i
            if len > 0
              # Each segment carries the arc length BEFORE it, so the walk
              # below can seek by comparison instead of re-accumulating.
              segs << [a, b, len, total]
              total += len
            end
            i += 1
          end
        end
      end
      # Nothing that moved a whole pixel: a knuckle, or a stroke that begins
      # and ends on the same point. read()'s dot guard normally answers this
      # first (Ink::MIN_PATH), and nil says the same thing one layer down
      # rather than dividing by a zero length.
      return nil if segs.empty?
      # Seek rather than accumulate: `want` is computed from the total, so
      # rounding cannot drift over 32 steps the way `+= step` would. The
      # denominator is clamped because n = 1 asks for "one point" and would
      # otherwise divide by zero; POINTS is 32 and nothing calls it with 1.
      den = n - 1
      den = 1 if den < 1
      out = []
      k = 0
      si = 0
      while k < n
        want = total * k / den
        si += 1 while si < segs.size - 1 && segs[si + 1][3] <= want
        seg = segs[si]
        a = seg[0]
        b = seg[1]
        t = want - seg[3]
        out << [a[0] + (b[0] - a[0]) * t / seg[2],
                a[1] + (b[1] - a[1]) * t / seg[2]]
        k += 1
      end
      out
    end

    def self.density(pts)
      boxes = Array.new(DENSITY, 0)
      pts.each do |x, y|
        cx = x * GRID_N / 256
        cy = y * GRID_N / 256
        cx = GRID_N - 1 if cx > GRID_N - 1
        cy = GRID_N - 1 if cy > GRID_N - 1
        boxes[cy * GRID_N + cx] += 1
      end
      out = []
      boxes.each { |c| out << c * 255 / pts.size }
      out
    end

    def self.aspect_of(strokes)
      min_x = min_y = max_x = max_y = nil
      strokes.each do |s|
        b = Ink.bbox(s)
        next unless b
        min_x = b[0] if min_x.nil? || b[0] < min_x
        min_y = b[1] if min_y.nil? || b[1] < min_y
        max_x = b[2] if max_x.nil? || b[2] > max_x
        max_y = b[3] if max_y.nil? || b[3] > max_y
      end
      return 128 if min_x.nil?
      w = max_x - min_x
      h = max_y - min_y
      return 255 if h < 1
      r = w * 128 / h
      r > 255 ? 255 : r
    end

    # How often the path doubles back. A 1 barely turns; an 8 turns
    # constantly. Counted on the sign of each axis delta rather than on an
    # angle, because atan2 per point is dear and the sign is enough.
    #
    # TURN_MIN is what makes that true of REAL ink, and it is the second half
    # of the 2026-08-28 accuracy fix. Ink arrives as integer panel pixels
    # (App#note_ink records every sample verbatim), so on a near-vertical
    # stroke dx is not "about zero" — it is quantisation and hand tremor, and
    # its SIGN is therefore noise that flips on about half of the steps. With
    # no deadband a hand-drawn 1 scored 204 on this feature where its
    # template scores 0, contributing 1734 of a total distance of 1740: this
    # one feature spent the whole ACCEPT_MAX budget four times over on noise.
    # Measured over the pen-sampled corpus with ±2 px of tremor: 59% correct
    # at deadband 0, 100% at 12 (and 100% at 8 and 16 too — 12 is the middle
    # of a plateau, not a knife edge).
    #
    # DELETING the feature reaches the same accuracy on digits (126/126 either
    # way over the clean and ±2 px sweeps) and is still the wrong fix, because
    # turn count is precisely what tells a scribble from a digit: drop it and
    # ACCEPT_MAX's own anchor scribble falls from d=370 to d=220 and reads as
    # a 7. The deadband keeps the signal and throws away the noise; deleting
    # the feature throws away both.
    def self.reversals(pts)
      n = 0
      last_sx = 0
      last_sy = 0
      i = 1
      while i < pts.size
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        sx = dx > TURN_MIN ? 1 : (dx < -TURN_MIN ? -1 : 0)
        sy = dy > TURN_MIN ? 1 : (dy < -TURN_MIN ? -1 : 0)
        n += 1 if sx != 0 && last_sx != 0 && sx != last_sx
        n += 1 if sy != 0 && last_sy != 0 && sy != last_sy
        last_sx = sx if sx != 0
        last_sy = sy if sy != 0
        i += 1
      end
      v = n * 12
      v > 255 ? 255 : v
    end

    # Mean absolute deviation from the centre — a blunt "how spread out is
    # the ink", which separates a compact 0-ish 8 from a sprawling 7.
    def self.spread(pts)
      total = 0
      pts.each do |x, y|
        dx = x - 128
        dy = y - 128
        total += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy)
      end
      v = total / pts.size
      v > 255 ? 255 : v
    end

    def self.distance(a, b)
      d = 0
      i = 0
      while i < a.size
        t = a[i] - b[i]
        d += t * t
        i += 1
      end
      d / a.size
    end

    # MEMOISED ON FIRST USE, and deliberately NOT a constant initialised at
    # load time. mruby loads a gem's mrblib as `Dir.glob('mrblib/**/*.rb')`
    # sorted, which puts this file (`redoku/recognizer.rb`) BEFORE both
    # `redoku/sudoku/grid.rb` and `redoku/templates.rb` — so
    # `TEMPLATE_FEATURES = build_template_features` would raise
    # `uninitialized constant Redoku::Templates` at load. This is the same
    # load-order trap ENGINE-IMPROVEMENTS.md item 4 records against
    # DEMAND_SETS, where it forced four rule lists to be duplicated by hand;
    # resolving the dependency inside a method makes load order irrelevant
    # instead of making it someone's problem later.
    #
    # Not thread-safety-sensitive: the game is a single-threaded poll loop.
    def self.template_features
      @template_features ||= build_template_features
    end

    # The authored polylines live in a 100x100 box, and the recorded ones
    # (templates.local, via Recorder#to_text) are already in panel points —
    # both are lifted into a real cell's coordinates before their feature
    # vectors are computed, because the feature vector must come from the
    # same kind of input the game hands read(). For the recorded set the
    # lift is an isotropic scale-and-shift of points that were already
    # panel-sized, which resample's normalisation (translate + uniform
    # scale by the larger side) divides back out; only its integer rounding
    # survives, which is noise at 140 px cells.
    def self.build_template_features
      out = []
      add_features(out, Templates::AUTHORED)
      add_features(out, load_local)   # the player's own hand, on top
      out
    end

    def self.add_features(out, set)
      cell = 40 # the middle cell; any cell works, features are normalised
      x, y, w, h = Layout.cell_rect(Sudoku::Grid.col_of(cell),
                                    Sudoku::Grid.row_of(cell))
      set.each do |digit, subpaths|
        mapped = []
        subpaths.each do |sub|
          m = []
          sub.each { |px, py| m << [x + px * w / 100, y + py * h / 100] }
          mapped << m
        end
        vec = features([{ color: 0, width: 1, subpaths: mapped }])
        out << [digit, vec] if vec
      end
      out
    end

    # Missing file is the NORMAL case, not an error: nobody has recorded
    # anything on a fresh install, and the authored set is what ships.
    def self.load_local
      return [] unless File.exist?(Recorder::TARGET)
      Recorder.parse(File.read(Recorder::TARGET))
    rescue StandardError
      []
    end

  end
end
