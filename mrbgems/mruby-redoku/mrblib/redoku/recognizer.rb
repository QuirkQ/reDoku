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

    # Tuned in Task 11 against recorded human clouds. These bootstrap
    # values are set from the authored set only and are deliberately
    # STRICT, per spec §5: a false '?' costs the player one rewrite, while
    # a guess that happens to match the solution is a false win they can
    # neither see nor undo.
    ACCEPT_MAX = 450      # best squared distance must be under this
    # 900 admitted a crossing scribble (X plus bars, the shape an unreadable
    # verdict exists for) at d=491 to the authored 7 — inside the old bar
    # with margin to spare. Every authored variant matches at d=0 with the
    # worst different-digit runner-up at 749, so the bar comes down to 450:
    # still generous for hand ink, but past it a cell is a '?' rather than a
    # lucky guess. Tuned again in Task 11 against recorded human clouds.
    MARGIN_MIN = 220      # runner-up must exceed the best by this

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
      vec << (strokes.size > 255 ? 255 : strokes.size) * 40
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
      flat = []
      strokes.each { |s| s[:subpaths].each { |sub| sub.each { |p| flat << p } } }
      # A release packet repeats the last position (see App#end_stroke), so
      # every captured stroke ends in a zero-length segment — and spread_evenly
      # below picks by INDEX, where one duplicated point distorts the whole
      # resampled cloud. Drop consecutive duplicates: a zero-length segment
      # carries no shape information and replays as a line of no length.
      clean = []
      flat.each { |p| clean << p if clean.empty? || clean[-1] != p }
      return nil if clean.empty?
      pts = spread_evenly(clean, n)
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

    # Picks n points evenly by INDEX, not by arc length. Arc-length
    # resampling is the textbook step and is skipped deliberately: the
    # digitizer already reports at a near-constant rate, so index spacing
    # approximates it closely, and the exact version costs a full
    # path-length pass plus an interpolation per point. If Task 11's
    # accuracy falls short, this is the first thing to upgrade.
    def self.spread_evenly(flat, n)
      return flat.dup if flat.size == n
      out = []
      i = 0
      while i < n
        out << flat[i * (flat.size - 1) / (n - 1)]
        i += 1
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
    def self.reversals(pts)
      n = 0
      last_sx = 0
      last_sy = 0
      i = 1
      while i < pts.size
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        sx = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        sy = dy > 0 ? 1 : (dy < 0 ? -1 : 0)
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
