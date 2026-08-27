# Redoku::Watcher tests. The launch policy — the startup grace, the
# lastOpened comparison, the fallback debounce, the already-running check
# and its cooldown, the config parsing and its retry — is all driven
# through injected fakes (clock/control/spawner/signals/out/err) — the
# App-style seam this suite follows (test/app.rb, test/_support.rb).
# Inotify itself stays REAL: a tmpdir file and real kernel events, exactly
# as mruby-rm2/test/inotify.rb does it. Class names below are prefixed
# `Watcher*` on purpose — mrbtest loads every gem's test files into one
# shared namespace, and test/app.rb already owns plain
# `FakeClock`/`FakeSignals`; reopening those classes here would mutate a
# suite this agent must not touch.

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

  # Lets a test flip presence mid-scenario (a spawn "becoming" a running
  # client, then "quitting") without rebuilding the whole Watcher.
  def set_clients(clients)
    @clients = clients
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
def watcher_config(pdf:, metadata: nil, game: nil, trigger: nil, path: "#{pdf}.conf")
  text = "pdf=#{pdf}\n"
  text += "metadata=#{metadata}\n" if metadata
  text += "game=#{game}\n" if game
  text += "trigger=#{trigger}\n" if trigger
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

# A minimal but real-shaped xochitl .metadata sidecar — only the one field
# Watcher#extract_last_opened ever reads, but in the same quoted-string
# shape the device dump (xochitl-3.27-format.md) shows.
def watcher_write_metadata(path, last_opened)
  File.open(path, 'w') { |f| f.write("{\n    \"lastOpened\": \"#{last_opened}\"\n}\n") }
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

# Starts a watcher and immediately clears the mandatory startup grace
# (M4-HIJACK fix round 2, requirement C), so a test that isn't ABOUT the
# grace itself doesn't have to know its value. Tests about the grace, or
# about a config/pdf that isn't there yet at start, call w.start directly —
# @started_at_ms is stamped once, at that first call, and every clock
# advance afterward is relative to it either way.
def start_past_grace(w, clock)
  w.start
  clock.advance(Redoku::Watcher::STARTUP_GRACE_MS)
  w
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
  assert_equal Redoku::Watcher::Config::DEFAULT_TRIGGER, cfg.trigger
end

assert('Watcher::Config.parse reads trigger=lastopened and trigger=open explicitly') do
  cfg = Redoku::Watcher::Config.parse("pdf=/a/decoy.pdf\ntrigger=lastopened\n")
  assert_equal :lastopened, cfg.trigger

  cfg = Redoku::Watcher::Config.parse("pdf=/a/decoy.pdf\ntrigger=open\n")
  assert_equal :open, cfg.trigger
end

assert('Watcher::Config.parse rejects a trigger= value that is neither lastopened nor open') do
  assert_raise(Redoku::Watcher::ConfigError) do
    Redoku::Watcher::Config.parse("pdf=/a/decoy.pdf\ntrigger=sometimes\n")
  end
end

assert('Watcher::Config.read wraps a missing file into ConfigError') do
  assert_raise(Redoku::Watcher::ConfigError) do
    Redoku::Watcher::Config.read('/tmp/redoku-watcher-test/no-such-config.conf')
  end
end

# --- start: never fatal, always retried (requirement D) ------------------

