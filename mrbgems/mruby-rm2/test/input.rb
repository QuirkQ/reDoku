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
