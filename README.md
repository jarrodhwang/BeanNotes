# BeanNotes

Designed for Bean 콩이.

For anyone who loves Bean 콩이.

BeanNotes is a free-form, local-first notes app for iPhone and iPad. It is built for handwritten ideas, study notes, imported documents, and cozy personal organization with folders and note tabs.

## Highlights

- Folder-based note library with color-coded folders, year-grouped archives, recent notes, search, and quick note creation.
- Bean-first visual identity with a warm paper theme, paw-marked project colors, and light, dark, and tinted app icons.
- Note tabs for keeping multiple notes open while moving between projects.
- PencilKit drawing with custom palettes, remembered palette placement, focus drawing mode with compact undo/redo/zoom controls, editor touch-mode switching, sub-point Light Touch ink, press-and-hold fine width nudges, one-tap Detail Writing Mode, Light Touch Focus, live zoom/ink calibration, detail resolution status, Page Ink Lock, Ultra Fine zoom presets, zoom-friendly rendering, and local autosave.
- Page options for plain, grid, dotted, lined, Cornell, music staff, planner, and customizable plain/grid chalkboards.
- Imports for PDFs, images, CSV files, Word documents, slides, and other files, including PDF/image version history that preserves handwritten annotations.
- Exports for pages or whole notes as PDF, PNG, or JPEG, plus sharing of original attachments.
- Share extension support for creating a new note or adding one PDF/image as a new version of an existing document note.
- Automatic local folder-welcome notifications, requested when a folder is first created.
- Local SwiftData storage with backup/export support and recovery behavior for damaged stores.
- Chemistry notes with guided formula entry and atom counts, editable 2D structures, and offline molecular examples in native interactive 3D. See [chemistry capabilities and validation](Tests/CHEMISTRY.md).

## Project Shape

```text
BeanNotes/                 Main SwiftUI app
BeanNotesShareExtension/   iOS share extension
BeanNotesTests/            Unit and integration-style tests
BeanNotesUITests/          UI and launch performance tests
Scripts/test-plan.sh       Test lane runner
Tests/TEST_PLAN.md         Test strategy and CI recommendations
```

## Requirements

- Xcode with iOS 17 SDK support.
- iOS or iPadOS 17.0+ target.
- Swift 5 project settings.

## Getting Started

1. Open `BeanNotes.xcodeproj` in Xcode.
2. Select the `BeanNotes` scheme.
3. Choose an iPhone or iPad simulator running iOS 17.0 or newer.
4. Build and run.

## Testing

Run the focused test lanes from the repository root:

```sh
Scripts/test-plan.sh unit
Scripts/test-plan.sh ui
Scripts/test-plan.sh slow-import
Scripts/test-plan.sh performance
Scripts/test-plan.sh all
```

Use `unit` for fast model, storage, cleanup, search, theme, drawing-tool, backup, and settings checks. Use `slow-import` when changing document import, export, rendering, thumbnailing, or file cleanup paths.

See [Tests/TEST_PLAN.md](Tests/TEST_PLAN.md) for the full quality and CI strategy.

## Document Imports

PDFs and images become annotatable pages. Word (`doc`, `docx`), PowerPoint (`ppt`, `pptx`),
HTML, RTF, plain text, Markdown, CSV/TSV, JSON, XML, and Excel documents are rendered locally
into note pages, with the original document retained as an attachment. Other file types
keep their original attachment and a preview when available. PowerPoint imports capture each
slide canvas individually into vector PDF pages, preserving the source slide proportions,
backgrounds, text and embedded images without paper margins. PPTX imports validate slide
count and correct explicit text-box rotations using the source geometry. Conversion waits
for fonts and images and rejects unreadable images rather than saving incomplete pages.
Office fonts and advanced effects still depend on iOS's document renderer; export from
PowerPoint as PDF for exact font and effect reproduction. Legacy Word pagination can reflow.
Office imports use iOS's local preview renderer; legacy Word and spreadsheet layout can
reflow, so use a PDF when exact source pagination is required.
HTML imports do not execute document scripts or download remote resources.

The share dialog uses the original filename as the title placeholder and remembers the last
successful destination folder. It follows the app's theme and Light/Dark/System appearance,
keeps Add and Cancel above the keyboard, and reports any items that could not be prepared.
“Open BeanNotes right away” also opens the imported note.
If the source app rejects the launch request, the dialog explains that the files are saved
and ready for the next BeanNotes launch. Files can also be sent directly to BeanNotes using Open In.

Drawing recovery rechecks disk after a temporarily missing file and resumes editing only
after the saved ink has loaded. Failed image/PDF loads and visible note previews retry
automatically with a delay between attempts, and retry when the app becomes active or
protected files become available. Incomplete thumbnails are never stored as current previews;
the previous preview stays visible with a retry indicator. Replacement imports wait for
the cancelled operation's rollback before starting, so its cleanup cannot undo a newer import.
The Files picker always includes a Cancel button, including on iPadOS 17. Document conversion
keeps its temporary web renderer active until conversion finishes so sheet navigation can complete.

## Quality Priorities

BeanNotes favors practical product quality over feature sprawl:

- Functional suitability: note creation, folders, tabs, imports, exports, drawing, and search should work clearly for everyday note-taking.
- Reliability: local autosave, storage cleanup, import rollback, export cancellation, and store recovery are treated as core behavior.
- Performance efficiency: heavy rendering and import/export paths are separated into slower test lanes so fast checks stay useful.
- Maintainability: models, services, and SwiftUI views are separated by responsibility, with focused tests around storage and document workflows.
- Compatibility and portability: the app targets modern iOS/iPadOS through standard Apple frameworks such as SwiftUI, SwiftData, PencilKit, PDFKit, and UIKit.
- Security and privacy: notes are local-first, with no CloudKit database configured in the app model container.
- Usability: folder organization, tabs, page backgrounds, and share/export flows are designed to keep common writing workflows direct.

## License

No license file is included yet. Add one before distributing or accepting outside contributions.
