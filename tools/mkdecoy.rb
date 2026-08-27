#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/mkdecoy.rb — builds the M4 decoy: a real, uniquely-solvable Sudoku
# PDF plus the xochitl sidecar files that make it a document in the
# reMarkable's stock library. See M4-HIJACK.md ("The PDF *is* a printable
# puzzle — it just also launches the game") and, for the exact field sets
# below, .superpowers/sdd/M4-HIJACK/xochitl-3.27-format.md — a dump taken
# directly off the owner's device on firmware 3.27.3.0. That dump is this
# file's spec; nothing here is guessed.
#
# Runs on the Mac as part of `bin/redoku install`, with the system CRuby —
# stdlib only, no gems (json and optparse are both stdlib).
#
#   ruby tools/mkdecoy.rb [--out DIR] [--uuid UUID]
#
# Writes into --out (default build/decoy/, gitignored):
#   <uuid>.pdf        the printable puzzle itself
#   <uuid>.metadata   xochitl library-row JSON (visibleName, timestamps…)
#   <uuid>.content    xochitl page-list/viewer-state JSON
#   <uuid>.pagedata   "Blank\n" — one line per PDF page
#   watch.conf        device-absolute paths for `redoku --watch` (Task 3)
#
# A real xochitl document also has an empty <uuid>/ directory (per-page ink
# lands there) and a <uuid>.thumbnails/ directory xochitl populates itself
# on first open. Neither is this tool's job: the dump notes "the trailing
# two are xochitl's to create; a document indexes without them", and the
# installer (Task 4) is what actually places files into xochitl's live
# documents directory — this tool only ever writes to --out.

require "json"
require "optparse"
require "fileutils"

