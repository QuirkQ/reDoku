# Store tests (M3a Task 1): real SQLite files under /tmp, one DB per
# assertion so a failure can never poison its neighbours. The journal sidecar
# is removed alongside the DB, because an assertion that dies mid-transaction
# leaves one behind and the next reopen would recover it into this test's
# business.

def store_db(name)
  '/tmp/redoku_mrbtest_store_' + name + '.db'
end

def remove_store_db(path)
  [path, path + '-journal', path + '-wal'].each do |f|
    File.delete(f) if File.exist?(f)
  end
end

DOTS81 = '.' * 81

def store_game(givens = EASY_81, tier = :easy, achieved = :easy,
               entries = DOTS81)
  { difficulty: tier, achieved_tier: achieved,
    givens: givens, entries: entries, solution: SOLVED_81 }
end

assert('save_autosave round-trips through load and autosave') do
  path = store_db('roundtrip')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  assert_true(id.is_a?(Integer))
  rec = store.load(id)
  assert_false rec.nil?
  assert_equal(id, rec[:id])
  assert_equal(:autosave, rec[:kind])
  assert_equal(:easy, rec[:difficulty])
  assert_equal(:easy, rec[:achieved_tier])
  assert_equal(EASY_81, rec[:givens])
  assert_equal(DOTS81, rec[:entries])
  assert_equal(SOLVED_81, rec[:solution])
  got = store.autosave
  assert_false got.nil?
  assert_equal(rec[:givens], got[:givens])
  assert_equal(rec[:id], got[:id])
  store.close
  remove_store_db(path)
end

assert('save_autosave upserts one singleton row, keeping its id') do
  path = store_db('upsert')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  first = store.save_autosave(store_game)
  second = store.save_autosave(store_game(UNIQUE_81))
  list = store.games
  assert_equal(1, list.size)
  assert_equal(:autosave, list[0][:kind])
  assert_equal(UNIQUE_81, store.autosave[:givens])
  # The id is STABLE across upserts (v2): the stroke journal hangs off it,
  # and a clean-quit refresh of the autosave row must not cascade the whole
  # session's strokes away.
  assert_equal(first, second)
  store.close
  remove_store_db(path)
end

assert('save_manual caps at 50 and refuses past it') do
  path = store_db('cap')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  50.times do |i|
    board = i.even? ? EASY_81 : UNIQUE_81
    id = store.save_manual(store_game(board))
    assert_true(!id.nil?, 'manual save ' + i.to_s + ' refused')
  end
  assert_equal(Redoku::Store::MANUAL_CAP, store.games.size)
  # A nil game — no board on the glass — is refused without touching the cap.
  assert_nil(store.save_manual(nil))
  assert_nil(store.save_manual(store_game(XY_WING_81)))
  assert_equal(Redoku::Store::MANUAL_CAP, store.games.size)
  store.close
  remove_store_db(path)
end

assert('an invalid record is refused before it reaches the database') do
  path = store_db('invalid')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  assert_nil(store.save_autosave('not a game'))
  assert_nil(store.save_manual('not a game'))
  bad_givens = store_game
  bad_givens[:givens] = EASY_81[0, 80]
  assert_nil(store.save_autosave(bad_givens))
  bad_chars = store_game
  # String#sub is not among this build's gems; slice the digit out by hand.
  bad_chars[:solution] = SOLVED_81[0, 40] + 'x' + SOLVED_81[41, 40]
  assert_nil(store.save_autosave(bad_chars))
  bad_tier = store_game(EASY_81, :impossible)
  assert_nil(store.save_autosave(bad_tier))
  assert_equal(0, store.games.size)
  assert_nil(store.autosave)
  store.close
  remove_store_db(path)
end

