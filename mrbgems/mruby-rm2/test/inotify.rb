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

assert('RM2::Inotify.init is CLOEXEC: nothing but stdio crosses the exec into a spawned child') do
  # Baseline: every fd already open in THIS process before this test adds
  # anything of its own. mrbtest runs every test file in one shared
  # process, and not every earlier file closes every socket it opens (a
  # pre-existing gap in other tests, not this one's to fix) — whatever
  # is already open here would be inherited into any child regardless of
  # what this test does, so it says nothing about whether the SHIM leaks
  # its own fds. Confirmed empirically (via a one-off diagnostic, since
  # removed) that this baseline is exactly what shows up as unexplained
  # noise otherwise: a stray leftover client socket from an earlier test
  # file, at a fixed fd number that survives unchanged across the fork.
  baseline = {}
  Dir.entries('/proc/self/fd').each do |name|
    next if name == '.' || name == '..'
    baseline[name] = true
  end

  iw = RM2::Inotify.init
  begin
    # sleep, not something that exits at once: the process must still be
    # around when we read /proc/<pid>/fd a moment later. spawn_detached
    # only returns after confirming the exec itself succeeded (it blocks
    # on the error pipe until exec's FD_CLOEXEC closes it), so there is no
    # race to wait out here — 1s is headroom against scheduling jitter
    # under the concurrent Docker load this session has, not a real need.
    pid = RM2.spawn_detached('/bin/sh', '-c', 'sleep 1')

    # Read the child's fd table from OUTSIDE it, in this process, rather
    # than asking the child to list its own /proc/self/fd (via `ls` or a
    # shell glob). Self-inspection needs an fd of its own to do the
    # asking — a directory-scan handle that is open exactly while the
    # listing is produced — so the child's own listing of itself always
    # contains one unavoidable, harmless extra entry for that scan, which
    # a correct test would then have to know how to explain away. Reading
    # /proc/<pid>/fd from here touches nothing in the CHILD's table at
    # all, so this listing is exactly, only, what the child inherited
    # across its exec.
    #
    # Every entry beyond stdio is tolerated for one of two independent
    # reasons, and flagged only when NEITHER applies:
    #  - it was already open in this process before this test started
    #    (the `baseline` above — pre-existing, not this shim's doing, and
    #    fork() preserves fd numbers exactly, so the same number in the
    #    child names the same pre-existing resource); or
    #  - what it points to is a plain filesystem PATH. On this dev
    #    machine (Docker --platform linux/amd64 emulated via Rosetta on
    #    Apple Silicon) a freshly spawned child also inherits open
    #    handles Rosetta and the loader hold on their own binaries
    #    (/usr/bin/ruby3.1, /run/rosetta/rosetta, dash's own executable)
    #    — confirmed via the diagnostic mentioned above. None of that is
    #    something this shim opens for its own bookkeeping: RM2::Inotify's
    #    fd always resolves to `anon_inode:inotify`, and spawn_detached's
    #    own pidpipe/errpipe always resolve to `pipe:[N]` — neither is a
    #    path, and neither existed before this test created it, so
    #    neither can hide behind either tolerance.
    leaked = []
    Dir.entries("/proc/#{pid}/fd").each do |name|
      next if name == '.' || name == '..' || name == '0' || name == '1' || name == '2'
      next if baseline[name]
      # The shell itself opens and closes a few fds transiently while it
      # starts up (before settling into `sleep`), so a name Dir.entries
      # just listed can already be gone by the time it is resolved —
      # ENOENT here, not a stale-but-real leak. A fd that survives to be
      # read at all, let alone for this whole process's life the way
      # spawn.c's pidpipe bug did, is the only kind this test cares about;
      # one that vanished between the listing and this line was never
      # that.
      target = begin
        File.readlink("/proc/#{pid}/fd/#{name}")
      rescue SystemCallError
        nil
      end
      next if target.nil?
      leaked.push("#{name} -> #{target}") unless target[0, 1] == '/'
    end

    # This is the invariant under test — "nothing the shim opened for its
    # own bookkeeping crosses an exec" (the fd-hygiene constraint the
    # brief calls out) — not "one specific fd, iw's, happens not to
    # collide with one we spawned." A marker check on a single fd number
    # only catches a leak when it happens to share iw's number by
    # coincidence, which is exactly how spawn.c's pidpipe leak was first
    # (accidentally) caught. This enumerates every fd the child actually
    # has and fails on any one of them that is both NEW (not in baseline)
    # and NOT a plain path, regardless of which number it lands on — the
    # leak that motivated this test, and any future one like it (a third
    # pipe, a shifted fd number, a new kind of resource such as a leaked
    # socket, which would show as `socket:[N]` and get caught the same
    # way). Do not "simplify" this back to a single-fd marker check, and
    # do not drop either tolerance for a bare count: the exact fd set on
    # this shared, emulated test process is not something this test owns.
    assert_equal [], leaked
  ensure
    iw.close
  end
end
