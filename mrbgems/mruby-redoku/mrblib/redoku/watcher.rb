module Redoku
  # `redoku --watch` — the hijack's other half (M4-HIJACK.md, PLAN.md §10).
  # A systemd service holding an inotify watch and the control socket and
  # NOTHING ELSE: it never calls RM2::Display.open, which is what keeps it
  # structurally incapable of stealing the screen. RM2::Control.clients is
  # fine here because it rides the separate control-socket datagram RPC, not
  # the display connection (PLAN.md §3).
  #
  # **The launch policy below is rewritten twice from what the device
  # actually measured**, not from the plan's original guess — read
  # `Watcher::Config::DEFAULT_TRIGGER`'s comment for the second rewrite's
  # numbers before touching either. Round 1 spawned on the raw inotify
  # event; the owner's device showed that was wrong twice over: `IN_OPEN`
  # fires on a boot-time restore with nobody touching the screen, and
  # Quit's own panel handback makes xochitl re-read the decoy, relaunching
  # the very game that just quit (M4-HIJACK device-watcher-journal.txt).
  # Round 2's answer was the startup grace, the suppress/cooldown, AND
  # gating the launch on the decoy's own `lastOpened` field increasing
  # (`trigger=lastopened`) rather than on either watched path's raw event.
  # A second device round then measured that gate's actual cost: xochitl
  # writes `lastOpened` at open time but flushes the sidecar to disk
  # lazily, up to nearly a minute late, while the grace and the cooldown
  # alone already close both hazards round 2 was built for — so
  # `trigger=open` (the raw event, wearing round 2's guards) ships as the
  # default, with `lastopened` kept as a selectable, strictly more precise
  # mode. Both watched paths (pdf `IN_OPEN`, metadata `IN_CLOSE_WRITE`)
  # stay armed either way; neither is ever the trigger by itself — see
  # #genuine_open? for what each mode does with the hint.
  #
  # `clock:`/`control:`/`spawner:`/`signals:` are the App-style seam: real
  # RM2 modules by default, fakes in tests, so the launch policy is
  # host-testable without a display server or a real game process.
  # `inotify:` is the one seam kept REAL (a real tmpdir file, real kernel
  # events), as mruby-rm2/test/inotify.rb does it.
  class Watcher
    # R5/R10: `redoku --watch` with no `--config PATH` reads this. Kept as a
    # literal in main.rb's USAGE text too (see that file's header comment)
    # rather than interpolated, for a load-order reason specific to that
    # constant's own eager evaluation — not a reason to duplicate it anywhere
    # a method body (evaluated lazily) can just reference this one.
    DEFAULT_CONFIG_PATH = '/home/root/redoku/watch.conf'.freeze

    # The FALLBACK filter's window (PLAN.md §11's "watcher re-trigger loop"
    # rule) — only reached when metadata cannot be read at all, so the raw
    # event is all there is to go on.
    DEBOUNCE_MS = 5_000

    # Boot is the noisiest moment on this device (M4-HIJACK fix round 2,
    # requirement C): xochitl's own restore-last-document / thumbnail read
    # can fire IN_OPEN on the decoy with nobody touching the screen, and the
    # device measured exactly that, seconds after boot. Every trigger in the
    # first 10 s of this process's life is swallowed outright, before even
    # the lastOpened check runs — belt under braces, since a boot restore is
    # not expected to bump lastOpened either, but boot is the one moment
    # this watcher trusts least.
    STARTUP_GRACE_MS = 10_000

    # After a spawn, requirement B: no relaunch while a client named
    # `redoku` is present, and none for this long after it disappears
    # either. This is the structural kill for the quit-relaunch loop the
    # device measured — Quit closes the display connection, the server
    # promotes xochitl, xochitl re-reads the decoy it still has open, and
    # that read can reach this watcher as a fresh trigger (and, the device
    # run could not rule out, possibly even a bumped lastOpened) well after
    # DEBOUNCE_MS has expired. Presence is authoritative and unconditional;
    # this cooldown is what closes the gap the instant presence cannot
    # cover — the moment between the game actually exiting and this watcher
    # next happening to check.
    COOLDOWN_MS = 10_000

    # Bounds the inotify wait so SIGTERM/SIGINT/SIGHUP latches are checked at
    # least once a second (ruling: "the poll must be bounded"), and doubles
    # as the pace a pending re-arm or config retry is checked at.
    POLL_MS = 1_000

    # How often a failed re-arm (the watched file briefly absent, mid a
    # xochitl/installer replace) OR a failed config read (mid a slow
    # `/home/root` mount — the device's `203/EXEC` on every boot,
    # requirement D) is retried, rather than every POLL_MS turn — that would
    # turn a multi-second window into a log flood. `:config` shares this
    # same retry bookkeeping (`@rearm_failing`/`@rearm_retry_at`) under its
    # own pseudo-role key alongside `:pdf`/`:metadata`; `reconcile!` never
    # sees it (`retry_pending_rearms` special-cases it to `#load_config`
    # instead), so nothing downstream has to know a third role exists.
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
    # number — this log is the only place Task 5 (and fix round 2's own
    # diagnosis) can read back which trigger actually fired on-device.
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

    # xochitl's own `lastOpened` field (device format: a millisecond epoch
    # as a JSON string — xochitl-3.27-format.md), read as a plain string
    # scan. No JSON parser and no new dependency: the device's own dump is a
    # fixed, machine-written shape, `"lastOpened": "<digits>"`, and this is
    # the one field this watcher ever needs out of it. Returns nil for
    # anything it cannot make sense of — missing key, missing quotes,
    # non-digit content — every one of which means "the caller falls back,"
    # never "raise."
    def self.extract_last_opened(text)
      idx = text.index('"lastOpened"')
      return nil unless idx
      colon = text.index(':', idx)
      return nil unless colon
      q1 = text.index('"', colon)
      return nil unless q1
      q2 = text.index('"', q1 + 1)
      return nil unless q2
      digits = text[(q1 + 1)...q2]
      return nil if digits.empty?
      digits.each_char { |c| return nil if c < '0' || c > '9' }
      digits.to_i
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
      @rearm_failing = {}  # :pdf/:metadata/:config => true while failing
      @rearm_retry_at = {} # same keys => monotonic ms of the next retry
      @last_trigger_ms = nil   # fallback-path debounce bookkeeping
      @last_opened_ms = nil    # primary-path baseline (nil until seeded)
      @started_at_ms = nil     # set by #start; anchors the startup grace
      @spawned_once = false    # has this process EVER called spawn_detached
      @redoku_gone_since_ms = nil # monotonic ms redoku was first seen gone
    end

    # Requirement D: never raises. A config that cannot be read yet — the
    # device's `203/EXEC`, `/home/root` mounting after this unit starts —
    # is logged and retried on the same bounded interval a re-arm uses, not
    # treated as fatal: a watcher that exits at boot because a mount lost a
    # race is a launcher that only works after a manual restart, and that
    # defeats the entire point of this milestone.
    def start
      @started_at_ms = @clock.monotonic_ms
      load_config
      self
    end

    # One full iteration, exposed so a test can drive the loop
    # deterministically: re-read the config if SIGHUP arrived, retry the
    # config (if it never loaded) or any watch still waiting to be
    # re-armed, wait up to timeout_ms for an inotify event, and act on
    # whatever came in.
    def tick(timeout_ms = POLL_MS)
      reread_config_if_requested
      retry_pending_rearms
      note_redoku_presence
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

    # Reads @config_path, retrying on REARM_RETRY_MS under the `:config`
    # pseudo-role until it succeeds — see REARM_RETRY_MS's own comment for
    # why this shares that bookkeeping rather than inventing a second retry
    # mechanism. Called from #start (the first attempt) and from
    # #retry_pending_rearms (every later one); both discard the true/false
    # it returns, because neither has anything more to do either way — the
    # loop just keeps turning. Always logs which trigger= mode is active on
    # success (not only on a recovery, unlike the re-arm-failing pattern
    # elsewhere in this file): fix round 3 asks for this specifically, so
    # one on-device tap plus one journal read settles which of :lastopened
    # or :open this device actually needs, without guessing.
    def load_config
      begin
        @config = Config.read(@config_path)
      rescue ConfigError => e
        first = !@rearm_failing[:config]
        @rearm_failing[:config] = true
        @rearm_retry_at[:config] = @clock.monotonic_ms + REARM_RETRY_MS
        if first
          err_line("config unreadable (#{@config_path}): #{e.message}; " \
                    "retrying every #{REARM_RETRY_MS}ms")
        end
        return false
      end
      @rearm_failing[:config] = false
      @rearm_retry_at.delete(:config)
      log_line("config read: pdf=#{@config.pdf} " \
                "metadata=#{@config.metadata || '(none)'} game=#{@config.game} " \
                "trigger=#{@config.trigger}")
      seed_last_opened
      reconcile!(:pdf)
      reconcile!(:metadata)
      true
    end

    # Establishes the primary path's baseline from the CURRENT lastOpened,
    # so a value already sitting there from before this process existed —
    # a boot restore, a stale open from days ago — can never itself read as
    # a fresh tap (requirement A: "seed... so a boot restore or a thumbnail
    # render... cannot launch anything"). A no-op in :open mode — nothing
    # ever reads @last_opened_ms there, and attempting the read would only
    # risk a misleading "metadata unreadable" line for a value this mode
    # never consults. Otherwise silent when metadata isn't configured at
    # all (nothing to seed); logged to stderr when it is configured but
    # unreadable right now, because #genuine_open? will keep retrying this
    # same read on every later trigger until it succeeds.
    def seed_last_opened
      return if @config.trigger == :open
      path = @config.metadata
      return if path.nil?
      reading = read_last_opened
      if reading
        @last_opened_ms = reading
        log_line("lastOpened baseline seeded at #{reading}")
      else
        err_line("metadata unreadable at startup (#{path}); will retry on the next trigger")
      end
    end

    # The current lastOpened value, or nil for "metadata not configured, or
    # unreadable, or unparseable right now" — every one of those is the
    # same instruction to the caller: fall back.
    def read_last_opened
      path = @config.metadata
      return nil if path.nil?
      self.class.extract_last_opened(File.read(path))
    rescue StandardError
      nil
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
    # as armed as it was. Never raises: "re-arm, don't die" is the whole
    # point (see #note_rearm_failing), and every caller — startup, SIGHUP, a
    # died watch, a bounded retry — gets the identical forgiving behaviour.
    def reconcile!(role)
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
      rescue StandardError => e
        # Deliberately StandardError, not just SystemCallError: #watch has a
        # second raise path this rescue must also catch — the C shim's own
        # "inotify is closed" RuntimeError guard (src/inotify.c). Nothing in
        # today's lifecycle closes @inotify out from under a live Watcher,
        # so that path is unreachable right now, but it is not structurally
        # prevented, and a rescue narrow enough to miss it would let the one
        # failure this requirement exists to guard against — a dead watcher,
        # silently — right back in. The error still reaches stderr either
        # way, via #note_rearm_failing below.
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
        if role == :config
          load_config
        else
          log_line("#{role} watch re-armed on #{target_path(role)}") if reconcile!(role)
        end
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
                "metadata=#{@config.metadata || '(none)'} game=#{@config.game} " \
                "trigger=#{@config.trigger}")
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

    # A watch dying this way (IN_IGNORED/DELETE_SELF/MOVE_SELF) is very
    # often xochitl replacing the file by rename — write-temp-then-rename
    # is the crash-safe pattern, and it unlinks the watched inode exactly
    # like an explicit delete does (this file's own header names it as one
    # of the two ways a replace happens). The rename IS the write: if the
    # replacement metadata already carries a bumped lastOpened, that fact
    # would otherwise reach this watcher as nothing but a re-arm log line —
    # a tap silently lost, with no evidence a launch decision was even
    # skipped (fix round 3). So a successful re-arm is evaluated exactly
    # like an ordinary trigger — same grace, same genuine_open?, same
    # suppression/cooldown — and says so in the log.
    def watch_died(wd, role, mask)
      path = target_path(role)
      log_line("#{role} watch on #{path} ended " \
                "(#{self.class.decode_mask(mask).join('|')}); re-arming")
      @watches.delete(wd)
      @wd_for[role] = nil
      return unless reconcile!(role)
      log_line("#{role} watch re-armed on #{target_path(role)}")
      log_line("#{role} re-arm carries a hint; evaluating the launch decision")
      evaluate_hint
    end

    # An armed path fired. Not itself the trigger any more (see this file's
    # header) — #evaluate_hint decides that, the same way whether it was
    # reached from here or from a re-arm that just carried a hint of its
    # own (#watch_died).
    def handle_trigger(role, mask)
      path = target_path(role)
      log_line("trigger: #{self.class.decode_mask(mask).join('|')} on #{path} (#{role})")
      evaluate_hint
    end

    # The startup grace, then #genuine_open?, then the spawn decision —
    # shared by every path that can carry a hint: an ordinary trigger
    # (#handle_trigger) and a watch that died and was re-armed
    # (#watch_died).
    def evaluate_hint
      since_start = @clock.monotonic_ms - @started_at_ms
      if since_start >= 0 && since_start < STARTUP_GRACE_MS
        log_line("swallowed: #{since_start}ms since start, inside the " \
                  "#{STARTUP_GRACE_MS}ms startup grace")
        return
      end

      return unless genuine_open?
      maybe_spawn
    end

    # Requirement A. lastOpened unreadable (not configured, file gone,
    # field missing) falls back to the raw event + the classic debounce —
    # a broken sidecar must cost redundancy, not the launcher entirely.
    # Otherwise: unchanged or lower is swallowed (a boot restore, a
    # thumbnail render, a duplicate hint for the same tap); the FIRST
    # successful read ever, with no baseline yet, seeds one instead of
    # spawning — the same "cannot launch anything" guarantee #seed_last_opened
    # gives eagerly at startup, reached lazily here for the one case that
    # beat it there (metadata unreadable at #start, readable by the time a
    # hint arrives); anything higher than the baseline is a real tap.
    def genuine_open?
      # trigger=open (fix round 3): the raw event is the whole answer, on
      # purpose — see Config::DEFAULT_TRIGGER's comment for why this is not
      # round 1's policy revived. A different condition from the fallback
      # below (which reacts to metadata being broken); this reacts to the
      # operator having said not to bother with lastOpened at all, so it is
      # checked first and unconditionally, never attempting the read.
      if @config.trigger == :open
        log_line('trigger=open: evaluating the raw event only')
        return fallback_genuine?
      end

      reading = read_last_opened
      if reading.nil?
        if @config.metadata
          err_line("metadata unreadable (#{@config.metadata}); falling back to the raw trigger")
        end
        return fallback_genuine?
      end
      if @last_opened_ms.nil?
        @last_opened_ms = reading
        log_line("lastOpened baseline seeded at #{reading} (was unset); not spawning")
        return false
      end
      if reading > @last_opened_ms
        @last_opened_ms = reading
        log_line("lastOpened increased to #{reading}")
        return true
      end
      log_line("lastOpened unchanged (#{reading}); swallowed")
      false
    end

    # The pre-round-2 policy, alive only for when lastOpened cannot be read
    # at all: PLAN.md §11's "watcher re-trigger loop" rule, DEBOUNCE_MS on
    # the raw event.
    def fallback_genuine?
      now = @clock.monotonic_ms
      if @last_trigger_ms
        elapsed = now - @last_trigger_ms
        # Negative elapsed can only be the 32-bit monotonic_ms wrap
        # (mruby-rm2/README.md); read as "long ago", App#touch_suppressed?'s
        # convention for the same clock.
        if elapsed >= 0 && elapsed < DEBOUNCE_MS
          log_line("swallowed: #{elapsed}ms since the last trigger, " \
                    "inside the #{DEBOUNCE_MS}ms debounce window (fallback)")
          return false
        end
      end
      @last_trigger_ms = now
      true
    end

    def maybe_spawn
      return if redoku_suppressed?
      begin
        pid = @spawner.spawn_detached(@config.game)
        @spawned_once = true
        @redoku_gone_since_ms = nil # a fresh cooldown starts at the NEXT observed "gone", not this instant
        log_line("spawned #{@config.game} (pid #{pid})")
      rescue StandardError => e
        err_line("spawn failed (#{e.message})")
      end
    end

    # Keeps @redoku_gone_since_ms honest BETWEEN triggers, once per tick —
    # not only reactively, inside #redoku_suppressed?, at whatever moment a
    # trigger next happens to ask. That reactive-only version was tried
    # first and measured wrong on the host suite before it ever reached a
    # device: with nothing else polling `clients` in between, the FIRST
    # trigger after a spawn always finds @redoku_gone_since_ms nil and sets
    # it to THAT trigger's own clock reading, so `elapsed` is zero at the
    # exact moment it matters most — the cooldown could never elapse no
    # matter how long a test (or a device) actually waited between two
    # trigger events. In production `tick` already runs about once a second
    # regardless of triggers (`run`'s own loop), so this makes the
    # observation timely off the real clock instead of off whenever the
    # next tap happens to land — matching "for a 10s cooldown AFTER it
    # disappears" instead of "for 10s after this watcher next happens to
    # look." Silent on failure: a broken control socket here just skips
    # this tick's nudge — #redoku_suppressed? is still the one authoritative,
    # LOGGED check at the moment that actually decides a spawn (R11).
    def note_redoku_presence
      return unless @spawned_once
      present = @control.clients.any? { |c| c[:name] == 'redoku' }
      if present
        @redoku_gone_since_ms = nil
      elsif @redoku_gone_since_ms.nil?
        @redoku_gone_since_ms = @clock.monotonic_ms
      end
    rescue StandardError
      nil
    end

    # Requirement B: presence is authoritative, and absence still holds the
    # suppression for COOLDOWN_MS after the first time it was OBSERVED gone
    # (by #note_redoku_presence, above — not set here, so a raise from THIS
    # call can never leave @redoku_gone_since_ms stuck mid-update). R11 is
    # unchanged: a `clients` call that itself raises must not block a spawn
    # (the check exists to prevent a double spawn, not to gate the launch),
    # so it counts as "not suppressed," logged as R11 always has.
    def redoku_suppressed?
      present = @control.clients.any? { |c| c[:name] == 'redoku' }
      if present
        @redoku_gone_since_ms = nil
        log_line('redoku is already a client; not spawning')
        return true
      end
      if @redoku_gone_since_ms
        elapsed = @clock.monotonic_ms - @redoku_gone_since_ms
        if elapsed >= 0 && elapsed < COOLDOWN_MS
          log_line("swallowed: #{elapsed}ms since redoku was last seen running, " \
                    "inside the #{COOLDOWN_MS}ms cooldown")
          return true
        end
      end
      false
    rescue StandardError => e
      err_line("clients check failed (#{e.message}); spawning anyway (R11)")
      false
    end
  end
end