assert('a corrupt row is skipped, its valid neighbours survive') do
  path = store_db('corruptrow')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  good_id = store.save_manual(store_game)
  store.close

  raw = SQLite3::Database.open(path)
  raw.execute(
    'INSERT INTO games (kind, difficulty, achieved_tier, givens, entries, ' \
    'solution, created_at, updated_at) ' \
    "VALUES ('manual', 'easy', 'easy', 'SHORT', '#{DOTS81}', " \
    "'#{SOLVED_81}', 1, 2)")
  raw.execute(
    'INSERT INTO games (kind, difficulty, achieved_tier, givens, entries, ' \
    'solution, created_at, updated_at) ' \
    "VALUES ('manual', 'legendary', 'easy', '#{EASY_81}', '#{DOTS81}', " \
    "'#{SOLVED_81}', 3, 4)")
  # A bogus KIND cannot be planted at all: the schema's own CHECK constraint
  # refuses the write, which is why validate_row's kind check is
  # belt-and-braces rather than load-bearing.
  raw.close

  store = Redoku::Store.open(path, log: nil)
  assert_equal(1, store.games.size)
  assert_equal(good_id, store.games[0][:id])
  assert_nil(store.load(good_id + 1))
  assert_nil(store.load(good_id + 2))
  assert_false(store.load(good_id).nil?)
  store.close
  remove_store_db(path)
end

assert('a corrupt autosave row reads as none') do
  path = store_db('corruptauto')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  store.save_autosave(store_game)
  store.close
  raw = SQLite3::Database.open(path)
  raw.execute("UPDATE games SET entries = '' WHERE kind = 'autosave'")
  raw.close
  store = Redoku::Store.open(path, log: nil)
  assert_nil(store.autosave)
  store.close
  remove_store_db(path)
end

assert('a corrupt database file is moved aside and replaced') do
  path = store_db('corruptfile')
  remove_store_db(path)
  File.open(path, 'w') { |f| f.write('this was never a database') }
  store = Redoku::Store.open(path, log: nil)
  assert_equal(0, store.games.size)
  # The damaged file survives under .bad-<epoch> rather than vanishing.
  names = Dir.entries(File.dirname(path))
  bad = nil
  prefix = File.basename(path) + '.bad-'
  names.each do |n|
    bad = n if n.start_with?(prefix)
  end
  assert_false(bad.nil?)
  store.save_autosave(store_game)
  assert_false(store.autosave.nil?)
  store.close
  remove_store_db(path)
  File.delete(File.join(File.dirname(path), bad)) unless bad.nil?
end

assert('delete removes exactly one row and reports what it did') do
  path = store_db('delete')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  keep = store.save_manual(store_game)
  gone = store.save_manual(store_game(UNIQUE_81))
  assert_true(store.delete(gone))
  assert_equal(1, store.games.size)
  assert_equal(keep, store.games[0][:id])
  assert_false(store.delete(gone))          # already deleted
  assert_false(store.delete(99_999))        # never existed
  assert_nil(store.load(gone))
  store.close
  remove_store_db(path)
end

assert('saved games persist across close and reopen of the store') do
  path = store_db('reopen')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  auto = store.save_autosave(store_game)
  man = store.save_manual(store_game(UNIQUE_81, :medium, :medium))
  store.close
  assert_true(store.closed?)

  reopened = Redoku::Store.open(path, log: nil)
  assert_equal(UNIQUE_81, reopened.load(man)[:givens])
  assert_equal(auto, reopened.autosave[:id])
  assert_equal(2, reopened.games.size)
  reopened.close
  assert_true(reopened.closed?)
  reopened.close                            # double close is safe
  remove_store_db(path)
end

assert('games lists metadata only, newest first') do
  path = store_db('ordering')
  remove_store_db(path)
  # Rows are planted by hand with pinned timestamps, so the ordering
  # assertion cannot be broken loose by three writes landing inside one
  # second. A Store opens the file first, because the schema has to exist
  # before raw inserts can land in it.
  seeder = Redoku::Store.open(path, log: nil)
  seeder.close
  raw = SQLite3::Database.open(path)
  [['hard', 100], ['expert', 200], ['master', 300]].each do |tier, ts|
    raw.execute(
      'INSERT INTO games (kind, difficulty, achieved_tier, givens, entries, ' \
      "solution, created_at, updated_at) VALUES ('manual', ?, ?, " \
      "'#{EASY_81}', '#{DOTS81}', '#{SOLVED_81}', #{ts}, #{ts})", [tier, tier])
  end
  raw.close

  store = Redoku::Store.open(path, log: nil)
  list = store.games
  assert_equal(3, list.size)
  assert_equal([300, 200, 100],
               list.map { |g| g[:updated_at] })
  assert_equal(:master, list[0][:difficulty])
  assert_equal(:expert, list[1][:difficulty])
  assert_equal(:hard, list[2][:difficulty])
  list.each do |g|
    keys = g.keys.map { |k| k.to_s }.sort
    assert_equal(['achieved_tier', 'difficulty', 'id', 'kind', 'updated_at'],
                 keys)
    assert_equal(:manual, g[:kind])
  end
  store.close
  remove_store_db(path)
