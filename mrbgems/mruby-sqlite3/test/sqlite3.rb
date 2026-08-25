# Spike tests for M3a Task 0 (GO/NO-GO gate): prove SQLite + the vendored
# binding work against mruby 4.0.0 under make test. Throwaway quality.

SPIKE_DB = '/tmp/redoku_mrbtest_sqlite3_spike.db'

def spike_remove_db
  File.delete(SPIKE_DB) if File.exist?(SPIKE_DB)
end

assert('SQLite3::Database opens and runs DDL') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)')
  # exec returns the changed-row count of the last statement.
  assert_equal 1, db.exec('INSERT INTO t (name) VALUES (?)', ['a'])
  spike_remove_db
end

assert('execute returns bound rows as an array of arrays') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)')
  db.execute('INSERT INTO t (name) VALUES (?)', ['hello'])
  id = db.last_insert_rowid
  assert_equal 1, id
  rows = db.execute('SELECT id, name FROM t WHERE name = ?', ['hello'])
  assert_equal [[id, 'hello']], rows
  # Multiple binds and multiple rows come back in order.
  db.execute('INSERT INTO t (name) VALUES (?)', ['world'])
  rows = db.execute('SELECT name FROM t ORDER BY id')
  assert_equal [['hello'], ['world']], rows
  db.close
  spike_remove_db
end

assert('close releases the database') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.close
  assert_true db.closed?
  # Double close must not raise.
  db.close
  spike_remove_db
end

assert('data persists across close and reopen of the same file') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)')
  db.execute('INSERT INTO t (name) VALUES (?)', ['survivor'])
  id = db.last_insert_rowid
  db.close

  reopened = SQLite3::Database.open(SPIKE_DB)
  rows = reopened.execute('SELECT id, name FROM t WHERE id = ?', [id])
  assert_equal [[id, 'survivor']], rows
  reopened.close
  spike_remove_db
end

assert('SQL errors raise RuntimeError') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  raised = false
  begin
    db.exec('CREATE TABLE')
  rescue RuntimeError
    raised = true
  end
  assert_true raised
  db.close
  spike_remove_db
end
