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
    assert_equal 'redoku', clients[1][:name]
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

assert('a write to a dead server raises instead of killing the process') do
  path = RM2::TestServer.start
  d = nil
  begin
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
