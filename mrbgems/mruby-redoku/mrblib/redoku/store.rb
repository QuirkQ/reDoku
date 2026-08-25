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
  # Schema v2 adds the stroke journal (Task 6): one row per completed pen
  # ink stroke, belonging to its game row and dying with it (the FK is real
  # — foreign_keys is turned ON per connection in SCHEMA_SQL, because SQLite
  # enforcement is off by default and off PER CONNECTION at that). Points are
  # stored as TEXT in panel ("screen") coordinates — the frame Renderer
  # repaints from — encoded 'x,y x,y|x,y' : points joined by spaces, a '|'
  # between subpaths where the stroke left the board and came back. Text, not
  # BLOB, deliberately: the binding binds Strings as text, and its reader
  # truncates TEXT columns at the first NUL byte (mrb_sqlite3.c uses
  # mrb_str_new_cstr for SQLITE_TEXT), so a binary encoding could not
  # round-trip through it.
  #
  # Caps keep a pathological session from bloating the file for ever:
  # STROKES_CAP rows per game (oldest dropped, logged) and MAX_STROKE_POINTS
  # recorded points per stroke (App stops recording past it; live ink keeps
  # flowing either way).
  class Store
    VERSION = 2
    MANUAL_CAP = 50
    STROKES_CAP = 2000
    MAX_STROKE_POINTS = 2048

    BOARD_CHARS = '0123456789.'

    # A replayed draw_line coordinate must fit what Display#draw_line accepts
    # (RM2_MAX_SPAN in src/display.c); Pen.to_screen cannot leave the panel,
    # but the validator reads back rows the store did not write.
    PTS_MAX = 65_535

    SCHEMA_SQL = <<~SQL
      PRAGMA synchronous = FULL;
      PRAGMA foreign_keys = ON;
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
      CREATE TABLE IF NOT EXISTS strokes (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        game_id    INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        seq        INTEGER NOT NULL,
        color      INTEGER NOT NULL,
        width      INTEGER NOT NULL,
        pts        TEXT    NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_strokes_game ON strokes(game_id, seq);
    SQL

    FULL_COLS =
      'id, kind, difficulty, achieved_tier, givens, entries, solution, ' \
      'created_at, updated_at'

    def self.open(path, log: $stderr, stroke_cap: STROKES_CAP)
      new(path, log, stroke_cap)
    end

    def initialize(path, log, stroke_cap)
      @path = path
      @log = log
      @db = nil
      # Injectable for the same reason `log:` is: the cap is real policy that
      # a test must be able to exercise without writing 2000 rows through
      # synchronous=FULL first.
      @stroke_cap = stroke_cap > 0 ? stroke_cap : 1
      self.class.make_parent_dirs(File.dirname(path))
      open_database
    end

    # Upserts the singleton autosave row, KEEPING ITS ID once it exists
    # (UPDATE in place rather than the v1 delete-and-reinsert). The id is
    # what the stroke journal hangs off, and a clean-quit autosave refresh
    # would otherwise cascade every journaled stroke of the session into
    # the void. A New press still discards deliberately — App clears that
    # game's strokes itself (see App#fill_board), and this method stays a
    # pure upsert.
    def save_autosave(game)
      vals = normalize(game)
      unless vals
        log_line('refused to autosave: invalid game record')
        return nil
      end
      now = Time.now.to_i
      id = nil
      begin
        @db.transaction
        rows = @db.execute("SELECT id FROM games WHERE kind = 'autosave'")
        if rows.empty?
          insert_row('autosave', vals, now)
          id = @db.last_insert_rowid
        else
          id = rows[0][0]
          @db.execute(
            'UPDATE games SET difficulty = ?, achieved_tier = ?, ' \
            'givens = ?, entries = ?, solution = ?, updated_at = ? ' \
            'WHERE id = ?',
            [vals[0], vals[1], vals[2], vals[3], vals[4], now, id])
        end
        @db.commit
      rescue StandardError => e
        rollback_quietly
        log_line('autosave failed (' + e.message + ')')
        return nil
      end
      id
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

    # --- the stroke journal (Task 6). One INSERT per completed stroke, no
    # transaction ceremony: SQLite's own autocommit gives the write its
    # durability against synchronous=FULL, which is the same crash-safe bar
    # the autosave holds. The seq and the cap check each cost one indexed
    # query against a table that stays small by construction.

    # Appends one stroke for `game_id`. `subpaths` is an array of arrays of
    # [x, y] panel points (one array per uninterrupted run of the stroke);
    # false on any refusal, logged. The stroke must outlive the game row it
    # belongs to — the FK cascade sees to that — so a nil id refuses.
    def journal_stroke(game_id, color, width, subpaths)
      return false unless game_id
      encoded = self.class.encode_pts(subpaths)
      unless encoded
        log_line('refused to journal a stroke: bad points')
        return false
      end
      begin
        seq = @db.execute(
          'SELECT COALESCE(MAX(seq), 0) + 1 FROM strokes WHERE game_id = ?',
          [game_id])[0][0]
        @db.execute(
          'INSERT INTO strokes (game_id, seq, color, width, pts, ' \
          'created_at) VALUES (?, ?, ?, ?, ?, ?)',
          [game_id, seq, color, width, encoded, Time.now.to_i])
      rescue StandardError => e
        log_line('stroke journal failed (' + e.message + ')')
        return false
      end
      enforce_stroke_cap(game_id)
      true
    end

    # Every journaled stroke of a game, oldest first, decoded and validated.
    # A corrupt row is skipped and logged, never raised — unchanged ink
    # beats a wiped board, same rule as the game rows above.
    def strokes(game_id)
      return [] unless game_id
      rows = @db.execute(
        'SELECT color, width, pts FROM strokes ' \
        'WHERE game_id = ? ORDER BY seq ASC, id ASC', [game_id])
      out = []
      rows.each do |color, width, pts|
        subpaths = self.class.decode_pts(pts)
        if subpaths.nil? || !int?(color) || color < 0 || color > 255 ||
           !int?(width) || width < 1
          log_line('skipped corrupt stroke row for game ' + game_id.to_s)
          next
        end
        out << { color: color, width: width, subpaths: subpaths }
      end
      out
    rescue StandardError => e
      log_line('could not read strokes (' + e.message + ')')
      []
    end

    def clear_strokes(game_id)
      return false unless game_id
      @db.execute('DELETE FROM strokes WHERE game_id = ?', [game_id])
      true
    rescue StandardError => e
      log_line('could not clear strokes (' + e.message + ')')
      false
    end

    # A manual copy takes the ink with it, so loading either restores the
    # same board AND the same marks on it.
    def copy_strokes(from_id, to_id)
      return false unless from_id && to_id
      @db.execute(
        'INSERT INTO strokes (game_id, seq, color, width, pts, created_at) ' \
        'SELECT ?, seq, color, width, pts, ? FROM strokes WHERE game_id = ? ' \
        'ORDER BY seq ASC, id ASC', [to_id, Time.now.to_i, from_id])
      enforce_stroke_cap(to_id)
      true
    rescue StandardError => e
      log_line('could not copy strokes (' + e.message + ')')
      false
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

    # Keeps one game's journal bounded: past the cap, the OLDEST strokes go
    # (they are the ones the player is least likely to still be looking at)
    # and the fact is logged. Called after each append, where it normally
    # costs one COUNT and deletes nothing.
    def enforce_stroke_cap(game_id)
      count = @db.execute(
        'SELECT COUNT(*) FROM strokes WHERE game_id = ?', [game_id])[0][0]
      excess = count - @stroke_cap
      return if excess <= 0
      @db.execute(
        'DELETE FROM strokes WHERE id IN (SELECT id FROM strokes ' \
        'WHERE game_id = ? ORDER BY seq ASC, id ASC LIMIT ?)',
        [game_id, excess])
      log_line('dropped ' + excess.to_s + ' oldest stroke(s) for game ' +
               game_id.to_s + ': cap of ' + @stroke_cap.to_s + ' reached')
    rescue StandardError => e
      log_line('stroke cap check failed (' + e.message + ')')
    end

    # --- the points codec. 'x,y x,y|x,y': points space-joined inside a
    # subpath, subpaths '|'-joined. Panel coordinates, integers only — no
    # sign, no decimals, nothing the parser has to guess about.

    def self.encode_pts(subpaths)
      return nil unless subpaths.is_a?(Array) && !subpaths.empty?
      total = 0
      parts = []
      subpaths.each do |sub|
        return nil unless sub.is_a?(Array) && !sub.empty?
        strs = []
        sub.each do |pt|
          return nil unless pt.is_a?(Array) && pt.size == 2 &&
                            pt_in_span?(pt[0]) && pt_in_span?(pt[1])
          total += 1
          strs << pt[0].to_s + ',' + pt[1].to_s
        end
        parts << strs.join(' ')
      end
      return nil if total > MAX_STROKE_POINTS
      parts.join('|')
    end

    def self.decode_pts(s)
      return nil unless s.is_a?(String) && !s.empty?
      subpaths = []
      s.split('|').each do |part|
        sub = []
        part.split(' ').each do |pair|
          xy = pair.split(',')
          return nil unless xy.size == 2 &&
                            unsigned_int?(xy[0]) && unsigned_int?(xy[1])
          x = xy[0].to_i
          y = xy[1].to_i
          return nil unless pt_in_span?(x) && pt_in_span?(y)
          sub << [x, y]
        end
        return nil if sub.empty?
        subpaths << sub
      end
      subpaths.empty? ? nil : subpaths
    end

    def self.pt_in_span?(v)
      v.is_a?(Integer) && v >= 0 && v <= PTS_MAX
    end

    def self.unsigned_int?(s)
      return false unless s.is_a?(String) && !s.empty?
      s.each_char { |ch| return false unless ch >= '0' && ch <= '9' }
      true
    end

    def int?(v)
      v.is_a?(Integer)
    end

    def open_database
      existed = File.exist?(@path)
      @db = SQLite3::Database.open(@path)
      if existed
        begin
          # 0 is a brand-new file (or one a crash left before the first
          # write); 1 is the v1 layout, which migrates by simply running the
          # v2 DDL — CREATE TABLE IF NOT EXISTS strokes adds exactly what v1
          # lacks and touches nothing else, so every saved game survives.
          # Anything GREATER than VERSION belongs to a future build we
          # cannot second-guess: rename aside per the prime directive.
          version = read_version
          if version > VERSION
            quarantine('unexpected schema version ' + version.to_s)
            @db = SQLite3::Database.open(@path)
          end
        rescue StandardError => e
          quarantine(e.message)
          @db = SQLite3::Database.open(@path)
        end
      end
      @db.exec(SCHEMA_SQL)
      @db.exec('PRAGMA user_version = ' + VERSION.to_s)
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
