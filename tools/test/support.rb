# tools/test/support.rb — a ~20-line assertion harness for tools/ tests.
#
# No test framework is assumed: `tools/` is stdlib-only CRuby (mkdecoy.rb
# runs from `bin/redoku install` on the owner's Mac), and CRuby's bundled
# gems (minitest, rspec…) aren't guaranteed to exist there *or* in the
# Docker build container (docker/Dockerfile installs plain "ruby", nothing
# more) — see M4-HIJACK's task-2 brief. So this is plain Ruby, not a gem.

module Support
  @checks = 0
  @failures = []

  def self.check(description)
    @checks += 1
    ok = yield
    @failures << description unless ok
  rescue StandardError => e
    @failures << "#{description} (raised #{e.class}: #{e.message})"
  end

  # Call once, at the end of a test file. Prints a one-line summary and
  # exits non-zero on any failure, so `make test-tools` / CI fail loudly.
  def self.report_and_exit
    puts "#{@checks} checks, #{@failures.size} failures"
    @failures.each { |f| puts "  FAIL: #{f}" }
    exit(@failures.empty? ? 0 : 1)
  end
end
