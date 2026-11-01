# Paperdesk

An offline PDF reader, annotation and study app for macOS 14+ and iOS/iPadOS 17+.

## Start

The ready-to-run Mac app is `../Paperdesk.app` beside this project folder. Open it, then import a PDF or choose **Explore a sample**. To develop the app, open `Paperdesk.xcodeproj`, select Paperdesk and My Mac, and press Command-R.

## Interface

A cover-based library, floating reader dock and shared Liquid Glass controls keep navigation consistent. The palette adapts to light, dark and increased contrast. Glass falls back to system materials on older systems, and opaque surfaces with Reduce Transparency. Document content remains on a solid readable surface.

## Read, write and organize

- Import PDFs into a local library; originals stay untouched.
- Search titles and notes, sort, rename and organize documents into collections.
- Read with zoom, page navigation, page jump and a remembered reading position.
- Write typed document notes, saved locally after a short pause.
- Choose **Write on PDF** to scribble directly on the visible page—no preview or separate editor opens. The notes panel temporarily hides to give the page more room.
- Pinch to zoom and pan while writing, or use the reader’s zoom controls. On iPad, Pencil-only mode leaves fingers free for navigation; enable Finger drawing to write with one finger and pan with two. On Mac, drag to write and use trackpad/reader zoom controls.
- Ink saves automatically as editable PDF annotations. Undo/redo work in the inline toolbar; Done returns to reading in the same view. If a save fails, keep the document open and use Retry ink save.
- For text boxes and changes to existing annotations, use **Tools → Edit annotations on page**. This advanced inspector is separate from normal inline handwriting.
- Edit existing annotations: recolor, move, resize, delete, add/edit text boxes, undo and redo. Links and form widgets remain intact during ordinary annotation saves.
- Another window's newer PDF changes are protected: stale saves are rejected and the unsaved editor draft stays available.
- iOS also has a separate handwritten notebook under Notes, with tools, undo/redo, zoom, Pencil-only or finger input, and background-save protection.
- Inline tools include stroke erasing, lasso selection, move/resize/recolor/delete, pressure-aware pen strokes, highlighter, favorite colors, lines, arrows, rectangles, ellipses and hold-to-shape recognition.
- Page tools rotate, reorder, duplicate, insert, delete, split and merge pages while preserving source artwork. Bookmarks, region-linked margin notes and document revision metadata live in the local workspace.
- Open page thumbnails, version history/recovery or a second read-only PDF beside the current document from Tools. Thumbnails use a bounded moving window rather than loading every page.

## Offline Study

Open **Offline Study** from the reader. Choose Document or Current page, then Summary, Key terms, Flashcards or Ask.

The standard mode selects source passages on-device and works without an AI model, account, internet connection or API key. Page links open the cited PDF page. Summaries, cards and answers can be saved into local document notes.

Ask has an optional **Use on-device AI** setting. On compatible devices with a ready Apple system model, it uses `SystemLanguageModel.default` locally to choose useful quotations. The app verifies quotations against source text and supplies page numbers itself. Model errors, unsupported output or model unavailability fall back to extractive results. There is no cloud model or network fallback.

No model weights are downloaded by Paperdesk. The optional model needs compatible hardware, macOS/iOS 26+ and an already-ready system model. Basic study tools continue to work when those requirements are not met.

AI answers intentionally use verified quotations rather than unrestricted explanations. Review the cited page for context. Study preparation is bounded to 250 pages, 300,000 characters and 1,600 passages; the UI identifies limited context. Current page can target pages beyond the document selection. Local AI receives at most three bounded passages and a short question.

## OCR and search

Tools can recognize the current page or the whole document using on-device Vision OCR. Completed pages are cached; progress, cancellation and resume are supported. Search combines native PDF text and recognized text, deduplicating occurrences by position.

**Export searchable PDF** creates a new copy containing searchable text. It preserves page appearance but flattens annotations/forms and omits interactive links, bookmarks and signatures. A confirmation explains this; the editable library original remains unchanged. Recognition accuracy and text placement depend on scan quality and layout.

## Export, backup and storage

Export annotated PDFs or plain-text notes from Tools. Library options → Library backup exports active PDFs, notes, collections, reading positions, notebook drawings and OCR caches to a portable JSON backup. PDF and backup exports use staged files; backup content is streamed in bounded chunks.

Restore adds new document IDs, preserving existing IDs rather than overwriting their edits. Removed documents are excluded from backups; their PDF, notes and drawing recovery copies are kept in the local Removed folder. Automatic cloud sync and live iPhone-to-Mac drawing are not implemented. Mac handwriting uses the trackpad/mouse.

For very large libraries, folder backup copies PDFs and sidecars one file at a time. Workspace backups include bookmarks, margin notes, review cards, per-page ink journals and durable text indexes. Handwriting recognition/search and the review queue also remain local.

Library data is under Application Support/Paperdesk in the app's sandbox container when sandboxed: UUID.pdf, library.json, and optional UUID.drawing / UUID.ocr.json. Project and build files for this workspace live in Downloads/Paperdesk-Workspace.

Imports, library loading, PDF opening, hashing, search, OCR and large exports run off the interface thread. Notes and drawing saves are batched; large PDFs save changed annotation pages without rewriting the source PDF for every stroke. Search uses a durable page index and thumbnails are bounded. Malformed or unusually complex PDFs can still perform differently across hardware. Keep backups of important work.

## Validation and remaining boundaries

See TEST_REPORT.md for the checks run on this build. Independent tests passed on Mac and an iPad simulator, including the real local model on Mac. Study and export services were also exercised with network access denied.

Physical Apple Pencil pressure, tilt, palm rejection and gestures still need a real iPad test. Standard PDF ink uses an averaged stroke width, which can differ from the Pencil preview. Undo history is bounded and ends when the page editor closes. Signing for physical devices and App Store distribution are not completed.

## Development checks

```
xcodebuild test -project Paperdesk.xcodeproj -scheme Paperdesk -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Paperdesk.xcodeproj -scheme Paperdesk -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

`Tests/run.sh` and `Tests/run-advanced.sh` run additional import, persistence, PDF editing, rotated-page, OCR and larger-document integration checks. Physical installation requires selecting your development team and connected device in Xcode; no app runtime API keys or service accounts are needed.
