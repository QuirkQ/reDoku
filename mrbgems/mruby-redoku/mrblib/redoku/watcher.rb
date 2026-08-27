module Redoku
  # `redoku --watch` — the hijack's other half (M4-HIJACK.md, PLAN.md §10).
  # A systemd service holding an inotify watch and the control socket and
  # NOTHING ELSE: it never calls RM2::Display.open, which is what keeps it
  # structurally incapable of stealing the screen. RM2::Control.clients is
  # fine here because it rides the separate control-socket datagram RPC, not
  # the display connection (PLAN.md §3).
  #
  # Two triggers are armed at once and share one 5 s debounce (M4-HIJACK.md
  # ruling): IN_OPEN on the decoy's own PDF (primary) and IN_CLOSE_WRITE on
  # its .metadata sidecar (fallback: xochitl writes `lastOpened` there on
  # every open) — which one xochitl actually fires is an on-device fact this
  # code cannot know. Every trigger is logged with its mask decoded into
  # constant names and the path it fired on: on a device with no
  # `inotifyd`, this log is the only instrument that will ever tell Task 5
  # which trigger is real.
  #
  # `clock:`/`control:`/`spawner:`/`signals:` are the App-style seam: real
  # RM2 modules by default, fakes in tests, so the debounce, the
  # already-running check and the spawn decision are host-testable without a
  # display server or a real game process. `inotify:` is the one seam kept
  # REAL (a real tmpdir file, real kernel events), as mruby-rm2/test/inotify.rb
  # does it — there is no protocol here worth faking, only a filesystem.
  class Watcher
    # Raised for a config this watcher cannot trust to arm from. `Redoku.watch`
    # (main.rb) treats it as fatal on the FIRST read (print, exit non-zero —
    # R5/R10: a decoy nobody can watch is a launcher nobody can use). A
    # SIGHUP re-read treats the same error as "log it, keep the previous good
    # paths armed" (#reread_config_if_requested) — a bad edit must not
    # silently disarm the launcher.
    class ConfigError < StandardError; end

    # watch.conf's shape is fixed by ruling: key=value lines, '#' comments
    # and blank lines allowed, exactly the keys pdf=/metadata=/game=.
    # tools/mkdecoy.rb (MkDecoy.watch_conf_for) is the one writer of a real
    # one; this is the one reader. DEFAULT_GAME mirrors
    # MkDecoy::DEVICE_GAME_BIN by value — the two tools can't share code
    # (one host CRuby, one mruby), so it's duplicated on purpose.
    class Config
      DEFAULT_GAME = '/home/root/redoku/bin/redoku'.freeze

      attr_reader :pdf, :metadata, :game

      def initialize(pdf:, metadata:, game:)
        @pdf = pdf
        @metadata = metadata
        @game = game
      end

      # A missing/blank pdf= is the "missing" half of R5/R10's "pdf missing
      # or unreadable is fatal"; the "unreadable" half is a filesystem fact
      # caught later, where the path is actually armed (fatal: true below).
      def self.parse(text)
        values = {}
        text.split("\n").each do |raw|
          line = raw.strip
          next if line.empty? || line.start_with?('#')
          key, value = line.split('=', 2)
          next if key.nil? || value.nil?
          key = key.strip
          next if key.empty?
          values[key] = value.strip # unknown keys: accepted, ignored, forward-compatible
        end

        pdf = values['pdf']
        raise ConfigError, 'pdf= is required' if pdf.nil? || pdf.empty?

        metadata = values['metadata']
        metadata = nil if metadata && metadata.empty?

        game = values['game']
        game = DEFAULT_GAME if game.nil? || game.empty?

        new(pdf: pdf, metadata: metadata, game: game)
      end

      def self.read(path)
        parse(File.read(path))
      rescue ConfigError => e
        # Re-raised through a captured variable, not a bare `raise`: mruby's
        # method-level `rescue` (no explicit begin) does not reliably leave
        # $! set the way a begin/rescue block does, and a bare `raise` there
        # was observed to surface as a bare RuntimeError instead of this
        # ConfigError — losing the exact message every caller depends on.
        raise e
      rescue StandardError => e
        # File.read raises a SystemCallError subclass on a missing/unreadable
        # file; folded into ConfigError so callers see one exception type.
        raise ConfigError, "cannot read config #{path} (#{e.message})"
      end
    end

    # R5/R10: `redoku --watch` with no `--config PATH` reads this. Kept as a
    # literal in main.rb's USAGE text too (see that file's header comment)
    # rather than interpolated, for a load-order reason specific to that
    # constant's own eager evaluation — not a reason to duplicate it anywhere
    # a method body (evaluated lazily) can just reference this one.
    DEFAULT_CONFIG_PATH = '/home/root/redoku/watch.conf'.freeze

    # PLAN.md §11's "watcher re-trigger loop" rule, shared across BOTH
    # trigger paths (ruling): a pdf IN_OPEN and a metadata IN_CLOSE_WRITE for
    # the same tap must not add up to two spawns.
    DEBOUNCE_MS = 5_000

    # Bounds the inotify wait so SIGTERM/SIGINT/SIGHUP latches are checked at
    # least once a second (ruling: "the poll must be bounded"), and doubles
    # as the pace a pending re-arm retry is checked at.
    POLL_MS = 1_000

    # How often a failed re-arm (the watched file briefly absent, mid a
    # xochitl/installer replace) is retried, rather than every POLL_MS turn —
    # that would turn a multi-second install window into a log flood.
    REARM_RETRY_MS = 5_000

    # IN_DELETE_SELF/IN_MOVE_SELF are requested explicitly per watch
    # (armed_mask) because — unlike IN_IGNORED, always delivered when a watch
    # dies for any reason — they only arrive if asked for. Without them, a
    # replace (delete+recreate, or rename a fresh file over the old one —
    # both unlink the watched inode) would kill this watcher with no event to
    # notice by.
    WATCH_DIED_MASK = RM2::Inotify::IN_IGNORED | RM2::Inotify::IN_DELETE_SELF |
                       RM2::Inotify::IN_MOVE_SELF

    # Every mask bit this watcher decodes, in the shim's own order
    # (mruby-rm2/README.md). The measuring-instrument requirement: every
    # trigger is logged with its mask decoded into NAMES, never a bare hex
    # number — this log is the only place Task 5 can read back which trigger
    # actually fired on-device.
    MASK_NAMES = [
      [RM2::Inotify::IN_OPEN, 'IN_OPEN'],
      [RM2::Inotify::IN_CLOSE_WRITE, 'IN_CLOSE_WRITE'],
      [RM2::Inotify::IN_MODIFY, 'IN_MODIFY'],
      [RM2::Inotify::IN_Q_OVERFLOW, 'IN_Q_OVERFLOW'],
      [RM2::Inotify::IN_IGNORED, 'IN_IGNORED'],
      [RM2::Inotify::IN_DELETE_SELF, 'IN_DELETE_SELF'],
      [RM2::Inotify::IN_MOVE_SELF, 'IN_MOVE_SELF'],
    ].freeze

    def self.decode_mask(mask)
      names = []
      MASK_NAMES.each { |bit, name| names << name if (mask & bit) != 0 }
      names << format('0x%x', mask) if names.empty?
      names
    end

    # `inotify:` defaults to a fresh fd; tests pass one they made and close
    # themselves, so #close below never touches an fd a test still wants
    # open. `out:`/`err:` are $stdout/$stderr in production (systemd
    # captures both into journald) and a plain recorder in tests.
    def initialize(config_path, inotify: RM2::Inotify.init, clock: RM2,
                   control: RM2::Control, spawner: RM2, signals: RM2,
                   out: $stdout, err: $stderr)
      @config_path = config_path
      @inotify = inotify
      @clock = clock
      @control = control
      @spawner = spawner
      @signals = signals
      @out = out
      @err = err

      @config = nil
      @watches = {}   # wd => :pdf or :metadata, for events read back later
      @wd_for = {}    # :pdf/:metadata => its current wd, or nil if unarmed
      @rearm_failing = {}  # role => true while its re-arm retry is failing
      @rearm_retry_at = {} # role => monotonic ms of its next retry attempt
      @last_trigger_ms = nil
    end

    # Loads the config and arms both triggers. pdf is fatal on failure
    # (R5/R10: no pdf, no launcher, nothing to run degraded); metadata is
    # best-effort like every later re-arm, since it is documented as the
    # FALLBACK — losing it costs redundancy, not the feature.
    def start
      @config = Config.read(@config_path)
      reconcile!(:pdf, fatal: true)
      reconcile!(:metadata)
      self
    end

    # One full iteration, exposed so a test can drive the loop
    # deterministically: re-read the config if SIGHUP arrived, retry any
    # watch still waiting to be re-armed, wait up to timeout_ms for an
    # inotify event, and act on whatever came in.
    def tick(timeout_ms = POLL_MS)
      reread_config_if_requested
      retry_pending_rearms
      ready = @inotify.wait(timeout_ms)
      process_events(@inotify.read_events) if ready
      self
    end

    # The production loop: tick until asked to stop (systemd stops this
    # service with SIGTERM — clean exit 0).
    def run
      tick until @signals.terminated?
      self
    end

    def close
      @inotify.close
    end

    private

    def log_line(msg)
      @out.puts("redoku-watch: #{msg}")
      @out.flush
    end

    # Failures (spawn, re-arm, config) go to stderr; normal decisions to
    # stdout (ruling) — two streams, one journald unit, still one story.
    def err_line(msg)
      @err.puts("redoku-watch: #{msg}")
      @err.flush
    end

    def target_path(role)
      role == :pdf ? @config.pdf : @config.metadata
    end

    def trigger_bit(role)
      role == :pdf ? RM2::Inotify::IN_OPEN : RM2::Inotify::IN_CLOSE_WRITE
    end

    def armed_mask(role)
      trigger_bit(role) | RM2::Inotify::IN_DELETE_SELF | RM2::Inotify::IN_MOVE_SELF
    end

    # Arms (or re-arms) one role's watch against @config's current path. On
    # success the previous watch for this role is forgotten only NOW — after
    # the new one is live — so a SIGHUP reread never has a gap where neither
    # path is covered, and a reread that fails leaves the OLD watch exactly
    # as armed as it was.
    #
    # `fatal:` is `start`'s escape hatch for the one case that must not
    # become a retry: the pdf trigger has never been armed even once. Every
    # other caller gets the forgiving behaviour — log once on the state
    # change into failing, keep retrying on REARM_RETRY_MS, never raise.
    def reconcile!(role, fatal: false)
      path = target_path(role)
      if path.nil?
        forget_watch(role)
        @rearm_failing.delete(role)
        @rearm_retry_at.delete(role)
        return true
      end

      begin
        wd = @inotify.watch(path, armed_mask(role))
        forget_watch(role)
        @watches[wd] = role
        @wd_for[role] = wd
        @rearm_failing[role] = false
        @rearm_retry_at.delete(role)
        true
      rescue SystemCallError => e
        raise ConfigError, "cannot watch #{role} at #{path} (#{e.message})" if fatal
        note_rearm_failing(role, path, e)
        false
      end
    end

    def forget_watch(role)
      old_wd = @wd_for[role]
      @watches.delete(old_wd) if old_wd
      @wd_for[role] = nil
    end

    # "once per state change" (ruling): only the transition INTO failing is
    # worth a line — a later retry logs its own outcome either way (success
    # via retry_pending_rearms, another failure changes nothing worth saying
    # twice).
    def note_rearm_failing(role, path, error)
      first = !@rearm_failing[role]
      @rearm_failing[role] = true
      @rearm_retry_at[role] = @clock.monotonic_ms + REARM_RETRY_MS
      return unless first
      err_line("#{role} watch could not be armed on #{path} " \
                "(#{error.message}); retrying every #{REARM_RETRY_MS}ms")
    end

    def retry_pending_rearms
      now = @clock.monotonic_ms
      @rearm_retry_at.keys.each do |role|
        due = @rearm_retry_at[role]
        next unless due && now >= due
        log_line("#{role} watch re-armed on #{target_path(role)}") if reconcile!(role)
      end
    end

    # SIGHUP re-reads the config and re-arms against whatever paths it now
    # names. RM2.reload? is consumed on read, like RM2.resumed? — unlike
    # "terminated," "config changed" must be seen again on a second SIGHUP
    # (mruby-rm2/README.md).
    def reread_config_if_requested
      return unless @signals.reload?
      begin
        new_config = Config.read(@config_path)
      rescue ConfigError => e
        # @config is untouched and reconcile! is never called: the previous
        # good paths stay armed exactly as they were.
        err_line("config reload failed (#{e.message}); keeping previous paths armed")
        return
      end
      @config = new_config
      reconcile!(:pdf)
      reconcile!(:metadata)
      log_line("config re-read: pdf=#{@config.pdf} " \
                "metadata=#{@config.metadata || '(none)'} game=#{@config.game}")
    end

    def process_events(events)
      events.each do |wd, mask, _cookie, _name|
        # IN_Q_OVERFLOW describes the queue, not one watch (wd == -1), so it
        # can never match a role by wd lookup — handled first.
        if (mask & RM2::Inotify::IN_Q_OVERFLOW) != 0
          log_line("inotify queue overflow (#{self.class.decode_mask(mask).join('|')}); re-arming")
          reconcile!(:pdf)
          reconcile!(:metadata)
          next
        end

        role = @watches[wd]
        next unless role

        if (mask & WATCH_DIED_MASK) != 0
          watch_died(wd, role, mask)
          next
        end

        handle_trigger(role, mask) if (mask & trigger_bit(role)) != 0
      end
    end

    def watch_died(wd, role, mask)
      path = target_path(role)
      log_line("#{role} watch on #{path} ended " \
                "(#{self.class.decode_mask(mask).join('|')}); re-arming")
      @watches.delete(wd)
      @wd_for[role] = nil
      log_line("#{role} watch re-armed on #{target_path(role)}") if reconcile!(role)
    end

    def handle_trigger(role, mask)
      path = target_path(role)
      log_line("trigger: #{self.class.decode_mask(mask).join('|')} on #{path} (#{role})")

      now = @clock.monotonic_ms
      if @last_trigger_ms
        elapsed = now - @last_trigger_ms
        # Negative elapsed can only be the 32-bit monotonic_ms wrap
        # (mruby-rm2/README.md); read as "long ago", App#touch_suppressed?'s
        # convention for the same clock.
        if elapsed >= 0 && elapsed < DEBOUNCE_MS
          log_line("swallowed: #{elapsed}ms since the last trigger, " \
                    "inside the #{DEBOUNCE_MS}ms debounce window")
          return
        end
      end
      @last_trigger_ms = now
      maybe_spawn
    end

    def maybe_spawn
      if redoku_running?
        log_line('redoku is already a client; not spawning')
        return
      end
      begin
        pid = @spawner.spawn_detached(@config.game)
        log_line("spawned #{@config.game} (pid #{pid})")
      rescue StandardError => e
        err_line("spawn failed (#{e.message})")
      end
    end

    # R11: a failing clients check must not block the spawn — the check
    # exists to prevent a double spawn, not to gate the launch.
    def redoku_running?
      @control.clients.any? { |c| c[:name] == 'redoku' }
    rescue StandardError => e
      err_line("clients check failed (#{e.message}); spawning anyway (R11)")
      false
    end
  end
end
