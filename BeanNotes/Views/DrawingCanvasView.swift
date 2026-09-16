//
//  DrawingCanvasView.swift
//  BeanNotes
//

import Combine
import PDFKit
import PencilKit
import QuartzCore
import SwiftUI
import UIKit

struct AttachmentImageRasterBudget: Equatable {
    private static let defaultRenderScale: CGFloat = 3
    private static let minimumPixelSize = 1_024
    private static let maximumPixelSize = 6_144
    private static let growthReloadFactor: CGFloat = 1.35
    private static let shrinkReloadFactor: CGFloat = 0.55

    let maxPixelSize: Int

    init(attachmentSize: CGSize, renderScale: CGFloat) {
        let longestEdge = Self.finitePositiveLongestEdge(in: attachmentSize)
        let effectiveScale = renderScale.isFinite && renderScale > 0 ? renderScale : Self.defaultRenderScale
        let scaledPixelSize = longestEdge * effectiveScale
        let boundedPixelSize = scaledPixelSize.isFinite
            ? min(scaledPixelSize.rounded(.up), CGFloat(Self.maximumPixelSize))
            : CGFloat(Self.maximumPixelSize)
        let requestedPixelSize = Int(max(boundedPixelSize, CGFloat(Self.minimumPixelSize)))
        maxPixelSize = requestedPixelSize
    }

    func shouldReplaceLoadedBudget(_ loadedBudget: AttachmentImageRasterBudget?) -> Bool {
        guard let loadedBudget else { return true }

        let loaded = CGFloat(loadedBudget.maxPixelSize)
        let requested = CGFloat(maxPixelSize)
        return requested > loaded * Self.growthReloadFactor
            || requested < loaded * Self.shrinkReloadFactor
    }

    private static func finitePositiveLongestEdge(in size: CGSize) -> CGFloat {
        let width = size.width.isFinite && size.width > 0 ? size.width : 0
        let height = size.height.isFinite && size.height > 0 ? size.height : 0
        let longestEdge = max(width, height)
        return longestEdge > 0 ? longestEdge : CGFloat(minimumPixelSize) / defaultRenderScale
    }
}

/// Batches normal handwriting pauses without letting a long session continually use
/// the full idle delay once the user finally pauses long enough to save.
enum DrawingAutosaveCadence {
    static let idleDelay: TimeInterval = 2
    static let maximumBatchDuration: TimeInterval = 12
    static let minimumDelay: TimeInterval = 0.3

    static func delay(elapsedSinceFirstChange: TimeInterval) -> TimeInterval {
        let elapsed = elapsedSinceFirstChange.isFinite
            ? max(elapsedSinceFirstChange, 0)
            : 0
        let remainingBatchDuration = maximumBatchDuration - elapsed
        return max(min(idleDelay, remainingBatchDuration), minimumDelay)
    }
}

struct DrawingCanvasLayoutSignature: Equatable {
    private struct PageSignature: Equatable {
        var id: UUID
        var pageOrder: Int
        var width: Double
        var height: Double
    }

    private var pageFlowMode: NoteEditorPageFlowMode
    private var hasTopContent: Bool
    private var pages: [PageSignature]

    init(
        pages: [NotePage],
        pageFlowMode: NoteEditorPageFlowMode,
        hasTopContent: Bool
    ) {
        self.pageFlowMode = pageFlowMode
        self.hasTopContent = hasTopContent
        self.pages = pages.map {
            PageSignature(
                id: $0.id,
                pageOrder: $0.pageOrder,
                width: $0.normalizedWidth,
                height: $0.normalizedHeight
            )
        }
    }
}

/// The subset of representable inputs that requires rebuilding UIKit canvas state.
///
/// SwiftUI republishes transient editor state such as zoom and undo availability while
/// the user is interacting. Keeping those values out of this signature prevents those
/// updates from remapping every page and refreshing image containers on each frame.
struct DrawingCanvasConfigurationSignature: Equatable {
    private struct AttachmentRevision: Equatable {
        var id: UUID
        var storedFileName: String
        var originalFileName: String
        var vectorSourceStoredFileName: String?
        var vectorSourcePageIndex: Int?
        var isLocked: Bool
        var rendersBehindDrawing: Bool
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private struct PageRevision: Equatable {
        var id: UUID
        var pageOrder: Int
        var width: Double
        var height: Double
        var backgroundStyleRaw: String
        var backgroundColorHex: String
        var attachments: [AttachmentRevision]
    }

    private var pages: [PageRevision]
    private var pageFlowMode: NoteEditorPageFlowMode
    private var inputMode: DrawingInputMode
    private var renderQuality: DrawingRenderQuality
    private var storageRootPath: String
    private var theme: BeanNotesTheme
    private var hasTopContent: Bool
    private var isDarkAppearance: Bool

    init(
        pages: [NotePage],
        pageFlowMode: NoteEditorPageFlowMode,
        inputMode: DrawingInputMode,
        renderQuality: DrawingRenderQuality,
        storageRootURL: URL,
        theme: BeanNotesTheme,
        hasTopContent: Bool,
        isDarkAppearance: Bool = false
    ) {
        self.pages = pages.map { page in
            PageRevision(
                id: page.id,
                pageOrder: page.pageOrder,
                width: page.normalizedWidth,
                height: page.normalizedHeight,
                backgroundStyleRaw: page.backgroundStyleRaw,
                backgroundColorHex: page.backgroundColorHex,
                attachments: page.visualAttachments.map { attachment in
                    let frame = attachment.frame
                    return AttachmentRevision(
                        id: attachment.id,
                        storedFileName: attachment.storedFileName,
                        originalFileName: attachment.originalFileName,
                        vectorSourceStoredFileName: attachment.vectorSourceStoredFileName,
                        vectorSourcePageIndex: attachment.vectorSourcePageIndex,
                        isLocked: attachment.isLocked,
                        rendersBehindDrawing: attachment.rendersBehindDrawing,
                        x: Int(frame.minX.rounded()),
                        y: Int(frame.minY.rounded()),
                        width: Int(frame.width.rounded()),
                        height: Int(frame.height.rounded())
                    )
                }
            )
        }
        self.pageFlowMode = pageFlowMode
        self.inputMode = inputMode
        self.renderQuality = renderQuality
        self.storageRootPath = storageRootURL.standardizedFileURL.path
        self.theme = theme
        self.hasTopContent = hasTopContent
        self.isDarkAppearance = isDarkAppearance
    }
}

/// A logical reading anchor for a drawing document.
///
/// The center is expressed in unscaled document coordinates rather than a raw
/// `UIScrollView.contentOffset`, which lets the position survive changes to insets,
/// zoom bounds, and device size.
struct DrawingCanvasViewport: Equatable {
    var center: CGPoint
    var zoomScale: CGFloat

    var isValid: Bool {
        center.x.isFinite
            && center.y.isFinite
            && zoomScale.isFinite
            && zoomScale > 0
    }
}

enum NotePageContextAction: Equatable {
    case add(NotePagePlacement)
    case pasteImage
    case remove
}

@MainActor
enum DrawingCanvasStaticContentSignature {
    static func signature(for page: NotePage) -> String {
        let attachments = page.visualAttachments
            .map(attachmentComponent)
            .joined(separator: "|")

        return [
            page.backgroundStyleRaw,
            page.backgroundColorHex,
            attachments
        ].joined(separator: "#")
    }

    static func attachmentComponent(for attachment: Attachment) -> String {
        let frame = attachment.frame
        let origin = "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded()))"
        let size = "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
        var components: [String] = []
        components.append(attachment.id.uuidString)
        components.append(attachment.storedFileName)
        components.append(attachment.originalFileName)
        components.append(attachment.vectorSourceStoredFileName ?? "")
        if let vectorPageIndex = attachment.vectorSourcePageIndex {
            components.append(String(vectorPageIndex))
        } else {
            components.append("")
        }
        components.append(String(attachment.isLocked))
        components.append(String(attachment.rendersBehindDrawing))
        components.append(origin)
        components.append(size)
        return components.joined(separator: ":")
    }
}

@MainActor
enum DrawingCanvasPDFCoverage {
    static func fullyCoversPage(_ attachments: [Attachment], pageSize: CGSize) -> Bool {
        attachments.contains { attachment in
            guard attachment.isLocked,
                  attachment.rendersBehindDrawing,
                  attachment.vectorSourceStoredFileName != nil else {
                return false
            }
            let attachmentFrame = attachment.normalizedFrame(for: pageSize)
            let pageBounds = CGRect(origin: .zero, size: pageSize)
            return abs(attachmentFrame.minX - pageBounds.minX) < 0.5
                && abs(attachmentFrame.minY - pageBounds.minY) < 0.5
                && abs(attachmentFrame.maxX - pageBounds.maxX) < 0.5
                && abs(attachmentFrame.maxY - pageBounds.maxY) < 0.5
        }
    }
}

struct DrawingCanvasView: UIViewRepresentable {
    let pages: [NotePage]
    @Binding var selectedPageID: UUID?
    @ObservedObject var toolState: DrawingToolState
    var paletteMode: PenPaletteMode
    var inputMode: DrawingInputMode
    var renderQuality: DrawingRenderQuality
    var strokeZoomBehavior: DrawingStrokeZoomBehavior
    var pageFlowMode: NoteEditorPageFlowMode
    var doubleTapAction: PencilDoubleTapAction
    var saveNowSignal: Int
    var exportPreparationSignal: Int = 0
    var fitToPageSignal: Int
    var zoomInSignal: Int
    var zoomOutSignal: Int
    var zoomToScaleSignal: Int
    var zoomTargetScale: CGFloat
    var undoSignal: Int
    var redoSignal: Int
    var toolShortcutSignal: Int
    var drawingStorage = DrawingStorageService()
    var attachmentChanged: () -> Void
    var deleteAttachment: (Attachment) -> Void
    var editCodeSnippet: (Attachment) -> Void = { _ in }
    var saveCodeSnippetSource: (CodeSnippetDraft, Attachment) -> Bool = { _, _ in false }
    var saveCodeSnippet: (CodeSnippetDraft, Attachment) -> Bool = { _, _ in false }
    var isDarkAppearance = false
    var drawingChanged: (UUID) -> Void
    var captureFailed: (Error) -> Void = { _ in }
    var saveStarted: () -> Void = {}
    var saveSucceeded: () -> Void = {}
    var saveFailed: (Error) -> Void = { _ in }
    var exportPreparationCompleted: (Int, Result<Void, Error>) -> Void = { _, _ in }
    var undoRedoAvailabilityChanged: (Bool, Bool) -> Void = { _, _ in }
    var zoomScaleChanged: (CGFloat) -> Void = { _ in }
    var initialViewport: DrawingCanvasViewport? = nil
    var viewportRestorationID = 0
    var viewportChanged: (DrawingCanvasViewport) -> Void = { _ in }
    var finalViewportChanged: (DrawingCanvasViewport, UUID?) -> Void = { _, _ in }
    var selectionRevision: () -> UInt64 = { 0 }
    var canPublishVisiblePageSelection: () -> Bool = { true }
    var userPageSelectionStarted: () -> Void = {}
    var pageActionRequested: (UUID, NotePageContextAction) -> Void = { _, _ in }
    var addPageRequested: () -> Void
    var topContent: AnyView?
    var theme: BeanNotesTheme = .defaultTheme
    var showsBeanArtwork = false

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let containerView = CanvasContainerView()
        containerView.visiblePageChanged = { [weak coordinator = context.coordinator] pageID in
            coordinator?.selectVisiblePage(pageID)
        }
        containerView.viewportChanged = { [weak coordinator = context.coordinator] viewport, force in
            coordinator?.publishViewport(viewport, force: force)
        }
        containerView.addPageRequested = { [weak coordinator = context.coordinator] in
            coordinator?.requestAddPage()
        }

        context.coordinator.containerView = containerView
        context.coordinator.viewportRestorationID = viewportRestorationID
        context.coordinator.configurePencilInteraction(on: containerView)

        let twoFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap(_:))
        )
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.delegate = context.coordinator
        twoFingerTap.cancelsTouchesInView = false
        containerView.addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerTap(_:))
        )
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.delegate = context.coordinator
        threeFingerTap.cancelsTouchesInView = false
        containerView.addGestureRecognizer(threeFingerTap)

        let doubleTapZoom = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFingerDoubleTap(_:))
        )
        doubleTapZoom.numberOfTouchesRequired = 1
        doubleTapZoom.numberOfTapsRequired = 2
        doubleTapZoom.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTapZoom.delegate = context.coordinator
        // A recognized editor double tap must own its second touch. Leaving that
        // touch active lets PencilKit's private recognizers open their edit menu
        // after the zoom gesture has completed.
        doubleTapZoom.cancelsTouchesInView = true
        containerView.addGestureRecognizer(doubleTapZoom)
        containerView.setFingerDoubleTapGesture(doubleTapZoom)

        if let pinchGesture = containerView.scrollView.pinchGestureRecognizer {
            twoFingerTap.require(toFail: pinchGesture)
            threeFingerTap.require(toFail: pinchGesture)
        }

        context.coordinator.observeToolState(toolState)
        containerView.setTopContentView(context.coordinator.updateTopContent(topContent))
        containerView.configure(
            pages: pages,
            selectedPageID: selectedPageID,
            pageFlowMode: pageFlowMode,
            inputMode: inputMode,
            renderQuality: renderQuality,
            drawingStorage: drawingStorage,
            coordinator: context.coordinator,
            theme: theme,
            showsBeanArtwork: showsBeanArtwork
        )
        context.coordinator.configurationSignature = configurationSignature()
        containerView.restoreViewport(initialViewport)
        context.coordinator.configureToolPicker(mode: paletteMode)

        return containerView
    }

    func updateUIView(_ containerView: CanvasContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configurePencilInteraction(on: containerView)
        context.coordinator.observeToolState(toolState)
        containerView.setTopContentView(context.coordinator.updateTopContent(topContent))
        let selectionUpdate = context.coordinator.reconcileSelectedPageID(selectedPageID)
        if selectionUpdate.shouldScroll,
           let selectedPageID = selectionUpdate.effectivePageID {
            // Relaying out after an add/remove can synchronously fire didScroll before
            // the destination offset is applied. Suppress that intermediate visible
            // page so it cannot overwrite the programmatic selection.
            containerView.prepareForProgrammaticScroll(to: selectedPageID)
        }

        let configurationSignature = configurationSignature()
        if context.coordinator.configurationSignature != configurationSignature {
            containerView.configure(
                pages: pages,
                selectedPageID: selectionUpdate.effectivePageID,
                pageFlowMode: pageFlowMode,
                inputMode: inputMode,
                renderQuality: renderQuality,
                drawingStorage: drawingStorage,
                coordinator: context.coordinator,
                theme: theme,
                showsBeanArtwork: showsBeanArtwork
            )
            context.coordinator.configurationSignature = configurationSignature
        }
        // Artwork is a repaint-only preference. Keep it out of the canvas rebuild
        // signature so changing it cannot release or reload live PencilKit drawings.
        containerView.updateArtworkVisibility(showsBeanArtwork)
        containerView.synchronizeSelectedPageID(selectionUpdate.effectivePageID)
        containerView.reassertInteractionState()

        if selectionUpdate.shouldScroll,
           let selectedPageID = selectionUpdate.effectivePageID {
            containerView.scrollToPage(id: selectedPageID, animated: true)
        }

        if context.coordinator.viewportRestorationID != viewportRestorationID {
            context.coordinator.viewportRestorationID = viewportRestorationID
            containerView.restoreViewport(initialViewport)
        }

        if context.coordinator.saveNowSignal != saveNowSignal {
            _ = containerView.flushInlineCodeSnippetEdits()
            context.coordinator.saveAllCanvases()
            context.coordinator.saveNowSignal = saveNowSignal
        }

        if context.coordinator.exportPreparationSignal != exportPreparationSignal {
            if containerView.flushInlineCodeSnippetEdits() {
                context.coordinator.prepareForExport(requestID: exportPreparationSignal)
            } else {
                context.coordinator.failExportPreparationForUnsavedCodeSnippet(
                    requestID: exportPreparationSignal
                )
            }
            context.coordinator.exportPreparationSignal = exportPreparationSignal
        }

        if context.coordinator.fitToPageSignal != fitToPageSignal {
            containerView.fitSelectedPageToScreen(animated: true)
            context.coordinator.fitToPageSignal = fitToPageSignal
        }

        if context.coordinator.zoomInSignal != zoomInSignal {
            containerView.zoomSelectedPage(by: 1.2, animated: true)
            context.coordinator.zoomInSignal = zoomInSignal
        }

        if context.coordinator.zoomOutSignal != zoomOutSignal {
            containerView.zoomSelectedPage(by: 1 / 1.2, animated: true)
            context.coordinator.zoomOutSignal = zoomOutSignal
        }

        if context.coordinator.zoomToScaleSignal != zoomToScaleSignal {
            containerView.zoomSelectedPage(to: zoomTargetScale, animated: true)
            context.coordinator.zoomToScaleSignal = zoomToScaleSignal
        }

        if context.coordinator.undoSignal != undoSignal {
            context.coordinator.performUndo()
            context.coordinator.undoSignal = undoSignal
        }

        if context.coordinator.redoSignal != redoSignal {
            context.coordinator.performRedo()
            context.coordinator.redoSignal = redoSignal
        }

        if context.coordinator.toolShortcutSignal != toolShortcutSignal {
            context.coordinator.applyToolShortcutSelection()
            context.coordinator.toolShortcutSignal = toolShortcutSignal
        }

        context.coordinator.applyCustomToolIfNeeded()
        context.coordinator.configureToolPicker(mode: paletteMode)
        context.coordinator.publishUndoRedoAvailability()
    }

    private func configurationSignature() -> DrawingCanvasConfigurationSignature {
        DrawingCanvasConfigurationSignature(
            pages: pages,
            pageFlowMode: pageFlowMode,
            inputMode: inputMode,
            renderQuality: renderQuality,
            storageRootURL: drawingStorage.storage.rootURL,
            theme: theme,
            hasTopContent: topContent != nil,
            isDarkAppearance: isDarkAppearance
        )
    }

    static func dismantleUIView(_ containerView: CanvasContainerView, coordinator: Coordinator) {
        coordinator.publishCurrentViewport()
        coordinator.performFinalDrawingFlush(reason: "Editor closed")
        coordinator.hideToolPicker()
        coordinator.removePencilInteraction()
        containerView.cancelPendingRenderingWork()
        containerView.releaseAllMaterializedPages(flushDrawingsBeforeRelease: false)
        coordinator.containerView = nil
    }

    final class CanvasContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        private final class ViewportRefreshDisplayLinkTarget: NSObject {
            weak var owner: CanvasContainerView?

            init(owner: CanvasContainerView) {
                self.owner = owner
            }

            @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
                guard let owner else {
                    displayLink.invalidate()
                    return
                }
                owner.performScheduledViewportRefresh()
            }
        }

        struct ContinuousDrawingLoadBundle {
            var drawing: PKDrawing?
            var results: [(NotePage, DrawingStorageService.LoadResult)]

            var firstError: Error? {
                results.lazy.compactMap { $0.1.error }.first
            }
        }

        private struct ContinuousStrokePointSignature: Hashable {
            var x: Int64
            var y: Int64
            var width: Int64
            var height: Int64
            var opacity: Int64
            var force: Int64
        }

        private struct ContinuousStrokeMaskSignature: Hashable {
            var lowerBound: Int64
            var upperBound: Int64
        }

        private struct ContinuousStrokeSignature: Hashable {
            var inkType: String
            var color: String
            var pointCount: Int
            var creationTime: UInt64
            var points: [ContinuousStrokePointSignature]
            var masks: [ContinuousStrokeMaskSignature]
        }

        /// Stable across document/page translations and lasso transforms. Reading two
        /// endpoint samples avoids hashing every PencilKit point after each erase.
        private struct ContinuousStrokeIdentity: Hashable {
            var inkType: String
            var creationTime: UInt64
            var pointCount: Int
            var firstX: Int64
            var firstY: Int64
            var lastX: Int64
            var lastY: Int64
        }

        /// Cheap mutable state used to distinguish an unchanged stroke from an erase
        /// mask or lasso transform without walking its complete point path.
        private struct ContinuousStrokeState: Hashable {
            var transform: [Int64]
            var renderBounds: [Int64]
            var masks: [ContinuousStrokeMaskSignature]
        }

        private struct ContinuousStrokeMutation {
            var previous: PKStroke?
            var current: PKStroke?
        }

        private struct DrawingPrefetchSignature: Equatable {
            var rootPath: String
            var fileNames: [String]
        }

        let scrollView = UIScrollView()
        let contentView = UIView()
        let addPageFooterButton = UIButton(type: .system)
        var visiblePageChanged: ((UUID) -> Void)?
        var viewportChanged: ((DrawingCanvasViewport, Bool) -> Void)?
        var addPageRequested: (() -> Void)?

        private var pageViews: [UUID: PageCanvasView] = [:]
        private var continuousPageView: PageCanvasView?
        private var continuousPageDrawingCache: [UUID: PKDrawing] = [:]
        private(set) var captureSelectionOverlay: NoteCaptureSelectionOverlayView?
        private var captureSelectionPageID: UUID?
        private var isCaptureToolEnabled = false
        private var seamlessAttachmentSelectionGesture: UITapGestureRecognizer?
        private weak var fingerDoubleTapGesture: UITapGestureRecognizer?
        private var pagesByID: [UUID: NotePage] = [:]
        private var orderedPageIDs: [UUID] = []
        private var pageIndexesByID: [UUID: Int] = [:]
        private var pageFrames: [UUID: CGRect] = [:]
        private var continuousDrawingFrame: CGRect?
        private var documentSize: CGSize = .zero
        private weak var topContentView: UIView?
        private var pageFlowMode: NoteEditorPageFlowMode = .seamless
        private var renderQuality: DrawingRenderQuality = .ultraFine
        private var layoutConfigurationSignature: DrawingCanvasLayoutSignature?
        private var selectedPageID: UUID?
        private var activeDrawingPageID: UUID?
        private var drawingStorage: DrawingStorageService?
        private let drawingPrefetchScopeID = UUID()
        private weak var coordinator: Coordinator?
        private var inputMode: DrawingInputMode = DrawingInputMode.defaultMode
        private var theme: BeanNotesTheme = .defaultTheme
        private var showsBeanArtwork = false
        private var lastFitScale: CGFloat = 1
        private var lastBackgroundRenderScale: CGFloat = 0
        private var lastImageRenderScale: CGFloat = 0
        private var didSetInitialZoom = false
        private var pendingViewport: DrawingCanvasViewport?
        private var isRestoringViewport = false
        private var isPinchZooming = false
        private var isProgrammaticZooming = false
        private var programmaticZoomEarliestFinishTime: CFTimeInterval = 0
        private var settledZoomWorkItem: DispatchWorkItem?
        private var lastDrawingViewportSize: CGSize = .zero
        private var lastZoomEndTime: CFTimeInterval = 0
        private var lastObservedContentOffsetY: CGFloat = 0
        private var lastScrollToTopRequestTime: CFTimeInterval?
        private var isScrollingTowardLaterPages = true
        private var isUserScrolling = false
        private var pendingTraversalVisiblePageID: UUID?
        private var lastPublishedVisiblePageID: UUID?
        private var isDrawingInteractionActive = false
        private var keepsPDFVectorSurfaceDuringDrawing = false
        private var pdfVectorProtectedPageIDs: Set<UUID> = []
        private var pdfRenderingResumeWorkItem: DispatchWorkItem?
        private var pdfRenderingResumeGeneration: UInt = 0
        private var defersPDFRenderingAfterTraversal = false
        private var traversalPDFResumeWorkItem: DispatchWorkItem?
        private var traversalPDFResumeGeneration: UInt = 0
        private var isProgrammaticScrollAnimating = false
        private var programmaticScrollTargetID: UUID?
        private var programmaticScrollTargetOffset: CGPoint?
        private var viewportRefreshDisplayLink: CADisplayLink?
        private var viewportRefreshDisplayLinkTarget: ViewportRefreshDisplayLinkTarget?
        private var hasPendingViewportRefresh = false
        private var pendingViewportRefreshNeedsMaterialization = false
        private var lastViewportResourceRefreshRect: CGRect?
        private var lastViewportResourceRefreshZoomScale: CGFloat = 0
        private var lastViewportResourceRefreshDirection = true
        private var lastDrawingPrefetchSignature: DrawingPrefetchSignature?
        private(set) var viewportResourceRefreshCount = 0
        private(set) var viewportVisibilityRefreshCount = 0
        private(set) var continuousAggregateSplitCount = 0
        private let separatedPageGap: CGFloat = 28
        private let pageMargin: CGFloat = 52
        private let addPageFooterSize: CGFloat = 56
        private let addPageFooterTopPadding: CGFloat = 36
        private let addPageFooterBottomPadding: CGFloat = 42
        private let pageForwardPreloadScreenPadding: CGFloat = 1_240
        private let pageBackwardPreloadScreenPadding: CGFloat = 420
        private let minimumPageForwardPreloadPadding: CGFloat = 880
        private let minimumPageBackwardPreloadPadding: CGFloat = 280
        private let imageForwardPreloadScreenPadding: CGFloat = 760
        private let imageBackwardPreloadScreenPadding: CGFloat = 220
        private let minimumImageForwardPreloadPadding: CGFloat = 480
        private let minimumImageBackwardPreloadPadding: CGFloat = 140
        private let scrollingPageRetentionScreens: CGFloat = 2
        private let scrollingImageRetentionScreens: CGFloat = 1
        private let drawingPrefetchForwardScreenPadding: CGFloat = 2_400
        private let drawingPrefetchBackwardScreenPadding: CGFloat = 520
        private let minimumDrawingViewportOverscan: CGFloat = 256
        private let drawingViewportOverscanFraction: CGFloat = 0.5
        private let topContentHeight: CGFloat = 96
        private let zoomOutMultiplier: CGFloat = 0.46
        private let absoluteMinimumZoomScale: CGFloat = 0.12
        private let renderScaleChangeThreshold: CGFloat = 0.08
        private let tapAfterZoomIgnoreDuration: CFTimeInterval = 0.32
        private let scrollToTopDoubleTapInterval: CFTimeInterval = 0.5
        private let settledZoomDelay: TimeInterval = 0.12
        private let programmaticZoomSettleDuration: CFTimeInterval = 0.4
        private let pdfRenderingResumeDelay: TimeInterval = 0.35
        private let fingerTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        var isZoomGestureActiveOrRecentlyEnded: Bool {
            let pinchState = scrollView.pinchGestureRecognizer?.state
            let pinchIsActive = pinchState == .began || pinchState == .changed
            return isPinchZooming
                || isProgrammaticZooming
                || pinchIsActive
                || CACurrentMediaTime() - lastZoomEndTime < tapAfterZoomIgnoreDuration
        }

        // This includes SwiftUI-driven updateUIView calls that arrive while UIScrollView
        // is still animating its native zoom transform.
        var isZoomTransitionActive: Bool {
            isPinchZooming || isProgrammaticZooming || scrollView.isZooming || isScrollViewAnimatingZoom
        }

        var defersViewStatePublishing: Bool {
            pendingViewport != nil || isRestoringViewport
        }

        var isDocumentTraversalActive: Bool {
            isUserScrolling
        }

        var isLiveDrawingInteractionActive: Bool {
            isDrawingInteractionActive
        }

        var isPDFVectorRenderingProtectedForDrawing: Bool {
            keepsPDFVectorSurfaceDuringDrawing
        }

        var isPDFRenderingDeferredAfterTraversal: Bool {
            defersPDFRenderingAfterTraversal
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        deinit {
            invalidateScheduledViewportRefresh()
        }

        var activeCanvasView: PKCanvasView? {
            if pageFlowMode.usesDocumentWideCanvas {
                return continuousPageView?.canvasView
            }

            guard let selectedPageID else {
                guard let firstPageID = orderedPageIDs.first else { return nil }
                return pageViews[firstPageID]?.canvasView
            }

            return pageViews[selectedPageID]?.canvasView
        }

        func pageCanvasViewForTesting(pageID: UUID) -> PageCanvasView? {
            pageViews[pageID]
        }

        var currentSelectedPageID: UUID? {
            guard let viewport = currentViewport() else { return selectedPageID }
            return nearestPageID(toY: viewport.center.y) ?? selectedPageID
        }

        var canvasPagePairs: [(NotePage, PKCanvasView)] {
            if let continuousPageView,
               let representativePage = orderedPageIDs.first.flatMap({ pagesByID[$0] }) {
                return [(representativePage, continuousPageView.canvasView)]
            }

            return orderedPageIDs.compactMap { id in
                guard let pageView = pageViews[id], let page = pageView.page else { return nil }
                return (page, pageView.canvasView)
            }
        }

        func setActiveDrawingPage(id: UUID?) {
            activeDrawingPageID = id
        }

        func synchronizeSelectedPageID(_ selectedPageID: UUID?) {
            // Keep the locally tracked nearest page while a large document is moving.
            // SwiftUI can still deliver the previously published selection in a
            // throttled state update; accepting it here would jump resource priority
            // backward on every such update.
            if isUserScrolling, pendingTraversalVisiblePageID != nil {
                return
            }
            self.selectedPageID = selectedPageID ?? orderedPageIDs.first
            lastPublishedVisiblePageID = self.selectedPageID
            if isCaptureToolEnabled {
                updateCaptureSelectionOverlay()
            }
        }

        func reassertInteractionState() {
            if let continuousPageView {
                continuousPageView.applyInputMode(inputMode)
                continuousPageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
                return
            }
            let activePageID = selectedPageID ?? orderedPageIDs.first
            if let activePageView = activePageID.flatMap({ pageViews[$0] }) {
                activePageView.applyInputMode(inputMode)
                activePageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
            }
        }

        func setCaptureToolEnabled(_ enabled: Bool) {
            let changed = isCaptureToolEnabled != enabled
            isCaptureToolEnabled = enabled
            applyCaptureInteractionState()

            if enabled {
                updateCaptureSelectionOverlay(resetSelection: changed)
            } else {
                captureSelectionOverlay?.removeFromSuperview()
                captureSelectionOverlay = nil
                captureSelectionPageID = nil
            }
        }

        func isContinuousCanvas(_ canvasView: PKCanvasView) -> Bool {
            continuousPageView?.canvasView === canvasView
        }

        var continuousPageIDs: [UUID] {
            isContinuousDrawingEnabled ? orderedPageIDs : []
        }

        /// Ink usually changes just one or two pages, even in a long PDF. Order that
        /// small set directly instead of scanning the complete document after every stroke.
        func continuousPageIDs(in requestedIDs: Set<UUID>) -> [UUID] {
            guard isContinuousDrawingEnabled else { return [] }
            return requestedIDs.compactMap { id -> (UUID, Int)? in
                guard let index = pageIndexesByID[id] else { return nil }
                return (id, index)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        }

        private var isContinuousDrawingEnabled: Bool {
            pageFlowMode.usesDocumentWideCanvas && continuousPageView != nil
        }

        func setTopContentView(_ view: UIView?) {
            guard topContentView !== view else { return }

            topContentView?.removeFromSuperview()
            topContentView = view

            if let view {
                view.backgroundColor = .clear
                contentView.addSubview(view)
            }

            setNeedsLayout()
        }

        func configure(
            pages: [NotePage],
            selectedPageID: UUID?,
            pageFlowMode: NoteEditorPageFlowMode,
            inputMode: DrawingInputMode,
            renderQuality: DrawingRenderQuality,
            drawingStorage: DrawingStorageService,
            coordinator: Coordinator,
            theme: BeanNotesTheme = .defaultTheme,
            showsBeanArtwork: Bool = false
        ) {
            applyWorkspaceTheme(theme)

            let qualityChanged = self.renderQuality != renderQuality
            let inputModeChanged = self.inputMode != inputMode
            let selectionChanged = self.selectedPageID != (selectedPageID ?? pages.first?.id)
            let nextSignature = DrawingCanvasLayoutSignature(
                pages: pages,
                pageFlowMode: pageFlowMode,
                hasTopContent: topContentView != nil
            )
            let shouldRelayout = nextSignature != layoutConfigurationSignature

            if shouldRelayout, (continuousPageView != nil || !pageViews.isEmpty) {
                // Persist current ink before page bounds or flow mode change, so a
                // rebuilt canvas can translate every stroke from stable coordinates.
                guard flushInlineCodeSnippetEdits() else { return }
                coordinator.saveAllCanvases(force: true)
            }
            if shouldRelayout, continuousPageView != nil {
                releaseContinuousPageView(flushDrawingBeforeRelease: false)
            }

            self.pageFlowMode = pageFlowMode
            seamlessAttachmentSelectionGesture?.isEnabled = pageFlowMode.usesDocumentWideCanvas
            self.inputMode = inputMode
            self.renderQuality = renderQuality
            self.theme = theme
            self.showsBeanArtwork = showsBeanArtwork
            self.selectedPageID = selectedPageID ?? pages.first?.id
            self.drawingStorage = drawingStorage
            self.coordinator = coordinator
            scrollView.panGestureRecognizer.minimumNumberOfTouches = inputMode == .anyInput ? 2 : 1
            if !isUserScrolling {
                lastPublishedVisiblePageID = self.selectedPageID
            }
            if shouldRelayout, pendingViewport == nil {
                pendingViewport = currentViewport()
            }

            if shouldRelayout {
                let incomingIDs = Set(pages.map(\.id))
                let removedIDs = pageViews.keys.filter { !incomingIDs.contains($0) }
                for id in removedIDs {
                    if let pageView = pageViews[id] {
                        retirePageView(id: id, pageView: pageView)
                    }
                }

                orderedPageIDs = pages.map(\.id)
                pageIndexesByID = Dictionary(uniqueKeysWithValues: orderedPageIDs.enumerated().map {
                    ($0.element, $0.offset)
                })
                pagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })

                layoutDocument()
                layoutConfigurationSignature = nextSignature
                setNeedsLayout()
            } else {
                orderedPageIDs = pages.map(\.id)
                pagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
            }

            updateZoomScalesIfNeeded(force: qualityChanged || selectionChanged)
            if shouldRelayout {
                _ = restorePendingViewportIfPossible()
            }
            // Configuration performs an immediate refresh against the new page model.
            // Discard any display-link work queued against the previous configuration.
            cancelScheduledViewportRefresh()
            materializePagesNearViewport(refreshesExistingPages: true)
            configureContinuousPageViewIfNeeded(reloadsDrawing: shouldRelayout)
            arrangeDocumentLayers()
            if isCaptureToolEnabled {
                updateCaptureSelectionOverlay()
            }
            updateNativeDrawingViewports(force: shouldRelayout)

            if inputModeChanged {
                applyInputModeToMaterializedPages()
            }
        }

        func updateArtworkVisibility(_ showsBeanArtwork: Bool) {
            guard self.showsBeanArtwork != showsBeanArtwork else { return }
            self.showsBeanArtwork = showsBeanArtwork
            for pageView in pageViews.values {
                pageView.updateArtworkVisibility(showsBeanArtwork)
            }
            continuousPageView?.updateArtworkVisibility(showsBeanArtwork)
        }

        /// Defers restoration until the document has frames, zoom limits, and a viewport.
        /// A raw scroll offset is intentionally not used because it changes with content
        /// insets and screen size.
        func restoreViewport(_ viewport: DrawingCanvasViewport?) {
            guard let viewport, viewport.isValid else { return }
            pendingViewport = viewport
            setNeedsLayout()
        }

        func currentViewport() -> DrawingCanvasViewport? {
            guard !defersViewStatePublishing,
                  documentSize.width > 0,
                  documentSize.height > 0,
                  scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0,
                  scrollView.zoomScale.isFinite,
                  scrollView.zoomScale > 0 else {
                return nil
            }

            let center = contentView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                from: scrollView
            )
            let viewport = DrawingCanvasViewport(center: center, zoomScale: scrollView.zoomScale)
            return viewport.isValid ? viewport : nil
        }

        func prepareForProgrammaticScroll(to pageID: UUID) {
            isProgrammaticScrollAnimating = false
            programmaticScrollTargetID = pageID
            programmaticScrollTargetOffset = nil
            pendingTraversalVisiblePageID = nil
        }

        func scrollToPage(id: UUID, animated: Bool) {
            guard orderedPageIDs.contains(id) else {
                cancelProgrammaticPageSelection()
                selectedPageID = orderedPageIDs.first
                finishDocumentTraversalIfIdle()
                return
            }
            selectedPageID = id
            guard let frame = pageFrames[id], scrollView.bounds != .zero else {
                programmaticScrollTargetID = id
                programmaticScrollTargetOffset = nil
                return
            }
            let scaledCenterX = frame.midX * scrollView.zoomScale
            let scaledTopY = frame.minY * scrollView.zoomScale
            let target = CGPoint(
                x: scaledCenterX - scrollView.bounds.width / 2,
                y: scaledTopY - scrollView.adjustedContentInset.top + 12
            )
            let clampedTarget = clampedContentOffset(target)
            let offsetDistance = hypot(
                clampedTarget.x - scrollView.contentOffset.x,
                clampedTarget.y - scrollView.contentOffset.y
            )
            let shouldAnimate = animated && offsetDistance > 0.5
            programmaticScrollTargetID = id
            programmaticScrollTargetOffset = clampedTarget
            isProgrammaticScrollAnimating = shouldAnimate
            if shouldAnimate {
                setUserScrolling(true)
            }
            scrollView.setContentOffset(clampedTarget, animated: shouldAnimate)
            if !shouldAnimate {
                cancelProgrammaticPageSelection()
                finishDocumentTraversalIfIdle()
            }
            cancelScheduledViewportRefresh()
            materializePagesNearViewport()
            updateNativeDrawingViewports()
        }

        private func restorePendingProgrammaticScrollIfPossible() {
            guard let targetID = programmaticScrollTargetID,
                  programmaticScrollTargetOffset == nil,
                  pageFrames[targetID] != nil,
                  scrollView.bounds != .zero else { return }
            scrollToPage(id: targetID, animated: false)
        }

        func fitSelectedPageToScreen(animated: Bool) {
            updateZoomScalesIfNeeded()
            if animated {
                beginProgrammaticZoom()
            }
            scrollView.setZoomScale(selectedPageOverviewScale(), animated: animated)
            if animated {
                scheduleSettledZoomRefresh()
            } else {
                finishProgrammaticZoom()
            }

            if let selectedPageID {
                scrollToPage(id: selectedPageID, animated: animated)
            }
        }

        func zoomSelectedPage(by multiplier: CGFloat, animated: Bool) {
            guard scrollView.bounds != .zero, multiplier > 0 else { return }

            updateZoomScalesIfNeeded()

            let currentScale = max(scrollView.zoomScale, 0.01)
            let targetScale = DrawingZoomLevel.clampedScale(
                currentScale * multiplier,
                minimum: scrollView.minimumZoomScale,
                maximum: scrollView.maximumZoomScale
            )
            setZoomScalePreservingViewportCenter(targetScale, animated: animated)
        }

        func zoomSelectedPage(to scale: CGFloat, animated: Bool) {
            guard scrollView.bounds != .zero else { return }

            updateZoomScalesIfNeeded()

            let targetScale = DrawingZoomLevel.clampedScale(
                scale,
                minimum: scrollView.minimumZoomScale,
                maximum: scrollView.maximumZoomScale
            )
            setZoomScalePreservingViewportCenter(targetScale, animated: animated)
        }

        func toggleDetailZoom(at contentPoint: CGPoint, animated: Bool) {
            guard scrollView.bounds != .zero, documentSize != .zero else { return }

            updateZoomScalesIfNeeded()

            let targetScale = DrawingZoomLevel.doubleTapTargetScale(
                current: scrollView.zoomScale,
                fitScale: lastFitScale,
                minimum: scrollView.minimumZoomScale,
                maximum: scrollView.maximumZoomScale
            )
            zoom(to: targetScale, centeredAt: contentPoint, animated: animated)
        }

        private func setZoomScalePreservingViewportCenter(_ targetScale: CGFloat, animated: Bool) {
            let currentScale = max(scrollView.zoomScale, 0.01)
            guard abs(targetScale - currentScale) > 0.001 else { return }

            let viewportCenter = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
            let contentCenter = contentView.convert(viewportCenter, from: scrollView)
            zoom(to: targetScale, centeredAt: contentCenter, animated: animated)
        }

        private func zoom(to targetScale: CGFloat, centeredAt contentPoint: CGPoint, animated: Bool) {
            guard targetScale.isFinite, targetScale > 0, documentSize != .zero else { return }

            let zoomRect = zoomRect(centeredAt: contentPoint, scale: targetScale)

            if animated {
                beginProgrammaticZoom()
                scrollView.zoom(to: zoomRect, animated: true)
                scheduleSettledZoomRefresh()
                return
            }

            scrollView.zoom(to: zoomRect, animated: false)
            finishProgrammaticZoom()
        }

        private func zoomRect(centeredAt contentPoint: CGPoint, scale: CGFloat) -> CGRect {
            let width = scrollView.bounds.width / scale
            let height = scrollView.bounds.height / scale
            let maxX = max(documentSize.width - width, 0)
            let maxY = max(documentSize.height - height, 0)
            let origin = CGPoint(
                x: min(max(contentPoint.x - width / 2, 0), maxX),
                y: min(max(contentPoint.y - height / 2, 0), maxY)
            )
            return CGRect(origin: origin, size: CGSize(width: width, height: height))
        }

        @discardableResult
        private func restorePendingViewportIfPossible() -> Bool {
            guard let viewport = pendingViewport,
                  viewport.isValid,
                  documentSize.width > 0,
                  documentSize.height > 0,
                  scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0 else {
                return false
            }

            isRestoringViewport = true
            defer {
                isRestoringViewport = false
                pendingViewport = nil
            }

            let restoredScale = DrawingZoomLevel.clampedScale(
                viewport.zoomScale,
                minimum: scrollView.minimumZoomScale,
                maximum: scrollView.maximumZoomScale
            )
            didSetInitialZoom = true

            if abs(scrollView.zoomScale - restoredScale) > 0.001 {
                scrollView.setZoomScale(restoredScale, animated: false)
            }

            centerDocument()
            let positionInScrollView = contentView.convert(viewport.center, to: scrollView)
            let proposedOffset = CGPoint(
                x: scrollView.contentOffset.x + positionInScrollView.x - scrollView.bounds.midX,
                y: scrollView.contentOffset.y + positionInScrollView.y - scrollView.bounds.midY
            )
            scrollView.setContentOffset(clampedContentOffset(proposedOffset), animated: false)
            lastObservedContentOffsetY = scrollView.contentOffset.y
            return true
        }

        private func finishProgrammaticZoom() {
            cancelScheduledViewportRefresh()
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            isProgrammaticZooming = false
            programmaticZoomEarliestFinishTime = 0
            lastZoomEndTime = CACurrentMediaTime()
            finishDocumentTraversalIfIdle()
            centerDocument()
            restorePendingProgrammaticScrollIfPossible()
            updateVisiblePage()
            // A Pencil double-tap can update the selected tool while UIKit owns the
            // zoom transform. Reapply it after every settled zoom, including the
            // page-width stroke mode that does not otherwise publish a new tool.
            coordinator?.applyCustomToolIfNeeded()
            publishZoomScale(force: true)
            publishViewport(force: true)
        }

        private func scheduleSettledZoomRefresh() {
            guard settledZoomWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settledZoomWorkItem = nil
                let isBeforeProgrammaticSettleDeadline = self.isProgrammaticZooming
                    && CACurrentMediaTime() < self.programmaticZoomEarliestFinishTime
                guard !self.isPinchZooming,
                      !self.scrollView.isZooming,
                      !self.isScrollViewAnimatingZoom,
                      !self.isDrawingInteractionActive,
                      !isBeforeProgrammaticSettleDeadline else {
                    self.scheduleSettledZoomRefresh()
                    return
                }
                self.finishProgrammaticZoom()
            }
            settledZoomWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + settledZoomDelay, execute: workItem)
        }

        /// UIScrollView can emit several callbacks inside one display interval. Defer the
        /// page-window scan and PencilKit viewport preparation to the next display tick so
        /// those callbacks collapse into one bounded refresh. Nearest-page tracking is
        /// synchronous; expensive external selection/viewport publication settles once.
        private func scheduleViewportRefresh(materializesPages: Bool) {
            hasPendingViewportRefresh = true
            pendingViewportRefreshNeedsMaterialization =
                pendingViewportRefreshNeedsMaterialization || materializesPages

            if viewportRefreshDisplayLink == nil {
                let target = ViewportRefreshDisplayLinkTarget(owner: self)
                let displayLink = CADisplayLink(
                    target: target,
                    selector: #selector(ViewportRefreshDisplayLinkTarget.displayLinkDidFire(_:))
                )
                displayLink.isPaused = true
                displayLink.add(to: .main, forMode: .common)
                viewportRefreshDisplayLinkTarget = target
                viewportRefreshDisplayLink = displayLink
            }
            viewportRefreshDisplayLink?.isPaused = false
        }

        static func requiresViewportResourceRefresh(
            previousRect: CGRect?,
            currentRect: CGRect,
            previousZoomScale: CGFloat,
            currentZoomScale: CGFloat,
            directionChanged: Bool
        ) -> Bool {
            guard let previousRect,
                  !previousRect.isNull,
                  !previousRect.isEmpty,
                  !currentRect.isNull,
                  !currentRect.isEmpty else {
                return true
            }
            guard previousZoomScale.isFinite,
                  currentZoomScale.isFinite,
                  previousZoomScale > 0,
                  currentZoomScale > 0 else {
                return true
            }
            if abs(currentZoomScale - previousZoomScale) / previousZoomScale > 0.01 {
                return true
            }

            let horizontalDelta = abs(previousRect.midX - currentRect.midX)
            let verticalDelta = abs(previousRect.midY - currentRect.midY)
            let horizontalThreshold = max(min(previousRect.width, currentRect.width) * 0.22, 1)
            let verticalThreshold = max(min(previousRect.height, currentRect.height) * 0.22, 1)
            let reversalThreshold = max(min(previousRect.height, currentRect.height) * 0.1, 1)
            let sizeChanged = abs(previousRect.width - currentRect.width) > 0.5
                || abs(previousRect.height - currentRect.height) > 0.5
            let moved = horizontalDelta >= horizontalThreshold
                || verticalDelta >= verticalThreshold
            // A one-pixel finger wobble can flip direction many times. The retained
            // backward window already covers that motion, so only rebalance directional
            // preload after a meaningful reversal.
            let meaningfullyReversed = directionChanged && verticalDelta >= reversalThreshold
            return sizeChanged || moved || meaningfullyReversed
        }

        private func recordViewportResourceRefresh(_ visibleRect: CGRect) {
            lastViewportResourceRefreshRect = visibleRect
            lastViewportResourceRefreshZoomScale = max(scrollView.zoomScale, 0.01)
            lastViewportResourceRefreshDirection = isScrollingTowardLaterPages
            viewportResourceRefreshCount += 1
        }

        private func performScheduledViewportRefresh() {
            guard hasPendingViewportRefresh else {
                viewportRefreshDisplayLink?.isPaused = true
                return
            }

            let materializesPages = pendingViewportRefreshNeedsMaterialization
            hasPendingViewportRefresh = false
            pendingViewportRefreshNeedsMaterialization = false
            // Pause before doing work. If UIKit synchronously emits another scroll callback
            // during materialization, that callback can safely arm the next display tick.
            viewportRefreshDisplayLink?.isPaused = true

            let visibleRect = visibleContentRect()
            // Visibility is cheap and must follow the physical viewport every frame.
            // Keeping it behind the heavier 22% resource hysteresis lets a configured
            // PDF enter the screen while its vector layer is still hidden, exposing an
            // obsolete preview. During pinch we update only this lightweight state.
            if isZoomTransitionActive {
                updatePageVisibility(in: visibleRect)
                return
            }

            let needsResourceRefresh = materializesPages
                && Self.requiresViewportResourceRefresh(
                    previousRect: lastViewportResourceRefreshRect,
                    currentRect: visibleRect,
                    previousZoomScale: lastViewportResourceRefreshZoomScale,
                    currentZoomScale: max(scrollView.zoomScale, 0.01),
                    directionChanged: lastViewportResourceRefreshDirection
                        != isScrollingTowardLaterPages
                )
            guard needsResourceRefresh else {
                updatePageVisibility(in: visibleRect)
                return
            }

            materializePagesNearViewport(updatesRenderScale: true)
            updateNativeDrawingViewports()
        }

        func flushScheduledViewportRefreshForTesting() {
            performScheduledViewportRefresh()
        }

        private func cancelScheduledViewportRefresh() {
            hasPendingViewportRefresh = false
            pendingViewportRefreshNeedsMaterialization = false
            viewportRefreshDisplayLink?.isPaused = true
        }

        private func invalidateScheduledViewportRefresh() {
            cancelScheduledViewportRefresh()
            viewportRefreshDisplayLink?.invalidate()
            viewportRefreshDisplayLink = nil
            viewportRefreshDisplayLinkTarget = nil
        }

        private var isScrollViewAnimatingZoom: Bool {
            if #available(iOS 17.4, *) {
                return scrollView.isZoomAnimating
            }
            return false
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.frame = bounds
            let viewportSizeChanged = scrollView.bounds.size != lastDrawingViewportSize
            lastDrawingViewportSize = scrollView.bounds.size
            if !isUserScrolling && !isZoomTransitionActive {
                updateZoomScalesIfNeeded()
            }
            // UIScrollView owns the zoom transform while a pinch/programmatic zoom is
            // active. Changing content insets from layoutSubviews during that transform
            // makes UIKit repeatedly reposition the zoomed content, which appears as a
            // blink. Re-center once the native zoom transaction has settled instead.
            if !isUserScrolling && !isZoomTransitionActive {
                centerDocument()
            }
            let didRestoreViewport = !isUserScrolling && !isZoomTransitionActive
                ? restorePendingViewportIfPossible()
                : false
            if isUserScrolling || isZoomTransitionActive {
                // Preserve page geometry when SwiftUI requests layout mid-gesture. The
                // display-link pass decides whether the prepared window needs work.
                if viewportSizeChanged {
                    lastViewportResourceRefreshRect = nil
                }
                scheduleViewportRefresh(materializesPages: !isZoomTransitionActive)
            } else {
                // Geometry changes above can synchronously emit didScroll. Settled
                // layout owns the authoritative refresh, so queued work is obsolete.
                cancelScheduledViewportRefresh()
                materializePagesNearViewport()
                updateNativeDrawingViewports(force: viewportSizeChanged)
            }
            restorePendingProgrammaticScrollIfPossible()
            updateVisiblePage()
            publishZoomScale(force: didRestoreViewport)
            publishViewport(force: didRestoreViewport)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let panState = scrollView.panGestureRecognizer.state
            let isActivelyPanning = panState == .began || panState == .changed
            if isActivelyPanning || scrollView.isDragging || scrollView.isDecelerating {
                if !isUserScrolling {
                    cancelProgrammaticPageSelection()
                    coordinator?.beginUserPageSelection()
                    setUserScrolling(true)
                }
            }
            let offsetDelta = scrollView.contentOffset.y - lastObservedContentOffsetY
            if abs(offsetDelta) > 0.5 {
                isScrollingTowardLaterPages = offsetDelta > 0
                lastObservedContentOffsetY = scrollView.contentOffset.y
            }
            scheduleViewportRefresh(
                materializesPages: !isPinchZooming && !isProgrammaticZooming
            )
            if !isPinchZooming && !isProgrammaticZooming {
                updateVisiblePage()
            }
            publishViewport()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            guard scrollView === self.scrollView else { return false }
            let shouldScroll = shouldAllowScrollToTop(at: CACurrentMediaTime())
            if shouldScroll {
                cancelProgrammaticPageSelection()
                coordinator?.beginUserPageSelection()
                setUserScrolling(true)
            }
            return shouldScroll
        }

        /// The native status-bar gesture is normally a single tap. Keep the gesture,
        /// but require a second nearby tap so an accidental touch cannot jump the
        /// reader back to the first page.
        func shouldAllowScrollToTop(at timestamp: CFTimeInterval) -> Bool {
            guard let lastScrollToTopRequestTime,
                  timestamp >= lastScrollToTopRequestTime,
                  timestamp - lastScrollToTopRequestTime <= scrollToTopDoubleTapInterval else {
                self.lastScrollToTopRequestTime = timestamp
                return false
            }

            self.lastScrollToTopRequestTime = nil
            return true
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelProgrammaticPageSelection()
            coordinator?.beginUserPageSelection()
            setUserScrolling(true)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            cancelScheduledViewportRefresh()
            isPinchZooming = true
            setUserScrolling(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // UIScrollView already preserves the pinch anchor. Avoid page-set scans and
            // SwiftUI publication on every zoom sample: rebuilding an all-page PDF
            // configuration just to update the percentage label can hitch the native
            // transform. Only the cheap PDF visibility pass follows each display tick;
            // the settled pass publishes the final scale and viewport once.
            scheduleViewportRefresh(materializesPages: false)
            scheduleSettledZoomRefresh()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isPinchZooming = false
            // Keep the exact user-selected scale. Fit-to-page remains an explicit
            // command; an implicit near-fit snap made a two-finger scroll look like
            // the PDF shrank and expanded at touch-up.
            // Restart the settle timer at touch-up. Finishing synchronously here can
            // materialize pages, load drawings, and retarget PencilKit before a rapid
            // follow-up pinch begins, which makes the next gesture appear to stop.
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            scheduleSettledZoomRefresh()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            finishDocumentTraversal()
            publishViewport(force: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishDocumentTraversal()
            publishViewport(force: true)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard isProgrammaticScrollAnimating else {
                finishDocumentTraversalIfIdle()
                return
            }
            isProgrammaticScrollAnimating = false
            cancelProgrammaticPageSelection()
            guard !isProgrammaticZooming else { return }
            finishDocumentTraversal()
            publishViewport(force: true)
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            finishDocumentTraversal()
            publishViewport(force: true)
        }

        private func configureView() {
            backgroundColor = .systemGroupedBackground

            scrollView.delegate = self
            scrollView.backgroundColor = .clear
            scrollView.alwaysBounceHorizontal = false
            scrollView.alwaysBounceVertical = true
            scrollView.isDirectionalLockEnabled = true
            scrollView.delaysContentTouches = false
            scrollView.canCancelContentTouches = true
            scrollView.keyboardDismissMode = .interactive
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            // Keep UIKit's status-bar gesture enabled so the delegate can require a
            // deliberate double tap before it scrolls the document to page one.
            scrollView.scrollsToTop = true
            scrollView.panGestureRecognizer.allowedTouchTypes = fingerTouchTypes
            scrollView.pinchGestureRecognizer?.allowedTouchTypes = fingerTouchTypes
            addSubview(scrollView)

            contentView.backgroundColor = .clear
            contentView.contentScaleFactor = UIScreen.main.scale
            contentView.layer.contentsScale = UIScreen.main.scale
            contentView.layer.rasterizationScale = UIScreen.main.scale
            contentView.layer.shouldRasterize = false
            scrollView.addSubview(contentView)

            let selectSeamlessAttachment = UITapGestureRecognizer(
                target: self,
                action: #selector(handleSeamlessAttachmentSelection(_:))
            )
            selectSeamlessAttachment.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            selectSeamlessAttachment.cancelsTouchesInView = true
            selectSeamlessAttachment.delegate = self
            selectSeamlessAttachment.isEnabled = false
            contentView.addGestureRecognizer(selectSeamlessAttachment)
            seamlessAttachmentSelectionGesture = selectSeamlessAttachment

            var footerConfiguration = UIButton.Configuration.filled()
            footerConfiguration.image = UIImage(systemName: "plus")
            footerConfiguration.cornerStyle = .capsule
            footerConfiguration.baseForegroundColor = .label
            footerConfiguration.baseBackgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.92)
            addPageFooterButton.configuration = footerConfiguration
            addPageFooterButton.accessibilityIdentifier = "editor.addPageFooter"
            addPageFooterButton.accessibilityLabel = "Add page"
            addPageFooterButton.accessibilityHint = "Adds a new page to the end of this note"
            addPageFooterButton.layer.shadowColor = UIColor.black.cgColor
            addPageFooterButton.layer.shadowOpacity = 0.16
            addPageFooterButton.layer.shadowRadius = 14
            addPageFooterButton.layer.shadowOffset = CGSize(width: 0, height: 8)
            addPageFooterButton.addTarget(self, action: #selector(handleAddPageFooterTapped), for: .touchUpInside)
            contentView.addSubview(addPageFooterButton)
        }

        private func applyWorkspaceTheme(_ theme: BeanNotesTheme) {
            let shouldRevealPaperBackdrop = theme.paperTextureImageName != nil
            backgroundColor = shouldRevealPaperBackdrop ? .clear : .systemGroupedBackground
            isOpaque = !shouldRevealPaperBackdrop
        }

        private func beginProgrammaticZoom() {
            cancelScheduledViewportRefresh()
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            isProgrammaticZooming = true
            programmaticZoomEarliestFinishTime = CACurrentMediaTime() + programmaticZoomSettleDuration
            setUserScrolling(true)
        }

        private func layoutDocument() {
            lastViewportResourceRefreshRect = nil
            guard !orderedPageIDs.isEmpty else {
                pageFrames.removeAll()
                continuousDrawingFrame = nil
                documentSize = .zero
                addPageFooterButton.isHidden = true
                addPageFooterButton.frame = .zero
                updateDocumentGeometry(to: .zero)
                return
            }

            let maxWidth = orderedPageIDs
                .compactMap { pagesByID[$0]?.pageSize.width }
                .max() ?? 0

            var y: CGFloat = 0
            var frames: [UUID: CGRect] = [:]
            var drawingFrame = CGRect.null
            let pageGap = pageFlowMode.usesFlushPageLayout ? 0 : separatedPageGap

            if let topContentView {
                topContentView.frame = CGRect(x: 0, y: 0, width: maxWidth, height: topContentHeight)
                y = topContentHeight + separatedPageGap
            }

            for id in orderedPageIDs {
                guard let page = pagesByID[id] else { continue }
                let size = page.pageSize
                let frame = CGRect(
                    x: (maxWidth - size.width) / 2,
                    y: y,
                    width: size.width,
                    height: size.height
                )
                if let pageView = pageViews[id] {
                    pageView.frame = frame
                    pageView.layoutPage()
                }

                frames[id] = frame
                drawingFrame = drawingFrame.union(frame)
                y += size.height + pageGap
            }

            if y > 0 {
                y -= pageGap
            }

            let footerY = y + addPageFooterTopPadding
            addPageFooterButton.isHidden = false
            let extendsScrollableDocument = pageFlowMode.usesFlushPageLayout
            addPageFooterButton.accessibilityLabel = extendsScrollableDocument
                ? "Add drawing space"
                : "Add page"
            addPageFooterButton.accessibilityHint = extendsScrollableDocument
                ? "Adds drawing space to the end of this note"
                : "Adds a new page to the end of this note"
            addPageFooterButton.frame = CGRect(
                x: (maxWidth - addPageFooterSize) / 2,
                y: footerY,
                width: addPageFooterSize,
                height: addPageFooterSize
            )
            y = footerY + addPageFooterSize + addPageFooterBottomPadding

            pageFrames = frames
            continuousDrawingFrame = drawingFrame.isNull ? nil : drawingFrame
            documentSize = CGSize(width: maxWidth, height: y)
            updateDocumentGeometry(to: documentSize)
            centerDocument()
            if isCaptureToolEnabled {
                updateCaptureSelectionOverlay()
            }
        }

        private func configureContinuousPageViewIfNeeded(reloadsDrawing: Bool) {
            guard pageFlowMode.usesDocumentWideCanvas,
                  let drawingStorage,
                  let coordinator,
                  let representativePage = orderedPageIDs.first.flatMap({ pagesByID[$0] }),
                  let drawingFrame = continuousDrawingFrame,
                  drawingFrame.width > 0,
                  drawingFrame.height > 0 else {
                releaseContinuousPageView(flushDrawingBeforeRelease: false)
                return
            }

            if let continuousPageView, !reloadsDrawing {
                continuousPageView.frame = drawingFrame
                continuousPageView.applyInputMode(inputMode)
                continuousPageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
                return
            }

            let loadBundle = continuousDrawingLoadBundle(storage: drawingStorage)
            if loadBundle.drawing == nil, let continuousPageView {
                // Keep the already materialized drawing when a relayout encounters a
                // transient read failure. Replacing it with a partial aggregate could
                // erase the page that failed to load on the next split save.
                continuousPageView.frame = drawingFrame
                continuousPageView.applyInputMode(inputMode)
                continuousPageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
                return
            }

            releaseContinuousPageView(flushDrawingBeforeRelease: false)
            continuousPageDrawingCache = Dictionary(
                uniqueKeysWithValues: loadBundle.results.map { page, result in
                    (page.id, result.drawing)
                }
            )
            let pageView = PageCanvasView(frame: drawingFrame)
            continuousPageView = pageView
            contentView.addSubview(pageView)
            pageView.configureContinuousDrawingOverlay(
                representativePage: representativePage,
                pageSize: drawingFrame.size,
                drawing: loadBundle.drawing ?? PKDrawing(),
                drawingLoadResults: loadBundle.results,
                inputMode: inputMode,
                coordinator: coordinator,
                pageIDForPageAction: { [weak self] localPoint in
                    guard let self,
                          let continuousFrame = self.continuousDrawingFrame else {
                        return nil
                    }

                    let documentPoint = CGPoint(
                        x: continuousFrame.minX + localPoint.x,
                        y: continuousFrame.minY + localPoint.y
                    )
                    return self.pageID(containing: documentPoint)
                },
                canRemovePage: orderedPageIDs.count > 1,
                pageActionRequested: { [weak coordinator] pageID, action in
                    coordinator?.requestPageAction(action, for: pageID)
                },
                pageContextMenuWillOpen: { [weak coordinator] pageID in
                    coordinator?.selectPageForContextMenu(pageID)
                }
            )
            pageView.prioritizePageActionGestures(over: fingerDoubleTapGesture)
            if let seamlessAttachmentSelectionGesture {
                pageView.canvasView.drawingGestureRecognizer.require(
                    toFail: seamlessAttachmentSelectionGesture
                )
            }
            pageView.setDocumentTraversalActive(effectivePDFTraversalActive)
            pageView.setDrawingInteractionActive(effectivePDFDrawingProtectionActive)
            pageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
        }

        private func continuousDrawingLoadBundle(
            storage: DrawingStorageService
        ) -> ContinuousDrawingLoadBundle {
            guard let drawingFrame = continuousDrawingFrame else {
                return ContinuousDrawingLoadBundle(drawing: PKDrawing(), results: [])
            }

            var joinedStrokes: [PKStroke] = []
            var seenStrokes: Set<ContinuousStrokeSignature> = []
            var results: [(NotePage, DrawingStorageService.LoadResult)] = []
            var encounteredUnavailableDrawing = false
            for id in orderedPageIDs {
                guard let page = pagesByID[id], let frame = pageFrames[id] else { continue }
                let loadResult = storage.loadDrawingResult(for: page)
                results.append((page, loadResult))
                if loadResult.error != nil {
                    encounteredUnavailableDrawing = true
                    continue
                }
                let translation = CGAffineTransform(
                    translationX: frame.minX - drawingFrame.minX,
                    y: frame.minY - drawingFrame.minY
                )
                let translatedDrawing = loadResult.drawing.transformed(using: translation)
                let pageInterior = frame.offsetBy(
                    dx: -drawingFrame.minX,
                    dy: -drawingFrame.minY
                ).insetBy(dx: 0.5, dy: 0.5)
                for stroke in translatedDrawing.strokes {
                    // Only boundary strokes can be duplicated across page archives.
                    // Ordinary handwriting needs no full path hashing at document open.
                    if pageInterior.contains(stroke.renderBounds) {
                        joinedStrokes.append(stroke)
                        continue
                    }
                    let signature = continuousStrokeSignature(stroke)
                    if seenStrokes.insert(signature).inserted {
                        joinedStrokes.append(stroke)
                    }
                }
            }
            return ContinuousDrawingLoadBundle(
                drawing: encounteredUnavailableDrawing ? nil : PKDrawing(strokes: joinedStrokes),
                results: results
            )
        }

        func retryContinuousDrawingLoad(
            for canvasView: PKCanvasView
        ) -> ContinuousDrawingLoadBundle? {
            guard let continuousPageView,
                  continuousPageView.canvasView === canvasView,
                  let drawingStorage else { return nil }

            let bundle = continuousDrawingLoadBundle(storage: drawingStorage)
            if bundle.drawing != nil {
                continuousPageDrawingCache = Dictionary(
                    uniqueKeysWithValues: bundle.results.map { page, result in
                        (page.id, result.drawing)
                    }
                )
            }
            return bundle
        }

        private func continuousStrokeSignature(_ stroke: PKStroke) -> ContinuousStrokeSignature {
            let transform = stroke.transform
            var points: [ContinuousStrokePointSignature] = []
            points.reserveCapacity(stroke.path.count)
            for index in 0..<stroke.path.count {
                let point = stroke.path[index]
                let location = point.location.applying(transform)
                points.append(
                    ContinuousStrokePointSignature(
                        x: quantizedContinuousValue(location.x),
                        y: quantizedContinuousValue(location.y),
                        width: quantizedContinuousValue(point.size.width),
                        height: quantizedContinuousValue(point.size.height),
                        opacity: quantizedContinuousValue(point.opacity),
                        force: quantizedContinuousValue(point.force)
                    )
                )
            }
            let masks = stroke.maskedPathRanges.map {
                ContinuousStrokeMaskSignature(
                    lowerBound: quantizedContinuousValue($0.lowerBound),
                    upperBound: quantizedContinuousValue($0.upperBound)
                )
            }
            return ContinuousStrokeSignature(
                inkType: stroke.ink.inkType.rawValue,
                color: stroke.ink.color.hexRGB,
                pointCount: stroke.path.count,
                creationTime: stroke.path.creationDate.timeIntervalSinceReferenceDate.bitPattern,
                points: points,
                masks: masks
            )
        }

        private func quantizedContinuousValue(_ value: CGFloat) -> Int64 {
            guard value.isFinite else { return 0 }
            return Int64((value * 10_000).rounded())
        }

        private func continuousStrokeIdentity(_ stroke: PKStroke) -> ContinuousStrokeIdentity {
            let firstLocation = stroke.path.isEmpty ? .zero : stroke.path[0].location
            let lastLocation = stroke.path.isEmpty
                ? .zero
                : stroke.path[stroke.path.count - 1].location
            return ContinuousStrokeIdentity(
                inkType: stroke.ink.inkType.rawValue,
                creationTime: stroke.path.creationDate.timeIntervalSinceReferenceDate.bitPattern,
                pointCount: stroke.path.count,
                firstX: quantizedContinuousValue(firstLocation.x),
                firstY: quantizedContinuousValue(firstLocation.y),
                lastX: quantizedContinuousValue(lastLocation.x),
                lastY: quantizedContinuousValue(lastLocation.y)
            )
        }

        private func continuousStrokeState(_ stroke: PKStroke) -> ContinuousStrokeState {
            let transform = stroke.transform
            let bounds = stroke.renderBounds
            return ContinuousStrokeState(
                transform: [
                    transform.a,
                    transform.b,
                    transform.c,
                    transform.d,
                    transform.tx,
                    transform.ty
                ].map(quantizedContinuousValue),
                renderBounds: [
                    bounds.minX,
                    bounds.minY,
                    bounds.maxX,
                    bounds.maxY
                ].map(quantizedContinuousValue),
                masks: stroke.maskedPathRanges.map {
                    ContinuousStrokeMaskSignature(
                        lowerBound: quantizedContinuousValue($0.lowerBound),
                        upperBound: quantizedContinuousValue($0.upperBound)
                    )
                }
            )
        }

        /// Resolves the page sections changed by a document-wide PencilKit update.
        /// The common pen/highlighter path examines only the appended stroke. Erase,
        /// lasso, and undo compare lightweight stroke identities/mutable state without
        /// hashing every point in the document on the main input thread.
        func changedContinuousPageIDs(
            from previousDrawing: PKDrawing,
            to drawing: PKDrawing,
            allowsSingleStrokeFastPath: Bool
        ) -> Set<UUID> {
            guard isContinuousDrawingEnabled else { return [] }

            let previousStrokes = previousDrawing.strokes
            let strokes = drawing.strokes
            var mutations: [ContinuousStrokeMutation] = []
            let preservesStrokeOrder = strokes.count == previousStrokes.count
                && zip(previousStrokes, strokes).allSatisfy { previous, current in
                    continuousStrokeIdentity(previous) == continuousStrokeIdentity(current)
                }

            if allowsSingleStrokeFastPath,
               strokes.count == previousStrokes.count + 1,
               continuousDrawingPrefixIsUnchanged(
                   previousStrokes: previousStrokes,
                   strokes: strokes
               ),
               let appendedStroke = strokes.last {
                mutations = [ContinuousStrokeMutation(previous: nil, current: appendedStroke)]
            } else if allowsSingleStrokeFastPath,
                      previousStrokes.count == strokes.count + 1,
                      continuousDrawingPrefixIsUnchanged(
                          previousStrokes: strokes,
                          strokes: previousStrokes
                      ),
                      let removedStroke = previousStrokes.last {
                mutations = [ContinuousStrokeMutation(previous: removedStroke, current: nil)]
            } else if preservesStrokeOrder {
                for (previous, current) in zip(previousStrokes, strokes) {
                    if continuousStrokeState(previous) != continuousStrokeState(current) {
                        mutations.append(ContinuousStrokeMutation(
                            previous: previous,
                            current: current
                        ))
                    }
                }
            } else {
                var previousByIdentity: [ContinuousStrokeIdentity: [PKStroke]] = [:]
                previousByIdentity.reserveCapacity(previousStrokes.count)
                for stroke in previousStrokes {
                    previousByIdentity[continuousStrokeIdentity(stroke), default: []]
                        .append(stroke)
                }

                for stroke in strokes {
                    let identity = continuousStrokeIdentity(stroke)
                    if var candidates = previousByIdentity[identity],
                       !candidates.isEmpty {
                        let currentState = continuousStrokeState(stroke)
                        let matchIndex = candidates.firstIndex {
                            continuousStrokeState($0) == currentState
                        } ?? (candidates.count - 1)
                        let previousStroke = candidates.remove(at: matchIndex)
                        previousByIdentity[identity] = candidates.isEmpty
                            ? nil
                            : candidates
                        if continuousStrokeState(previousStroke) != currentState {
                            mutations.append(ContinuousStrokeMutation(
                                previous: previousStroke,
                                current: stroke
                            ))
                        }
                    } else {
                        mutations.append(ContinuousStrokeMutation(previous: nil, current: stroke))
                    }
                }
                for removedStroke in previousByIdentity.values.flatMap({ $0 }) {
                    mutations.append(ContinuousStrokeMutation(previous: removedStroke, current: nil))
                }
            }

            var changedPageIDs: Set<UUID> = []
            for mutation in mutations {
                if let previous = mutation.previous {
                    changedPageIDs.formUnion(continuousPageIDs(intersecting: previous.renderBounds))
                }
                if let current = mutation.current {
                    changedPageIDs.formUnion(continuousPageIDs(intersecting: current.renderBounds))
                }
            }
            if changedPageIDs.isEmpty,
               !mutations.isEmpty,
               let fallbackPageID = currentSelectedPageID ?? orderedPageIDs.first {
                changedPageIDs.insert(fallbackPageID)
            }
            if !mutations.isEmpty {
                updateContinuousPageDrawingCache(
                    mutations: mutations,
                    currentDrawing: drawing,
                    changedPageIDs: changedPageIDs
                )
            }
            return changedPageIDs
        }

        private func continuousDrawingPrefixIsUnchanged(
            previousStrokes: [PKStroke],
            strokes: [PKStroke]
        ) -> Bool {
            guard strokes.count == previousStrokes.count + 1 else { return false }
            guard let previousFirst = previousStrokes.first,
                  let previousLast = previousStrokes.last else {
                return previousStrokes.isEmpty
            }
            return continuousStrokeIdentity(previousFirst)
                    == continuousStrokeIdentity(strokes[0])
                && continuousStrokeState(previousFirst)
                    == continuousStrokeState(strokes[0])
                && continuousStrokeIdentity(previousLast)
                    == continuousStrokeIdentity(strokes[previousStrokes.count - 1])
                && continuousStrokeState(previousLast)
                    == continuousStrokeState(strokes[previousStrokes.count - 1])
        }

        private func continuousPageIDs(intersecting drawingBounds: CGRect) -> Set<UUID> {
            guard let drawingFrame = continuousDrawingFrame,
                  drawingBounds.minX.isFinite,
                  drawingBounds.minY.isFinite,
                  drawingBounds.maxX.isFinite,
                  drawingBounds.maxY.isFinite else { return [] }
            let documentBounds = drawingBounds
                .insetBy(dx: -0.5, dy: -0.5)
                .offsetBy(dx: drawingFrame.minX, dy: drawingFrame.minY)
            return Set(pageIDsIntersecting(documentBounds))
        }

        /// Applies the small stroke delta to page-local snapshots. Autosave can then
        /// persist one or two immutable page drawings without rescanning the aggregate
        /// canvas during the next user's first stroke after an idle interval.
        private func updateContinuousPageDrawingCache(
            mutations: [ContinuousStrokeMutation],
            currentDrawing: PKDrawing,
            changedPageIDs: Set<UUID>
        ) {
            guard !changedPageIDs.isEmpty else { return }

            var strokesByPageID: [UUID: [PKStroke]] = [:]
            var pageIDsNeedingRebuild: Set<UUID> = []
            for pageID in changedPageIDs {
                if let drawing = continuousPageDrawingCache[pageID] {
                    strokesByPageID[pageID] = drawing.strokes
                } else {
                    pageIDsNeedingRebuild.insert(pageID)
                }
            }

            for mutation in mutations {
                let previousPageIDs = mutation.previous
                    .map { continuousPageIDs(intersecting: $0.renderBounds) }
                    ?? []
                let currentPageIDs = mutation.current
                    .map { continuousPageIDs(intersecting: $0.renderBounds) }
                    ?? []
                let sharedPageIDs = previousPageIDs.intersection(currentPageIDs)

                if let previous = mutation.previous,
                   let current = mutation.current {
                    let previousIdentity = continuousStrokeIdentity(previous)
                    for pageID in sharedPageIDs where !pageIDsNeedingRebuild.contains(pageID) {
                        guard var pageStrokes = strokesByPageID[pageID],
                              let localizedPrevious = localizedContinuousStroke(
                                  previous,
                                  for: pageID
                              ),
                              let localizedCurrent = localizedContinuousStroke(
                                  current,
                                  for: pageID
                              ) else {
                            pageIDsNeedingRebuild.insert(pageID)
                            continue
                        }
                        let previousState = continuousStrokeState(localizedPrevious)
                        let index = pageStrokes.firstIndex {
                            continuousStrokeIdentity($0) == previousIdentity
                                && continuousStrokeState($0) == previousState
                        } ?? pageStrokes.firstIndex {
                            continuousStrokeIdentity($0) == previousIdentity
                        }
                        if let index {
                            pageStrokes[index] = localizedCurrent
                        } else {
                            pageIDsNeedingRebuild.insert(pageID)
                        }
                        strokesByPageID[pageID] = pageStrokes
                    }
                }

                if let previous = mutation.previous {
                    let previousIdentity = continuousStrokeIdentity(previous)
                    for pageID in previousPageIDs.subtracting(currentPageIDs)
                    where !pageIDsNeedingRebuild.contains(pageID) {
                        guard var pageStrokes = strokesByPageID[pageID],
                              let localizedPrevious = localizedContinuousStroke(
                                  previous,
                                  for: pageID
                              ) else {
                            pageIDsNeedingRebuild.insert(pageID)
                            continue
                        }
                        let previousState = continuousStrokeState(localizedPrevious)
                        let index = pageStrokes.firstIndex {
                            continuousStrokeIdentity($0) == previousIdentity
                                && continuousStrokeState($0) == previousState
                        } ?? pageStrokes.firstIndex {
                            continuousStrokeIdentity($0) == previousIdentity
                        }
                        guard let index else {
                            pageIDsNeedingRebuild.insert(pageID)
                            continue
                        }
                        pageStrokes.remove(at: index)
                        strokesByPageID[pageID] = pageStrokes
                    }
                }

                if let current = mutation.current {
                    for pageID in currentPageIDs.subtracting(previousPageIDs)
                    where !pageIDsNeedingRebuild.contains(pageID) {
                        guard let localizedCurrent = localizedContinuousStroke(
                            current,
                            for: pageID
                        ) else {
                            pageIDsNeedingRebuild.insert(pageID)
                            continue
                        }
                        strokesByPageID[pageID, default: []].append(localizedCurrent)
                    }
                }
            }

            for (pageID, strokes) in strokesByPageID
            where !pageIDsNeedingRebuild.contains(pageID) {
                continuousPageDrawingCache[pageID] = PKDrawing(strokes: strokes)
            }

            if !pageIDsNeedingRebuild.isEmpty,
               let rebuilt = splitContinuousPageDrawings(
                   from: currentDrawing,
                   pageIDs: pageIDsNeedingRebuild
               ) {
                for (page, drawing) in rebuilt {
                    continuousPageDrawingCache[page.id] = drawing
                }
            }
        }

        private func localizedContinuousStroke(
            _ stroke: PKStroke,
            for pageID: UUID
        ) -> PKStroke? {
            guard let drawingFrame = continuousDrawingFrame,
                  let pageFrame = pageFrames[pageID] else { return nil }
            let localSegmentFrame = pageFrame.offsetBy(
                dx: -drawingFrame.minX,
                dy: -drawingFrame.minY
            )
            return PKDrawing(strokes: [stroke]).transformed(
                using: CGAffineTransform(
                    translationX: -localSegmentFrame.minX,
                    y: -localSegmentFrame.minY
                )
            ).strokes.first
        }

        func continuousPageDrawings(
            from drawing: PKDrawing,
            pageIDs requestedPageIDs: Set<UUID>? = nil
        ) -> [(NotePage, PKDrawing)]? {
            guard isContinuousDrawingEnabled else { return nil }

            let orderedTargetPageIDs = requestedPageIDs.map { continuousPageIDs(in: $0) }
                ?? orderedPageIDs
            let cached = orderedTargetPageIDs.compactMap { pageID -> (NotePage, PKDrawing)? in
                guard let page = pagesByID[pageID],
                      let drawing = continuousPageDrawingCache[pageID] else { return nil }
                return (page, drawing)
            }
            if cached.count == orderedTargetPageIDs.count {
                return cached
            }
            return splitContinuousPageDrawings(from: drawing, pageIDs: requestedPageIDs)
        }

        private func splitContinuousPageDrawings(
            from drawing: PKDrawing,
            pageIDs requestedPageIDs: Set<UUID>? = nil
        ) -> [(NotePage, PKDrawing)]? {
            guard isContinuousDrawingEnabled,
                  let drawingFrame = continuousDrawingFrame else { return nil }
            continuousAggregateSplitCount += 1

            let orderedTargetPageIDs = requestedPageIDs.map { continuousPageIDs(in: $0) }
                ?? orderedPageIDs
            var strokesByPageID: [UUID: [PKStroke]] = Dictionary(
                uniqueKeysWithValues: orderedTargetPageIDs.map { ($0, []) }
            )
            for stroke in drawing.strokes {
                let bounds = stroke.renderBounds.insetBy(dx: -0.5, dy: -0.5)
                let documentBounds = bounds.offsetBy(
                    dx: drawingFrame.minX,
                    dy: drawingFrame.minY
                )
                let intersectingIDs: [UUID]
                if requestedPageIDs == nil {
                    intersectingIDs = pageIDsIntersecting(documentBounds)
                } else {
                    intersectingIDs = orderedTargetPageIDs.filter {
                        pageFrames[$0]?.intersects(documentBounds) == true
                    }
                }
                for id in intersectingIDs {
                    strokesByPageID[id, default: []].append(stroke)
                }
            }

            return orderedTargetPageIDs.compactMap { id in
                guard let page = pagesByID[id], let frame = pageFrames[id] else { return nil }
                let localSegmentFrame = frame.offsetBy(
                    dx: -drawingFrame.minX,
                    dy: -drawingFrame.minY
                )
                let pageDrawing = PKDrawing(strokes: strokesByPageID[id] ?? []).transformed(
                    using: CGAffineTransform(
                        translationX: -localSegmentFrame.minX,
                        y: -localSegmentFrame.minY
                    )
                )
                return (page, pageDrawing)
            }
        }

        private func arrangeDocumentLayers() {
            if let continuousPageView {
                contentView.bringSubviewToFront(continuousPageView)
                for id in orderedPageIDs {
                    guard let pageView = pageViews[id], let frame = pageFrames[id] else { continue }
                    pageView.presentForegroundImages(in: contentView, documentFrame: frame)
                    pageView.presentAttachmentEditingControls(in: contentView, documentFrame: frame)
                }
            }
            if let topContentView {
                contentView.bringSubviewToFront(topContentView)
            }
            if let captureSelectionOverlay {
                contentView.bringSubviewToFront(captureSelectionOverlay)
            }
            contentView.bringSubviewToFront(addPageFooterButton)
        }

        private func applyCaptureInteractionState() {
            continuousPageView?.setCaptureInteractionEnabled(isCaptureToolEnabled)
            for pageView in pageViews.values {
                pageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
            }
            seamlessAttachmentSelectionGesture?.isEnabled = pageFlowMode.usesDocumentWideCanvas
                && !isCaptureToolEnabled
        }

        private func updateCaptureSelectionOverlay(resetSelection: Bool = false) {
            guard isCaptureToolEnabled,
                  let pageID = selectedPageID ?? currentSelectedPageID ?? orderedPageIDs.first,
                  let pageFrame = pageFrames[pageID],
                  pagesByID[pageID] != nil else {
                captureSelectionOverlay?.isHidden = true
                return
            }

            let overlay = captureSelectionOverlay ?? {
                let overlay = NoteCaptureSelectionOverlayView()
                captureSelectionOverlay = overlay
                contentView.addSubview(overlay)
                return overlay
            }()
            let changesPage = captureSelectionPageID != pageID
            let selectionFrame: CGRect
            if resetSelection || changesPage || overlay.frame.isEmpty {
                selectionFrame = NoteCaptureSelectionGeometry.initialFrame(in: pageFrame)
            } else {
                selectionFrame = NoteCaptureSelectionGeometry.movedFrame(
                    from: overlay.frame,
                    translation: .zero,
                    in: pageFrame
                )
            }

            captureSelectionPageID = pageID
            overlay.configure(
                selectionFrame: selectionFrame,
                within: pageFrame
            ) { [weak self] selectionFrame in
                self?.requestCapture(selectionFrame, from: pageID)
            }
            arrangeDocumentLayers()
        }

        private func requestCapture(_ documentRect: CGRect, from pageID: UUID) {
            guard let page = pagesByID[pageID],
                  let pageFrame = pageFrames[pageID],
                  let coordinator,
                  let overlay = captureSelectionOverlay else {
                return
            }

            let capturePageIDs = continuousPageView == nil ? [pageID] : orderedPageIDs
            if let error = coordinator.drawingLoadFailure(for: capturePageIDs) {
                coordinator.reportCaptureFailure(error, overlay: overlay)
                return
            }

            let selectionRect = documentRect.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
            let drawing: PKDrawing
            if let continuousPageView,
               let pageDrawing = continuousPageDrawings(from: continuousPageView.canvasView.drawing)?
                .first(where: { $0.0.id == pageID })?.1 {
                drawing = pageDrawing
            } else if let pageView = pageViews[pageID], pageView.canvasView.delegate != nil {
                drawing = pageView.canvasView.drawing
            } else if let drawingStorage {
                switch drawingStorage.loadDrawingResult(for: page) {
                case let .loaded(loadedDrawing, _):
                    drawing = loadedDrawing
                case .missing:
                    drawing = PKDrawing()
                case let .unavailable(error):
                    coordinator.reportCaptureFailure(error, overlay: overlay)
                    return
                }
            } else {
                drawing = PKDrawing()
            }

            coordinator.captureSelection(
                page: page,
                drawing: drawing,
                selectionRect: selectionRect,
                overlay: overlay
            )
        }

        private func releaseContinuousPageView(flushDrawingBeforeRelease: Bool) {
            guard let continuousPageView else { return }
            for pageView in pageViews.values {
                pageView.restoreForegroundImagesToPage()
                pageView.restoreAttachmentEditingControlsToPage()
            }
            if let page = continuousPageView.page {
                coordinator?.unregister(
                    canvasView: continuousPageView.canvasView,
                    page: page,
                    flushDrawingBeforeRelease: flushDrawingBeforeRelease
                )
            }
            continuousPageView.releaseHeavyResources()
            continuousPageView.removeFromSuperview()
            self.continuousPageView = nil
            continuousPageDrawingCache.removeAll(keepingCapacity: false)
        }

        /// Resizes the zoomable document without assigning `frame` while UIKit owns a
        /// non-identity zoom transform. Updating bounds and center keeps the logical
        /// page coordinate space intact and makes the full scaled document reachable.
        private func updateDocumentGeometry(to size: CGSize) {
            let scale = scrollView.zoomScale.isFinite && scrollView.zoomScale > 0
                ? scrollView.zoomScale
                : 1
            let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)

            contentView.bounds = CGRect(origin: .zero, size: size)
            scrollView.contentSize = scaledSize
            contentView.center = CGPoint(x: scaledSize.width / 2, y: scaledSize.height / 2)
        }

        private func updateZoomScalesIfNeeded(force: Bool = false) {
            guard documentSize.width > 0, documentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            // Freeze limits and fit geometry while UIKit owns a live transform. A
            // sub-pixel layout update must not clamp or re-fit an active scroll/pinch.
            guard !didSetInitialZoom || (!isUserScrolling && !isZoomTransitionActive) else { return }

            let widthFit = (bounds.width - pageMargin * 2) / documentSize.width
            let fitScale = min(max(widthFit, 0.18), 1.35)
            let minimumZoomScale = max(fitScale * zoomOutMultiplier, absoluteMinimumZoomScale)
            let maximumZoomScale = max(renderQuality.maximumZoomScale, fitScale * renderQuality.maximumZoomFitMultiplier)
            let previousFitScale = lastFitScale
            let fitScaleChanged = abs(fitScale - previousFitScale) > 0.001
            let wasAtPreviousFitScale = didSetInitialZoom
                && !isPinchZooming
                && !isProgrammaticZooming
                && abs(scrollView.zoomScale - previousFitScale)
                    <= max(0.001, previousFitScale * 0.001)

            scrollView.minimumZoomScale = minimumZoomScale
            scrollView.maximumZoomScale = maximumZoomScale
            // Keep the previous fit anchor across sub-pixel layout jitter. Small
            // incremental split-view/rotation changes then accumulate until they are
            // meaningful, while an exactly fitted viewport still follows the resize.
            if !didSetInitialZoom || fitScaleChanged {
                lastFitScale = fitScale
            }

            let adjustedZoomScale: CGFloat?
            if !didSetInitialZoom || (fitScaleChanged && wasAtPreviousFitScale) {
                adjustedZoomScale = fitScale
                didSetInitialZoom = true
            } else if scrollView.zoomScale < minimumZoomScale {
                adjustedZoomScale = minimumZoomScale
            } else if scrollView.zoomScale > maximumZoomScale {
                adjustedZoomScale = maximumZoomScale
            } else {
                adjustedZoomScale = nil
            }

            if let adjustedZoomScale,
               abs(adjustedZoomScale - scrollView.zoomScale) > 0.001 {
                scrollView.setZoomScale(adjustedZoomScale, animated: false)
            }

            updateRasterScale(force: force)
            publishZoomScale(force: force)
        }

        private func selectedPageOverviewScale() -> CGFloat {
            guard bounds.width > 0, bounds.height > 0 else { return lastFitScale }

            let selectedFrame = selectedPageID.flatMap { pageFrames[$0] }
                ?? orderedPageIDs.first.flatMap { pageFrames[$0] }

            guard let selectedFrame, selectedFrame.width > 0, selectedFrame.height > 0 else {
                return lastFitScale
            }

            let widthFit = (bounds.width - pageMargin * 2) / selectedFrame.width
            let heightFit = (bounds.height - 164) / selectedFrame.height
            let overviewScale = min(widthFit, heightFit)
            return min(max(overviewScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        }

        private func centerDocument() {
            guard documentSize != .zero,
                  !isUserScrolling,
                  !isZoomTransitionActive else { return }

            let scaledWidth = documentSize.width * scrollView.zoomScale
            let horizontalInset = max((bounds.width - scaledWidth) / 2, pageMargin)
            let verticalInset: CGFloat = 92

            let inset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: max(120, verticalInset),
                right: horizontalInset
            )
            guard scrollView.contentInset.distance(to: inset) > 0.5 else { return }
            scrollView.contentInset = inset
        }

        private func updateRasterScale(force: Bool = false, reloadImageVariants: Bool = true) {
            // Do not rebuild PencilKit's backing layers in the middle of a native zoom.
            // SwiftUI republishes the zoom value for the controls, which otherwise makes
            // updateUIView reconfigure the canvas several times per second and causes ink
            // to disappear/reappear. finishProgrammaticZoom applies the latest scale once.
            guard !isZoomTransitionActive else { return }

            let screenScale = window?.screen.scale ?? UIScreen.main.scale
            let zoomScale = max(scrollView.zoomScale, 1)
            let targetScale = zoomScale * screenScale
            let backgroundScale = min(targetScale, screenScale * renderQuality.backgroundScaleMultiplier)
            let imageScale = min(targetScale, screenScale * renderQuality.imageScaleMultiplier)
            let backgroundScaleChanged = abs(backgroundScale - lastBackgroundRenderScale) > renderScaleChangeThreshold
            let imageScaleChanged = abs(imageScale - lastImageRenderScale) > renderScaleChangeThreshold

            guard force || backgroundScaleChanged || imageScaleChanged else { return }

            lastBackgroundRenderScale = backgroundScale
            lastImageRenderScale = imageScale

            topContentView?.applyOwnedBackingScale(targetScale)

            for pageView in pageViews.values {
                pageView.updateRenderScale(
                    backgroundScale: backgroundScale,
                    imageScale: imageScale,
                    reloadImageVariants: reloadImageVariants,
                    force: force
                )
            }
            continuousPageView?.updateRenderScale(
                backgroundScale: backgroundScale,
                imageScale: imageScale,
                reloadImageVariants: false,
                force: force
            )
        }

        @discardableResult
        private func materializePagesNearViewport(
            updatesRenderScale: Bool = true,
            refreshesExistingPages: Bool = false,
            prunesTraversalResources: Bool = false
        ) -> Bool {
            guard !orderedPageIDs.isEmpty else {
                DrawingStorageService.cancelPrefetches(scopeID: drawingPrefetchScopeID)
                lastDrawingPrefetchSignature = nil
                lastViewportResourceRefreshRect = nil
                return false
            }
            guard let drawingStorage, let coordinator else { return false }

            let visibleRect = visibleContentRect()
            if !isDrawingInteractionActive {
                prefetchDrawingFiles(around: visibleRect, drawingStorage: drawingStorage)
            }
            let activeRect = directionalPreloadRect(
                around: visibleRect,
                forwardScreenPadding: pageForwardPreloadScreenPadding,
                backwardScreenPadding: pageBackwardPreloadScreenPadding,
                minimumForwardPadding: minimumPageForwardPreloadPadding,
                minimumBackwardPadding: minimumPageBackwardPreloadPadding
            )
            let imageActiveRect = imageLoadingContentRect(visibleRect: visibleRect)
            let defersHeavyImageWork = isPinchZooming || isProgrammaticZooming
            var neededIDs = Set(pageIDsIntersecting(activeRect))
            var retainedIDs = neededIDs

            if isUserScrolling, !prunesTraversalResources {
                let retentionPadding = max(
                    visibleRect.height * scrollingPageRetentionScreens,
                    minimumPageForwardPreloadPadding
                )
                retainedIDs.formUnion(
                    pageIDsIntersecting(
                        activeRect.insetBy(dx: 0, dy: -retentionPadding)
                    )
                )
            }

            // The selected page owns the active PencilKit canvas. It must never be retired
            // merely because UIScrollView briefly reports an offset outside the preload
            // rectangle while a touch, pinch, or inset adjustment is in progress.
            // Releasing it clears PKCanvasView's in-memory drawing and makes ink vanish.
            if let selectedPageID {
                neededIDs.insert(selectedPageID)
                retainedIDs.insert(selectedPageID)
            }
            if let activeDrawingPageID {
                neededIDs.insert(activeDrawingPageID)
                retainedIDs.insert(activeDrawingPageID)
            }

            if neededIDs.isEmpty, let firstID = selectedPageID ?? orderedPageIDs.first {
                neededIDs.insert(firstID)
                retainedIDs.insert(firstID)
            }

            var didChangeMaterializedPages = false

            // The preload window is intentionally a Set for cheap retention checks,
            // but Set iteration made visible JPEG requests land behind arbitrary
            // offscreen pages on the serial decode queue. Rank the small window so
            // first-frame latency is deterministic without expanding its size.
            let orderedNeededIDs = neededIDs.sorted { lhs, rhs in
                let lhsIsVisible = pageFrame(id: lhs, intersects: visibleRect)
                let rhsIsVisible = pageFrame(id: rhs, intersects: visibleRect)
                if lhsIsVisible != rhsIsVisible {
                    return lhsIsVisible
                }

                let lhsDistance = pageFrames[lhs]
                    .map { abs($0.midY - visibleRect.midY) }
                    ?? .greatestFiniteMagnitude
                let rhsDistance = pageFrames[rhs]
                    .map { abs($0.midY - visibleRect.midY) }
                    ?? .greatestFiniteMagnitude
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }

                let lhsOrder = pagesByID[lhs]?.pageOrder ?? Int.max
                let rhsOrder = pagesByID[rhs]?.pageOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return lhs.uuidString < rhs.uuidString
            }

            for id in orderedNeededIDs {
                let shouldLoadImages = pageFrame(id: id, intersects: imageActiveRect)
                if materializePageView(
                    id: id,
                    drawingStorage: drawingStorage,
                    coordinator: coordinator,
                    shouldLoadImages: shouldLoadImages,
                    updatesImageLoadingState: !defersHeavyImageWork
                        && (!isUserScrolling || shouldLoadImages),
                    refreshesExistingPage: refreshesExistingPages
                ) {
                    didChangeMaterializedPages = true
                }
            }

            if !defersHeavyImageWork {
                let retiredIDs = pageViews.keys.filter { !retainedIDs.contains($0) }
                for id in retiredIDs {
                    // A final traversal prune is exactly when a recently edited page
                    // is most likely to leave the viewport. Keep its live canvas until
                    // every pending or in-flight save has completed successfully.
                    if coordinator.hasPendingDrawingWork(for: id) {
                        continue
                    }
                    if let pageView = pageViews[id] {
                        if retirePageView(id: id, pageView: pageView) {
                            didChangeMaterializedPages = true
                        }
                    }
                }

                let imageLoadingRect: CGRect
                if isUserScrolling, !prunesTraversalResources {
                    let retentionPadding = max(
                        visibleRect.height * scrollingImageRetentionScreens,
                        minimumImageForwardPreloadPadding
                    )
                    imageLoadingRect = imageActiveRect.insetBy(dx: 0, dy: -retentionPadding)
                } else {
                    imageLoadingRect = imageActiveRect
                }
                updateImageLoading(in: imageLoadingRect)
            }
            updatePageVisibility(in: visibleRect)

            if updatesRenderScale {
                updateRasterScale(
                    force: didChangeMaterializedPages,
                    reloadImageVariants: !defersHeavyImageWork && !isUserScrolling
                )
            }

            if didChangeMaterializedPages {
                arrangeDocumentLayers()
            }
            recordViewportResourceRefresh(visibleRect)
            return didChangeMaterializedPages
        }

        @objc private func handleSeamlessAttachmentSelection(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            selectSeamlessAttachment(at: recognizer.location(in: contentView))
        }

        /// Routes image editing through the document-level canvas used by seamless mode.
        /// The section views that own attachment models sit below PencilKit in this mode,
        /// so their local tap recognizers cannot receive the touch directly.
        @discardableResult
        func selectSeamlessAttachment(at documentPoint: CGPoint) -> Bool {
            guard pageFlowMode.usesDocumentWideCanvas else { return false }

            guard let target = seamlessAttachmentTarget(at: documentPoint) else {
                for pageView in pageViews.values {
                    guard pageView.clearAttachmentSelection() else { return false }
                }
                return false
            }
            return selectSeamlessAttachment(
                pageView: target.pageView,
                attachment: target.attachment,
                documentFrame: target.documentFrame
            )
        }

        @discardableResult
        private func selectSeamlessAttachment(
            pageView targetPageView: PageCanvasView,
            attachment: Attachment,
            documentFrame: CGRect
        ) -> Bool {
            for pageView in pageViews.values where pageView !== targetPageView {
                guard pageView.clearAttachmentSelection() else { return false }
            }

            targetPageView.beginEditingAttachment(id: attachment.id)
            targetPageView.presentAttachmentEditingControls(
                in: contentView,
                documentFrame: documentFrame
            )
            return targetPageView.selectedAttachmentID == attachment.id
        }

        private func seamlessAttachmentTarget(
            at documentPoint: CGPoint
        ) -> (pageView: PageCanvasView, attachment: Attachment, documentFrame: CGRect)? {
            guard let id = pageID(containing: documentPoint),
                  let documentFrame = pageFrames[id],
                  let pageView = pageViews[id] else { return nil }
            let pagePoint = CGPoint(
                x: documentPoint.x - documentFrame.minX,
                y: documentPoint.y - documentFrame.minY
            )
            guard let attachment = pageView.editableAttachment(at: pagePoint) else { return nil }
            return (pageView, attachment, documentFrame)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === seamlessAttachmentSelectionGesture,
                  pageFlowMode.usesDocumentWideCanvas else {
                return true
            }

            var touchedView = touch.view
            while let view = touchedView {
                if view is AttachmentEditingOverlayView
                    || view.accessibilityIdentifier == "codeSnippet.inlineEditor" {
                    return false
                }
                touchedView = view.superview
            }

            let documentPoint = touch.location(in: contentView)
            return seamlessAttachmentTarget(at: documentPoint) != nil
                || pageViews.values.contains { $0.selectedAttachmentID != nil }
                || continuousPageView?.consumesBlankCanvasTaps == true
        }

        @discardableResult
        func clearAttachmentSelectionsForContinuousDrawing() -> Bool {
            for pageView in pageViews.values where pageView.selectedAttachmentID != nil {
                guard pageView.clearAttachmentSelection() else { return false }
            }
            return true
        }

        @discardableResult
        func flushInlineCodeSnippetEdits() -> Bool {
            for pageView in pageViews.values {
                guard pageView.flushInlineCodeSnippetEdits() else { return false }
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === seamlessAttachmentSelectionGesture,
                  let tapGesture = otherGestureRecognizer as? UITapGestureRecognizer else {
                return false
            }

            return tapGesture.numberOfTouchesRequired == 1
                && tapGesture.numberOfTapsRequired > 1
        }

        @discardableResult
        private func materializePageView(
            id: UUID,
            drawingStorage: DrawingStorageService,
            coordinator: Coordinator,
            shouldLoadImages: Bool,
            updatesImageLoadingState: Bool,
            refreshesExistingPage: Bool
        ) -> Bool {
            guard let page = pagesByID[id], let frame = pageFrames[id] else { return false }
            let existingPageView = pageViews[id]
            let didCreatePageView = existingPageView == nil

            let pageView = existingPageView ?? {
                let pageView = PageCanvasView()
                contentView.addSubview(pageView)
                pageViews[id] = pageView
                return pageView
            }()

            pageView.frame = frame
            pageView.setBackgroundPatternOrigin(
                pageFlowMode.usesDocumentWideCanvas
                    ? CGPoint(x: -frame.minX, y: -frame.minY)
                    : nil
            )
            // Apply interaction state before attachments are configured so a page
            // materialized mid-scroll or mid-stroke stays consistent with the editor.
            pageView.setDocumentTraversalActive(
                shouldDeferPDFTraversalRendering(on: id)
            )
            pageView.setDrawingInteractionActive(
                shouldProtectVectorPDFDuringDrawing(on: id)
            )
            if updatesImageLoadingState {
                pageView.setImageLoadingEnabled(shouldLoadImages)
            } else if didCreatePageView {
                pageView.setImageLoadingEnabled(false)
            }
            if didCreatePageView || refreshesExistingPage {
                pageView.configure(
                    page: page,
                    storage: drawingStorage.storage,
                    drawingStorage: drawingStorage,
                    inputMode: inputMode,
                    theme: theme,
                    showsBeanArtwork: showsBeanArtwork,
                    coordinator: coordinator,
                    attachmentChanged: { [weak coordinator] in
                        coordinator?.notifyAttachmentChanged()
                    },
                    deleteAttachment: { [weak coordinator] attachment in
                        coordinator?.requestAttachmentDeletion(attachment)
                    },
                    editCodeSnippet: { [weak coordinator] attachment in
                        coordinator?.requestCodeSnippetEditing(attachment)
                    },
                    saveCodeSnippetSource: { [weak coordinator] draft, attachment in
                        coordinator?.saveCodeSnippetSource(draft, attachment: attachment) ?? false
                    },
                    saveCodeSnippet: { [weak coordinator] draft, attachment in
                        coordinator?.saveCodeSnippet(draft, attachment: attachment) ?? false
                    },
                    isDarkAppearance: coordinator.parent.isDarkAppearance,
                    canRemovePage: orderedPageIDs.count > 1,
                    drawingEnabled: !pageFlowMode.usesDocumentWideCanvas,
                    flushAppearance: pageFlowMode.usesFlushPageLayout,
                    pageActionRequested: { [weak coordinator] pageID, action in
                        coordinator?.requestPageAction(action, for: pageID)
                    },
                    pageContextMenuWillOpen: { [weak coordinator] pageID in
                        coordinator?.selectPageForContextMenu(pageID)
                    }
                )
                pageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
                // PencilKit's private gesture hierarchy is expensive to traverse. It
                // changes when a canvas is installed/reconfigured, not on every offset
                // sample, so install these requirements only at that lifecycle point.
                pageView.prioritizePageActionGestures(over: fingerDoubleTapGesture)
            }

            // Static snippet views are VoiceOver elements. Route their activation
            // through the document-level editing host in seamless mode so the live
            // editor and controls remain above the continuous PencilKit canvas.
            pageView.accessibilityAttachmentSelectionRequested = { [weak self, weak pageView] attachment in
                guard let self, let pageView else { return }
                if self.pageFlowMode.usesDocumentWideCanvas,
                   let documentFrame = self.pageFrames[id] {
                    _ = self.selectSeamlessAttachment(
                        pageView: pageView,
                        attachment: attachment,
                        documentFrame: documentFrame
                    )
                } else {
                    pageView.beginEditingAttachment(id: attachment.id)
                }
            }

            return didCreatePageView
        }

        private func applyInputModeToMaterializedPages() {
            for pageView in pageViews.values {
                pageView.applyInputMode(inputMode)
            }
            continuousPageView?.applyInputMode(inputMode)
        }

        func releaseAllMaterializedPages(flushDrawingsBeforeRelease: Bool = true) {
            releaseContinuousPageView(flushDrawingBeforeRelease: flushDrawingsBeforeRelease)
            for id in Array(pageViews.keys) {
                if let pageView = pageViews[id] {
                    retirePageView(
                        id: id,
                        pageView: pageView,
                        flushDrawingBeforeRelease: flushDrawingsBeforeRelease
                    )
                }
            }
        }

        @discardableResult
        private func retirePageView(
            id: UUID,
            pageView: PageCanvasView,
            flushDrawingBeforeRelease: Bool = true,
            evictCachedImages: Bool = false
        ) -> Bool {
            // A virtualized page must not discard the only copy of a live draft.
            // Keep it materialized when preview/source persistence reports failure.
            guard pageView.flushInlineCodeSnippetEdits() else { return false }

            if let page = pageView.page, pageView.canvasView.delegate != nil {
                coordinator?.unregister(
                    canvasView: pageView.canvasView,
                    page: page,
                    flushDrawingBeforeRelease: flushDrawingBeforeRelease
                )
            }

            pageView.releaseHeavyResources(evictCachedImages: evictCachedImages)
            pageView.removeFromSuperview()
            pageViews[id] = nil
            return true
        }

        func reduceMemoryFootprint() {
            let retainedID = selectedPageID ?? orderedPageIDs.first
            let retiredIDs = pageViews.keys.filter { id in
                id != retainedID && coordinator?.hasPendingDrawingWork(for: id) != true
            }

            for id in retiredIDs {
                if let pageView = pageViews[id] {
                    retirePageView(id: id, pageView: pageView, evictCachedImages: true)
                }
            }

            ImageMemoryCache.shared.removeAllImages()
            NativePDFPageView.removeAllCachedDocuments()
            DrawingStorageService.clearCache()
            updateImageLoading(in: imageLoadingContentRect(visibleRect: visibleContentRect()))
            for pageView in pageViews.values {
                pageView.reduceDrawingMemoryFootprint()
            }
            continuousPageView?.reduceDrawingMemoryFootprint()
            updateRasterScale(force: true)
        }

        func cancelPendingRenderingWork() {
            DrawingStorageService.cancelPrefetches(scopeID: drawingPrefetchScopeID)
            lastDrawingPrefetchSignature = nil
            invalidateScheduledViewportRefresh()
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            cancelPostTraversalPDFDeferral()
            isPinchZooming = false
            isProgrammaticZooming = false
            programmaticZoomEarliestFinishTime = 0
            isProgrammaticScrollAnimating = false
            cancelProgrammaticPageSelection()
            pendingTraversalVisiblePageID = nil
            setUserScrolling(false)
            isDrawingInteractionActive = false
            finishPDFRenderingDeferral()

            for pageView in pageViews.values {
                pageView.cancelPendingNativeViewportUpdate()
            }
            continuousPageView?.cancelPendingNativeViewportUpdate()
        }

        private func visibleContentRect() -> CGRect {
            guard scrollView.bounds != .zero else {
                return selectedPageID.flatMap { pageFrames[$0] } ?? .zero
            }

            // UIScrollView changes the zoomed content view's transform, bounds origin,
            // and effective insets independently. Converting the visible bounds through
            // that view keeps the clipped PencilKit input surface aligned with what the
            // user can actually see, including while centering or zooming settles.
            return contentView.convert(scrollView.bounds, from: scrollView)
        }

        private func imageLoadingContentRect(visibleRect: CGRect) -> CGRect {
            directionalPreloadRect(
                around: visibleRect,
                forwardScreenPadding: imageForwardPreloadScreenPadding,
                backwardScreenPadding: imageBackwardPreloadScreenPadding,
                minimumForwardPadding: minimumImageForwardPreloadPadding,
                minimumBackwardPadding: minimumImageBackwardPreloadPadding
            )
        }

        private func directionalPreloadRect(
            around visibleRect: CGRect,
            forwardScreenPadding: CGFloat,
            backwardScreenPadding: CGFloat,
            minimumForwardPadding: CGFloat,
            minimumBackwardPadding: CGFloat
        ) -> CGRect {
            let scale = max(scrollView.zoomScale, 0.01)
            let forward = max(forwardScreenPadding / scale, minimumForwardPadding)
            let backward = max(backwardScreenPadding / scale, minimumBackwardPadding)
            let minY = visibleRect.minY - (isScrollingTowardLaterPages ? backward : forward)
            return CGRect(
                x: -documentSize.width,
                y: minY,
                width: documentSize.width * 3,
                height: visibleRect.height + forward + backward
            )
        }

        private func prefetchDrawingFiles(
            around visibleRect: CGRect,
            drawingStorage: DrawingStorageService
        ) {
            let prefetchRect = directionalPreloadRect(
                around: visibleRect,
                forwardScreenPadding: drawingPrefetchForwardScreenPadding,
                backwardScreenPadding: drawingPrefetchBackwardScreenPadding,
                minimumForwardPadding: 1_600,
                minimumBackwardPadding: 360
            )
            let rootURL = drawingStorage.storage.rootURL
            let prioritizedPageIDs = pageIDsIntersecting(prefetchRect)
                .enumerated()
                .sorted { lhs, rhs in
                    let lhsFrame = pageFrames[lhs.element] ?? .zero
                    let rhsFrame = pageFrames[rhs.element] ?? .zero
                    let lhsVisible = lhsFrame.intersects(visibleRect)
                    let rhsVisible = rhsFrame.intersects(visibleRect)
                    if lhsVisible != rhsVisible {
                        return lhsVisible
                    }

                    let lhsDistance = abs(lhsFrame.midY - visibleRect.midY)
                    let rhsDistance = abs(rhsFrame.midY - visibleRect.midY)
                    if lhsDistance != rhsDistance {
                        return lhsDistance < rhsDistance
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            let fileNames = prioritizedPageIDs.compactMap { pagesByID[$0]?.drawingFileName }
            let signature = DrawingPrefetchSignature(
                rootPath: rootURL.standardizedFileURL.path,
                fileNames: fileNames
            )
            guard signature != lastDrawingPrefetchSignature else { return }
            lastDrawingPrefetchSignature = signature
            DrawingStorageService.prefetchDrawings(
                fileNames: fileNames,
                rootURL: rootURL,
                scopeID: drawingPrefetchScopeID
            )
        }

        private func updateNativeDrawingViewports(force: Bool = false) {
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            guard !isZoomTransitionActive else { return }
            let zoomScale = max(scrollView.zoomScale, 0.01)
            let settledNativeZoomScale = Self.preparedNativeDrawingScale(for: zoomScale)
            // Keep enough prepared PencilKit content above and below the viewport that
            // normal scrolling does not repeatedly resize its tiled backing surface.
            let overscanScreenPadding = max(
                minimumDrawingViewportOverscan,
                scrollView.bounds.height * drawingViewportOverscanFraction
            )
            let overscan = overscanScreenPadding / zoomScale
            let visibleRect = visibleContentRect()

            if let continuousPageView {
                for pageView in pageViews.values {
                    pageView.deactivateDrawingViewport()
                }
                let visibleDrawingRect = continuousPageView.frame.intersection(visibleRect)
                guard !visibleDrawingRect.isNull, !visibleDrawingRect.isEmpty else {
                    continuousPageView.deactivateDrawingViewport()
                    return
                }
                let localRect = visibleDrawingRect.offsetBy(
                    dx: -continuousPageView.frame.minX,
                    dy: -continuousPageView.frame.minY
                )
                let nativeZoomScale = isZoomTransitionActive
                    ? continuousPageView.currentNativeDrawingZoomScale
                    : settledNativeZoomScale
                continuousPageView.updateNativeDrawingViewport(
                    visiblePageRect: localRect,
                    overscan: overscan,
                    nativeZoomScale: nativeZoomScale,
                    force: force
                )
                return
            }

            for (id, pageView) in pageViews {
                guard let pageFrame = pageFrames[id] else {
                    pageView.deactivateDrawingViewport()
                    continue
                }

                let visiblePageRect = pageFrame.intersection(visibleRect)
                guard !visiblePageRect.isNull, !visiblePageRect.isEmpty else {
                    pageView.deactivateDrawingViewport()
                    continue
                }

                let localRect = visiblePageRect.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
                let nativeZoomScale = isZoomTransitionActive
                    ? pageView.currentNativeDrawingZoomScale
                    : settledNativeZoomScale
                pageView.updateNativeDrawingViewport(
                    visiblePageRect: localRect,
                    overscan: overscan,
                    nativeZoomScale: nativeZoomScale,
                    force: force
                )
            }
        }

        static func preparedNativeDrawingScale(for documentZoomScale: CGFloat) -> CGFloat {
            // Quarter-step preparation keeps live ink at or above screen resolution while
            // avoiding the large offscreen surfaces caused by coarse zoom tiers.
            guard documentZoomScale.isFinite else { return 1 }
            let requestedScale = max(documentZoomScale, 1)
            return (requestedScale * 4).rounded(.up) / 4
        }

        private func pageFrame(id: UUID, intersects rect: CGRect) -> Bool {
            pageFrames[id]?.intersects(rect) == true
        }

        private func pageID(containing documentPoint: CGPoint) -> UUID? {
            let index = firstPageIndex(endingAfter: documentPoint.y)
            guard orderedPageIDs.indices.contains(index) else { return nil }
            let id = orderedPageIDs[index]
            guard pageFrames[id]?.contains(documentPoint) == true else { return nil }
            return id
        }

        private func updateImageLoading(in rect: CGRect) {
            for (id, pageView) in pageViews {
                pageView.setImageLoadingEnabled(pageFrame(id: id, intersects: rect))
            }
        }

        private func updatePageVisibility(in rect: CGRect) {
            viewportVisibilityRefreshCount += 1
            for (id, pageView) in pageViews {
                pageView.setViewportVisible(pageFrame(id: id, intersects: rect))
            }
        }

        private func setUserScrolling(_ isScrolling: Bool) {
            guard isUserScrolling != isScrolling else { return }
            isUserScrolling = isScrolling
            publishPDFRenderingState()
            if isScrolling {
                cancelPostTraversalPDFDeferral()
            }
        }

        func setDrawingInteractionActive(
            _ active: Bool,
            prioritizing activePageView: PageCanvasView? = nil
        ) {
            isDrawingInteractionActive = active

            if active {
                DrawingStorageService.cancelPrefetches(scopeID: drawingPrefetchScopeID)
                lastDrawingPrefetchSignature = nil
                pdfRenderingResumeGeneration &+= 1
                pdfRenderingResumeWorkItem?.cancel()
                pdfRenderingResumeWorkItem = nil
                keepsPDFVectorSurfaceDuringDrawing = true

                if let protectedPageID = activeDrawingPageID ?? selectedPageID {
                    pdfVectorProtectedPageIDs.insert(protectedPageID)
                    pageViews[protectedPageID]?.setDrawingInteractionActive(true)
                }
                // The seamless canvas owns PencilKit geometry while its individual
                // page views own PDF backgrounds. Protect both, but do not walk every
                // materialized PDF on the stroke-begin callback.
                continuousPageView?.setDrawingInteractionActive(true)
                activePageView?.setDrawingInteractionActive(true)
                pausePostTraversalPDFReleaseDuringDrawing()
                return
            }

            // PencilKit reports a begin/end pair for each stroke. Keep the drawing
            // interaction state stable across short pen lifts so resource work cannot
            // repeatedly restart between letters and contend with the next live stroke.
            guard keepsPDFVectorSurfaceDuringDrawing,
                  pdfRenderingResumeWorkItem == nil else { return }
            pdfRenderingResumeGeneration &+= 1
            let resumeGeneration = pdfRenderingResumeGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pdfRenderingResumeGeneration == resumeGeneration else { return }
                self.pdfRenderingResumeWorkItem = nil
                guard !self.isDrawingInteractionActive else { return }
                self.keepsPDFVectorSurfaceDuringDrawing = false
                self.pdfVectorProtectedPageIDs.removeAll(keepingCapacity: true)
                if !self.isUserScrolling {
                    self.clearHeldPostTraversalPDFDeferral()
                }
                self.publishPDFRenderingState()
            }
            pdfRenderingResumeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + pdfRenderingResumeDelay,
                execute: workItem
            )
        }

        private func finishPDFRenderingDeferral() {
            pdfRenderingResumeGeneration &+= 1
            pdfRenderingResumeWorkItem?.cancel()
            pdfRenderingResumeWorkItem = nil
            guard keepsPDFVectorSurfaceDuringDrawing else { return }
            keepsPDFVectorSurfaceDuringDrawing = false
            pdfVectorProtectedPageIDs.removeAll(keepingCapacity: false)
            publishPDFRenderingState()
        }

        private var effectivePDFTraversalActive: Bool {
            isUserScrolling || defersPDFRenderingAfterTraversal
        }

        private var effectivePDFDrawingProtectionActive: Bool {
            keepsPDFVectorSurfaceDuringDrawing
        }

        private func shouldProtectVectorPDFDuringDrawing(on pageID: UUID) -> Bool {
            effectivePDFDrawingProtectionActive
                && pdfVectorProtectedPageIDs.contains(pageID)
        }

        private func shouldDeferPDFTraversalRendering(on pageID: UUID) -> Bool {
            guard effectivePDFTraversalActive else { return false }
            // Once navigation physically stops, prewarm the selected page's vector
            // surface before PencilKit receives another touch. Other materialized PDF
            // pages keep their bounded snapshots until the short settle window ends.
            let isSettledPostTraversalWindow = defersPDFRenderingAfterTraversal
                && !isUserScrolling
            return !isSettledPostTraversalWindow || pageID != selectedPageID
        }

        private func beginPostTraversalPDFDeferral() {
            traversalPDFResumeGeneration &+= 1
            traversalPDFResumeWorkItem?.cancel()
            traversalPDFResumeWorkItem = nil
            defersPDFRenderingAfterTraversal = true
            publishPDFRenderingState()

            let generation = traversalPDFResumeGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.traversalPDFResumeGeneration == generation else { return }
                self.traversalPDFResumeWorkItem = nil
                self.defersPDFRenderingAfterTraversal = false
                self.publishPDFRenderingState()
            }
            traversalPDFResumeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + pdfRenderingResumeDelay,
                execute: workItem
            )
        }

        private func cancelPostTraversalPDFDeferral() {
            traversalPDFResumeGeneration &+= 1
            traversalPDFResumeWorkItem?.cancel()
            traversalPDFResumeWorkItem = nil
            guard defersPDFRenderingAfterTraversal else { return }
            defersPDFRenderingAfterTraversal = false
            publishPDFRenderingState()
        }

        private func pausePostTraversalPDFReleaseDuringDrawing() {
            guard defersPDFRenderingAfterTraversal else { return }
            traversalPDFResumeGeneration &+= 1
            traversalPDFResumeWorkItem?.cancel()
            traversalPDFResumeWorkItem = nil
        }

        private func clearHeldPostTraversalPDFDeferral() {
            traversalPDFResumeGeneration &+= 1
            traversalPDFResumeWorkItem?.cancel()
            traversalPDFResumeWorkItem = nil
            defersPDFRenderingAfterTraversal = false
        }

        private func publishPDFRenderingState() {
            let traversalActive = effectivePDFTraversalActive
            for (id, pageView) in pageViews {
                pageView.setDocumentTraversalActive(
                    shouldDeferPDFTraversalRendering(on: id)
                )
                pageView.setDrawingInteractionActive(
                    shouldProtectVectorPDFDuringDrawing(on: id)
                )
            }
            continuousPageView?.setDocumentTraversalActive(traversalActive)
            continuousPageView?.setDrawingInteractionActive(
                effectivePDFDrawingProtectionActive
            )
        }

        func dismissNativeCanvasEditMenus() {
            for pageView in pageViews.values {
                pageView.dismissNativeCanvasEditMenus()
            }
            continuousPageView?.dismissNativeCanvasEditMenus()
        }

        func suppressNativeCanvasEditMenus() {
            for pageView in pageViews.values {
                pageView.suppressNativeCanvasEditMenus()
            }
            continuousPageView?.suppressNativeCanvasEditMenus()
        }

        func setFingerDoubleTapGesture(_ gesture: UITapGestureRecognizer) {
            fingerDoubleTapGesture = gesture
            for pageView in pageViews.values {
                pageView.prioritizePageActionGestures(over: gesture)
            }
            continuousPageView?.prioritizePageActionGestures(over: gesture)
        }

        private func updateVisiblePage() {
            guard !defersViewStatePublishing,
                  programmaticScrollTargetID == nil,
                  !pageFrames.isEmpty else { return }

            let contentPoint = contentView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                from: scrollView
            )

            guard let nearestID = nearestPageID(toY: contentPoint.y) else { return }

            selectedPageID = nearestID
            if isUserScrolling {
                // Crossing a page in a large PDF must not rebuild SwiftUI's all-page
                // configuration and tool state on the scrolling frame. Publish only the
                // final page once deceleration has ended.
                pendingTraversalVisiblePageID = nearestID == lastPublishedVisiblePageID
                    ? nil
                    : nearestID
                return
            }

            pendingTraversalVisiblePageID = nil
            guard nearestID != lastPublishedVisiblePageID else { return }
            lastPublishedVisiblePageID = nearestID
            visiblePageChanged?(nearestID)
        }

        private func publishPendingTraversalVisiblePage() {
            guard let pendingTraversalVisiblePageID else { return }
            self.pendingTraversalVisiblePageID = nil
            selectedPageID = pendingTraversalVisiblePageID
            guard pendingTraversalVisiblePageID != lastPublishedVisiblePageID else { return }
            lastPublishedVisiblePageID = pendingTraversalVisiblePageID
            visiblePageChanged?(pendingTraversalVisiblePageID)
        }

        func cancelProgrammaticPageSelection() {
            isProgrammaticScrollAnimating = false
            programmaticScrollTargetID = nil
            programmaticScrollTargetOffset = nil
        }

        private func finishDocumentTraversalIfIdle() {
            guard !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating,
                  !isPinchZooming,
                  !isProgrammaticZooming,
                  !isProgrammaticScrollAnimating else { return }
            finishDocumentTraversal()
        }

        private func finishDocumentTraversal() {
            cancelScheduledViewportRefresh()
            guard isUserScrolling else {
                materializePagesNearViewport()
                updateNativeDrawingViewports()
                publishPendingTraversalVisiblePage()
                return
            }
            // Prune/disable distant resources while PDF views are still suspended, then
            // keep the survivor set paused briefly so the first Pencil contact after a
            // scroll cannot race a burst of newly resumed vector tiles.
            // Prune against the final viewport while representations are still paused,
            // but do not consume the new zoom scale with image-variant reloads disabled.
            // Once traversal is cleared, updateZoomScalesIfNeeded performs the single
            // authoritative scale pass and can request the sharper ordinary-image tier.
            let didChangeMaterializedPages = materializePagesNearViewport(
                updatesRenderScale: false,
                prunesTraversalResources: true
            )
            if keepsPDFVectorSurfaceDuringDrawing {
                // Preserve the navigation snapshots on non-active PDF pages until the
                // short handwriting session ends. Resuming them all between letters is
                // a large, intermittent main-thread PDFKit tile burst.
                defersPDFRenderingAfterTraversal = true
                pausePostTraversalPDFReleaseDuringDrawing()
            } else {
                beginPostTraversalPDFDeferral()
            }
            setUserScrolling(false)
            updateZoomScalesIfNeeded(force: didChangeMaterializedPages)
            centerDocument()
            updateNativeDrawingViewports()
            publishPendingTraversalVisiblePage()
        }

        private func firstPageIndex(endingAfter y: CGFloat) -> Int {
            var low = 0
            var high = orderedPageIDs.count
            while low < high {
                let mid = (low + high) / 2
                let frame = pageFrames[orderedPageIDs[mid]] ?? .zero
                if frame.maxY <= y {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        private func pageIDsIntersecting(_ rect: CGRect) -> [UUID] {
            guard !orderedPageIDs.isEmpty else { return [] }

            var index = firstPageIndex(endingAfter: rect.minY)
            var ids: [UUID] = []

            while index < orderedPageIDs.count {
                let id = orderedPageIDs[index]
                guard let frame = pageFrames[id] else {
                    index += 1
                    continue
                }

                if frame.minY > rect.maxY {
                    break
                }

                if frame.intersects(rect) {
                    ids.append(id)
                }

                index += 1
            }

            return ids
        }

        private func nearestPageID(toY yPosition: CGFloat) -> UUID? {
            guard !orderedPageIDs.isEmpty else { return nil }

            var low = 0
            var high = orderedPageIDs.count

            while low < high {
                let mid = (low + high) / 2
                let midY = pageFrames[orderedPageIDs[mid]]?.midY ?? 0
                if midY < yPosition {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            let candidateIndexes = [low - 1, low]
                .filter { orderedPageIDs.indices.contains($0) }

            return candidateIndexes.min { lhs, rhs in
                let lhsDistance = abs((pageFrames[orderedPageIDs[lhs]]?.midY ?? 0) - yPosition)
                let rhsDistance = abs((pageFrames[orderedPageIDs[rhs]]?.midY ?? 0) - yPosition)
                return lhsDistance < rhsDistance
            }
            .map { orderedPageIDs[$0] }
        }

        @objc private func handleAddPageFooterTapped() {
            addPageRequested?()
        }

        private func clampedContentOffset(_ proposed: CGPoint) -> CGPoint {
            let inset = scrollView.adjustedContentInset
            let maxX = max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            return CGPoint(
                x: min(max(proposed.x, -inset.left), maxX),
                y: min(max(proposed.y, -inset.top), maxY)
            )
        }

        private func publishZoomScale(force: Bool = false) {
            coordinator?.publishZoomScale(scrollView.zoomScale, force: force)
        }

        private func publishViewport(force: Bool = false) {
            guard force || !isUserScrolling else { return }
            guard let viewport = currentViewport() else { return }
            viewportChanged?(viewport, force)
        }
    }

    final class EraserScopeGestureRecognizer: UIGestureRecognizer {
        enum Interaction {
            case began(CGPoint)
            case moved(CGPoint)
            case movedBatch([CGPoint])
            case ended(CGPoint)
            case endedBatch([CGPoint])
            case cancelled
        }

        weak var coordinateView: UIView?
        var interactionChanged: ((Interaction) -> Void)?
        private(set) var currentLocation: CGPoint?

        private weak var trackedTouch: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard trackedTouch == nil else {
                // A second touch is document navigation, not an erase stroke. Cancel the
                // custom object transaction so its live changes are rolled back.
                interactionChanged?(.cancelled)
                trackedTouch = nil
                currentLocation = nil
                state = .failed
                return
            }
            guard let touch = touches.first else { return }
            trackedTouch = touch
            state = .began
            publishBegan(for: touch)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let trackedTouch,
                  touches.contains(where: { $0 === trackedTouch }) else { return }
            state = .changed
            let samples = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
            publishMoved(samples)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finishIfTracking(touches, event: event, state: .ended)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finishIfTracking(touches, event: event, state: .cancelled)
        }

        override func reset() {
            if trackedTouch != nil {
                interactionChanged?(.cancelled)
            }
            trackedTouch = nil
            currentLocation = nil
            super.reset()
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func finishIfTracking(
            _ touches: Set<UITouch>,
            event: UIEvent,
            state finalState: State
        ) {
            guard let trackedTouch,
                  touches.contains(where: { $0 === trackedTouch }) else { return }
            switch finalState {
            case .ended:
                let samples = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
                publishEnded(samples)
                state = .ended
            case .cancelled, .failed:
                interactionChanged?(.cancelled)
                state = finalState
            default:
                return
            }
            self.trackedTouch = nil
            currentLocation = nil
        }

        private func publishBegan(for touch: UITouch) {
            guard let coordinateView else {
                interactionChanged?(.cancelled)
                return
            }
            let location = touch.location(in: coordinateView)
            currentLocation = location
            interactionChanged?(.began(location))
        }

        private func publishMoved(_ touches: [UITouch]) {
            guard let locations = locations(for: touches) else { return }
            currentLocation = locations.last
            interactionChanged?(.movedBatch(locations))
        }

        private func publishEnded(_ touches: [UITouch]) {
            guard let locations = locations(for: touches) else { return }
            currentLocation = locations.last
            interactionChanged?(.endedBatch(locations))
        }

        private func locations(for touches: [UITouch]) -> [CGPoint]? {
            guard let coordinateView else {
                interactionChanged?(.cancelled)
                return nil
            }
            let locations = touches.map { $0.location(in: coordinateView) }
            return locations.isEmpty ? nil : locations
        }
    }

    struct ObjectEraserPathAccumulator {
        private(set) var points: [CGPoint] = []

        mutating func begin(at location: CGPoint) {
            guard isFinite(location) else {
                points.removeAll(keepingCapacity: false)
                return
            }

            points = [location]
        }

        mutating func append(
            _ location: CGPoint,
            minimumSpacing: CGFloat,
            force: Bool = false
        ) {
            guard isFinite(location) else { return }
            guard let previous = points.last else {
                points = [location]
                return
            }

            let deltaX = location.x - previous.x
            let deltaY = location.y - previous.y
            let distanceSquared = deltaX * deltaX + deltaY * deltaY
            guard distanceSquared > 0 else { return }

            let spacing = minimumSpacing.isFinite && minimumSpacing > 0 ? minimumSpacing : 0
            guard force || distanceSquared >= spacing * spacing else { return }
            points.append(location)
        }

        mutating func reset() {
            points.removeAll(keepingCapacity: false)
        }

        private func isFinite(_ point: CGPoint) -> Bool {
            point.x.isFinite && point.y.isFinite
        }
    }

    enum ObjectEraserHitTester {
        private static let edgeTolerance: CGFloat = 0.01

        private struct StrokeSample {
            var location: CGPoint
            var radius: CGFloat
        }

        private struct LineSegment {
            var start: CGPoint
            var end: CGPoint
        }

        /// A lightweight per-gesture broad phase. Handwritten pages commonly contain
        /// thousands of short strokes; indexing their render bounds once prevents every
        /// coalesced eraser move from walking the complete drawing on the main thread.
        private struct SpatialIndex {
            private struct Cell: Hashable {
                var column: Int
                var row: Int
            }

            private static let maximumCellsPerStroke = 256
            private static let maximumCoordinateMagnitude = 1_000_000

            private let cellSize: CGFloat
            private var allStrokeIndexes = IndexSet()
            private var strokeIndexesByCell: [Cell: IndexSet] = [:]
            private var fallbackStrokeIndexes = IndexSet()

            init(strokes: [PKStroke], diameter: CGFloat, candidateBounds: CGRect?) {
                let requestedCellSize = diameter.isFinite && diameter > 0
                    ? diameter * 2
                    : 64
                cellSize = min(max(requestedCellSize, 64), 256)
                let boundedCandidateRegion = candidateBounds.flatMap { bounds -> CGRect? in
                    let standardized = bounds.standardized
                    guard !standardized.isNull,
                          !standardized.isInfinite,
                          standardized.minX.isFinite,
                          standardized.minY.isFinite,
                          standardized.maxX.isFinite,
                          standardized.maxY.isFinite else { return nil }
                    return standardized
                }
                var includedStrokeIndexes = IndexSet()

                for (index, stroke) in strokes.enumerated() {
                    if let boundedCandidateRegion,
                       !stroke.renderBounds.intersects(boundedCandidateRegion) {
                        continue
                    }
                    includedStrokeIndexes.insert(index)
                    guard let span = cellSpan(for: stroke.renderBounds) else {
                        fallbackStrokeIndexes.insert(index)
                        continue
                    }

                    for column in span.columns {
                        for row in span.rows {
                            strokeIndexesByCell[
                                Cell(column: column, row: row),
                                default: IndexSet()
                            ].insert(index)
                        }
                    }
                }
                allStrokeIndexes = includedStrokeIndexes
            }

            func strokeIndexes(intersecting bounds: CGRect) -> IndexSet {
                guard let span = cellSpan(for: bounds) else {
                    return allStrokeIndexes
                }

                var candidates = fallbackStrokeIndexes
                for column in span.columns {
                    for row in span.rows {
                        if let indexes = strokeIndexesByCell[
                            Cell(column: column, row: row)
                        ] {
                            candidates.formUnion(indexes)
                        }
                    }
                }
                return candidates
            }

            private func cellSpan(
                for rawBounds: CGRect
            ) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
                let bounds = rawBounds.standardized
                guard !bounds.isNull,
                      !bounds.isInfinite,
                      bounds.minX.isFinite,
                      bounds.maxX.isFinite,
                      bounds.minY.isFinite,
                      bounds.maxY.isFinite else {
                    return nil
                }

                let minimumColumnValue = floor(bounds.minX / cellSize)
                let maximumColumnValue = floor(bounds.maxX / cellSize)
                let minimumRowValue = floor(bounds.minY / cellSize)
                let maximumRowValue = floor(bounds.maxY / cellSize)
                let coordinateLimit = CGFloat(Self.maximumCoordinateMagnitude)
                guard minimumColumnValue >= -coordinateLimit,
                      maximumColumnValue <= coordinateLimit,
                      minimumRowValue >= -coordinateLimit,
                      maximumRowValue <= coordinateLimit else {
                    return nil
                }

                let minimumColumn = Int(minimumColumnValue)
                let maximumColumn = Int(maximumColumnValue)
                let minimumRow = Int(minimumRowValue)
                let maximumRow = Int(maximumRowValue)
                let columnCount = maximumColumn - minimumColumn + 1
                let rowCount = maximumRow - minimumRow + 1
                guard columnCount > 0,
                      rowCount > 0,
                      columnCount <= Self.maximumCellsPerStroke,
                      rowCount <= Self.maximumCellsPerStroke,
                      columnCount * rowCount <= Self.maximumCellsPerStroke else {
                    return nil
                }

                return (
                    minimumColumn...maximumColumn,
                    minimumRow...maximumRow
                )
            }
        }

        /// Reuses the expensive, transformed PencilKit stroke samples for the lifetime
        /// of one eraser gesture. The broad-phase bounds check remains lazy, so a page
        /// with many strokes only prepares the few strokes the eraser actually reaches.
        struct Session {
            private let strokes: [PKStroke]
            private let diameter: CGFloat
            private let spatialIndex: SpatialIndex
            private var sampleRunsByStrokeIndex: [Int: [[StrokeSample]]] = [:]
            private(set) var lastBroadPhaseCandidateCount = 0

            init(
                strokes: [PKStroke],
                diameter: CGFloat,
                candidateBounds: CGRect? = nil
            ) {
                self.strokes = strokes
                self.diameter = diameter
                spatialIndex = SpatialIndex(
                    strokes: strokes,
                    diameter: diameter,
                    candidateBounds: candidateBounds
                )
            }

            var preparedStrokeCount: Int {
                sampleRunsByStrokeIndex.count
            }

            mutating func intersectedStrokeIndexes(
                eraserPath: [CGPoint],
                excluding excludedIndexes: IndexSet = []
            ) -> IndexSet {
                guard diameter.isFinite, diameter > 0 else { return [] }

                let path = eraserPath.filter { $0.x.isFinite && $0.y.isFinite }
                guard !path.isEmpty else { return [] }

                let radius = diameter / 2
                let sweepBounds = ObjectEraserHitTester.bounds(
                    of: path,
                    expandedBy: radius + ObjectEraserHitTester.edgeTolerance
                )
                let sweepSegments = ObjectEraserHitTester.segments(for: path)
                let samplingDistance = min(max(radius / 4, 1), 3)
                let candidateIndexes = spatialIndex.strokeIndexes(intersecting: sweepBounds)
                lastBroadPhaseCandidateCount = candidateIndexes.count
                var intersected = IndexSet()

                for index in candidateIndexes {
                    let stroke = strokes[index]
                    guard !excludedIndexes.contains(index),
                          stroke.renderBounds.intersects(sweepBounds) else {
                        continue
                    }

                    let sampleRuns: [[StrokeSample]]
                    if let cached = sampleRunsByStrokeIndex[index] {
                        sampleRuns = cached
                    } else {
                        let prepared = ObjectEraserHitTester.strokeSampleRuns(
                            for: stroke,
                            spacing: samplingDistance
                        )
                        sampleRunsByStrokeIndex[index] = prepared
                        sampleRuns = prepared
                    }

                    if ObjectEraserHitTester.strokeIntersectsSweep(
                        sampleRuns: sampleRuns,
                        sweepSegments: sweepSegments,
                        eraserRadius: radius
                    ) {
                        intersected.insert(index)
                    }
                }

                return intersected
            }
        }

        static func intersectedStrokeIndexes(
            in strokes: [PKStroke],
            eraserPath: [CGPoint],
            diameter: CGFloat
        ) -> IndexSet {
            var session = Session(strokes: strokes, diameter: diameter)
            return session.intersectedStrokeIndexes(eraserPath: eraserPath)
        }

        private static func strokeSampleRuns(for stroke: PKStroke, spacing: CGFloat) -> [[StrokeSample]] {
            guard !stroke.path.isEmpty else { return [] }

            let transform = stroke.transform
            let scale = maximumScale(of: transform)
            let fullPathRange = 0...CGFloat(stroke.path.count - 1)
            let ranges = stroke.mask == nil
                ? [fullPathRange]
                : stroke.maskedPathRanges.compactMap {
                    clampedPathRange($0, to: fullPathRange)
                }

            return ranges.compactMap { range in
                var samples: [StrokeSample] = []
                append(
                    stroke.path.interpolatedPoint(at: range.lowerBound),
                    transform: transform,
                    scale: scale,
                    to: &samples
                )

                for point in stroke.path.interpolatedPoints(in: range, by: .distance(spacing)) {
                    append(point, transform: transform, scale: scale, to: &samples)
                }

                append(
                    stroke.path.interpolatedPoint(at: range.upperBound),
                    transform: transform,
                    scale: scale,
                    to: &samples
                )

                return samples.isEmpty ? nil : samples
            }
        }

        private static func clampedPathRange(
            _ range: ClosedRange<CGFloat>,
            to fullPathRange: ClosedRange<CGFloat>
        ) -> ClosedRange<CGFloat>? {
            guard range.lowerBound.isFinite,
                  range.upperBound.isFinite else {
                return nil
            }

            let lowerBound = max(range.lowerBound, fullPathRange.lowerBound)
            let upperBound = min(range.upperBound, fullPathRange.upperBound)
            guard lowerBound <= upperBound else { return nil }
            return lowerBound...upperBound
        }

        private static func append(
            _ point: PKStrokePoint,
            transform: CGAffineTransform,
            scale: CGFloat,
            to samples: inout [StrokeSample]
        ) {
            let location = point.location.applying(transform)
            guard isFinite(location) else { return }

            let width = max(point.size.width, point.size.height)
            let radius = width.isFinite && width > 0 ? width * scale / 2 : 0
            samples.append(StrokeSample(location: location, radius: radius))
        }

        private static func strokeIntersectsSweep(
            sampleRuns: [[StrokeSample]],
            sweepSegments: [LineSegment],
            eraserRadius: CGFloat
        ) -> Bool {
            for samples in sampleRuns {
                guard let firstSample = samples.first else { continue }

                if samples.count == 1 {
                    if sweepSegments.contains(where: { segment in
                        pointToSegmentDistanceSquared(firstSample.location, segment) <= squared(
                            eraserRadius + firstSample.radius + edgeTolerance
                        )
                    }) {
                        return true
                    }
                    continue
                }

                for index in samples.indices.dropFirst() {
                    let previous = samples[index - 1]
                    let current = samples[index]
                    let strokeSegment = LineSegment(start: previous.location, end: current.location)
                    let strokeRadius = max(previous.radius, current.radius)

                    for sweepSegment in sweepSegments {
                        let threshold = eraserRadius + strokeRadius + edgeTolerance
                        if segmentToSegmentDistanceSquared(strokeSegment, sweepSegment) <= squared(threshold) {
                            return true
                        }
                    }
                }
            }

            return false
        }

        private static func bounds(of points: [CGPoint], expandedBy inset: CGFloat) -> CGRect {
            guard let first = points.first else { return .null }

            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y

            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }

            return CGRect(
                x: minX - inset,
                y: minY - inset,
                width: maxX - minX + inset * 2,
                height: maxY - minY + inset * 2
            )
        }

        private static func segments(for points: [CGPoint]) -> [LineSegment] {
            guard let first = points.first else { return [] }
            guard points.count > 1 else {
                return [LineSegment(start: first, end: first)]
            }

            return points.indices.dropFirst().map {
                LineSegment(start: points[$0 - 1], end: points[$0])
            }
        }

        private static func maximumScale(of transform: CGAffineTransform) -> CGFloat {
            let squaredTerms = transform.a * transform.a
                + transform.b * transform.b
                + transform.c * transform.c
                + transform.d * transform.d
            let determinant = transform.a * transform.d - transform.b * transform.c
            let discriminant = max(
                squaredTerms * squaredTerms - 4 * determinant * determinant,
                0
            )
            let scale = sqrt((squaredTerms + sqrt(discriminant)) / 2)
            return scale.isFinite && scale > 0 ? scale : 1
        }

        private static func isFinite(_ point: CGPoint) -> Bool {
            point.x.isFinite && point.y.isFinite
        }

        private static func segmentToSegmentDistanceSquared(
            _ first: LineSegment,
            _ second: LineSegment
        ) -> CGFloat {
            if segmentsIntersect(first, second) {
                return 0
            }

            return min(
                pointToSegmentDistanceSquared(first.start, second),
                pointToSegmentDistanceSquared(first.end, second),
                pointToSegmentDistanceSquared(second.start, first),
                pointToSegmentDistanceSquared(second.end, first)
            )
        }

        private static func pointToSegmentDistanceSquared(
            _ point: CGPoint,
            _ segment: LineSegment
        ) -> CGFloat {
            let vector = CGPoint(
                x: segment.end.x - segment.start.x,
                y: segment.end.y - segment.start.y
            )
            let lengthSquared = dot(vector, vector)
            guard lengthSquared > 0 else {
                return squaredDistance(point, segment.start)
            }

            let pointVector = CGPoint(
                x: point.x - segment.start.x,
                y: point.y - segment.start.y
            )
            let ratio = min(max(dot(pointVector, vector) / lengthSquared, 0), 1)
            let nearest = CGPoint(
                x: segment.start.x + vector.x * ratio,
                y: segment.start.y + vector.y * ratio
            )
            return squaredDistance(point, nearest)
        }

        private static func segmentsIntersect(_ first: LineSegment, _ second: LineSegment) -> Bool {
            let firstStart = orientation(first.start, first.end, second.start)
            let firstEnd = orientation(first.start, first.end, second.end)
            let secondStart = orientation(second.start, second.end, first.start)
            let secondEnd = orientation(second.start, second.end, first.end)

            if oppositeSides(firstStart, firstEnd), oppositeSides(secondStart, secondEnd) {
                return true
            }

            return abs(firstStart) <= edgeTolerance && pointLiesOnSegment(second.start, first)
                || abs(firstEnd) <= edgeTolerance && pointLiesOnSegment(second.end, first)
                || abs(secondStart) <= edgeTolerance && pointLiesOnSegment(first.start, second)
                || abs(secondEnd) <= edgeTolerance && pointLiesOnSegment(first.end, second)
        }

        private static func orientation(_ start: CGPoint, _ end: CGPoint, _ point: CGPoint) -> CGFloat {
            (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
        }

        private static func oppositeSides(_ first: CGFloat, _ second: CGFloat) -> Bool {
            (first < 0 && second > 0) || (first > 0 && second < 0)
        }

        private static func pointLiesOnSegment(_ point: CGPoint, _ segment: LineSegment) -> Bool {
            point.x >= min(segment.start.x, segment.end.x) - edgeTolerance
                && point.x <= max(segment.start.x, segment.end.x) + edgeTolerance
                && point.y >= min(segment.start.y, segment.end.y) - edgeTolerance
                && point.y <= max(segment.start.y, segment.end.y) + edgeTolerance
        }

        private static func dot(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            lhs.x * rhs.x + lhs.y * rhs.y
        }

        private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            squared(lhs.x - rhs.x) + squared(lhs.y - rhs.y)
        }

        private static func squared(_ value: CGFloat) -> CGFloat {
            value * value
        }
    }

    struct RubEraserConfiguration: Equatable {
        var shape: DrawingRubEraserShape
        var size: CGFloat
        var angle: CGFloat

        var isValid: Bool {
            size.isFinite && size > 0 && angle.isFinite
        }
    }

    enum RubEraserGeometry {
        static func shapePath(
            centeredAt center: CGPoint,
            configuration: RubEraserConfiguration
        ) -> UIBezierPath {
            guard center.x.isFinite,
                  center.y.isFinite,
                  configuration.isValid else {
                return UIBezierPath()
            }

            let size = configuration.size
            let rect: CGRect
            let path: UIBezierPath

            switch configuration.shape {
            case .rectangle:
                rect = CGRect(x: -size / 2, y: -size * 0.28, width: size, height: size * 0.56)
                path = UIBezierPath(rect: rect)
            case .chisel:
                rect = CGRect(x: -size * 0.18, y: -size / 2, width: size * 0.36, height: size)
                path = UIBezierPath(rect: rect)
            case .beveled:
                path = UIBezierPath()
                path.move(to: CGPoint(x: -size / 2, y: -size * 0.3))
                path.addLine(to: CGPoint(x: size * 0.24, y: -size * 0.3))
                path.addLine(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size * 0.24, y: size * 0.3))
                path.addLine(to: CGPoint(x: -size / 2, y: size * 0.3))
                path.close()
            case .wedge:
                path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: -size / 2))
                path.addLine(to: CGPoint(x: size / 2, y: size * 0.42))
                path.addLine(to: CGPoint(x: -size / 2, y: size * 0.42))
                path.close()
            case .rubberBlock:
                rect = CGRect(x: -size / 2, y: -size * 0.36, width: size, height: size * 0.72)
                path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.16)
            }

            path.apply(CGAffineTransform(rotationAngle: configuration.angle * .pi / 180))
            path.apply(CGAffineTransform(translationX: center.x, y: center.y))
            return path
        }

        static func sweptPath(
            along locations: [CGPoint],
            configuration: RubEraserConfiguration
        ) -> UIBezierPath {
            guard configuration.isValid else { return UIBezierPath() }

            var combinedPath: CGPath?
            var currentRun: [CGPoint] = []
            func appendCurrentRun() {
                guard let runPath = sweptPath(
                    alongFiniteRun: currentRun,
                    configuration: configuration
                ) else {
                    currentRun.removeAll(keepingCapacity: true)
                    return
                }
                combinedPath = combinedPath?.union(runPath) ?? runPath
                currentRun.removeAll(keepingCapacity: true)
            }

            for location in locations {
                guard location.x.isFinite, location.y.isFinite else {
                    appendCurrentRun()
                    continue
                }
                if let previous = currentRun.last,
                   hypot(location.x - previous.x, location.y - previous.y) <= 0.01 {
                    continue
                }
                currentRun.append(location)
            }
            appendCurrentRun()

            guard let combinedPath else { return UIBezierPath() }
            return UIBezierPath(cgPath: combinedPath)
        }

        private static func sweptPath(
            alongFiniteRun locations: [CGPoint],
            configuration: RubEraserConfiguration
        ) -> CGPath? {
            guard let first = locations.first else { return nil }
            guard locations.count > 1 else {
                return shapePath(centeredAt: first, configuration: configuration).cgPath
            }

            var combinedPath: CGPath?
            for index in locations.indices.dropFirst() {
                let startPath = shapePath(
                    centeredAt: locations[index - 1],
                    configuration: configuration
                ).cgPath
                let endPath = shapePath(
                    centeredAt: locations[index],
                    configuration: configuration
                ).cgPath
                let boundaryPoints = flattenedBoundaryPoints(
                    in: startPath,
                    threshold: 0.05
                ) + flattenedBoundaryPoints(in: endPath, threshold: 0.05)
                guard let hullPath = convexHullPath(for: boundaryPoints) else { continue }

                // A translated convex eraser sweeps the convex hull of its endpoint
                // shapes. Union the exact endpoint curves back into the flattened hull
                // so rounded rubber-block ends remain pixel accurate.
                let segmentPath = hullPath.union(startPath).union(endPath)
                combinedPath = combinedPath?.union(segmentPath) ?? segmentPath
            }
            return combinedPath
        }

        private static func flattenedBoundaryPoints(
            in path: CGPath,
            threshold: CGFloat
        ) -> [CGPoint] {
            var points: [CGPoint] = []
            path.flattened(threshold: threshold).applyWithBlock { elementPointer in
                let element = elementPointer.pointee
                switch element.type {
                case .moveToPoint, .addLineToPoint:
                    points.append(element.points[0])
                case .addQuadCurveToPoint:
                    points.append(element.points[1])
                case .addCurveToPoint:
                    points.append(element.points[2])
                case .closeSubpath:
                    break
                @unknown default:
                    break
                }
            }
            return points
        }

        static func convexHullPath(for points: [CGPoint]) -> CGPath? {
            let sorted = points.sorted {
                $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
            }
            guard sorted.count >= 3 else { return nil }

            func cross(_ origin: CGPoint, _ first: CGPoint, _ second: CGPoint) -> CGFloat {
                (first.x - origin.x) * (second.y - origin.y)
                    - (first.y - origin.y) * (second.x - origin.x)
            }

            var lower: [CGPoint] = []
            for point in sorted {
                while lower.count >= 2,
                      cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                    lower.removeLast()
                }
                lower.append(point)
            }

            var upper: [CGPoint] = []
            for point in sorted.reversed() {
                while upper.count >= 2,
                      cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                    upper.removeLast()
                }
                upper.append(point)
            }

            lower.removeLast()
            upper.removeLast()
            let hull = lower + upper
            guard hull.count >= 3 else { return nil }

            let path = CGMutablePath()
            path.addLines(between: hull)
            path.closeSubpath()
            return path
        }
    }

    enum PartialEraserStrokeProcessor {
        private static let edgeTolerance: CGFloat = 0.01

        private enum StrokeErasure {
            case unchanged
            case removed
            case updated(PKStroke)
        }

        static func strokesByErasing(
            _ strokes: [PKStroke],
            along locations: [CGPoint],
            configuration: RubEraserConfiguration
        ) -> [PKStroke]? {
            let eraserPath = RubEraserGeometry.sweptPath(
                along: locations,
                configuration: configuration
            )
            guard !eraserPath.isEmpty else { return nil }
            return strokesByErasing(strokes, using: eraserPath)
        }

        static func strokesByErasing(
            _ strokes: [PKStroke],
            along locations: [CGPoint],
            diameter: CGFloat
        ) -> [PKStroke]? {
            guard let eraserPath = circularSweepPath(along: locations, diameter: diameter) else {
                return nil
            }
            return strokesByErasing(strokes, using: eraserPath)
        }

        private static func strokesByErasing(
            _ strokes: [PKStroke],
            using eraserPath: UIBezierPath
        ) -> [PKStroke]? {
            let eraserComponents = eraserPath.cgPath.componentsSeparated().filter {
                !$0.isEmpty
            }
            guard !eraserComponents.isEmpty else { return nil }

            var changed = false
            var result: [PKStroke] = []
            result.reserveCapacity(strokes.count)

            for stroke in strokes {
                let relevantComponents = eraserComponents.filter {
                    stroke.renderBounds.intersects(
                        $0.boundingBoxOfPath.insetBy(
                            dx: -edgeTolerance,
                            dy: -edgeTolerance
                        )
                    )
                }
                guard let firstComponent = relevantComponents.first else {
                    result.append(stroke)
                    continue
                }

                let relevantPath = relevantComponents.dropFirst().reduce(firstComponent) {
                    $0.union($1)
                }
                guard mightIntersectRenderedInk(stroke, eraserPath: relevantPath) else {
                    result.append(stroke)
                    continue
                }
                switch erase(stroke, using: UIBezierPath(cgPath: relevantPath)) {
                case .unchanged:
                    result.append(stroke)
                case .removed:
                    changed = true
                case let .updated(updatedStroke):
                    changed = true
                    result.append(updatedStroke)
                }
            }

            return changed ? result : nil
        }

        private static func mightIntersectRenderedInk(
            _ stroke: PKStroke,
            eraserPath: CGPath
        ) -> Bool {
            let transformedPoints = deduplicated(
                stroke.path.compactMap { point in
                    let location = point.location.applying(stroke.transform)
                    return location.x.isFinite && location.y.isFinite ? location : nil
                }
            )
            guard let firstPoint = transformedPoints.first else { return false }

            let transformScale = maximumScale(of: stroke.transform)
            let pointRadius = stroke.path.reduce(CGFloat.zero) { radius, point in
                let width = max(point.size.width, point.size.height)
                guard width.isFinite else { return radius }
                return max(radius, width * transformScale / 2)
            }

            let centerBounds = boundingRect(of: transformedPoints)
            let renderBounds = stroke.renderBounds
            let renderOutset = max(
                max(
                    centerBounds.minX - renderBounds.minX,
                    renderBounds.maxX - centerBounds.maxX
                ),
                max(
                    centerBounds.minY - renderBounds.minY,
                    renderBounds.maxY - centerBounds.maxY
                )
            )
            let finiteRenderOutset = renderOutset.isFinite ? renderOutset : 0
            let padding = max(max(pointRadius, finiteRenderOutset), 1) + edgeTolerance

            let inkEnvelope: CGPath
            if transformedPoints.count == 1 {
                inkEnvelope = CGPath(
                    ellipseIn: CGRect(
                        x: firstPoint.x - padding,
                        y: firstPoint.y - padding,
                        width: padding * 2,
                        height: padding * 2
                    ),
                    transform: nil
                )
            } else if let hullPath = RubEraserGeometry.convexHullPath(
                for: transformedPoints
            ) {
                let outline = hullPath.copy(
                    strokingWithWidth: padding * 2,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 1
                )
                inkEnvelope = hullPath.union(outline)
            } else {
                let centerline = CGMutablePath()
                centerline.addLines(between: transformedPoints)
                inkEnvelope = centerline.copy(
                    strokingWithWidth: padding * 2,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 1
                )
            }

            return inkEnvelope.intersects(eraserPath)
        }

        private static func erase(
            _ stroke: PKStroke,
            using eraserPath: UIBezierPath
        ) -> StrokeErasure {
            guard !stroke.path.isEmpty,
                  let inverseTransform = inverse(of: stroke.transform) else {
                return .unchanged
            }

            let localEraserPath = UIBezierPath(cgPath: eraserPath.cgPath)
            localEraserPath.apply(inverseTransform)

            // PencilKit masks live in the stroke's pre-transform coordinate space.
            // Subtracting from that mask preserves the original spline, pressure data,
            // randomized ink seed, and every untouched pixel of a wide stroke.
            let visibleMask: CGPath
            if let existingMask = stroke.mask {
                let fillRule: CGPathFillRule = existingMask.usesEvenOddFillRule
                    ? .evenOdd
                    : .winding
                visibleMask = existingMask.cgPath.normalized(using: fillRule)
                guard visibleMask.intersects(localEraserPath.cgPath) else {
                    return .unchanged
                }
            } else {
                // An unmasked stroke needs an initial all-visible clip. Expanding its
                // rendered bounds avoids trimming anti-aliased edge pixels when the mask
                // is installed for the first partial erase.
                let coveragePath = UIBezierPath(
                    rect: stroke.renderBounds.insetBy(dx: -1, dy: -1)
                )
                coveragePath.apply(inverseTransform)
                visibleMask = coveragePath.cgPath
            }

            let updatedMaskPath = visibleMask.subtracting(localEraserPath.cgPath)
            guard !updatedMaskPath.isEmpty else { return .removed }

            var updatedStroke = stroke
            updatedStroke.mask = UIBezierPath(cgPath: updatedMaskPath)
            // The rectangular seed mask can retain off-ink corner slivers after a
            // large circular erase. Drop the stroke only when its conservative ink
            // envelope no longer overlaps any visible mask area.
            let transformedUpdatedMask = UIBezierPath(cgPath: updatedMaskPath)
            transformedUpdatedMask.apply(stroke.transform)
            guard mightIntersectRenderedInk(
                stroke,
                eraserPath: transformedUpdatedMask.cgPath
            ) else {
                return .removed
            }
            return .updated(updatedStroke)
        }

        private static func circularSweepPath(
            along locations: [CGPoint],
            diameter: CGFloat
        ) -> UIBezierPath? {
            guard diameter.isFinite, diameter > 0 else { return nil }
            var combinedPath: CGPath?
            var currentRun: [CGPoint] = []
            func appendCurrentRun() {
                let points = deduplicated(currentRun)
                if let runPath = circularSweepPath(
                    alongFiniteRun: points,
                    diameter: diameter
                ) {
                    combinedPath = combinedPath?.union(runPath) ?? runPath
                }
                currentRun.removeAll(keepingCapacity: true)
            }

            for location in locations {
                guard location.x.isFinite, location.y.isFinite else {
                    appendCurrentRun()
                    continue
                }
                currentRun.append(location)
            }
            appendCurrentRun()

            guard let combinedPath else { return nil }
            return UIBezierPath(cgPath: combinedPath)
        }

        private static func circularSweepPath(
            alongFiniteRun points: [CGPoint],
            diameter: CGFloat
        ) -> CGPath? {
            guard let first = points.first else { return nil }

            if points.count == 1 {
                let radius = diameter / 2
                return CGPath(
                    ellipseIn: CGRect(
                        x: first.x - radius,
                        y: first.y - radius,
                        width: diameter,
                        height: diameter
                    ),
                    transform: nil
                )
            }

            let centerline = CGMutablePath()
            centerline.move(to: first)
            for point in points.dropFirst() {
                centerline.addLine(to: point)
            }
            return centerline.copy(
                strokingWithWidth: diameter,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 1
            )
        }

        private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in points {
                guard let previous = result.last else {
                    result.append(point)
                    continue
                }
                guard hypot(
                    point.x - previous.x,
                    point.y - previous.y
                ) > 0.01 else { continue }
                result.append(point)
            }
            return result
        }

        private static func inverse(of transform: CGAffineTransform) -> CGAffineTransform? {
            let determinant = transform.a * transform.d - transform.b * transform.c
            guard determinant.isFinite, abs(determinant) > .ulpOfOne else { return nil }
            return transform.inverted()
        }

        private static func maximumScale(of transform: CGAffineTransform) -> CGFloat {
            let squaredTerms = transform.a * transform.a
                + transform.b * transform.b
                + transform.c * transform.c
                + transform.d * transform.d
            let determinant = transform.a * transform.d - transform.b * transform.c
            let discriminant = max(
                squaredTerms * squaredTerms - 4 * determinant * determinant,
                0
            )
            let scale = sqrt((squaredTerms + sqrt(discriminant)) / 2)
            return scale.isFinite && scale > 0 ? scale : 1
        }

        private static func boundingRect(of points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .null }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        }
    }

    final class EraserScopeView: UIView {
        static let objectEraserDiameter: CGFloat = 12
        private let shapeLayer = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        func show(at location: CGPoint, diameter: CGFloat) {
            guard location.x.isFinite,
                  location.y.isFinite,
                  diameter.isFinite,
                  diameter > 0 else {
                hide()
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transform = .identity
            bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            center = location
            layer.cornerRadius = diameter / 2
            backgroundColor = UIColor.white.withAlphaComponent(0.18)
            layer.borderWidth = 1.5
            shapeLayer.isHidden = true
            isHidden = false
            CATransaction.commit()
        }

        func showRub(at location: CGPoint, configuration: RubEraserConfiguration) {
            guard location.x.isFinite,
                  location.y.isFinite,
                  configuration.isValid else {
                hide()
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bounds = CGRect(x: 0, y: 0, width: configuration.size, height: configuration.size)
            center = location
            layer.cornerRadius = 0
            layer.borderWidth = 0
            backgroundColor = .clear
            shapeLayer.frame = bounds
            shapeLayer.path = RubEraserGeometry.shapePath(
                centeredAt: CGPoint(x: bounds.midX, y: bounds.midY),
                configuration: configuration
            ).cgPath
            shapeLayer.isHidden = false
            isHidden = false
            CATransaction.commit()
        }

        func hide() {
            isHidden = true
        }

        private func configureView() {
            isHidden = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = UIColor.white.withAlphaComponent(0.18)
            layer.borderColor = UIColor.black.withAlphaComponent(0.68).cgColor
            layer.borderWidth = 1.5
            layer.shadowColor = UIColor.white.cgColor
            layer.shadowOpacity = 0.95
            layer.shadowRadius = 1
            layer.shadowOffset = .zero
            shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.18).cgColor
            shapeLayer.strokeColor = UIColor.black.withAlphaComponent(0.68).cgColor
            shapeLayer.lineWidth = 1.5
            shapeLayer.shadowColor = UIColor.white.cgColor
            shapeLayer.shadowOpacity = 0.95
            shapeLayer.shadowRadius = 1
            shapeLayer.shadowOffset = .zero
            layer.addSublayer(shapeLayer)
        }
    }

    final class PageCanvasView: UIView, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        private struct NativeViewportRequest {
            var rect: CGRect
            var overscan: CGFloat
            var scale: CGFloat
            var force: Bool
        }

        /// PencilKit's canvas is still needed for drawing, but its standard edit
        /// commands are not meaningful for a drawing page. Keep the canvas's normal
        /// responder behavior for PencilKit while preventing those commands from
        /// creating a second native menu during a finger hold.
        private final class DrawingOnlyCanvasView: PKCanvasView {
            override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
                if PageCanvasView.blocksNativeDrawingEditAction(action) {
                    return false
                }
                return super.canPerformAction(action, withSender: sender)
            }
        }

        let backgroundView = PageBackgroundUIView()
        let behindImageContainerView = UIView(frame: .zero)
        let drawingViewportView = UIView(frame: .zero)
        let canvasView: PKCanvasView = DrawingOnlyCanvasView(frame: .zero)
        let foregroundImageContainerView = UIView(frame: .zero)
        let eraserScopeView = EraserScopeView(frame: .zero)

        private var imageViews: [UUID: AttachmentImageContainerView] = [:]
        private let eraserScopeGesture = EraserScopeGestureRecognizer()
        private(set) var attachmentSelectionGesture: UITapGestureRecognizer?
        private var attachmentEditingOverlay: AttachmentEditingOverlayView?
        private var attachmentEditingHostView: AttachmentEditingHostView?
        private var codeSnippetEditingController: UIHostingController<CodeSnippetCanvasEditor>?
        private var codeSnippetEditingState: CodeSnippetCanvasEditingState?
        private var codeSnippetLastSavedDraft: CodeSnippetDraft?
        private var codeSnippetLastSourceSavedDraft: CodeSnippetDraft?
        private var codeSnippetPreviewNeedsRefresh = false
        private var codeSnippetSaveWorkItem: DispatchWorkItem?
        private var pendingCodeSnippetPreviewRefreshIDs: [UUID] = []
        private var pendingCodeSnippetPreviewRefreshIDSet: Set<UUID> = []
        private var codeSnippetPreviewRefreshAttempts: [UUID: Int] = [:]
        private var codeSnippetPreviewRefreshWorkItem: DispatchWorkItem?
        private static let maximumCodeSnippetPreviewRefreshAttempts = 3
        private(set) var page: NotePage?
        private(set) var selectedAttachmentID: UUID?
        private var configurationSignature: String?
        private var attachmentChanged: (() -> Void)?
        private var deleteAttachment: ((Attachment) -> Void)?
        private var editCodeSnippet: ((Attachment) -> Void)?
        private var saveCodeSnippetSource: ((CodeSnippetDraft, Attachment) -> Bool)?
        private var saveCodeSnippet: ((CodeSnippetDraft, Attachment) -> Bool)?
        private var isDarkAppearance = false
        private var pageActionRequested: ((UUID, NotePageContextAction) -> Void)?
        private var pageContextMenuWillOpen: ((UUID) -> Void)?
        private var pageIDForPageAction: ((CGPoint) -> UUID?)?
        private var activePageActionPageID: UUID?
        private var nativeEditMenuSuppressionGeneration = 0
        private var canRemovePage = false
        private(set) lazy var pageActionMenuInteraction = UIEditMenuInteraction(delegate: self)
        private(set) var pageActionLongPressGesture: UILongPressGestureRecognizer?
        private var hasConfiguredImageAttachments = false
        private var lastBackgroundScale: CGFloat = 0
        private var lastImageScale: CGFloat = 0
        private var isImageLoadingEnabled = true
        private var isViewportVisible = false
        private var isDocumentTraversalActive = false
        private var isDrawingInteractionActive = false
        private var appliedInputMode: DrawingInputMode?
        private var isCaptureInteractionEnabled = false
        private var allowsAttachmentSelection = true
        private var isUsingDrawingTool = false
        private var eraserPreviewDiameter: CGFloat?
        private var usesCustomObjectEraser = false
        private var rubEraserConfiguration: RubEraserConfiguration?
        private var objectEraserPath = ObjectEraserPathAccumulator()
        private var objectEraserPendingPath: [CGPoint] = []
        private var objectEraserPendingTravelDistance: CGFloat = 0
        private var objectEraserPendingFlushWorkItem: DispatchWorkItem?
        private var isTrackingObjectEraser = false
        private var objectEraserInitialDrawing: PKDrawing?
        private var objectEraserHitTestSession: ObjectEraserHitTester.Session?
        private var objectEraserRemovedStrokeIndexes = IndexSet()
        private var objectEraserHasChanges = false
        private(set) var objectEraserLiveEvaluationCount = 0
        private var laidOutPageBounds: CGRect = .null

        var isDrawingInteractionActiveForTesting: Bool {
            isDrawingInteractionActive
        }

        var isDocumentTraversalActiveForTesting: Bool {
            isDocumentTraversalActive
        }
        private var drawingPageSizeOverride: CGSize?
        private var isDrawingSurfaceEnabled = true
        private var isDrawingLoadBlocked = false
        private var activeDrawingViewportRect: CGRect = .null
        private var nativeZoomScale: CGFloat = 1
        private var pendingNativeViewport: NativeViewportRequest?

        var objectEraserDidBegin: (() -> Void)?
        var objectEraserDidEnd: (() -> Void)?
        var objectEraserDrawingChanged: (() -> Void)?
        var accessibilityAttachmentSelectionRequested: ((Attachment) -> Void)?

        var currentNativeDrawingZoomScale: CGFloat {
            nativeZoomScale
        }

        private var drawingPageSize: CGSize {
            drawingPageSizeOverride ?? page?.pageSize ?? .zero
        }

        var isUsingCustomObjectEraser: Bool {
            usesCustomObjectEraser
        }

        var isUsingCustomRubEraser: Bool {
            rubEraserConfiguration != nil
        }

        var hasActiveDrawingGesture: Bool {
            [
                canvasView.drawingGestureRecognizer.state,
                eraserScopeGesture.state
            ].contains { $0 == .began || $0 == .changed }
        }

        private var usesCustomEraserInput: Bool {
            usesCustomObjectEraser || rubEraserConfiguration != nil
        }

        var consumesBlankCanvasTaps: Bool {
            !isCaptureInteractionEnabled
                && appliedInputMode == .pencilOnly
                && !(canvasView.tool is PKLassoTool)
        }

        var allowsPageActionLongPress: Bool {
            appliedInputMode == .pencilOnly
                && !isCaptureInteractionEnabled
                && !(canvasView.tool is PKLassoTool)
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            guard !Self.blocksNativeDrawingEditAction(action) else { return false }
            return super.canPerformAction(action, withSender: sender)
        }

        private static func blocksNativeDrawingEditAction(_ action: Selector) -> Bool {
            switch action {
            case #selector(UIResponder.selectAll(_:)),
                 Selector(("insertSpace:")),
                 Selector(("insertTab:")):
                return true
            default:
                return false
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        func configure(
            page: NotePage,
            storage: LocalStorageService,
            drawingStorage: DrawingStorageService,
            inputMode: DrawingInputMode,
            theme: BeanNotesTheme = .defaultTheme,
            showsBeanArtwork: Bool = false,
            coordinator: Coordinator,
            attachmentChanged: @escaping () -> Void,
            deleteAttachment: @escaping (Attachment) -> Void,
            editCodeSnippet: @escaping (Attachment) -> Void = { _ in },
            saveCodeSnippetSource: ((CodeSnippetDraft, Attachment) -> Bool)? = nil,
            saveCodeSnippet: ((CodeSnippetDraft, Attachment) -> Bool)? = nil,
            isDarkAppearance: Bool = false,
            canRemovePage: Bool = false,
            drawingEnabled: Bool = true,
            flushAppearance: Bool = false,
            pageActionRequested: @escaping (UUID, NotePageContextAction) -> Void = { _, _ in },
            pageContextMenuWillOpen: @escaping (UUID) -> Void = { _ in }
        ) {
            var drawingLoadResults: [(NotePage, DrawingStorageService.LoadResult)]?
            let wasDrawingSurfaceEnabled = isDrawingSurfaceEnabled
            let wasRegisteredForDrawing = canvasView.delegate != nil
            let isNewPage = self.page?.id != page.id
            let signature = "\(staticContentSignature(for: page))#theme=\(theme.rawValue)#beanArtwork=\(showsBeanArtwork)#dark=\(isDarkAppearance)"
            let needsStaticRefresh = isNewPage || signature != configurationSignature
            let pageSizeChanged = laidOutPageBounds.size != page.pageSize
            drawingPageSizeOverride = nil
            isDrawingSurfaceEnabled = drawingEnabled
            allowsAttachmentSelection = true
            if isNewPage {
                clearAttachmentSelection()
                cancelPendingCodeSnippetPreviewRefreshes()
                hasConfiguredImageAttachments = false
            }
            self.page = page
            accessibilityIdentifier = drawingEnabled ? "notePageCanvas" : "noteCanvasSection"
            accessibilityLabel = drawingEnabled
                ? "Page \(page.pageOrder + 1) canvas"
                : "Drawing space section \(page.pageOrder + 1)"
            self.attachmentChanged = attachmentChanged
            self.deleteAttachment = deleteAttachment
            self.editCodeSnippet = editCodeSnippet
            self.saveCodeSnippetSource = saveCodeSnippetSource
            self.saveCodeSnippet = saveCodeSnippet
            self.isDarkAppearance = isDarkAppearance
            self.canRemovePage = canRemovePage
            self.pageActionRequested = pageActionRequested
            self.pageContextMenuWillOpen = pageContextMenuWillOpen
            self.pageIDForPageAction = { _ in page.id }
            activePageActionPageID = nil
            layer.shadowOpacity = flushAppearance ? 0 : 0.12
            backgroundView.isHidden = false
            behindImageContainerView.isHidden = false
            foregroundImageContainerView.isHidden = false
            attachmentSelectionGesture?.isEnabled = true
            pageActionLongPressGesture?.isEnabled = true

            applyInputMode(inputMode)
            canvasView.isUserInteractionEnabled = drawingEnabled && !isDrawingLoadBlocked
            if !drawingEnabled {
                setDrawingLoadBlocked(false)
                drawingViewportView.isHidden = true
                canvasView.delegate = nil
                canvasView.drawing = PKDrawing()
            }

            if !isNewPage, !needsStaticRefresh, !pageSizeChanged,
               wasDrawingSurfaceEnabled == drawingEnabled {
                return
            }

            if needsStaticRefresh {
                backgroundView.background = page.background
                backgroundView.theme = theme
                backgroundView.showsBeanArtwork = showsBeanArtwork
                backgroundView.pageID = page.id
            }

            if needsStaticRefresh || pageSizeChanged {
                backgroundView.isCoveredByOpaquePDF = DrawingCanvasPDFCoverage.fullyCoversPage(
                    page.visualAttachments,
                    pageSize: page.pageSize
                )
                backgroundView.refreshRenderingMode()
            }

            if needsStaticRefresh {
                configureImages(page.visualAttachments, storage: storage, attachmentChanged: attachmentChanged)
                configurationSignature = signature
            }

            if drawingEnabled, isNewPage || !wasDrawingSurfaceEnabled {
                resetNativeCanvas(
                    pageSize: page.pageSize,
                    initialViewportSize: compactDrawingViewportSize(for: page.pageSize)
                )
                let loadResult = drawingStorage.loadDrawingResult(for: page)
                drawingLoadResults = [(page, loadResult)]
                canvasView.drawing = loadResult.drawing
                setDrawingLoadBlocked(loadResult.error != nil)
            } else if drawingEnabled, pageSizeChanged {
                resetNativeCanvas(
                    pageSize: page.pageSize,
                    initialViewportSize: compactDrawingViewportSize(for: page.pageSize)
                )
            }

            if drawingEnabled {
                canvasView.delegate = coordinator
                coordinator.register(
                    canvasView: canvasView,
                    page: page,
                    pageView: self,
                    drawingLoadResults: drawingLoadResults
                )
            } else if wasDrawingSurfaceEnabled, wasRegisteredForDrawing {
                coordinator.unregister(
                    canvasView: canvasView,
                    page: page,
                    flushDrawingBeforeRelease: false
                )
            }

            layoutPage()
            restoreDrawingLayerOrder()
        }

        func updateArtworkVisibility(_ showsBeanArtwork: Bool) {
            guard backgroundView.showsBeanArtwork != showsBeanArtwork else { return }
            backgroundView.showsBeanArtwork = showsBeanArtwork
            backgroundView.refreshRenderingMode()
            // Repainting the background must not alter the PencilKit and attachment
            // layer order, and must not require rebuilding the live drawing.
            restoreDrawingLayerOrder()
        }

        func setBackgroundPatternOrigin(_ origin: CGPoint?) {
            backgroundView.patternOrigin = origin
        }

        func configureContinuousDrawingOverlay(
            representativePage: NotePage,
            pageSize: CGSize,
            drawing: PKDrawing,
            drawingLoadResults: [(NotePage, DrawingStorageService.LoadResult)],
            inputMode: DrawingInputMode,
            coordinator: Coordinator,
            pageIDForPageAction: @escaping (CGPoint) -> UUID?,
            canRemovePage: Bool,
            pageActionRequested: @escaping (UUID, NotePageContextAction) -> Void,
            pageContextMenuWillOpen: @escaping (UUID) -> Void
        ) {
            let needsCanvasReset = page?.id != representativePage.id
                || drawingPageSizeOverride != pageSize
                || !isDrawingSurfaceEnabled

            page = representativePage
            drawingPageSizeOverride = pageSize
            isDrawingSurfaceEnabled = true
            allowsAttachmentSelection = false
            accessibilityIdentifier = "notePageCanvas"
            accessibilityLabel = "Continuous drawing canvas"
            attachmentChanged = nil
            deleteAttachment = nil
            editCodeSnippet = nil
            saveCodeSnippetSource = nil
            saveCodeSnippet = nil
            self.canRemovePage = canRemovePage
            self.pageActionRequested = pageActionRequested
            self.pageContextMenuWillOpen = pageContextMenuWillOpen
            self.pageIDForPageAction = pageIDForPageAction
            activePageActionPageID = nil

            layer.shadowOpacity = 0
            backgroundView.isHidden = true
            behindImageContainerView.isHidden = true
            foregroundImageContainerView.isHidden = true
            attachmentSelectionGesture?.isEnabled = false
            updateDrawingInteractionRecognizers()
            let hasUnavailableDrawing = drawingLoadResults.contains { $0.1.error != nil }
            setDrawingLoadBlocked(hasUnavailableDrawing)
            applyInputMode(inputMode)

            if needsCanvasReset {
                resetNativeCanvas(
                    pageSize: pageSize,
                    initialViewportSize: CGSize(
                        width: min(pageSize.width, 2_048),
                        height: min(pageSize.height, 2_048)
                    )
                )
            }
            canvasView.drawing = drawing
            canvasView.delegate = coordinator
            coordinator.register(
                canvasView: canvasView,
                page: representativePage,
                pageView: self,
                drawingLoadResults: drawingLoadResults
            )
            layoutPage()
            restoreDrawingLayerOrder()
        }

        func applyInputMode(_ inputMode: DrawingInputMode) {
            appliedInputMode = inputMode
            eraserScopeGesture.allowedTouchTypes = inputMode == .pencilOnly
                ? [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
                : [
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                    NSNumber(value: UITouch.TouchType.direct.rawValue)
                ]
            // UIKit can disable a recognizer while resolving competing gestures.
            // Reassert the editable state whenever SwiftUI configures the canvas so
            // a recycled page cannot remain permanently non-interactive. Custom
            // erasing owns this recognizer's input while it performs boundary-matched hits.
            canvasView.isUserInteractionEnabled = isDrawingSurfaceEnabled && !isDrawingLoadBlocked
            updateDrawingInteractionRecognizers()
            guard canvasView.drawingPolicy != inputMode.drawingPolicy else { return }
            canvasView.drawingPolicy = inputMode.drawingPolicy
        }

        func setDrawingLoadBlocked(_ blocked: Bool) {
            guard isDrawingLoadBlocked != blocked else { return }
            isDrawingLoadBlocked = blocked
            canvasView.isUserInteractionEnabled = isDrawingSurfaceEnabled && !blocked
            updateDrawingInteractionRecognizers()
        }

        func setCaptureInteractionEnabled(_ enabled: Bool) {
            guard isCaptureInteractionEnabled != enabled else { return }
            isCaptureInteractionEnabled = enabled
            if enabled {
                clearAttachmentSelection()
                dismissNativeCanvasEditMenus()
            }
            attachmentSelectionGesture?.isEnabled = allowsAttachmentSelection && !enabled
            pageActionLongPressGesture?.isEnabled = !enabled
            eraserScopeGesture.isEnabled = !enabled
            canvasView.drawingGestureRecognizer.isEnabled = !enabled && !usesCustomEraserInput
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            for view in imageViews.values {
                view.setImageLoadingEnabled(enabled)
            }
        }

        func setViewportVisible(_ visible: Bool) {
            guard isViewportVisible != visible else { return }
            isViewportVisible = visible
            for view in imageViews.values {
                view.setViewportVisible(visible)
            }
        }

        func setDocumentTraversalActive(_ active: Bool) {
            guard isDocumentTraversalActive != active else { return }
            isDocumentTraversalActive = active
            for view in imageViews.values {
                view.setDocumentTraversalActive(active)
            }
        }

        func setDrawingInteractionActive(_ active: Bool) {
            guard isDrawingInteractionActive != active else { return }
            isDrawingInteractionActive = active
            for view in imageViews.values {
                view.setDrawingInteractionActive(active)
            }
            applyPendingNativeViewportIfPossible()
        }

        private func staticContentSignature(for page: NotePage) -> String {
            DrawingCanvasStaticContentSignature.signature(for: page)
        }

        func layoutPage() {
            guard let page else { return }
            let pageBounds = CGRect(origin: .zero, size: drawingPageSize)

            if laidOutPageBounds != pageBounds {
                backgroundView.frame = pageBounds
                behindImageContainerView.frame = pageBounds
                foregroundImageContainerView.frame = pageBounds
                layer.shadowPath = UIBezierPath(rect: pageBounds).cgPath
                laidOutPageBounds = pageBounds
            }

            for attachment in page.visualAttachments {
                imageViews[attachment.id]?.frame = displayedFrame(for: attachment)
            }

            if let selectedAttachmentID,
               let selectedAttachment = page.visualAttachments.first(where: { $0.id == selectedAttachmentID }) {
                attachmentEditingOverlay?.updateFrame(
                    displayedFrame(for: selectedAttachment),
                    pageSize: page.pageSize
                )
                codeSnippetEditingController?.view.frame = displayedFrame(for: selectedAttachment)
            }
        }

        func presentForegroundImages(in hostView: UIView, documentFrame: CGRect) {
            if foregroundImageContainerView.superview !== hostView {
                foregroundImageContainerView.removeFromSuperview()
                hostView.addSubview(foregroundImageContainerView)
            }
            foregroundImageContainerView.frame = documentFrame
            hostView.bringSubviewToFront(foregroundImageContainerView)
        }

        func presentAttachmentEditingControls(in hostView: UIView, documentFrame: CGRect) {
            guard let attachmentEditingOverlay else { return }

            let editingHost = attachmentEditingHostView ?? {
                let view = AttachmentEditingHostView()
                attachmentEditingHostView = view
                return view
            }()
            editingHost.frame = documentFrame
            if editingHost.superview !== hostView {
                editingHost.removeFromSuperview()
                hostView.addSubview(editingHost)
            }
            if let editorView = codeSnippetEditingController?.view,
               editorView.superview !== editingHost {
                editorView.removeFromSuperview()
                editingHost.addSubview(editorView)
            }
            if attachmentEditingOverlay.superview !== editingHost {
                attachmentEditingOverlay.removeFromSuperview()
                editingHost.addSubview(attachmentEditingOverlay)
            }
            if let editorView = codeSnippetEditingController?.view {
                editingHost.bringSubviewToFront(editorView)
            }
            editingHost.bringSubviewToFront(attachmentEditingOverlay)
            hostView.bringSubviewToFront(editingHost)
        }

        func restoreForegroundImagesToPage() {
            guard foregroundImageContainerView.superview !== self else { return }
            foregroundImageContainerView.removeFromSuperview()
            addSubview(foregroundImageContainerView)
            foregroundImageContainerView.frame = CGRect(origin: .zero, size: drawingPageSize)
            restoreDrawingLayerOrder()
        }

        func restoreAttachmentEditingControlsToPage() {
            guard let editingHost = attachmentEditingHostView else { return }
            if let editorView = codeSnippetEditingController?.view {
                editorView.removeFromSuperview()
                addSubview(editorView)
            }
            if let attachmentEditingOverlay {
                attachmentEditingOverlay.removeFromSuperview()
                addSubview(attachmentEditingOverlay)
            }
            editingHost.removeFromSuperview()
            attachmentEditingHostView = nil
            restoreDrawingLayerOrder()
        }

        private func configureView() {
            // Paper and PencilKit ink stay visually stable while the workspace chrome follows dark mode.
            overrideUserInterfaceStyle = .light
            clipsToBounds = false
            contentScaleFactor = UIScreen.main.scale
            layer.contentsScale = UIScreen.main.scale
            layer.rasterizationScale = UIScreen.main.scale
            layer.shouldRasterize = false
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 8)

            backgroundView.isUserInteractionEnabled = false
            addSubview(backgroundView)

            behindImageContainerView.backgroundColor = .clear
            behindImageContainerView.clipsToBounds = true
            behindImageContainerView.isUserInteractionEnabled = false
            addSubview(behindImageContainerView)

            drawingViewportView.backgroundColor = .clear
            drawingViewportView.clipsToBounds = true
            drawingViewportView.isHidden = true
            addSubview(drawingViewportView)

            foregroundImageContainerView.backgroundColor = .clear
            foregroundImageContainerView.clipsToBounds = true
            foregroundImageContainerView.isUserInteractionEnabled = false
            addSubview(foregroundImageContainerView)

            canvasView.backgroundColor = .clear
            canvasView.isOpaque = false
            canvasView.isScrollEnabled = false
            canvasView.delaysContentTouches = false
            // The document scroll view is the only view that should respond to the
            // status-bar scroll-to-top gesture.
            canvasView.scrollsToTop = false
            canvasView.panGestureRecognizer.isEnabled = false
            canvasView.pinchGestureRecognizer?.isEnabled = false
            canvasView.minimumZoomScale = 1
            canvasView.maximumZoomScale = 1
            canvasView.contentScaleFactor = UIScreen.main.scale
            canvasView.layer.contentsScale = UIScreen.main.scale
            canvasView.layer.rasterizationScale = UIScreen.main.scale
            canvasView.layer.shouldRasterize = false
            canvasView.layer.allowsEdgeAntialiasing = true
            canvasView.contentMode = .redraw
            drawingViewportView.addSubview(canvasView)

            eraserScopeGesture.coordinateView = self
            eraserScopeGesture.interactionChanged = { [weak self] interaction in
                self?.handleEraserInteraction(interaction)
            }
            eraserScopeGesture.cancelsTouchesInView = false
            eraserScopeGesture.delaysTouchesBegan = false
            eraserScopeGesture.delaysTouchesEnded = false
            eraserScopeGesture.delegate = self
            canvasView.addGestureRecognizer(eraserScopeGesture)

            addSubview(eraserScopeView)

            let selectAttachmentGesture = UITapGestureRecognizer(
                target: self,
                action: #selector(handleAttachmentSelection(_:))
            )
            selectAttachmentGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            selectAttachmentGesture.cancelsTouchesInView = true
            selectAttachmentGesture.delegate = self
            addGestureRecognizer(selectAttachmentGesture)
            attachmentSelectionGesture = selectAttachmentGesture

            let pageLongPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handlePageActionLongPress(_:))
            )
            pageLongPress.minimumPressDuration = 0.5
            pageLongPress.allowableMovement = 12
            pageLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pageLongPress.cancelsTouchesInView = true
            pageLongPress.delegate = self
            addGestureRecognizer(pageLongPress)
            pageActionLongPressGesture = pageLongPress
            selectAttachmentGesture.require(toFail: pageLongPress)
            // In Any Input mode, a finger tap on a snippet must select it without
            // leaving a PencilKit dot underneath. A moving finger quickly fails the
            // tap recognizer and continues as normal drawing.
            canvasView.drawingGestureRecognizer.require(toFail: selectAttachmentGesture)
            // Pencil-only mode can reserve a stationary finger hold for page actions.
            // Any Input disables this recognizer so first ink never waits for the
            // long-press failure timeout; page actions remain available in the toolbar.
            canvasView.drawingGestureRecognizer.require(toFail: pageLongPress)
            eraserScopeGesture.require(toFail: pageLongPress)

            addInteraction(pageActionMenuInteraction)
        }

        /// Gives the editor's direct-touch gestures priority over PencilKit's private
        /// tap and hold recognizers, which otherwise can present Select All / Insert
        /// Space after a completed page action gesture.
        func prioritizePageActionGestures(over fingerDoubleTap: UITapGestureRecognizer?) {
            installPageActionGestureRequirements(over: fingerDoubleTap)
            DispatchQueue.main.async { [weak self, weak fingerDoubleTap] in
                self?.installPageActionGestureRequirements(over: fingerDoubleTap)
            }
        }

        private func installPageActionGestureRequirements(over fingerDoubleTap: UITapGestureRecognizer?) {
            guard let pageActionLongPressGesture else { return }

            for recognizer in nativeDirectTouchMenuRecognizers(in: canvasView) {
                recognizer.require(toFail: pageActionLongPressGesture)
                if let fingerDoubleTap {
                    recognizer.require(toFail: fingerDoubleTap)
                }
            }
        }

        private func nativeDirectTouchMenuRecognizers(in view: UIView) -> [UIGestureRecognizer] {
            let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
            let localRecognizers = (view.gestureRecognizers ?? []).filter { recognizer in
                guard recognizer !== pageActionLongPressGesture,
                      recognizer !== canvasView.drawingGestureRecognizer,
                      recognizer !== eraserScopeGesture,
                      recognizer is UILongPressGestureRecognizer || recognizer is UITapGestureRecognizer
                else {
                    return false
                }

                return recognizer.allowedTouchTypes.contains(directTouch)
            }
            return localRecognizers + view.subviews.flatMap(nativeDirectTouchMenuRecognizers(in:))
        }

        func makePageContextMenu(
            for pageID: UUID,
            canRemovePage: Bool,
            canPasteImage: Bool
        ) -> UIMenu {
            let addBelow = UIAction(
                title: "Add Page Below",
                image: UIImage(systemName: "rectangle.stack.badge.plus")
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .add(.below))
            }
            let addAbove = UIAction(
                title: "Add Page Above",
                image: UIImage(systemName: "rectangle.stack.badge.plus")
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .add(.above))
            }
            let pasteImage = UIAction(
                title: "Paste Image",
                image: UIImage(systemName: "photo.on.clipboard")
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .pasteImage)
            }
            pasteImage.attributes = canPasteImage ? [] : [.disabled]
            let remove = UIAction(
                title: "Remove Page",
                image: UIImage(systemName: "trash"),
                attributes: canRemovePage ? [.destructive] : [.destructive, .disabled]
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .remove)
            }

            return UIMenu(
                title: "",
                options: [.displayInline],
                children: [addBelow, addAbove, pasteImage, remove]
            )
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard interaction === pageActionMenuInteraction,
                  let pageID = activePageActionPageID ?? page?.id else {
                return nil
            }
            // Returning only BeanNotes actions intentionally replaces UIKit's suggested
            // edit commands, including PencilKit's Select All and Insert Space items.
            return makePageContextMenu(
                for: pageID,
                canRemovePage: canRemovePage,
                canPasteImage: UIPasteboard.general.hasImages
            )
        }

        @objc private func handlePageActionLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer === pageActionLongPressGesture,
                  recognizer.state == .began,
                  let pageID = pageIDForPageAction?(recognizer.location(in: self)) else {
                return
            }

            activePageActionPageID = pageID
            clearAttachmentSelection()
            suppressNativeCanvasEditMenus()
            pageContextMenuWillOpen?(pageID)
            let configuration = UIEditMenuConfiguration(
                identifier: pageID as NSUUID,
                sourcePoint: recognizer.location(in: self)
            )
            pageActionMenuInteraction.presentEditMenu(with: configuration)
            suppressNativeCanvasEditMenus()
        }

        func updateRenderScale(
            backgroundScale: CGFloat,
            imageScale: CGFloat,
            reloadImageVariants: Bool = true,
            force: Bool = false
        ) {
            let backgroundChanged = abs(backgroundScale - lastBackgroundScale) > 0.05
            let imageChanged = abs(imageScale - lastImageScale) > 0.05
            guard force || backgroundChanged || imageChanged else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            contentScaleFactor = backgroundScale
            layer.contentsScale = backgroundScale
            layer.rasterizationScale = backgroundScale

            if force || backgroundChanged {
                backgroundView.updateRenderScale(backgroundScale)
                lastBackgroundScale = backgroundScale
            }

            if force || imageChanged {
                for view in imageViews.values {
                    view.updateRasterScale(imageScale, reloadImageVariant: reloadImageVariants)
                }
                lastImageScale = imageScale
            }

            CATransaction.commit()
        }

        func updateNativeDrawingViewport(
            visiblePageRect: CGRect,
            overscan: CGFloat,
            nativeZoomScale: CGFloat,
            force: Bool = false
        ) {
            guard page != nil, isDrawingSurfaceEnabled else { return }
            let pageBounds = CGRect(origin: .zero, size: drawingPageSize)
            let requiredRect = visiblePageRect.intersection(pageBounds)
            guard !requiredRect.isNull, !requiredRect.isEmpty else {
                deactivateDrawingViewport()
                return
            }

            let normalizedOverscan = max(overscan.isFinite ? overscan : 0, 0)
            let scale = max(nativeZoomScale.isFinite ? nativeZoomScale : 1, 1)
            let request = NativeViewportRequest(
                rect: requiredRect,
                overscan: normalizedOverscan,
                scale: scale,
                force: force
            )

            // Moving or resizing PencilKit's native tiled surface during an active stroke can
            // interrupt live ink. Keep its geometry stable until PencilKit ends the stroke.
            guard !isUsingDrawingTool else {
                pendingNativeViewport = request
                return
            }

            applyNativeDrawingViewport(request)
        }

        func deactivateDrawingViewport() {
            guard isDrawingSurfaceEnabled, !isUsingDrawingTool else { return }
            pendingNativeViewport = nil
            drawingViewportView.isHidden = true
        }

        func cancelPendingNativeViewportUpdate() {
            pendingNativeViewport = nil
        }

        func reduceDrawingMemoryFootprint() {
            guard isDrawingSurfaceEnabled, !isUsingDrawingTool else { return }
            resetNativeCanvas(
                pageSize: drawingPageSize,
                initialViewportSize: compactDrawingViewportSize(for: drawingPageSize)
            )
            drawingViewportView.isHidden = true
        }

        func setLiveDrawingActive(_ active: Bool) {
            guard isUsingDrawingTool != active else { return }
            isUsingDrawingTool = active
            if active {
                clearAttachmentSelection()
                updateEraserScope(at: eraserScopeGesture.currentLocation)
            } else {
                eraserScopeView.hide()
            }
            applyPendingNativeViewportIfPossible()
        }

        func drawingDidChange() {
            applyPendingNativeViewportIfPossible()
        }

        private func applyPendingNativeViewportIfPossible() {
            guard !isUsingDrawingTool,
                  !isDrawingInteractionActive,
                  let pendingNativeViewport else { return }
            self.pendingNativeViewport = nil
            applyNativeDrawingViewport(pendingNativeViewport)
        }

        private func applyNativeDrawingViewport(_ request: NativeViewportRequest) {
            guard page != nil, isDrawingSurfaceEnabled else { return }
            let pageBounds = CGRect(origin: .zero, size: drawingPageSize)
            let targetRect = request.rect
                .insetBy(dx: -request.overscan, dy: -request.overscan)
                .intersection(pageBounds)
                .integral
            guard !targetRect.isNull, !targetRect.isEmpty else { return }

            let safeInset = min(request.overscan * 0.35, 48 / request.scale)
            let stableRect = activeDrawingViewportRect.insetBy(dx: safeInset, dy: safeInset)
            let scaleChanged = abs(request.scale - nativeZoomScale) > 0.005
            if !request.force, !scaleChanged, stableRect.contains(request.rect) {
                drawingViewportView.isHidden = false
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            drawingViewportView.transform = .identity
            drawingViewportView.frame = targetRect
            drawingViewportView.bounds = CGRect(origin: .zero, size: targetRect.size)

            canvasView.transform = .identity
            if scaleChanged {
                let currentScale = max(canvasView.zoomScale, 0.01)
                canvasView.minimumZoomScale = min(currentScale, request.scale)
                canvasView.maximumZoomScale = max(currentScale, request.scale)
                canvasView.setZoomScale(request.scale, animated: false)
                canvasView.minimumZoomScale = request.scale
                canvasView.maximumZoomScale = request.scale
                nativeZoomScale = request.scale
            }

            canvasView.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: targetRect.width * request.scale, height: targetRect.height * request.scale)
            )
            canvasView.center = CGPoint(x: drawingViewportView.bounds.midX, y: drawingViewportView.bounds.midY)
            canvasView.setContentOffset(
                CGPoint(x: targetRect.minX * request.scale, y: targetRect.minY * request.scale),
                animated: false
            )
            canvasView.transform = CGAffineTransform(scaleX: 1 / request.scale, y: 1 / request.scale)

            activeDrawingViewportRect = targetRect
            drawingViewportView.isHidden = false
            CATransaction.commit()
            restoreDrawingLayerOrder()
        }

        private func resetNativeCanvas(
            pageSize: CGSize,
            initialViewportSize: CGSize? = nil
        ) {
            guard pageSize.width > 0, pageSize.height > 0 else { return }
            pendingNativeViewport = nil
            let viewportSize = initialViewportSize.map { requestedSize in
                CGSize(
                    width: min(max(requestedSize.width, 1), pageSize.width),
                    height: min(max(requestedSize.height, 1), pageSize.height)
                )
            } ?? pageSize

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            canvasView.transform = .identity
            let currentScale = max(canvasView.zoomScale, 0.01)
            canvasView.minimumZoomScale = min(currentScale, 1)
            canvasView.maximumZoomScale = max(currentScale, 1)
            canvasView.setZoomScale(1, animated: false)
            canvasView.minimumZoomScale = 1
            canvasView.maximumZoomScale = 1
            canvasView.contentSize = pageSize
            canvasView.bounds = CGRect(origin: .zero, size: viewportSize)
            canvasView.center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            canvasView.contentOffset = .zero

            drawingViewportView.frame = CGRect(origin: .zero, size: viewportSize)
            drawingViewportView.bounds = CGRect(origin: .zero, size: viewportSize)
            drawingViewportView.isHidden = false
            nativeZoomScale = 1
            activeDrawingViewportRect = CGRect(origin: .zero, size: viewportSize)
            CATransaction.commit()
        }

        private func compactDrawingViewportSize(for pageSize: CGSize) -> CGSize {
            CGSize(
                width: min(pageSize.width, 2_048),
                height: min(pageSize.height, 2_048)
            )
        }

        private func configureImages(
            _ attachments: [Attachment],
            storage: LocalStorageService,
            attachmentChanged: @escaping () -> Void
        ) {
            let existingIDs = Set(imageViews.keys)
            let attachmentIDs = Set(attachments.map(\.id))
            let removedIDs = imageViews.keys.filter { !attachmentIDs.contains($0) }
            for id in removedIDs {
                if let view = imageViews[id] {
                    view.releaseImage()
                    view.removeFromSuperview()
                    imageViews[id] = nil
                }
            }

            for attachment in attachments {
                enqueueCodeSnippetPreviewRefreshIfNeeded(attachment)
                let imageView = imageViews[attachment.id] ?? {
                    let view = AttachmentImageContainerView()
                    imageViews[attachment.id] = view
                    return view
                }()

                let imageContainer = (attachment.isCodeSnippet || attachment.rendersBehindDrawing)
                    ? behindImageContainerView
                    : foregroundImageContainerView
                if imageView.superview !== imageContainer {
                    imageView.removeFromSuperview()
                    imageContainer.addSubview(imageView)
                } else {
                    imageContainer.bringSubviewToFront(imageView)
                }

                // Set final bounds before configuration creates the native PDF view.
                imageView.frame = displayedFrame(for: attachment)
                imageView.setImageLoadingEnabled(isImageLoadingEnabled)
                imageView.setViewportVisible(isViewportVisible)
                imageView.setDocumentTraversalActive(isDocumentTraversalActive)
                imageView.setDrawingInteractionActive(isDrawingInteractionActive)
                let vectorSource = resolvedVectorSource(for: attachment, storage: storage)
                imageView.configure(
                    attachment: attachment,
                    storage: storage,
                    pageSize: page?.pageSize ?? .zero,
                    vectorSourceURL: vectorSource?.url,
                    vectorPageIndex: vectorSource?.pageIndex,
                    changed: attachmentChanged,
                    selectionRequested: { [weak self, weak attachment] in
                        guard let self, let attachment, !attachment.isLocked else { return }
                        if let accessibilityAttachmentSelectionRequested = self.accessibilityAttachmentSelectionRequested {
                            accessibilityAttachmentSelectionRequested(attachment)
                        } else {
                            self.beginEditingAttachment(attachment)
                        }
                    }
                )
            }

            let selectedAttachment = selectedAttachmentID.flatMap { selectedID in
                attachments.first(where: { $0.id == selectedID && !$0.isLocked })
            }
            if let selectedAttachment {
                beginEditingAttachment(selectedAttachment)
            } else if selectedAttachmentID != nil {
                clearAttachmentSelection()
            } else if hasConfiguredImageAttachments,
                      let addedAttachment = attachments.last(where: {
                          !existingIDs.contains($0.id) && !$0.isLocked
                      }) {
                beginEditingAttachment(addedAttachment)
            }

            hasConfiguredImageAttachments = true
            restoreDrawingLayerOrder()
        }

        @discardableResult
        private func refreshCodeSnippetPreviewIfNeeded(_ attachment: Attachment) -> Bool {
            guard attachment.isCodeSnippet else { return true }
            let draft: CodeSnippetDraft
            if let editingState = codeSnippetEditingState,
               editingState.draft.id == attachment.id {
                draft = editingState.draft
            } else {
                draft = CodeSnippetDraft(
                    editing: attachment,
                    defaults: CodeSnippetPreferences.defaultDraft()
                )
            }
            let interfaceStyle: UIUserInterfaceStyle = isDarkAppearance ? .dark : .light
            let expectedVersion = CodeSnippetPreviewRenderer.previewVersion(
                for: draft,
                automaticInterfaceStyle: interfaceStyle
            )
            guard attachment.codeSnippetPreviewVersion != expectedVersion else {
                discardPendingCodeSnippetPreviewRefresh(id: attachment.id)
                return true
            }
            guard let saveCodeSnippet else {
                if codeSnippetEditingState?.draft.id == attachment.id {
                    codeSnippetPreviewNeedsRefresh = true
                }
                return false
            }
            guard saveCodeSnippet(draft, attachment) else {
                if codeSnippetEditingState?.draft.id == attachment.id {
                    codeSnippetPreviewNeedsRefresh = true
                }
                return false
            }

            if codeSnippetEditingState?.draft.id == attachment.id {
                codeSnippetLastSavedDraft = draft
                codeSnippetLastSourceSavedDraft = draft
                codeSnippetPreviewNeedsRefresh = false
            }
            discardPendingCodeSnippetPreviewRefresh(id: attachment.id)
            return true
        }

        private func enqueueCodeSnippetPreviewRefreshIfNeeded(_ attachment: Attachment) {
            guard attachment.isCodeSnippet, saveCodeSnippet != nil else { return }
            let draft = CodeSnippetDraft(
                editing: attachment,
                defaults: CodeSnippetPreferences.defaultDraft()
            )
            let interfaceStyle: UIUserInterfaceStyle = isDarkAppearance ? .dark : .light
            let expectedVersion = CodeSnippetPreviewRenderer.previewVersion(
                for: draft,
                automaticInterfaceStyle: interfaceStyle
            )
            guard attachment.codeSnippetPreviewVersion != expectedVersion else {
                discardPendingCodeSnippetPreviewRefresh(id: attachment.id)
                return
            }
            guard pendingCodeSnippetPreviewRefreshIDSet.insert(attachment.id).inserted else {
                return
            }

            pendingCodeSnippetPreviewRefreshIDs.append(attachment.id)
            scheduleNextCodeSnippetPreviewRefresh()
        }

        private func scheduleNextCodeSnippetPreviewRefresh(after delay: TimeInterval = 0) {
            guard codeSnippetPreviewRefreshWorkItem == nil,
                  !pendingCodeSnippetPreviewRefreshIDs.isEmpty else {
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.codeSnippetPreviewRefreshWorkItem = nil
                self.processNextCodeSnippetPreviewRefresh()
            }
            codeSnippetPreviewRefreshWorkItem = workItem
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            } else {
                // Never render or mutate SwiftData inside UIViewRepresentable's
                // configuration pass. One item per turn also bounds UI stalls when a
                // migrated page contains several stale snippet previews.
                DispatchQueue.main.async(execute: workItem)
            }
        }

        private func processNextCodeSnippetPreviewRefresh() {
            guard !pendingCodeSnippetPreviewRefreshIDs.isEmpty else { return }
            let attachmentID = pendingCodeSnippetPreviewRefreshIDs.removeFirst()
            pendingCodeSnippetPreviewRefreshIDSet.remove(attachmentID)

            guard let attachment = page?.visualAttachments.first(where: {
                $0.id == attachmentID && $0.isCodeSnippet
            }) else {
                codeSnippetPreviewRefreshAttempts.removeValue(forKey: attachmentID)
                scheduleNextCodeSnippetPreviewRefresh(after: 0.01)
                return
            }

            if refreshCodeSnippetPreviewIfNeeded(attachment) {
                codeSnippetPreviewRefreshAttempts.removeValue(forKey: attachmentID)
                scheduleNextCodeSnippetPreviewRefresh(after: 0.01)
                return
            }

            let attempts = codeSnippetPreviewRefreshAttempts[attachmentID, default: 0] + 1
            if attempts < Self.maximumCodeSnippetPreviewRefreshAttempts {
                codeSnippetPreviewRefreshAttempts[attachmentID] = attempts
                if pendingCodeSnippetPreviewRefreshIDSet.insert(attachmentID).inserted {
                    pendingCodeSnippetPreviewRefreshIDs.append(attachmentID)
                }
            } else {
                codeSnippetPreviewRefreshAttempts.removeValue(forKey: attachmentID)
            }
            scheduleNextCodeSnippetPreviewRefresh(
                after: pendingCodeSnippetPreviewRefreshIDs.count == 1 ? 0.15 : 0.01
            )
        }

        private func discardPendingCodeSnippetPreviewRefresh(id: UUID) {
            pendingCodeSnippetPreviewRefreshIDSet.remove(id)
            pendingCodeSnippetPreviewRefreshIDs.removeAll { $0 == id }
            codeSnippetPreviewRefreshAttempts.removeValue(forKey: id)
        }

        private func cancelPendingCodeSnippetPreviewRefreshes() {
            codeSnippetPreviewRefreshWorkItem?.cancel()
            codeSnippetPreviewRefreshWorkItem = nil
            pendingCodeSnippetPreviewRefreshIDs.removeAll()
            pendingCodeSnippetPreviewRefreshIDSet.removeAll()
            codeSnippetPreviewRefreshAttempts.removeAll()
        }

        private func resolvedVectorSource(
            for attachment: Attachment,
            storage: LocalStorageService
        ) -> (url: URL, pageIndex: Int)? {
            if let storedFileName = attachment.vectorSourceStoredFileName,
               let pageIndex = attachment.vectorSourcePageIndex,
               let url = try? storage.validatedURL(forRelativePath: storedFileName) {
                return (url, pageIndex)
            }

            guard attachment.rendersBehindDrawing,
                  attachment.originalFileName.lowercased().contains("-page-"),
                  let page,
                  let note = page.note,
                  let pageIndex = note.sortedPages.firstIndex(where: { $0.id == page.id }),
                  let originalPDF = note.pages
                    .flatMap(\.attachments)
                    .first(where: { $0.kind == .pdf }),
                  let url = try? storage.validatedURL(forRelativePath: originalPDF.storedFileName)
            else {
                return nil
            }

            return (url, pageIndex)
        }

        @objc private func handleAttachmentSelection(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }

            if let attachment = topmostEditableAttachment(at: recognizer.location(in: self)) {
                beginEditingAttachment(attachment)
            } else {
                clearAttachmentSelection()
            }

            // PencilKit owns a private edit menu on its tiled drawing view. Consuming
            // the blank tap prevents it from opening; dismissing once more on the next
            // run-loop turn closes the race on OS versions that present asynchronously.
            dismissNativeCanvasEditMenus()
            DispatchQueue.main.async { [weak self] in
                self?.dismissNativeCanvasEditMenus()
            }
        }

        func dismissNativeCanvasEditMenus() {
            dismissEditMenus(in: canvasView)
        }

        func suppressNativeCanvasEditMenus() {
            nativeEditMenuSuppressionGeneration &+= 1
            let generation = nativeEditMenuSuppressionGeneration
            let delays: [TimeInterval] = [0, 0.1, 0.35, 0.75, 1.5, 2.25]

            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.nativeEditMenuSuppressionGeneration == generation else {
                        return
                    }
                    self.dismissNativeCanvasEditMenus()
                }
            }
        }

        private func dismissEditMenus(in view: UIView) {
            for interaction in view.interactions {
                (interaction as? UIEditMenuInteraction)?.dismissMenu()
            }

            for subview in view.subviews {
                dismissEditMenus(in: subview)
            }
        }

        func beginEditingAttachment(id: UUID) {
            guard let attachment = page?.visualAttachments.first(where: { $0.id == id && !$0.isLocked }) else {
                clearAttachmentSelection()
                return
            }

            beginEditingAttachment(attachment)
        }

        func editableAttachment(at point: CGPoint) -> Attachment? {
            topmostEditableAttachment(at: point)
        }

        private func beginEditingAttachment(_ attachment: Attachment) {
            guard !attachment.isLocked, let page else {
                clearAttachmentSelection()
                return
            }

            if let selectedAttachmentID,
               selectedAttachmentID != attachment.id {
                guard finishInlineCodeSnippetEditing(
                    attachmentID: selectedAttachmentID
                ) else {
                    return
                }
            }
            selectedAttachmentID = attachment.id
            let overlay = attachmentEditingOverlay ?? {
                let overlay = AttachmentEditingOverlayView()
                attachmentEditingOverlay = overlay
                addSubview(overlay)
                return overlay
            }()
            let attachmentID = attachment.id
            overlay.configure(
                attachment: attachment,
                pageSize: page.pageSize,
                frameChanged: { [weak self] frame in
                    guard self?.selectedAttachmentID == attachmentID else { return }
                    self?.imageViews[attachmentID]?.frame = frame
                    self?.codeSnippetEditingController?.view.frame = frame
                },
                changeCommitted: { [weak self] in
                    self?.attachmentChanged?()
                },
                resizeCommitted: { [weak self, weak attachment] in
                    guard let self, let attachment else { return }
                    // Geometry is already committed at this point. Persist a stale
                    // marker before attempting PNG regeneration so a failed render
                    // cannot leave the old-size raster marked as current.
                    attachment.codeSnippetPreviewVersion = nil
                    attachment.touch()
                    self.attachmentChanged?()
                    self.codeSnippetPreviewNeedsRefresh = true
                    _ = self.persistInlineCodeSnippet(attachment, force: true)
                },
                deleteRequested: { [weak self] in
                    guard let self,
                          self.selectedAttachmentID == attachmentID else {
                        return
                    }

                    self.clearAttachmentSelection()
                    self.deleteAttachment?(attachment)
                },
                dismiss: { [weak self] in
                    self?.clearAttachmentSelection()
                },
                settingsMenu: attachment.isCodeSnippet
                    ? codeSnippetSettingsMenu(for: attachment)
                    : nil
            )
            if attachment.isCodeSnippet {
                beginInlineCodeSnippetEditing(attachment)
            }
            overlay.superview?.bringSubviewToFront(overlay)
        }

        private func beginInlineCodeSnippetEditing(_ attachment: Attachment) {
            guard attachment.isCodeSnippet,
                  saveCodeSnippet != nil else {
                editCodeSnippet?(attachment)
                return
            }

            if let editingState = codeSnippetEditingState,
               editingState.draft.id == attachment.id,
               let controller = codeSnippetEditingController {
                controller.view.frame = displayedFrame(for: attachment)
                // Keep appearance on the observable editing state. Updating only the
                // hosting controller's root view can leave its existing UITextView on
                // the previous palette until SwiftUI finishes replacing the hierarchy.
                editingState.updateAppearance(isDark: isDarkAppearance)
                let interfaceStyle: UIUserInterfaceStyle = isDarkAppearance ? .dark : .light
                codeSnippetPreviewNeedsRefresh = attachment.codeSnippetPreviewVersion
                    != CodeSnippetPreviewRenderer.previewVersion(
                        for: editingState.draft,
                        automaticInterfaceStyle: interfaceStyle
                    )
                let attachmentID = attachment.id
                controller.rootView = CodeSnippetCanvasEditor(
                    editingState: editingState,
                    onDraftChanged: { [weak self, weak attachment] _ in
                        guard let attachment, attachment.id == attachmentID else { return }
                        self?.scheduleInlineCodeSnippetSourceSave(for: attachment)
                    }
                )
                imageViews[attachment.id]?.isHidden = true
                return
            }

            let draft = CodeSnippetDraft(
                editing: attachment,
                defaults: CodeSnippetPreferences.defaultDraft()
            )
            let editingState = CodeSnippetCanvasEditingState(
                draft: draft,
                isDarkAppearance: isDarkAppearance
            )
            let attachmentID = attachment.id
            let controller = UIHostingController(
                rootView: CodeSnippetCanvasEditor(
                    editingState: editingState,
                    onDraftChanged: { [weak self, weak attachment] _ in
                        guard let attachment, attachment.id == attachmentID else { return }
                        self?.scheduleInlineCodeSnippetSourceSave(for: attachment)
                    }
                )
            )
            controller.view.backgroundColor = .clear
            controller.view.frame = displayedFrame(for: attachment)
            controller.view.accessibilityIdentifier = "codeSnippet.inlineEditor"
            imageViews[attachmentID]?.isHidden = true
            if let overlay = attachmentEditingOverlay,
               overlay.superview === self {
                insertSubview(controller.view, belowSubview: overlay)
            } else {
                addSubview(controller.view)
            }
            codeSnippetEditingState = editingState
            codeSnippetLastSavedDraft = draft
            codeSnippetLastSourceSavedDraft = draft
            let interfaceStyle: UIUserInterfaceStyle = isDarkAppearance ? .dark : .light
            codeSnippetPreviewNeedsRefresh = attachment.codeSnippetPreviewVersion
                != CodeSnippetPreviewRenderer.previewVersion(
                    for: draft,
                    automaticInterfaceStyle: interfaceStyle
                )
            codeSnippetEditingController = controller
        }

        @discardableResult
        private func finishInlineCodeSnippetEditing(
            attachmentID: UUID,
            persistsChanges: Bool = true
        ) -> Bool {
            if persistsChanges {
                commitInlineCodeSnippetTextInput()
            }
            codeSnippetSaveWorkItem?.cancel()
            codeSnippetSaveWorkItem = nil
            if persistsChanges,
               codeSnippetEditingState?.draft.id == attachmentID,
               let attachment = page?.visualAttachments.first(where: {
                   $0.id == attachmentID && $0.isCodeSnippet
               }) {
                guard persistInlineCodeSnippet(attachment) else {
                    _ = persistInlineCodeSnippetSource(attachment)
                    return false
                }
            }
            codeSnippetEditingController?.view.removeFromSuperview()
            codeSnippetEditingController = nil
            codeSnippetEditingState = nil
            codeSnippetLastSavedDraft = nil
            codeSnippetLastSourceSavedDraft = nil
            codeSnippetPreviewNeedsRefresh = false
            imageViews[attachmentID]?.isHidden = false
            if selectedAttachmentID == attachmentID {
                selectedAttachmentID = nil
            }
            return true
        }

        private func scheduleInlineCodeSnippetSourceSave(for attachment: Attachment) {
            codeSnippetSaveWorkItem?.cancel()
            let attachmentID = attachment.id
            let workItem = DispatchWorkItem { [weak self, weak attachment] in
                guard let self,
                      let attachment,
                      self.selectedAttachmentID == attachmentID else {
                    return
                }
                self.codeSnippetSaveWorkItem = nil
                _ = self.persistInlineCodeSnippetSource(attachment)
            }
            codeSnippetSaveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
        }

        @discardableResult
        private func persistInlineCodeSnippetSource(_ attachment: Attachment) -> Bool {
            guard attachment.isCodeSnippet,
                  let editingState = codeSnippetEditingState,
                  editingState.draft.id == attachment.id else {
                return false
            }

            let draft = editingState.draft
            guard draft != codeSnippetLastSourceSavedDraft else { return true }
            guard let saveCodeSnippetSource else {
                // Full persistence still runs on deselection, explicit save, export,
                // and lifecycle release when a lightweight source saver is unavailable.
                return true
            }

            let previousSavedDraft = codeSnippetLastSourceSavedDraft
            codeSnippetLastSourceSavedDraft = draft
            guard saveCodeSnippetSource(draft, attachment) else {
                codeSnippetLastSourceSavedDraft = previousSavedDraft
                return false
            }
            return true
        }

        @discardableResult
        func flushInlineCodeSnippetEdits() -> Bool {
            commitInlineCodeSnippetTextInput()
            codeSnippetSaveWorkItem?.cancel()
            codeSnippetSaveWorkItem = nil
            guard let editingState = codeSnippetEditingState else { return true }
            guard let attachment = page?.visualAttachments.first(where: {
                $0.id == editingState.draft.id && $0.isCodeSnippet
            }) else {
                return finishInlineCodeSnippetEditing(
                    attachmentID: editingState.draft.id,
                    persistsChanges: false
                )
            }
            guard persistInlineCodeSnippet(attachment) else {
                // A preview/render failure should not also lose the editable source.
                // Keep the page mounted, and opportunistically persist the cheaper
                // source payload for lifecycle recovery.
                _ = persistInlineCodeSnippetSource(attachment)
                return false
            }
            return true
        }

        /// Commit marked IME text before a deselect/export/lifecycle save. The live
        /// UITextView deliberately does not publish while composition is active, so
        /// reading only the SwiftUI binding here could otherwise omit the last word.
        private func commitInlineCodeSnippetTextInput() {
            guard let controller = codeSnippetEditingController,
                  let editingState = codeSnippetEditingState,
                  let textView = firstTextView(in: controller.view) else {
                return
            }

            let markedEditContext = codeSnippetMarkedTextRange(in: textView).flatMap {
                codeSnippetMarkedEditContext(
                    currentText: textView.text ?? "",
                    stableText: editingState.draft.code,
                    markedRange: $0
                )
            }
            textView.unmarkText()
            let boundedEdit: CodeSnippetBoundedEdit
            if let markedEditContext {
                boundedEdit = codeSnippetBoundedMarkedEdit(
                    currentText: textView.text ?? "",
                    context: markedEditContext,
                    selectedRange: textView.selectedRange,
                    maximumUTF16Length: CodeSyntaxHighlighter.maximumHighlightedUTF16Length
                )
            } else {
                boundedEdit = codeSnippetBoundedEdit(
                    currentText: textView.text ?? "",
                    stableText: editingState.draft.code,
                    selectedRange: textView.selectedRange,
                    maximumUTF16Length: CodeSyntaxHighlighter.maximumHighlightedUTF16Length
                )
            }
            if textView.text != boundedEdit.text {
                textView.text = boundedEdit.text
            }
            textView.selectedRange = boundedEdit.selectedRange
            if editingState.draft.code != boundedEdit.text {
                editingState.draft.code = boundedEdit.text
            }
            textView.resignFirstResponder()
        }

        private func firstTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView {
                return textView
            }
            for subview in view.subviews {
                if let textView = firstTextView(in: subview) {
                    return textView
                }
            }
            return nil
        }

#if DEBUG
        @discardableResult
        func replaceInlineCodeSnippetDraftForTesting(_ draft: CodeSnippetDraft) -> Bool {
            guard let editingState = codeSnippetEditingState,
                  editingState.draft.id == draft.id else {
                return false
            }
            editingState.draft = draft
            if let attachment = page?.visualAttachments.first(where: { $0.id == draft.id }) {
                scheduleInlineCodeSnippetSourceSave(for: attachment)
            }
            return true
        }
#endif

        @discardableResult
        private func persistInlineCodeSnippet(
            _ attachment: Attachment,
            force: Bool = false
        ) -> Bool {
            guard attachment.isCodeSnippet,
                  let editingState = codeSnippetEditingState,
                  editingState.draft.id == attachment.id,
                  let saveCodeSnippet else {
                return false
            }

            let draft = editingState.draft
            guard force
                    || codeSnippetPreviewNeedsRefresh
                    || draft != codeSnippetLastSavedDraft else {
                return true
            }
            let previousSavedDraft = codeSnippetLastSavedDraft
            codeSnippetLastSavedDraft = draft
            guard saveCodeSnippet(draft, attachment) else {
                codeSnippetLastSavedDraft = previousSavedDraft
                return false
            }
            codeSnippetLastSourceSavedDraft = draft
            codeSnippetPreviewNeedsRefresh = false
            discardPendingCodeSnippetPreviewRefresh(id: attachment.id)
            attachmentEditingOverlay?.updateSettingsMenu(
                codeSnippetSettingsMenu(for: attachment)
            )
            return true
        }

        private func updateSelectedCodeSnippet(
            _ attachment: Attachment,
            mutation: (inout CodeSnippetDraft) -> Void
        ) {
            guard attachment.id == selectedAttachmentID,
                  let editingState = codeSnippetEditingState,
                  editingState.draft.id == attachment.id else {
                return
            }

            var draft = editingState.draft
            mutation(&draft)
            guard draft != editingState.draft else { return }
            editingState.draft = draft
            attachmentEditingOverlay?.updateSettingsMenu(
                codeSnippetSettingsMenu(for: attachment)
            )
            scheduleInlineCodeSnippetSourceSave(for: attachment)
        }

        private func codeSnippetSettingsMenu(for attachment: Attachment) -> UIMenu {
            let fallbackDraft = CodeSnippetDraft(
                editing: attachment,
                defaults: CodeSnippetPreferences.defaultDraft()
            )
            let draft = codeSnippetEditingState?.draft.id == attachment.id
                ? codeSnippetEditingState?.draft ?? fallbackDraft
                : fallbackDraft

            let languageActions = CodeSnippetLanguage.allCases.map { language in
                UIAction(
                    title: language.label,
                    state: draft.language == language ? .on : .off
                ) { [weak self, weak attachment] _ in
                    guard let self, let attachment else { return }
                    self.updateSelectedCodeSnippet(attachment) {
                        $0.language = language
                    }
                }
            }
            let languageMenu = UIMenu(
                title: "Language",
                image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
                children: languageActions
            )

            let fontActions = CodeSnippetFontChoice.allCases.map { font in
                UIAction(
                    title: font.label,
                    state: draft.font == font ? .on : .off
                ) { [weak self, weak attachment] _ in
                    guard let self, let attachment else { return }
                    self.updateSelectedCodeSnippet(attachment) {
                        $0.font = font
                    }
                }
            }
            let fontMenu = UIMenu(
                title: "Font",
                image: UIImage(systemName: "textformat"),
                children: fontActions
            )

            let fontSizeActions = (Int(CodeSnippetPreferences.supportedFontSize.lowerBound)...Int(CodeSnippetPreferences.supportedFontSize.upperBound)).map { size in
                UIAction(
                    title: "\(size) pt",
                    state: Int(draft.fontSize.rounded()) == size ? .on : .off
                ) { [weak self, weak attachment] _ in
                    guard let self, let attachment else { return }
                    self.updateSelectedCodeSnippet(attachment) {
                        $0.fontSize = Double(size)
                    }
                }
            }
            let fontSizeMenu = UIMenu(
                title: "Font Size",
                image: UIImage(systemName: "textformat.size"),
                children: fontSizeActions
            )

            let appearanceActions = CodeSnippetBackgroundStyle.allCases.map { style in
                UIAction(
                    title: style.label,
                    state: draft.backgroundStyle == style ? .on : .off
                ) { [weak self, weak attachment] _ in
                    guard let self, let attachment else { return }
                    self.updateSelectedCodeSnippet(attachment) {
                        $0.backgroundStyle = style
                    }
                }
            }
            let appearanceMenu = UIMenu(
                title: "Box Appearance",
                image: UIImage(systemName: "circle.lefthalf.filled"),
                children: appearanceActions
            )

            let syntaxThemeActions = CodeSnippetSyntaxTheme.allCases.map { theme in
                UIAction(
                    title: theme.label,
                    state: draft.syntaxTheme == theme ? .on : .off
                ) { [weak self, weak attachment] _ in
                    guard let self, let attachment else { return }
                    self.updateSelectedCodeSnippet(attachment) {
                        $0.syntaxTheme = theme
                    }
                }
            }
            let syntaxThemeMenu = UIMenu(
                title: "Syntax Theme",
                image: UIImage(systemName: "paintpalette"),
                children: syntaxThemeActions
            )

            let remove = UIAction(
                title: "Remove Code Snippet",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self, weak attachment] _ in
                guard let self,
                      let attachment,
                      self.selectedAttachmentID == attachment.id else {
                    return
                }
                // Keep the live draft mounted until the parent confirmation resolves.
                // Cancelling deletion must return to the same pending text and settings.
                self.deleteAttachment?(attachment)
            }

            return UIMenu(children: [
                languageMenu,
                fontMenu,
                fontSizeMenu,
                appearanceMenu,
                syntaxThemeMenu,
                remove
            ])
        }

        private func displayedFrame(for attachment: Attachment) -> CGRect {
            if selectedAttachmentID == attachment.id,
               let attachmentEditingOverlay {
                return attachmentEditingOverlay.displayedFrame
            }
            return attachment.normalizedFrame(for: page?.pageSize)
        }

        @discardableResult
        func clearAttachmentSelection() -> Bool {
            if let selectedAttachmentID {
                guard finishInlineCodeSnippetEditing(
                    attachmentID: selectedAttachmentID
                ) else {
                    return false
                }
            }
            selectedAttachmentID = nil
            attachmentEditingOverlay?.removeFromSuperview()
            attachmentEditingOverlay = nil
            attachmentEditingHostView?.removeFromSuperview()
            attachmentEditingHostView = nil
            return true
        }

        private func topmostEditableAttachment(at point: CGPoint) -> Attachment? {
            guard let page else { return nil }
            let attachments = page.visualAttachments.filter { !$0.isLocked }
            let foreground = attachments.filter {
                !$0.isCodeSnippet && !$0.rendersBehindDrawing
            }.reversed()
            let background = attachments.filter {
                $0.isCodeSnippet || $0.rendersBehindDrawing
            }.reversed()

            return (Array(foreground) + Array(background)).first(where: {
                $0.normalizedFrame(for: page.pageSize).contains(point)
            })
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer === eraserScopeGesture {
                return true
            }

            if let attachmentEditingOverlay,
               touch.view?.isDescendant(of: attachmentEditingOverlay) == true {
                return false
            }

            if let editorView = codeSnippetEditingController?.view,
               touch.view?.isDescendant(of: editorView) == true {
                return false
            }

            if gestureRecognizer === pageActionLongPressGesture {
                return pageIDForPageAction?(touch.location(in: self)) != nil
                    && allowsPageActionLongPress
                    && topmostEditableAttachment(at: touch.location(in: self)) == nil
            }

            return selectedAttachmentID != nil
                || topmostEditableAttachment(at: touch.location(in: self)) != nil
                || consumesBlankCanvasTaps
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === attachmentSelectionGesture,
                  let tapGesture = otherGestureRecognizer as? UITapGestureRecognizer else {
                return false
            }

            // Attachment selection is a single tap, while the editor owns a
            // single-finger double tap for detail zoom. Give the double tap priority
            // so selection cannot recognize after the first touch and cancel zoom.
            return tapGesture.numberOfTouchesRequired == 1
                && tapGesture.numberOfTapsRequired > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === eraserScopeGesture
                || otherGestureRecognizer === eraserScopeGesture
        }

        func handleEraserInteraction(
            _ interaction: EraserScopeGestureRecognizer.Interaction
        ) {
            switch interaction {
            case .began(let location):
                beginObjectEraser(at: location)
                updateEraserScope(at: location)
            case .moved(let location):
                appendObjectEraserLocation(location)
                updateEraserScope(at: location)
            case .movedBatch(let locations):
                appendObjectEraserLocations(locations)
                updateEraserScope(at: locations.last)
            case .ended(let location):
                appendObjectEraserLocations([location], forcesEvaluation: true)
                finishObjectEraser(committing: true)
                updateEraserScope(at: nil)
            case .endedBatch(let locations):
                appendObjectEraserLocations(locations, forcesEvaluation: true)
                finishObjectEraser(committing: true)
                updateEraserScope(at: nil)
            case .cancelled:
                finishObjectEraser(committing: false)
                updateEraserScope(at: nil)
            }
        }

        func updateEraserScope(at location: CGPoint?) {
            guard isUsingDrawingTool,
                  let location,
                  let eraserTool = canvasView.tool as? PKEraserTool else {
                eraserScopeView.hide()
                return
            }

            if let rubEraserConfiguration {
                eraserScopeView.showRub(at: location, configuration: rubEraserConfiguration)
                bringSubviewToFront(eraserScopeView)
                return
            }

            let diameter = eraserPreviewDiameter
                ?? (eraserTool.width > 0 ? eraserTool.width : EraserScopeView.objectEraserDiameter)
            eraserScopeView.show(at: location, diameter: diameter)
            bringSubviewToFront(eraserScopeView)
        }

        func setEraserPreviewEnabled(
            _ enabled: Bool,
            diameter: CGFloat? = nil,
            usesCustomObjectEraser: Bool = false,
            rubEraserConfiguration: RubEraserConfiguration? = nil
        ) {
            let previewDiameterChanged = eraserPreviewDiameter != diameter
            eraserPreviewDiameter = diameter
            let shouldUseCustomObjectEraser = enabled && usesCustomObjectEraser
            let nextRubConfiguration = enabled && rubEraserConfiguration?.isValid == true
                ? rubEraserConfiguration
                : nil
            let customConfigurationChanged = self.usesCustomObjectEraser != shouldUseCustomObjectEraser
                || self.rubEraserConfiguration != nextRubConfiguration
            if customConfigurationChanged {
                if isTrackingObjectEraser {
                    finishObjectEraser(committing: false)
                }
                self.usesCustomObjectEraser = shouldUseCustomObjectEraser
                self.rubEraserConfiguration = nextRubConfiguration
            }

            canvasView.drawingGestureRecognizer.isEnabled = !usesCustomEraserInput
            if eraserScopeGesture.isEnabled != enabled {
                eraserScopeGesture.isEnabled = enabled
            }
            if !enabled {
                eraserScopeView.hide()
            } else if (previewDiameterChanged || customConfigurationChanged),
                      !eraserScopeView.isHidden {
                updateEraserScope(
                    at: eraserScopeGesture.currentLocation ?? eraserScopeView.center
                )
            }
        }

        private func updateDrawingInteractionRecognizers() {
            let allowsCustomInput = !isCaptureInteractionEnabled && !isDrawingLoadBlocked
            eraserScopeGesture.isEnabled = allowsCustomInput && eraserPreviewDiameter != nil
            pageActionLongPressGesture?.isEnabled = allowsPageActionLongPress
            canvasView.drawingGestureRecognizer.isEnabled = allowsCustomInput && !usesCustomEraserInput
        }
        private func beginObjectEraser(at location: CGPoint) {
            guard usesCustomEraserInput,
                  location.x.isFinite,
                  location.y.isFinite,
                  !isTrackingObjectEraser else {
                return
            }

            isTrackingObjectEraser = true
            objectEraserPendingFlushWorkItem?.cancel()
            objectEraserPendingFlushWorkItem = nil
            objectEraserPath.begin(at: location)
            objectEraserPendingPath = [location]
            objectEraserPendingTravelDistance = 0
            objectEraserInitialDrawing = canvasView.drawing
            objectEraserRemovedStrokeIndexes.removeAll()
            if usesCustomObjectEraser,
               rubEraserConfiguration == nil,
               let diameter = eraserPreviewDiameter,
               diameter.isFinite,
               diameter > 0 {
                let candidateBounds = activeDrawingViewportRect.isNull
                    || activeDrawingViewportRect.isEmpty
                    ? nil
                    : activeDrawingViewportRect.insetBy(dx: -diameter, dy: -diameter)
                objectEraserHitTestSession = ObjectEraserHitTester.Session(
                    strokes: canvasView.drawing.strokes,
                    diameter: diameter,
                    candidateBounds: candidateBounds
                )
            } else {
                objectEraserHitTestSession = nil
            }
            objectEraserHasChanges = false
            objectEraserLiveEvaluationCount = 0
            canvasView.becomeFirstResponder()
            objectEraserDidBegin?()
            eraseObjectsLive(along: [location])
        }

        private func appendObjectEraserLocation(_ location: CGPoint) {
            appendObjectEraserLocations([location])
        }

        private func appendObjectEraserLocations(
            _ locations: [CGPoint],
            forcesEvaluation: Bool = false
        ) {
            guard isTrackingObjectEraser,
                  let previousLocation = objectEraserPath.points.last else { return }

            if objectEraserPendingPath.isEmpty {
                objectEraserPendingPath = [previousLocation]
            }
            for location in locations {
                guard location.x.isFinite, location.y.isFinite else { continue }
                guard let lastLocation = objectEraserPath.points.last else { continue }
                let previousPointCount = objectEraserPath.points.count
                objectEraserPath.append(
                    location,
                    minimumSpacing: 0
                )
                guard objectEraserPath.points.count > previousPointCount,
                      let currentLocation = objectEraserPath.points.last else {
                    continue
                }
                objectEraserPendingTravelDistance += hypot(
                    currentLocation.x - lastLocation.x,
                    currentLocation.y - lastLocation.y
                )
                objectEraserPendingPath.append(currentLocation)
            }

            // Whole-stroke deletion rebuilds PencilKit's immutable drawing. Cap that
            // work at one batch per display interval so coalesced Pencil samples can
            // remove several touched strokes with one aggregate replacement.
            if forcesEvaluation || !usesCustomObjectEraser || rubEraserConfiguration != nil {
                flushPendingObjectEraserPath(forcesEvaluation: forcesEvaluation)
            }
            schedulePendingObjectEraserFlushIfNeeded()
        }

        private func schedulePendingObjectEraserFlushIfNeeded() {
            guard usesCustomObjectEraser,
                  rubEraserConfiguration == nil,
                  objectEraserPendingPath.count > 1,
                  objectEraserPendingFlushWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.objectEraserPendingFlushWorkItem = nil
                guard self.isTrackingObjectEraser else { return }
                // A small move can make the displayed circle touch a stroke before
                // the distance batch fills. Resolve it on the next main-loop turn so
                // boundary contact never waits for pencil/finger lift.
                self.flushPendingObjectEraserPath(forcesEvaluation: true)
            }
            objectEraserPendingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (1.0 / 60.0),
                execute: workItem
            )
        }

        private func flushPendingObjectEraserPath(forcesEvaluation: Bool) {
            guard objectEraserPendingPath.count > 1,
                  let lastLocation = objectEraserPendingPath.last else { return }

            let requestedDiameter = eraserPreviewDiameter
                ?? EraserScopeView.objectEraserDiameter
            let diameter = requestedDiameter.isFinite && requestedDiameter > 0
                ? requestedDiameter
                : EraserScopeView.objectEraserDiameter
            let evaluatesWholeObjects = usesCustomObjectEraser
                && rubEraserConfiguration == nil
            let evaluationDistance = evaluatesWholeObjects
                ? max(diameter / 4, 1)
                : 0
            guard forcesEvaluation
                    || objectEraserPendingTravelDistance >= evaluationDistance else { return }

            objectEraserPendingFlushWorkItem?.cancel()
            objectEraserPendingFlushWorkItem = nil

            // Buffer exact points across UIKit events and evaluate by travelled distance.
            // This keeps small returning loops while avoiding a full drawing scan for
            // every slow, single-sample event.
            let livePath = objectEraserPendingPath
            objectEraserPendingPath = [lastLocation]
            objectEraserPendingTravelDistance = 0
            objectEraserPath.begin(at: lastLocation)
            eraseObjectsLive(along: livePath)
        }

        private func finishObjectEraser(committing: Bool) {
            guard isTrackingObjectEraser else { return }
            defer {
                objectEraserPendingFlushWorkItem?.cancel()
                objectEraserPendingFlushWorkItem = nil
                isTrackingObjectEraser = false
                objectEraserPath.reset()
                objectEraserPendingPath.removeAll(keepingCapacity: false)
                objectEraserPendingTravelDistance = 0
                objectEraserInitialDrawing = nil
                objectEraserHitTestSession = nil
                objectEraserRemovedStrokeIndexes.removeAll()
                objectEraserHasChanges = false
                objectEraserDidEnd?()
            }

            guard objectEraserHasChanges,
                  let initialDrawing = objectEraserInitialDrawing else { return }

            if committing {
                registerObjectEraserUndo(
                    undoDrawing: initialDrawing,
                    redoDrawing: canvasView.drawing
                )
            } else {
                canvasView.drawing = initialDrawing
                notifyObjectEraserDrawingChanged()
            }
        }

        @discardableResult
        func eraseObjects(along eraserPath: [CGPoint], diameter: CGFloat) -> Bool {
            guard diameter.isFinite,
                  diameter > 0 else {
                return false
            }

            let before = canvasView.drawing
            guard let after = drawingByErasingObjects(
                along: eraserPath,
                diameter: diameter,
                from: before
            ) else { return false }

            replaceObjectEraserDrawing(after, undoDrawing: before)
            return true
        }

        private func eraseObjectsLive(along eraserPath: [CGPoint]) {
            objectEraserLiveEvaluationCount += 1
            let drawing: PKDrawing?
            if let rubEraserConfiguration {
                drawing = drawingByRubbingInk(
                    along: eraserPath,
                    configuration: rubEraserConfiguration,
                    from: canvasView.drawing
                )
            } else if usesCustomObjectEraser,
                      var hitTestSession = objectEraserHitTestSession,
                      let initialDrawing = objectEraserInitialDrawing {
                let newlyRemovedIndexes = hitTestSession.intersectedStrokeIndexes(
                    eraserPath: eraserPath,
                    excluding: objectEraserRemovedStrokeIndexes
                )
                objectEraserHitTestSession = hitTestSession
                if newlyRemovedIndexes.isEmpty {
                    drawing = nil
                } else {
                    objectEraserRemovedStrokeIndexes.formUnion(newlyRemovedIndexes)
                    drawing = PKDrawing(
                        strokes: initialDrawing.strokes.enumerated().compactMap { index, stroke in
                            objectEraserRemovedStrokeIndexes.contains(index) ? nil : stroke
                        }
                    )
                }
            } else {
                drawing = nil
            }
            guard let drawing else { return }

            canvasView.drawing = drawing
            let isFirstLiveChange = !objectEraserHasChanges
            objectEraserHasChanges = true
            if isFirstLiveChange {
                // One dirty notification is enough: the coordinator defers persistence
                // until tool end and snapshots the canvas's latest drawing then.
                notifyObjectEraserDrawingChanged()
            }
        }

        private func drawingByErasingObjects(
            along eraserPath: [CGPoint],
            diameter: CGFloat,
            from drawing: PKDrawing
        ) -> PKDrawing? {
            let intersected = ObjectEraserHitTester.intersectedStrokeIndexes(
                in: drawing.strokes,
                eraserPath: eraserPath,
                diameter: diameter
            )
            guard !intersected.isEmpty else { return nil }

            return PKDrawing(
                strokes: drawing.strokes.enumerated().compactMap { index, stroke in
                    intersected.contains(index) ? nil : stroke
                }
            )
        }

        private func drawingByRubbingInk(
            along eraserPath: [CGPoint],
            configuration: RubEraserConfiguration,
            from drawing: PKDrawing
        ) -> PKDrawing? {
            guard let strokes = PartialEraserStrokeProcessor.strokesByErasing(
                drawing.strokes,
                along: eraserPath,
                configuration: configuration
            ) else { return nil }
            return PKDrawing(strokes: strokes)
        }

        private func replaceObjectEraserDrawing(_ drawing: PKDrawing, undoDrawing: PKDrawing) {
            registerObjectEraserUndo(undoDrawing: undoDrawing, redoDrawing: drawing)
            canvasView.drawing = drawing
            notifyObjectEraserDrawingChanged()
        }

        private func notifyObjectEraserDrawingChanged() {
            let undoManager = canvasView.undoManager
            guard undoManager?.isUndoing == true || undoManager?.isRedoing == true else {
                objectEraserDrawingChanged?()
                return
            }

            // Undo registration is still active while NSUndoManager executes its block. Defer
            // autosave bookkeeping until that transaction has fully unwound, otherwise a
            // SwiftUI update can re-enter the coordinator from inside the undo operation.
            DispatchQueue.main.async { [weak self] in
                self?.objectEraserDrawingChanged?()
            }
        }

        private func registerObjectEraserUndo(undoDrawing: PKDrawing, redoDrawing: PKDrawing) {
            canvasView.undoManager?.registerUndo(withTarget: self) { pageView in
                pageView.replaceObjectEraserDrawing(undoDrawing, undoDrawing: redoDrawing)
            }
            canvasView.undoManager?.setActionName("Erase")
        }

        private func restoreDrawingLayerOrder() {
            sendSubviewToBack(backgroundView)
            insertSubview(behindImageContainerView, aboveSubview: backgroundView)
            insertSubview(drawingViewportView, aboveSubview: behindImageContainerView)
            if foregroundImageContainerView.superview === self {
                insertSubview(foregroundImageContainerView, aboveSubview: drawingViewportView)
            }

            if let editorView = codeSnippetEditingController?.view,
               editorView.superview === self {
                bringSubviewToFront(editorView)
            }
            if let attachmentEditingOverlay, attachmentEditingOverlay.superview === self {
                bringSubviewToFront(attachmentEditingOverlay)
            }
            bringSubviewToFront(eraserScopeView)
        }

        @discardableResult
        func releaseHeavyResources(evictCachedImages: Bool = false) -> Bool {
            guard clearAttachmentSelection() else { return false }
            cancelPendingCodeSnippetPreviewRefreshes()
            restoreForegroundImagesToPage()
            pendingNativeViewport = nil
            drawingViewportView.isHidden = true
            eraserScopeView.hide()
            canvasView.delegate = nil
            canvasView.drawing = PKDrawing()

            for view in imageViews.values {
                view.releaseImage(evictCachedVariants: evictCachedImages)
                view.removeFromSuperview()
            }

            imageViews.removeAll()
            hasConfiguredImageAttachments = false
            return true
        }
    }

    final class AttachmentEditingHostView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }

            for subview in subviews.reversed() {
                let subviewPoint = subview.convert(point, from: self)
                if let hitView = subview.hitTest(subviewPoint, with: event) {
                    return hitView
                }
            }

            // The host spans a whole page but only the image editing controls should
            // intercept touches. Everything else continues to the PencilKit canvas.
            return nil
        }
    }

    final class PageBackgroundUIView: UIView {
        var background: NoteBackground = .plain()
        var theme: BeanNotesTheme = .defaultTheme
        var showsBeanArtwork = false
        var pageID: UUID?
        var patternOrigin: CGPoint? {
            didSet {
                guard patternOrigin != oldValue else { return }
                patternedContentView?.patternOrigin = patternOrigin
                patternedContentView?.setNeedsDisplay()
            }
        }
        var isCoveredByOpaquePDF = false
        private(set) var usesSolidColorRendering = false
        private var patternedContentView: PatternedPageBackgroundView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.contentsScale = UIScreen.main.scale
            layer.rasterizationScale = UIScreen.main.scale
            layer.shouldRasterize = false
            // This view is redrawn when theme artwork is toggled. Drawing it on the
            // main thread keeps the new background state in lockstep with the live
            // PencilKit canvas above it; asynchronous layer drawing can otherwise
            // present a cleared or stale backing store during the transition.
            layer.drawsAsynchronously = false
            refreshRenderingMode()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.contentsScale = UIScreen.main.scale
            layer.rasterizationScale = UIScreen.main.scale
            layer.shouldRasterize = false
            // See init(frame:): artwork visibility changes must repaint this opaque
            // background deterministically without affecting the drawing layer.
            layer.drawsAsynchronously = false
            refreshRenderingMode()
        }

        func updateRenderScale(_ scale: CGFloat) {
            guard abs(contentScaleFactor - scale) > 0.05 else { return }
            contentScaleFactor = scale
            layer.contentsScale = scale
            layer.rasterizationScale = scale
            if let patternedContentView {
                patternedContentView.updateRenderScale(scale)
            }
        }

        func refreshRenderingMode() {
            let hasThemeArtwork = showsBeanArtwork && theme != .standard
            let shouldUseSolidColor = isCoveredByOpaquePDF
                || (background.style == .plain && !hasThemeArtwork)
            layer.backgroundColor = UIColor(hex: background.renderedColorHex).cgColor
            usesSolidColorRendering = shouldUseSolidColor
            contentMode = shouldUseSolidColor ? .scaleToFill : .redraw
            layer.contents = nil

            if shouldUseSolidColor {
                // PageBackgroundUIView itself has no draw(_:) implementation, so this
                // path remains a layer-only color surface. Removing the draw-backed
                // child also releases any pattern bitmap allocated before a PDF became
                // full-page coverage.
                patternedContentView?.layer.contents = nil
                patternedContentView?.removeFromSuperview()
                patternedContentView = nil
            } else {
                let patternedContentView = patternedContentView ?? makePatternedContentView()
                patternedContentView.configure(
                    background: background,
                    theme: theme,
                    showsBeanArtwork: showsBeanArtwork,
                    pageID: pageID,
                    patternOrigin: patternOrigin
                )
                patternedContentView.frame = bounds
                patternedContentView.setNeedsDisplay()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            patternedContentView?.frame = bounds
        }

        private func makePatternedContentView() -> PatternedPageBackgroundView {
            let view = PatternedPageBackgroundView(frame: bounds)
            view.updateRenderScale(contentScaleFactor)
            addSubview(view)
            patternedContentView = view
            return view
        }

        private final class PatternedPageBackgroundView: UIView {
            private var background: NoteBackground = .plain()
            private var theme: BeanNotesTheme = .defaultTheme
            private var showsBeanArtwork = false
            private var pageID: UUID?
            var patternOrigin: CGPoint?

            override init(frame: CGRect) {
                super.init(frame: frame)
                isOpaque = true
                isUserInteractionEnabled = false
                contentMode = .redraw
                layer.shouldRasterize = false
                layer.drawsAsynchronously = false
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                isOpaque = true
                isUserInteractionEnabled = false
                contentMode = .redraw
                layer.shouldRasterize = false
                layer.drawsAsynchronously = false
            }

            func configure(
                background: NoteBackground,
                theme: BeanNotesTheme,
                showsBeanArtwork: Bool,
                pageID: UUID?,
                patternOrigin: CGPoint?
            ) {
                self.background = background
                self.theme = theme
                self.showsBeanArtwork = showsBeanArtwork
                self.pageID = pageID
                self.patternOrigin = patternOrigin
            }

            func updateRenderScale(_ scale: CGFloat) {
                contentScaleFactor = scale
                layer.contentsScale = scale
                layer.rasterizationScale = scale
                setNeedsDisplay()
            }

            override func draw(_ rect: CGRect) {
                guard let context = UIGraphicsGetCurrentContext() else { return }
                NoteBackgroundRenderer.draw(
                    background: background,
                    theme: theme,
                    showsBeanArtwork: showsBeanArtwork,
                    pageID: pageID,
                    patternOrigin: patternOrigin,
                    in: bounds,
                    context: context
                )
            }
        }
    }

    /// A single, non-interactive PDFKit surface for one imported PDF page.
    ///
    /// The enclosing editor owns all scrolling and zooming. PDFKit receives one fixed
    /// page-to-bounds scale and is never allowed to auto-fit again during an outer
    /// gesture, eliminating representation swaps and changing page ratios.
    final class NativePDFPageView: PDFView {
        private static let documentCache: NSCache<NSString, PDFDocument> = {
            let cache = NSCache<NSString, PDFDocument>()
            cache.countLimit = 6
            return cache
        }()
        private static let pageDocumentCache: NSCache<NSString, PDFDocument> = {
            let cache = NSCache<NSString, PDFDocument>()
            cache.countLimit = 24
            return cache
        }()

        private(set) var sourceIdentity: String?
        private(set) var sourceURL: URL?
        private(set) var sourcePageIndex: Int?
        private(set) var fixedScaleForTesting: CGFloat = 0
        private(set) var fittedBoundsSizeForTesting: CGSize = .zero
        private(set) var isInteractionRenderingDeferred = false
        var documentFrameInViewForTesting: CGRect? {
            guard let documentView else { return nil }
            return documentView.convert(documentView.bounds, to: self)
        }
        private var isUpdatingFixedScale = false
        private var requestedInteractionRasterScale: CGFloat = 1
        private var interactionRasterBoundsSize: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        static func removeAllCachedDocuments() {
            pageDocumentCache.removeAllObjects()
            documentCache.removeAllObjects()
        }

        @discardableResult
        func configure(url: URL, pageIndex: Int) -> Bool {
            guard pageIndex >= 0 else {
                releaseDocument()
                return false
            }

            let identity = Self.pdfSourceIdentity(url: url)
            if sourceIdentity == identity,
               sourcePageIndex == pageIndex,
               document?.page(at: 0) != nil {
                updateFixedScaleIfNeeded()
                return true
            }

            guard let document = Self.cachedPageDocument(
                url: url, identity: identity, pageIndex: pageIndex
            ), let page = document.page(at: 0) else {
                releaseDocument()
                return false
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.document = document
            go(to: page)
            sourceIdentity = identity
            sourceURL = url.standardizedFileURL
            sourcePageIndex = pageIndex
            fittedBoundsSizeForTesting = .zero
            updateFixedScaleIfNeeded(force: true)
            CATransaction.commit()
            return true
        }

        func releaseDocument() {
            setInteractionRenderingDeferred(false, rasterScale: 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            document = nil
            sourceIdentity = nil
            sourceURL = nil
            sourcePageIndex = nil
            fixedScaleForTesting = 0
            fittedBoundsSizeForTesting = .zero
            CATransaction.commit()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateFixedScaleIfNeeded()
            if isInteractionRenderingDeferred {
                setInteractionRenderingDeferred(true, rasterScale: requestedInteractionRasterScale)
            }
        }

        /// Cache the already-rendered PDF subtree only during outer navigation. The
        /// page remains visible, but PDFKit no longer competes to retile unchanged
        /// content on every scroll/zoom frame. Live drawing explicitly disables this
        /// cache so ink is always shown over PDFKit's stable vector surface.
        /// A bounded scale keeps the transient cache from multiplying memory at deep
        /// zoom levels; PDFKit resumes its sharp vector rendering after settlement.
        func setInteractionRenderingDeferred(_ deferred: Bool, rasterScale: CGFloat) {
            requestedInteractionRasterScale = rasterScale
            let boundedScale = Self.interactionRasterScale(for: bounds.size, requestedScale: rasterScale)
            guard isInteractionRenderingDeferred != deferred
                    || (deferred && (interactionRasterBoundsSize != bounds.size
                        || abs(layer.rasterizationScale - boundedScale) > 0.05)) else {
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.rasterizationScale = boundedScale
            layer.shouldRasterize = deferred
            CATransaction.commit()
            isInteractionRenderingDeferred = deferred
            interactionRasterBoundsSize = bounds.size
        }

        /// Scale alone does not bound memory: a large map at 2× can allocate hundreds
        /// of MB. Limit each temporary navigation surface to 4 MP (about 16 MB RGBA).
        static func interactionRasterScale(for size: CGSize, requestedScale: CGFloat) -> CGFloat {
            let requested = requestedScale.isFinite && requestedScale > 0
                ? requestedScale
                : UIScreen.main.scale
            let scale = min(max(requested, 1), 2)
            guard isValid(size) else { return scale }
            let pixelBudgetScale = sqrt(4_000_000 / size.width / size.height)
            let edgeBudgetScale = 4_096 / max(size.width, size.height)
            return min(scale, pixelBudgetScale, edgeBudgetScale)
        }

        private func configureView() {
            autoScales = false
            displayMode = .singlePage
            displayDirection = .vertical
            displayBox = .cropBox
            displaysPageBreaks = false
            pageShadowsEnabled = false
            backgroundColor = .white
            isOpaque = true
            isUserInteractionEnabled = false
            clipsToBounds = true
            usePageViewController(false)
        }

        private func updateFixedScaleIfNeeded(force: Bool = false) {
            guard !isUpdatingFixedScale,
                  bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width > 0,
                  bounds.height > 0,
                  let page = currentPage ?? document?.page(at: 0) else {
                return
            }
            guard force || fittedBoundsSizeForTesting != bounds.size else { return }

            let selectedDisplayBox = Self.preferredDisplayBox(
                for: page,
                targetSize: bounds.size
            )
            let pageSize = Self.displayedPageSize(for: page, box: selectedDisplayBox)
            guard pageSize.width > 0, pageSize.height > 0 else { return }
            let fixedScale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
            guard fixedScale.isFinite, fixedScale > 0 else { return }

            isUpdatingFixedScale = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayBox = selectedDisplayBox
            minScaleFactor = 0.01
            maxScaleFactor = 64
            scaleFactor = fixedScale
            minScaleFactor = fixedScale
            maxScaleFactor = fixedScale
            CATransaction.commit()
            fixedScaleForTesting = fixedScale
            fittedBoundsSizeForTesting = bounds.size
            isUpdatingFixedScale = false
        }

        /// New imports use CropBox geometry. Older notes can contain MediaBox-sized
        /// canvases, so choose the native page box whose aspect ratio matches the saved
        /// attachment rather than letterboxing or mutating its logical size.
        private static func preferredDisplayBox(
            for page: PDFPage,
            targetSize: CGSize
        ) -> PDFDisplayBox {
            let cropSize = displayedPageSize(for: page, box: .cropBox)
            let mediaSize = displayedPageSize(for: page, box: .mediaBox)
            guard isValid(cropSize) else { return .mediaBox }
            guard isValid(mediaSize), isValid(targetSize) else { return .cropBox }

            let targetAspect = targetSize.width / targetSize.height
            let cropDistance = abs(log(targetAspect / (cropSize.width / cropSize.height)))
            let mediaDistance = abs(log(targetAspect / (mediaSize.width / mediaSize.height)))
            return cropDistance <= mediaDistance ? .cropBox : .mediaBox
        }

        private static func displayedPageSize(
            for page: PDFPage,
            box: PDFDisplayBox
        ) -> CGSize {
            let boxSize = page.bounds(for: box).size
            let rotation = ((page.rotation % 360) + 360) % 360
            return rotation == 90 || rotation == 270
                ? CGSize(width: boxSize.height, height: boxSize.width)
                : boxSize
        }

        private static func isValid(_ size: CGSize) -> Bool {
            size.width.isFinite
                && size.height.isFinite
                && size.width > 0
                && size.height > 0
        }

        /// A page background has no document navigation. Giving PDFView a full PDF
        /// makes each mounted background participate in document-wide layout work.
        /// Copy the vector page into a bounded display document without moving it out
        /// of the source, flattening annotations, or changing CropBox/rotation metadata.
        private static func cachedPageDocument(
            url: URL,
            identity: String,
            pageIndex: Int
        ) -> PDFDocument? {
            let pageKey = "\(identity)|page=\(pageIndex)" as NSString
            if let cached = pageDocumentCache.object(forKey: pageKey) {
                return cached
            }
            guard let source = cachedDocument(url: url, identity: identity),
                  let page = source.page(at: pageIndex)?.copy() as? PDFPage else { return nil }
            let document = PDFDocument()
            document.insert(page, at: 0)
            pageDocumentCache.setObject(document, forKey: pageKey)
            return document
        }

        private static func cachedDocument(url: URL, identity: String) -> PDFDocument? {
            let key = identity as NSString
            if let cached = documentCache.object(forKey: key) {
                return cached
            }
            guard let document = PDFDocument(url: url.standardizedFileURL) else { return nil }
            documentCache.setObject(document, forKey: key)
            return document
        }

        private static func pdfSourceIdentity(url: URL) -> String {
            let identity = ImageMemoryCache.shared.fileIdentity(for: url)
            return "\(identity.standardizedPath)|\(identity.modifiedAt)|\(identity.byteCount)"
        }

    }

    final class AttachmentEditingOverlayView: UIView, UIGestureRecognizerDelegate {
        private let outerBorderView = UIView()
        private let innerBorderView = UIView()
        private let deleteButton = UIButton(type: .custom)
        private let settingsButton = UIButton(type: .custom)
        private let settingsVisualView = UIImageView()
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var dragStart: CGRect?
        private var activeResizeHandle: AttachmentResizeHandle?
        private var resizeStart: CGRect?
        private var previewFrame: CGRect?
        private var frameChanged: ((CGRect) -> Void)?
        private var changeCommitted: (() -> Void)?
        private var resizeCommitted: (() -> Void)?
        private var deleteRequested: (() -> Void)?
        private var dismiss: (() -> Void)?
        private(set) var editingPanGestureRecognizers: [UIPanGestureRecognizer] = []
        private let resizeHitWidth: CGFloat = 24

        var displayedFrame: CGRect {
            previewFrame ?? frame
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        func configure(
            attachment: Attachment,
            pageSize: CGSize,
            frameChanged: @escaping (CGRect) -> Void,
            changeCommitted: @escaping () -> Void,
            resizeCommitted: @escaping () -> Void = {},
            deleteRequested: @escaping () -> Void,
            dismiss: @escaping () -> Void,
            settingsMenu: UIMenu? = nil
        ) {
            self.attachment = attachment
            self.frameChanged = frameChanged
            self.changeCommitted = changeCommitted
            self.resizeCommitted = resizeCommitted
            self.deleteRequested = deleteRequested
            self.dismiss = dismiss
            if let previewFrame {
                self.pageSize = pageSize
                frame = previewFrame
                setNeedsLayout()
            } else {
                updateFrame(attachment.normalizedFrame(for: pageSize), pageSize: pageSize)
            }

            outerBorderView.accessibilityLabel = "Selected \(attachment.displayName)"
            outerBorderView.accessibilityValue = attachment.isCodeSnippet
                ? "Ready for Apple Pencil or keyboard input"
                : nil
            outerBorderView.accessibilityHint = attachment.isCodeSnippet
                ? "Drag the header to move, drag an edge or corner to resize, or choose Settings for code options"
                : "Drag the item to move it, or drag an edge or corner to resize it"
            var accessibilityActions = [
                UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in
                    self?.nudge(by: CGPoint(x: -8, y: 0)) ?? false
                },
                UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in
                    self?.nudge(by: CGPoint(x: 8, y: 0)) ?? false
                },
                UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in
                    self?.nudge(by: CGPoint(x: 0, y: -8)) ?? false
                },
                UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in
                    self?.nudge(by: CGPoint(x: 0, y: 8)) ?? false
                },
                UIAccessibilityCustomAction(name: "Increase size") { [weak self] _ in
                    self?.resize(by: CGPoint(x: 16, y: 16)) ?? false
                },
                UIAccessibilityCustomAction(name: "Decrease size") { [weak self] _ in
                    self?.resize(by: CGPoint(x: -16, y: -16)) ?? false
                }
            ]
            accessibilityActions.append(
                UIAccessibilityCustomAction(name: "Finish editing") { [weak self] _ in
                    guard let self else { return false }
                    self.dismiss?()
                    return true
                }
            )
            outerBorderView.accessibilityCustomActions = accessibilityActions
            let selectionColor = attachment.isCodeSnippet
                ? UIColor.systemGreen
                : UIColor.separator
            outerBorderView.layer.borderWidth = attachment.isCodeSnippet ? 2 : 0
            outerBorderView.layer.borderColor = selectionColor.cgColor
            outerBorderView.layer.cornerRadius = attachment.isCodeSnippet
                ? CodeSnippetLayout.cornerRadius
                : 0
            innerBorderView.layer.borderColor = selectionColor.withAlphaComponent(
                attachment.isCodeSnippet ? 0.72 : 0.9
            ).cgColor
            innerBorderView.layer.cornerRadius = attachment.isCodeSnippet
                ? max(CodeSnippetLayout.cornerRadius - 1, 0)
                : 0
            deleteButton.isHidden = attachment.isCodeSnippet
            settingsButton.isHidden = !attachment.isCodeSnippet
            settingsVisualView.isHidden = !attachment.isCodeSnippet
            settingsButton.menu = settingsMenu
            settingsButton.showsMenuAsPrimaryAction = attachment.isCodeSnippet
            deleteButton.accessibilityLabel = "Delete \(attachment.displayName)"
            deleteButton.accessibilityHint = attachment.isCodeSnippet
                ? "Removes the code snippet after confirmation"
                : "Removes the image after confirmation"
            settingsButton.accessibilityLabel = "Code snippet settings"
            settingsButton.accessibilityHint = "Changes font size, font, theme, language, or removes the code snippet"
            settingsButton.accessibilityIdentifier = "codeSnippet.settings"
        }

        func updateSettingsMenu(_ menu: UIMenu) {
            settingsButton.menu = menu
        }

        func updateFrame(_ frame: CGRect, pageSize: CGSize) {
            self.pageSize = pageSize
            self.frame = previewFrame ?? frame
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            outerBorderView.frame = bounds
            innerBorderView.frame = bounds.insetBy(dx: 1, dy: 1)
            let horizontalScale = localToScreenScale(horizontal: true)
            let verticalScale = localToScreenScale(horizontal: false)
            let screenScale = max(min(horizontalScale, verticalScale), 0.05)
            let availableInternalControlSize = max(min(bounds.width, bounds.height) - 4, 1)
            let screenCompensatedControlSize = max(44, 44 / screenScale)
            let controlSize = attachment?.isCodeSnippet == true
                ? min(screenCompensatedControlSize, availableInternalControlSize)
                : screenCompensatedControlSize
            let controlGap = max(8, 8 / screenScale)
            let controlOffset = controlSize + controlGap
            let symbolPointSize = max(18, 18 / screenScale)
            updateControlSymbolSize(deleteButton, pointSize: symbolPointSize)
            if attachment?.isCodeSnippet == true {
                // Keep the visible gear inside the snippet. Its transparent menu button
                // remains screen-size compensated so it is still easy to hit while zoomed.
                let visualSize = min(
                    30,
                    max(min(bounds.width, bounds.height) - 12, 24)
                )
                let visualInset = min(
                    7,
                    max((min(bounds.width, bounds.height) - visualSize) / 2, 4)
                )
                settingsVisualView.frame = CGRect(
                    x: bounds.maxX - visualInset - visualSize,
                    y: bounds.minY + visualInset,
                    width: visualSize,
                    height: visualSize
                )
                settingsVisualView.layer.cornerRadius = visualSize / 2
                settingsVisualView.image = UIImage(
                    systemName: "gearshape.fill",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: min(16, visualSize * 0.58),
                        weight: .semibold
                    )
                )
                settingsButton.frame = CGRect(
                    x: bounds.maxX - min(controlSize, bounds.width),
                    y: bounds.minY,
                    width: min(controlSize, bounds.width),
                    height: min(controlSize, bounds.height)
                )
                deleteButton.frame = settingsButton.frame
            } else if frame.minY >= controlOffset {
                deleteButton.frame = CGRect(
                    x: bounds.maxX - controlSize,
                    y: -controlOffset,
                    width: controlSize,
                    height: controlSize
                )
            } else if pageSize.height - frame.maxY >= controlOffset {
                deleteButton.frame = CGRect(
                    x: bounds.maxX - controlSize,
                    y: bounds.maxY + controlGap,
                    width: controlSize,
                    height: controlSize
                )
            } else if frame.minX >= controlOffset {
                deleteButton.frame = CGRect(
                    x: -controlOffset,
                    y: 0,
                    width: controlSize,
                    height: controlSize
                )
            } else {
                deleteButton.frame = CGRect(
                    x: bounds.maxX + controlGap,
                    y: 0,
                    width: controlSize,
                    height: controlSize
                )
            }
            if attachment?.isCodeSnippet != true {
                settingsButton.frame = deleteButton.frame
            }
        }

        private func updateControlSymbolSize(_ button: UIButton, pointSize: CGFloat) {
            guard var configuration = button.configuration else { return }
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: .semibold
            )
            button.configuration = configuration
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if event?.allTouches?.contains(where: { $0.type == .pencil }) == true {
                return nil
            }

            if deleteButton.frame.contains(point),
               !deleteButton.isHidden,
               deleteButton.alpha > 0.01 {
                return deleteButton.hitTest(deleteButton.convert(point, from: self), with: event)
            }
            if attachment?.isCodeSnippet == true,
               bounds.contains(point),
               point.x >= bounds.maxX - effectiveSettingsCornerResizeHitWidth,
               point.y <= bounds.minY + effectiveSettingsCornerResizeHitWidth {
                // Keep a dedicated top-right vertex available even though the
                // settings button intentionally has a larger transparent hit target.
                return self
            }
            if settingsButton.frame.contains(point),
               !settingsButton.isHidden,
               settingsButton.alpha > 0.01 {
                return settingsButton.hitTest(settingsButton.convert(point, from: self), with: event)
            }

            let hitWidth = effectiveResizeHitWidth
            let resizeRegion = bounds.insetBy(dx: -hitWidth, dy: -hitWidth)
            guard resizeRegion.contains(point) else { return nil }
            guard attachment?.isCodeSnippet == true else { return self }

            // Let the live text view own the snippet body for cursor placement,
            // keyboard input, and Apple Pencil Scribble. The border resizes and the
            // header area remains a generous move handle.
            let isOnResizeEdge = point.x <= hitWidth
                || point.x >= bounds.width - hitWidth
                || point.y <= hitWidth
                || point.y >= bounds.height - hitWidth
            let isInMoveHeader = bounds.contains(point)
                && point.y <= effectiveMoveHeaderHeight
            return isOnResizeEdge || isInMoveHeader ? self : nil
        }

        private func configureView() {
            backgroundColor = .clear
            clipsToBounds = false

            outerBorderView.isUserInteractionEnabled = false
            outerBorderView.backgroundColor = .clear
            outerBorderView.layer.borderWidth = 0
            outerBorderView.isAccessibilityElement = true
            addSubview(outerBorderView)

            innerBorderView.isUserInteractionEnabled = false
            innerBorderView.backgroundColor = .clear
            innerBorderView.layer.borderWidth = 1
            innerBorderView.layer.borderColor = UIColor.separator.withAlphaComponent(0.9).cgColor
            addSubview(innerBorderView)

            configureHandle(
                deleteButton,
                systemImage: "trash",
                backgroundColor: UIColor.systemRed.withAlphaComponent(0.94)
            )
            deleteButton.addTarget(self, action: #selector(requestDeletion), for: .touchUpInside)
            addSubview(deleteButton)

            settingsVisualView.image = UIImage(systemName: "gearshape.fill")
            settingsVisualView.tintColor = .white
            settingsVisualView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.94)
            settingsVisualView.contentMode = .center
            settingsVisualView.isUserInteractionEnabled = false
            settingsVisualView.isHidden = true
            settingsVisualView.accessibilityIdentifier = "codeSnippet.settings.visual"
            settingsVisualView.accessibilityElementsHidden = true
            addSubview(settingsVisualView)

            settingsButton.configuration = .plain()
            settingsButton.backgroundColor = .clear
            settingsButton.isAccessibilityElement = true
            settingsButton.showsMenuAsPrimaryAction = true
            settingsButton.isHidden = true
            addSubview(settingsButton)

            let editingGesture = UIPanGestureRecognizer(target: self, action: #selector(handleEditingPan(_:)))
            editingGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            editingGesture.maximumNumberOfTouches = 1
            editingGesture.cancelsTouchesInView = true
            editingGesture.delegate = self
            addGestureRecognizer(editingGesture)
            editingPanGestureRecognizers.append(editingGesture)
        }

        private func configureHandle(
            _ button: UIButton,
            systemImage: String,
            backgroundColor: UIColor
        ) {
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: systemImage)
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = backgroundColor
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
            button.configuration = configuration
            button.tintColor = .white
            button.isAccessibilityElement = true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let touchedView = touch.view else { return true }
            return touchedView !== deleteButton
                && !touchedView.isDescendant(of: deleteButton)
                && touchedView !== settingsButton
                && !touchedView.isDescendant(of: settingsButton)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard editingPanGestureRecognizers.contains(where: { $0 === gestureRecognizer }),
                  let scrollView = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scrollView.panGestureRecognizer else {
                return false
            }

            // Give direct selected-image editing priority over an ancestor
            // document scroll without ever disabling the document pan recognizer.
            return isDescendant(of: scrollView)
        }

        @objc private func requestDeletion() {
            deleteRequested?()
        }

        @objc private func handleEditingPan(_ recognizer: UIPanGestureRecognizer) {
            guard let attachment else {
                dragStart = nil
                activeResizeHandle = nil
                resizeStart = nil
                return
            }

            switch recognizer.state {
            case .began:
                let startFrame = previewFrame ?? attachment.normalizedFrame(for: pageSize)
                let translation = recognizer.translation(in: self)
                let location = recognizer.location(in: self)
                let initialLocation = CGPoint(
                    x: location.x - translation.x,
                    y: location.y - translation.y
                )
                activeResizeHandle = resizeHandle(at: initialLocation)
                if activeResizeHandle == nil {
                    dragStart = startFrame
                } else {
                    resizeStart = startFrame
                }
            case .changed:
                let translation = recognizer.translation(in: superview)
                if let resizeStart, let activeResizeHandle {
                    applyPreview(AttachmentEditingGeometry.resizedFrame(
                        from: resizeStart,
                        translation: translation,
                        pageSize: pageSize,
                        handle: activeResizeHandle,
                        minimumLongEdge: attachment.isCodeSnippet
                            ? CodeSnippetLayout.minimumFrameLongEdge
                            : AttachmentEditingGeometry.minimumResizeLongEdge,
                        minimumSize: attachment.isCodeSnippet
                            ? CodeSnippetLayout.minimumFrameSize
                            : nil,
                        resizesEdgesIndependently: attachment.isCodeSnippet
                    ))
                } else if let dragStart {
                    applyPreview(AttachmentEditingGeometry.movedFrame(
                        from: dragStart,
                        translation: translation,
                        pageSize: pageSize
                    ))
                }
            case .ended:
                let wasResizing = resizeStart != nil
                let didCommit = commitPreview(startingAt: resizeStart ?? dragStart)
                dragStart = nil
                activeResizeHandle = nil
                resizeStart = nil
                if wasResizing, didCommit {
                    resizeCommitted?()
                }
            case .cancelled, .failed:
                if let startFrame = resizeStart ?? dragStart {
                    applyPreview(startFrame)
                }
                previewFrame = nil
                dragStart = nil
                activeResizeHandle = nil
                resizeStart = nil
            default:
                break
            }
        }

        func resizeHandle(at point: CGPoint) -> AttachmentResizeHandle? {
            let hitWidth = effectiveResizeHitWidth
            let isNearLeft = point.x <= hitWidth
            let isNearRight = point.x >= bounds.width - hitWidth
            let isNearTop = point.y <= hitWidth
            let isNearBottom = point.y >= bounds.height - hitWidth

            if attachment?.isCodeSnippet == true,
               point.y <= effectiveMoveHeaderHeight,
               !isNearLeft,
               !isNearRight,
               point.y > effectiveTopResizeHitHeight {
                // The center of the header moves the snippet. Its shallow top strip
                // remains available for vertical-only resizing.
                return nil
            }

            switch (isNearLeft, isNearRight, isNearTop, isNearBottom) {
            case (true, _, true, _): return .topLeft
            case (_, true, true, _): return .topRight
            case (true, _, _, true): return .bottomLeft
            case (_, true, _, true): return .bottomRight
            case (_, _, true, _): return .top
            case (_, true, _, _): return .right
            case (_, _, _, true): return .bottom
            case (true, _, _, _): return .left
            default: return nil
            }
        }

        private var effectiveResizeHitWidth: CGFloat {
            guard bounds.width > 0, bounds.height > 0 else { return resizeHitWidth }
            let scale = localToScreenScale(horizontal: true)
            let screenCompensatedWidth = resizeHitWidth / max(scale, 0.05)
            return min(
                max(resizeHitWidth, screenCompensatedWidth),
                min(bounds.width, bounds.height) * 0.32
            )
        }

        private var effectiveSettingsCornerResizeHitWidth: CGFloat {
            let horizontalScale = localToScreenScale(horizontal: true)
            let verticalScale = localToScreenScale(horizontal: false)
            let screenScale = max(min(horizontalScale, verticalScale), 0.05)
            return min(max(10, 12 / screenScale), effectiveResizeHitWidth)
        }

        private var effectiveTopResizeHitHeight: CGFloat {
            let scale = max(localToScreenScale(horizontal: false), 0.05)
            return min(
                max(10, 12 / scale),
                effectiveResizeHitWidth,
                effectiveMoveHeaderHeight * 0.4
            )
        }

        private var effectiveMoveHeaderHeight: CGFloat {
            guard bounds.height > 0 else { return CodeSnippetLayout.headerHeight }
            let scale = localToScreenScale(horizontal: false)
            let accessibleScreenHeight: CGFloat = 44
            let requestedHeight = max(
                CodeSnippetLayout.headerHeight,
                accessibleScreenHeight / max(scale, 0.05)
            )
            // At minimum size and a distant zoom, independently compensating the
            // header and bottom resize edge can make their hit regions overlap and
            // swallow every tap intended for the UITextView. Always preserve at
            // least one logical header-height of body content for cursor placement.
            let maximumHeightLeavingEditableBody = max(
                CodeSnippetLayout.headerHeight,
                bounds.height
                    - effectiveResizeHitWidth
                    - CodeSnippetLayout.headerHeight
            )
            return min(requestedHeight, maximumHeightLeavingEditableBody, bounds.height)
        }

        private func localToScreenScale(horizontal: Bool) -> CGFloat {
            let origin = convert(CGPoint.zero, to: nil)
            let unitPoint = convert(
                horizontal ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1),
                to: nil
            )
            let scale = hypot(unitPoint.x - origin.x, unitPoint.y - origin.y)
            return scale.isFinite && scale > 0 ? scale : 1
        }

        private func nudge(by translation: CGPoint) -> Bool {
            guard let attachment else { return false }
            let startFrame = attachment.normalizedFrame(for: pageSize)
            applyPreview(AttachmentEditingGeometry.movedFrame(
                from: startFrame,
                translation: translation,
                pageSize: pageSize
            ))
            commitPreview(startingAt: startFrame)
            return true
        }

        private func resize(by translation: CGPoint) -> Bool {
            guard let attachment else { return false }
            let startFrame = attachment.normalizedFrame(for: pageSize)
            applyPreview(AttachmentEditingGeometry.resizedFrame(
                from: startFrame,
                translation: translation,
                pageSize: pageSize,
                handle: .bottomRight,
                minimumLongEdge: attachment.isCodeSnippet
                    ? CodeSnippetLayout.minimumFrameLongEdge
                    : AttachmentEditingGeometry.minimumResizeLongEdge,
                minimumSize: attachment.isCodeSnippet
                    ? CodeSnippetLayout.minimumFrameSize
                    : nil,
                resizesEdgesIndependently: attachment.isCodeSnippet
            ))
            let didCommit = commitPreview(startingAt: startFrame)
            if didCommit {
                resizeCommitted?()
            }
            return didCommit
        }

        /// Updates only UIKit state while a gesture is active. Writing SwiftData here
        /// would invalidate the entire editor for every touch sample.
        func applyPreview(_ frame: CGRect) {
            previewFrame = frame
            self.frame = frame
            setNeedsLayout()
            frameChanged?(frame)
        }

        @discardableResult
        func commitPreview(startingAt startFrame: CGRect?) -> Bool {
            guard let attachment,
                  let startFrame,
                  let previewFrame,
                  previewFrame != startFrame else {
                self.previewFrame = nil
                return false
            }

            attachment.frame = previewFrame
            self.previewFrame = nil
            changeCommitted?()
            return true
        }
    }

    final class AttachmentImageContainerView: UIView {
        private enum RasterSourceKey: Equatable {
            case image(ImageFileIdentity)
        }

        private final class ImageLoadToken {
            private let lock = NSLock()
            private var isCancelledStorage = false
            private var evictsCachedVariantsOnCompletionStorage = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return isCancelledStorage
            }

            var evictsCachedVariantsOnCompletion: Bool {
                lock.lock()
                defer { lock.unlock() }
                return evictsCachedVariantsOnCompletionStorage
            }

            func cancel(evictCachedVariantsOnCompletion: Bool = false) {
                lock.lock()
                evictsCachedVariantsOnCompletionStorage = evictsCachedVariantsOnCompletionStorage || evictCachedVariantsOnCompletion
                isCancelledStorage = true
                lock.unlock()
            }
        }

        private static let imageDecodeQueue = DispatchQueue(
            label: "com.snowfox.BeanNotes.attachment-image-decode",
            qos: .utility
        )
        private let imageView = UIImageView()
        private var nativePDFPageView: NativePDFPageView?
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var imageURL: URL?
        private var imageFileIdentity: ImageFileIdentity?
        private var vectorPDFURL: URL?
        private var vectorPDFPageIndex: Int?
        private var loadedStoredFileName: String?
        private var loadedFileIdentity: ImageFileIdentity?
        private var loadedRasterBudget: AttachmentImageRasterBudget?
        private var loadedRasterSourceKey: RasterSourceKey?
        private var loadingStoredFileName: String?
        private var loadingFileIdentity: ImageFileIdentity?
        private var loadingRasterBudget: AttachmentImageRasterBudget?
        private var loadingRasterSourceKey: RasterSourceKey?
        private var desiredRasterSourceKey: RasterSourceKey?
        private var imageLoadRequestID: UUID?
        private var imageLoadToken: ImageLoadToken?
        private var currentRenderScale: CGFloat = 0
        private var isImageLoadingEnabled = true
        private var isDocumentTraversalActive = false
        private var isDrawingInteractionActive = false
        private var selectionRequested: (() -> Void)?

        var isRasterImageLoaded: Bool {
            imageView.image != nil
        }

        var isRasterBackingPresentedForTesting: Bool {
            imageView.image != nil && !imageView.isHidden && imageView.alpha > 0.01
        }

        var isVectorPDFVisible: Bool {
            nativePDFPageView.map { !$0.isHidden && $0.document != nil } == true
        }

        var hasVectorPDFView: Bool {
            nativePDFPageView != nil
        }

        var isVectorPDFRenderingSuspended: Bool {
            nativePDFPageView?.isInteractionRenderingDeferred == true
        }

        var rasterContentMode: UIView.ContentMode {
            imageView.contentMode
        }

        var rasterDisplayFrame: CGRect {
            imageView.frame
        }

        var vectorDisplayFrame: CGRect? {
            nativePDFPageView?.frame
        }

        var vectorDocumentURLForTesting: URL? {
            nativePDFPageView?.sourceURL
        }

        var vectorPageIndexForTesting: Int? {
            nativePDFPageView?.sourcePageIndex
        }

        var vectorFixedScaleForTesting: CGFloat? {
            nativePDFPageView?.fixedScaleForTesting
        }

        var vectorDocumentFrameForTesting: CGRect? {
            nativePDFPageView?.documentFrameInViewForTesting
        }

        var rasterBudgetMaxPixelSize: Int? {
            loadedRasterBudget?.maxPixelSize ?? loadingRasterBudget?.maxPixelSize
        }

        var rasterImageForTesting: UIImage? {
            imageView.image
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        deinit {
            cancelPendingImageLoad()
        }

        func configure(
            attachment: Attachment,
            storage: LocalStorageService,
            pageSize: CGSize,
            vectorSourceURL: URL? = nil,
            vectorPageIndex: Int? = nil,
            changed: @escaping () -> Void,
            selectionRequested: (() -> Void)? = nil
        ) {
            self.attachment = attachment
            self.pageSize = pageSize
            self.selectionRequested = selectionRequested

            // Establish final logical geometry before starting the source PDF render.
            // Every quality tier is displayed in this same immutable attachment frame.
            frame = attachment.normalizedFrame(for: pageSize)

            let storedVectorURL: URL? = if let vectorSource = attachment.vectorSourceStoredFileName {
                try? storage.validatedURL(forRelativePath: vectorSource)
            } else {
                nil
            }
            if let vectorURL = vectorSourceURL ?? storedVectorURL,
               let pageIndex = vectorPageIndex ?? attachment.vectorSourcePageIndex {
                vectorPDFURL = vectorURL
                vectorPDFPageIndex = pageIndex
            } else {
                vectorPDFURL = nil
                vectorPDFPageIndex = nil
            }

            if vectorPDFURL != nil, vectorPDFPageIndex != nil {
                // Imported PDF pages never enter the image decode/raster path. Keep
                // exactly one PDFKit view in the hierarchy for the entire lifetime of
                // this attachment container.
                transitionRasterSource(to: nil)
                releaseRasterImage(updatesVectorVisibility: false)
                imageView.removeFromSuperview()
                imageURL = nil
                imageFileIdentity = nil
                if isImageLoadingEnabled {
                    configureNativePDFViewIfNeeded()
                } else {
                    ensureNativePDFView().releaseDocument()
                }
            } else if let imageURL = try? storage.validatedURL(forRelativePath: attachment.storedFileName) {
                releaseNativePDFView()
                ensureImageView()
                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .clear
                imageView.isOpaque = false
                // Refresh identity when model content is reconfigured so replacing a
                // file in place invalidates cached pixels. Scale/scroll updates reuse it.
                let imageFileIdentity = ImageMemoryCache.shared.fileIdentity(for: imageURL)
                self.imageFileIdentity = imageFileIdentity
                self.imageURL = imageURL
                transitionRasterSource(
                    to: rasterSourceKey(imageFileIdentity: imageFileIdentity)
                )
                if isImageLoadingEnabled {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                } else {
                    releaseImage()
                }
            } else {
                releaseNativePDFView()
                ensureImageView()
                transitionRasterSource(to: nil)
                self.imageURL = nil
                imageFileIdentity = nil
                releaseImage()
            }
            updatePDFSurfaceVisibility()

            // Image pixels are document content only. Selection chrome and editing
            // gestures live in a separate layer above PencilKit.
            isUserInteractionEnabled = false
            isAccessibilityElement = attachment.isCodeSnippet && !attachment.isLocked
            accessibilityTraits = attachment.isCodeSnippet ? [.button] : []
            accessibilityLabel = attachment.isCodeSnippet ? attachment.displayName : nil
            accessibilityHint = attachment.isCodeSnippet
                ? "Selects this code snippet for typing, Apple Pencil writing, moving, resizing, and settings"
                : nil
            layer.borderWidth = 0
            layer.borderColor = nil
            backgroundColor = .clear
            setNeedsLayout()
        }

        override func accessibilityActivate() -> Bool {
            guard isAccessibilityElement, let selectionRequested else { return false }
            selectionRequested()
            return true
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            nativePDFPageView?.frame = bounds
        }

        private func configureView() {
            clipsToBounds = true
            imageView.contentMode = .scaleAspectFit
        }

        func updateRasterScale(_ scale: CGFloat, reloadImageVariant: Bool = true) {
            contentScaleFactor = scale
            layer.contentsScale = scale
            imageView.contentScaleFactor = scale
            imageView.layer.contentsScale = scale
            currentRenderScale = scale

            guard vectorPDFURL == nil else {
                updateVectorPDFInteractionRendering()
                return
            }
            guard reloadImageVariant, isImageLoadingEnabled, let imageURL, let attachment else { return }
            loadImageIfNeeded(from: imageURL, attachment: attachment)
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            if vectorPDFURL != nil, vectorPDFPageIndex != nil {
                if enabled {
                    configureNativePDFViewIfNeeded()
                } else {
                    nativePDFPageView?.releaseDocument()
                }
            } else if enabled {
                if let imageURL, let attachment {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                }
            } else {
                releaseRasterImage()
            }
            updatePDFSurfaceVisibility()
        }

        func setViewportVisible(_ visible: Bool) {
            // A loaded PDF stays mounted across viewport-boundary callbacks. The
            // enclosing page/scroll view already clips off-screen content; hiding the
            // PDF here caused a blank frame when a prefetched page became visible.
            _ = visible
        }

        func setDocumentTraversalActive(_ active: Bool) {
            guard isDocumentTraversalActive != active else { return }
            isDocumentTraversalActive = active
            updateVectorPDFInteractionRendering()
        }

        func setDrawingInteractionActive(_ active: Bool) {
            guard isDrawingInteractionActive != active else { return }
            isDrawingInteractionActive = active
            updateVectorPDFInteractionRendering()
        }

        private func loadImageIfNeeded(from imageURL: URL, attachment: Attachment) {
            guard isImageLoadingEnabled, vectorPDFURL == nil else { return }

            let attachmentSize = attachment.normalizedFrame(for: pageSize).size
            let budget = AttachmentImageRasterBudget(
                attachmentSize: attachmentSize,
                renderScale: currentRenderScale
            )
            let storedFileName = attachment.storedFileName
            let fileIdentity = imageFileIdentity
                ?? ImageMemoryCache.shared.fileIdentity(for: imageURL)
            let rasterSourceKey = rasterSourceKey(imageFileIdentity: fileIdentity)
            transitionRasterSource(to: rasterSourceKey)
            let sourceChanged = loadedRasterSourceKey != rasterSourceKey
            guard sourceChanged || budget.shouldReplaceLoadedBudget(loadedRasterBudget) else { return }
            guard loadingRasterSourceKey != rasterSourceKey
                    || loadingRasterBudget != budget else { return }

            if sourceChanged {
                imageView.image = nil
                loadedStoredFileName = nil
                loadedFileIdentity = nil
                loadedRasterBudget = nil
                loadedRasterSourceKey = nil
            }

            let requestID = UUID()
            let token = ImageLoadToken()
            imageLoadToken?.cancel()
            imageLoadRequestID = requestID
            imageLoadToken = token
            loadingStoredFileName = storedFileName
            loadingFileIdentity = fileIdentity
            loadingRasterBudget = budget
            loadingRasterSourceKey = rasterSourceKey

            let maxPixelSize = CGFloat(budget.maxPixelSize)
            Self.imageDecodeQueue.async { [
                imageURL,
                requestID,
                token,
                storedFileName,
                fileIdentity,
                budget,
                maxPixelSize
            ] in
                guard !token.isCancelled else { return }

                let image: UIImage? = autoreleasepool {
                    ImageMemoryCache.shared.image(
                        at: imageURL,
                        maxPixelSize: maxPixelSize,
                        identity: fileIdentity
                    )
                }

                guard !Self.evictCancelledImageIfNeeded(token, imageURL: imageURL) else { return }

                DispatchQueue.main.async { [weak self] in
                    guard !Self.evictCancelledImageIfNeeded(token, imageURL: imageURL) else { return }

                    guard let self,
                          self.imageLoadRequestID == requestID,
                          self.imageLoadToken === token,
                          !token.isCancelled,
                          self.isImageLoadingEnabled,
                          self.imageURL == imageURL,
                          self.desiredRasterSourceKey == rasterSourceKey,
                          self.loadingStoredFileName == storedFileName,
                          self.loadingFileIdentity == fileIdentity,
                          self.loadingRasterBudget == budget,
                          self.loadingRasterSourceKey == rasterSourceKey else {
                        _ = Self.evictCancelledImageIfNeeded(token, imageURL: imageURL)
                        return
                    }

                    self.imageLoadRequestID = nil
                    self.imageLoadToken = nil
                    self.loadingStoredFileName = nil
                    self.loadingFileIdentity = nil
                    self.loadingRasterBudget = nil
                    self.loadingRasterSourceKey = nil
                    // Ordinary-image pixel upgrades are an atomic contents replacement
                    // on the same fixed UIImageView.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageView.image = image
                    CATransaction.commit()

                    if image == nil {
                        self.loadedStoredFileName = nil
                        self.loadedFileIdentity = nil
                        self.loadedRasterBudget = nil
                        self.loadedRasterSourceKey = nil
                    } else {
                        self.loadedStoredFileName = storedFileName
                        self.loadedFileIdentity = fileIdentity
                        self.loadedRasterBudget = budget
                        self.loadedRasterSourceKey = rasterSourceKey
                    }
                    self.updatePDFSurfaceVisibility()
                }
            }
        }

        func releaseImage(evictCachedVariants: Bool = false) {
            releaseRasterImage(
                evictCachedVariants: evictCachedVariants,
                updatesVectorVisibility: false
            )
            nativePDFPageView?.releaseDocument()
            updatePDFSurfaceVisibility()
        }

        private func releaseRasterImage(
            evictCachedVariants: Bool = false,
            updatesVectorVisibility: Bool = true
        ) {
            cancelPendingImageLoad(evictCachedVariantsAfterDecode: evictCachedVariants)
            if evictCachedVariants, let imageURL {
                ImageMemoryCache.shared.removeImages(for: imageURL)
            }
            imageView.image = nil
            loadedStoredFileName = nil
            loadedFileIdentity = nil
            loadedRasterBudget = nil
            loadedRasterSourceKey = nil
            if updatesVectorVisibility {
                updatePDFSurfaceVisibility()
            }
        }

        private func updatePDFSurfaceVisibility() {
            guard isImageLoadingEnabled else {
                imageView.isHidden = true
                nativePDFPageView?.isHidden = true
                return
            }

            guard vectorPDFURL != nil, vectorPDFPageIndex != nil else {
                imageView.isHidden = false
                nativePDFPageView?.isHidden = true
                return
            }

            imageView.isHidden = true
            nativePDFPageView?.isHidden = nativePDFPageView?.document == nil
        }

        private func ensureImageView() {
            guard imageView.superview !== self else { return }
            imageView.removeFromSuperview()
            addSubview(imageView)
            imageView.frame = bounds
        }

        @discardableResult
        private func ensureNativePDFView() -> NativePDFPageView {
            if let nativePDFPageView {
                if nativePDFPageView.superview !== self {
                    addSubview(nativePDFPageView)
                }
                nativePDFPageView.frame = bounds
                return nativePDFPageView
            }

            let view = NativePDFPageView(frame: bounds)
            addSubview(view)
            nativePDFPageView = view
            return view
        }

        private func configureNativePDFViewIfNeeded() {
            guard let vectorPDFURL, let vectorPDFPageIndex else { return }
            let view = ensureNativePDFView()
            _ = view.configure(url: vectorPDFURL, pageIndex: vectorPDFPageIndex)
            updateVectorPDFInteractionRendering()
            updatePDFSurfaceVisibility()
        }

        private func updateVectorPDFInteractionRendering() {
            guard let nativePDFPageView else { return }
            let screenScale = window?.screen.scale ?? UIScreen.main.scale
            let rasterScale = currentRenderScale > 0 ? currentRenderScale : screenScale
            // Navigation can reuse a bounded snapshot, but live ink always restores
            // PDFKit's vector surface—even when a prior pinch has not settled yet.
            let usesTraversalSnapshot = isDocumentTraversalActive
                && !isDrawingInteractionActive
            nativePDFPageView.setInteractionRenderingDeferred(
                usesTraversalSnapshot,
                rasterScale: rasterScale
            )
        }

        private func releaseNativePDFView() {
            nativePDFPageView?.releaseDocument()
            nativePDFPageView?.removeFromSuperview()
            nativePDFPageView = nil
        }

        private func cancelPendingImageLoad(evictCachedVariantsAfterDecode: Bool = false) {
            imageLoadToken?.cancel(evictCachedVariantsOnCompletion: evictCachedVariantsAfterDecode)
            imageLoadRequestID = nil
            imageLoadToken = nil
            loadingStoredFileName = nil
            loadingFileIdentity = nil
            loadingRasterBudget = nil
            loadingRasterSourceKey = nil
        }

        private func rasterSourceKey(imageFileIdentity: ImageFileIdentity) -> RasterSourceKey {
            .image(imageFileIdentity)
        }

        private func transitionRasterSource(to sourceKey: RasterSourceKey?) {
            guard desiredRasterSourceKey != sourceKey else { return }

            desiredRasterSourceKey = sourceKey
            cancelPendingImageLoad()
            imageView.image = nil
            loadedStoredFileName = nil
            loadedFileIdentity = nil
            loadedRasterBudget = nil
            loadedRasterSourceKey = nil
        }

        private static func evictCancelledImageIfNeeded(_ token: ImageLoadToken, imageURL: URL) -> Bool {
            guard token.isCancelled else { return false }

            if token.evictsCachedVariantsOnCompletion {
                ImageMemoryCache.shared.removeImages(for: imageURL)
            }

            return true
        }

    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        struct SelectionUpdate {
            var effectivePageID: UUID?
            var shouldScroll: Bool
        }

        private final class WeakPageCanvasView {
            weak var value: PageCanvasView?

            init(_ value: PageCanvasView?) {
                self.value = value
            }
        }

        private enum DrawingSaveError: LocalizedError {
            case snapshotUnavailable

            var errorDescription: String? {
                "The current drawing could not be captured for saving."
            }
        }

        var parent: DrawingCanvasView
        var selectedPageID: UUID?
        private(set) var pendingVisiblePageID: UUID?
        private var pendingVisiblePageSelectionRevision: UInt64?
        private var visiblePagePublicationID: UInt64 = 0
        var saveNowSignal: Int
        var exportPreparationSignal: Int
        var fitToPageSignal: Int
        var zoomInSignal: Int
        var zoomOutSignal: Int
        var zoomToScaleSignal: Int
        var undoSignal: Int
        var redoSignal: Int
        var toolShortcutSignal: Int
        var viewportRestorationID: Int
        var configurationSignature: DrawingCanvasConfigurationSignature?
        var toolPicker = PKToolPicker()
        private var configuredToolPickerMode: PenPaletteMode?
        private var visibleToolPickerCanvasID: ObjectIdentifier?
        var pendingSaves: [UUID: DispatchWorkItem] = [:]
        var pendingSaveTokens: [UUID: UUID] = [:]
        var inFlightSaveTokens: [UUID: Set<UUID>] = [:]
        var registeredCanvasIDs: Set<ObjectIdentifier> = []
        private var toolPickerObservedCanvasIDs: Set<ObjectIdentifier> = []
        var dirtyPageIDs: Set<UUID> = []
        private var firstDirtyTimestamps: [UUID: CFTimeInterval] = [:]
        private var activeToolCanvasIDs: Set<ObjectIdentifier> = []
        private var deferredExportPreparationRequestID: Int?
        private var deferredExportPreparationDeadline: CFTimeInterval?
        private var deferredExportFallbackWorkItem: DispatchWorkItem?
        private var deferredDrawingChangeNotifications: Set<UUID> = []
        private var loadedDrawingDataByPageID: [UUID: Data] = [:]
        private var drawingChangeRevisionsByPageID: [UUID: UInt64] = [:]
        private var continuousDrawingBaselinesByCanvasID: [ObjectIdentifier: PKDrawing] = [:]
        private var continuousCanvasesWithDeferredChanges: Set<ObjectIdentifier> = []
        private var registeredPageIDsByCanvasID: [ObjectIdentifier: Set<UUID>] = [:]
        private var drawingLoadPagesByPageID: [UUID: NotePage] = [:]
        private var unavailableDrawingErrorsByPageID: [UUID: Error] = [:]
        private var drawingLoadRetryWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]
        private var drawingLoadRetryAttempts: [ObjectIdentifier: Int] = [:]
        var toolStateCancellable: AnyCancellable?
        weak var observedToolState: DrawingToolState?
        weak var containerView: CanvasContainerView?
        private var topContentHostingController: UIHostingController<AnyView>?
        private var lifecycleObservers: [NSObjectProtocol] = []

        private var canvasPages: [ObjectIdentifier: NotePage] = [:]
        private var canvasPageViews: [ObjectIdentifier: WeakPageCanvasView] = [:]
        private var pencilInteraction: UIPencilInteraction?
        private weak var pencilInteractionHostView: UIView?
        private var canvasToolSignatures: [ObjectIdentifier: String] = [:]
        private var temporaryEraserCanvasIDs: Set<ObjectIdentifier> = []
        private var lastPublishedCanUndo: Bool?
        private var lastPublishedCanRedo: Bool?
        private var lastPublishedZoomScale: CGFloat?
        private var lastZoomPublishTime: CFTimeInterval = 0
        private var lastPublishedViewport: DrawingCanvasViewport?
        private var lastViewportPublishTime: CFTimeInterval = 0
        private let zoomScalePublishThreshold: CGFloat = 0.01
        private let minimumZoomPublishInterval: CFTimeInterval = 1 / 15
        private let viewportCenterPublishThreshold: CGFloat = 4
        private let viewportZoomPublishThreshold: CGFloat = 0.01
        private let minimumViewportPublishInterval: CFTimeInterval = 1 / 15
        private static let drawingWriteQueueKey = DispatchSpecificKey<Void>()
        private static let drawingWriteQueue: DispatchQueue = {
            let queue = DispatchQueue(label: "com.snowfox.BeanNotes.drawing-write", qos: .utility)
            queue.setSpecific(key: drawingWriteQueueKey, value: ())
            return queue
        }()
        private static let drawingWriteRetryDelays: [TimeInterval] = [0.1, 0.3]

        private struct CanvasSaveRequest {
            var page: NotePage
            var drawing: PKDrawing
            var rootURL: URL
            var drawingFileName: String
            var drawingChangeRevision: UInt64
            var token: UUID?
        }

        func requestAddPage() {
            let addPageRequested = parent.addPageRequested
            dispatchToSwiftUI(addPageRequested)
        }

        func notifyAttachmentChanged() {
            let attachmentChanged = parent.attachmentChanged
            dispatchToSwiftUI(attachmentChanged)
        }

        func requestAttachmentDeletion(_ attachment: Attachment) {
            let deleteAttachment = parent.deleteAttachment
            dispatchToSwiftUI {
                deleteAttachment(attachment)
            }
        }

        func requestCodeSnippetEditing(_ attachment: Attachment) {
            guard attachment.isCodeSnippet else { return }
            let editCodeSnippet = parent.editCodeSnippet
            dispatchToSwiftUI {
                editCodeSnippet(attachment)
            }
        }

        func saveCodeSnippet(
            _ draft: CodeSnippetDraft,
            attachment: Attachment
        ) -> Bool {
            guard attachment.isCodeSnippet else { return false }
            return parent.saveCodeSnippet(draft, attachment)
        }

        func saveCodeSnippetSource(
            _ draft: CodeSnippetDraft,
            attachment: Attachment
        ) -> Bool {
            guard attachment.isCodeSnippet else { return false }
            return parent.saveCodeSnippetSource(draft, attachment)
        }

        func failExportPreparationForUnsavedCodeSnippet(requestID: Int) {
            let exportPreparationCompleted = parent.exportPreparationCompleted
            dispatchToSwiftUI {
                exportPreparationCompleted(requestID, .failure(ImportExportError.exportFailed))
            }
        }

        func requestPageAction(_ action: NotePageContextAction, for pageID: UUID) {
            let pageActionRequested = parent.pageActionRequested
            dispatchToSwiftUI {
                pageActionRequested(pageID, action)
            }
        }

        func captureSelection(
            page: NotePage,
            drawing: PKDrawing,
            selectionRect: CGRect,
            overlay: NoteCaptureSelectionOverlayView
        ) {
            overlay.setCopying(true)
            let snapshot = NotePageRenderSnapshot(
                page: page,
                theme: parent.theme,
                showsBeanArtwork: parent.showsBeanArtwork,
                automaticInterfaceStyle: parent.isDarkAppearance ? .dark : .light
            )
            let rootURL = parent.drawingStorage.storage.rootURL
            let captureFailed = parent.captureFailed

            Task { @MainActor [weak overlay] in
                // PencilKit drawings are UIKit-owned. Rendering them from a detached
                // task can leave the request unfinished, which in turn leaves the
                // capture control in its copying state. Yield first so the activity
                // indicator is visible before the bounded capture render begins.
                await Task.yield()
                let result = autoreleasepool { () -> Result<Data, NoteCaptureError> in
                    guard let image = ThumbnailService.renderPageCaptureImage(
                        snapshot: snapshot,
                        drawing: drawing,
                        rootURL: rootURL,
                        selectionRect: selectionRect
                    ) else {
                        return .failure(.renderFailed)
                    }
                    guard let data = image.pngData(), !data.isEmpty else {
                        return .failure(.encodingFailed)
                    }
                    return .success(data)
                }

                switch result {
                case .success(let data):
                    NoteCapturePasteboard.copyPNGData(data)
                    overlay?.showCopySucceeded()
                case .failure(let error):
                    overlay?.showCopyFailed()
                    captureFailed(error)
                }
            }
        }

        func drawingLoadFailure(for pageIDs: [UUID]) -> Error? {
            unavailableDrawingError(for: pageIDs)
        }

        func reportCaptureFailure(
            _ error: Error,
            overlay: NoteCaptureSelectionOverlayView
        ) {
            overlay.showCopyFailed()
            parent.captureFailed(error)
        }

        private func notifyVisiblePageChanged(_ pageID: UUID, selectionRevision: UInt64) {
            let selectedPageID = parent.$selectedPageID
            let currentSelectionRevision = parent.selectionRevision
            visiblePagePublicationID &+= 1
            let publicationID = visiblePagePublicationID
            dispatchToSwiftUI { [weak self] in
                guard let self else { return }
                guard self.visiblePagePublicationID == publicationID,
                      currentSelectionRevision() == selectionRevision,
                      self.selectedPageID == pageID else {
                    if self.visiblePagePublicationID == publicationID {
                        self.clearPendingVisiblePageSelection()
                    }
                    return
                }
                selectedPageID.wrappedValue = pageID
            }
        }

        private func notifyDrawingChanged(pageID: UUID) {
            let drawingChanged = parent.drawingChanged
            dispatchToSwiftUI {
                drawingChanged(pageID)
            }
        }

        private func notifySaveStarted() {
            let saveStarted = parent.saveStarted
            dispatchToSwiftUI(saveStarted)
        }

        private func notifySaveSucceededIfClean() {
            let saveSucceeded = parent.saveSucceeded
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pendingSaves.isEmpty,
                      self.dirtyPageIDs.isEmpty,
                      !self.hasAnyInFlightSaves,
                      self.unavailableDrawingErrorsByPageID.isEmpty else { return }
                saveSucceeded()
            }
        }

        private func notifySaveFailed(_ error: Error) {
            let saveFailed = parent.saveFailed
            dispatchToSwiftUI {
                saveFailed(error)
            }
        }

        private func notifyUndoRedoAvailabilityChanged(canUndo: Bool, canRedo: Bool) {
            let undoRedoAvailabilityChanged = parent.undoRedoAvailabilityChanged
            dispatchToSwiftUI {
                undoRedoAvailabilityChanged(canUndo, canRedo)
            }
        }

        func publishZoomScale(_ scale: CGFloat, force: Bool = false) {
            guard scale.isFinite,
                  scale > 0,
                  containerView?.defersViewStatePublishing != true else {
                return
            }
            let now = CACurrentMediaTime()
            let shouldPublish = force
                || (lastPublishedZoomScale.map { abs($0 - scale) > zoomScalePublishThreshold } ?? true)
            let intervalElapsed = now - lastZoomPublishTime >= minimumZoomPublishInterval
            guard shouldPublish, force || intervalElapsed else { return }

            lastPublishedZoomScale = scale
            lastZoomPublishTime = now
            if parent.strokeZoomBehavior.adjustsForZoomScale,
               containerView?.isZoomTransitionActive != true {
                applyCustomToolIfNeeded()
            }

            let zoomScaleChanged = parent.zoomScaleChanged
            dispatchToSwiftUI {
                zoomScaleChanged(scale)
            }
        }

        func publishViewport(_ viewport: DrawingCanvasViewport, force: Bool = false) {
            guard viewport.isValid,
                  containerView?.defersViewStatePublishing != true else {
                return
            }

            let now = CACurrentMediaTime()
            let hasMeaningfulChange = lastPublishedViewport.map { previous in
                let centerDelta = hypot(
                    viewport.center.x - previous.center.x,
                    viewport.center.y - previous.center.y
                )
                return centerDelta > viewportCenterPublishThreshold
                    || abs(viewport.zoomScale - previous.zoomScale) > viewportZoomPublishThreshold
            } ?? true
            let intervalElapsed = now - lastViewportPublishTime >= minimumViewportPublishInterval
            guard force || (hasMeaningfulChange && intervalElapsed) else { return }

            lastPublishedViewport = viewport
            lastViewportPublishTime = now
            let viewportChanged = parent.viewportChanged
            dispatchToSwiftUI {
                viewportChanged(viewport)
            }
        }

        func publishCurrentViewport() {
            guard let viewport = containerView?.currentViewport() else { return }
            publishViewport(viewport, force: true)

            let finalViewportChanged = parent.finalViewportChanged
            let selectedPageID = containerView?.currentSelectedPageID
            dispatchToSwiftUI {
                finalViewportChanged(viewport, selectedPageID)
            }
        }

        private func dispatchToSwiftUI(_ action: @escaping () -> Void) {
            DispatchQueue.main.async {
                action()
            }
        }

        var activeCanvasView: PKCanvasView? {
            containerView?.activeCanvasView
        }

        init(parent: DrawingCanvasView) {
            self.parent = parent
            self.selectedPageID = parent.selectedPageID
            self.saveNowSignal = parent.saveNowSignal
            self.exportPreparationSignal = parent.exportPreparationSignal
            self.fitToPageSignal = parent.fitToPageSignal
            self.zoomInSignal = parent.zoomInSignal
            self.zoomOutSignal = parent.zoomOutSignal
            self.zoomToScaleSignal = parent.zoomToScaleSignal
            self.undoSignal = parent.undoSignal
            self.redoSignal = parent.redoSignal
            self.toolShortcutSignal = parent.toolShortcutSignal
            self.viewportRestorationID = parent.viewportRestorationID
            super.init()
            observeApplicationLifecycle()
        }

        deinit {
            deferredExportFallbackWorkItem?.cancel()
            drawingLoadRetryWorkItems.values.forEach { $0.cancel() }
            removePencilInteraction()
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func updateTopContent(_ topContent: AnyView?) -> UIView? {
            guard let topContent else {
                topContentHostingController?.view.removeFromSuperview()
                topContentHostingController = nil
                return nil
            }

            if let topContentHostingController {
                topContentHostingController.rootView = topContent
                return topContentHostingController.view
            }

            let controller = UIHostingController(rootView: topContent)
            controller.view.backgroundColor = .clear
            topContentHostingController = controller
            return controller.view
        }

        func configurePencilInteraction(on view: UIView) {
            let interaction: UIPencilInteraction
            if let pencilInteraction {
                interaction = pencilInteraction
            } else {
                interaction = UIPencilInteraction()
                interaction.delegate = self
                pencilInteraction = interaction
            }

            if pencilInteractionHostView !== view {
                pencilInteractionHostView?.removeInteraction(interaction)
                view.addInteraction(interaction)
                pencilInteractionHostView = view
            }

            interaction.isEnabled = parent.paletteMode == .custom
        }

        func removePencilInteraction() {
            guard let pencilInteraction else { return }
            pencilInteractionHostView?.removeInteraction(pencilInteraction)
            pencilInteractionHostView = nil
            self.pencilInteraction = nil
        }

        func register(
            canvasView: PKCanvasView,
            page: NotePage,
            pageView: PageCanvasView? = nil,
            drawingLoadResults: [(NotePage, DrawingStorageService.LoadResult)]? = nil
        ) {
            let id = ObjectIdentifier(canvasView)
            canvasPages[id] = page
            canvasPageViews[id] = WeakPageCanvasView(pageView)
            if let drawingLoadResults {
                let pageIDs = Set(drawingLoadResults.map { $0.0.id })
                registeredPageIDsByCanvasID[id] = pageIDs
                var firstNewError: Error?
                for (loadedPage, result) in drawingLoadResults {
                    drawingLoadPagesByPageID[loadedPage.id] = loadedPage
                    switch result {
                    case .loaded:
                        unavailableDrawingErrorsByPageID[loadedPage.id] = nil
                        recordLoadedDrawingBaselineIfClean(
                            page: loadedPage,
                            result: result
                        )
                    case .missing:
                        // A missing file is a valid blank only when there was no
                        // earlier read/decode failure for this page. Internal canvas
                        // rebuilds can overlap an atomic or coordinated replacement.
                        if unavailableDrawingErrorsByPageID[loadedPage.id] == nil {
                            recordLoadedDrawingBaselineIfClean(
                                page: loadedPage,
                                result: result
                            )
                        }
                        break
                    case let .unavailable(error):
                        if unavailableDrawingErrorsByPageID[loadedPage.id] == nil,
                           firstNewError == nil {
                            firstNewError = error
                        }
                        unavailableDrawingErrorsByPageID[loadedPage.id] = error
                    }
                }

                let isBlocked = pageIDs.contains {
                    unavailableDrawingErrorsByPageID[$0] != nil
                }
                pageView?.setDrawingLoadBlocked(isBlocked)
                if isBlocked {
                    if let firstNewError {
                        notifySaveFailed(firstNewError)
                    }
                    scheduleDrawingLoadRetry(for: canvasView)
                } else {
                    cancelDrawingLoadRetry(for: id)
                }
            } else {
                let registeredPageIDs = registeredPageIDsByCanvasID[id] ?? [page.id]
                registeredPageIDsByCanvasID[id] = registeredPageIDs
                let isBlocked = registeredPageIDs.contains {
                    unavailableDrawingErrorsByPageID[$0] != nil
                }
                pageView?.setDrawingLoadBlocked(isBlocked)
            }
            pageView?.objectEraserDidBegin = { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.canvasViewDidBeginUsingTool(canvasView)
            }
            pageView?.objectEraserDidEnd = { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.canvasViewDidEndUsingTool(canvasView)
            }
            pageView?.objectEraserDrawingChanged = { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.canvasViewDrawingDidChange(canvasView)
            }

            if !registeredCanvasIDs.contains(id) {
                registeredCanvasIDs.insert(id)
            }
            if containerView?.isContinuousCanvas(canvasView) == true {
                continuousDrawingBaselinesByCanvasID[id] = canvasView.drawing
                continuousCanvasesWithDeferredChanges.remove(id)
            }
            if parent.paletteMode == .applePencil,
               toolPickerObservedCanvasIDs.insert(id).inserted {
                toolPicker.addObserver(canvasView)
            }

            applyCurrentCustomTool(to: canvasView)
            publishUndoRedoAvailability()
        }

        func unregister(
            canvasView: PKCanvasView,
            page: NotePage,
            flushDrawingBeforeRelease: Bool = true
        ) {
            let id = ObjectIdentifier(canvasView)
            let affectedPageIDs = registeredPageIDsByCanvasID[id] ?? [page.id]
            if activeToolCanvasIDs.contains(id) {
                canvasViewDidEndUsingTool(canvasView)
            }
            if flushDrawingBeforeRelease {
                flushDrawingBeforeCanvasRelease(canvasView, for: page)
            }
            for pageID in affectedPageIDs {
                pendingSaves[pageID]?.cancel()
                pendingSaves[pageID] = nil
                pendingSaveTokens[pageID] = nil
                loadedDrawingDataByPageID[pageID] = nil
                drawingChangeRevisionsByPageID[pageID] = nil
                if !parent.pages.contains(where: { $0.id == pageID }) {
                    drawingLoadPagesByPageID[pageID] = nil
                    unavailableDrawingErrorsByPageID[pageID] = nil
                }
            }
            registeredPageIDsByCanvasID[id] = nil
            continuousDrawingBaselinesByCanvasID[id] = nil
            continuousCanvasesWithDeferredChanges.remove(id)
            cancelDrawingLoadRetry(for: id)
            if toolPickerObservedCanvasIDs.remove(id) != nil {
                toolPicker.removeObserver(canvasView)
            }
            registeredCanvasIDs.remove(id)
            let removedActiveTool = activeToolCanvasIDs.remove(id) != nil
            if removedActiveTool, activeToolCanvasIDs.isEmpty {
                containerView?.setDrawingInteractionActive(false)
            }
            deferredDrawingChangeNotifications.remove(page.id)
            canvasPages[id] = nil
            canvasPageViews[id]?.value?.objectEraserDidBegin = nil
            canvasPageViews[id]?.value?.objectEraserDidEnd = nil
            canvasPageViews[id]?.value?.objectEraserDrawingChanged = nil
            canvasPageViews[id] = nil
            canvasToolSignatures[id] = nil
            temporaryEraserCanvasIDs.remove(id)

        }

        private func recordLoadedDrawingBaselineIfClean(
            page: NotePage,
            result: DrawingStorageService.LoadResult
        ) {
            guard !hasPendingDrawingWork(for: page.id) else { return }
            switch result {
            case .loaded:
                loadedDrawingDataByPageID[page.id] = result.archiveData
            case .missing:
                // Empty Data is an internal sentinel for a known blank page. It avoids
                // asking PencilKit to encode an empty drawing just to establish a baseline.
                loadedDrawingDataByPageID[page.id] = Data()
            case .unavailable:
                break
            }
        }

        private func scheduleDrawingLoadRetry(for canvasView: PKCanvasView) {
            let canvasID = ObjectIdentifier(canvasView)
            guard drawingLoadRetryWorkItems[canvasID] == nil else { return }

            let attempt = (drawingLoadRetryAttempts[canvasID] ?? 0) + 1
            let delay = Self.drawingLoadRetryDelay(forAttempt: attempt)
            drawingLoadRetryAttempts[canvasID] = attempt

            let retry = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self else { return }
                self.drawingLoadRetryWorkItems[canvasID] = nil
                guard let canvasView,
                      self.registeredCanvasIDs.contains(canvasID) else { return }
                self.retryUnavailableDrawingLoad(
                    for: canvasView,
                    attempt: attempt
                )
            }
            drawingLoadRetryWorkItems[canvasID] = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        }

        static func drawingLoadRetryDelay(forAttempt attempt: Int) -> TimeInterval {
            let initialDelays: [TimeInterval] = [0.25, 0.75, 1.5, 3]
            guard attempt > 0 else { return initialDelays[0] }
            guard attempt <= initialDelays.count else { return 10 }
            return initialDelays[attempt - 1]
        }

        private func retryUnavailableDrawingLoad(
            for canvasView: PKCanvasView,
            attempt: Int
        ) {
            let canvasID = ObjectIdentifier(canvasView)
            let pageIDs = registeredPageIDsByCanvasID[canvasID] ?? []
            guard !pageIDs.isEmpty else { return }
            guard !activeToolCanvasIDs.contains(canvasID),
                  !pageIDs.contains(where: hasPendingDrawingWork(for:)) else {
                scheduleDrawingLoadRetry(for: canvasView)
                return
            }

            let resolved: Bool
            if containerView?.isContinuousCanvas(canvasView) == true {
                guard let loadBundle = containerView?.retryContinuousDrawingLoad(for: canvasView) else {
                    scheduleDrawingLoadRetry(for: canvasView)
                    return
                }
                updateUnavailableDrawingErrors(from: loadBundle.results)
                if let drawing = loadBundle.drawing,
                   !pageIDs.contains(where: { unavailableDrawingErrorsByPageID[$0] != nil }) {
                    let delegate = canvasView.delegate
                    canvasView.delegate = nil
                    canvasView.drawing = drawing
                    canvasView.delegate = delegate
                    continuousDrawingBaselinesByCanvasID[canvasID] = drawing
                    continuousCanvasesWithDeferredChanges.remove(canvasID)
                    resolved = true
                } else {
                    resolved = false
                }
            } else if let pageID = pageIDs.first,
                      let page = drawingLoadPagesByPageID[pageID] {
                let loadResult = parent.drawingStorage.loadDrawingResult(for: page)
                switch loadResult {
                case let .loaded(drawing, _):
                    let delegate = canvasView.delegate
                    canvasView.delegate = nil
                    canvasView.drawing = drawing
                    canvasView.delegate = delegate
                    unavailableDrawingErrorsByPageID[pageID] = nil
                    resolved = true
                case .missing:
                    // A file that was previously present but unreadable disappearing
                    // is not proof that it became a legitimate blank page.
                    resolved = false
                case let .unavailable(error):
                    unavailableDrawingErrorsByPageID[pageID] = error
                    resolved = false
                }
            } else {
                resolved = false
            }

            guard resolved else {
                if attempt == 4,
                   let error = pageIDs.lazy.compactMap({ self.unavailableDrawingErrorsByPageID[$0] }).first {
                    notifySaveFailed(error)
                }
                scheduleDrawingLoadRetry(for: canvasView)
                return
            }

            drawingLoadRetryAttempts[canvasID] = nil
            canvasPageViews[canvasID]?.value?.setDrawingLoadBlocked(false)
            notifySaveSucceededIfClean()
        }

        private func updateUnavailableDrawingErrors(
            from results: [(NotePage, DrawingStorageService.LoadResult)]
        ) {
            for (page, result) in results {
                drawingLoadPagesByPageID[page.id] = page
                switch result {
                case .loaded:
                    unavailableDrawingErrorsByPageID[page.id] = nil
                    recordLoadedDrawingBaselineIfClean(page: page, result: result)
                case .missing:
                    // Preserve an existing unavailable state during retry; the file
                    // may be between coordinated replacement steps.
                    if unavailableDrawingErrorsByPageID[page.id] == nil {
                        recordLoadedDrawingBaselineIfClean(page: page, result: result)
                    }
                    break
                case let .unavailable(error):
                    unavailableDrawingErrorsByPageID[page.id] = error
                }
            }
        }

        private func cancelDrawingLoadRetry(for canvasID: ObjectIdentifier) {
            drawingLoadRetryWorkItems[canvasID]?.cancel()
            drawingLoadRetryWorkItems[canvasID] = nil
            drawingLoadRetryAttempts[canvasID] = nil
        }

        func hasPendingDrawingWork(for pageID: UUID) -> Bool {
            dirtyPageIDs.contains(pageID)
                || pendingSaves[pageID] != nil
                || pendingSaveTokens[pageID] != nil
                || hasInFlightSave(for: pageID)
        }

        private func unavailableDrawingError<S: Sequence>(for pageIDs: S) -> Error?
        where S.Element == UUID {
            pageIDs.lazy.compactMap { unavailableDrawingErrorsByPageID[$0] }.first
        }

        func selectVisiblePage(_ pageID: UUID) {
            guard parent.canPublishVisiblePageSelection() else {
                clearPendingVisiblePageSelection()
                selectedPageID = parent.$selectedPageID.wrappedValue
                return
            }

            let isAlreadyPublished = parent.$selectedPageID.wrappedValue == pageID
            selectedPageID = pageID
            if isAlreadyPublished {
                // A context-menu hold on the already-selected page does not produce a
                // SwiftUI binding change. Avoid leaving a pending selection that could
                // later override an add/remove/undo command.
                clearPendingVisiblePageSelection()
            } else {
                let selectionRevision = parent.selectionRevision()
                pendingVisiblePageID = pageID
                pendingVisiblePageSelectionRevision = selectionRevision
                notifyVisiblePageChanged(pageID, selectionRevision: selectionRevision)
            }
            activeCanvasView?.becomeFirstResponder()
            applyCustomToolIfNeeded()
            configureToolPicker(mode: parent.paletteMode)
            publishUndoRedoAvailability()
        }

        func selectPageForContextMenu(_ pageID: UUID) {
            containerView?.cancelProgrammaticPageSelection()
            beginUserPageSelection()
            selectVisiblePage(pageID)
        }

        func beginUserPageSelection() {
            parent.userPageSelectionStarted()
        }

        /// Keeps an asynchronously published visible-page change from being undone by
        /// an intervening SwiftUI update that still contains the previous selection.
        func reconcileSelectedPageID(_ proposedPageID: UUID?) -> SelectionUpdate {
            if pendingVisiblePageID != nil,
               pendingVisiblePageSelectionRevision != parent.selectionRevision() {
                clearPendingVisiblePageSelection()
            }

            if let pendingVisiblePageID {
                if proposedPageID == pendingVisiblePageID {
                    clearPendingVisiblePageSelection()
                    selectedPageID = proposedPageID
                }

                return SelectionUpdate(
                    effectivePageID: pendingVisiblePageID,
                    shouldScroll: false
                )
            }

            guard selectedPageID != proposedPageID else {
                return SelectionUpdate(effectivePageID: proposedPageID, shouldScroll: false)
            }

            selectedPageID = proposedPageID
            return SelectionUpdate(effectivePageID: proposedPageID, shouldScroll: proposedPageID != nil)
        }

        private func clearPendingVisiblePageSelection() {
            visiblePagePublicationID &+= 1
            pendingVisiblePageID = nil
            pendingVisiblePageSelectionRevision = nil
        }

        func configureToolPicker(mode: PenPaletteMode) {
            let usesCaptureTool = mode == .custom && parent.toolState.selectedTool == .capture
            containerView?.setCaptureToolEnabled(usesCaptureTool)
            if usesCaptureTool {
                if configuredToolPickerMode == .applePencil {
                    hideToolPicker()
                    detachToolPickerObservers()
                }
                configuredToolPickerMode = .custom
                return
            }
            guard let activeCanvasView else { return }

            if mode == .applePencil {
                let modeChanged = configuredToolPickerMode != .applePencil
                if modeChanged {
                    canvasToolSignatures.removeAll()
                    for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                        let id = ObjectIdentifier(canvasView)
                        canvasPageViews[id]?.value?.setEraserPreviewEnabled(false)
                    }
                }
                let id = ObjectIdentifier(activeCanvasView)
                if toolPickerObservedCanvasIDs.insert(id).inserted {
                    toolPicker.addObserver(activeCanvasView)
                }
                if modeChanged || visibleToolPickerCanvasID != id {
                    if visibleToolPickerCanvasID != nil {
                        hideToolPicker()
                    }
                    activeCanvasView.becomeFirstResponder()
                    toolPicker.setVisible(true, forFirstResponder: activeCanvasView)
                    visibleToolPickerCanvasID = id
                }
            } else {
                if configuredToolPickerMode == .applePencil {
                    hideToolPicker()
                    detachToolPickerObservers()
                }
            }
            configuredToolPickerMode = mode
        }

        func hideToolPicker() {
            for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                toolPicker.setVisible(false, forFirstResponder: canvasView)
            }
            visibleToolPickerCanvasID = nil
        }

        private func detachToolPickerObservers() {
            guard !toolPickerObservedCanvasIDs.isEmpty else { return }
            for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                let id = ObjectIdentifier(canvasView)
                if toolPickerObservedCanvasIDs.remove(id) != nil {
                    toolPicker.removeObserver(canvasView)
                }
            }
        }

        func observeToolState(_ toolState: DrawingToolState) {
            guard observedToolState !== toolState else { return }

            observedToolState = toolState
            toolStateCancellable = toolState.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyCustomToolIfNeeded()
                }
            }

            applyCustomToolIfNeeded()
        }

        func applyCustomToolIfNeeded() {
            guard parent.paletteMode == .custom else {
                containerView?.setCaptureToolEnabled(false)
                return
            }
            let usesCaptureTool = parent.toolState.selectedTool == .capture
            containerView?.setCaptureToolEnabled(usesCaptureTool)
            guard !usesCaptureTool else { return }
            // Replacing PKCanvasView.tool while UIKit is zooming interrupts its live ink
            // renderer. The settled zoom publish reapplies the calibrated tool once.
            guard containerView?.isZoomTransitionActive != true else { return }
            applyCurrentCustomToolToVisibleCanvases()
        }

        func applyToolShortcutSelection() {
            let signature = currentCustomToolSignature
            let tool = currentCustomTool

            if let activeCanvasView {
                applyCurrentCustomTool(tool, signature: signature, to: activeCanvasView, force: true)
                activeCanvasView.becomeFirstResponder()
            } else {
                for canvasView in containerView?.canvasPagePairs.map(\.1) ?? [] {
                    applyCurrentCustomTool(tool, signature: signature, to: canvasView, force: true)
                }
            }

            configureToolPicker(mode: parent.paletteMode)
        }

        private func applyCurrentCustomTool(to canvasView: PKCanvasView) {
            guard parent.paletteMode == .custom else { return }
            let signature = currentCustomToolSignature
            applyCurrentCustomTool(currentCustomTool, signature: signature, to: canvasView)
        }

        private func applyCurrentCustomToolToVisibleCanvases() {
            let signature = currentCustomToolSignature
            let tool = currentCustomTool
            let canvasViews = containerView?.canvasPagePairs.map { $0.1 } ?? []

            if canvasViews.isEmpty {
                if let activeCanvasView {
                    applyCurrentCustomTool(tool, signature: signature, to: activeCanvasView)
                }
                return
            }

            for canvasView in canvasViews {
                applyCurrentCustomTool(tool, signature: signature, to: canvasView)
            }
        }

        private func applyCurrentCustomTool(
            _ tool: PKTool,
            signature: String,
            to canvasView: PKCanvasView,
            force: Bool = false
        ) {
            let id = ObjectIdentifier(canvasView)
            guard force || canvasToolSignatures[id] != signature else { return }
            canvasView.tool = tool
            canvasToolSignatures[id] = signature
            let eraserTool = tool as? PKEraserTool
            let eraserMode = parent.toolState.selectedTool == .eraser
                ? parent.toolState.eraserMode
                : nil
            let usesCustomObjectEraser = eraserMode == .object
            let previewDiameter: CGFloat? = if eraserTool == nil {
                nil
            } else if eraserMode == .rub {
                parent.toolState.rubEraserSize
            } else {
                parent.toolState.eraserWidth
            }
            let rubConfiguration = eraserMode == .rub
                ? RubEraserConfiguration(
                    shape: parent.toolState.rubEraserShape,
                    size: parent.toolState.rubEraserSize,
                    angle: parent.toolState.rubEraserAngle
                )
                : nil
            canvasPageViews[id]?.value?.setEraserPreviewEnabled(
                eraserTool != nil,
                diameter: previewDiameter,
                usesCustomObjectEraser: usesCustomObjectEraser,
                rubEraserConfiguration: rubConfiguration
            )
        }

        private var currentCustomToolZoomScale: CGFloat {
            let scale = containerView?.scrollView.zoomScale ?? lastPublishedZoomScale ?? 1
            guard scale.isFinite, scale > 0 else { return 1 }
            return scale
        }

        private var currentCustomToolSignature: String {
            parent.toolState.pkToolSignature(
                zoomScale: currentCustomToolZoomScale,
                zoomBehavior: parent.strokeZoomBehavior
            )
        }

        private var currentCustomTool: PKTool {
            parent.toolState.makePKTool(
                zoomScale: currentCustomToolZoomScale,
                zoomBehavior: parent.strokeZoomBehavior
            )
        }

        /// Converts one document-wide PencilKit mutation into page-local dirty state.
        /// This is the key scalability boundary: normal ink updates never mark every
        /// page merely because the visible canvas spans the full note.
        @discardableResult
        private func reconcileContinuousDrawingChange(
            _ canvasView: PKCanvasView
        ) -> Set<UUID> {
            let canvasID = ObjectIdentifier(canvasView)
            guard containerView?.isContinuousCanvas(canvasView) == true,
                  let containerView else { return [] }

            let previousDrawing = continuousDrawingBaselinesByCanvasID[canvasID]
                ?? PKDrawing()
            let drawing = canvasView.drawing
            let changedPageIDs = containerView.changedContinuousPageIDs(
                from: previousDrawing,
                to: drawing,
                allowsSingleStrokeFastPath: parent.toolState.selectedTool == .pen
                    || parent.toolState.selectedTool == .pencil
                    || parent.toolState.selectedTool == .highlighter
            )
            continuousDrawingBaselinesByCanvasID[canvasID] = drawing
            continuousCanvasesWithDeferredChanges.remove(canvasID)
            guard !changedPageIDs.isEmpty else { return [] }

            advanceDrawingChangeRevisions(for: changedPageIDs)
            let newlyDirtyPageIDs = changedPageIDs.filter { pageID in
                !dirtyPageIDs.contains(pageID)
                    && pendingSaves[pageID] == nil
                    && !hasInFlightSave(for: pageID)
            }
            markDirty(changedPageIDs)
            canvasPageViews[canvasID]?.value?.drawingDidChange()
            for pageID in newlyDirtyPageIDs {
                notifyDrawingChanged(pageID: pageID)
            }
            if !newlyDirtyPageIDs.isEmpty {
                notifySaveStarted()
            }
            return changedPageIDs
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let key = ObjectIdentifier(canvasView)
            guard let page = canvasPages[key] else { return }

            if containerView?.isContinuousCanvas(canvasView) == true {
                if activeToolCanvasIDs.contains(key) {
                    continuousCanvasesWithDeferredChanges.insert(key)
                    return
                }

                if !reconcileContinuousDrawingChange(canvasView).isEmpty {
                    scheduleContinuousDrawingSave(canvasView)
                }
                publishUndoRedoAvailability()
                return
            }

            advanceDrawingChangeRevision(for: page.id)
            let didBecomeDirty = markDirty(page.id)
            let wasAlreadyDirty = !didBecomeDirty
                || pendingSaves[page.id] != nil
                || hasInFlightSave(for: page.id)

            if activeToolCanvasIDs.contains(key) {
                if !wasAlreadyDirty {
                    deferredDrawingChangeNotifications.insert(page.id)
                }
                return
            }

            canvasPageViews[key]?.value?.drawingDidChange()

            if !wasAlreadyDirty {
                notifyDrawingChanged(pageID: page.id)
                notifySaveStarted()
            }
            scheduleDrawingSave(for: page, canvasView: canvasView)
            publishUndoRedoAvailability()
        }

        private func scheduleContinuousDrawingSave(_ canvasView: PKCanvasView) {
            guard let containerView,
                  containerView.isContinuousCanvas(canvasView) else { return }
            // A shared canvas is only trustworthy when every page archive that
            // contributed to it loaded successfully. Keep the existing all-or-none
            // recovery guarantee even though the eventual writes are page-scoped.
            if !unavailableDrawingErrorsByPageID.isEmpty,
               let error = unavailableDrawingError(for: containerView.continuousPageIDs) {
                notifySaveFailed(error)
                return
            }
            let pageIDs = containerView.continuousPageIDs(in: dirtyPageIDs
                .union(pendingSaves.keys)
                .union(pendingSaveTokens.keys))
            guard !pageIDs.isEmpty else { return }
            notifySaveStarted()

            let token = UUID()
            for pageID in pageIDs {
                pendingSaves[pageID]?.cancel()
                pendingSaveTokens[pageID] = token
            }

            // Split PencilKit content on the main thread, then serialize each immutable
            // page drawing on the write queue. PencilKit's model objects are UIKit-owned;
            // touching their strokes off the main thread can leave an empty page snapshot.
            let save = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self else { return }
                let activePageIDs = Set(pageIDs.filter {
                    self.pendingSaveTokens[$0] == token
                })
                guard !activePageIDs.isEmpty else { return }
                guard let canvasView,
                      let pageDrawings = self.containerView?.continuousPageDrawings(
                          from: canvasView.drawing,
                          pageIDs: activePageIDs
                      ) else {
                    self.failPendingSave(
                        pageIDs: activePageIDs,
                        token: token,
                        error: DrawingSaveError.snapshotUnavailable
                    )
                    return
                }

                let rootURL = self.parent.drawingStorage.storage.rootURL
                var capturedPageIDs: Set<UUID> = []
                for (page, drawing) in pageDrawings where activePageIDs.contains(page.id) {
                    let pageID = page.id
                    let drawingChangeRevision = self.drawingChangeRevision(for: pageID)
                    capturedPageIDs.insert(pageID)
                    self.pendingSaves[pageID] = nil
                    self.pendingSaveTokens[pageID] = nil
                    let drawingFileName = page.drawingFileName
                    self.beginInFlightSave(pageID: pageID, token: token)
                    Self.writeDrawing(
                        drawing,
                        rootURL: rootURL,
                        drawingFileName: drawingFileName,
                        onSuccess: { [weak self] savedData in
                            self?.reportDrawingSaveSuccess(
                                pageID: pageID,
                                token: token,
                                page: page,
                                savedDrawingData: savedData,
                                drawingChangeRevision: drawingChangeRevision
                            )
                        },
                        onFailure: { [weak self] error in
                            self?.reportDrawingSaveFailure(error, pageID: pageID, token: token)
                        }
                    )
                }

                let missingPageIDs = activePageIDs.subtracting(capturedPageIDs)
                if !missingPageIDs.isEmpty {
                    self.failPendingSave(
                        pageIDs: missingPageIDs,
                        token: token,
                        error: DrawingSaveError.snapshotUnavailable
                    )
                }
            }

            for pageID in pageIDs {
                pendingSaves[pageID] = save
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + drawingSaveDelay(for: pageIDs),
                execute: save
            )
        }

        private func scheduleDrawingSave(for page: NotePage, canvasView: PKCanvasView) {
            scheduleDrawingSave(for: page) { [weak canvasView] in
                canvasView?.drawing
            }
        }

        private func scheduleDrawingSave(
            for page: NotePage,
            drawingProvider: @escaping () -> PKDrawing?
        ) {
            let pageID = page.id
            if let error = unavailableDrawingErrorsByPageID[pageID] {
                notifySaveFailed(error)
                return
            }
            notifySaveStarted()
            let rootURL = parent.drawingStorage.storage.rootURL
            let drawingFileName = page.drawingFileName
            let token = UUID()

            pendingSaves[pageID]?.cancel()
            pendingSaveTokens[pageID] = token

            let save = DispatchWorkItem { [weak self] in
                guard let self, self.pendingSaveTokens[pageID] == token else { return }
                guard let drawing = drawingProvider() else {
                    self.failPendingSave(
                        pageIDs: [pageID],
                        token: token,
                        error: DrawingSaveError.snapshotUnavailable
                    )
                    return
                }

                self.pendingSaves[pageID] = nil
                self.pendingSaveTokens[pageID] = nil
                self.beginInFlightSave(pageID: pageID, token: token)
                let drawingChangeRevision = self.drawingChangeRevision(for: pageID)

                Self.writeDrawing(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName,
                    onSuccess: { [weak self] savedData in
                        self?.reportDrawingSaveSuccess(
                            pageID: pageID,
                            token: token,
                            page: page,
                            savedDrawingData: savedData,
                            drawingChangeRevision: drawingChangeRevision
                        )
                    },
                    onFailure: { [weak self] error in
                        self?.reportDrawingSaveFailure(error, pageID: pageID, token: token)
                    }
                )
            }

            pendingSaves[pageID] = save
            DispatchQueue.main.asyncAfter(
                deadline: .now() + drawingSaveDelay(for: [pageID]),
                execute: save
            )
        }

        private func failPendingSave<S: Sequence>(
            pageIDs: S,
            token: UUID,
            error: Error
        ) where S.Element == UUID {
            var failedPageIDs: [UUID] = []
            for pageID in pageIDs where pendingSaveTokens[pageID] == token {
                pendingSaves[pageID]?.cancel()
                pendingSaves[pageID] = nil
                pendingSaveTokens[pageID] = nil
                markDirty(pageID)
                failedPageIDs.append(pageID)
            }
            guard !failedPageIDs.isEmpty else { return }
            notifySaveFailed(error)
        }

        private func flushDrawingBeforeCanvasRelease(_ canvasView: PKCanvasView, for page: NotePage) {
            let affectedPageIDs = registeredPageIDsByCanvasID[ObjectIdentifier(canvasView)] ?? [page.id]
            if let error = unavailableDrawingError(for: affectedPageIDs) {
                notifySaveFailed(error)
                return
            }
            if containerView?.isContinuousCanvas(canvasView) == true {
                saveAllCanvases(force: true)
                return
            }
            guard hasPendingDrawingWork(for: page.id) else { return }

            pendingSaves[page.id]?.cancel()
            pendingSaves[page.id] = nil
            pendingSaveTokens[page.id] = nil
            invalidateInFlightSaves(for: page.id)

            let rootURL = parent.drawingStorage.storage.rootURL
            let drawingFileName = page.drawingFileName
            let drawing = canvasView.drawing
            notifySaveStarted()

            do {
                let savedData = try Self.writeDrawingSynchronously(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName
                )
                page.touch()
                loadedDrawingDataByPageID[page.id] = savedData
                markClean(page.id)
                reportDrawingSaveSuccess()
            } catch {
                markDirty(page.id)
                reportDrawingSaveFailure(error, pageID: page.id)
            }
        }

        private static func writeDrawing(
            _ drawing: PKDrawing,
            rootURL: URL,
            drawingFileName: String,
            onSuccess: @escaping (Data) -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            drawingWriteQueue.async {
                autoreleasepool {
                    var lastError: Error?
                    for attempt in 0...drawingWriteRetryDelays.count {
                        do {
                            let savedData = try writeDrawingFile(
                                drawing,
                                rootURL: rootURL,
                                drawingFileName: drawingFileName
                            )
                            DispatchQueue.main.async {
                                onSuccess(savedData)
                            }
                            return
                        } catch {
                            lastError = error
                            guard attempt < drawingWriteRetryDelays.count else { break }
                            // A coordinated replacement can fail briefly while the
                            // app backgrounds or storage reconnects. Retry the same
                            // immutable snapshot on the utility queue before exposing
                            // an error; normal successful saves never pay this delay.
                            Thread.sleep(forTimeInterval: drawingWriteRetryDelays[attempt])
                        }
                    }

                    guard let lastError else { return }
                    DispatchQueue.main.async {
                        onFailure(lastError)
                    }
                }
            }
        }

        private static func writeDrawingSynchronously(
            _ drawing: PKDrawing,
            rootURL: URL,
            drawingFileName: String
        ) throws -> Data {
            if DispatchQueue.getSpecific(key: drawingWriteQueueKey) != nil {
                return try writeDrawingFile(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName
                )
            }

            var result: Result<Data, Error>!
            drawingWriteQueue.sync {
                autoreleasepool {
                    result = Result {
                        try writeDrawingFile(drawing, rootURL: rootURL, drawingFileName: drawingFileName)
                    }
                }
            }
            return try result.get()
        }

        private static func writeDrawingFile(
            _ drawing: PKDrawing,
            rootURL: URL,
            drawingFileName: String
        ) throws -> Data {
            try DrawingStorageService.writeDrawing(
                drawing,
                rootURL: rootURL,
                drawingFileName: drawingFileName
            )
        }

        private func reportDrawingSaveSuccess(
            pageID: UUID? = nil,
            token: UUID? = nil,
            page: NotePage? = nil,
            savedDrawingData: Data? = nil,
            drawingChangeRevision: UInt64? = nil
        ) {
            if let pageID {
                if let token {
                    guard finishInFlightSave(pageID: pageID, token: token) else { return }
                }

                let savedCurrentDrawing = drawingChangeRevision.map {
                    $0 == self.drawingChangeRevision(for: pageID)
                } ?? true
                if savedCurrentDrawing {
                    page?.touch()
                }
                if savedCurrentDrawing,
                   pendingSaves[pageID] == nil,
                   pendingSaveTokens[pageID] == nil,
                   !hasInFlightSave(for: pageID) {
                    if let savedDrawingData {
                        loadedDrawingDataByPageID[pageID] = savedDrawingData
                    }
                    markClean(pageID)
                }
            }

            guard pendingSaves.isEmpty, dirtyPageIDs.isEmpty, !hasAnyInFlightSaves else { return }
            notifySaveSucceededIfClean()
        }

        private func reportDrawingSaveFailure(_ error: Error, pageID: UUID, token: UUID? = nil) {
            if let token {
                guard finishInFlightSave(pageID: pageID, token: token) else { return }
            }

            markDirty(pageID)
            notifySaveFailed(error)
        }

        @discardableResult
        private func markDirty(_ pageID: UUID) -> Bool {
            let inserted = dirtyPageIDs.insert(pageID).inserted
            if firstDirtyTimestamps[pageID] == nil {
                firstDirtyTimestamps[pageID] = CACurrentMediaTime()
            }
            return inserted
        }

        private func markDirty<S: Sequence>(_ pageIDs: S) where S.Element == UUID {
            let now = CACurrentMediaTime()
            for pageID in pageIDs {
                dirtyPageIDs.insert(pageID)
                if firstDirtyTimestamps[pageID] == nil {
                    firstDirtyTimestamps[pageID] = now
                }
            }
        }

        private func advanceDrawingChangeRevision(for pageID: UUID) {
            drawingChangeRevisionsByPageID[pageID, default: 0] &+= 1
        }

        private func advanceDrawingChangeRevisions<S: Sequence>(for pageIDs: S)
        where S.Element == UUID {
            for pageID in pageIDs {
                advanceDrawingChangeRevision(for: pageID)
            }
        }

        private func drawingChangeRevision(for pageID: UUID) -> UInt64 {
            drawingChangeRevisionsByPageID[pageID, default: 0]
        }

        private func markClean(_ pageID: UUID) {
            dirtyPageIDs.remove(pageID)
            firstDirtyTimestamps[pageID] = nil
        }

        private func drawingSaveDelay(for pageIDs: [UUID]) -> TimeInterval {
            let now = CACurrentMediaTime()
            let firstChange = pageIDs.compactMap { firstDirtyTimestamps[$0] }.min() ?? now
            return DrawingAutosaveCadence.delay(elapsedSinceFirstChange: now - firstChange)
        }

        private var hasAnyInFlightSaves: Bool {
            inFlightSaveTokens.values.contains { !$0.isEmpty }
        }

        private func hasInFlightSave(for pageID: UUID) -> Bool {
            inFlightSaveTokens[pageID]?.isEmpty == false
        }

        private func beginInFlightSave(pageID: UUID, token: UUID) {
            inFlightSaveTokens[pageID, default: []].insert(token)
        }

        @discardableResult
        private func finishInFlightSave(pageID: UUID, token: UUID) -> Bool {
            guard var tokens = inFlightSaveTokens[pageID],
                  tokens.remove(token) != nil else {
                return false
            }

            if tokens.isEmpty {
                inFlightSaveTokens[pageID] = nil
            } else {
                inFlightSaveTokens[pageID] = tokens
            }

            return true
        }

        private func invalidateInFlightSaves(for pageID: UUID) {
            inFlightSaveTokens[pageID] = nil
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            let id = ObjectIdentifier(canvasView)
            activeToolCanvasIDs.insert(id)
            let activePageView = canvasPageViews[id]?.value
            let registeredPage = canvasPages[id]
            let activePageID: UUID? = if containerView?.isContinuousCanvas(canvasView) == true {
                containerView?.currentSelectedPageID ?? registeredPage?.id
            } else {
                registeredPage?.id
            }
            if containerView?.isContinuousCanvas(canvasView) == true {
                // Pencil input inside a selected snippet is intercepted by its live
                // text editor for Scribble. Reaching the document canvas therefore
                // means the user started ordinary page ink outside the snippet.
                containerView?.clearAttachmentSelectionsForContinuousDrawing()
                continuousDrawingBaselinesByCanvasID[id] = canvasView.drawing
                continuousCanvasesWithDeferredChanges.remove(id)
            }
            containerView?.setActiveDrawingPage(id: activePageID)
            containerView?.setDrawingInteractionActive(
                true,
                prioritizing: activePageView
            )
            if parent.toolState.temporaryEraserActive {
                temporaryEraserCanvasIDs.insert(id)
            }
            if let page = registeredPage {
                let affectedPageIDs = containerView?.isContinuousCanvas(canvasView) == true
                    ? Array(dirtyPageIDs)
                    : [page.id]
                for pageID in affectedPageIDs {
                    pendingSaves[pageID]?.cancel()
                    pendingSaves[pageID] = nil
                    pendingSaveTokens[pageID] = nil
                }
            }
            activePageView?.setLiveDrawingActive(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            let id = ObjectIdentifier(canvasView)
            activeToolCanvasIDs.remove(id)
            let completedTemporaryErase = temporaryEraserCanvasIDs.remove(id) != nil
            containerView?.setActiveDrawingPage(id: nil)
            canvasPageViews[id]?.value?.setLiveDrawingActive(false)

            if let page = canvasPages[id] {
                if containerView?.isContinuousCanvas(canvasView) == true {
                    if continuousCanvasesWithDeferredChanges.contains(id) {
                        _ = reconcileContinuousDrawingChange(canvasView)
                    }
                    if !dirtyPageIDs.isEmpty {
                        scheduleContinuousDrawingSave(canvasView)
                        publishUndoRedoAvailability()
                    }
                } else {
                    if deferredDrawingChangeNotifications.remove(page.id) != nil {
                        canvasPageViews[id]?.value?.drawingDidChange()
                        notifyDrawingChanged(pageID: page.id)
                    }
                    if dirtyPageIDs.contains(page.id) {
                        scheduleDrawingSave(for: page, canvasView: canvasView)
                        publishUndoRedoAvailability()
                    }
                }
            }

            if activeToolCanvasIDs.isEmpty {
                containerView?.setDrawingInteractionActive(false)
            }

            if activeToolCanvasIDs.isEmpty,
               let requestID = deferredExportPreparationRequestID {
                deferredExportPreparationRequestID = nil
                prepareForExport(requestID: requestID)
            }

            guard completedTemporaryErase,
                  parent.toolState.temporaryEraserActive else { return }
            parent.toolState.restoreAfterTemporaryEraser()
        }

        func performFinalDrawingFlush(reason: String, force: Bool = true, useBackgroundTask: Bool = true) {
            if useBackgroundTask {
                saveAllCanvasesInBackgroundTask(reason: reason, force: force)
            } else {
                saveAllCanvases(synchronously: false, force: force)
            }
        }

        private func observeApplicationLifecycle() {
            let center = NotificationCenter.default
            lifecycleObservers = [
                center.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.performFinalDrawingFlush(
                        reason: "Inactive",
                        force: false,
                        useBackgroundTask: false
                    )
                },
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.performFinalDrawingFlush(reason: "Background")
                },
                center.addObserver(
                    forName: UIApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.performFinalDrawingFlush(reason: "Termination")
                },
                center.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleMemoryWarning()
                },
                center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.restartUnavailableDrawingLoadRetries()
                }
            ]
        }

        private func handleMemoryWarning() {
            containerView?.reduceMemoryFootprint()
        }

        private func restartUnavailableDrawingLoadRetries() {
            for (canvasID, pageIDs) in registeredPageIDsByCanvasID
            where pageIDs.contains(where: { unavailableDrawingErrorsByPageID[$0] != nil }) {
                guard let canvasView = canvasView(for: canvasID) else { continue }
                cancelDrawingLoadRetry(for: canvasID)
                scheduleDrawingLoadRetry(for: canvasView)
            }
        }

        private func saveAllCanvasesInBackgroundTask(reason: String, force: Bool) {
            let requests = canvasSaveRequests(force: force)
            guard !requests.isEmpty else { return }

            let application = UIApplication.shared
            var taskID: UIBackgroundTaskIdentifier = .invalid

            let endBackgroundTask = {
                DispatchQueue.main.async {
                    guard taskID != .invalid else { return }
                    application.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }

            taskID = application.beginBackgroundTask(withName: "BeanNotes \(reason) Drawing Flush") {
                endBackgroundTask()
            }

            let group = DispatchGroup()
            for request in requests {
                group.enter()
                Self.writeDrawing(
                    request.drawing,
                    rootURL: request.rootURL,
                    drawingFileName: request.drawingFileName,
                    onSuccess: { [weak self] savedData in
                        self?.reportDrawingSaveSuccess(
                            pageID: request.page.id,
                            token: request.token,
                            page: request.page,
                            savedDrawingData: savedData,
                            drawingChangeRevision: request.drawingChangeRevision
                        )
                        group.leave()
                    },
                    onFailure: { [weak self] error in
                        self?.reportDrawingSaveFailure(error, pageID: request.page.id, token: request.token)
                        group.leave()
                    }
                )
            }

            group.notify(queue: .main, execute: endBackgroundTask)
        }

        func saveAllCanvases(synchronously: Bool = true, force: Bool = false) {
            var savedAtLeastOneCanvas = false
            let requests = canvasSaveRequests(
                force: force,
                trackInFlight: !synchronously,
                invalidateInFlight: synchronously
            )

            for request in requests {
                if synchronously {
                    do {
                        let savedData = try Self.writeDrawingSynchronously(
                            request.drawing,
                            rootURL: request.rootURL,
                            drawingFileName: request.drawingFileName
                        )
                        request.page.touch()
                        loadedDrawingDataByPageID[request.page.id] = savedData
                        markClean(request.page.id)
                        savedAtLeastOneCanvas = true
                    } catch {
                        reportDrawingSaveFailure(error, pageID: request.page.id)
                    }
                } else {
                    Self.writeDrawing(
                        request.drawing,
                        rootURL: request.rootURL,
                        drawingFileName: request.drawingFileName,
                        onSuccess: { [weak self] savedData in
                            self?.reportDrawingSaveSuccess(
                                pageID: request.page.id,
                                token: request.token,
                                page: request.page,
                                savedDrawingData: savedData,
                                drawingChangeRevision: request.drawingChangeRevision
                            )
                        },
                        onFailure: { [weak self] error in
                            self?.reportDrawingSaveFailure(error, pageID: request.page.id, token: request.token)
                        }
                    )
                }
            }

            if synchronously,
               savedAtLeastOneCanvas,
               dirtyPageIDs.isEmpty,
               pendingSaves.isEmpty,
               !hasAnyInFlightSaves {
                notifySaveSucceededIfClean()
            }
        }

        func prepareForExport(requestID: Int) {
            guard activeToolCanvasIDs.isEmpty else {
                if deferredExportPreparationRequestID != requestID {
                    deferredExportPreparationDeadline = CACurrentMediaTime() + 5
                }
                deferredExportPreparationRequestID = requestID
                scheduleDeferredExportFallback(requestID: requestID, after: 1)
                return
            }
            deferredExportFallbackWorkItem?.cancel()
            deferredExportFallbackWorkItem = nil
            deferredExportPreparationRequestID = nil
            deferredExportPreparationDeadline = nil

            if let loadError = unavailableDrawingErrorsByPageID.values.first {
                notifySaveFailed(loadError)
                let exportPreparationCompleted = parent.exportPreparationCompleted
                dispatchToSwiftUI {
                    exportPreparationCompleted(requestID, .failure(loadError))
                }
                return
            }

            let requests = canvasSaveRequests(
                // PencilKit can deliver its final change callback just after the user taps
                // Export. Snapshot every materialized canvas so that timing cannot produce
                // a clean-looking export with the newest ink missing.
                force: true,
                trackInFlight: false,
                invalidateInFlight: true
            )
            var firstError: Error?

            for request in requests {
                do {
                    let savedData = try Self.writeDrawingSynchronously(
                        request.drawing,
                        rootURL: request.rootURL,
                        drawingFileName: request.drawingFileName
                    )
                    request.page.touch()
                    loadedDrawingDataByPageID[request.page.id] = savedData
                    markClean(request.page.id)
                } catch {
                    markDirty(request.page.id)
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            if firstError == nil,
               (!dirtyPageIDs.isEmpty || !pendingSaves.isEmpty || hasAnyInFlightSaves) {
                firstError = ImportExportError.exportFailed
            }

            if let firstError {
                notifySaveFailed(firstError)
            } else {
                notifySaveSucceededIfClean()
            }

            let result: Result<Void, Error> = firstError.map(Result.failure) ?? .success(())
            let exportPreparationCompleted = parent.exportPreparationCompleted
            dispatchToSwiftUI {
                exportPreparationCompleted(requestID, result)
            }
        }

        private func scheduleDeferredExportFallback(
            requestID: Int,
            after delay: TimeInterval
        ) {
            deferredExportFallbackWorkItem?.cancel()
            let fallback = DispatchWorkItem { [weak self] in
                guard let self,
                      self.deferredExportPreparationRequestID == requestID else { return }

                var stillDrawing = false
                for canvasID in Array(self.activeToolCanvasIDs) {
                    guard let canvasView = self.canvasView(for: canvasID) else {
                        self.activeToolCanvasIDs.remove(canvasID)
                        continue
                    }
                    if self.canvasPageViews[canvasID]?.value?.hasActiveDrawingGesture == true {
                        stillDrawing = true
                        continue
                    }
                    // The recognizers are idle, so this is a stale PencilKit lifecycle
                    // flag rather than an in-progress stroke.
                    self.canvasViewDidEndUsingTool(canvasView)
                }

                guard self.deferredExportPreparationRequestID == requestID else { return }
                if self.activeToolCanvasIDs.isEmpty {
                    self.deferredExportPreparationRequestID = nil
                    self.prepareForExport(requestID: requestID)
                } else if stillDrawing,
                          CACurrentMediaTime() < (self.deferredExportPreparationDeadline ?? 0) {
                    self.scheduleDeferredExportFallback(requestID: requestID, after: 0.25)
                } else {
                    self.failDeferredExportPreparation(requestID: requestID)
                }
            }
            deferredExportFallbackWorkItem = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fallback)
        }

        private func failDeferredExportPreparation(requestID: Int) {
            guard deferredExportPreparationRequestID == requestID else { return }
            deferredExportPreparationRequestID = nil
            deferredExportPreparationDeadline = nil
            deferredExportFallbackWorkItem?.cancel()
            deferredExportFallbackWorkItem = nil
            let error = ImportExportError.exportFailed
            notifySaveFailed(error)
            let exportPreparationCompleted = parent.exportPreparationCompleted
            dispatchToSwiftUI {
                exportPreparationCompleted(requestID, .failure(error))
            }
        }

        private func canvasSaveRequests(
            force: Bool,
            trackInFlight: Bool = true,
            invalidateInFlight: Bool = false
        ) -> [CanvasSaveRequest] {
            let snapshots: [(NotePage, PKDrawing)]
            if let canvasView = containerView?.activeCanvasView,
               containerView?.isContinuousCanvas(canvasView) == true {
                let canvasID = ObjectIdentifier(canvasView)
                let registeredPageIDs = registeredPageIDsByCanvasID[canvasID]
                    ?? Set(containerView?.continuousPageIDs ?? [])
                if force
                    || continuousCanvasesWithDeferredChanges.contains(canvasID)
                    || continuousDrawingBaselinesByCanvasID[canvasID] == nil {
                    _ = reconcileContinuousDrawingChange(canvasView)
                }
                if let error = unavailableDrawingError(for: registeredPageIDs) {
                    notifySaveFailed(error)
                    return []
                }
                let trackedPageIDs = Set(registeredPageIDs.filter { pageID in
                    dirtyPageIDs.contains(pageID)
                        || pendingSaves[pageID] != nil
                        || pendingSaveTokens[pageID] != nil
                })
                guard !trackedPageIDs.isEmpty else { return [] }
                guard let continuousSnapshots = containerView?.continuousPageDrawings(
                    from: canvasView.drawing,
                    pageIDs: trackedPageIDs
                ) else {
                    return []
                }
                snapshots = continuousSnapshots
            } else {
                snapshots = (containerView?.canvasPagePairs ?? []).map { page, canvasView in
                    (page, canvasView.drawing)
                }
            }
            var requests: [CanvasSaveRequest] = []

            for (page, drawing) in snapshots {
                if let error = unavailableDrawingErrorsByPageID[page.id] {
                    notifySaveFailed(error)
                    continue
                }
                let hasTrackedChanges = dirtyPageIDs.contains(page.id)
                        || pendingSaves[page.id] != nil
                        || pendingSaveTokens[page.id] != nil
                let hasUnreportedDrawingChange: Bool
                if force, let loadedData = loadedDrawingDataByPageID[page.id] {
                    hasUnreportedDrawingChange = loadedData.isEmpty
                        ? !drawing.strokes.isEmpty
                        : drawing.dataRepresentation() != loadedData
                } else if force {
                    // No trustworthy archive baseline means the cache may contain a
                    // newer live drawing. Rare lifecycle/export flushes favor one extra
                    // write over risking unreported ink loss.
                    hasUnreportedDrawingChange = true
                } else {
                    hasUnreportedDrawingChange = false
                }
                guard hasTrackedChanges || hasUnreportedDrawingChange else { continue }

                pendingSaves[page.id]?.cancel()
                pendingSaves[page.id] = nil
                pendingSaveTokens[page.id] = nil
                if invalidateInFlight {
                    invalidateInFlightSaves(for: page.id)
                }
                let token = trackInFlight ? UUID() : nil
                if let token {
                    beginInFlightSave(pageID: page.id, token: token)
                }
                notifySaveStarted()

                requests.append(
                    CanvasSaveRequest(
                        page: page,
                        drawing: drawing,
                        rootURL: parent.drawingStorage.storage.rootURL,
                        drawingFileName: page.drawingFileName,
                        drawingChangeRevision: drawingChangeRevision(for: page.id),
                        token: token
                    )
                )
            }

            return requests
        }

        private func canvasView(for id: ObjectIdentifier) -> PKCanvasView? {
            guard let containerView else { return nil }
            if let activeCanvasView = containerView.activeCanvasView,
               ObjectIdentifier(activeCanvasView) == id {
                return activeCanvasView
            }
            return containerView.canvasPagePairs
                .map(\.1)
                .first { ObjectIdentifier($0) == id }
        }

        @objc func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            guard containerView?.isZoomGestureActiveOrRecentlyEnded != true else { return }
            performUndo()
        }

        @objc func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            guard containerView?.isZoomGestureActiveOrRecentlyEnded != true else { return }
            performRedo()
        }

        @objc func handleFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let containerView else { return }

            // PencilKit can defer its private edit menu until the second touch ends.
            // Close both the immediate and deferred presentation before performing the
            // editor's own double-tap zoom.
            containerView.suppressNativeCanvasEditMenus()

            guard parent.inputMode == .pencilOnly else { return }
            guard containerView.isZoomGestureActiveOrRecentlyEnded != true else { return }

            let contentPoint = recognizer.location(in: containerView.contentView)
            containerView.toggleDetailZoom(at: contentPoint, animated: true)
        }

        func performUndo() {
            guard let undoManager = activeCanvasView?.undoManager, undoManager.canUndo else {
                publishUndoRedoAvailability()
                return
            }

            undoManager.undo()
            publishUndoRedoAvailability()
        }

        func performRedo() {
            guard let undoManager = activeCanvasView?.undoManager, undoManager.canRedo else {
                publishUndoRedoAvailability()
                return
            }

            undoManager.redo()
            publishUndoRedoAvailability()
        }

        func publishUndoRedoAvailability() {
            let canUndo = activeCanvasView?.undoManager?.canUndo ?? false
            let canRedo = activeCanvasView?.undoManager?.canRedo ?? false

            guard canUndo != lastPublishedCanUndo || canRedo != lastPublishedCanRedo else { return }
            lastPublishedCanUndo = canUndo
            lastPublishedCanRedo = canRedo

            notifyUndoRedoAvailabilityChanged(canUndo: canUndo, canRedo: canRedo)
        }

        func handlePencilDoubleTap() {
            guard parent.paletteMode == .custom,
                  pencilInteraction?.isEnabled == true else { return }
            parent.toolState.handleDoubleTap(action: parent.doubleTapAction)
            applyCustomToolIfNeeded()
        }

        @available(iOS, introduced: 12.1, deprecated: 17.5)
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard interaction === pencilInteraction else { return }
            handlePencilDoubleTap()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap _: UIPencilInteraction.Tap
        ) {
            guard interaction === pencilInteraction else { return }
            handlePencilDoubleTap()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if let tapGesture = gestureRecognizer as? UITapGestureRecognizer {
                if tapGesture.numberOfTouchesRequired == 1,
                   tapGesture.numberOfTapsRequired == 2,
                   parent.inputMode != .pencilOnly {
                    return false
                }

                return containerView?.isZoomGestureActiveOrRecentlyEnded != true
            }

            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UITapGestureRecognizer {
                return false
            }

            return true
        }
    }
}

private extension UIView {
    func applyOwnedBackingScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if abs(contentScaleFactor - scale) > 0.05 {
            contentScaleFactor = scale
        }
        if abs(layer.contentsScale - scale) > 0.05 {
            layer.contentsScale = scale
        }
        if abs(layer.rasterizationScale - scale) > 0.05 {
            layer.rasterizationScale = scale
        }

        layer.shouldRasterize = false
        setNeedsDisplay()
        layer.setNeedsDisplay()
        CATransaction.commit()
    }

}

private extension UIEdgeInsets {
    func distance(to other: UIEdgeInsets) -> CGFloat {
        max(
            abs(top - other.top),
            abs(left - other.left),
            abs(bottom - other.bottom),
            abs(right - other.right)
        )
    }
}
