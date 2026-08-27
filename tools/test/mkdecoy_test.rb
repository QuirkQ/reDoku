#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/test/mkdecoy_test.rb — asserts tools/mkdecoy.rb's output against
# the field sets, types and byte format measured off a real reMarkable 2 on
# firmware 3.27.3.0 (.superpowers/sdd/M4-HIJACK/xochitl-3.27-format.md) and
# the M4-HIJACK.md task-2 brief. No test framework — see support.rb.
#
#   ruby tools/test/mkdecoy_test.rb     (directly, CRuby stdlib only)
#   make test-tools                     (same thing, inside the build image)

require "json"
require "tmpdir"
require_relative "support"
require_relative "../mkdecoy"

# A valid UUIDv4-shaped literal, deliberately NOT MkDecoy::DEFAULT_UUID —
# the test drives --uuid explicitly so it never depends on (or risks
# colliding output with) the shipped constant.
TEST_UUID = "11111111-2222-4333-8444-555555555555"

def build_decoy(uuid, dir)
  code = MkDecoy::CLI.run(["--out", dir, "--uuid", uuid])
  raise "mkdecoy exited #{code} for uuid=#{uuid} dir=#{dir}" unless code.zero?
end

def read_watch_conf(path)
  File.readlines(path).each_with_object({}) do |line, kv|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    k, v = line.split("=", 2)
    kv[k] = v
  end
end

# --- brute-force uniqueness check for MkDecoy::PUZZLE -----------------
# Independent of the mruby sudoku engine (mrbgems/mruby-redoku/mrblib/
# redoku/sudoku/) on purpose — that code only runs under mruby and cannot
# be called from host CRuby (task brief). A puzzle that is not really
# uniquely solvable would be exactly the lie PLAN.md's M4 risk table
# rejects ("The PDF *is* a printable puzzle — it just also launches the
# game"), so this is proven here, not assumed.

def placeable?(grid, row, col, v)
  return false if grid[row].include?(v)
  return false if grid.any? { |r| r[col] == v }

  br = (row / 3) * 3
  bc = (col / 3) * 3
  (br...br + 3).each do |r|
    (bc...bc + 3).each do |c|
      return false if grid[r][c] == v
    end
  end
  true
end

def find_empty(grid)
  9.times do |r|
    9.times do |c|
      return [r, c] if grid[r][c].zero?
    end
  end
  nil
end

# Collects up to `cap` solutions into `solutions` and stops early once the
# cap is hit — a puzzle is unique iff exactly 1 comes back at cap=2.
def solve_all(grid, cap, solutions)
  row, col = find_empty(grid)
  if row.nil?
    solutions << grid.map(&:dup)
    return solutions
  end

  (1..9).each do |v|
    next unless placeable?(grid, row, col, v)

    grid[row][col] = v
    solve_all(grid, cap, solutions)
    grid[row][col] = 0
    return solutions if solutions.length >= cap
  end
  solutions
end

Support.check("MkDecoy::PUZZLE is 9 rows of 9 characters") do
  MkDecoy::PUZZLE.length == 9 && MkDecoy::PUZZLE.all? { |row| row.length == 9 }
end

puzzle_grid = MkDecoy::PUZZLE.map { |row| row.each_char.map { |ch| ch == "." ? 0 : ch.to_i } }
solutions = solve_all(puzzle_grid.map(&:dup), 2, [])

Support.check("embedded puzzle is uniquely solvable (brute force finds exactly 1 solution)") do
  solutions.length == 1
end

Support.check("embedded puzzle is not already fully solved (it has empty cells)") do
  puzzle_grid.flatten.include?(0)
end

# --- one full generate-and-inspect run ----------------------------------

