# Paperdesk local verification — 1 November 2026

This report supersedes the earlier rolling reports. Local compilation and tests are not App Store approval, physical Pencil certification, or a completed visual/accessibility audit.

## Current results

| Check | Result |
|---|---|
| Xcode Coding Assistant build, My Mac | Passed; no application-source compiler errors or warnings |
| Generic iOS device build, arm64, signing disabled | Passed; no application-source compiler errors or warnings |
| Xcode Mac Swift Testing run | 48 passed, 0 failed; the current result bundle contains 48 test cases |
| Patch whitespace check | `git diff --check` passed |

The Mac tests include inline writing/zoom/reopen, undo/redo, stale-save protection, image/vector/link preservation, pressure/highlighter/shapes, lasso and eraser, pending journal export, folder backup, removal safety, workspace cards/notes/bookmarks, recovery and the actual Apple on-device model with verified citations. No new tests were added for presentation-only changes.

Both builds emit the tooling notice “Metadata extraction skipped, no AppIntents.framework dependency found.” Paperdesk has no App Intents integration; this is not a Swift source warning. Initial restricted-shell builds failed because the sandbox prevented Swift macro plugins from responding. Xcode compiled successfully, and an unrestricted unsigned generic iOS build succeeded. A signed generic iOS attempt stopped because no development team is configured; signing remains an owner step.

## Source audit and concrete changes

Reviewed the library/sidebar/overview, reader/search/dock, comparison reader/thumbnails, inline writing toolbar, annotation inspector, handwritten notebook, OCR sheet, document notes, workspace bookmarks/notes/cards and editors, page organizer, history/recovery, backup, offline study and help screens.

- Compact layout: writing tools scroll horizontally instead of expanding into a tall column over the PDF. Reader toolbar actions retain accessible text while using compact icons. Page tools keep actions scrollable and counts vertically arranged. iOS annotation editing no longer imposes a desktop minimum window height.
- Native behavior: history uses one scrolling List; workspace text/card editors use grouped Forms, initial field focus and keyboard shortcuts. Study allows interactive keyboard dismissal. PDF/Pencil gesture handling and editing services are unchanged.
- States: backup imports use indeterminate progress, exports retain measured progress, stale status clears when work starts, and active backup work prevents swipe dismissal. Empty OCR results explain how to proceed. Comparison pagination disables unavailable directions and loading has a label.
- Accessibility: thumbnail/page-selection controls announce their page and selection state; the annotation width slider has a label and value. Workspace errors use an icon and semantic foreground rather than color alone. Help now correctly names the Write on PDF shortcut.
- Appearance: retained semantic backgrounds/text, light/dark/high-contrast accent assets and opaque Reduce Transparency chrome. Glass remains limited to compact controls. No hero copy or decorative large cards were added.

Dynamic Type source verdict: **PASS** for SwiftUI text-style usage (no fixed-size text fonts or scaling clamps found). This does not certify every extreme-size/device combination; live largest-size and keyboard-open layout checks remain pending.

VoiceOver whole-app verdict: **FAIL** for release certification. SwiftUI control-label gaps found in this pass were fixed, but custom freehand PDF drawing surfaces still require a fully evaluated accessible interaction route and device testing. Native PDFKit/PencilKit behavior is not certified by the SwiftUI source audit.

Contrast verdict: **NEEDS VERIFICATION** for rendered glass, native PDF content and user-selected annotation colors. Semantic chrome and appearance-specific assets were reviewed, but no screenshot-based contrast or Accessibility Inspector measurement was performed this pass.

## Earlier evidence, not rerun on this source revision

Prior reports described a 10,000-page mixed-content PDF search (3.356 s cold / 0.076 s cached), a 10,000-page text fixture (2.513 s / 0.075 s), a 1,000-page OCR/index/export fixture, simulator tests, unsigned Release archives, and network-denied study/export checks. These are historical observations, not fresh results or guarantees for all PDFs. This pass leaves persistence, indexing, OCR budgets, thumbnail bounds and ink-save algorithms unchanged.

## Remaining release work

- Physical iPhone/iPad testing, including Pencil pressure, tilt, palm rejection, double-tap/squeeze, zoom/pan and background-save completion.
- Live VoiceOver, Full Keyboard Access, largest Dynamic Type, smallest supported window/device, light/dark, increased contrast and Reduce Transparency checks. No visual screenshots were generated or committed in this pass.
- Fresh Release archives and minimum-OS/device testing, large/scanned-PDF memory/progress/cancellation checks, and integration-script reruns on the submission revision.
- Owner: confirm production identity/team/bundle ID, sign and validate archives, TestFlight, publish reviewed privacy/support drafts, complete App Store metadata/privacy questionnaires and capture real submission screenshots.

See [release readiness](AppStore/RELEASE_READINESS.md). Privacy/support drafts are retained. No networking, API keys, sample PDF files, screenshots or build products were added to version control. Shell build outputs are ignored under `work/polish` in Downloads. Xcode tools manage their own temporary logs and test result bundles outside the repository.
