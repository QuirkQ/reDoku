module Redoku
  PEN_DEVICE = 'Wacom I2C Digitizer'.freeze

  USAGE = <<~TEXT
    usage: redoku [options]

    Draws the reDoku board on the reMarkable 2 and echoes pen ink into it.
    Tap Quit to give the screen back to xochitl.

      --clients   list the display server's clients and exit
      --help      show this message
  TEXT

  # Entry point called from tools/redoku/redoku.c. Returns the process exit
  # status.
  def self.main(argv)
    unknown = argv.find { |a| !['--help', '--clients'].include?(a) }
    if unknown
      $stderr.puts "redoku: unknown option #{unknown}"
      $stderr.puts USAGE
      return 2
    end
    if argv.include?('--help')
      puts USAGE
      return 0
    end
    return list_clients if argv.include?('--clients')

    play
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

    App.new(display, inputs, Renderer.new(display)).run

    inputs.each { |input| input.close }
    display.close # closing the connection hands the panel back to xochitl
    0
  rescue StandardError => e
    $stderr.puts "redoku: #{e.message}"
    1
  end
end
