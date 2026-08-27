# RM2::Inotify tests run against the real kernel inotify facility inside the
# Docker test container (Linux either way) — no fake server needed, unlike
# display.c's wire protocol. Every mask value asserted below is the fixed
# Linux kernel-userspace ABI value from <sys/inotify.h>, stable across
# kernel versions, so asserting the literal number (not just "truthy") is
# what actually catches a wrong constant wired to the wrong name.

assert('RM2::Inotify exposes the mask constants the watcher needs') do
  assert_equal 0x00000020, RM2::Inotify::IN_OPEN
  assert_equal 0x00000008, RM2::Inotify::IN_CLOSE_WRITE
  assert_equal 0x00000002, RM2::Inotify::IN_MODIFY
  assert_equal 0x00004000, RM2::Inotify::IN_Q_OVERFLOW
  assert_equal 0x00008000, RM2::Inotify::IN_IGNORED
  assert_equal 0x00000400, RM2::Inotify::IN_DELETE_SELF
  assert_equal 0x00000800, RM2::Inotify::IN_MOVE_SELF
end

assert('RM2::Inotify.init starts open; #close makes it closed') do
  iw = RM2::Inotify.init
  assert_false iw.closed?
  iw.close
  assert_true iw.closed?
  iw.close # idempotent, like RM2::Input#close
end

assert('RM2::Inotify#watch and #read_events decode open/modify/close on a real file') do
  dir = '/tmp/redoku-inotify-test'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  path = "#{dir}/decoy.pdf"
  File.open(path, 'w').close # must exist before it can be watched

  iw = RM2::Inotify.init
  begin
    mask = RM2::Inotify::IN_OPEN | RM2::Inotify::IN_MODIFY |
           RM2::Inotify::IN_CLOSE_WRITE
    wd = iw.watch(path, mask)
    assert_true wd >= 0

    f = File.open(path, 'w')
    f.write('hi')
    f.close

    assert_true iw.wait(2000)
    events = iw.read_events
    assert_true events.size >= 1

    combined = 0
    events.each do |e|
      assert_equal 4, e.size
      assert_equal wd, e[0]      # every event here is on the one watch
      assert_equal 0, e[2]       # cookie only matters for MOVED_FROM/TO pairs
      assert_equal '', e[3]      # watching a file directly: no name component
      combined |= e[1]
    end
    assert_equal RM2::Inotify::IN_OPEN, combined & RM2::Inotify::IN_OPEN
    assert_equal RM2::Inotify::IN_MODIFY, combined & RM2::Inotify::IN_MODIFY
    assert_equal RM2::Inotify::IN_CLOSE_WRITE, combined & RM2::Inotify::IN_CLOSE_WRITE
  ensure
    iw.close
  end
end

assert('RM2::Inotify#read_events returns empty, not an error, when nothing happened yet') do
  dir = '/tmp/redoku-inotify-test'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  path = "#{dir}/quiet.pdf"
  File.open(path, 'w').close

  iw = RM2::Inotify.init
  begin
    iw.watch(path, RM2::Inotify::IN_OPEN)
    assert_equal [], iw.read_events
    assert_false iw.wait(20) # a real poll timeout, not a raise
  ensure
    iw.close
  end
end

assert('RM2::Inotify reports the child name when watching a directory') do
  dir = '/tmp/redoku-inotify-test-dir'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  child = "#{dir}/child.pdf"
  File.delete(child) if File.exist?(child)

  iw = RM2::Inotify.init
  begin
    iw.watch(dir, RM2::Inotify::IN_OPEN | RM2::Inotify::IN_CLOSE_WRITE)
    File.open(child, 'w').close # create + open(w) + close on the child

    assert_true iw.wait(2000)
    events = iw.read_events
    assert_true events.size >= 1
    events.each { |e| assert_equal 'child.pdf', e[3] }
  ensure
    iw.close
  end
end

assert('RM2::Inotify reports DELETE_SELF and the automatic IGNORED that follows it') do
  dir = '/tmp/redoku-inotify-test'
  path = "#{dir}/deleteme.pdf"
  Dir.mkdir(dir) unless Dir.exist?(dir)
  File.open(path, 'w').close

  iw = RM2::Inotify.init
  begin
    iw.watch(path, RM2::Inotify::IN_DELETE_SELF)
    File.delete(path)

    assert_true iw.wait(2000)
    combined = 0
    iw.read_events.each { |e| combined |= e[1] }
    assert_equal RM2::Inotify::IN_DELETE_SELF, combined & RM2::Inotify::IN_DELETE_SELF
    # A removed watch target auto-generates IGNORED: the watcher's loop must
    # treat it as "stop expecting this wd", not as a wire-format error.
    assert_equal RM2::Inotify::IN_IGNORED, combined & RM2::Inotify::IN_IGNORED
  ensure
    iw.close
  end
end

assert('RM2::Inotify#watch raises when the path does not exist') do
  iw = RM2::Inotify.init
  begin
    assert_raise(SystemCallError) do
      iw.watch('/tmp/redoku-no-such-inotify-target', RM2::Inotify::IN_OPEN)
    end
  ensure
    iw.close
  end
end

assert('RM2::Inotify#watch and #read_events raise on a closed instance') do
  iw = RM2::Inotify.init
  iw.close
  assert_raise(RuntimeError) { iw.watch('/tmp', RM2::Inotify::IN_OPEN) }
  assert_raise(RuntimeError) { iw.read_events }
  assert_raise(RuntimeError) { iw.wait(0) }
end

assert('RM2::Inotify#wait validates its timeout') do
  iw = RM2::Inotify.init
  begin
    assert_raise(ArgumentError) { iw.wait(-1) }
  ensure
    iw.close
  end
end

assert('RM2::Inotify.init is CLOEXEC: a spawned child does not inherit its fd') do
  dir = '/tmp/redoku-inotify-test-cloexec'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  out = "#{dir}/fds"
  File.open(out, 'w').close

  iw = RM2::Inotify.init
  observer = RM2::Inotify.init
  begin
    observer.watch(out, RM2::Inotify::IN_CLOSE_WRITE)
    # `ls -la` (not a bare listing) so each line shows what the fd points
    # to: checking a fd NUMBER alone would be a false-positive trap, since
    # fd numbers are just reused small integers and the child's own
    # unrelated fds (its redirect target, ls's own directory read) could
    # coincidentally land on the same number iw happens to hold in this
    # process. Only a line naming iw's number AND "inotify" proves
    # inheritance.
    RM2.spawn_detached('/bin/sh', '-c', "ls -la /proc/self/fd > #{out}")
    assert_true observer.wait(2000)
    observer.read_events

    marker = " #{iw.fd} -> "
    inherited = false
    File.read(out).split("\n").each do |line|
      next if line.index(marker).nil?
      inherited = true unless line.index('inotify').nil?
    end
    assert_false inherited
  ensure
    iw.close
    observer.close
  end
end
