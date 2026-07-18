#!/usr/bin/env bash
set -euo pipefail

PROJECT="${BEANNOTES_PROJECT:-BeanNotes.xcodeproj}"
SCHEME="${BEANNOTES_SCHEME:-BeanNotes}"
DESTINATION="${BEANNOTES_TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=17.5}"
LANE="${1:-unit}"

COMMON_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "$DESTINATION"
  -parallel-testing-enabled NO
)

SLOW_IMPORT_TESTS=(
  "BeanNotesTests/BeanNotesTests/thumbnailGenerationStoresFirstPagePreview()"
  "BeanNotesTests/BeanNotesTests/pdfImportCreatesAnnotatablePages()"
  "BeanNotesTests/BeanNotesTests/stagedDocumentVersionImportPreservesPagesAndDrawingsAndCreatesLatestVersion()"
  "BeanNotesTests/BeanNotesTests/rotatedPDFImportUsesDisplayedPageAspect()"
  "BeanNotesTests/BeanNotesTests/stagedPDFImportRollbackRemovesCopiedFilesBeforeCommit()"
  "BeanNotesTests/BeanNotesTests/imageImportCreatesAnnotatableImageNote()"
  "BeanNotesTests/BeanNotesTests/csvImportCreatesPreviewNoteAndKeepsOriginalFile()"
  "BeanNotesTests/BeanNotesTests/noteExportCreatesPDFAndImageFiles()"
  "BeanNotesTests/BeanNotesTests/cancelingNoteExportRemovesPartialFiles()"
)

run_unit() {
  local args=(test "${COMMON_ARGS[@]}" -only-testing:BeanNotesTests -skip-testing:BeanNotesUITests)
  for test_id in "${SLOW_IMPORT_TESTS[@]}"; do
    args+=("-skip-testing:$test_id")
  done
  xcodebuild "${args[@]}"
}

run_ui() {
  xcodebuild test "${COMMON_ARGS[@]}" \
    -skip-testing:BeanNotesTests \
    -only-testing:BeanNotesUITests/BeanNotesUITests \
    -only-testing:BeanNotesUITests/BeanNotesUITestsLaunchTests
}

run_slow_import() {
  local args=(test "${COMMON_ARGS[@]}" -skip-testing:BeanNotesUITests)
  for test_id in "${SLOW_IMPORT_TESTS[@]}"; do
    args+=("-only-testing:$test_id")
  done
  xcodebuild "${args[@]}"
}

run_performance() {
  xcodebuild test "${COMMON_ARGS[@]}" \
    -skip-testing:BeanNotesTests \
    -only-testing:"BeanNotesUITests/BeanNotesPerformanceTests/testLaunchPerformance()"
}

usage() {
  cat <<USAGE
Usage: Scripts/test-plan.sh [unit|ui|slow-import|performance|all]

Environment overrides:
  BEANNOTES_PROJECT           Default: BeanNotes.xcodeproj
  BEANNOTES_SCHEME            Default: BeanNotes
  BEANNOTES_TEST_DESTINATION  Default: platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=17.5
USAGE
}

case "$LANE" in
  unit)
    run_unit
    ;;
  ui)
    run_ui
    ;;
  slow-import)
    run_slow_import
    ;;
  performance)
    run_performance
    ;;
  all)
    xcodebuild test "${COMMON_ARGS[@]}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 64
    ;;
esac
