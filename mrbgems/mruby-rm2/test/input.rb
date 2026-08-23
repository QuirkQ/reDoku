# The pen packets a real Wacom I2C Digitizer sends, as [type, code, value]:
#   EV_ABS=3 (ABS_X=0, ABS_Y=1, ABS_PRESSURE=24), EV_KEY=1 (BTN_TOUCH=0x14a,
#   BTN_TOOL_PEN=0x140, BTN_TOOL_RUBBER=0x141), EV_SYN=0/SYN_REPORT=0.
assert('RM2::Input decodes one evdev packet into one sample at SYN_REPORT') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    w.write RM2::TestServer.pack_events([
      [1, 0x140, 1], [1, 0x14a, 1], [3, 0, 5000], [3, 1, 3000], [3, 24, 900],
      [0, 0, 0]
    ])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 1, samples.size
    assert_equal [5000, 3000, 900, RM2::Input::PEN | RM2::Input::TOUCH], samples[0]
    w.close
    i.close
    assert_true i.closed?
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input carries evdev state across packets and reports each SYN') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    # Two packets: the second moves x only, so y and pressure must persist.
    w.write RM2::TestServer.pack_events([
      [1, 0x140, 1], [1, 0x14a, 1], [3, 0, 100], [3, 1, 200], [3, 24, 10], [0, 0, 0],
      [3, 0, 150], [0, 0, 0]
    ])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 2, samples.size
    assert_equal [100, 200, 10, RM2::Input::PEN | RM2::Input::TOUCH], samples[0]
    assert_equal [150, 200, 10, RM2::Input::PEN | RM2::Input::TOUCH], samples[1]
    assert_equal [], i.pending_events # drained
    w.close
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input tracks tool and touch release in the tools bitmask') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    w.write RM2::TestServer.pack_events([
      [1, 0x141, 1], [1, 0x14a, 1], [0, 0, 0], # rubber down
      [1, 0x14a, 0], [0, 0, 0],                # tip up, rubber still hovering
      [1, 0x141, 0], [0, 0, 0]                 # tool gone
    ])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 3, samples.size
    assert_equal RM2::Input::RUBBER | RM2::Input::TOUCH, samples[0][3]
    assert_equal RM2::Input::RUBBER, samples[1][3]
    assert_equal 0, samples[2][3]
    w.close
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input holds a packet split across two writes until its SYN') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    # Half a packet: readable, but no SYN_REPORT has closed it yet.
    w.write RM2::TestServer.pack_events([[1, 0x140, 1], [3, 0, 700], [3, 1, 800]])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    assert_equal [], i.pending_events
    # The rest arrives on a later read: the sticky state lives in the input,
    # not on pending_events' stack, so nothing was lost in between.
    w.write RM2::TestServer.pack_events([[3, 24, 55], [0, 0, 0]])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 1, samples.size
    assert_equal [700, 800, 55, RM2::Input::PEN], samples[0]
    w.close
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input reads a batch larger than one read() buffer') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    # 202 events > the 64-event read buffer, so this needs several reads.
    events = [[1, 0x140, 1], [1, 0x14a, 1]]
    100.times { |n| events << [3, 0, 1000 + n] << [0, 0, 0] }
    w.write RM2::TestServer.pack_events(events)
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 100, samples.size
    assert_equal [1000, 0, 0, RM2::Input::PEN | RM2::Input::TOUCH], samples[0]
    assert_equal [1099, 0, 0, RM2::Input::PEN | RM2::Input::TOUCH], samples[99]
    assert_equal [], i.pending_events
    w.close
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input drops the packet torn by SYN_DROPPED, then resyncs') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    w = File.open(fifo, 'w')
    w.write RM2::TestServer.pack_events([
      [1, 0x140, 1], [3, 0, 10], [3, 1, 20], [3, 24, 5], [0, 0, 0], # clean
      [3, 0, 99], [0, 3, 0],   # SYN_DROPPED: this packet mixes two states
      [3, 1, 77], [0, 0, 0],   # its SYN closes the torn packet, reports nothing
      [3, 0, 111], [0, 0, 0]   # back in sync
    ])
    w.flush
    assert_true RM2::Input.wait([i], 500)
    samples = i.pending_events
    assert_equal 2, samples.size
    assert_equal [10, 20, 5, RM2::Input::PEN], samples[0]
    assert_equal [111, 77, 5, RM2::Input::PEN], samples[1]
    w.close
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input reports a hangup instead of reading as always ready') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    assert_false i.hung_up?
    w = File.open(fifo, 'w')
    w.write RM2::TestServer.pack_events([[3, 0, 42], [3, 1, 43], [0, 0, 0]])
    w.flush
    w.close # the only writer is gone: the read end hangs up

    # Events buffered before the hangup still drain.
    samples = i.pending_events
    assert_equal 1, samples.size
    assert_equal [42, 43], [samples[0][0], samples[0][1]]

    # Now empty: read() reports EOF, which is what marks the input hung up.
    assert_equal [], i.pending_events
    assert_true i.hung_up?

    # POLLHUP is set whether or not it was asked for and makes poll return a
    # positive count, so a bare `n > 0` would report this dead fd as ready
    # for ever while pending_events kept returning [].
    assert_false RM2::Input.wait([i], 20)
    assert_false i.closed? # a hangup is not closure: the fd is still ours
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input.wait marks a hangup it sees in revents') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    File.open(fifo, 'w').close # a writer opens and closes, writing nothing
    assert_false RM2::Input.wait([i], 20)
    assert_true i.hung_up?
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input.wait paces its timeout once every source has hung up') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    i = d.open_input(fifo)
    File.open(fifo, 'w').close # a writer opens and closes: hangup
    assert_false RM2::Input.wait([i], 20)
    assert_true i.hung_up?
    # POLLHUP is raised on every poll of a hung-up fd and makes poll return
    # at once, so a wait that keeps polling one spins as fast as its caller
    # can loop — 100% CPU on a battery device. With no live fd left there is
    # nothing to poll and the timeout is the only thing left to honour.
    t0 = Time.now
    5.times { assert_false RM2::Input.wait([i], 20) }
    assert_true Time.now - t0 >= 0.05, 'wait returned early: it is not pacing'
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input.wait times out when no events are pending') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    i = d.open_input(RM2::TestServer.make_fifo)
    assert_false RM2::Input.wait([i], 20)
    assert_equal [], i.pending_events
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input.wait validates its arguments') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    i = d.open_input(RM2::TestServer.make_fifo)
    assert_false RM2::Input.wait([], 0)
    assert_raise(ArgumentError) { RM2::Input.wait([i] * 9, 0) }
    # A negative timeout is poll's "block forever"; refuse it rather than
    # hang the caller's loop with no diagnostic.
    assert_raise(ArgumentError) { RM2::Input.wait([i], -1) }
    assert_raise(TypeError) { RM2::Input.wait([Object.new], 0) }
    i.close
    assert_raise(RuntimeError) { RM2::Input.wait([i], 0) }
    assert_raise(RuntimeError) { i.pending_events }
  ensure
    RM2::TestServer.stop
  end
