# The decoy document, as xochitl actually stores it

**Date:** 2026-08-27, measured on the owner's reMarkable 2, firmware
**3.27.3.0** (`IMG_VERSION="3.27.3.0"`, Codex Linux 5.7.126).
**Why this document exists:** docs/plans/2026-08-27-m4-hijack.md originally
guessed at the decoy's shape — it called it a "trio" of files in a "line-based
format." Both guesses were wrong, and the correction was made by dumping a
real document's sidecars off the device rather than by reasoning about it
further. The raw capture and the working notes taken from it
(`.superpowers/sdd/M4-HIJACK/device-doc-dump.txt` and
`xochitl-3.27-format.md`) live in this repo's git-ignored SDD workspace and
are deleted when the M4 milestone closes, so this document is what survives
them. `tools/mkdecoy.rb` is the tested, executable form of everything below
(`tools/test/mkdecoy_test.rb` checks its JSON byte-for-byte); read this first
for the shape and the reasoning, that file for the exact bytes.

## A PDF document is five filesystem entries, not three

```
<uuid>.pdf              the document itself
<uuid>.metadata         library entry: name, parent, timestamps
<uuid>.content          page list and viewer state
<uuid>.pagedata         one line per page ("Blank\n" for a PDF page)
<uuid>/                 empty directory — per-page ink (.rm files) lands here
```

`mkdecoy.rb` writes all five. Two more entries exist on a real document but
are xochitl's to create, not the tool's — `<uuid>.thumbnails/` (a rendered
PNG per page, written on first open) is left alone by `mkdecoy.rb` and
cleaned up by `device/uninstall.sh` alongside the rest of the decoy. A
document indexes into the library without either of the xochitl-owned
entries present.

## The sidecars are JSON, not a line-based format

