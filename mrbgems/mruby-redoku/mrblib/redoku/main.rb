module Redoku
  PEN_DEVICE = 'Wacom I2C Digitizer'.freeze
  TOUCH_DEVICE = 'pt_mt'.freeze

  # Survives firmware updates (/home/root/redoku is install.sh's home too).
  # Store creates the directory itself, so a fresh device needs nothing.
  DB_PATH = '/home/root/redoku/games.db'.freeze

  # How many passes over 1..9 one --record run asks for. Four rounds is 36
  # samples — enough for Task 11 to tune against without asking the player
  # to sit through a hundred prompts.
  RECORD_ROUNDS = 4

  # The default config path below is a literal, not
  # Watcher::DEFAULT_CONFIG_PATH: mrblib files load in sorted filename order
  # (test/_support.rb's own header explains why), and 'main.rb' sorts before
  # 'watcher.rb', so this constant's own class body runs before Watcher
  # exists — an interpolation here would raise NameError on every launch,
  # not just --watch.
  USAGE = <<~TEXT
    usage: redoku [options]

    Draws the reDoku board on the reMarkable 2 and echoes pen ink into it.
    The board takes the pen only; the buttons also take a finger.
    Tap Quit to give the screen back to xochitl.

      --record          capture handwriting templates for the recognizer
      --clients         list the display server's clients and exit
      --watch           run the resident hijack watcher (systemd service;
                         reads /home/root/redoku/watch.conf)
      --watch --config PATH
                         same, reading PATH instead of the default config
      --help            show this message
  TEXT

  KNOWN_FLAGS = ['--help', '--clients', '--record', '--watch'].freeze

  # Entry point called from tools/redoku/redoku.c. Returns the process exit
  # status.
  def self.main(argv)
    args = argv.dup
    config_path = nil
    idx = args.index('--config')
    if idx
      config_path = args[idx + 1]
      if config_path.nil?
        $stderr.puts 'redoku: --config requires a PATH argument'
        $stderr.puts USAGE
        return 2
      end
      # Removed rather than added to KNOWN_FLAGS: --config takes a value, so
      # it and that value are consumed as a pair before the flag-only check
      # below runs, or the path itself would read as an unknown option.
      args.delete_at(idx + 1)
      args.delete_at(idx)
    end

    unknown = args.find { |a| !KNOWN_FLAGS.include?(a) }
    if unknown
      $stderr.puts "redoku: unknown option #{unknown}"
      $stderr.puts USAGE
      return 2
    end
    if config_path && !args.include?('--watch')
      $stderr.puts 'redoku: --config is only valid with --watch'
      $stderr.puts USAGE
      return 2
    end
    if args.include?('--help')
      puts USAGE
      return 0
    end
    return record_templates if args.include?('--record')
    return list_clients if args.include?('--clients')
    return watch(config_path) if args.include?('--watch')

    play
  end

  # `redoku --watch` (M4-HIJACK.md Task 3): the resident watcher, run under
  # `redoku-watcher.service`. RM2.setup_signals is called here rather than
  # inside Watcher — the same split play/record_templates already use — so
  # Watcher's own `signals:` default (plain RM2) can be exercised in tests
  # without a real signal handler installed on the test process.
  #
  # A ConfigError (no pdf= key, or a pdf file that cannot be watched) is
  # fatal here and only here: R5/R10 says a decoy nobody can arm is a
  # launcher nobody can use, so there is nothing to run degraded. Once
  # running, the very same error on a SIGHUP re-read is NOT fatal — Watcher
  # swallows it itself and keeps the previous paths armed.
  def self.watch(config_path)
    RM2.setup_signals
    watcher = Watcher.new(config_path || Watcher::DEFAULT_CONFIG_PATH)
    begin
      watcher.start
      watcher.run
    ensure
      watcher.close
    end
    0
  rescue StandardError => e
    $stderr.puts "redoku: #{e.message}"
    1
  end

  def self.list_clients
    RM2::Control.clients.each do |c|
      puts "#{c[:active] ? '*' : ' '}#{c[:pid]} #{c[:name]}"
    end
    0
  rescue StandardError => e
    $stderr.puts "redoku: #{e.message}"
    1
  end

  # The capture half of --record: paint the prompt, feed pen strokes to the
  # Recorder one completed stroke at a time, and write TARGET when the walk
  # is over. This is a stripped-down App loop — no buttons, no board, no
  # store — because a recording session has exactly one interaction: write
  # the digit being asked for. Everything smarter than that (round-major
  # ordering, codec, corrupt-line tolerance) lives in Recorder, which is
  # what makes it host-testable.
  #
  # A SIGINT/SIGTERM mid-walk still writes what was captured: parse skips
  # corrupt lines precisely so a torn file costs samples, never the session,
  # and 20 good samples beat 0 because the player had to write them by hand.
  def self.record_templates
    RM2.setup_signals
    display = nil
    inputs = []
    begin
      display = RM2::Display.open

      paths = RM2::Input.resolve_all(PEN_DEVICE)
      if paths.empty?
        raise "no input device named #{PEN_DEVICE}"
      end
      inputs = paths.map { |path| display.open_input(path) }

      renderer = Renderer.new(display)
      recorder = Recorder.new(rounds: RECORD_ROUNDS)
      renderer.draw_record_prompt(recorder)
      renderer.flush_all

      subs = nil # subpaths of the stroke open right now; nil when pen is up
      until recorder.done? || RM2.terminated?
        ready = RM2::Input.wait(inputs, App::POLL_MS)
        next unless ready
        inputs.each do |input|
          input.pending_events.each do |sample|
            raw_x, raw_y, _pressure, tools = sample
            x, y = Pen.to_screen(raw_x, raw_y)
            down = (tools & RM2::Input::TOUCH) != 0
            if down && subs.nil?
              subs = [[[x, y]]]
            elsif down
              cur = subs[0]
              prev = cur[cur.size - 1]
              cur << [x, y] if prev[0] != x || prev[1] != y
            elsif subs
              stroke = { subpaths: subs }
              # The dot guard decides "is this ink at all", exactly as it
              # does in play: an accidental contact must not become a
              # template of nothing.
              if Ink.path_length(stroke) >= Ink::MIN_PATH
                recorder.accept(stroke[:subpaths])
                renderer.draw_record_prompt(recorder)
                renderer.flush_all
              end
              subs = nil
            end
          end
        end
        # Same rule as App#drop_hung_up_sources: the server tearing down a
        # uinput clone costs one source, never the session, and a session
        # whose every pen source died has nothing left to wait on.
        inputs = inputs.reject { |source| source.hung_up? }
        break if inputs.empty?
      end

      Store.make_parent_dirs(File.dirname(Recorder::TARGET))
      File.open(Recorder::TARGET, 'w') { |f| f.write(recorder.to_text) }
      puts "redoku: saved #{recorder.samples.size} sample(s) to " +
           Recorder::TARGET
    ensure
      inputs.each { |input| input.close }
      # Closing the connection hands the panel back to xochitl, as in play.
      display.close if display
    end
    0
  end

  def self.play
    RM2.setup_signals
    # No socket override: the default path is absent in the build container,
    # which is exactly what the bintest's failure case needs, and ENV would
    # mean declaring mruby-env for a test hook.
    display = RM2::Display.open

    paths = RM2::Input.resolve_all(PEN_DEVICE)
    if paths.empty?
      raise "no input device named #{PEN_DEVICE}"
    end
    inputs = paths.map { |path| display.open_input(path) }

    # The touchscreen is what makes the buttons finger-tappable, and unlike
    # the pen it is not required — so nothing about it may keep the game from
    # starting. A missing node, or one the server declines to open, costs the
    # player finger buttons and nothing else: reDoku is a pen game, and
    # App#drop_hung_up_sources already treats a touchscreen that dies
    # mid-session exactly this way ("a game whose buttons went back to
    # pen-only"). Whatever did open stays open and is still polled — one node
    # of two is still a touchscreen, and the one that failed may well be the
    # uinput clone that carries no contacts anyway.
    #
    # Plural for the same reason the pen is: the display server publishes a
    # uinput clone under the same evdev name, and only the hardware node
    # carries real contacts. That is 2 pen + 2 touch fds of the 8
    # RM2::Input.wait accepts on the owner's device — worth watching, because
    # a firmware publishing more clones than that would raise from the first
    # wait rather than from an open, which this rescue does not cover.
    touches = []
    begin
      RM2::Input.resolve_all(TOUCH_DEVICE).each do |path|
        touches << display.open_input(path)
      end
    rescue StandardError => e
      # Not fatal, but not silent either: a player who expected to tap a
      # button with a finger should be told why they cannot.
      $stderr.puts "redoku: touchscreen unavailable (#{e.message})"
    end

    # Persistence is optional from the game's point of view: a missing or
    # unopenable DB (unwritable /home/root, a file Store could not even
    # quarantine) means the player plays on without saves, told why on
    # stderr. It must never keep the board from starting.
    store = nil
    begin
      store = Store.open(DB_PATH)
    rescue StandardError => e
      $stderr.puts "redoku: saves unavailable (#{e.message})"
    end

    begin
      App.new(display, inputs, Renderer.new(display),
              touch_sources: touches, store: store).run
    ensure
      # App's own shutdown already closed the store; this is the same
      # belt-and-braces pass that closes the inputs and display below, for
      # the path where run itself raised.
      begin
        store.close if store && !store.closed?
      rescue StandardError
        nil
      end
    end

    (inputs + touches).each { |input| input.close }
    display.close # closing the connection hands the panel back to xochitl
    0
  rescue StandardError => e
    $stderr.puts "redoku: #{e.message}"
    1
  end
end