Dir.mktmpdir("mkdecoy-test") do |dir|
  build_decoy(TEST_UUID, dir)

  pdf_path = File.join(dir, "#{TEST_UUID}.pdf")
  metadata_path = File.join(dir, "#{TEST_UUID}.metadata")
  content_path = File.join(dir, "#{TEST_UUID}.content")
  pagedata_path = File.join(dir, "#{TEST_UUID}.pagedata")
  watch_conf_path = File.join(dir, "watch.conf")

  Support.check("writes all five files") do
    [pdf_path, metadata_path, content_path, pagedata_path, watch_conf_path]
      .all? { |p| File.exist?(p) }
  end

  metadata = JSON.parse(File.read(metadata_path))
  content = JSON.parse(File.read(content_path))
  pdf_bytes = File.binread(pdf_path)

  expected_metadata_fields = %w[
    createdTime lastModified lastOpened lastOpenedPage new parent pinned
    source type visibleName
  ].sort

  Support.check("metadata field set matches the 3.27 dump, key for key") do
    metadata.keys.sort == expected_metadata_fields
  end

  expected_content_fields = %w[
    coverPageNumber customZoomCenterX customZoomCenterY
    customZoomOrientation customZoomPageHeight customZoomPageWidth
    customZoomScale documentMetadata extraMetadata fileType fontName
    formatVersion lineHeight orientation originalPageCount pageCount
    pageTags pages redirectionPageMap sizeInBytes tags textAlignment
    textScale zoomMode
  ].sort

  Support.check("content field set matches the 3.27 dump, key for key") do
    content.keys.sort == expected_content_fields
  end

  # Beyond field-set equality (JSON.parse doesn't see indentation or key
  # order): the RAW BYTES must match the device's own JSON grammar exactly
  # — 4-space indent, ASCII key order, empty {}/[] broken across two lines,
  # a populated array with one element per line (never packed onto one
  # line), trailing newline. This whitespace is transcribed directly from
  # .superpowers/sdd/M4-HIJACK/device-doc-dump.txt — the raw `cat` capture
  # off the device, not the xochitl-3.27-format.md summary of it (that
  # summary once compressed its example arrays onto single lines for
  # readability without saying so, which is exactly the kind of drift a
  # byte-exact expectation sourced from the raw capture cannot repeat).
  # Built with this run's own uuid/pdf-size substituted in, so a formatting
  # regression (Ruby's JSON.pretty_generate collapsing "{}" onto one line,
  # 2-space indent, insertion-order keys…) fails loudly instead of hiding
  # behind a parsed-equality check that can't see it.
  expected_metadata_text = <<~JSON
    {
        "createdTime": "#{MkDecoy::CREATED_TIME_MS}",
        "lastModified": "#{MkDecoy::LAST_MODIFIED_MS}",
        "lastOpened": "0",
        "lastOpenedPage": 0,
        "new": false,
        "parent": "",
        "pinned": false,
        "source": "",
        "type": "DocumentType",
        "visibleName": "Sudoku"
    }
  JSON

  Support.check("metadata file bytes match the device's JSON grammar exactly") do
    File.read(metadata_path) == expected_metadata_text
  end

  expected_content_text = <<~JSON
    {
        "coverPageNumber": 0,
        "customZoomCenterX": 0,
        "customZoomCenterY": 936,
        "customZoomOrientation": "portrait",
        "customZoomPageHeight": 1872,
        "customZoomPageWidth": 1404,
        "customZoomScale": 1,
        "documentMetadata": {
        },
        "extraMetadata": {
        },
        "fileType": "pdf",
        "fontName": "",
        "formatVersion": 1,
        "lineHeight": -1,
        "orientation": "portrait",
        "originalPageCount": 1,
        "pageCount": 1,
        "pageTags": [
        ],
        "pages": [
            "#{MkDecoy::PAGE_UUID}"
        ],
        "redirectionPageMap": [
            0
        ],
        "sizeInBytes": "#{pdf_bytes.bytesize}",
        "tags": [
        ],
        "textAlignment": "justify",
        "textScale": 1,
        "zoomMode": "bestFit"
    }
  JSON

  Support.check("content file bytes match the device's JSON grammar exactly") do
    File.read(content_path) == expected_content_text
  end

  Support.check("metadata.visibleName is the bare library row name (no .pdf)") do
    metadata["visibleName"] == "Sudoku"
  end

  Support.check("metadata.parent is the library root, not trash") do
    metadata["parent"] == ""
  end

  Support.check("metadata.type is DocumentType") do
    metadata["type"] == "DocumentType"
  end

  Support.check("metadata.new is false (no blue 'new' dot)") do
    metadata["new"] == false
  end

  Support.check("metadata timestamps are millisecond values AS STRINGS") do
    metadata["createdTime"].is_a?(String) && metadata["createdTime"].match?(/\A\d+\z/) &&
      metadata["lastModified"].is_a?(String) && metadata["lastModified"].match?(/\A\d+\z/)
  end

  Support.check("metadata timestamps come from the fixed constants, not Time.now") do
    metadata["createdTime"] == MkDecoy::CREATED_TIME_MS.to_s &&
      metadata["lastModified"] == MkDecoy::LAST_MODIFIED_MS.to_s
  end

  Support.check("content.formatVersion is the integer 1") do
    content["formatVersion"] == 1 && content["formatVersion"].is_a?(Integer)
  end

  Support.check("content.fileType is pdf") do
    content["fileType"] == "pdf"
  end

  Support.check("content.documentMetadata and extraMetadata are empty objects") do
    content["documentMetadata"] == {} && content["extraMetadata"] == {}
  end

  Support.check("content.sizeInBytes equals the real PDF byte size, as a string") do
    content["sizeInBytes"] == pdf_bytes.bytesize.to_s
  end

  Support.check("content.pages has exactly one page uuid") do
    content["pages"].is_a?(Array) && content["pages"].length == 1 &&
      content["pages"].first.is_a?(String) && !content["pages"].first.empty?
  end

  Support.check("content.redirectionPageMap is [0]") do
    content["redirectionPageMap"] == [0]
  end

  Support.check("content.pageCount and originalPageCount are both 1") do
    content["pageCount"] == 1 && content["originalPageCount"] == 1
  end

  Support.check(".pagedata is exactly 'Blank\\n' (one page)") do
    File.read(pagedata_path) == "Blank\n"
  end

  Support.check("PDF MediaBox is 0 0 1404 1872 (1:1 with the panel, PLAN.md §3)") do
    pdf_bytes.include?("/MediaBox [0 0 1404 1872]")
  end

  # --- xref offsets actually point at the objects they claim ------------

  xref_match = pdf_bytes.match(/startxref\r?\n(\d+)\r?\n%%EOF/)
  Support.check("PDF ends with startxref + a byte offset + %%EOF") { !xref_match.nil? }

  if xref_match
    xref_offset = xref_match[1].to_i

    Support.check("the byte at the startxref offset begins the xref table") do
      pdf_bytes[xref_offset, 5] == "xref\n"
    end

    xref_lines = pdf_bytes[xref_offset..].lines
    # xref_lines[0] = "xref\n", [1] = "0 6\n", [2..7] = the 6 entries.
    entry_lines = xref_lines[2, 6]

    Support.check("xref subsection header claims 6 entries (object 0 + objects 1..5)") do
      xref_lines[1] == "0 6\n"
    end

    Support.check("xref table has 6 entry lines") do
      !entry_lines.nil? && entry_lines.length == 6
    end

    if entry_lines
      # Object 0 is the free-list head ("f"), not a real object — objects
      # 1..5 are Catalog, Pages, Page, Font, Contents (in that order).
      (1..5).each do |obj_num|
        line = entry_lines[obj_num]
        m = line && line.match(/\A(\d{10}) (\d{5}) n /)
        Support.check("xref entry for object #{obj_num} parses as in-use") { !m.nil? }
        next unless m

        offset = m[1].to_i
        expected_prefix = "#{obj_num} 0 obj"
        Support.check("xref offset for object #{obj_num} points at '#{expected_prefix}'") do
          pdf_bytes[offset, expected_prefix.bytesize] == expected_prefix
        end
      end
    end
  end

  Support.check("watch.conf has the three required keys with device-absolute paths") do
    kv = read_watch_conf(watch_conf_path)
    kv["pdf"] == "/home/root/.local/share/remarkable/xochitl/#{TEST_UUID}.pdf" &&
      kv["metadata"] == "/home/root/.local/share/remarkable/xochitl/#{TEST_UUID}.metadata" &&
      kv["game"] == "/home/root/redoku/bin/redoku"
  end