`.metadata` and `.content` are JSON objects, written by xochitl's own Qt
writer (`QJsonDocument`'s indented mode) rather than a flat `key=value`
format. Three things distinguish this from what `JSON.pretty_generate`
(or most other pretty-printers) would produce by default, each visible
directly in the raw capture:

- **4-space indent**, not 2.
- **Keys in ASCII sort order**, not insertion order.
- **Every array and object breaks its brackets onto their own lines, empty
  or not** — an empty one as `{\n    }` / `[\n    ]` rather than collapsing
  to `{}`/`[]`, and a populated array with exactly **one element per line**
  at that level's 4-space step. A 5-element array like `pages` is five
  lines, never packed onto one.

Getting the third point wrong is what actually happened here: the first
pass at `xochitl-3.27-format.md` compressed arrays onto single lines "for
readability" while summarizing the raw capture, which made a Task 2 review
flag the array formatting as an unverified guess. The code was already
right — `mkdecoy.rb`'s `render_json` was written against the raw capture
directly — only the summary document was wrong, and cost a review round
before that was sorted out. The lesson that earned its own line in the
ledger: a summary handed to an implementer or reviewer is trusted
absolutely, so compressing measured data inside one is a real defect, not a
style choice.

Timestamps are **milliseconds since epoch, as strings** (`"1780567685687"`,
not a JSON number). Page counts and scale factors are plain numbers.

## `<uuid>.metadata`

```json
{
    "createdTime": "1780567685687",
    "lastModified": "1780568050637",
    "lastOpened": "0",
    "lastOpenedPage": 0,
    "new": false,
    "parent": "",
    "pinned": false,
    "source": "",
    "type": "DocumentType",
    "visibleName": "Example.pdf"
}
```

- `parent`: `""` is the library root; `"trash"` is the trash; anything else
  is a collection uuid. Two real documents were read to pin this — one in
  the trash (`parent: "trash"`, its timestamps are what the raw capture
  shows verbatim) and one at the library root (`parent: ""`, read
  separately because the first one is not what a decoy wants).
- `visibleName` on a real PDF **includes the `.pdf` extension**, because
  that field is literally what the library row displays. The decoy's own
  `visibleName` deliberately omits it (`"Sudoku"`, not `"Sudoku.pdf"`) to
  match the UX the plan asks for — that is a choice, not an oversight
  against the device's own convention.
- `lastOpened: "0"` / `lastOpenedPage: 0` means never opened; `new: false`
  keeps the blue "new" dot off a document that should look established.
- No `deleted`, `synced`, `version` or `metadatamodified` keys on 3.27.3.0 —
  older community write-ups list them; this firmware does not write them.
- `lastOpened` is the field the watcher's `lastopened` trigger mode reads
  (`mrbgems/mruby-redoku/mrblib/redoku/watcher.rb`), and the device proved
  it is written at open time but the sidecar is flushed to disk lazily —
  see docs/plans/2026-08-27-m4-hijack.md's "the trigger, measured" section for
  that evidence and what it decided.

## `<uuid>.content`

```json
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
        "LastActiveTool": "primary",
        "LastBallpointv2Color": "Black",
        "LastBallpointv2Size": "2",
        "LastEraserColor": "Black",
        "LastEraserSize": "3",
        "LastEraserTool": "Eraser",
        "LastPen": "Ballpointv2",
        "LastPencilv2Color": "Black",
        "LastPencilv2Size": "2",
        "LastSelectionToolColor": "Black",
        "LastSelectionToolSize": "2",
        "SecondaryHighlighterv2Color": "HighlighterYellow",
        "SecondaryHighlighterv2Size": "1",
        "SecondaryPen": "Highlighterv2"
    },
    "fileType": "pdf",
    "fontName": "",
    "formatVersion": 1,
    "lineHeight": -1,
    "orientation": "portrait",
    "originalPageCount": 5,
    "pageCount": 5,
    "pageTags": [
    ],
    "pages": [
        "b17ac276-513e-4c51-a6d1-6af8690c9a57",
        "..."
    ],
    "redirectionPageMap": [
        0,
        "..."
    ],
    "sizeInBytes": "156795",
    "tags": [
    ],
    "textAlignment": "justify",
    "textScale": 1,
    "zoomMode": "bestFit"
}
```

(The captured document had 5 pages; the array bodies above are elided for
length — see the raw capture's own field for the real shape, or
`mkdecoy.rb`'s `content_for`, which builds the one-page equivalent the decoy
actually ships.)

- `formatVersion` is **1** on 3.27.3.0 for a PDF-backed document, not the
  `formatVersion: 2` / `cPages` shape some community write-ups describe for
  other firmware lines.
- `pages` holds one fresh page UUID per PDF page; `redirectionPageMap` maps
  page index to PDF page index, so the decoy's one-page document is
  `pages: ["<page-uuid>"]` and `redirectionPageMap: [0]`.
- `sizeInBytes` is a **string**, and is the size of the `.pdf` file.
- `extraMetadata` is xochitl's own per-document tool memory, written as the
  player draws. It is shown here in full only so its shape is on record — a
  fresh, never-drawn-on document (the decoy, always) ships it as `{}`.
- The four `customZoom*` numbers describe a 1404×1872 portrait page, which
  is the device panel's own pixel geometry (PLAN.md §3). The decoy's PDF
  page box uses the same numbers so the printed puzzle fills the screen at
  1:1 with no viewer-side rescaling — see `mkdecoy.rb`'s page-geometry
  comment for why that matters on e-ink specifically.

## `<uuid>.pagedata`

Six bytes per page: `Blank\n`. Present on every real document, including a
PDF, so the decoy ships one line per page.

## What this is not the place for

The reasoning behind the decoy's own choices — the fixed UUID constant, the
JSON grammar's exact byte output, the PDF content-stream construction, the
page geometry math — is already carried as comments in `tools/mkdecoy.rb`
next to the code it explains, and is not repeated here. This document exists
to answer "what does xochitl actually expect on 3.27.3.0, and how do we
know," which is the part that would otherwise vanish with the workspace.