module MkDecoy
  # R9 (M4-HIJACK.md controller ruling): `bin/redoku install` is idempotent
  # and re-runnable. A freshly-generated UUID per run would deposit a
  # SECOND decoy into the library on every install, and uninstall would
  # have nothing fixed to name for deletion. So the decoy's identity is
  # this one constant, not SecureRandom.uuid — override with --uuid only if
  # it ever collides with a real document, which is astronomically
  # unlikely: it is UUIDv4-shaped, so it lives in the same random namespace
  # as the device's own documents (052ba33b-…-style, per the dump) rather
  # than some recognizably-fake pattern that would stand out as a UUID but
  # isn't one.
  DEFAULT_UUID = "c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b"

  # The PDF's one page also needs its own page UUID (xochitl's `pages`
  # array, one entry per page). Fixed for the same reason as DEFAULT_UUID:
  # two installs with the same --uuid must produce byte-identical output,
  # which a fresh SecureRandom.uuid per run would break.
  PAGE_UUID = "a1d4f6e2-8c3b-4f91-8e5a-2b6c9d0e4f71"

  UUID_RE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  # Device-absolute paths (measured facts, not this tool's business logic)
  # that watch.conf (R5) and .content/.metadata need. mkdecoy.rb runs on
  # the Mac, but every path it writes describes where things live on the
  # reMarkable once the installer copies them there.
  DEVICE_XOCHITL_DIR = "/home/root/.local/share/remarkable/xochitl"
  DEVICE_GAME_BIN = "/home/root/redoku/bin/redoku"

  # The library row must read "Sudoku". The dump shows real PDFs carry the
  # extension in visibleName ("Example.pdf", "BAUHAUS NDA.pdf") because
  # that field is literally what the row displays — so the missing ".pdf"
  # here is deliberate, matching the plan's "A document named Sudoku.pdf
  # sits in the stock library… Tapping it opens" (the UX name), not an
  # oversight against the dump's own convention.
  VISIBLE_NAME = "Sudoku"

  # Fixed so a re-run of `bin/redoku install` (idempotent, R9) regenerates
  # byte-identical sidecars instead of stamping a fresh Time.now on every
  # install — xochitl would otherwise see the decoy "edited" on every
  # install, and the whole point of a byte-identical re-run (tested in
  # tools/test/mkdecoy_test.rb) would be lost. The exact instant carries no
  # meaning beyond being fixed; it's midnight UTC on the day M4 was planned
  # (M4-HIJACK.md). The decoy is never opened before install, so
  # createdTime and lastModified are the same instant.
  CREATED_TIME_MS = Time.utc(2026, 8, 26).to_i * 1000
  LAST_MODIFIED_MS = CREATED_TIME_MS

  # --- page geometry -------------------------------------------------
  #
  # 1404x1872 is the reMarkable 2 panel's own pixel resolution (PLAN.md
  # §3), and the dump's customZoomPageWidth/Height confirm xochitl treats
  # a document's "full size" the same way. Setting the PDF's MediaBox to
  # exactly that, in PDF units, makes the viewer's default zoom land at
  # 1:1 — one PDF unit per panel pixel — so the grid lines fall on whole
  # pixels instead of being resampled (blurred) by a fractional scale
  # factor. A page at a real paper size (e.g. US Letter, 612x792) would
  # print correctly but would force xochitl to scale the puzzle to fit,
  # and a fractional scale is exactly what turns a crisp 1px grid line
  # into a blurry 2px one on e-ink.
  PANEL_WIDTH = 1404
  PANEL_HEIGHT = 1872

  # Board geometry mirrors the game's own board (PLAN.md §8: 1260x1260,
  # nine 140px cells, 4px block borders, 1px cell borders) purely so the
  # printed puzzle looks like the one on-screen. Nothing on the device
  # reads these numbers — they matter only to a human eyeballing the PDF.
  BOARD_SIZE = 1260
  CELL = 140
  MARGIN_X = (PANEL_WIDTH - BOARD_SIZE) / 2 # 72, centers the board horizontally
  BOARD_BOTTOM = 260 # leaves room below for margin, and above for the title
  BOARD_TOP = BOARD_BOTTOM + BOARD_SIZE

  TITLE_FONT_SIZE = 96
  TITLE_BASELINE_Y = 1720 # comfortably between BOARD_TOP (1520) and the page top
  DIGIT_FONT_SIZE = 88

  # Standard Adobe Helvetica AFM metrics (public — part of the base-14 font
  # spec every PDF viewer ships, so nothing is embedded). Helvetica's
  # digit glyphs 0-9 share one advance width by design (so numbers line up
  # in tables), so ONE constant centers every digit in the grid; "Sudoku"
  # mixes glyph widths, so its own centering uses the AFM sum for exactly
  # those six letters (S 667, u 556, d 556, o 556, k 500, u 556) instead of
  # carrying a full width table this tool has no other use for.
  HELVETICA_DIGIT_WIDTH_PER_1000 = 556
  HELVETICA_CAP_HEIGHT_PER_1000 = 718
  HELVETICA_SUDOKU_TITLE_WIDTH_PER_1000 = 667 + 556 + 556 + 556 + 500 + 556 # = 3391

  DIGIT_X_OFFSET = (CELL - (DIGIT_FONT_SIZE * HELVETICA_DIGIT_WIDTH_PER_1000 / 1000.0)) / 2.0
  DIGIT_Y_OFFSET = (CELL - (DIGIT_FONT_SIZE * HELVETICA_CAP_HEIGHT_PER_1000 / 1000.0)) / 2.0
  TITLE_X = (PANEL_WIDTH - (TITLE_FONT_SIZE * HELVETICA_SUDOKU_TITLE_WIDTH_PER_1000 / 1000.0)) / 2.0

  # --- the puzzle ------------------------------------------------------
  #
  # A fixed, documented, uniquely-solvable 9x9 sudoku — the classic example
  # puzzle used throughout Wikipedia's Sudoku article (its solution is the
  # familiar 5 3 4 / 6 7 2 / 1 9 8 … grid). '.' is an empty cell. It ships
  # here rather than a call into the game's own generator
  # (mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb) because that
  # code only runs under mruby and cannot be invoked from host CRuby (task
  # brief). Uniqueness is not assumed — tools/test/mkdecoy_test.rb proves
  # it with an independent brute-force solver, because a decoy that is not
  # a real sudoku is exactly the lie M4-HIJACK.md's risk table rejects
  # ("The PDF *is* a printable puzzle — it just also launches the game").
  PUZZLE = [
    "53..7....",
    "6..195...",
    ".98....6.",
    "8...6...3",
    "4..8.3..1",
    "7...2...6",
    ".6....28.",
    "...419..5",
    "....8..79",
  ].freeze

  # Yields [row, col, digit_char] for every given (non-'.') cell.
  def self.each_given(puzzle)
    puzzle.each_with_index do |row_str, row|
      row_str.each_char.with_index do |ch, col|
        next if ch == "."

        yield row, col, ch
      end
    end
  end

  # Row 0 is the puzzle's top row, but PDF y grows upward from the page's
  # bottom, so row 0's cells sit at the top of the board (highest y).
  def self.cell_bottom(row)
    BOARD_BOTTOM + ((8 - row) * CELL)
  end

  # Grid coordinates are all whole pixels by construction (MARGIN_X,
  # BOARD_BOTTOM, CELL are integers); only the centered text positions need
  # decimal places, so this only bothers formatting floats.
  def self.num(x)
    x.is_a?(Integer) ? x.to_s : format("%.2f", x)
  end

  # --- PDF content stream ------------------------------------------------
  #
  # Only ASCII digits and the literal "Sudoku" are ever written as PDF
  # strings here, so no ( ) \ escaping is needed — a general-purpose text
  # writer would need it, this single-purpose one doesn't.
  def self.build_content_stream
    lines = []
    lines << "0 G" # explicit black stroke — already the PDF default, stated for clarity
    lines << "0 g" # explicit black fill, same reason

    # Thin cell-division lines, then thick block/outer borders drawn over
    # them — matters only at the intersections, where the thick stroke
    # should win. PLAN.md §8 draws the game's own board the same way: 1px
    # cell lines read as mere divisions, 4px block/outer lines read as
    # structure, and that distinction is what makes a sudoku grid legible
    # at all on e-ink.
    lines << "q"
    lines << "1 w"
    (0..9).each do |i|
      next if (i % 3).zero?

      x = MARGIN_X + (i * CELL)
      lines << "#{x} #{BOARD_BOTTOM} m #{x} #{BOARD_TOP} l S"
    end
    (0..9).each do |i|
      next if (i % 3).zero?

      y = BOARD_BOTTOM + (i * CELL)
      lines << "#{MARGIN_X} #{y} m #{MARGIN_X + BOARD_SIZE} #{y} l S"
    end
    lines << "Q"

    lines << "q"
    lines << "4 w"
    (0..9).each do |i|
      next unless (i % 3).zero?

      x = MARGIN_X + (i * CELL)
      lines << "#{x} #{BOARD_BOTTOM} m #{x} #{BOARD_TOP} l S"
    end
    (0..9).each do |i|
      next unless (i % 3).zero?

      y = BOARD_BOTTOM + (i * CELL)
      lines << "#{MARGIN_X} #{y} m #{MARGIN_X + BOARD_SIZE} #{y} l S"
    end
    lines << "Q"

    lines << "BT"
    lines << "/F1 #{TITLE_FONT_SIZE} Tf"
    lines << "#{num(TITLE_X)} #{num(TITLE_BASELINE_Y)} Td"
    lines << "(Sudoku) Tj"
    lines << "ET"

    each_given(PUZZLE) do |row, col, digit|
      x = MARGIN_X + (col * CELL) + DIGIT_X_OFFSET
      y = cell_bottom(row) + DIGIT_Y_OFFSET
      lines << "BT"
      lines << "/F1 #{DIGIT_FONT_SIZE} Tf"
      lines << "#{num(x)} #{num(y)} Td"
      lines << "(#{digit}) Tj"
      lines << "ET"
    end

    lines.join("\n")
  end

  # --- the PDF itself, hand-written ---------------------------------------
  #
  # Stdlib-only CRuby means no prawn/rmagick/bundler — the same reason the
  # game's own bitmap "stamps" are hand-rolled. One page, an uncompressed
  # content stream, one base-14 font (Helvetica: no embedding, every PDF
  # viewer ships it), and a hand-built xref table with the byte offsets
  # measured out, not guessed.
  def self.build_pdf
    content = build_content_stream

    objects = {
      1 => "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      2 => "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      3 => "3 0 obj\n<< /Type /Page /Parent 2 0 R " \
           "/MediaBox [0 0 #{PANEL_WIDTH} #{PANEL_HEIGHT}] " \
           "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
      4 => "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
      5 => "5 0 obj\n<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream\nendobj\n",
    }

    header = "%PDF-1.4\n"
    body = +""
    offsets = {}
    pos = header.bytesize
    (1..5).each do |n|
      offsets[n] = pos
      body << objects.fetch(n)
      pos += objects.fetch(n).bytesize
    end

    xref_offset = header.bytesize + body.bytesize
    # Each entry is the ISO 32000-1 canonical 20-byte form: a 10-digit
    # offset, a space, a 5-digit generation, a space, the in-use flag
    # ("n") or free flag ("f"), a space, and a newline. Object 0 is always
    # the free-list head (generation 65535, flag "f") — not a real object,
    # but xref's own "0 6" subsection header counts it, so the table has 6
    # entries for 5 real objects.
    xref = +"xref\n0 6\n"
    xref << xref_entry(0, 65_535, "f")
    (1..5).each { |n| xref << xref_entry(offsets.fetch(n), 0, "n") }

    trailer = "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"

    (header + body + xref + trailer).b
  end

  def self.xref_entry(offset, generation, flag)
    format("%010d %05d %s \n", offset, generation, flag)
  end

  # --- xochitl sidecars ----------------------------------------------------

  def self.metadata_for
    {
      "createdTime" => CREATED_TIME_MS.to_s,
      "lastModified" => LAST_MODIFIED_MS.to_s,
      "lastOpened" => "0", # never opened yet — set by xochitl once tapped
      "lastOpenedPage" => 0,
      "new" => false, # keeps the blue "new" dot off the library row
      "parent" => "", # library root — the dump's example was "trash"; ours must not be
      "pinned" => false,
      "source" => "",
      "type" => "DocumentType",
      "visibleName" => VISIBLE_NAME,
    }
  end

  def self.content_for(pdf_size_bytes)
    {
      "coverPageNumber" => 0,
      "customZoomCenterX" => 0,
      "customZoomCenterY" => PANEL_HEIGHT / 2,
      "customZoomOrientation" => "portrait",
      "customZoomPageHeight" => PANEL_HEIGHT,
      "customZoomPageWidth" => PANEL_WIDTH,
      "customZoomScale" => 1,
      "documentMetadata" => {},
      # Per-document tool memory xochitl writes as the player draws. The
      # decoy is never drawn on before it's tapped, so a fresh document
      # ships this empty — the dump shows its shape only so it's on
      # record, not because a decoy needs to fake prior pen use.
      "extraMetadata" => {},
      "fileType" => "pdf",
      "fontName" => "",
      "formatVersion" => 1, # PDF-backed document on 3.27.3.0 — not the community write-ups' v2/cPages shape
      "lineHeight" => -1,
      "orientation" => "portrait",
      "originalPageCount" => 1,
      "pageCount" => 1,
      "pageTags" => [],
      "pages" => [PAGE_UUID],
      "redirectionPageMap" => [0], # page index -> PDF page index; one page, so [0]
      "sizeInBytes" => pdf_size_bytes.to_s,
      "tags" => [],
      "textAlignment" => "justify",
      "textScale" => 1,
      "zoomMode" => "bestFit",
    }
  end

  # xochitl's own JSON pretty-printer, reverse-engineered from a real dump
  # (xochitl-3.27-format.md), not Ruby's: 4-space indent, keys in ASCII
  # sort order, and empty objects/arrays STILL break across two lines
  # ("{\n    }") instead of collapsing to "{}" the way
  # JSON.pretty_generate would. That mismatch — confirmed against the
  # dump's measured byte counts for both sidecars — is exactly why this is
  # hand-rolled instead of the stdlib pretty-printer.
  def self.render_json(value, level = 0)
    pad = "    " * level
    child_pad = "    " * (level + 1)
    case value
    when Hash
      return "{\n#{pad}}" if value.empty?

      entries = value.keys.sort.map { |k| "#{child_pad}#{k.to_json}: #{render_json(value[k], level + 1)}" }
      "{\n#{entries.join(",\n")}\n#{pad}}"
    when Array
      return "[\n#{pad}]" if value.empty?

      entries = value.map { |v| "#{child_pad}#{render_json(v, level + 1)}" }
      "[\n#{entries.join(",\n")}\n#{pad}]"
    else
      value.to_json
    end
  end

  def self.pagedata
    "Blank\n" # one line per PDF page (the dump: 6 bytes/page, "Blank" for a PDF); one page here
  end

  # R5 (M4-HIJACK.md controller ruling): the watcher (Task 3) reads this
  # instead of scanning xochitl's whole documents directory (295 entries /
  # ~100 documents, measured on the owner's device). mkdecoy.rb runs on
  # the Mac, but these are the paths the installer places things at on the
  # device, so they're written out device-absolute even though nothing
  # here is a device path relative to this tool's own run.
  def self.watch_conf_for(uuid)
    <<~CONF
      # watch.conf — generated by tools/mkdecoy.rb; regenerated on every
      # `bin/redoku install` run. Hand edits will not survive a re-run.
      pdf=#{DEVICE_XOCHITL_DIR}/#{uuid}.pdf
      metadata=#{DEVICE_XOCHITL_DIR}/#{uuid}.metadata
      game=#{DEVICE_GAME_BIN}
    CONF
  end

  # --- writing it all out -------------------------------------------------

  def self.write_all(out_dir, uuid)
    FileUtils.mkdir_p(out_dir)

    pdf_bytes = build_pdf
    pdf_path = File.join(out_dir, "#{uuid}.pdf")
    File.binwrite(pdf_path, pdf_bytes)
    puts "wrote #{pdf_path} (#{pdf_bytes.bytesize} bytes)"

    metadata_path = File.join(out_dir, "#{uuid}.metadata")
    File.write(metadata_path, "#{render_json(metadata_for)}\n")
    puts "wrote #{metadata_path}"

    content_path = File.join(out_dir, "#{uuid}.content")
    File.write(content_path, "#{render_json(content_for(pdf_bytes.bytesize))}\n")
    puts "wrote #{content_path}"

    pagedata_path = File.join(out_dir, "#{uuid}.pagedata")
    File.write(pagedata_path, pagedata)
    puts "wrote #{pagedata_path}"

    watch_conf_path = File.join(out_dir, "watch.conf")
    File.write(watch_conf_path, watch_conf_for(uuid))
    puts "wrote #{watch_conf_path}"
  end

  # Thin CLI wrapper. `run` returns an exit code rather than calling
  # `exit` itself, so tools/test/mkdecoy_test.rb can drive it in-process
  # (including its failure paths) without killing the test process.
  module CLI
    def self.run(argv)
      out_dir = "build/decoy"
      uuid = DEFAULT_UUID
      show_help = false

      parser = OptionParser.new do |o|
        o.banner = "usage: ruby tools/mkdecoy.rb [--out DIR] [--uuid UUID]"
        o.on("--out DIR", "output directory (default: build/decoy)") { |v| out_dir = v }
        o.on("--uuid UUID", "override the decoy's fixed UUID (see MkDecoy::DEFAULT_UUID)") { |v| uuid = v }
        o.on("-h", "--help", "show this help") { show_help = true }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn "mkdecoy: #{e.message}"
        warn parser
        return 1
      end

      if show_help
        puts parser
        return 0
      end

      unless argv.empty?
        warn "mkdecoy: unexpected argument(s): #{argv.join(' ')}"
        warn parser
        return 1
      end

      unless uuid.match?(UUID_RE)
        warn "mkdecoy: --uuid must look like a UUID (8-4-4-4-12 hex), got #{uuid.inspect}"
        return 1
      end

      MkDecoy.write_all(out_dir, uuid)
      0
    end
  end
end

exit(MkDecoy::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
