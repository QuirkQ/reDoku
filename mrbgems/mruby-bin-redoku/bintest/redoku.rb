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

assert('redoku --watch --config PATH fails clearly on a bogus config path') do
  # No rm2fb server and no /home/root exist in the build container either,
  # but this must fail on the CONFIG, before anything ever touches a
  # display or a real device path — proving --watch's own argument handling
  # rather than falling through to some other failure.
  out, err, status = run_redoku('--watch', '--config', '/tmp/redoku-bintest-no-such-config.conf')
  assert_equal 1, status
  assert_equal '', out
  assert_include err, 'redoku:'
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
