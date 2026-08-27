assert('RM2::Control.clients parses the client table') do
  path = RM2::TestServer.start_control
  begin
    clients = RM2::Control.clients(path)
    assert_equal 2, clients.size
    assert_equal 1232, clients[0][:pid]
    assert_true clients[0][:active]
    assert_equal 'xochitl', clients[0][:name]
    assert_equal 4711, clients[1][:pid]
    assert_false clients[1][:active]
    # Fills all 32 bytes of name[], unterminated: proves the parse walks the
    # whole buffer instead of relying on a NUL that need not be there.
    assert_equal 'unterminated-32-byte-client-name', clients[1][:name]
    assert_equal 32, clients[1][:name].bytesize
    # GetClients = type 0, pid 0, 8 bytes on the wire.
    req = RM2::TestServer.last_control_request
    assert_equal 8, req.bytesize
    assert_equal [0, 0], req.unpack('V2')
  ensure
    RM2::TestServer.stop_control
  end
end

assert('RM2::Control.switch_to sends the pid and returns the verdict') do
  path = RM2::TestServer.start_control
  begin
    assert_true RM2::Control.switch_to(1232, path)
    assert_equal [2, 1232], RM2::TestServer.last_control_request.unpack('V2')
    assert_false RM2::Control.switch_to(9999, path) # fake server refuses
  ensure
    RM2::TestServer.stop_control
  end
end

assert('RM2::Control raises when no control socket is there') do
  assert_raise(SystemCallError) { RM2::Control.clients('/tmp/redoku-no-ctl.sock') }
end

assert('RM2.setup_signals turns SIGTERM into a sticky flag') do
  RM2.setup_signals
  assert_false RM2.terminated?
  RM2::TestServer.raise_signal(15) # SIGTERM
  assert_true RM2.terminated?
  assert_true RM2.terminated? # sticky: stays set once seen
end

assert('RM2.resumed? reports each SIGCONT once') do
  RM2.setup_signals
  RM2.resumed? # clear anything left by an earlier assertion
  assert_false RM2.resumed?
  RM2::TestServer.raise_signal(18) # SIGCONT
  assert_true RM2.resumed?
  assert_false RM2.resumed? # consumed
end

assert('RM2.reload? reports each SIGHUP once, like resumed? does for SIGCONT') do
  RM2.setup_signals
  RM2.reload? # clear anything left by an earlier assertion
  assert_false RM2.reload?
  RM2::TestServer.raise_signal(1) # SIGHUP
  assert_true RM2.reload?
  assert_false RM2.reload? # consumed: a config re-read is a repeatable action,
                            # not a fact that becomes permanently true (unlike
                            # terminated?), so the next SIGHUP must be seen too
end

assert('a write to a dead server raises instead of killing the process') do
  path = RM2::TestServer.start
  d = nil
  begin
    # setup_signals is not what this assertion depends on: it passes with or
    # without the call below, because MSG_NOSIGNAL on display.c's send()
    # turns a broken pipe into EPIPE regardless of SIGPIPE's disposition.
    # Called anyway to mirror real game startup — do not read its presence
    # here as license to drop MSG_NOSIGNAL.
    RM2.setup_signals
    d = RM2::Display.open(path)
    assert_true d.update(0, 0, 10, 10)
    RM2::TestServer.stop # server gone; the next write hits a broken pipe
    assert_raise(SystemCallError) do
      20.times { d.update(0, 0, 10, 10) }
    end
  ensure
    d.close if d && !d.closed?
    RM2::TestServer.stop
  end
end
