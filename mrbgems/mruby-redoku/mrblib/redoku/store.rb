module Redoku
  # SQLite-backed save storage (docs/plans/2026-08-25-m3-sqlite-saves.md).
  #
  # One connection for the app's lifetime, single process, so locking is moot.
  # Every row read back is validated before use and a bad one is skipped and
  # logged — an unchanged board beats a wiped one, the same rule §11's signal
  # handling makes. A corrupt DATABASE file never refuses to start either:
  # it is renamed aside to <path>.bad-<epoch> and an empty one takes its
  # place. If even that fails, Store raises out of .open and it is the
  # caller's (App's / main.rb's) fallback that keeps the game running without
  # persistence.
  #
  # There is no Regexp in this build (no regexp gem in the default gembox),
  # so board strings are validated by hand rather than with /\A[0-9.]{81}\z/.
  class Store
    VERSION = 1
    MANUAL_CAP = 50

    BOARD_CHARS = '0123456789.'

    SCHEMA_SQL = <<~SQL
      PRAGMA synchronous = FULL;
      PRAGMA user_version = 1;
      CREATE TABLE IF NOT EXISTS games (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        kind          TEXT    NOT NULL CHECK (kind IN ('autosave','manual')),
        difficulty    TEXT    NOT NULL,
        achieved_tier TEXT    NOT NULL,
        givens        TEXT    NOT NULL,
        entries       TEXT    NOT NULL,
        solution      TEXT    NOT NULL,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_games_updated ON games(updated_at DESC);
    SQL

    FULL_COLS =
      'id, kind, difficulty, achieved_tier, givens, entries, solution, ' \
      'created_at, updated_at'

    def self.open(path, log: $stderr)
      new(path, log)
    end

    def initialize(path, log)
      @path = path
      @log = log
      @db = nil
      self.class.make_parent_dirs(File.dirname(path))
      open_database
    end

    def save_autosave(game)
      vals = normalize(game)
      unless vals
        log_line('refused to autosave: invalid game record')
        return nil
      end
      now = Time.now.to_i
      begin
        @db.transaction
        @db.execute('DELETE FROM games WHERE kind = ?', ['autosave'])
        insert_row('autosave', vals, now)
        @db.commit
      rescue StandardError => e
        rollback_quietly
        log_line('autosave failed (' + e.message + ')')
        return nil
      end
      @db.last_insert_rowid
    end

    def autosave
      rows = @db.execute("SELECT #{FULL_COLS} FROM games WHERE kind = 'autosave'")
      return nil if rows.empty?
      validate_row(rows[0])
    rescue StandardError => e
      log_line('could not read autosave (' + e.message + ')')
      nil
    end

    def save_manual(game)
      if game.nil?
        log_line('no board to save')
        return nil
      end
      vals = normalize(game)
      unless vals
        log_line('refused to save: invalid game record')
        return nil
      end
      count = @db.execute(
        "SELECT COUNT(*) FROM games WHERE kind = 'manual'")[0][0]
      if count >= MANUAL_CAP
        log_line('manual save refused: cap of ' + MANUAL_CAP.to_s +
                 ' reached')
        return nil
      end
      now = Time.now.to_i
      begin
        @db.transaction
        insert_row('manual', vals, now)
        @db.commit
      rescue StandardError => e
        rollback_quietly
        log_line('manual save failed (' + e.message + ')')
        return nil
      end
      @db.last_insert_rowid
    end

    def games
      # Validated through the SAME helper as autosave/load — a row whose
      # board strings are corrupt has no business being listed either — and
      # projected down to metadata only, so a listing never carries puzzle
      # strings out of the database.
      rows = @db.execute("SELECT #{FULL_COLS} FROM games " \
                         'ORDER BY updated_at DESC')
      out = []
      rows.each do |r|
        rec = validate_row(r)
        next unless rec
        out << { id: rec[:id], kind: rec[:kind],
                 difficulty: rec[:difficulty],
                 achieved_tier: rec[:achieved_tier],
                 updated_at: rec[:updated_at] }
      end
      out
    rescue StandardError => e
      log_line('could not list games (' + e.message + ')')
      []
    end

    def load(id)
      rows = @db.execute("SELECT #{FULL_COLS} FROM games WHERE id = ?", [id])
      return nil if rows.empty?
      validate_row(rows[0])
    rescue StandardError => e
      log_line('could not load game ' + id.to_s + ' (' + e.message + ')')
      nil
    end

    def delete(id)
      changed = nil
      begin
        @db.transaction
        changed = @db.exec('DELETE FROM games WHERE id = ?', [id])
        @db.commit
      rescue StandardError => e
        rollback_quietly
        log_line('delete failed (' + e.message + ')')
        return false
      end
      changed > 0
    end

    def close
      @db.close if @db && !@db.closed?
      nil
    rescue StandardError => e
      log_line('close failed (' + e.message + ')')
      nil
    end

    def closed?
      @db.nil? || @db.closed?
    end

    def self.make_parent_dirs(dir)
      absolute = dir[0] == '/'
      path = ''
      dir.split('/').each do |part|
        next if part == ''
        if path == ''
          path = absolute ? '/' + part : part
        else
          path = path + '/' + part
        end
        Dir.mkdir(path) unless Dir.exist?(path)
      end
    end

    private

    def open_database
      existed = File.exist?(@path)
      @db = SQLite3::Database.open(@path)
      if existed
        begin
          version = read_version
          if version != 0 && version != VERSION
            quarantine('unexpected schema version ' + version.to_s)
            @db = SQLite3::Database.open(@path)
          end
        rescue StandardError => e
          quarantine(e.message)
          @db = SQLite3::Database.open(@path)
        end
      end
      @db.exec(SCHEMA_SQL)
    end

    def read_version
      rows = @db.execute('PRAGMA user_version')
      row = rows[0]
      row ? row[0] : 0
    end

    def quarantine(reason)
      begin
        @db.close if @db && !@db.closed?
      rescue StandardError
        nil
      end
      @db = nil
      bad = @path + '.bad-' + Time.now.to_i.to_s
      File.rename(@path, bad) if File.exist?(@path)
      log_line('save database unusable (' + reason + '); moved aside')
    rescue StandardError => e
      log_line('could not move damaged save database aside (' +
               e.message + ')')
    end

    def insert_row(kind, vals, now)
      @db.execute(
        'INSERT INTO games (kind, difficulty, achieved_tier, givens, ' \
        'entries, solution, created_at, updated_at) ' \
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [kind, vals[0], vals[1], vals[2], vals[3], vals[4], now, now])
    end

    def normalize(game)
      return nil unless game.is_a?(Hash)
      return nil unless board?(game[:givens]) && board?(game[:entries]) &&
                        board?(game[:solution])
      diff = tier_of(game[:difficulty])
      ach = tier_of(game[:achieved_tier])
      return nil if diff.nil? || ach.nil?
      [diff.to_s, ach.to_s, game[:givens], game[:entries], game[:solution]]
    end

    def validate_row(r)
      kind = kind_of(r[1])
      diff = tier_of(r[2])
      ach = tier_of(r[3])
      if kind.nil? || diff.nil? || ach.nil? ||
         !board?(r[4]) || !board?(r[5]) || !board?(r[6])
        log_line('skipped corrupt saved-game row ' + r[0].to_s)
        return nil
      end
      { id: r[0], kind: kind, difficulty: diff, achieved_tier: ach,
        givens: r[4], entries: r[5], solution: r[6],
        created_at: r[7], updated_at: r[8] }
    end

    def board?(s)
      return false unless s.is_a?(String) && s.size == 81
      s.each_char { |ch| return false unless BOARD_CHARS.include?(ch) }
      true
    end

    def tier_of(t)
      sym = t.is_a?(Symbol) ? t : (t.is_a?(String) ? t.to_sym : nil)
      Sudoku::Rater::TIERS.include?(sym) ? sym : nil
    end

    def kind_of(k)
      k == 'autosave' || k == 'manual' ? k.to_sym : nil
    end

    def rollback_quietly
      @db.rollback
    rescue StandardError
      nil
    end

    def log_line(text)
      @log.puts('redoku: ' + text) if @log
      self
    end
  end
end
