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
