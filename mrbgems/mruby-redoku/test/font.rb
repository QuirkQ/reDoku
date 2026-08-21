assert('Font.width advances 6 px per glyph and trims the trailing gap') do
  assert_equal 5, Redoku::Font.width('A', 1)
  assert_equal 11, Redoku::Font.width('AB', 1)
  assert_equal 34, Redoku::Font.width('NEW', 2)  # 3*(5+1)*2 - 2
  assert_equal 0, Redoku::Font.width('', 3)
end

assert('Font.draw stamps set pixels and leaves clear ones alone') do
  d = TestDisplay.new
  # 'I' is a full top row, a centre column, and a full bottom row.
  Redoku::Font.draw(d, 'I', 10, 20, 1, 0)
  assert_equal 0, d.gray_at(10, 20)      # top row, left end
  assert_equal 0, d.gray_at(14, 20)      # top row, right end
  assert_equal 0, d.gray_at(12, 23)      # middle of the stem
  assert_nil d.gray_at(10, 23)           # left of the stem: untouched
  assert_equal 0, d.gray_at(10, 26)      # bottom row
  assert_nil d.gray_at(10, 27)           # one row past the glyph
end

assert('Font.draw scales each pixel into a square block') do
  d = TestDisplay.new
  Redoku::Font.draw(d, 'I', 0, 0, 4, 0)
  # The top-left glyph pixel becomes a 4x4 block.
  assert_equal 0, d.gray_at(0, 0)
  assert_equal 0, d.gray_at(3, 3)
  assert_nil d.gray_at(0, 4)   # row 1 of 'I' is blank outside the stem
  # The glyph is 7 rows of 4 px: its last row is y 24..27, and nothing below.
  assert_equal 0, d.gray_at(0, 24)
  assert_nil d.gray_at(0, 28)
end

assert('Font.draw advances along the string and honours gray') do
  d = TestDisplay.new
  Redoku::Font.draw(d, 'II', 0, 0, 1, 128)
  assert_equal 128, d.gray_at(0, 0)
  assert_equal 128, d.gray_at(6, 0) # second glyph starts 6 px along
  assert_nil d.gray_at(5, 0)        # the 1 px gap between glyphs
end

assert('Font covers every character the UI uses') do
  'REDOKU NEWLVQIT0123456789EASYMDHRC-:.'.each_char do |ch|
    assert_true Redoku::Font::GLYPHS.key?(ch), "missing glyph #{ch}"
  end
  assert_equal 7, Redoku::Font::GLYPHS['A'].size
  Redoku::Font::GLYPHS.each do |ch, rows|
    assert_equal 7, rows.size, "#{ch} has #{rows.size} rows"
    rows.each { |r| assert_equal 5, r.size, "#{ch} row '#{r}' is not 5 wide" }
  end
end

assert('Font.draw ignores unknown characters without raising') do
  d = TestDisplay.new
  Redoku::Font.draw(d, '?', 0, 0, 1, 0)
  assert_equal [], d.rects
  assert_equal 5, Redoku::Font.width('?', 1) # still advances
end
