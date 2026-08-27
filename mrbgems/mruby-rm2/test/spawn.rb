# RM2.spawn_detached tests run real subprocesses inside the Docker test
# container — no fake needed, same reasoning as inotify.rb. Each test waits
# for its child's effect via a real RM2::Inotify watch rather than a sleep
# (this gem has no sleep primitive and none is worth adding just for
# tests), which also happens to dogfood the exact wait-for-a-file pattern
# Task 3 uses to notice the game spawned.

# Blocks (via a real poll, not a spin) until path's IN_CLOSE_WRITE fires or
# timeout_ms elapses. Returns true/false the way RM2::Inotify#wait does.
def wait_for_close_write(path, timeout_ms)
  iw = RM2::Inotify.init
  begin
    iw.watch(path, RM2::Inotify::IN_CLOSE_WRITE)
    ready = iw.wait(timeout_ms)
    iw.read_events
    ready
  ensure
    iw.close
  end
end

assert('RM2.spawn_detached actually runs the command') do
  dir = '/tmp/redoku-spawn-test'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  marker = "#{dir}/ran"
  File.open(marker, 'w').close # must exist before it can be watched

  pid = RM2.spawn_detached('/bin/sh', '-c', "echo hello > #{marker}")
  assert_true pid > 0
  assert_true wait_for_close_write(marker, 2000)
  assert_equal "hello\n", File.read(marker)
end

assert('RM2.spawn_detached puts the child in its own session and process group') do
  dir = '/tmp/redoku-spawn-test'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  marker = "#{dir}/sid"
  File.open(marker, 'w').close

  # A long-enough-lived child (sleep, not echo) so getsid/getpgid have
  # something to query; it is fully detached, so letting it run out on its
  # own afterward leaves nothing for this process to clean up.
  pid = RM2.spawn_detached('/bin/sh', '-c',
                            "echo up > #{marker}; sleep 1")
  assert_true wait_for_close_write(marker, 2000)

  assert_not_equal RM2::TestServer.getsid(0), RM2::TestServer.getsid(pid)
  assert_not_equal RM2::TestServer.getpgid(0), RM2::TestServer.getpgid(pid)
  # setsid() is called by the double fork's INTERMEDIATE process (never
  # exposed to Ruby — only the grandchild's pid comes back), so the
  # session/group leader is the intermediate's pid, not the returned pid's
  # own. What that leadership looks like from here: sid == pgid, the
  # signature of a session that setsid() actually created, both distinct
  # from this process's own (just asserted above).
  assert_equal RM2::TestServer.getsid(pid), RM2::TestServer.getpgid(pid)
end

assert('RM2.spawn_detached raises SystemCallError when exec fails, not a crash') do
  assert_raise(SystemCallError) do
    RM2.spawn_detached('/tmp/redoku-spawn-test/no-such-binary')
  end
end

assert('RM2.spawn_detached leaves no zombie for the caller to reap') do
  dir = '/tmp/redoku-spawn-test'
  Dir.mkdir(dir) unless Dir.exist?(dir)
  marker = "#{dir}/reap"
  File.open(marker, 'w').close

  RM2.spawn_detached('/bin/sh', '-c', "echo ok > #{marker}")
  assert_true wait_for_close_write(marker, 2000)

  # The intermediate fork step is reaped inside spawn_detached itself
  # (waitpid before it returns), and the grandchild that actually execs
  # was never this process's own child — it is reparented to init the
  # moment the intermediate exits. So this process should have nothing
  # left to reap at all.
  assert_nil RM2::TestServer.wait_any_nohang
end

assert('RM2.spawn_detached validates its arguments') do
  assert_raise(TypeError) { RM2.spawn_detached('/bin/sh', 1) }
  assert_raise(ArgumentError) { RM2.spawn_detached('/bin/sh', *(['x'] * 40)) }
end