end

assert('opening a store creates missing parent directories') do
  base = '/tmp/redoku_mrbtest_store_dirs'
  nested = base + '/a/b'
  path = nested + '/games.db'
  File.delete(path) if File.exist?(path)
  Dir.delete(nested) if Dir.exist?(nested)
  Dir.delete(base + '/a') if Dir.exist?(base + '/a')
  Dir.delete(base) if Dir.exist?(base)

  store = Redoku::Store.open(path, log: nil)
  store.save_autosave(store_game)
  store.close
  assert_true(File.exist?(path))

  Redoku::Store.make_parent_dirs('/tmp')
  Redoku::Store.make_parent_dirs('redoku_rel/a')
  Dir.delete('redoku_rel/a') if Dir.exist?('redoku_rel/a')
  Dir.delete('redoku_rel') if Dir.exist?('redoku_rel')

  cleanup = Redoku::Store.open(path, log: nil)
  cleanup.close
  File.delete(path)
  Dir.delete(nested)
  Dir.delete(base + '/a')
  Dir.delete(base)
end

# --- the stroke journal (Task 6). Same discipline as above: real SQLite in
# tmp files, one DB per assertion.

def stroke_subpaths
  # Two subpaths, as a stroke that left the board and came back records:
  # [[300,400],[320,420],[340,440]] then a gap, then [[360,460],[380,480]].
  [[[300, 400], [320, 420], [340, 440]],
   [[360, 460], [380, 480]]]
end

assert('a v1 database migrates to v2 in place, games intact') do
  path = store_db('migrate_v1')
  remove_store_db(path)
  raw = SQLite3::Database.open(path)
  raw.execute(
    'CREATE TABLE IF NOT EXISTS games (' \
    'id INTEGER PRIMARY KEY AUTOINCREMENT,' \
    "kind TEXT NOT NULL CHECK (kind IN ('autosave','manual'))," \
    'difficulty TEXT NOT NULL, achieved_tier TEXT NOT NULL,' \
    'givens TEXT NOT NULL, entries TEXT NOT NULL, solution TEXT NOT NULL,' \
    'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)')
  raw.execute('CREATE INDEX IF NOT EXISTS idx_games_updated ' \
              'ON games(updated_at DESC)')
  raw.execute("INSERT INTO games (kind, difficulty, achieved_tier, givens, " \
              "entries, solution, created_at, updated_at) VALUES " \
              "('manual', 'easy', 'easy', '#{EASY_81}', '#{DOTS81}', " \
              "'#{SOLVED_81}', 1, 2)")
  raw.execute('PRAGMA user_version = 1')
  raw.close

  store = Redoku::Store.open(path, log: nil)
  list = store.games
  # The saved game survived untouched.
  assert_equal(1, list.size)
  assert_equal(EASY_81, store.load(list[0][:id])[:givens])
  # The new table is there and empty for this game.
  assert_equal([], store.strokes(list[0][:id]))
  store.close

  raw = SQLite3::Database.open(path)
  version = raw.execute('PRAGMA user_version')[0][0]
  raw.close
  assert_equal(Redoku::Store::VERSION, version)
  remove_store_db(path)
end

assert('a future schema version is still renamed aside') do
  path = store_db('future_version')
  remove_store_db(path)
  seeder = Redoku::Store.open(path, log: nil)
  seeder.save_autosave(store_game)
  seeder.close
  raw = SQLite3::Database.open(path)
  raw.execute('PRAGMA user_version = 99')
  raw.close

  store = Redoku::Store.open(path, log: nil)
  assert_equal(0, store.games.size)   # fresh DB took its place
  names = Dir.entries(File.dirname(path))
  bad = nil
  prefix = File.basename(path) + '.bad-'
  names.each { |n| bad = n if n.start_with?(prefix) }
  assert_false(bad.nil?)
  store.close
  remove_store_db(path)
  File.delete(File.join(File.dirname(path), bad)) unless bad.nil?
end

