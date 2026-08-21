assert('RM2::Display.open performs the Init handshake and mmaps the buffer') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_equal 1404, d.width
    assert_equal 1872, d.height
    assert_false d.closed?
    d.close
    assert_true d.closed?
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Display.open raises when no server is listening') do
  assert_raise(SystemCallError) do
    RM2::Display.open('/tmp/no-such-rm2fb.sock')
  end
end

assert('RM2::Display raises on use after close') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.close
    assert_raise(RuntimeError) { d.width }
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect writes RGB565 pixels into the shared buffer') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_equal 0x0000, d.pixel(10, 20) # memfd starts zeroed (black)
    d.fill_rect(10, 20, 3, 2, 255)
    assert_equal 0xFFFF, d.pixel(10, 20) # top-left corner
    assert_equal 0xFFFF, d.pixel(12, 21) # bottom-right corner
    assert_equal 0x0000, d.pixel(13, 20) # right edge is exclusive
    assert_equal 0x0000, d.pixel(10, 22) # bottom edge is exclusive
    d.fill_rect(0, 0, 1, 1, 128)
    assert_equal 0x8410, d.pixel(0, 0)   # (128>>3)|((128>>2)<<5)|((128>>3)<<11)
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect clamps to the framebuffer bounds') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.fill_rect(1400, 1868, 100, 100, 255) # spills past both edges
    assert_equal 0xFFFF, d.pixel(1403, 1871)
    d.fill_rect(-5, -5, 10, 10, 255)       # spills past the origin
    assert_equal 0xFFFF, d.pixel(0, 0)
    assert_equal 0xFFFF, d.pixel(4, 4)
    assert_equal 0x0000, d.pixel(5, 5)
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect and pixel validate their arguments') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(ArgumentError) { d.fill_rect(0, 0, 1, 1, 256) }
    assert_raise(ArgumentError) { d.fill_rect(0, 0, 1, 1, -1) }
    assert_raise(RangeError) { d.pixel(1404, 0) }
    assert_raise(RangeError) { d.pixel(0, -1) }
  ensure
    RM2::TestServer.stop
  end
end

assert('update sends y-first inclusive corners and reads the ack') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(100, 200, 50, 25, waveform: RM2::GC16, flags: RM2::SYNC)
    log = File.open(RM2::TestServer.log_path) { |f| f.read }
    assert_equal 32, log.bytesize
    y1, x1, y2, x2, flags, waveform, temp_bits, extra = log.unpack('V8')
    assert_equal 200, y1
    assert_equal 100, x1
    assert_equal 224, y2          # 200 + 25 - 1: inclusive corner
    assert_equal 149, x2          # 100 + 50 - 1
    assert_equal RM2::SYNC, flags
    assert_equal 0xf002, waveform # GC16 | WAVEFORM_FLAG
    assert_equal 0, temp_bits     # 0.0f is all-zero bits
    assert_equal 0, extra
  ensure
    RM2::TestServer.stop
  end
end

assert('update defaults to GL16 with no flags and clamps the rect') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(1400, 0, 100, 10)
    _y1, x1, _y2, x2, flags, waveform, _temp, _extra =
      File.open(RM2::TestServer.log_path) { |f| f.read }.unpack('V8')
    assert_equal 1400, x1
    assert_equal 1403, x2         # clamped to the panel edge, inclusive
    assert_equal 0, flags
    assert_equal 0xf003, waveform # GL16 | WAVEFORM_FLAG
  ensure
    RM2::TestServer.stop
  end
end

assert('update on an empty rect is a no-op') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(2000, 2000, 50, 50) # fully off-screen
    assert_true d.update(0, 0, 0, 10)        # zero width
    log = File.open(RM2::TestServer.log_path) { |f| f.read }
    assert_equal 0, log.bytesize             # nothing hit the wire
  ensure
    RM2::TestServer.stop
  end
end

assert('draw_line draws a horizontal run of pixels') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.draw_line(10, 50, 14, 50, 1, 255)
    assert_equal 0xFFFF, d.pixel(10, 50)
    assert_equal 0xFFFF, d.pixel(12, 50)
    assert_equal 0xFFFF, d.pixel(14, 50)
    assert_equal 0x0000, d.pixel(15, 50) # endpoint is inclusive, no further
    assert_equal 0x0000, d.pixel(10, 51) # width 1 stays on one row
  ensure
    RM2::TestServer.stop
  end
end

assert('draw_line draws a diagonal and a single point') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.draw_line(100, 100, 103, 103, 1, 255)
    assert_equal 0xFFFF, d.pixel(100, 100)
    assert_equal 0xFFFF, d.pixel(101, 101)
    assert_equal 0xFFFF, d.pixel(102, 102)
    assert_equal 0xFFFF, d.pixel(103, 103)
    d.draw_line(200, 200, 200, 200, 1, 255) # degenerate: one stamp
    assert_equal 0xFFFF, d.pixel(200, 200)
    assert_equal 0x0000, d.pixel(201, 200)
  ensure
    RM2::TestServer.stop
  end
end

assert('draw_line width stamps a square brush centred on the line') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.draw_line(300, 300, 305, 300, 3, 255)
    assert_equal 0xFFFF, d.pixel(300, 299) # one row above
    assert_equal 0xFFFF, d.pixel(300, 300)
    assert_equal 0xFFFF, d.pixel(300, 301) # one row below
    assert_equal 0x0000, d.pixel(300, 302) # brush is 3 tall, not 4
    assert_equal 0xFFFF, d.pixel(299, 300) # brush extends left of the start
  ensure
    RM2::TestServer.stop
  end
end

assert('draw_line clips to the panel instead of writing out of bounds') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.draw_line(-20, 5, 20, 5, 1, 255) # starts off the left edge
    assert_equal 0xFFFF, d.pixel(0, 5)
    assert_equal 0xFFFF, d.pixel(20, 5)
    d.draw_line(1400, 1870, 1420, 1890, 5, 255) # runs off the far corner
    assert_equal 0xFFFF, d.pixel(1403, 1871)
  ensure
    RM2::TestServer.stop
  end
end

assert('draw_line validates its arguments') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(ArgumentError) { d.draw_line(0, 0, 1, 1, 0, 255) }   # width < 1
    assert_raise(ArgumentError) { d.draw_line(0, 0, 1, 1, 1, 256) }   # gray > 255
    assert_raise(ArgumentError) { d.draw_line(0, 0, 1, 1, 1, -1) }    # gray < 0
    assert_raise(ArgumentError) { d.draw_line(0, 0, 200000, 0, 1, 0) } # span too large
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect and update reject negative extents') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(ArgumentError) { d.fill_rect(10, 10, -5, 5, 0) }
    assert_raise(ArgumentError) { d.fill_rect(10, 10, 5, -5, 0) }
    assert_raise(ArgumentError) { d.update(10, 10, -5, 5) }
    assert_raise(ArgumentError) { d.update(10, 10, 5, -5) }
    assert_true d.update(10, 10, 0, 5) # zero extent stays a silent no-op
  ensure
    RM2::TestServer.stop
  end
end
