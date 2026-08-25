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

assert('save_autosave upserts one singleton row') do
  path = store_db('upsert')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  first = store.save_autosave(store_game)
  second = store.save_autosave(store_game(UNIQUE_81))
  list = store.games
  assert_equal(1, list.size)
  assert_equal(:autosave, list[0][:kind])
  assert_equal(UNIQUE_81, store.autosave[:givens])
  assert_true(second != first)
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