assert('Watcher#start does not raise when the pdf file cannot be watched yet, and retries it') do
  pdf = "#{WATCHER_TMP}/not-yet.pdf"
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, out, err = new_watcher(path)
  begin
    assert_nothing_raised { w.start }
    assert_include err.text, 'could not be armed'

    # The device fact fix round 2 quotes, confirmed rather than assumed:
    # the watcher ran for 91s with its pdf= target not yet existing.
    # Create it, clear the re-arm retry interval, and it picks itself up.
    watcher_touch(pdf)
    clock.advance(Redoku::Watcher::REARM_RETRY_MS)
    w.tick(50)
    assert_include out.text, 're-armed'

    clock.advance(Redoku::Watcher::STARTUP_GRACE_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
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

assert('a missing config file at startup does not raise, and Watcher#tick keeps retrying it') do
  path = "#{WATCHER_TMP}/never-written-yet.conf"
  w, clock, _control, spawner, _signals, out, err = new_watcher(path)
  begin
    assert_nothing_raised { w.start }
    assert_include err.text, 'config unreadable'

    # /home/root mounting after systemd starts this unit (203/EXEC on
    # every boot) is exactly this: the config is not there yet, then it is.
    pdf = "#{WATCHER_TMP}/recovered-after-config.pdf"
    watcher_touch(pdf)
    watcher_config(pdf: pdf, path: path)

    clock.advance(Redoku::Watcher::REARM_RETRY_MS)
    w.tick(50)
    assert_include out.text, 'config read'

    clock.advance(Redoku::Watcher::STARTUP_GRACE_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

# --- triggering: the raw-event fallback (no metadata configured) ---------

assert('a real IN_OPEN on the pdf triggers exactly one spawn (fallback path)') do
  pdf = "#{WATCHER_TMP}/trigger-open.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, = new_watcher(path)
  begin
    start_past_grace(w, clock)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_equal Redoku::Watcher::Config::DEFAULT_GAME, spawner.calls[0][0]
  ensure
    w.close
  end
end

assert('a second trigger inside the 5s fallback window is swallowed; the next after it fires') do
  pdf = "#{WATCHER_TMP}/debounce.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    clock.advance(1000) # still inside the 5000ms window
    watcher_open_close(pdf)
    w.tick(2000) # note_redoku_presence also runs here, first noticing redoku "gone"
    assert_equal 1, spawner.calls.size
    assert_include out.text, 'swallowed'

    # COOLDOWN_MS, not DEBOUNCE_MS: the second spawn also has to clear
    # requirement B's cooldown, counted from the tick just above where it
    # was first observed gone, not from this trigger's own clock reading.
    clock.advance(Redoku::Watcher::COOLDOWN_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

# --- triggering: lastOpened, the primary path (requirement A) ------------

assert('Watcher.extract_last_opened reads the field from a real-shaped dump, and nil when absent') do
  dump = "{\n    \"createdTime\": \"1780567685687\",\n" \
         "    \"lastOpened\": \"1780568050637\",\n    \"lastOpenedPage\": 0\n}\n"
  assert_equal 1_780_568_050_637, Redoku::Watcher.extract_last_opened(dump)
  assert_nil Redoku::Watcher.extract_last_opened("{\n    \"createdTime\": \"1\"\n}\n")
  assert_nil Redoku::Watcher.extract_last_opened('not json at all')
end

assert('lastOpened unchanged does not spawn, even on a real IN_OPEN') do
  pdf = "#{WATCHER_TMP}/lo-unchanged.pdf"
  metadata = "#{WATCHER_TMP}/lo-unchanged.metadata"
  watcher_touch(pdf)
  watcher_write_metadata(metadata, 1000)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock) # seeds the baseline at 1000 during #start

    watcher_open_close(pdf) # a real event, but lastOpened has not moved
    w.tick(2000)
    assert_equal 0, spawner.calls.size
    assert_include out.text, 'lastOpened unchanged'
  ensure
    w.close
  end
end

assert('lastOpened increased spawns exactly once, and the same value again does not') do
  pdf = "#{WATCHER_TMP}/lo-increased.pdf"
  metadata = "#{WATCHER_TMP}/lo-increased.metadata"
  watcher_touch(pdf)
  watcher_write_metadata(metadata, 1000)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)

    watcher_write_metadata(metadata, 2000) # the real tap: xochitl bumps it
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include out.text, 'lastOpened increased to 2000'

    watcher_write_close(metadata) # a hint, but the value is unchanged
    w.tick(200)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

assert('either armed path is just a hint: pdf IN_OPEN and metadata IN_CLOSE_WRITE both reach the same lastOpened check') do
  pdf = "#{WATCHER_TMP}/lo-either.pdf"
  metadata = "#{WATCHER_TMP}/lo-either.metadata"
  watcher_touch(pdf)
  watcher_write_metadata(metadata, 0)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, = new_watcher(path)
  begin
    start_past_grace(w, clock)

    watcher_write_metadata(metadata, 1000)
    watcher_write_close(metadata) # the metadata role's own trigger, IN_CLOSE_WRITE
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    # An ordinary idle tick, nothing pending on the fd: lets
    # note_redoku_presence notice redoku is gone off the real clock, the
    # same way it would once a second in production (#run's own loop),
    # rather than only when the next trigger happens to ask.
    w.tick(50)
    clock.advance(Redoku::Watcher::COOLDOWN_MS)

    watcher_write_metadata(metadata, 2000)
    watcher_open_close(pdf) # the pdf role's own trigger, IN_OPEN
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

assert('metadata unreadable falls back to the raw trigger, and says so') do
  pdf = "#{WATCHER_TMP}/lo-unreadable.pdf"
  metadata = "#{WATCHER_TMP}/lo-unreadable-missing.metadata" # never created
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, _signals, _out, err = new_watcher(path)
  begin
    start_past_grace(w, clock)

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include err.text, 'metadata unreadable'
    assert_include err.text, 'falling back'
  ensure
    w.close
  end
end

# --- triggering: trigger=open (fix round 3) -------------------------------

assert('trigger=open spawns on a raw IN_OPEN alone, with no metadata configured at all') do
  pdf = "#{WATCHER_TMP}/mode-open.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf, trigger: 'open')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)
    assert_include out.text, 'trigger=open'

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
  ensure
    w.close
  end
end

assert('trigger=open still respects the fallback debounce, not a raw event every time') do
  pdf = "#{WATCHER_TMP}/mode-open-debounce.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf, trigger: 'open')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    watcher_open_close(pdf) # no clock advance: still inside DEBOUNCE_MS
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include out.text, 'swallowed'
  ensure
    w.close
  end
end

assert('trigger=open: a redraw IN_OPEN while redoku is present is suppressed, independent of the debounce') do
  # The device capture (fix round 3's second measurement): xochitl redraws
  # as it is demoted, ~1-2s after the spawn, firing IN_OPEN on the decoy
  # again. Because trigger=open carries a launch decision on the raw event
  # alone, this is the one place open mode differs materially from what
  # round 2's tests already covered — it needs its own proof that
  # suppression (not merely the debounce, which the previous test already
  # covers) is what holds the line.
  pdf = "#{WATCHER_TMP}/mode-open-redraw.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf, trigger: 'open')
  control = WatcherClientsStub.new([])
  w, clock, control2, spawner, _signals, out, = new_watcher(path, control: control)
  begin
    start_past_grace(w, clock)

    watcher_open_close(pdf) # the tap itself
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    # redoku is now "running"; advance PAST DEBOUNCE_MS so only
    # suppression, not the debounce, can be what blocks the redraw below.
    control2.set_clients([{ pid: 99, active: true, name: 'redoku' }])
    clock.advance(Redoku::Watcher::DEBOUNCE_MS + 100)
    watcher_open_close(pdf) # xochitl's own redraw as it is demoted
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include out.text, 'already a client'
  ensure
    w.close
  end
end

# --- already-running (R11) + cooldown (requirement B) ---------------------

assert('a client named redoku suppresses the spawn') do
  pdf = "#{WATCHER_TMP}/already-running.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  control = WatcherClientsStub.new([{ pid: 5, active: true, name: 'redoku' }])
  w, clock, _control2, spawner, = new_watcher(path, control: control)
  begin
    start_past_grace(w, clock)
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
  w, clock, _control2, spawner, _signals, _out, err = new_watcher(path, control: control)
  begin
    start_past_grace(w, clock)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size
    assert_include err.text, 'clients check failed'
  ensure
    w.close
  end
end

assert('a spawn followed by a present redoku client suppresses a further trigger') do
  pdf = "#{WATCHER_TMP}/present-after-spawn.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  control = WatcherClientsStub.new([])
  w, clock, control2, spawner, _signals, out, = new_watcher(path, control: control)
  begin
    start_past_grace(w, clock)

    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size # the game is now "running"

    control2.set_clients([{ pid: 99, active: true, name: 'redoku' }])
    clock.advance(Redoku::Watcher::DEBOUNCE_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size # still 1: redoku is present now
    assert_include out.text, 'already a client'
  ensure
    w.close
  end
end

assert('redoku gone but inside the cooldown swallows a further trigger; past it, the trigger fires') do
  pdf = "#{WATCHER_TMP}/cooldown.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  control = WatcherClientsStub.new([]) # redoku never shows as a client in this test
  w, clock, _control2, spawner, _signals, out, = new_watcher(path, control: control)
  begin
    start_past_grace(w, clock)

    watcher_open_close(pdf) # the first-ever trigger: nothing to cool down from yet
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    clock.advance(Redoku::Watcher::DEBOUNCE_MS) # clears the fallback debounce, not the cooldown
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size # inside the 10s cooldown since "gone" was first noticed
    assert_include out.text, 'cooldown'

    clock.advance(Redoku::Watcher::COOLDOWN_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
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
    start_past_grace(w, clock)
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

assert('a deleted-and-recreated pdf file re-arms, and the re-arm itself is evaluated as a hint') do
  pdf = "#{WATCHER_TMP}/replaced.pdf"
  watcher_touch(pdf)
  path = watcher_config(pdf: pdf)
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)
    File.delete(pdf)
    watcher_touch(pdf) # replace, the way xochitl/install.sh do (not edited in place)
    w.tick(2000) # drains DELETE_SELF (+ IGNORED), re-arms, and evaluates the re-arm itself
    assert_include out.text, 're-armed'
    assert_include out.text, 'evaluating the launch decision'
    # Fix round 3: the re-arm IS a launch decision now, not merely bookkeeping —
    # no metadata is configured here, so it reaches the fallback path and,
    # first-ever trigger of this Watcher's life, is not swallowed.
    assert_equal 1, spawner.calls.size

    # A genuinely independent trigger afterward, once the debounce and the
    # cooldown both clear, still works — the watch is not merely alive, it
    # is USABLE. The idle tick lets note_redoku_presence notice "gone" off
    # the clock before the cooldown window below is measured from it (the
    # same fix M4-HIJACK fix round 2 needed for the same reason).
    w.tick(50)
    clock.advance(Redoku::Watcher::COOLDOWN_MS)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 2, spawner.calls.size
  ensure
    w.close
  end
end

assert('a metadata file replaced by RENAME (not edited in place) still carries its bumped lastOpened through') do
  pdf = "#{WATCHER_TMP}/rename-metadata.pdf"
  metadata = "#{WATCHER_TMP}/rename-metadata.metadata"
  watcher_touch(pdf)
  watcher_write_metadata(metadata, 0)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock) # seeds the baseline at 0

    # xochitl's own crash-safe pattern (and install.sh's): write a NEW file
    # under a temp name, then rename it over the watched path. This
    # unlinks the watched inode exactly like an explicit delete does
    # (IN_DELETE_SELF + the automatic IN_IGNORED) — never an in-place
    # edit, so IN_CLOSE_WRITE on the OLD inode never fires at all. Before
    # fix round 3 this bump would have reached the watcher as nothing but
    # a routine "metadata watch re-armed" line.
    tmp = "#{metadata}.tmp"
    watcher_write_metadata(tmp, 1000)
    File.rename(tmp, metadata)

    w.tick(2000) # drains DELETE_SELF/IGNORED, re-arms, and must evaluate the carried bump
    assert_include out.text, 're-armed'
    assert_include out.text, 'evaluating the launch decision'
    assert_include out.text, 'lastOpened increased to 1000'
    assert_equal 1, spawner.calls.size
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
    start_past_grace(w, clock)
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
    start_past_grace(w, clock)

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
    # trigger on each of the (now current) files still fires (via the
    # fallback path — metadata here is touched empty, not seeded), proving
    # reconcile! actually re-armed BOTH roles against their live inodes
    # rather than leaving either silently watching a file that is gone.
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 1, spawner.calls.size

    # An ordinary idle tick, nothing pending: lets note_redoku_presence
    # notice redoku is gone off the real clock before the cooldown window
    # below starts counting, the same as production's own once-a-second
    # loop would.
    w.tick(50)
    clock.advance(Redoku::Watcher::COOLDOWN_MS)
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
  w, clock, _control, spawner, signals, out, = new_watcher(path)
  begin
    start_past_grace(w, clock)
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
  w, clock, _control, spawner, signals, _out, err = new_watcher(path)
  begin
    start_past_grace(w, clock)
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

# --- startup grace (requirement C) ----------------------------------------

assert('a trigger inside the startup grace does not spawn; the same lastOpened value fires once the grace ends') do
  pdf = "#{WATCHER_TMP}/grace.pdf"
  metadata = "#{WATCHER_TMP}/grace.metadata"
  watcher_touch(pdf)
  watcher_write_metadata(metadata, 0)
  path = watcher_config(pdf: pdf, metadata: metadata, trigger: 'lastopened')
  w, clock, _control, spawner, _signals, out, = new_watcher(path)
  begin
    w.start # clock stays at 0; the grace runs to STARTUP_GRACE_MS from here

    # A genuinely-would-be trigger — lastOpened DID move — arriving while
    # still inside the grace: swallowed before genuine_open? even runs, so
    # the baseline stays at its seeded value.
    watcher_write_metadata(metadata, 1000)
    watcher_open_close(pdf)
    w.tick(2000)
    assert_equal 0, spawner.calls.size
    assert_include out.text, 'startup grace'

    clock.advance(Redoku::Watcher::STARTUP_GRACE_MS)
    watcher_open_close(pdf) # the SAME already-bumped value, evaluated for the first time now
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
