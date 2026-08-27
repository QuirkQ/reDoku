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

      attr_reader :pdf, :metadata, :game

      def initialize(pdf:, metadata:, game:)
        @pdf = pdf
        @metadata = metadata
        @game = game
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
  end
end
