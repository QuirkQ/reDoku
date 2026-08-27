# Redoku::Watcher tests. The debounce, the already-running check, the spawn
# decision and the config parsing are all driven through injected fakes
# (clock/control/spawner/signals/out/err) — the App-style seam this suite
# follows (test/app.rb, test/_support.rb). Inotify itself stays REAL: a
# tmpdir file and real kernel events, exactly as mruby-rm2/test/inotify.rb
# does it. Class names below are prefixed `Watcher*` on purpose — mrbtest
# loads every gem's test files into one shared namespace, and test/app.rb
# already owns plain `FakeClock`/`FakeSignals`; reopening those classes here
# would mutate a suite this agent must not touch.

class WatcherFakeClock
  def initialize(now = 0)
    @now = now
  end

  def monotonic_ms
    @now
  end

  def advance(ms)
    @now += ms
  end
end

# reload? mirrors RM2.reload?'s consumed-on-read contract (mruby-rm2/README.md):
# a caller that never asks for a reload never gets one, and asking clears it.
class WatcherFakeSignals
  def initialize
    @terminated = false
    @reload = false
  end

  def terminated?
    @terminated
  end

  def reload?
    seen = @reload
    @reload = false
    seen
  end

  def request_reload!
    @reload = true
  end

  def terminate!
    @terminated = true
  end
end

class WatcherClientsStub
  def initialize(clients = [], raise_error: nil)
    @clients = clients
    @raise_error = raise_error
  end

  def clients
    raise @raise_error if @raise_error
    @clients
  end
end

class WatcherSpawnSpy
  attr_reader :calls

  def initialize
    @calls = []
    @next_pid = 1000
    @fail_next = false
  end

  def fail_next!
    @fail_next = true
  end

  def spawn_detached(path, *argv)
    @calls << [path, argv]
    if @fail_next
      @fail_next = false
      raise 'spawn boom'
    end
    @next_pid += 1
  end
end

class WatcherLogSpy
  attr_reader :lines

  def initialize
    @lines = []
  end

  def puts(msg)
    @lines << msg
  end

  def flush
    self
  end

  def text
    @lines.join("\n")
  end
end

WATCHER_TMP = '/tmp/redoku-watcher-test'.freeze
Dir.mkdir(WATCHER_TMP) unless Dir.exist?(WATCHER_TMP)

# Named after the pdf it watches by default, so each test's config lands at
# its own path without pulling in an RNG this file has no other use for.
def watcher_config(pdf:, metadata: nil, game: nil, path: "#{pdf}.conf")
  text = "pdf=#{pdf}\n"
  text += "metadata=#{metadata}\n" if metadata
  text += "game=#{game}\n" if game
  File.open(path, 'w') { |f| f.write(text) }
  path
end

def watcher_touch(path)
  File.open(path, 'w').close
end

def watcher_open_close(path)
  File.open(path, 'r').close
end

def watcher_write_close(path)
  f = File.open(path, 'w')
  f.write('x')
  f.close
end

# Builds a Watcher with every collaborator injected, real inotify. Callers
# get the fakes back so they can drive the clock/signals/spawner/clients and
# read the logs.
def new_watcher(config_path, clock: WatcherFakeClock.new, control: WatcherClientsStub.new,
                 spawner: WatcherSpawnSpy.new, signals: WatcherFakeSignals.new,
                 out: WatcherLogSpy.new, err: WatcherLogSpy.new)
  w = Redoku::Watcher.new(config_path, inotify: RM2::Inotify.init, clock: clock,
                                        control: control, spawner: spawner,
                                        signals: signals, out: out, err: err)
  [w, clock, control, spawner, signals, out, err]
end

# --- Config parsing ---------------------------------------------------

assert('Watcher::Config.parse reads pdf/metadata/game, skipping comments and blanks') do
  text = <<~CONF
    # a comment
    pdf=/a/decoy.pdf

    metadata=/a/decoy.metadata
    game=/a/bin/redoku
  CONF
  cfg = Redoku::Watcher::Config.parse(text)
  assert_equal '/a/decoy.pdf', cfg.pdf
  assert_equal '/a/decoy.metadata', cfg.metadata
  assert_equal '/a/bin/redoku', cfg.game
end

assert('Watcher::Config.parse ignores keys it does not know') do
  cfg = Redoku::Watcher::Config.parse("pdf=/a/decoy.pdf\nfuture_key=whatever\n")
  assert_equal '/a/decoy.pdf', cfg.pdf
end

