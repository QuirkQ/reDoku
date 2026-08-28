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
# Both word sizes' boundaries are asserted, so the host exercises the
# heap-boxed path at its own 2**62 line instead of asserting nothing: on a
# 64-bit build every epoch fits as an immediate, which is exactly why the host
# suite missed this for a whole milestone.
assert('integers beyond the word-boxing immediate range round-trip') do
  spike_remove_db
  db = SQLite3::Database.open(SPIKE_DB)
  db.exec('CREATE TABLE t (v INTEGER NOT NULL)')

  # MRB_FIXNUM_MAX + 1 on each word size: the first value mruby has to put on
  # the heap. Both bounds are built by addition from it so nothing here
  # overflows mrb_int while being computed.
  #
  # Spelled out rather than derived. `1.size` was the derivation and it is a
  # CRuby-ism: mrbtest has no Integer#size, so this assertion crashed with
  # `undefined method 'size' for Integer` before it tested anything at all.
  # (The plain `mruby` binary *does* answer 1.size, which is what made the
  # derivation look safe.) Deriving it by doubling until the shift turns
  # negative does not work either — mruby does not wrap on shift overflow,
  # so that loop never terminates.
  #
  # So: 2**62 is this 64-bit host's boxing boundary and is the one that
  # exercises the heap-boxed path here; 2**30 is the armv7 device's, and is
  # the line a 2026 epoch (~1.79e9) sits past — the reason saved games came
  # back stamped 1970. mrbtest only ever runs on the host (the rm2 target is
  # build_mrbtest_lib_only), so the 2**62 literals never have to fit in a
  # 32-bit mrb_int.
  boxed = 1 << 62
  int_max = boxed + (boxed - 1)
  device_boxed = 1 << 30

  [0, 1, -1,
   boxed - 1, boxed, boxed + 1, int_max,
   -boxed, -boxed - 1, -int_max - 1,
   device_boxed - 1, device_boxed, device_boxed + 1, -device_boxed - 1,
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
