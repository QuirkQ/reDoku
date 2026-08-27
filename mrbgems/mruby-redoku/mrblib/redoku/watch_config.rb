module Redoku
  class Watcher
    # Raised for a config this watcher cannot trust to arm from (a missing
    # `pdf=` key, or the config file itself being unreadable). Nothing
    # downstream of `Watcher#start` treats this as fatal any more
    # (M4-HIJACK fix round 2, requirement D — the device measured
    # `/home/root` mounting AFTER this unit starts, `203/EXEC` on every
    # boot): `#load_config` catches it, logs it, and retries on the same
    # bounded interval a re-arm uses. A SIGHUP re-read catches the identical
    # error the identical way — log it, keep the previous good paths armed
    # (`Watcher#reread_config_if_requested`) — a bad edit must not silently
    # disarm the launcher either.
    class ConfigError < StandardError; end

    # watch.conf's shape is fixed by ruling: key=value lines, '#' comments
    # and blank lines allowed, exactly the keys pdf=/metadata=/game=.
    # tools/mkdecoy.rb (MkDecoy.watch_conf_for) is the one writer of a real
    # one; this is the one reader. Its own file (not nested inside
    # watcher.rb) because it is a clean extraction: parsing key=value text
    # into three strings shares no state with the watcher's own arm/re-arm
    # machinery. Loads before watcher.rb (mrblib's own sorted load order,
    # documented in test/_support.rb: '_' < 'a' < ... so
    # 'watch_config.rb' sorts ahead of 'watcher.rb' on the underscore) —
    # not that it matters here, since `Watcher` is merely reopened either
    # way and nothing here is referenced from a top-level constant
    # expression the way main.rb's USAGE literal is.
    class Config
      # Mirrors MkDecoy::DEVICE_GAME_BIN (tools/mkdecoy.rb) by value — the
      # two tools can't share code (one host CRuby, one mruby), so it's
      # duplicated on purpose rather than guessed independently.
      DEFAULT_GAME = '/home/root/redoku/bin/redoku'.freeze

      # M4-HIJACK fix round 3: which signal a spawn is gated on.
      # :lastopened — a spawn requires the decoy's own `lastOpened` field
      # to have strictly increased (fix round 2's original policy). :open
      # — an `IN_OPEN` on the pdf (or an `IN_CLOSE_WRITE` on metadata,
      # since both armed paths are still just hints either way) is
      # sufficient on its own, gated only by the startup grace, the
      # fallback debounce and the suppress/cooldown — see
      # `Watcher#genuine_open?`. This is NOT round 1's raw-event policy
      # revived: round 1 had no grace and no cooldown; :open is the same
      # raw trigger wearing round 2's guards, which is exactly what makes
      # it safe to ship as a default rather than a revert.
      #
      # **:open is the shipped default, measured, not guessed** — a second
      # device round (device-latency-journal.txt) settled the question fix
      # round 3 raised: xochitl DOES write `lastOpened` at open time, but
      # flushes the sidecar file to disk lazily — 13 s after one tap, 54 s
      # after another, decoded straight out of the recorded epoch value
      # itself, while `IN_OPEN` on the pdf fired at the instant of both
      # taps, every time. Gating the launch on :lastopened means the owner
      # stares at a static PDF for up to nearly a minute; that is a worse
      # failure than either hazard :lastopened was built to prevent, and
      # the SAME capture proved both of those hazards are independently
      # closed already: the boot-time phantom `IN_OPEN` was swallowed at
      # 9190 ms into the 10 s startup grace, and the post-quit relaunch was
      # swallowed twice by the cooldown ("swallowed: 1504ms since redoku
      # was last seen running, inside the 10000ms cooldown"). :lastopened
      # stays selectable — a strictly more precise signal, and it may earn
      # its keep on a firmware that flushes eagerly — but nothing measured
      # on THIS device asks for it as the default. Whoever is tempted to
      # flip this back on principle: reread this comment and the journal
      # it cites first.
      DEFAULT_TRIGGER = :open

      attr_reader :pdf, :metadata, :game, :trigger

      def initialize(pdf:, metadata:, game:, trigger:)
        @pdf = pdf
        @metadata = metadata
        @game = game
        @trigger = trigger
      end

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

        new(pdf: pdf, metadata: metadata, game: game, trigger: parse_trigger(values['trigger']))
      end

      # An absent key (every watch.conf mkdecoy.rb generates today has no
      # `trigger=` line at all) must mean the default, not an error — this
      # switch has to work against the file that already ships. mkdecoy.rb
      # is another agent's file and is not touched here; it should learn to
      # emit `trigger=` explicitly later, once the device measurement
      # picks a mode worth defaulting to on record rather than by omission.
      def self.parse_trigger(raw)
        return DEFAULT_TRIGGER if raw.nil? || raw.empty?
        case raw
        when 'lastopened' then :lastopened
        when 'open' then :open
        else
          raise ConfigError, "trigger= must be lastopened or open, got #{raw.inspect}"
        end
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
  end
end