assert('Watcher::Config.parse raises without pdf=') do
  assert_raise(Redoku::Watcher::ConfigError) do
    Redoku::Watcher::Config.parse("metadata=/a/decoy.metadata\n")
  end
  assert_raise(Redoku::Watcher::ConfigError) { Redoku::Watcher::Config.parse("pdf=\n") }
end

assert('Watcher::Config.parse leaves metadata nil and defaults game when absent') do
  cfg = Redoku::Watcher::Config.parse("pdf=/a/decoy.pdf\n")
  assert_nil cfg.metadata
  assert_equal Redoku::Watcher::Config::DEFAULT_GAME, cfg.game
end

assert('Watcher::Config.read wraps a missing file into ConfigError') do
  assert_raise(Redoku::Watcher::ConfigError) do
    Redoku::Watcher::Config.read('/tmp/redoku-watcher-test/no-such-config.conf')
  end
end

# --- start: fatal vs best-effort arming --------------------------------

assert('Watcher#start raises ConfigError when the pdf file cannot be watched') do
  path = watcher_config(pdf: "#{WATCHER_TMP}/does-not-exist.pdf")
  w, = new_watcher(path)
  begin
    assert_raise(Redoku::Watcher::ConfigError) { w.start }
  ensure
    w.close
  end
end

assert('Watcher#start succeeds with only pdf configured (metadata optional)') do
  pdf = "#{WATCHER_TMP}/only-pdf.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, = new_watcher(path)
  begin
    assert_nothing_raised { w.start }
  ensure
    w.close
  end
end

# --- triggering + debounce ----------------------------------------------

assert('a real IN_OPEN on the pdf triggers exactly one spawn') do
  pdf = "#{WATCHER_TMP}/trigger-open.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, = new_watcher(path)
  begin
    w.start
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_equal Redoku::Watcher::Config::DEFAULT_GAME, spawner.calls[0][0]
  ensure
    w.close
  end
end

assert('a real IN_CLOSE_WRITE on metadata triggers a spawn too, sharing the pdf debounce') do
  pdf = "#{WATCHER_TMP}/shared-debounce.pdf"
  metadata = "#{WATCHER_TMP}/shared-debounce.metadata"
  watcher_touch(pdf)
  watcher_touch(metadata)
  path = watcher_config(pdf: pdf, metadata: metadata)
  w, clock, _control, spawner, = new_watcher(path)
  begin
    w.start
    watcher_write_close(metadata)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    # A pdf IN_OPEN inside the same debounce window must be swallowed too —
    # proof the two trigger paths share ONE timestamp, not one each.
    watcher_open_close(pdf)
    w.tick(200)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

assert('a second trigger inside the 5s window is swallowed; the next after it fires') do
  pdf = "#{WATCHER_TMP}/debounce.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    w.start
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    clock.advance(1000) # still inside the 5000ms window
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include out.text, 'swallowed'

    clock.advance(Redoku::Watcher::DEBOUNCE_MS) # now outside it
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

# --- already-running check (R11) ----------------------------------------

assert('a client named redoku suppresses the spawn') do
  pdf = "#{WATCHER_TMP}/already-running.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  control = WatcherClientsStub.new([{ pid: 5, active: true, name: 'redoku' }])
  w, _clock, _control2, spawner, = new_watcher(path, control: control)
  begin
    w.start
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 0, spawner.calls.size
  ensure
    w.close
  end
end

assert('a raising clients check still spawns (R11), and the failure is logged') do
  pdf = "#{WATCHER_TMP}/clients-raises.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  control = WatcherClientsStub.new(raise_error: RuntimeError.new('control socket gone'))
  w, _clock, _control2, spawner, _signals, _out, err = new_watcher(path, control: control)
  begin
    w.start
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include err.text, 'clients check failed'
  ensure
    w.close
  end
end

# --- spawn failure --------------------------------------------------------