assert('quarantine takes sidecars along and never overwrites an earlier bad copy') do
  path = store_db('quarantine_sidecars')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  store.close
  # Two quarantines driven back to back, each with a database AND a fake hot
  # journal planted beside it — the state a crash mid-write leaves. Whether
  # both land inside one wall-clock second decides whether the second copy
  # is named .bad-<epoch>-2 or carries a fresh epoch; either way BOTH must
  # survive, and no sidecar may remain beside where the fresh db will live.
  dir = File.dirname(path)
  prefix = File.basename(path) + '.bad-'

  File.open(path, 'w') { |f| f.write('first casualty') }
  File.open(path + '-journal', 'w') { |f| f.write('first hot journal') }
  store.send(:quarantine, 'test one')
  File.open(path, 'w') { |f| f.write('second casualty') }
  File.open(path + '-journal', 'w') { |f| f.write('second hot journal') }
  store.send(:quarantine, 'test two')

  names = Dir.entries(dir).select { |n| n.start_with?(prefix) }
  dbs = names.reject { |n|
    n.end_with?('-journal') || n.end_with?('-wal') || n.end_with?('-shm')
  }
  sides = names.select { |n| n.end_with?('-journal') }
  assert_equal(2, dbs.size)     # neither bad copy was overwritten
  assert_equal(2, sides.size)   # both journals travelled with their db
  contents = dbs.map { |n| File.read(File.join(dir, n)) }.sort
  assert_equal(['first casualty', 'second casualty'], contents)
  journals = sides.map { |n| File.read(File.join(dir, n)) }.sort
  assert_equal(['first hot journal', 'second hot journal'], journals)
  # Nothing sidecar-shaped left next to the path a fresh db will take: a hot
  # journal recovered against the NEW file would resurrect rolled-back writes.
  assert_false(File.exist?(path + '-journal'))
  assert_false(File.exist?(path + '-wal'))
  assert_false(File.exist?(path + '-shm'))
  dbs.each { |n| File.delete(File.join(dir, n)) }
  sides.each { |n| File.delete(File.join(dir, n)) }
end

assert('strokes round-trip through journal and read-back, across reopen') do
  path = store_db('stroke_roundtrip')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)

  assert_true(store.journal_stroke(id, 0, 4, stroke_subpaths))
  got = store.strokes(id)
  assert_equal(1, got.size)
  assert_equal(0, got[0][:color])
  assert_equal(4, got[0][:width])
  assert_equal(stroke_subpaths, got[0][:subpaths])

  # Second stroke appends after the first, in order.
  assert_true(store.journal_stroke(id, 96, 2, [[[500, 500], [510, 520]]]))
  got = store.strokes(id)
  assert_equal(2, got.size)
  assert_equal([[[500, 500], [510, 520]]], got[1][:subpaths])

  # And it all survives close/reopen.
  store.close
  reopened = Redoku::Store.open(path, log: nil)
  got = reopened.strokes(id)
  assert_equal(2, got.size)
  assert_equal(stroke_subpaths, got[0][:subpaths])
  assert_equal([[[500, 500], [510, 520]]], got[1][:subpaths])
  reopened.close
  remove_store_db(path)
end

assert('a corrupt stroke row is skipped, its valid neighbours survive') do
  path = store_db('corrupt_stroke')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  store.journal_stroke(id, 0, 4, [[[1, 2], [3, 4]]])
  store.close

  raw = SQLite3::Database.open(path)
  # Garbage where points belong...
  raw.execute("INSERT INTO strokes (game_id, seq, color, width, pts, " \
              "created_at) VALUES (#{id}, 90, 0, 4, 'not points at all', 1)")
  # ...coordinates out of draw_line's span...
  raw.execute("INSERT INTO strokes (game_id, seq, color, width, pts, " \
              "created_at) VALUES (#{id}, 91, 0, 4, '70000,0|0,0', 1)")
  # ...and an absurd brush width.
  raw.execute("INSERT INTO strokes (game_id, seq, color, width, pts, " \
              "created_at) VALUES (#{id}, 92, 0, 0, '1,2', 1)")
  raw.close

  store = Redoku::Store.open(path, log: nil)
  got = store.strokes(id)
  assert_equal(1, got.size)
  assert_equal([[[1, 2], [3, 4]]], got[0][:subpaths])
  store.close
  remove_store_db(path)
end

