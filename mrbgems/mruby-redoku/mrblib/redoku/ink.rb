module Redoku
  # Geometry over one journaled ink stroke. Pure Ruby, no display and no
  # store: the same stroke hash M3a persists and replays
  # ({ color:, width:, subpaths: [[[x, y], ...], ...] }, panel coordinates,
  # plus an id: from schema v3 which nothing here reads).
  #
  # Three callers, all of which ask the same question in different words:
  # the eraser wants "which strokes are in the cell I just cleared", CHECK
  # wants "group the live ink by cell", and the dot guard wants "is this
  # ink at all, or a knuckle". Kept in one module so the answer cannot
  # drift between them — a stroke assigned to cell A by the recognizer and
  # cell B by the eraser would strand ink that no repaint could remove.
  module Ink
    # Ink below this much total path is an accidental contact, not a mark
    # (PLAN.md §6, "tiny dots (< 8 px path) are discarded"). Applied by
    # CHECK's grouping, never by the journal: an accidental dot is still
    # the player's ink and still erasable.
    MIN_PATH = 8

    def self.bbox(stroke)
      min_x = nil
      min_y = nil
      max_x = nil
      max_y = nil
      stroke[:subpaths].each do |sub|
        sub.each do |x, y|
          if min_x.nil?
            # NOT `min_x = max_x = x`: mruby 4.0 compiles a chained
            # assignment to block-captured locals so only the LAST target
            # receives the value (the rest stay nil), which made bbox
            # return nil for every real stroke under make test.
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
      end
      min_x.nil? ? nil : [min_x, min_y, max_x, max_y]
    end

    # The BOUNDING BOX centre, deliberately, and not the centroid of the
    # points. A 7's long diagonal or a 4's tail puts many more samples at
    # one end than the other, so a centroid drifts toward wherever the pen
    # dawdled; the box centre is where the glyph LOOKS like it sits, which
    # is the cell the player aimed at.
    def self.centre(stroke)
      b = bbox(stroke)
      return nil unless b
      [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]
    end

    def self.cell_of(stroke)
      c = centre(stroke)
      return nil unless c
      cell = Layout.cell_at(c[0], c[1])
      return nil unless cell
      Sudoku::Grid.index_of(cell[0], cell[1])
    end

    # Summed segment length WITHIN each subpath. The gap between subpaths is
    # where the pen left the board and came back, so bridging it would
    # invent travel the pen never made — the same reason replay must not
    # draw across it (M3a Task 6).
    def self.path_length(stroke)
      total = 0
      stroke[:subpaths].each do |sub|
        i = 1
        while i < sub.size
          dx = sub[i][0] - sub[i - 1][0]
          dy = sub[i][1] - sub[i - 1][1]
          total += Math.sqrt(dx * dx + dy * dy).to_i
          i += 1
        end
      end
      total
    end
  end
end