end

# --- determinism: the idempotent install depends on this ---------------

Dir.mktmpdir("mkdecoy-det-a") do |dir_a|
  Dir.mktmpdir("mkdecoy-det-b") do |dir_b|
    build_decoy(TEST_UUID, dir_a)
    build_decoy(TEST_UUID, dir_b)

    names = ["#{TEST_UUID}.pdf", "#{TEST_UUID}.metadata", "#{TEST_UUID}.content",
             "#{TEST_UUID}.pagedata", "watch.conf"]

    Support.check("two runs with the same --uuid produce byte-identical files") do
      names.all? { |name| File.binread(File.join(dir_a, name)) == File.binread(File.join(dir_b, name)) }
    end
  end
end

# --- argument handling ---------------------------------------------------

Support.check("a bad --uuid exits non-zero and touches no files") do
  Dir.mktmpdir("mkdecoy-bad-uuid") do |dir|
    code = MkDecoy::CLI.run(["--out", dir, "--uuid", "not-a-uuid"])
    code != 0 && Dir.empty?(dir)
  end
end

Support.check("an unknown option exits non-zero") do
  MkDecoy::CLI.run(["--bogus"]) != 0
end

Support.check("the default UUID constant is UUIDv4-shaped") do
  MkDecoy::DEFAULT_UUID.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
end

Support.report_and_exit
