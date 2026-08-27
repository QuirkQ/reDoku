require 'open3'
require 'timeout'

# cmd_bin comes from mruby's test/bintest.rb: it resolves the built binary
# in the target's BUILD_DIR and copes with the .exe suffix. (EMULATOR is
# handled by cmd_list, which this bintest does not use.)
REDOKU = cmd_bin('redoku')

# How long any redoku invocation here may take. Everything under test either
# prints and exits or fails to reach a socket, so well under a second is the
# norm; the limit exists for the one case that could genuinely block.
RUN_LIMIT = 15

# Runs the binary and returns [stdout, stderr, exitstatus] — never blocking
# forever. The no-argument mode opens the real display socket, and on a host
# that happens to be running an rm2fb server it would enter the game loop and
# sit there until someone tapped Quit, turning `make test` into a hang. A hang
# costs far more to diagnose than an assertion, so time it out, kill it, and
# report the timeout as a failed assertion instead.
#
# The reads are inside the limit too, deliberately: `read` blocks until every
# writer of the pipe closes it, so a surviving grandchild keeps it blocked
# long after the child itself is gone — reading outside the window is exactly
# how a guard like this ends up hanging anyway. Draining stdout before stderr
# cannot deadlock on outputs this small (a few hundred bytes, far under one
# pipe buffer), and if it ever did, the limit is what breaks it.
def run_redoku(*args)
  Open3.popen3(REDOKU, *args) do |stdin, stdout, stderr, thread|
    stdin.close
    out = err = status = nil
    begin
      Timeout.timeout(RUN_LIMIT) do
        out = stdout.read
        err = stderr.read
        status = thread.value.exitstatus
      end
    rescue Timeout::Error
      begin
        Process.kill('KILL', thread.pid)
      rescue Errno::ESRCH
        # It exited in the gap between the limit expiring and the kill.
      end
      flunk("redoku #{args.join(' ')} did not exit within #{RUN_LIMIT}s")
      # flunk records without raising, so without this the timeout falls
      # through to [nil, nil, nil] and the next assert_include crashes with
      # NoMethodError instead of reporting the timeout as a plain KO.
      return ['', '', -1]
    end
    [out, err, status]
  end
end

assert('redoku --help explains itself and exits 0') do
  out, _err, status = run_redoku('--help')
  assert_equal 0, status
  assert_include out, 'redoku'
  assert_include out, '--clients'
  assert_include out, '--watch'
end

assert('redoku --watch survives a config that is not there yet, and stops cleanly on SIGTERM') do
  # M4-HIJACK fix round 2, requirement D: the device measured `/home/root`
  # mounting AFTER systemd starts this unit (203/EXEC on every boot), so a
  # config the watcher cannot read yet must not be fatal any more — this is
  # the opposite assertion from round 1's bintest for the same CLI shape.
  # `stdout`/`stderr` are read only AFTER the process has been asked to
  # exit, so this never blocks on a pipe the way run_redoku's helper
  # explicitly avoids — reading them earlier, while the process is still
  # alive and still writing, is exactly the hang that helper's own comment
  # warns about.
  Open3.popen3(REDOKU, '--watch', '--config', '/tmp/redoku-bintest-no-such-config.conf') do |stdin, stdout, stderr, thread|
    stdin.close
    sleep 0.5 # long enough for the first config-read attempt and its log line
    assert_true thread.alive?, 'redoku --watch should not exit on a missing config'

    Process.kill('TERM', thread.pid)
    status = nil
    begin
      Timeout.timeout(RUN_LIMIT) { status = thread.value.exitstatus }
    rescue Timeout::Error
      begin
        Process.kill('KILL', thread.pid)
      rescue Errno::ESRCH
        nil
      end
      flunk("redoku --watch did not exit within #{RUN_LIMIT}s of SIGTERM")
      next
    end
    assert_equal 0, status
    assert_include stderr.read, 'config unreadable'
  end
end

assert('redoku fails clearly when no display server is listening') do
  # No rm2fb server exists in the build container, so the default socket
  # path is absent and this exercises the real failure path.
  _out, err, status = run_redoku
  assert_equal 1, status
  assert_include err, 'redoku:'
end

assert('redoku rejects an unknown option instead of guessing') do
  # 2, not 1: Redoku.main separates a usage error from a runtime failure.
  _out, err, status = run_redoku('--nonsense')
  assert_equal 2, status
  assert_include err, '--nonsense'
end
