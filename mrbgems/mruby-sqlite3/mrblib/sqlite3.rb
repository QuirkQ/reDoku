module SQLite3
  class Database
    # Spike note (M3a Task 0, 2026-08-25): the C layer below is mattn's
    # mruby-sqlite3 binding, vendored and compiled against the SQLite
    # amalgamation in src/. It built cleanly against mruby 4.0.0 (its legacy
    # MRB_TT_FIXNUM / mrb_fixnum names still resolve via compat macros), so
    # the hand-rolled ~200-line fallback from the plan was NOT needed.
    #
    # Upstream's execute yields rows to a block or returns a ResultSet; the
    # M3a Store API wants execute(sql, binds = []) returning an array of
    # rows. The C method is therefore registered as _execute and wrapped here.

    def self.open(path)
      new(path)
    end

    def execute(sql, binds = [])
      rows = []
      _execute(sql, *binds) { |row| rows << row }
      rows
    end

    # Runs one or more semicolon-separated statements; returns the number of
    # changed rows of the last statement. Binds apply to the first statement.
    def exec(sql, binds = [])
      execute_batch(sql, *binds)
    end

    def closed?
      @closed ||= false
    end

    # The C implementation cannot be reached with super() from a same-class
    # redefinition in mruby, so it is aliased before being wrapped.
    alias _close_native close
    def close
      return if closed?
      _close_native
      @closed = true
    end
  end
end
