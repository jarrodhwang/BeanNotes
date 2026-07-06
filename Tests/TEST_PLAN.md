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
- Run launch performance metrics only, currently `BeanNotesPerformanceTests`.

When to run:
- Nightly or before performance-sensitive releases.
- After changes to app launch, SwiftData container setup, first-run flows, image cache startup, or share-extension registration.

Quality focus:
- Performance efficiency without making normal UI tests noisy.
- Satisfaction by guarding against slow startup.

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
