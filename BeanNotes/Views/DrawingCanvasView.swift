//
//  DrawingCanvasView.swift
//  BeanNotes
//

import Combine
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

    init(
        pages: [NotePage],
        pageFlowMode: NoteEditorPageFlowMode,
        inputMode: DrawingInputMode,
        renderQuality: DrawingRenderQuality,
        storageRootURL: URL,
        theme: BeanNotesTheme,
        hasTopContent: Bool
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
        doubleTapZoom.cancelsTouchesInView = false
        containerView.addGestureRecognizer(doubleTapZoom)

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
            context.coordinator.saveAllCanvases()
            context.coordinator.saveNowSignal = saveNowSignal
        }

        if context.coordinator.exportPreparationSignal != exportPreparationSignal {
            context.coordinator.prepareForExport(requestID: exportPreparationSignal)
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
            hasTopContent: topContent != nil
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

        let scrollView = UIScrollView()
        let contentView = UIView()
        let addPageFooterButton = UIButton(type: .system)

        var visiblePageChanged: ((UUID) -> Void)?
        var viewportChanged: ((DrawingCanvasViewport, Bool) -> Void)?
        var addPageRequested: (() -> Void)?

        private var pageViews: [UUID: PageCanvasView] = [:]
        private var continuousPageView: PageCanvasView?
        private(set) var captureSelectionOverlay: NoteCaptureSelectionOverlayView?
        private var captureSelectionPageID: UUID?
        private var isCaptureToolEnabled = false
        private var seamlessAttachmentSelectionGesture: UITapGestureRecognizer?
        private var pagesByID: [UUID: NotePage] = [:]
        private var orderedPageIDs: [UUID] = []
        private var pageFrames: [UUID: CGRect] = [:]
        private var documentSize: CGSize = .zero
        private weak var topContentView: UIView?
        private var pageFlowMode: NoteEditorPageFlowMode = .seamless
        private var renderQuality: DrawingRenderQuality = .ultraFine
        private var layoutConfigurationSignature: DrawingCanvasLayoutSignature?
        private var selectedPageID: UUID?
        private var activeDrawingPageID: UUID?
        private var drawingStorage: DrawingStorageService?
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
        private var isDrawingInteractionActive = false
        private var isProgrammaticScrollAnimating = false
        private var programmaticScrollTargetID: UUID?
        private var programmaticScrollTargetOffset: CGPoint?
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
        private let fitSnapThreshold: CGFloat = 0.045
        private let tapAfterZoomIgnoreDuration: CFTimeInterval = 0.32
        private let scrollToTopDoubleTapInterval: CFTimeInterval = 0.5
        private let settledZoomDelay: TimeInterval = 0.12
        private let programmaticZoomSettleDuration: CFTimeInterval = 0.4
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

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        var activeCanvasView: PKCanvasView? {
            if pageFlowMode == .seamless {
                return continuousPageView?.canvasView
            }

            guard let selectedPageID else {
                guard let firstPageID = orderedPageIDs.first else { return nil }
                return pageViews[firstPageID]?.canvasView
            }

            return pageViews[selectedPageID]?.canvasView
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
            self.selectedPageID = selectedPageID ?? orderedPageIDs.first
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

        private var isContinuousDrawingEnabled: Bool {
            pageFlowMode == .seamless && continuousPageView != nil
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
                coordinator.saveAllCanvases(force: true)
            }
            if shouldRelayout, continuousPageView != nil {
                releaseContinuousPageView(flushDrawingBeforeRelease: false)
            }

            self.pageFlowMode = pageFlowMode
            seamlessAttachmentSelectionGesture?.isEnabled = pageFlowMode == .seamless
            self.inputMode = inputMode
            self.renderQuality = renderQuality
            self.theme = theme
            self.showsBeanArtwork = showsBeanArtwork
            self.selectedPageID = selectedPageID ?? pages.first?.id
            self.drawingStorage = drawingStorage
            self.coordinator = coordinator
            scrollView.panGestureRecognizer.minimumNumberOfTouches = inputMode == .anyInput ? 2 : 1
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
            materializePagesNearViewport()
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
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            isProgrammaticZooming = false
            programmaticZoomEarliestFinishTime = 0
            lastZoomEndTime = CACurrentMediaTime()
            centerDocument()
            finishDocumentTraversalIfIdle()
            updateRasterScale(force: true)
            materializePagesNearViewport(updatesRenderScale: false)
            updateNativeDrawingViewports(force: true)
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
            settledZoomWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let isBeforeProgrammaticSettleDeadline = self.isProgrammaticZooming
                    && CACurrentMediaTime() < self.programmaticZoomEarliestFinishTime
                guard !self.isPinchZooming,
                      !self.scrollView.isZooming,
                      !self.isScrollViewAnimatingZoom,
                      !isBeforeProgrammaticSettleDeadline else {
                    self.scheduleSettledZoomRefresh()
                    return
                }
                self.finishProgrammaticZoom()
            }
            settledZoomWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + settledZoomDelay, execute: workItem)
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
            updateZoomScalesIfNeeded()
            // UIScrollView owns the zoom transform while a pinch/programmatic zoom is
            // active. Changing content insets from layoutSubviews during that transform
            // makes UIKit repeatedly reposition the zoomed content, which appears as a
            // blink. Re-center once the native zoom transaction has settled instead.
            if !isPinchZooming && !isProgrammaticZooming {
                centerDocument()
            }
            let didRestoreViewport = restorePendingViewportIfPossible()
            materializePagesNearViewport()
            if viewportSizeChanged {
                updateNativeDrawingViewports(force: true)
            } else {
                updateNativeDrawingViewports()
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
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                cancelProgrammaticPageSelection()
                coordinator?.beginUserPageSelection()
                setUserScrolling(true)
            }
            let offsetDelta = scrollView.contentOffset.y - lastObservedContentOffsetY
            if abs(offsetDelta) > 0.5 {
                isScrollingTowardLaterPages = offsetDelta > 0
                lastObservedContentOffsetY = scrollView.contentOffset.y
            }
            materializePagesNearViewport(
                updatesRenderScale: !isPinchZooming && !isProgrammaticZooming
            )
            updateNativeDrawingViewports()
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
            isPinchZooming = true
            setUserScrolling(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // UIScrollView already preserves the pinch anchor. Avoid page-set scans and
            // redundant offset writes on every zoom sample; preload padding keeps the
            // active pages alive until the settled refresh materializes the final view.
            updateNativeDrawingViewports()
            scheduleSettledZoomRefresh()
            publishZoomScale()
            publishViewport()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isPinchZooming = false
            let isNearFitScale = abs(scale - lastFitScale) / max(lastFitScale, 0.01) < fitSnapThreshold
            let needsFitSnap = isNearFitScale && abs(scale - lastFitScale) > 0.001

            if needsFitSnap {
                beginProgrammaticZoom()
                scrollView.setZoomScale(lastFitScale, animated: true)
                scheduleSettledZoomRefresh()
                return
            }

            finishProgrammaticZoom()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            finishDocumentTraversal()
            updateNativeDrawingViewports()
            publishViewport(force: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishDocumentTraversal()
            updateNativeDrawingViewports()
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
            updateNativeDrawingViewports()
            publishViewport(force: true)
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            finishDocumentTraversal()
            updateNativeDrawingViewports()
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
            isProgrammaticZooming = true
            programmaticZoomEarliestFinishTime = CACurrentMediaTime() + programmaticZoomSettleDuration
        }

        private func layoutDocument() {
            guard !orderedPageIDs.isEmpty else {
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
            let pageGap = pageFlowMode == .seamless ? 0 : separatedPageGap

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
                y += size.height + pageGap
            }

            if y > 0 {
                y -= pageGap
            }

            let footerY = y + addPageFooterTopPadding
            addPageFooterButton.isHidden = false
            let extendsContinuousCanvas = pageFlowMode == .seamless
            addPageFooterButton.accessibilityLabel = extendsContinuousCanvas
                ? "Add drawing space"
                : "Add page"
            addPageFooterButton.accessibilityHint = extendsContinuousCanvas
                ? "Extends the continuous drawing canvas"
                : "Adds a new page to the end of this note"
            addPageFooterButton.frame = CGRect(
                x: (maxWidth - addPageFooterSize) / 2,
                y: footerY,
                width: addPageFooterSize,
                height: addPageFooterSize
            )
            y = footerY + addPageFooterSize + addPageFooterBottomPadding

            pageFrames = frames
            documentSize = CGSize(width: maxWidth, height: y)
            updateDocumentGeometry(to: documentSize)
            centerDocument()
            if isCaptureToolEnabled {
                updateCaptureSelectionOverlay()
            }
        }

        private var continuousDrawingFrame: CGRect? {
            guard let firstID = orderedPageIDs.first,
                  var drawingFrame = pageFrames[firstID] else { return nil }
            for id in orderedPageIDs.dropFirst() {
                if let frame = pageFrames[id] {
                    drawingFrame = drawingFrame.union(frame)
                }
            }
            return drawingFrame
        }

        private func configureContinuousPageViewIfNeeded(reloadsDrawing: Bool) {
            guard pageFlowMode == .seamless,
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
            pageView.setDocumentTraversalActive(isUserScrolling)
            pageView.setDrawingInteractionActive(isDrawingInteractionActive)
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
                for stroke in translatedDrawing.strokes {
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

            return continuousDrawingLoadBundle(storage: drawingStorage)
        }

        private func continuousStrokeSignature(_ stroke: PKStroke) -> ContinuousStrokeSignature {
            func quantized(_ value: CGFloat) -> Int64 {
                guard value.isFinite else { return 0 }
                return Int64((value * 10_000).rounded())
            }

            let transform = stroke.transform
            var points: [ContinuousStrokePointSignature] = []
            points.reserveCapacity(stroke.path.count)
            for index in 0..<stroke.path.count {
                let point = stroke.path[index]
                let location = point.location.applying(transform)
                points.append(
                    ContinuousStrokePointSignature(
                        x: quantized(location.x),
                        y: quantized(location.y),
                        width: quantized(point.size.width),
                        height: quantized(point.size.height),
                        opacity: quantized(point.opacity),
                        force: quantized(point.force)
                    )
                )
            }
            let masks = stroke.maskedPathRanges.map {
                ContinuousStrokeMaskSignature(
                    lowerBound: quantized($0.lowerBound),
                    upperBound: quantized($0.upperBound)
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

        func continuousPageDrawings(from drawing: PKDrawing) -> [(NotePage, PKDrawing)]? {
            guard isContinuousDrawingEnabled,
                  let drawingFrame = continuousDrawingFrame else { return nil }

            var strokesByPageID: [UUID: [PKStroke]] = Dictionary(
                uniqueKeysWithValues: orderedPageIDs.map { ($0, []) }
            )
            for stroke in drawing.strokes {
                let bounds = stroke.renderBounds.insetBy(dx: -0.5, dy: -0.5)
                let documentBounds = bounds.offsetBy(
                    dx: drawingFrame.minX,
                    dy: drawingFrame.minY
                )
                for id in pageIDsIntersecting(documentBounds) {
                    strokesByPageID[id, default: []].append(stroke)
                }
            }

            return orderedPageIDs.compactMap { id in
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
            seamlessAttachmentSelectionGesture?.isEnabled = pageFlowMode == .seamless && !isCaptureToolEnabled
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
                case let .loaded(loadedDrawing):
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

            let widthFit = (bounds.width - pageMargin * 2) / documentSize.width
            let fitScale = min(max(widthFit, 0.18), 1.35)
            let minimumZoomScale = max(fitScale * zoomOutMultiplier, absoluteMinimumZoomScale)
            let maximumZoomScale = max(renderQuality.maximumZoomScale, fitScale * renderQuality.maximumZoomFitMultiplier)
            let wasNearFitScale = !isPinchZooming
                && !isProgrammaticZooming
                && abs(scrollView.zoomScale - lastFitScale) / max(lastFitScale, 0.01) < 0.05

            scrollView.minimumZoomScale = minimumZoomScale
            scrollView.maximumZoomScale = maximumZoomScale
            lastFitScale = fitScale

            let adjustedZoomScale: CGFloat?
            if !didSetInitialZoom || wasNearFitScale {
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
            guard documentSize != .zero else { return }

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

        private func materializePagesNearViewport(
            updatesRenderScale: Bool = true,
            refreshesExistingPages: Bool = false,
            prunesTraversalResources: Bool = false
        ) {
            guard !orderedPageIDs.isEmpty, let drawingStorage, let coordinator else { return }

            let visibleRect = visibleContentRect()
            prefetchDrawingFiles(around: visibleRect, drawingStorage: drawingStorage)
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

            for id in neededIDs {
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
                    if isUserScrolling,
                       !prunesTraversalResources,
                       coordinator.hasPendingDrawingWork(for: id) {
                        continue
                    }
                    if let pageView = pageViews[id] {
                        retirePageView(id: id, pageView: pageView)
                        didChangeMaterializedPages = true
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

            if updatesRenderScale {
                updateRasterScale(
                    force: didChangeMaterializedPages,
                    reloadImageVariants: !defersHeavyImageWork
                )
            }

            if didChangeMaterializedPages {
                arrangeDocumentLayers()
                updateNativeDrawingViewports()
            }
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
            guard pageFlowMode == .seamless else { return false }

            let target = seamlessAttachmentTarget(at: documentPoint)
            for pageView in pageViews.values where pageView !== target?.pageView {
                pageView.clearAttachmentSelection()
            }

            guard let target else {
                return false
            }

            target.pageView.beginEditingAttachment(id: target.attachment.id)
            target.pageView.presentAttachmentEditingControls(
                in: contentView,
                documentFrame: target.documentFrame
            )
            return target.pageView.selectedAttachmentID == target.attachment.id
        }

        private func seamlessAttachmentTarget(
            at documentPoint: CGPoint
        ) -> (pageView: PageCanvasView, attachment: Attachment, documentFrame: CGRect)? {
            for id in orderedPageIDs.reversed() {
                guard let documentFrame = pageFrames[id],
                      documentFrame.contains(documentPoint),
                      let pageView = pageViews[id] else {
                    continue
                }

                let pagePoint = CGPoint(
                    x: documentPoint.x - documentFrame.minX,
                    y: documentPoint.y - documentFrame.minY
                )
                if let attachment = pageView.editableAttachment(at: pagePoint) {
                    return (pageView, attachment, documentFrame)
                }
            }

            return nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === seamlessAttachmentSelectionGesture,
                  pageFlowMode == .seamless else {
                return true
            }

            var touchedView = touch.view
            while let view = touchedView {
                if view is AttachmentEditingOverlayView {
                    return false
                }
                touchedView = view.superview
            }

            let documentPoint = touch.location(in: contentView)
            return seamlessAttachmentTarget(at: documentPoint) != nil
                || pageViews.values.contains { $0.selectedAttachmentID != nil }
                || continuousPageView?.consumesBlankCanvasTaps == true
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
            // Apply interaction state before attachments are configured so a page
            // materialized mid-scroll or mid-stroke stays consistent with the editor.
            pageView.setDocumentTraversalActive(isUserScrolling)
            pageView.setDrawingInteractionActive(isDrawingInteractionActive)
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
                    saveCodeSnippet: { [weak coordinator] draft, attachment in
                        coordinator?.saveCodeSnippet(draft, attachment: attachment) ?? false
                    },
                    isDarkAppearance: coordinator.parent.isDarkAppearance,
                    canRemovePage: orderedPageIDs.count > 1,
                    drawingEnabled: pageFlowMode != .seamless,
                    seamlessAppearance: pageFlowMode == .seamless,
                    pageActionRequested: { [weak coordinator] pageID, action in
                        coordinator?.requestPageAction(action, for: pageID)
                    },
                    pageContextMenuWillOpen: { [weak coordinator] pageID in
                        coordinator?.selectPageForContextMenu(pageID)
                    }
                )
                pageView.setCaptureInteractionEnabled(isCaptureToolEnabled)
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

        private func retirePageView(
            id: UUID,
            pageView: PageCanvasView,
            flushDrawingBeforeRelease: Bool = true,
            evictCachedImages: Bool = false
        ) {
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
        }

        func reduceMemoryFootprint() {
            let retainedID = selectedPageID ?? orderedPageIDs.first
            let retiredIDs = pageViews.keys.filter { $0 != retainedID }

            for id in retiredIDs {
                if let pageView = pageViews[id] {
                    retirePageView(id: id, pageView: pageView, evictCachedImages: true)
                }
            }

            ImageMemoryCache.shared.removeAllImages()
            DrawingStorageService.clearCache()
            updateImageLoading(in: imageLoadingContentRect(visibleRect: visibleContentRect()))
            for pageView in pageViews.values {
                pageView.reduceDrawingMemoryFootprint()
            }
            continuousPageView?.reduceDrawingMemoryFootprint()
            updateRasterScale(force: true)
        }

        func cancelPendingRenderingWork() {
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            isPinchZooming = false
            isProgrammaticZooming = false
            programmaticZoomEarliestFinishTime = 0
            isProgrammaticScrollAnimating = false
            cancelProgrammaticPageSelection()
            setUserScrolling(false)
            setDrawingInteractionActive(false)

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
            for id in pageIDsIntersecting(prefetchRect) {
                guard let page = pagesByID[id] else { continue }
                DrawingStorageService.prefetchDrawing(
                    fileName: page.drawingFileName,
                    rootURL: rootURL
                )
            }
        }

        private func updateNativeDrawingViewports(force: Bool = false) {
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
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
            orderedPageIDs.first { pageFrames[$0]?.contains(documentPoint) == true }
        }

        private func updateImageLoading(in rect: CGRect) {
            for (id, pageView) in pageViews {
                pageView.setImageLoadingEnabled(pageFrame(id: id, intersects: rect))
            }
        }

        private func setUserScrolling(_ isScrolling: Bool) {
            guard isUserScrolling != isScrolling else { return }
            isUserScrolling = isScrolling
            for pageView in pageViews.values {
                pageView.setDocumentTraversalActive(isScrolling)
            }
            continuousPageView?.setDocumentTraversalActive(isScrolling)
        }

        func setDrawingInteractionActive(_ active: Bool) {
            guard isDrawingInteractionActive != active else { return }
            isDrawingInteractionActive = active
            for pageView in pageViews.values {
                pageView.setDrawingInteractionActive(active)
            }
            continuousPageView?.setDrawingInteractionActive(active)
        }

        func dismissNativeCanvasEditMenus() {
            for pageView in pageViews.values {
                pageView.dismissNativeCanvasEditMenus()
            }
            continuousPageView?.dismissNativeCanvasEditMenus()
        }

        private func updateVisiblePage() {
            guard !defersViewStatePublishing,
                  programmaticScrollTargetID == nil,
                  !pageFrames.isEmpty else { return }

            let contentPoint = contentView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                from: scrollView
            )

            let nearestID = nearestPageID(toY: contentPoint.y)

            guard let nearestID, nearestID != selectedPageID else { return }
            selectedPageID = nearestID
            visiblePageChanged?(nearestID)
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
            guard isUserScrolling else {
                materializePagesNearViewport()
                return
            }
            // Prune/disable distant resources while PDF views are still suspended, then
            // resume rendering only for the bounded survivor set.
            materializePagesNearViewport(prunesTraversalResources: true)
            setUserScrolling(false)
        }

        private func pageIDsIntersecting(_ rect: CGRect) -> [UUID] {
            guard !orderedPageIDs.isEmpty else { return [] }

            var low = 0
            var high = orderedPageIDs.count

            while low < high {
                let mid = (low + high) / 2
                let frame = pageFrames[orderedPageIDs[mid]] ?? .zero
                if frame.maxY < rect.minY {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            var index = low
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

        static func intersectedStrokeIndexes(
            in strokes: [PKStroke],
            eraserPath: [CGPoint],
            diameter: CGFloat
        ) -> IndexSet {
            guard diameter.isFinite,
                  diameter > 0 else {
                return []
            }

            let path = eraserPath.filter { $0.x.isFinite && $0.y.isFinite }
            guard !path.isEmpty else { return [] }

            let radius = diameter / 2
            let sweepBounds = bounds(of: path, expandedBy: radius + edgeTolerance)
            let sweepSegments = segments(for: path)
            var intersected = IndexSet()

            for (index, stroke) in strokes.enumerated() {
                // The swept path bounds already include the eraser radius, while
                // renderBounds already include the visible ink width. Expanding both
                // sides sends unrelated nearby handwriting through exact sampling.
                guard stroke.renderBounds.intersects(sweepBounds) else { continue }

                let samplingDistance = min(max(radius / 4, 1), 3)
                let sampleRuns = strokeSampleRuns(for: stroke, spacing: samplingDistance)
                guard strokeIntersectsSweep(
                    sampleRuns: sampleRuns,
                    sweepSegments: sweepSegments,
                    eraserRadius: radius
                ) else {
                    continue
                }

                intersected.insert(index)
            }

            return intersected
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

        let backgroundView = PageBackgroundUIView()
        let behindImageContainerView = UIView(frame: .zero)
        let drawingViewportView = UIView(frame: .zero)
        // PencilKit must retain its responder actions so UIKit can build a valid
        // edit-menu configuration after an ink or palette interaction.
        let canvasView = PKCanvasView(frame: .zero)
        let foregroundImageContainerView = UIView(frame: .zero)
        let eraserScopeView = EraserScopeView(frame: .zero)

        private var imageViews: [UUID: AttachmentImageContainerView] = [:]
        private let eraserScopeGesture = EraserScopeGestureRecognizer()
        private(set) var attachmentSelectionGesture: UITapGestureRecognizer?
        private var attachmentEditingOverlay: AttachmentEditingOverlayView?
        private var attachmentEditingHostView: AttachmentEditingHostView?
        private var codeSnippetEditingController: UIHostingController<CodeSnippetInlineEditor>?
        private(set) var page: NotePage?
        private(set) var selectedAttachmentID: UUID?
        private var configurationSignature: String?
        private var attachmentChanged: (() -> Void)?
        private var deleteAttachment: ((Attachment) -> Void)?
        private var editCodeSnippet: ((Attachment) -> Void)?
        private var saveCodeSnippet: ((CodeSnippetDraft, Attachment) -> Bool)?
        private var isDarkAppearance = false
        private var pageActionRequested: ((UUID, NotePageContextAction) -> Void)?
        private var pageContextMenuWillOpen: ((UUID) -> Void)?
        private var pageIDForPageAction: ((CGPoint) -> UUID?)?
        private var activePageActionPageID: UUID?
        private var canRemovePage = false
        private(set) lazy var pageActionMenuInteraction = UIEditMenuInteraction(delegate: self)
        private(set) var pageActionLongPressGesture: UILongPressGestureRecognizer?
        private var hasConfiguredImageAttachments = false
        private var lastBackgroundScale: CGFloat = 0
        private var lastImageScale: CGFloat = 0
        private var isImageLoadingEnabled = true
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
        private var isTrackingObjectEraser = false
        private var objectEraserInitialDrawing: PKDrawing?
        private var objectEraserHasChanges = false
        private(set) var objectEraserLiveEvaluationCount = 0
        private var laidOutPageBounds: CGRect = .null
        private var drawingPageSizeOverride: CGSize?
        private var isDrawingSurfaceEnabled = true
        private var isDrawingLoadBlocked = false
        private var activeDrawingViewportRect: CGRect = .null
        private var nativeZoomScale: CGFloat = 1
        private var pendingNativeViewport: NativeViewportRequest?

        var objectEraserDidBegin: (() -> Void)?
        var objectEraserDidEnd: (() -> Void)?
        var objectEraserDrawingChanged: (() -> Void)?

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
            !isCaptureInteractionEnabled && !(canvasView.tool is PKLassoTool)
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
            saveCodeSnippet: ((CodeSnippetDraft, Attachment) -> Bool)? = nil,
            isDarkAppearance: Bool = false,
            canRemovePage: Bool = false,
            drawingEnabled: Bool = true,
            seamlessAppearance: Bool = false,
            pageActionRequested: @escaping (UUID, NotePageContextAction) -> Void = { _, _ in },
            pageContextMenuWillOpen: @escaping (UUID) -> Void = { _ in }
        ) {
            var drawingLoadResults: [(NotePage, DrawingStorageService.LoadResult)]?
            let wasDrawingSurfaceEnabled = isDrawingSurfaceEnabled
            let wasRegisteredForDrawing = canvasView.delegate != nil
            let isNewPage = self.page?.id != page.id
            let signature = "\(staticContentSignature(for: page))#theme=\(theme.rawValue)#beanArtwork=\(showsBeanArtwork)"
            let needsStaticRefresh = isNewPage || signature != configurationSignature
            let pageSizeChanged = laidOutPageBounds.size != page.pageSize
            drawingPageSizeOverride = nil
            isDrawingSurfaceEnabled = drawingEnabled
            allowsAttachmentSelection = true
            if isNewPage {
                clearAttachmentSelection()
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
            self.saveCodeSnippet = saveCodeSnippet
            self.isDarkAppearance = isDarkAppearance
            self.canRemovePage = canRemovePage
            self.pageActionRequested = pageActionRequested
            self.pageContextMenuWillOpen = pageContextMenuWillOpen
            self.pageIDForPageAction = { _ in page.id }
            activePageActionPageID = nil
            layer.shadowOpacity = seamlessAppearance ? 0 : 0.12
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
                backgroundView.setNeedsDisplay()
                configureImages(page.visualAttachments, storage: storage, attachmentChanged: attachmentChanged)
                configurationSignature = signature
            }

            if drawingEnabled, isNewPage || !wasDrawingSurfaceEnabled {
                resetNativeCanvas(pageSize: page.pageSize)
                let loadResult = drawingStorage.loadDrawingResult(for: page)
                drawingLoadResults = [(page, loadResult)]
                canvasView.drawing = loadResult.drawing
                setDrawingLoadBlocked(loadResult.error != nil)
            } else if drawingEnabled, pageSizeChanged {
                resetNativeCanvas(pageSize: page.pageSize)
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
            backgroundView.setNeedsDisplay()
            // Repainting the background must not alter the PencilKit and attachment
            // layer order, and must not require rebuilding the live drawing.
            restoreDrawingLayerOrder()
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
            if attachmentEditingOverlay.superview !== editingHost {
                attachmentEditingOverlay.removeFromSuperview()
                editingHost.addSubview(attachmentEditingOverlay)
            }
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
            // A stationary finger hold owns the page menu, including in Pencil or
            // Finger mode. Ink and custom erasing resume as soon as the hold fails
            // from movement, while Pencil input bypasses this direct-touch gesture.
            canvasView.drawingGestureRecognizer.require(toFail: pageLongPress)
            eraserScopeGesture.require(toFail: pageLongPress)

            addInteraction(pageActionMenuInteraction)
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
            let remove = UIAction(
                title: "Remove Page",
                image: UIImage(systemName: "trash"),
                attributes: canRemovePage ? [.destructive] : [.destructive, .disabled]
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .remove)
            }

            var actions: [UIMenuElement] = [addBelow, addAbove]
            if canPasteImage {
                actions.append(pasteImage)
            }
            actions.append(remove)
            return UIMenu(children: actions)
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
            dismissNativeCanvasEditMenus()
            pageContextMenuWillOpen?(pageID)
            let configuration = UIEditMenuConfiguration(
                identifier: pageID as NSUUID,
                sourcePoint: recognizer.location(in: self)
            )
            pageActionMenuInteraction.presentEditMenu(with: configuration)
            DispatchQueue.main.async { [weak self] in
                self?.dismissNativeCanvasEditMenus()
            }
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
            let compactViewportSize = drawingPageSizeOverride.map { pageSize in
                CGSize(width: min(pageSize.width, 2_048), height: min(pageSize.height, 2_048))
            }
            resetNativeCanvas(
                pageSize: drawingPageSize,
                initialViewportSize: compactViewportSize
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
            if !active, let pendingNativeViewport {
                self.pendingNativeViewport = nil
                applyNativeDrawingViewport(pendingNativeViewport)
            }
        }

        func drawingDidChange() {
            guard !isUsingDrawingTool, let pendingNativeViewport else { return }
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

                imageView.setImageLoadingEnabled(isImageLoadingEnabled)
                imageView.setDocumentTraversalActive(isDocumentTraversalActive)
                imageView.setDrawingInteractionActive(isDrawingInteractionActive)
                let vectorSource = resolvedVectorSource(for: attachment, storage: storage)
                imageView.configure(
                    attachment: attachment,
                    storage: storage,
                    pageSize: page?.pageSize ?? .zero,
                    vectorSourceURL: vectorSource?.url,
                    vectorPageIndex: vectorSource?.pageIndex,
                    changed: attachmentChanged
                )
                imageView.frame = displayedFrame(for: attachment)
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
                },
                changeCommitted: { [weak self] in
                    self?.attachmentChanged?()
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
                }
            )
            overlay.superview?.bringSubviewToFront(overlay)
        }

        private func beginInlineCodeSnippetEditing(_ attachment: Attachment) {
            guard attachment.isCodeSnippet,
                  let saveCodeSnippet else {
                editCodeSnippet?(attachment)
                return
            }

            finishInlineCodeSnippetEditing(attachmentID: attachment.id)
            selectedAttachmentID = attachment.id
            attachmentEditingOverlay?.removeFromSuperview()
            attachmentEditingOverlay = nil

            let draft = CodeSnippetDraft(
                editing: attachment,
                defaults: CodeSnippetPreferences.defaultDraft()
            )
            let attachmentID = attachment.id
            let controller = UIHostingController(
                rootView: CodeSnippetInlineEditor(
                    draft: draft,
                    isDarkAppearance: isDarkAppearance,
                    onSave: { [weak self, weak attachment] updatedDraft in
                        guard let self,
                              let attachment,
                              attachment.id == attachmentID,
                              saveCodeSnippet(updatedDraft, attachment) else {
                            return false
                        }
                        self.finishInlineCodeSnippetEditing(attachmentID: attachmentID)
                        return true
                    },
                    onCancel: { [weak self] in
                        self?.finishInlineCodeSnippetEditing(attachmentID: attachmentID)
                    }
                )
            )
            controller.view.backgroundColor = .clear
            controller.view.frame = displayedFrame(for: attachment)
            controller.view.accessibilityIdentifier = "codeSnippet.inlineEditor"
            imageViews[attachmentID]?.isHidden = true
            addSubview(controller.view)
            codeSnippetEditingController = controller
        }

        private func finishInlineCodeSnippetEditing(attachmentID: UUID) {
            codeSnippetEditingController?.view.removeFromSuperview()
            codeSnippetEditingController = nil
            imageViews[attachmentID]?.isHidden = false
            selectedAttachmentID = nil
        }

        private func displayedFrame(for attachment: Attachment) -> CGRect {
            if selectedAttachmentID == attachment.id,
               let attachmentEditingOverlay {
                return attachmentEditingOverlay.displayedFrame
            }
            return attachment.normalizedFrame(for: page?.pageSize)
        }

        func clearAttachmentSelection() {
            if let selectedAttachmentID {
                finishInlineCodeSnippetEditing(attachmentID: selectedAttachmentID)
            }
            selectedAttachmentID = nil
            attachmentEditingOverlay?.removeFromSuperview()
            attachmentEditingOverlay = nil
            attachmentEditingHostView?.removeFromSuperview()
            attachmentEditingHostView = nil
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
            objectEraserPath.begin(at: location)
            objectEraserPendingPath = [location]
            objectEraserPendingTravelDistance = 0
            objectEraserInitialDrawing = canvasView.drawing
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

            flushPendingObjectEraserPath(forcesEvaluation: forcesEvaluation)
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
                isTrackingObjectEraser = false
                objectEraserPath.reset()
                objectEraserPendingPath.removeAll(keepingCapacity: false)
                objectEraserPendingTravelDistance = 0
                objectEraserInitialDrawing = nil
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
            } else if let diameter = eraserPreviewDiameter,
                      diameter.isFinite,
                      diameter > 0 {
                drawing = drawingByErasingObjects(
                    along: eraserPath,
                    diameter: diameter,
                    from: canvasView.drawing
                )
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

            if let attachmentEditingOverlay, attachmentEditingOverlay.superview === self {
                bringSubviewToFront(attachmentEditingOverlay)
            }
            bringSubviewToFront(eraserScopeView)
        }

        func releaseHeavyResources(evictCachedImages: Bool = false) {
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
            clearAttachmentSelection()
            hasConfiguredImageAttachments = false
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

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.contentsScale = UIScreen.main.scale
            layer.rasterizationScale = UIScreen.main.scale
            layer.shouldRasterize = false
            layer.drawsAsynchronously = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.contentsScale = UIScreen.main.scale
            layer.rasterizationScale = UIScreen.main.scale
            layer.shouldRasterize = false
            layer.drawsAsynchronously = true
        }

        func updateRenderScale(_ scale: CGFloat) {
            guard abs(contentScaleFactor - scale) > 0.05 else { return }
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
                in: bounds,
                context: context
            )
        }
    }

    final class ImmediatePDFTiledLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }

    final class PDFPageTiledView: UIView {
        override class var layerClass: AnyClass { ImmediatePDFTiledLayer.self }

        // Main-thread lifecycle changes must never wait for a potentially expensive
        // PDF tile draw. State access stays brief, while background tile draws retain
        // their own document snapshot and serialize through a render-only lock.
        private let stateLock = NSLock()
        private let renderLock = NSLock()
        private var document: CGPDFDocument?
        private var sourceURL: URL?
        private var pageNumber = 0
        private var sourceIdentity: String?
        private var renderingSuspended = false
        private var needsDisplayAfterSuspension = false
        private(set) var displayInvalidationCount = 0

        private var tiledLayer: CATiledLayer {
            layer as! CATiledLayer
        }

        var isRenderingSuspended: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return renderingSuspended
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureLayer()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureLayer()
        }

        func configure(url: URL, pageIndex: Int) {
            let nextPageNumber = pageIndex + 1
            let nextIdentity = "\(url.standardizedFileURL.path)|\(nextPageNumber)"

            stateLock.lock()
            guard sourceIdentity != nextIdentity else {
                stateLock.unlock()
                return
            }
            document = nil
            sourceURL = url
            pageNumber = nextPageNumber
            sourceIdentity = nextIdentity
            let shouldDisplay = !renderingSuspended
            if renderingSuspended {
                needsDisplayAfterSuspension = true
            }
            stateLock.unlock()
            if shouldDisplay {
                requestDisplay()
            }
        }

        func setRenderingSuspended(_ suspended: Bool) {
            stateLock.lock()
            guard renderingSuspended != suspended else {
                stateLock.unlock()
                return
            }
            renderingSuspended = suspended
            let shouldDisplay = !suspended && needsDisplayAfterSuspension
            if !suspended {
                needsDisplayAfterSuspension = false
            }
            stateLock.unlock()

            if shouldDisplay {
                requestDisplay()
            }
        }

        func updateRenderScale(_ scale: CGFloat) {
            // CATiledLayer selects its own level of detail from the enclosing scroll-view
            // transform. Keep the base scale fixed so settled zoom updates do not discard
            // already visible tiles and flash the raster fallback.
            _ = scale
            let screenScale = window?.screen.scale ?? UIScreen.main.scale
            guard abs(tiledLayer.contentsScale - screenScale) > 0.05 else { return }
            tiledLayer.contentsScale = screenScale
            contentScaleFactor = screenScale
        }

        func releaseDocument() {
            stateLock.lock()
            document = nil
            sourceURL = nil
            pageNumber = 0
            sourceIdentity = nil
            needsDisplayAfterSuspension = false
            stateLock.unlock()
            requestDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), !bounds.isEmpty else { return }

            renderLock.lock()
            defer { renderLock.unlock() }

            stateLock.lock()
            guard !renderingSuspended else {
                needsDisplayAfterSuspension = true
                stateLock.unlock()
                return
            }
            let requestedIdentity = sourceIdentity
            let requestedURL = sourceURL
            let requestedPageNumber = pageNumber
            var renderDocument = document
            stateLock.unlock()

            if renderDocument == nil, let requestedURL {
                let loadedDocument = CGPDFDocument(requestedURL as CFURL)

                stateLock.lock()
                if sourceIdentity == requestedIdentity {
                    if document == nil {
                        document = loadedDocument
                    }
                    renderDocument = document
                } else {
                    renderDocument = nil
                }
                stateLock.unlock()
            }

            guard let renderDocument,
                  requestedIdentity != nil,
                  let page = renderDocument.page(at: requestedPageNumber) else {
                return
            }

            stateLock.lock()
            let shouldRender = !renderingSuspended && sourceIdentity == requestedIdentity
            if !shouldRender, renderingSuspended {
                needsDisplayAfterSuspension = true
            }
            stateLock.unlock()
            guard shouldRender else { return }

            context.saveGState()
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rect)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.concatenate(
                page.getDrawingTransform(
                    .mediaBox,
                    rect: bounds,
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            context.interpolationQuality = .high
            context.drawPDFPage(page)
            context.restoreGState()
        }

        private func configureLayer() {
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            tiledLayer.tileSize = CGSize(width: 512, height: 512)
            // Cover the editor's 12%–600% zoom range with native vector tiles rather
            // than upscaling a lower-detail tile at either end of the range.
            tiledLayer.levelsOfDetail = 4
            tiledLayer.levelsOfDetailBias = 4
            tiledLayer.drawsAsynchronously = true
            tiledLayer.contentsScale = UIScreen.main.scale
            contentScaleFactor = UIScreen.main.scale
        }

        private func requestDisplay() {
            displayInvalidationCount += 1
            tiledLayer.setNeedsDisplay()
        }
    }

    final class AttachmentEditingOverlayView: UIView, UIGestureRecognizerDelegate {
        private let outerBorderView = UIView()
        private let innerBorderView = UIView()
        private let deleteButton = UIButton(type: .custom)
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var dragStart: CGRect?
        private var activeResizeHandle: AttachmentResizeHandle?
        private var resizeStart: CGRect?
        private var previewFrame: CGRect?
        private var frameChanged: ((CGRect) -> Void)?
        private var changeCommitted: (() -> Void)?
        private var deleteRequested: (() -> Void)?
        private var dismiss: (() -> Void)?
        private(set) var editingPanGestureRecognizers: [UIPanGestureRecognizer] = []
        private let resizeHitWidth: CGFloat = 22

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
            deleteRequested: @escaping () -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.attachment = attachment
            self.frameChanged = frameChanged
            self.changeCommitted = changeCommitted
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
            outerBorderView.accessibilityHint = "Drag the item to move it, or drag an edge or corner to resize it"
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
            deleteButton.accessibilityLabel = "Delete \(attachment.displayName)"
            deleteButton.accessibilityHint = attachment.isCodeSnippet
                ? "Removes the code snippet after confirmation"
                : "Removes the image after confirmation"
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
            let controlSize: CGFloat = 44
            let controlGap: CGFloat = 8
            let controlOffset = controlSize + controlGap

            if frame.minY >= controlOffset {
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

            let resizeRegion = bounds.insetBy(dx: -resizeHitWidth, dy: -resizeHitWidth)
            return resizeRegion.contains(point) ? self : nil
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
                        handle: activeResizeHandle
                    ))
                } else if let dragStart {
                    applyPreview(AttachmentEditingGeometry.movedFrame(
                        from: dragStart,
                        translation: translation,
                        pageSize: pageSize
                    ))
                }
            case .ended:
                commitPreview(startingAt: resizeStart ?? dragStart)
                dragStart = nil
                activeResizeHandle = nil
                resizeStart = nil
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
            let isNearLeft = point.x <= resizeHitWidth
            let isNearRight = point.x >= bounds.width - resizeHitWidth
            let isNearTop = point.y <= resizeHitWidth
            let isNearBottom = point.y >= bounds.height - resizeHitWidth

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
                handle: .bottomRight
            ))
            commitPreview(startingAt: startFrame)
            return true
        }

        /// Updates only UIKit state while a gesture is active. Writing SwiftData here
        /// would invalidate the entire editor for every touch sample.
        func applyPreview(_ frame: CGRect) {
            previewFrame = frame
            self.frame = frame
            setNeedsLayout()
            frameChanged?(frame)
        }

        func commitPreview(startingAt startFrame: CGRect?) {
            guard let attachment,
                  let startFrame,
                  let previewFrame,
                  previewFrame != startFrame else {
                self.previewFrame = nil
                return
            }

            attachment.frame = previewFrame
            self.previewFrame = nil
            changeCommitted?()
        }
    }

    final class AttachmentImageContainerView: UIView {
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
        private var pdfPageView: PDFPageTiledView?
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var imageURL: URL?
        private var imageFileIdentity: ImageFileIdentity?
        private var vectorPDFURL: URL?
        private var vectorPDFPageIndex: Int?
        private var loadedStoredFileName: String?
        private var loadedFileIdentity: ImageFileIdentity?
        private var loadedRasterBudget: AttachmentImageRasterBudget?
        private var loadingStoredFileName: String?
        private var loadingFileIdentity: ImageFileIdentity?
        private var loadingRasterBudget: AttachmentImageRasterBudget?
        private var imageLoadRequestID: UUID?
        private var imageLoadToken: ImageLoadToken?
        private var currentRenderScale: CGFloat = 0
        private var isImageLoadingEnabled = true
        private var isDocumentTraversalActive = false
        private var isDrawingInteractionActive = false

        var isRasterImageLoaded: Bool {
            imageView.image != nil
        }

        var isVectorPDFVisible: Bool {
            pdfPageView?.isHidden == false
        }

        var hasVectorPDFView: Bool {
            pdfPageView != nil
        }

        var isVectorPDFRenderingSuspended: Bool {
            pdfPageView?.isRenderingSuspended == true
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
            changed: @escaping () -> Void
        ) {
            self.attachment = attachment
            self.pageSize = pageSize

            if let imageURL = try? storage.validatedURL(forRelativePath: attachment.storedFileName) {
                // Refresh identity when model content is reconfigured so replacing a
                // file in place invalidates cached pixels. Scale/scroll updates reuse it.
                imageFileIdentity = ImageMemoryCache.shared.fileIdentity(for: imageURL)
                self.imageURL = imageURL
                if isImageLoadingEnabled {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                } else {
                    releaseImage()
                }
            } else {
                self.imageURL = nil
                imageFileIdentity = nil
                releaseImage()
            }

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
                releaseVectorPDFView()
            }
            updateVectorPDFVisibility()

            frame = attachment.normalizedFrame(for: pageSize)
            // Image pixels are document content only. Selection chrome and editing
            // gestures live in a separate layer above PencilKit.
            isUserInteractionEnabled = false
            layer.borderWidth = 0
            layer.borderColor = nil
            backgroundColor = .clear
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            pdfPageView?.frame = bounds
        }

        private func configureView() {
            clipsToBounds = true
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }

        func updateRasterScale(_ scale: CGFloat, reloadImageVariant: Bool = true) {
            contentScaleFactor = scale
            layer.contentsScale = scale
            imageView.contentScaleFactor = scale
            imageView.layer.contentsScale = scale
            pdfPageView?.updateRenderScale(scale)
            currentRenderScale = scale

            guard reloadImageVariant, isImageLoadingEnabled, let imageURL, let attachment else { return }
            loadImageIfNeeded(from: imageURL, attachment: attachment)
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            if enabled {
                if let imageURL, let attachment {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                }
            } else {
                releaseRasterImage()
                releaseVectorPDFView()
            }
            updateVectorPDFVisibility()
        }

        func setDocumentTraversalActive(_ active: Bool) {
            guard isDocumentTraversalActive != active else { return }
            isDocumentTraversalActive = active
            updateVectorPDFVisibility()
        }

        func setDrawingInteractionActive(_ active: Bool) {
            guard isDrawingInteractionActive != active else { return }
            isDrawingInteractionActive = active
            updateVectorPDFVisibility()
        }

        private func loadImageIfNeeded(from imageURL: URL, attachment: Attachment) {
            guard isImageLoadingEnabled else { return }

            let budget = AttachmentImageRasterBudget(
                attachmentSize: attachment.normalizedFrame(for: pageSize).size,
                renderScale: currentRenderScale
            )
            let storedFileName = attachment.storedFileName
            let fileIdentity = imageFileIdentity
                ?? ImageMemoryCache.shared.fileIdentity(for: imageURL)
            let fileChanged = loadedStoredFileName != storedFileName || loadedFileIdentity != fileIdentity
            guard fileChanged || budget.shouldReplaceLoadedBudget(loadedRasterBudget) else { return }
            guard loadingStoredFileName != storedFileName
                    || loadingFileIdentity != fileIdentity
                    || loadingRasterBudget != budget else { return }

            if fileChanged {
                imageView.image = nil
                loadedStoredFileName = nil
                loadedFileIdentity = nil
                loadedRasterBudget = nil
            }

            let requestID = UUID()
            let token = ImageLoadToken()
            imageLoadToken?.cancel()
            imageLoadRequestID = requestID
            imageLoadToken = token
            loadingStoredFileName = storedFileName
            loadingFileIdentity = fileIdentity
            loadingRasterBudget = budget

            let maxPixelSize = CGFloat(budget.maxPixelSize)
            Self.imageDecodeQueue.async { [imageURL, requestID, token, storedFileName, fileIdentity, budget, maxPixelSize] in
                guard !token.isCancelled else { return }

                let image = autoreleasepool {
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
                          self.loadingStoredFileName == storedFileName,
                          self.loadingFileIdentity == fileIdentity,
                          self.loadingRasterBudget == budget else {
                        _ = Self.evictCancelledImageIfNeeded(token, imageURL: imageURL)
                        return
                    }

                    self.imageLoadRequestID = nil
                    self.imageLoadToken = nil
                    self.loadingStoredFileName = nil
                    self.loadingFileIdentity = nil
                    self.loadingRasterBudget = nil
                    self.imageView.image = image

                    if image == nil {
                        self.loadedStoredFileName = nil
                        self.loadedFileIdentity = nil
                        self.loadedRasterBudget = nil
                    } else {
                        self.loadedStoredFileName = storedFileName
                        self.loadedFileIdentity = fileIdentity
                        self.loadedRasterBudget = budget
                    }
                    self.updateVectorPDFVisibility()
                }
            }
        }

        func releaseImage(evictCachedVariants: Bool = false) {
            releaseRasterImage(
                evictCachedVariants: evictCachedVariants,
                updatesVectorVisibility: false
            )
            releaseVectorPDFView()
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
            if updatesVectorVisibility {
                updateVectorPDFVisibility()
            }
        }

        private func updateVectorPDFVisibility() {
            guard let vectorPDFURL,
                  let vectorPDFPageIndex,
                  isImageLoadingEnabled else {
                pdfPageView?.setRenderingSuspended(true)
                pdfPageView?.isHidden = true
                return
            }

            let view = ensurePDFPageView()
            view.configure(url: vectorPDFURL, pageIndex: vectorPDFPageIndex)
            view.setRenderingSuspended(false)
            view.isHidden = false
        }

        private func ensurePDFPageView() -> PDFPageTiledView {
            if let pdfPageView {
                return pdfPageView
            }

            let view = PDFPageTiledView()
            view.isHidden = true
            view.frame = bounds
            addSubview(view)
            view.updateRenderScale(currentRenderScale)
            pdfPageView = view
            return view
        }

        private func releaseVectorPDFView() {
            pdfPageView?.releaseDocument()
            pdfPageView?.removeFromSuperview()
            pdfPageView = nil
        }

        private func cancelPendingImageLoad(evictCachedVariantsAfterDecode: Bool = false) {
            imageLoadToken?.cancel(evictCachedVariantsOnCompletion: evictCachedVariantsAfterDecode)
            imageLoadRequestID = nil
            imageLoadToken = nil
            loadingStoredFileName = nil
            loadingFileIdentity = nil
            loadingRasterBudget = nil
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
                showsBeanArtwork: parent.showsBeanArtwork
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
                    case .missing:
                        // A missing file is a valid blank only when there was no
                        // earlier read/decode failure for this page. Internal canvas
                        // rebuilds can overlap an atomic or coordinated replacement.
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
                    recordLoadedDrawingBaselineIfClean(canvasView, page: page)
                }
            } else {
                let registeredPageIDs = registeredPageIDsByCanvasID[id] ?? [page.id]
                registeredPageIDsByCanvasID[id] = registeredPageIDs
                let isBlocked = registeredPageIDs.contains {
                    unavailableDrawingErrorsByPageID[$0] != nil
                }
                pageView?.setDrawingLoadBlocked(isBlocked)
                if !isBlocked {
                    recordLoadedDrawingBaselineIfClean(canvasView, page: page)
                }
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
            _ canvasView: PKCanvasView,
            page: NotePage
        ) {
            if containerView?.isContinuousCanvas(canvasView) == true,
               let pageDrawings = containerView?.continuousPageDrawings(from: canvasView.drawing) {
                for (continuousPage, drawing) in pageDrawings
                where !hasPendingDrawingWork(for: continuousPage.id) {
                    loadedDrawingDataByPageID[continuousPage.id] = drawing.dataRepresentation()
                }
            } else if !hasPendingDrawingWork(for: page.id) {
                loadedDrawingDataByPageID[page.id] = canvasView.drawing.dataRepresentation()
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
                    resolved = true
                } else {
                    resolved = false
                }
            } else if let pageID = pageIDs.first,
                      let page = drawingLoadPagesByPageID[pageID] {
                let loadResult = parent.drawingStorage.loadDrawingResult(for: page)
                switch loadResult {
                case let .loaded(drawing):
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
            if let page = canvasPages[canvasID] {
                recordLoadedDrawingBaselineIfClean(canvasView, page: page)
            }
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
                case .missing:
                    // Preserve an existing unavailable state during retry; the file
                    // may be between coordinated replacement steps.
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
                hideToolPicker()
                return
            }
            guard let activeCanvasView else { return }

            if mode == .applePencil {
                canvasToolSignatures.removeAll()
                for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                    let id = ObjectIdentifier(canvasView)
                    canvasPageViews[id]?.value?.setEraserPreviewEnabled(false)
                }
                let id = ObjectIdentifier(activeCanvasView)
                if toolPickerObservedCanvasIDs.insert(id).inserted {
                    toolPicker.addObserver(activeCanvasView)
                }
                activeCanvasView.becomeFirstResponder()
                toolPicker.setVisible(true, forFirstResponder: activeCanvasView)
            } else {
                hideToolPicker()
                detachToolPickerObservers()
            }
        }

        func hideToolPicker() {
            for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                toolPicker.setVisible(false, forFirstResponder: canvasView)
            }
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
            let previewDiameter = eraserTool.map { _ in
                if eraserMode == .rub {
                    return parent.toolState.rubEraserSize
                }
                return parent.toolState.eraserWidth
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
                usesCustomObjectEraser: eraserMode == .object,
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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let key = ObjectIdentifier(canvasView)
            guard let page = canvasPages[key] else { return }

            if containerView?.isContinuousCanvas(canvasView) == true {
                let pageIDs = containerView?.continuousPageIDs ?? [page.id]
                advanceDrawingChangeRevisions(for: pageIDs)
                let wasAlreadyDirty = pageIDs.contains {
                    dirtyPageIDs.contains($0)
                        || pendingSaves[$0] != nil
                        || hasInFlightSave(for: $0)
                }
                markDirty(pageIDs)

                if activeToolCanvasIDs.contains(key) {
                    if !wasAlreadyDirty {
                        deferredDrawingChangeNotifications.insert(page.id)
                        for pageID in pageIDs {
                            notifyDrawingChanged(pageID: pageID)
                        }
                        notifySaveStarted()
                    }
                    return
                }

                canvasPageViews[key]?.value?.drawingDidChange()
                if !wasAlreadyDirty {
                    for pageID in pageIDs {
                        notifyDrawingChanged(pageID: pageID)
                    }
                    notifySaveStarted()
                }
                scheduleContinuousDrawingSave(canvasView)
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
                    notifyDrawingChanged(pageID: page.id)
                    notifySaveStarted()
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
            guard let pageIDs = containerView?.continuousPageIDs, !pageIDs.isEmpty else { return }
            if let error = unavailableDrawingError(for: pageIDs) {
                notifySaveFailed(error)
                return
            }
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
                          from: canvasView.drawing
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
                    do {
                        let savedData = try writeDrawingFile(
                            drawing,
                            rootURL: rootURL,
                            drawingFileName: drawingFileName
                        )
                        DispatchQueue.main.async {
                            onSuccess(savedData)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            onFailure(error)
                        }
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
            let drawingsURL = rootURL.appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: drawingsURL, withIntermediateDirectories: true)
            let data = drawing.dataRepresentation()
            try data.write(to: drawingsURL.appendingPathComponent(drawingFileName), options: [.atomic])
            DrawingStorageService.cache(
                drawing,
                fileName: drawingFileName,
                rootURL: rootURL,
                approximateBytes: data.count
            )
            return data
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
            containerView?.setDrawingInteractionActive(true)
            if parent.toolState.temporaryEraserActive {
                temporaryEraserCanvasIDs.insert(id)
            }
            if let page = canvasPages[id] {
                let affectedPageIDs = containerView?.isContinuousCanvas(canvasView) == true
                    ? containerView?.continuousPageIDs ?? [page.id]
                    : [page.id]
                for pageID in affectedPageIDs {
                    pendingSaves[pageID]?.cancel()
                    pendingSaves[pageID] = nil
                    pendingSaveTokens[pageID] = nil
                }
                containerView?.setActiveDrawingPage(id: page.id)
            }
            canvasPageViews[id]?.value?.setLiveDrawingActive(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            let id = ObjectIdentifier(canvasView)
            activeToolCanvasIDs.remove(id)
            let completedTemporaryErase = temporaryEraserCanvasIDs.remove(id) != nil
            containerView?.setActiveDrawingPage(id: nil)
            canvasPageViews[id]?.value?.setLiveDrawingActive(false)

            if let page = canvasPages[id] {
                if deferredDrawingChangeNotifications.remove(page.id) != nil {
                    canvasPageViews[id]?.value?.drawingDidChange()
                }
                if containerView?.isContinuousCanvas(canvasView) == true,
                   (containerView?.continuousPageIDs.contains(where: dirtyPageIDs.contains) == true) {
                    scheduleContinuousDrawingSave(canvasView)
                    publishUndoRedoAvailability()
                } else if dirtyPageIDs.contains(page.id) {
                    scheduleDrawingSave(for: page, canvasView: canvasView)
                    publishUndoRedoAvailability()
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
                let pageIDs = registeredPageIDsByCanvasID[canvasID]
                    ?? Set(containerView?.continuousPageIDs ?? [])
                if let error = unavailableDrawingError(for: pageIDs) {
                    notifySaveFailed(error)
                    return []
                }
                guard let continuousSnapshots = containerView?.continuousPageDrawings(
                    from: canvasView.drawing
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
                    hasUnreportedDrawingChange = drawing.dataRepresentation() != loadedData
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
            containerView.dismissNativeCanvasEditMenus()
            DispatchQueue.main.async { [weak containerView] in
                containerView?.dismissNativeCanvasEditMenus()
            }

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
