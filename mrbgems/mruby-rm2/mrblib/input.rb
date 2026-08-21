module RM2
  class Input
    SYSFS_ROOT = '/sys/class/input'.freeze

    # Every evdev node whose device reports exactly `name`, ordered by node
    # number. Plural on purpose: the rm2fb server publishes uinput clones of
    # the real devices for its TCP injection path, and a clone carries the
    # same name as the hardware it mirrors, with real events going only to
    # the hardware node and injected ones only to the clone. A client that
    # wants both opens every path this returns.
    def self.resolve_all(name, root = SYSFS_ROOT)
      return [] unless Dir.exist?(root)

      found = []
      Dir.entries(root).each do |node|
        # Core String#[] rather than start_with?, which lives in
        # mruby-string-ext: this gem depends only on io/dir/errno, and
        # mrbtest runs its tests with just those loaded. Also drops
        # Dir.entries's '.' and '..'.
        next unless node[0, 5] == 'event'
        name_file = "#{root}/#{node}/device/name"
        next unless File.exist?(name_file)
        next unless File.read(name_file).chomp == name
        found << [node[5..-1].to_i, "/dev/input/#{node}"]
      end
      found.sort { |a, b| a[0] <=> b[0] }.map { |pair| pair[1] }
    end
  end
end