assert('a spawn failure is logged to err without killing the loop') do
  pdf = "#{WATCHER_TMP}/spawn-fails.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, _out, err = new_watcher(path)
  begin
    w.start
    spawner.fail_next!
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include err.text, 'spawn failed'

    clock.advance(Redoku::Watcher::DEBOUNCE_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

# --- re-arm after the watched file is replaced ---------------------------

assert('a deleted-and-recreated pdf file re-arms and a fresh trigger still fires') do
  pdf = "#{WATCHER_TMP}/replaced.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, _clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    w.start
    File.delete(pdf)
    watcher_touch(pdf) # replace, the way xochitl/install.sh do (not edited in place)
    w.tick(2000) # drains DELETE_SELF (+ the automatic IGNORED) and re-arms

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include out.text, 're-armed'
  ensure
    w.close
  end
end

assert('a re-arm that fails retries on a bounded interval and recovers once the file returns') do
  pdf = "#{WATCHER_TMP}/retry.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, out, err = new_watcher(path)
  begin
    w.start
    File.delete(pdf) # no recreate yet: the very next reconcile! attempt must fail
    w.tick(2000)
    assert_include err.text, 'could not be armed'

    clock.advance(1_000) # short of REARM_RETRY_MS: no second attempt yet
    err.lines.clear
    w.tick(50)
    assert_equal [], err.lines

    clock.advance(Redoku::Watcher::REARM_RETRY_MS)
    watcher_touch(pdf) # the file comes back before the retry fires
    # 50ms, not 2000: retry_pending_rearms runs before the inotify wait, so
    # the re-arm itself does not depend on the timeout, and nothing else is
    # pending on the fd yet (the watch this just added starts from now).
    w.tick(50)
    assert_include out.text, 're-armed'

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

assert('a synthetic IN_Q_OVERFLOW re-arms both roles, healing a watch gone stale with its DELETE_SELF never drained') do
  pdf = "#{WATCHER_TMP}/overflow.pdf"
  metadata = "#{WATCHER_TMP}/overflow.metadata"
  watcher_touch(pdf)
  watcher_touch(metadata)
  path = watcher_config(pdf: pdf, metadata: metadata)
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    w.start

    # Replace BOTH watched files without ever draining the DELETE_SELF (+
    # automatic IGNORED) this generates for either — standing in for what a
    # real queue overflow actually means: those events are simply never
    # seen. Both old watch descriptors are now stale, still mapped in
    # @watches but pointing at inodes that no longer exist under either
    # path — the exact "silently dead" failure requirement 5 exists to
    # prevent, reached here without the normal watch_died path ever firing.
    File.delete(pdf)
    watcher_touch(pdf)
    File.delete(metadata)
    watcher_touch(metadata)

    # A synthetic event, not a real kernel overflow: forcing a real one
    # needs thousands of events in one burst, which
    # mruby-rm2/test/inotify.rb does not attempt either. process_events is
    # a plain private method over a [wd, mask, cookie, name] array, so
    # driving it directly touches nothing about @inotify itself — it stays
    # the real fd/watches opened by #start, only the EVENT is synthetic.
    w.send(:process_events, [[-1, RM2::Inotify::IN_Q_OVERFLOW, 0, '']])
    assert_include out.text, 'inotify queue overflow'

    # The observable consequence, not just that the branch ran: a REAL
    # trigger on each of the (now current) files still fires, proving
    # reconcile! actually re-armed BOTH roles against their live inodes
    # rather than leaving either silently watching a file that is gone.
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    clock.advance(Redoku::Watcher::DEBOUNCE_MS)
    watcher_write_close(metadata)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

# --- SIGHUP ----------------------------------------------------------------

assert('SIGHUP re-reads the config and re-arms against a changed pdf path') do
  pdf_a = "#{WATCHER_TMP}/hup-a.pdf"
  pdf_b = "#{WATCHER_TMP}/hup-b.pdf"
  watcher_touch(pdf_a)
  watcher_touch(pdf_b)
  path = watcher_config(pdf: pdf_a)
  w, _clock, _control, spawner, signals, out, = new_watcher(path)
  begin
    w.start
    watcher_config(pdf: pdf_b, path: path)
    signals.request_reload!
    w.tick(50)
    assert_include out.text, 'config re-read'

    watcher_open_close(pdf_b)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    # The old path was forgotten: it must not still be able to spawn.
    watcher_open_close(pdf_a)
    w.tick(200)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

assert('a config that goes bad on re-read leaves the previous good paths armed') do
  pdf = "#{WATCHER_TMP}/hup-bad.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, _clock, _control, spawner, signals, _out, err = new_watcher(path)
  begin
    w.start
    File.open(path, 'w') { |f| f.write("# no pdf key any more\n") }
    signals.request_reload!
    w.tick(50)
    assert_include err.text, 'config reload failed'

    watcher_open_close(pdf) # the OLD watch must still be live
    w.tick(2000)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

# --- mask decoding ---------------------------------------------------------

assert('Watcher.decode_mask names every bit it knows, and falls back to hex for the rest') do
  combo = RM2::Inotify::IN_OPEN | RM2::Inotify::IN_Q_OVERFLOW
  names = Redoku::Watcher.decode_mask(combo)
  assert_include names, 'IN_OPEN'
  assert_include names, 'IN_Q_OVERFLOW'
  assert_equal ['0x0'], Redoku::Watcher.decode_mask(0)
end
