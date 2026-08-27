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

# Integers ABOVE the word-boxing immediate range must survive a round-trip.
# mruby 4.0.0 defaults to MRB_WORD_BOXING (include/mrbconf.h), which packs an
# Integer into the mrb_value word behind a 1-bit tag: the immediate range is
# INT32_MAX >> 1 (1_073_741_823) on the 32-bit armv7 device and INT64_MAX >> 1
# on the 64-bit host. Anything past that line is a HEAP RInteger, and the
# FIXNUM accessors (mrb_fixnum / mrb_fixnum_value) read and write that word
# directly — which on a boxed value is a POINTER, not a number. A Unix epoch
# (~1.79e9) sits past the device's line, which is how saved games came back
# stamped 1970: the binding wrote half a heap address into created_at /
# updated_at. The correct accessors are mrb_integer / mrb_int_value.
#
# The boundary is DERIVED from Integer#size rather than hardcoded, so this
# exercises the same defect on both builds. Hardcoding the device's 2**30
# would leave the host asserting nothing: on a 64-bit build every epoch fits
# as an immediate, which is exactly why the host suite missed this for a
# whole milestone.
assert('integers beyond the word-boxing immediate range round-trip') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.exec('CREATE TABLE t (v INTEGER NOT NULL)')

  # MRB_FIXNUM_MAX + 1: the first value mruby has to put on the heap. Both
  # bounds are built by addition from it so nothing here overflows mrb_int
  # while being computed.
  boxed = 1 << (1.size * 8 - 2)
  int_max = boxed + (boxed - 1)

  [0, 1, -1,
   boxed - 1, boxed, boxed + 1, int_max,
   -boxed, -boxed - 1, -int_max - 1,
   1787821174 # a 2026 Unix epoch: the value the bug was reported against
  ].each do |v|
    db.execute('INSERT INTO t (v) VALUES (?)', [v])
    back = db.execute('SELECT v FROM t ORDER BY rowid DESC LIMIT 1')[0][0]
    assert_equal v, back
  end
  db.close
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