assert('garbage never reaches the journal; a nil game refuses') do
  path = store_db('stroke_refuse')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  assert_false(store.journal_stroke(nil, 0, 4, stroke_subpaths))
  assert_false(store.journal_stroke(id, 0, 4, []))
  assert_false(store.journal_stroke(id, 0, 4, [[]]))
  assert_false(store.journal_stroke(id, 0, 4, [['x', 1]]))
  assert_false(store.journal_stroke(id, 0, 4, [[[300]]]))
  assert_false(store.journal_stroke(id, 0, 4, 'not subpaths'))
  assert_equal([], store.strokes(id))
  store.close
  remove_store_db(path)
end

assert('the stroke cap drops the oldest strokes and keeps appending') do
  path = store_db('stroke_cap')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil, stroke_cap: 3)
  id = store.save_autosave(store_game)
  4.times do |i|
    assert_true(store.journal_stroke(id, 0, 4, [[[i, i], [i + 1, i + 1]]]))
  end
  got = store.strokes(id)
  assert_equal(3, got.size)
  # The FIRST stroke went; the newest three remain.
  assert_equal([[[1, 1], [2, 2]]], got[0][:subpaths])
  assert_equal([[[3, 3], [4, 4]]], got[2][:subpaths])
  store.close
  remove_store_db(path)
end

assert('clear_strokes empties one game\'s journal and no one else\'s') do
  path = store_db('stroke_clear')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  a = store.save_autosave(store_game)
  b = store.save_manual(store_game(UNIQUE_81))
  store.journal_stroke(a, 0, 4, [[[1, 1], [2, 2]]])
  store.journal_stroke(b, 0, 4, [[[3, 3], [4, 4]]])
  assert_true(store.clear_strokes(a))
  assert_equal([], store.strokes(a))
  assert_equal(1, store.strokes(b).size)
  store.close
  remove_store_db(path)
end

assert('deleting a game takes its strokes with it — the cascade fires') do
  # THE PROOF THE IMPLEMENTATION RELIES ON: foreign key enforcement is OFF
  # by default in SQLite and is turned ON per connection inside SCHEMA_SQL.
  # If that pragma ever stopped reaching the C binding, this assertion is
  # what turns red instead of the device silently growing orphan rows.
  path = store_db('stroke_cascade')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_manual(store_game)
  store.journal_stroke(id, 0, 4, stroke_subpaths)
  assert_equal(1, store.strokes(id).size)
  assert_true(store.delete(id))
  assert_equal([], store.strokes(id))
  store.close
  remove_store_db(path)
end

assert('copy_strokes clones a game\'s ink onto its manual copy') do
  path = store_db('stroke_copy')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  src = store.save_autosave(store_game)
  store.journal_stroke(src, 0, 4, stroke_subpaths)
  store.journal_stroke(src, 96, 2, [[[9, 9], [8, 8]]])
  dst = store.save_manual(store_game)
  assert_true(dst != src)
  assert_true(store.copy_strokes(src, dst))
  got = store.strokes(dst)
  assert_equal(2, got.size)
  assert_equal(stroke_subpaths, got[0][:subpaths])
  assert_equal(96, got[1][:color])
  # The source keeps its own copy.
  assert_equal(2, store.strokes(src).size)
  store.close
  remove_store_db(path)
end

assert('a many-subpath stroke over the point cap round-trips truncated') do
  path = store_db('stroke_truncate')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  cap = Redoku::Store::MAX_STROKE_POINTS
  # App counts SEGMENTS against the cap while the encoded text also carries a
  # head point per subpath, so three subpaths of 1000 points each pass capture
  # and arrive here over the line. The stroke must come back truncated to the
  # cap — a prefix of what was sent — never refused whole.
  subs = []
  n = 0
  3.times do
    sub = []
    1000.times do
      sub << [n % 1000, (n * 7) % 1000]
      n += 1
    end
    subs << sub
  end
  assert_true(n > cap)

  assert_true(store.journal_stroke(id, 0, 4, subs))
  got = store.strokes(id)
  assert_equal(1, got.size)
  back = got[0][:subpaths]
  flat = []
  back.each { |s| s.each { |pt| flat << pt } }
  assert_equal(cap, flat.size)
  want = []
  subs.each { |s| s.each { |pt| want << pt } }
  assert_equal(want[0, cap], flat)          # exactly the first `cap` points
  assert_equal(subs[0], back[0])            # whole subpaths stay whole...
  assert_equal(subs[1], back[1])
  assert_equal(cap - 2000, back[2].size)    # ...and the tail is cut mid-path
  store.close
  remove_store_db(path)
end
