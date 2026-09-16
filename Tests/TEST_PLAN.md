# BeanNotes Test Plan

BeanNotes uses separate test lanes so fast correctness checks stay quick, while UI, document-import, and performance work run when their signal is worth the cost.

Run lanes through:

```sh
Scripts/test-plan.sh unit
Scripts/test-plan.sh ui
Scripts/test-plan.sh slow-import
Scripts/test-plan.sh performance
Scripts/test-plan.sh all
```

Override the simulator in CI when needed:

```sh
BEANNOTES_TEST_DESTINATION="platform=iOS Simulator,name=iPad Pro 11-inch (M4),OS=17.5" Scripts/test-plan.sh unit
```

## Unit Lane

Command:

```sh
Scripts/test-plan.sh unit
```

Purpose:
- Fast model, storage, cleanup, search, theme, drawing-tool, backup, and settings checks.
- Run on every pull request and before local commits.

Excludes:
- PDF/image/CSV import rendering.
- Export rendering/cancellation.
- UI automation and launch metrics.
- Synthetic drawing and PDF performance measurements.

Quality focus:
- Functional suitability for core model/storage behavior.
- Reliability for cleanup, rollback, and color/tool persistence.
- Maintainability because this lane should stay quick enough to run often.

## UI Lane

Command:

```sh
Scripts/test-plan.sh ui
```

Purpose:
- Launch the app with onboarding skipped and storage reset.
- Verify the main library creates a note and opens the editor.
- Verify finger drawing creates undoable ink and Pencil Only mode preserves page-action gestures.
- Capture launch-screen smoke coverage separately from performance metrics.

Quality focus:
- Usability and effectiveness for first-run app workflows.
- Compatibility with iPadOS launch arguments used by CI.
- Freedom from risk by resetting local state before each UI run.

## Slow Import Lane

Command:

```sh
Scripts/test-plan.sh slow-import
```

Purpose:
- Exercise PDF, image, CSV, thumbnail, export, and cancellation paths.
- Catch regressions in local file storage, rendering, staging rollback, and cleanup.

When to run:
- Before merging import/export/storage changes.
- Nightly in CI.
- Manually when changing PDFKit, QuickLook thumbnailing, image encoding, storage paths, or cancellation logic.

Quality focus:
- Reliability for large-document and partially-failed workflows.
- Performance efficiency by keeping heavy rendering out of the default unit lane.
- Portability because tests use temporary directories instead of absolute app paths.

## Performance Lane

Command:

```sh
Scripts/test-plan.sh performance
```

Purpose:
- Run launch metrics in `BeanNotesPerformanceTests`.
- Run `DrawingPerformanceTests` for 100 stroke additions/removal in a 200-page connected canvas and five page backgrounds from a 200-page PDF.
- Record five repetitions of each synthetic workload. Compare on the same simulator/device and build configuration; these timings measure app work, not physical Pencil-to-screen latency.

When to run:
- Nightly or before performance-sensitive releases.
- After changes to app launch, SwiftData container setup, first-run flows, image cache startup, or share-extension registration.
- After changes to ink reconciliation, PDF backgrounds, viewport resource management, or drawing autosave.

Quality focus:
- Performance efficiency without making normal UI tests noisy.
- Satisfaction by guarding against slow startup.
- Reliability by keeping performance measurements separate from correctness checks for cross-page ink, autosave, unavailable drawings, PDF replacement, cropping, and rotation.

### Physical iPad Drawing Check

Use a release build with Apple Pencil on the target iPad. Compare blank notes, a small PDF, a long text PDF, and a scanned PDF with large pages. Write short letters continuously, draw across connected page boundaries, and resume writing immediately after scrolling or pinching. Verify undo/redo and reopen the note after autosave and backgrounding.

Use Instruments Time Profiler and Animation Hitches to inspect the main thread during those interactions. Record device, OS, document size, zoom, and thermal state. The simulator cannot establish first-ink latency or sustained 120 Hz delivery.

### Recorded Comparison — 2026-09-15

Xcode 26.6, Debug build, iPad Pro 13-inch (M5) simulator, iOS 26.5. Five measured iterations per workload, before and after the drawing/PDF changes:

| Workload | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| 100 stroke additions and removal in a 200-page connected canvas | 127 ms | 78 ms | 39% |
| Configure and lay out five backgrounds from a 200-page PDF | 64 ms | 36 ms | 44% |

The PDF benchmark clears document caches before each iteration. The ink benchmark excludes fixture creation and measures stroke reconciliation and page snapshot maintenance. These are synthetic processing measurements, not end-to-end input latency or scanned-document benchmarks.

PDF backgrounds retain vector content, cropping, rotation, and annotations in single-page display documents. A bounded cache trades some retained page objects for faster revisits. Temporary navigation snapshots have a 4 MP / 4,096-pixel edge budget (roughly 16 MB of raw RGBA per page); very large pages can be softer during navigation, then return to vector display for drawing. Ink persistence and the all-or-none protection for unreadable drawing archives remain covered by correctness tests.

Validation: all 318 correctness tests passed on iOS 26.5, including the resize budget regression. Eight focused drawing/PDF tests passed on iOS 17.5. UI checks verified finger ink and undo plus Pencil Only page-action gestures on both OS versions.

## Full Lane

Command:

```sh
Scripts/test-plan.sh all
```

Purpose:
- Run every test in the scheme.

When to run:
- Before release tags.
- After test-plan edits.
- When diagnosing cross-lane behavior.

## CI Recommendation

Suggested CI stages:

```text
pull_request:
  - unit
  - ui

nightly:
  - unit
  - ui
  - slow-import
  - performance

release_candidate:
  - all
```

Keep slow import tests explicit. If a new test renders PDFs, uses QuickLook thumbnails, encodes large images, waits on UI automation, or records metrics, add it to the matching lane instead of the default unit lane.
