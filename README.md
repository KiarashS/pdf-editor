# PDF Editor

A native macOS PDF editor written in Swift with SwiftUI and PDFKit. The feature set follows UPDF: reading, annotating, editing, page organization, forms, OCR, conversion, redaction, protection, batch processing, comparison and an AI assistant (Claude).

Requires macOS 14 Sonoma or later. Building needs Xcode 16 or later.

## Download

Every push to `main` builds the app, runs the tests and publishes a disk image on the [Releases](https://github.com/KiarashS/pdf-editor/releases) page, versioned `1.0.<build number>`. Open the .dmg and drag PDF Editor to Applications. The build is ad-hoc signed and not notarized, so the first time you open it, right-click the app and choose Open (or run `xattr -dr com.apple.quarantine "/Applications/PDF Editor.app"`).

## Building

```sh
# Command line: builds "build/PDF Editor.app" (ad-hoc signed, not sandboxed)
scripts/build-app.sh

# Disk image with an Applications shortcut: build/PDF-Editor-<version>.dmg
scripts/make-dmg.sh

# Run the unit tests for the core library
swift test

# Xcode project with App Sandbox and entitlements (needs XcodeGen: brew install xcodegen)
xcodegen generate && open PDFEditor.xcodeproj
```

The icon is drawn by `scripts/make_icon.py` (needs Pillow), which writes `Support/AppIcon.png` and the asset catalog; the build script converts it to `AppIcon.icns` with `iconutil`.

`swift run PDFEditor` also launches the app, but without a bundle macOS will not register it for PDF files, so use the build script for day-to-day use.

## Features

### Reading
- Single page, continuous, two-up and book layouts; zoom presets, fit page and fit width
- Page thumbnails, bookmarks (add, rename, delete, jump), comment list with filtering, and full-text search with highlighted results
- Reading themes (Night, Sepia, Eye Care), read aloud with the system voice, full-screen slideshow (arrow keys, space, Esc)

### Comment mode
- Highlight, underline and strikethrough on selected text (one annotation per line, with QuadPoints so other viewers render them)
- Pen and marker strokes, smoothed with Ramer–Douglas–Peucker
- Text boxes, sticky notes, rectangles, ovals, lines, arrows; colors, fill, line width, dash and opacity
- Standard stamps (Approved, Confidential, Draft, ...) and custom text or date stamps
- Signatures: draw, type in a script font, or import an image; saved in Application Support and placed with one click
- Distance measurement in pt, in, cm or mm with a drawing scale
- Select, move, resize (handles, Shift keeps aspect), nudge with arrow keys, duplicate, delete, undo/redo everything
- Flatten annotations into the page

### Edit mode
- Edit existing text: click a line, change the words, font, size and color. See "How text editing works" below.
- Add text, add images (movable and resizable), add links to web pages or to pages in the document
- Crop pages by dragging a box or with margins; automatic content-margin detection
- Watermarks (text or image, tiled or positioned, rotation, opacity, above or behind content)
- Headers, footers and Bates numbering with `{page}`, `{pages}`, `{date}`, `{bates}`, `{filename}` and `{title}` tokens
- Page backgrounds (color or image)

### Pages mode
- Thumbnail grid with click, ⌘-click and ⇧-click selection and drag-to-reorder
- Insert blank pages or pages from PDF, image and text files (drop files on the grid), duplicate, extract, replace, reverse, rotate, delete
- Split by every N pages, by number of files, by page ranges, or at top-level bookmarks

### Forms
- Fill AcroForm fields directly on the page
- Create text fields, text areas, checkboxes, radio buttons, dropdowns, list boxes, reset buttons and signature fields
- Detect blanks (`____` runs and `[ ]` boxes) and turn them into fields
- Export field values as JSON or CSV, import JSON, reset the form

### Redact and protect
- Mark text or areas for redaction, or find and mark every occurrence of a phrase, email address, phone number, SSN or card number
- Applying redactions rasterizes the affected pages at 200 dpi with the marked areas painted over, so no text, vector or image data remains underneath. OCR then restores a text layer for the unredacted parts.
- Open password, permissions password, and print/copy restrictions (applied on save)

### Tools
- OCR with the Vision framework: adds an invisible, selectable text layer to scanned pages, with language selection
- Convert to Word (.docx), Excel (.xlsx), PowerPoint (.pptx), RTF, OpenDocument, HTML, Markdown, CSV, plain text, PNG/JPEG/TIFF/HEIC images, or an image-only PDF; optional OCR before conversion
- Create PDFs from images, the clipboard, text documents, or by combining several files (File > New From, File > Combine Files)
- Compress: an optimized mode that keeps text, or rasterized modes at 150 or 96 dpi with optional OCR; shows an estimated size first
- Batch processing window: convert, compress, add or remove passwords, watermark, OCR, flatten, number pages, combine or print many files
- Compare two PDFs: word-level differences per page (Myers diff), listed and highlighted in side-by-side views
- Edit document properties (title, author, subject, keywords)

### AI assistant
Summaries, key points, explanations, translation into 15 languages, and free-form chat about the open document, using the Claude Messages API with streaming. The document goes to the API as a PDF (or as extracted text when it is over 600 pages or 30 MB), with a cache breakpoint so follow-up questions reuse it. If text is selected, the request is about the selection. Replies can be copied or added to the page as a note.

Add an Anthropic API key in Settings > AI Assistant (it is stored in the keychain) or set `ANTHROPIC_API_KEY`. The default model is `claude-opus-5-5` with adaptive thinking and `medium` effort; both can be changed in Settings. Requests opt into server-side refusal fallback (`fallbacks: "default"`), so a declined request is retried on Anthropic's recommended fallback model within the same call.

## How text editing works

PDFKit has no API for rewriting a page's content stream, so "Edit Text" works in two steps. While you edit, the change is an overlay that covers the original line with a sampled background color and draws the new text on top; you can move it or edit it again. When the document is saved, the overlay is drawn into the page content as real, searchable text. The original glyphs are still in the page's content stream underneath the cover, so copying text from that region can return both versions. For removing text so that it cannot be recovered, use redaction instead.

Images placed with Add Image and image signatures work the same way: they are movable overlays during editing and become page content when saved.

## Project layout

```
Sources/PDFEditorCore   PDF logic with no UI: page compositing, decorations, redaction,
                        OCR, conversion (including minimal XLSX/PPTX writers), forms,
                        diff, batch processing, Claude client
Sources/PDFEditor       SwiftUI app: document type, EditorController (all edits, with undo),
                        PDFView subclass and tool overlay, sidebars, inspector, sheets
Tests/PDFEditorCoreTests  XCTest suite for the core library
Support/                Info.plist, sandbox entitlements, app icon and asset catalog
scripts/                App bundle, disk image and icon scripts
project.yml             XcodeGen spec
```

`EditorController` performs every change and registers an undo action for it, which is also how SwiftUI's `DocumentGroup` learns that the document has unsaved changes. Operations that rewrite pages (watermarks, OCR, redaction, flattening) build a new page with `CGContext.drawPDFPage`, which keeps the original text and vector content, move the annotations across, and repoint bookmarks and links at the new page.

## Not supported

- Certificate-based digital signatures (PDFKit cannot create them); signatures here are visual
- Reflowing paragraphs when edited text is longer than the original line
- File attachment annotations and PDF/A export
