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
