# Ink is pure geometry over the stroke hash M3a journals: no display, no
# store, no sudoku. Every helper here is called once per stroke per CHECK,
# so they allocate nothing they do not have to.

def ink_stroke(subpaths)
  { color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
    subpaths: subpaths }
end

assert('Ink.bbox spans every subpath') do
  s = ink_stroke([[[10, 20], [30, 40]], [[5, 50], [7, 9]]])
  assert_equal [5, 9, 30, 50], Redoku::Ink.bbox(s)
end

assert('Ink.bbox of a stroke with no points is nil') do
  assert_nil Redoku::Ink.bbox(ink_stroke([]))
  assert_nil Redoku::Ink.bbox(ink_stroke([[]]))
end

assert('Ink.centre is the bounding box centre, not the mean point') do
  # Nine points bunched left, one far right: the mean would sit left of
  # centre, the bbox centre does not. Which one we use decides the cell a
  # digit with a long tail lands in, so this is pinned deliberately.
  pts = [[10, 10], [10, 11], [10, 12], [10, 13], [10, 14],
         [10, 15], [10, 16], [10, 17], [10, 18], [110, 10]]
  assert_equal [60, 14], Redoku::Ink.centre(ink_stroke([pts]))
end

assert('Ink.cell_of answers the cell holding the bbox centre') do
  # Cell (1,1) is index 10: x 212..351, y 340..479.
  x, y, w, h = Redoku::Layout.cell_rect(1, 1)
  cx = x + w / 2
  cy = y + h / 2
  s = ink_stroke([[[cx - 5, cy - 5], [cx + 5, cy + 5]]])
  assert_equal 10, Redoku::Ink.cell_of(s)
end

assert('a stroke whose centre lies off the board has no cell') do
  s = ink_stroke([[[0, 0], [4, 4]]]) # above and left of BOARD_X/BOARD_Y
  assert_nil Redoku::Ink.cell_of(s)
end

assert('cell_of follows the CENTRE even when the ink crosses a cell line') do
  # PLAN.md §6 contradicts itself here: step 1 says "the cell containing its
  # bounding-box center", the pre-classification guards say "strokes fully
  # inside a cell's bounds only". The centre wins (spec §4) — a digit
  # written slightly over a line is normal handwriting, and discarding it
  # would be invisible to the player.
  x, y, w, h = Redoku::Layout.cell_rect(4, 4)
  s = ink_stroke([[[x - 20, y + h / 2], [x + w / 2 + 10, y + h / 2]]])
  assert_equal Redoku::Sudoku::Grid.index_of(4, 4), Redoku::Ink.cell_of(s)
end

assert('Ink.path_length sums every segment and ignores subpath gaps') do
  # 3-4-5 triangle twice, in two subpaths: 5 + 5, and NOT the jump between.
  s = ink_stroke([[[0, 0], [3, 4]], [[100, 100], [103, 104]]])
  assert_equal 10, Redoku::Ink.path_length(s)
end

assert('a single-point stroke has no length — the dot guard') do
  assert_equal 0, Redoku::Ink.path_length(ink_stroke([[[50, 50]]]))
end