end

assert('Display#open_input raises when the server refuses the path') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(RuntimeError) { d.open_input('/tmp/redoku-no-such-input') }
    # The connection stays usable after a refusal.
    assert_true d.update(0, 0, 4, 4)
  ensure
    RM2::TestServer.stop
  end
end

assert('Display#open_input sends the path and flags on the wire') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    fifo = RM2::TestServer.make_fifo
    d.open_input(fifo)
    req = RM2::TestServer.last_open_input
    assert_equal 68, req.bytesize
    assert_equal fifo, req[0, 64].unpack('Z64')[0]
    # Default flags: O_RDONLY (0) | O_NONBLOCK.
    assert_equal RM2::Input::NONBLOCK, req[64, 4].unpack('V')[0]
  ensure
    RM2::TestServer.stop
  end
end

assert('Display#open_input rejects a path that does not fit the wire struct') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(ArgumentError) { d.open_input('/tmp/' + ('x' * 60)) }
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Input.resolve_all returns every node with a matching name') do
  root = '/tmp/redoku-sysfs-test'
  begin
    Dir.mkdir(root) unless Dir.exist?(root)
    # event10 proves numeric (not lexicographic) ordering.
    { 'event0' => 'snvs-powerkey', 'event1' => 'Wacom I2C Digitizer',
      'event4' => 'Wacom I2C Digitizer', 'event10' => 'Wacom I2C Digitizer',
      'event2' => 'pt_mt' }.each do |node, name|
      Dir.mkdir("#{root}/#{node}") unless Dir.exist?("#{root}/#{node}")
      Dir.mkdir("#{root}/#{node}/device") unless Dir.exist?("#{root}/#{node}/device")
      File.open("#{root}/#{node}/device/name", 'w') { |f| f.write("#{name}\n") }
    end
    # A node with no readable name must be skipped, not raise.
    Dir.mkdir("#{root}/event7") unless Dir.exist?("#{root}/event7")

    assert_equal ['/dev/input/event1', '/dev/input/event4', '/dev/input/event10'],
                 RM2::Input.resolve_all('Wacom I2C Digitizer', root)
    assert_equal ['/dev/input/event2'], RM2::Input.resolve_all('pt_mt', root)
    assert_equal [], RM2::Input.resolve_all('No Such Device', root)
    assert_equal [], RM2::Input.resolve_all('pt_mt', '/tmp/redoku-no-such-sysfs')
  end
end
