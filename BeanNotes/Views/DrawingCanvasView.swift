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
    case remove
}

@MainActor
enum DrawingCanvasStaticContentSignature {
    static func signature(for page: NotePage) -> String {
        let attachments = page.imageAttachments
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
        return [
            attachment.id.uuidString,
            attachment.storedFileName,
            attachment.vectorSourceStoredFileName ?? "",
            attachment.vectorSourcePageIndex.map(String.init) ?? "",
            "\(attachment.isLocked)",
            "\(attachment.rendersBehindDrawing)",
            origin,
            size
        ].joined(separator: ":")
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
    var drawingChanged: (UUID) -> Void
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
        containerView.restoreViewport(initialViewport)
        context.coordinator.configureToolPicker(mode: paletteMode)

        return containerView
    }

    func updateUIView(_ containerView: CanvasContainerView, context: Context) {
        let newPageIDs = Set(pages.map(\.id))
        if context.coordinator.pageIDs != newPageIDs {
            context.coordinator.saveAllCanvases()
            context.coordinator.pageIDs = newPageIDs
        }

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

    static func dismantleUIView(_ containerView: CanvasContainerView, coordinator: Coordinator) {
        coordinator.publishCurrentViewport()
        coordinator.performFinalDrawingFlush(reason: "Editor closed")
        coordinator.hideToolPicker()
        coordinator.removePencilInteraction()
        containerView.cancelPendingRenderingWork()
        containerView.releaseAllMaterializedPages(flushDrawingsBeforeRelease: false)
        coordinator.containerView = nil
    }

    final class CanvasContainerView: UIView, UIScrollViewDelegate {
        let scrollView = UIScrollView()
        let contentView = UIView()
        let addPageFooterButton = UIButton(type: .system)

        var visiblePageChanged: ((UUID) -> Void)?
        var viewportChanged: ((DrawingCanvasViewport, Bool) -> Void)?
        var addPageRequested: (() -> Void)?

        private var pageViews: [UUID: PageCanvasView] = [:]
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

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        var activeCanvasView: PKCanvasView? {
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
            orderedPageIDs.compactMap { id in
                guard let pageView = pageViews[id], let page = pageView.page else { return nil }
                return (page, pageView.canvasView)
            }
        }

        func setActiveDrawingPage(id: UUID?) {
            activeDrawingPageID = id
        }

        func setTopContentView(_ view: UIView?) {
            if topContentView !== view {
                topContentView?.removeFromSuperview()
                topContentView = view

                if let view {
                    view.backgroundColor = .clear
                    contentView.addSubview(view)
                }
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
            self.pageFlowMode = pageFlowMode
            self.inputMode = inputMode
            self.renderQuality = renderQuality
            self.theme = theme
            self.showsBeanArtwork = showsBeanArtwork
            self.selectedPageID = selectedPageID ?? pages.first?.id
            self.drawingStorage = drawingStorage
            self.coordinator = coordinator
            scrollView.panGestureRecognizer.minimumNumberOfTouches = inputMode == .anyInput ? 2 : 1
            let nextSignature = DrawingCanvasLayoutSignature(
                pages: pages,
                pageFlowMode: pageFlowMode,
                hasTopContent: topContentView != nil
            )
            let shouldRelayout = nextSignature != layoutConfigurationSignature
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

            if inputModeChanged {
                applyInputModeToMaterializedPages()
            }
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
            programmaticScrollTargetID = pageID
            programmaticScrollTargetOffset = nil
        }

        func scrollToPage(id: UUID, animated: Bool) {
            guard let frame = pageFrames[id], scrollView.bounds != .zero else {
                programmaticScrollTargetID = nil
                programmaticScrollTargetOffset = nil
                return
            }
            selectedPageID = id
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
            scrollView.setContentOffset(clampedTarget, animated: shouldAnimate)
            if !shouldAnimate {
                cancelProgrammaticPageSelection()
            }
            materializePagesNearViewport()
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
            setUserScrolling(false)
            centerDocument()
            updateRasterScale(force: true)
            materializePagesNearViewport(updatesRenderScale: false)
            updateNativeDrawingViewports(force: true)
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
            programmaticScrollTargetID = nil
            programmaticScrollTargetOffset = nil
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
            setUserScrolling(false)
            materializePagesNearViewport()
            updateNativeDrawingViewports(force: true)
            publishViewport(force: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            setUserScrolling(false)
            materializePagesNearViewport()
            updateNativeDrawingViewports(force: true)
            publishViewport(force: true)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            if programmaticScrollTargetID != nil,
               programmaticScrollTargetOffset == nil {
                return
            }
            if let targetOffset = programmaticScrollTargetOffset {
                let distance = hypot(
                    targetOffset.x - scrollView.contentOffset.x,
                    targetOffset.y - scrollView.contentOffset.y
                )
                guard distance <= 0.5 else { return }
            }
            cancelProgrammaticPageSelection()
            guard !isProgrammaticZooming else { return }
            setUserScrolling(false)
            materializePagesNearViewport()
            updateNativeDrawingViewports(force: true)
            publishViewport(force: true)
        }

        private func configureView() {
            backgroundColor = .systemGroupedBackground

            scrollView.delegate = self
            scrollView.backgroundColor = .clear
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = true
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
        }

        private func materializePagesNearViewport(
            updatesRenderScale: Bool = true,
            refreshesExistingPages: Bool = false
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

            // The selected page owns the active PencilKit canvas. It must never be retired
            // merely because UIScrollView briefly reports an offset outside the preload
            // rectangle while a touch, pinch, or inset adjustment is in progress.
            // Releasing it clears PKCanvasView's in-memory drawing and makes ink vanish.
            if let selectedPageID {
                neededIDs.insert(selectedPageID)
            }
            if let activeDrawingPageID {
                neededIDs.insert(activeDrawingPageID)
            }

            if neededIDs.isEmpty, let firstID = selectedPageID ?? orderedPageIDs.first {
                neededIDs.insert(firstID)
            }

            var didChangeMaterializedPages = false

            for id in neededIDs {
                let shouldLoadImages = pageFrame(id: id, intersects: imageActiveRect)
                if materializePageView(
                    id: id,
                    drawingStorage: drawingStorage,
                    coordinator: coordinator,
                    shouldLoadImages: shouldLoadImages,
                    updatesImageLoadingState: !defersHeavyImageWork,
                    refreshesExistingPage: refreshesExistingPages
                ) {
                    didChangeMaterializedPages = true
                }
            }

            if !defersHeavyImageWork {
                let retiredIDs = pageViews.keys.filter { !neededIDs.contains($0) }
                for id in retiredIDs {
                    if isUserScrolling, coordinator.hasPendingDrawingWork(for: id) {
                        continue
                    }
                    if let pageView = pageViews[id] {
                        retirePageView(id: id, pageView: pageView)
                        didChangeMaterializedPages = true
                    }
                }

                updateImageLoading(in: imageActiveRect)
            }

            if updatesRenderScale {
                updateRasterScale(
                    force: didChangeMaterializedPages,
                    reloadImageVariants: !defersHeavyImageWork
                )
            }

            if didChangeMaterializedPages {
                updateNativeDrawingViewports(force: true)
            }
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
                    canRemovePage: orderedPageIDs.count > 1,
                    pageActionRequested: { [weak coordinator] pageID, action in
                        coordinator?.requestPageAction(action, for: pageID)
                    },
                    pageContextMenuWillOpen: { [weak coordinator] pageID in
                        coordinator?.selectPageForContextMenu(pageID)
                    }
                )
            }
            pageView.setDocumentTraversalActive(isUserScrolling)

            return didCreatePageView
        }

        private func applyInputModeToMaterializedPages() {
            for pageView in pageViews.values {
                pageView.applyInputMode(inputMode)
            }
        }

        func releaseAllMaterializedPages(flushDrawingsBeforeRelease: Bool = true) {
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
            if let page = pageView.page {
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
            updateRasterScale(force: true)
        }

        func cancelPendingRenderingWork() {
            settledZoomWorkItem?.cancel()
            settledZoomWorkItem = nil
            isPinchZooming = false
            isProgrammaticZooming = false
            programmaticZoomEarliestFinishTime = 0
            cancelProgrammaticPageSelection()
            setUserScrolling(false)

            for pageView in pageViews.values {
                pageView.cancelPendingNativeViewportUpdate()
            }
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
            programmaticScrollTargetID = nil
            programmaticScrollTargetOffset = nil
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
            case ended(CGPoint)
            case cancelled
        }

        private enum InteractionPhase {
            case began
            case moved
            case ended
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
            publish(.began, for: touch)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let trackedTouch,
                  touches.contains(where: { $0 === trackedTouch }) else { return }
            state = .changed
            let samples = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
            for touch in samples {
                publish(.moved, for: touch)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finishIfTracking(touches, state: .ended)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finishIfTracking(touches, state: .cancelled)
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

        private func finishIfTracking(_ touches: Set<UITouch>, state finalState: State) {
            guard let trackedTouch,
                  touches.contains(where: { $0 === trackedTouch }) else { return }
            switch finalState {
            case .ended:
                publish(.ended, for: trackedTouch)
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

        private func publish(_ phase: InteractionPhase, for touch: UITouch) {
            guard let coordinateView else {
                interactionChanged?(.cancelled)
                return
            }
            let location = touch.location(in: coordinateView)
            currentLocation = location
            switch phase {
            case .began:
                interactionChanged?(.began(location))
            case .moved:
                interactionChanged?(.moved(location))
            case .ended:
                interactionChanged?(.ended(location))
            }
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
                let expandedStrokeBounds = stroke.renderBounds.insetBy(
                    dx: -(radius + edgeTolerance),
                    dy: -(radius + edgeTolerance)
                )
                guard expandedStrokeBounds.intersects(sweepBounds) else { continue }

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
            let horizontalScale = hypot(transform.a, transform.c)
            let verticalScale = hypot(transform.b, transform.d)
            let scale = max(horizontalScale, verticalScale)
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

    final class EraserScopeView: UIView {
        static let objectEraserDiameter: CGFloat = 12

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
            bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            center = location
            layer.cornerRadius = diameter / 2
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
        let canvasView = PKCanvasView(frame: .zero)
        let foregroundImageContainerView = UIView(frame: .zero)
        let eraserScopeView = EraserScopeView(frame: .zero)

        private var imageViews: [UUID: AttachmentImageContainerView] = [:]
        private let eraserScopeGesture = EraserScopeGestureRecognizer()
        private(set) var attachmentSelectionGesture: UITapGestureRecognizer?
        private var attachmentEditingOverlay: AttachmentEditingOverlayView?
        private(set) var page: NotePage?
        private(set) var selectedAttachmentID: UUID?
        private var configurationSignature: String?
        private var attachmentChanged: (() -> Void)?
        private var deleteAttachment: ((Attachment) -> Void)?
        private var pageActionRequested: ((UUID, NotePageContextAction) -> Void)?
        private var pageContextMenuWillOpen: ((UUID) -> Void)?
        private var canRemovePage = false
        private(set) lazy var pageActionMenuInteraction = UIEditMenuInteraction(delegate: self)
        private(set) var pageActionLongPressGesture: UILongPressGestureRecognizer?
        private var hasConfiguredImageAttachments = false
        private var lastBackgroundScale: CGFloat = 0
        private var lastImageScale: CGFloat = 0
        private var isImageLoadingEnabled = true
        private var isDocumentTraversalActive = false
        private var appliedInputMode: DrawingInputMode?
        private var isUsingDrawingTool = false
        private var eraserPreviewDiameter: CGFloat?
        private var usesCustomObjectEraser = false
        private var objectEraserPath = ObjectEraserPathAccumulator()
        private var isTrackingObjectEraser = false
        private var objectEraserInitialDrawing: PKDrawing?
        private var objectEraserHasChanges = false
        private var laidOutPageBounds: CGRect = .null
        private var activeDrawingViewportRect: CGRect = .null
        private var nativeZoomScale: CGFloat = 1
        private var pendingNativeViewport: NativeViewportRequest?

        var objectEraserDidBegin: (() -> Void)?
        var objectEraserDidEnd: (() -> Void)?
        var objectEraserDrawingChanged: (() -> Void)?

        var currentNativeDrawingZoomScale: CGFloat {
            nativeZoomScale
        }

        var isUsingCustomObjectEraser: Bool {
            usesCustomObjectEraser
        }

        var consumesBlankCanvasTaps: Bool {
            appliedInputMode == .pencilOnly && !(canvasView.tool is PKLassoTool)
        }

        var allowsPageActionLongPress: Bool {
            !(canvasView.tool is PKLassoTool)
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
            canRemovePage: Bool = false,
            pageActionRequested: @escaping (UUID, NotePageContextAction) -> Void = { _, _ in },
            pageContextMenuWillOpen: @escaping (UUID) -> Void = { _ in }
        ) {
            let isNewPage = self.page?.id != page.id
            let signature = "\(staticContentSignature(for: page))#theme=\(theme.rawValue)#beanArtwork=\(showsBeanArtwork)"
            let needsStaticRefresh = isNewPage || signature != configurationSignature
            let pageSizeChanged = laidOutPageBounds.size != page.pageSize
            if isNewPage {
                clearAttachmentSelection()
                hasConfiguredImageAttachments = false
            }
            self.page = page
            accessibilityIdentifier = "notePageCanvas"
            accessibilityLabel = "Page \(page.pageOrder + 1) canvas"
            self.attachmentChanged = attachmentChanged
            self.deleteAttachment = deleteAttachment
            self.canRemovePage = canRemovePage
            self.pageActionRequested = pageActionRequested
            self.pageContextMenuWillOpen = pageContextMenuWillOpen

            applyInputMode(inputMode)
            if !isNewPage, !needsStaticRefresh, !pageSizeChanged {
                return
            }

            if needsStaticRefresh {
                backgroundView.background = page.background
                backgroundView.theme = theme
                backgroundView.showsBeanArtwork = showsBeanArtwork
                backgroundView.pageID = page.id
                backgroundView.setNeedsDisplay()
                configureImages(page.imageAttachments, storage: storage, attachmentChanged: attachmentChanged)
                configurationSignature = signature
            }

            if isNewPage {
                resetNativeCanvas(pageSize: page.pageSize)
                canvasView.drawing = drawingStorage.loadDrawing(for: page)
            } else if pageSizeChanged {
                resetNativeCanvas(pageSize: page.pageSize)
            }

            canvasView.delegate = coordinator
            coordinator.register(canvasView: canvasView, page: page, pageView: self)

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
            // a recycled page cannot remain permanently non-interactive. Custom object
            // erasing owns this recognizer's input while it performs whole-stroke hits.
            canvasView.isUserInteractionEnabled = true
            canvasView.drawingGestureRecognizer.isEnabled = !usesCustomObjectEraser
            guard canvasView.drawingPolicy != inputMode.drawingPolicy else { return }
            canvasView.drawingPolicy = inputMode.drawingPolicy
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

        private func staticContentSignature(for page: NotePage) -> String {
            DrawingCanvasStaticContentSignature.signature(for: page)
        }

        func layoutPage() {
            guard let page else { return }
            let pageBounds = CGRect(origin: .zero, size: page.pageSize)

            if laidOutPageBounds != pageBounds {
                backgroundView.frame = pageBounds
                behindImageContainerView.frame = pageBounds
                foregroundImageContainerView.frame = pageBounds
                layer.shadowPath = UIBezierPath(rect: pageBounds).cgPath
                laidOutPageBounds = pageBounds
            }

            for attachment in page.imageAttachments {
                imageViews[attachment.id]?.frame = attachment.normalizedFrame(for: page.pageSize)
            }

            if let selectedAttachmentID,
               let selectedAttachment = page.imageAttachments.first(where: { $0.id == selectedAttachmentID }) {
                attachmentEditingOverlay?.updateFrame(
                    selectedAttachment.normalizedFrame(for: page.pageSize),
                    pageSize: page.pageSize
                )
            }
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

        func makePageContextMenu(for pageID: UUID, canRemovePage: Bool) -> UIMenu {
            let remove = UIAction(
                title: "Remove This Page",
                image: UIImage(systemName: "trash"),
                attributes: canRemovePage ? [.destructive] : [.destructive, .disabled]
            ) { [weak self] _ in
                self?.pageActionRequested?(pageID, .remove)
            }

            return UIMenu(children: [remove])
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard interaction === pageActionMenuInteraction, let pageID = page?.id else { return nil }
            return makePageContextMenu(for: pageID, canRemovePage: canRemovePage)
        }

        @objc private func handlePageActionLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer === pageActionLongPressGesture,
                  recognizer.state == .began,
                  let pageID = page?.id else {
                return
            }

            clearAttachmentSelection()
            dismissCanvasEditMenus()
            pageContextMenuWillOpen?(pageID)
            let configuration = UIEditMenuConfiguration(
                identifier: pageID as NSUUID,
                sourcePoint: recognizer.location(in: self)
            )
            pageActionMenuInteraction.presentEditMenu(with: configuration)
            DispatchQueue.main.async { [weak self] in
                self?.dismissCanvasEditMenus()
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
            guard let page else { return }
            let pageBounds = CGRect(origin: .zero, size: page.pageSize)
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
            guard !isUsingDrawingTool else { return }
            pendingNativeViewport = nil
            drawingViewportView.isHidden = true
        }

        func cancelPendingNativeViewportUpdate() {
            pendingNativeViewport = nil
        }

        func reduceDrawingMemoryFootprint() {
            guard let page, !isUsingDrawingTool else { return }
            resetNativeCanvas(pageSize: page.pageSize)
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
            guard let page else { return }
            let pageBounds = CGRect(origin: .zero, size: page.pageSize)
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

        private func resetNativeCanvas(pageSize: CGSize) {
            guard pageSize.width > 0, pageSize.height > 0 else { return }
            pendingNativeViewport = nil

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
            canvasView.bounds = CGRect(origin: .zero, size: pageSize)
            canvasView.center = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
            canvasView.contentOffset = .zero

            drawingViewportView.frame = CGRect(origin: .zero, size: pageSize)
            drawingViewportView.bounds = CGRect(origin: .zero, size: pageSize)
            drawingViewportView.isHidden = false
            nativeZoomScale = 1
            activeDrawingViewportRect = CGRect(origin: .zero, size: pageSize)
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

                let imageContainer = attachment.rendersBehindDrawing
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
                let vectorSource = resolvedVectorSource(for: attachment, storage: storage)
                imageView.configure(
                    attachment: attachment,
                    storage: storage,
                    pageSize: page?.pageSize ?? .zero,
                    vectorSourceURL: vectorSource?.url,
                    vectorPageIndex: vectorSource?.pageIndex,
                    changed: attachmentChanged
                )
                imageView.frame = attachment.normalizedFrame(for: page?.pageSize)
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
            dismissCanvasEditMenus()
            DispatchQueue.main.async { [weak self] in
                self?.dismissCanvasEditMenus()
            }
        }

        private func dismissCanvasEditMenus() {
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
            guard let attachment = page?.imageAttachments.first(where: { $0.id == id && !$0.isLocked }) else {
                clearAttachmentSelection()
                return
            }

            beginEditingAttachment(attachment)
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
            bringSubviewToFront(overlay)
        }

        func clearAttachmentSelection() {
            selectedAttachmentID = nil
            attachmentEditingOverlay?.removeFromSuperview()
            attachmentEditingOverlay = nil
        }

        private func topmostEditableAttachment(at point: CGPoint) -> Attachment? {
            guard let page else { return nil }
            let attachments = page.imageAttachments.filter { !$0.isLocked }
            let foreground = attachments.filter { !$0.rendersBehindDrawing }.reversed()
            let background = attachments.filter(\.rendersBehindDrawing).reversed()

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

            if gestureRecognizer === pageActionLongPressGesture {
                return allowsPageActionLongPress
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
            case .ended(let location):
                appendObjectEraserLocation(location, force: true)
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

            let diameter = eraserTool.width > 0
                ? eraserTool.width
                : eraserPreviewDiameter ?? EraserScopeView.objectEraserDiameter
            eraserScopeView.show(at: location, diameter: diameter)
            bringSubviewToFront(eraserScopeView)
        }

        func setEraserPreviewEnabled(
            _ enabled: Bool,
            diameter: CGFloat? = nil,
            usesCustomObjectEraser: Bool = false
        ) {
            eraserPreviewDiameter = diameter
            let shouldUseCustomObjectEraser = enabled && usesCustomObjectEraser
            if self.usesCustomObjectEraser != shouldUseCustomObjectEraser {
                if !shouldUseCustomObjectEraser {
                    finishObjectEraser(committing: false)
                }
                self.usesCustomObjectEraser = shouldUseCustomObjectEraser
            }

            canvasView.drawingGestureRecognizer.isEnabled = !shouldUseCustomObjectEraser
            if eraserScopeGesture.isEnabled != enabled {
                eraserScopeGesture.isEnabled = enabled
            }
            if !enabled {
                eraserScopeView.hide()
            }
        }

        private func beginObjectEraser(at location: CGPoint) {
            guard usesCustomObjectEraser,
                  location.x.isFinite,
                  location.y.isFinite,
                  !isTrackingObjectEraser else {
                return
            }

            isTrackingObjectEraser = true
            objectEraserPath.begin(at: location)
            objectEraserInitialDrawing = canvasView.drawing
            objectEraserHasChanges = false
            canvasView.becomeFirstResponder()
            objectEraserDidBegin?()
            eraseObjectsLive(along: [location])
        }

        private func appendObjectEraserLocation(_ location: CGPoint, force: Bool = false) {
            guard isTrackingObjectEraser,
                  location.x.isFinite,
                  location.y.isFinite else {
                return
            }

            // Coalesced Pencil samples can be much denser than the eraser radius. Keeping
            // points apart by a small fraction of that radius bounds whole-stroke hit-testing
            // work on long gestures. The accumulator retains the touch-down point and final
            // endpoint, so slow movement cannot leave an early part of the sweep behind.
            guard let previousLocation = objectEraserPath.points.last else { return }
            let diameter = eraserPreviewDiameter ?? EraserScopeView.objectEraserDiameter
            let minimumSpacing = max(diameter / 4, 1)
            let previousPointCount = objectEraserPath.points.count
            objectEraserPath.append(location, minimumSpacing: minimumSpacing, force: force)
            guard objectEraserPath.points.count > previousPointCount,
                  let currentLocation = objectEraserPath.points.last else {
                return
            }
            eraseObjectsLive(along: [previousLocation, currentLocation])
        }

        private func finishObjectEraser(committing: Bool) {
            guard isTrackingObjectEraser else { return }
            defer {
                isTrackingObjectEraser = false
                objectEraserPath.reset()
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
                objectEraserDrawingChanged?()
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
            guard let diameter = eraserPreviewDiameter,
                  diameter.isFinite,
                  diameter > 0,
                  let drawing = drawingByErasingObjects(
                    along: eraserPath,
                    diameter: diameter,
                    from: canvasView.drawing
                  ) else {
                return
            }

            canvasView.drawing = drawing
            objectEraserHasChanges = true
            objectEraserDrawingChanged?()
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

        private func replaceObjectEraserDrawing(_ drawing: PKDrawing, undoDrawing: PKDrawing) {
            registerObjectEraserUndo(undoDrawing: undoDrawing, redoDrawing: drawing)
            canvasView.drawing = drawing
            objectEraserDrawingChanged?()
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
            insertSubview(foregroundImageContainerView, aboveSubview: drawingViewportView)

            if let attachmentEditingOverlay {
                bringSubviewToFront(attachmentEditingOverlay)
            }
            bringSubviewToFront(eraserScopeView)
        }

        func releaseHeavyResources(evictCachedImages: Bool = false) {
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

        private var tiledLayer: CATiledLayer {
            layer as! CATiledLayer
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
            stateLock.unlock()
            tiledLayer.setNeedsDisplay()
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
            stateLock.unlock()
            tiledLayer.setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), !bounds.isEmpty else { return }

            renderLock.lock()
            defer { renderLock.unlock() }

            stateLock.lock()
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
            tiledLayer.levelsOfDetail = 3
            tiledLayer.levelsOfDetailBias = 3
            tiledLayer.drawsAsynchronously = true
            tiledLayer.contentsScale = UIScreen.main.scale
            contentScaleFactor = UIScreen.main.scale
        }
    }

    final class AttachmentEditingOverlayView: UIView, UIGestureRecognizerDelegate {
        private let outerBorderView = UIView()
        private let innerBorderView = UIView()
        private let moveHandle = UIButton(type: .custom)
        private let resizeHandle = UIButton(type: .custom)
        private let deleteButton = UIButton(type: .custom)
        private let doneButton = UIButton(type: .custom)
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var dragStart: CGRect?
        private var resizeStart: CGRect?
        private var frameChanged: ((CGRect) -> Void)?
        private var changeCommitted: (() -> Void)?
        private var deleteRequested: (() -> Void)?
        private var dismiss: (() -> Void)?
        private(set) var editingPanGestureRecognizers: [UIPanGestureRecognizer] = []

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
            updateFrame(attachment.normalizedFrame(for: pageSize), pageSize: pageSize)

            moveHandle.accessibilityLabel = "Move \(attachment.displayName)"
            moveHandle.accessibilityHint = "Drag to reposition the image on the page"
            resizeHandle.accessibilityLabel = "Resize \(attachment.displayName)"
            resizeHandle.accessibilityHint = "Drag to resize the image proportionally"
            deleteButton.accessibilityLabel = "Delete \(attachment.displayName)"
            deleteButton.accessibilityHint = "Removes the image after confirmation"
            doneButton.accessibilityLabel = "Finish editing \(attachment.displayName)"
        }

        func updateFrame(_ frame: CGRect, pageSize: CGSize) {
            self.pageSize = pageSize
            self.frame = frame
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            outerBorderView.frame = bounds
            innerBorderView.frame = bounds.insetBy(dx: 1, dy: 1)
            let controlSize: CGFloat = 44
            let horizontalInset = min(4, max((bounds.width - controlSize * 2) / 2, 0))
            let verticalInset = min(4, max((bounds.height - controlSize * 2) / 2, 0))
            let trailingX = bounds.maxX - horizontalInset - controlSize
            let bottomY = bounds.maxY - verticalInset - controlSize
            moveHandle.frame = CGRect(
                x: horizontalInset,
                y: verticalInset,
                width: controlSize,
                height: controlSize
            )
            doneButton.frame = CGRect(
                x: trailingX,
                y: verticalInset,
                width: controlSize,
                height: controlSize
            )
            deleteButton.frame = CGRect(
                x: horizontalInset,
                y: bottomY,
                width: controlSize,
                height: controlSize
            )
            resizeHandle.frame = CGRect(
                x: trailingX,
                y: bottomY,
                width: controlSize,
                height: controlSize
            )
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if event?.allTouches?.contains(where: { $0.type == .pencil }) == true {
                return nil
            }

            let interactiveControls = [moveHandle, resizeHandle, deleteButton, doneButton]
            guard interactiveControls.contains(where: {
                $0.frame.contains(point) && !$0.isHidden && $0.alpha > 0.01
            }) else {
                return nil
            }

            return super.hitTest(point, with: event)
        }

        private func configureView() {
            backgroundColor = .clear
            clipsToBounds = false

            outerBorderView.isUserInteractionEnabled = false
            outerBorderView.backgroundColor = .clear
            outerBorderView.layer.borderWidth = 4
            outerBorderView.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.92).cgColor
            addSubview(outerBorderView)

            innerBorderView.isUserInteractionEnabled = false
            innerBorderView.backgroundColor = .clear
            innerBorderView.layer.borderWidth = 2
            innerBorderView.layer.borderColor = UIColor.systemBlue.cgColor
            addSubview(innerBorderView)

            configureHandle(
                moveHandle,
                systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                backgroundColor: .systemBlue
            )
            moveHandle.accessibilityCustomActions = [
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
                }
            ]
            addSubview(moveHandle)

            configureHandle(
                resizeHandle,
                systemImage: "arrow.up.left.and.arrow.down.right",
                backgroundColor: UIColor.black.withAlphaComponent(0.72)
            )
            resizeHandle.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Increase size") { [weak self] _ in
                    self?.resize(by: CGPoint(x: 16, y: 16)) ?? false
                },
                UIAccessibilityCustomAction(name: "Decrease size") { [weak self] _ in
                    self?.resize(by: CGPoint(x: -16, y: -16)) ?? false
                }
            ]
            addSubview(resizeHandle)

            configureHandle(
                deleteButton,
                systemImage: "trash",
                backgroundColor: UIColor.systemRed.withAlphaComponent(0.94)
            )
            deleteButton.addTarget(self, action: #selector(requestDeletion), for: .touchUpInside)
            addSubview(deleteButton)

            configureHandle(
                doneButton,
                systemImage: "checkmark",
                backgroundColor: UIColor.systemGreen.withAlphaComponent(0.94)
            )
            doneButton.addTarget(self, action: #selector(finishEditing), for: .touchUpInside)
            addSubview(doneButton)

            let moveGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
            moveGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            moveGesture.maximumNumberOfTouches = 1
            moveGesture.cancelsTouchesInView = false
            moveGesture.delegate = self
            moveHandle.addGestureRecognizer(moveGesture)
            editingPanGestureRecognizers.append(moveGesture)

            let resizeGesture = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            resizeGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            resizeGesture.maximumNumberOfTouches = 1
            resizeGesture.cancelsTouchesInView = false
            resizeGesture.delegate = self
            resizeHandle.addGestureRecognizer(resizeGesture)
            editingPanGestureRecognizers.append(resizeGesture)
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
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard editingPanGestureRecognizers.contains(where: { $0 === gestureRecognizer }),
                  let scrollView = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scrollView.panGestureRecognizer else {
                return false
            }

            // Give a selected image's move/resize handles priority over an ancestor
            // document scroll without ever disabling the document pan recognizer.
            return isDescendant(of: scrollView)
        }

        @objc private func finishEditing() {
            dismiss?()
        }

        @objc private func requestDeletion() {
            deleteRequested?()
        }

        @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
            guard let attachment else {
                dragStart = nil
                return
            }

            switch recognizer.state {
            case .began:
                dragStart = attachment.normalizedFrame(for: pageSize)
            case .changed:
                guard let dragStart else { return }
                apply(AttachmentEditingGeometry.movedFrame(
                    from: dragStart,
                    translation: recognizer.translation(in: superview),
                    pageSize: pageSize
                ))
            case .ended:
                commitChange(startingAt: dragStart)
                dragStart = nil
            case .cancelled, .failed:
                if let dragStart {
                    apply(dragStart)
                }
                dragStart = nil
            default:
                break
            }
        }

        @objc private func handleResize(_ recognizer: UIPanGestureRecognizer) {
            guard let attachment else {
                resizeStart = nil
                return
            }

            switch recognizer.state {
            case .began:
                resizeStart = attachment.normalizedFrame(for: pageSize)
            case .changed:
                guard let resizeStart else { return }
                apply(AttachmentEditingGeometry.resizedFrame(
                    from: resizeStart,
                    translation: recognizer.translation(in: superview),
                    pageSize: pageSize
                ))
            case .ended:
                commitChange(startingAt: resizeStart)
                resizeStart = nil
            case .cancelled, .failed:
                if let resizeStart {
                    apply(resizeStart)
                }
                resizeStart = nil
            default:
                break
            }
        }

        private func nudge(by translation: CGPoint) -> Bool {
            guard let attachment else { return false }
            let startFrame = attachment.normalizedFrame(for: pageSize)
            apply(AttachmentEditingGeometry.movedFrame(
                from: startFrame,
                translation: translation,
                pageSize: pageSize
            ))
            commitChange(startingAt: startFrame)
            return true
        }

        private func resize(by translation: CGPoint) -> Bool {
            guard let attachment else { return false }
            let startFrame = attachment.normalizedFrame(for: pageSize)
            apply(AttachmentEditingGeometry.resizedFrame(
                from: startFrame,
                translation: translation,
                pageSize: pageSize
            ))
            commitChange(startingAt: startFrame)
            return true
        }

        private func apply(_ frame: CGRect) {
            guard let attachment else { return }
            attachment.x = Double(frame.minX)
            attachment.y = Double(frame.minY)
            attachment.width = Double(frame.width)
            attachment.height = Double(frame.height)
            self.frame = frame
            frameChanged?(frame)
        }

        private func commitChange(startingAt startFrame: CGRect?) {
            guard let attachment, let startFrame,
                  attachment.normalizedFrame(for: pageSize) != startFrame else {
                return
            }

            attachment.touch()
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
        private let pdfPageView = PDFPageTiledView()
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var imageURL: URL?
        private var vectorPDFURL: URL?
        private var vectorPDFPageIndex: Int?
        private var loadedStoredFileName: String?
        private var loadedFileIdentity: String?
        private var loadedRasterBudget: AttachmentImageRasterBudget?
        private var loadingStoredFileName: String?
        private var loadingFileIdentity: String?
        private var loadingRasterBudget: AttachmentImageRasterBudget?
        private var imageLoadRequestID: UUID?
        private var imageLoadToken: ImageLoadToken?
        private var currentRenderScale: CGFloat = 0
        private var isImageLoadingEnabled = true
        private var isDocumentTraversalActive = false

        var isRasterImageLoaded: Bool {
            imageView.image != nil
        }

        var isVectorPDFVisible: Bool {
            !pdfPageView.isHidden
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
                self.imageURL = imageURL
                if isImageLoadingEnabled {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                } else {
                    releaseImage()
                }
            } else {
                self.imageURL = nil
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
                if isImageLoadingEnabled {
                    pdfPageView.configure(url: vectorURL, pageIndex: pageIndex)
                }
            } else {
                vectorPDFURL = nil
                vectorPDFPageIndex = nil
                pdfPageView.isHidden = true
                pdfPageView.releaseDocument()
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
            pdfPageView.frame = bounds
        }

        private func configureView() {
            clipsToBounds = true
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)

            pdfPageView.isHidden = true
            addSubview(pdfPageView)
        }

        func updateRasterScale(_ scale: CGFloat, reloadImageVariant: Bool = true) {
            contentScaleFactor = scale
            layer.contentsScale = scale
            imageView.contentScaleFactor = scale
            imageView.layer.contentsScale = scale
            pdfPageView.updateRenderScale(scale)
            currentRenderScale = scale

            guard reloadImageVariant, isImageLoadingEnabled, let imageURL, let attachment else { return }
            loadImageIfNeeded(from: imageURL, attachment: attachment)
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            if enabled {
                if let vectorPDFURL, let vectorPDFPageIndex {
                    pdfPageView.configure(url: vectorPDFURL, pageIndex: vectorPDFPageIndex)
                }
                if let imageURL, let attachment {
                    loadImageIfNeeded(from: imageURL, attachment: attachment)
                }
            } else {
                releaseRasterImage()
                pdfPageView.releaseDocument()
            }
            updateVectorPDFVisibility()
        }

        func setDocumentTraversalActive(_ active: Bool) {
            guard isDocumentTraversalActive != active else { return }
            isDocumentTraversalActive = active
            updateVectorPDFVisibility()
        }

        private func loadImageIfNeeded(from imageURL: URL, attachment: Attachment) {
            guard isImageLoadingEnabled else { return }

            let budget = AttachmentImageRasterBudget(
                attachmentSize: attachment.normalizedFrame(for: pageSize).size,
                renderScale: currentRenderScale
            )
            let storedFileName = attachment.storedFileName
            let fileIdentity = Self.fileIdentity(for: imageURL)
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
                        maxPixelSize: maxPixelSize
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
            releaseRasterImage(evictCachedVariants: evictCachedVariants)
            pdfPageView.releaseDocument()
        }

        private func releaseRasterImage(evictCachedVariants: Bool = false) {
            cancelPendingImageLoad(evictCachedVariantsAfterDecode: evictCachedVariants)
            if evictCachedVariants, let imageURL {
                ImageMemoryCache.shared.removeImages(for: imageURL)
            }
            imageView.image = nil
            loadedStoredFileName = nil
            loadedFileIdentity = nil
            loadedRasterBudget = nil
            updateVectorPDFVisibility()
        }

        private func updateVectorPDFVisibility() {
            let hasVectorSource = vectorPDFURL != nil && vectorPDFPageIndex != nil
            let usesRasterWhileTraversing = isDocumentTraversalActive && imageView.image != nil
            pdfPageView.isHidden = !hasVectorSource
                || !isImageLoadingEnabled
                || usesRasterWhileTraversing
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

        private static func fileIdentity(for url: URL) -> String {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(modified)|\(size)"
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
        var pageIDs: Set<UUID>
        var toolPicker = PKToolPicker()
        var pendingSaves: [UUID: DispatchWorkItem] = [:]
        var pendingSaveTokens: [UUID: UUID] = [:]
        var inFlightSaveTokens: [UUID: Set<UUID>] = [:]
        var registeredCanvasIDs: Set<ObjectIdentifier> = []
        private var toolPickerObservedCanvasIDs: Set<ObjectIdentifier> = []
        var dirtyPageIDs: Set<UUID> = []
        private var activeToolCanvasIDs: Set<ObjectIdentifier> = []
        private var deferredExportPreparationRequestID: Int?
        private var deferredDrawingChangeNotifications: Set<UUID> = []
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
        private let drawingSaveDebounce: TimeInterval = 1.25
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

        func requestPageAction(_ action: NotePageContextAction, for pageID: UUID) {
            let pageActionRequested = parent.pageActionRequested
            dispatchToSwiftUI {
                pageActionRequested(pageID, action)
            }
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
                      !self.hasAnyInFlightSaves else { return }
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
            self.pageIDs = Set(parent.pages.map(\.id))
            super.init()
            observeApplicationLifecycle()
        }

        deinit {
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
            pageView: PageCanvasView? = nil
        ) {
            let id = ObjectIdentifier(canvasView)
            canvasPages[id] = page
            canvasPageViews[id] = WeakPageCanvasView(pageView)
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
            if flushDrawingBeforeRelease {
                flushDrawingBeforeCanvasRelease(canvasView, for: page)
            }
            pendingSaves[page.id]?.cancel()
            pendingSaves[page.id] = nil
            pendingSaveTokens[page.id] = nil
            if toolPickerObservedCanvasIDs.remove(id) != nil {
                toolPicker.removeObserver(canvasView)
            }
            registeredCanvasIDs.remove(id)
            activeToolCanvasIDs.remove(id)
            deferredDrawingChangeNotifications.remove(page.id)
            canvasPages[id] = nil
            canvasPageViews[id]?.value?.objectEraserDidBegin = nil
            canvasPageViews[id]?.value?.objectEraserDidEnd = nil
            canvasPageViews[id]?.value?.objectEraserDrawingChanged = nil
            canvasPageViews[id] = nil
            canvasToolSignatures[id] = nil
            temporaryEraserCanvasIDs.remove(id)

        }

        func hasPendingDrawingWork(for pageID: UUID) -> Bool {
            dirtyPageIDs.contains(pageID)
                || pendingSaves[pageID] != nil
                || pendingSaveTokens[pageID] != nil
                || hasInFlightSave(for: pageID)
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
            guard parent.paletteMode == .custom else { return }
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
            let previewDiameter = eraserTool.map { eraserTool in
                eraserTool.width > 0 ? eraserTool.width : parent.toolState.eraserWidth
            }
            canvasPageViews[id]?.value?.setEraserPreviewEnabled(
                eraserTool != nil,
                diameter: previewDiameter,
                usesCustomObjectEraser: eraserTool?.eraserType == .vector
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

            let didBecomeDirty = dirtyPageIDs.insert(page.id).inserted
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

        private func scheduleDrawingSave(for page: NotePage, canvasView: PKCanvasView) {
            let pageID = page.id
            let rootURL = parent.drawingStorage.storage.rootURL
            let drawingFileName = page.drawingFileName
            let token = UUID()

            pendingSaves[pageID]?.cancel()
            pendingSaveTokens[pageID] = token

            let save = DispatchWorkItem { [weak self, weak canvasView] in
                guard let self,
                      self.pendingSaveTokens[pageID] == token,
                      let canvasView else { return }

                self.pendingSaves[pageID] = nil
                self.pendingSaveTokens[pageID] = nil
                self.beginInFlightSave(pageID: pageID, token: token)

                let drawing = canvasView.drawing
                DrawingStorageService.cache(drawing, fileName: drawingFileName, rootURL: rootURL)
                Self.writeDrawing(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName,
                    onSuccess: { [weak self] in
                        self?.reportDrawingSaveSuccess(pageID: pageID, token: token)
                    },
                    onFailure: { [weak self] error in
                        self?.reportDrawingSaveFailure(error, pageID: pageID, token: token)
                    }
                )
            }

            pendingSaves[pageID] = save
            DispatchQueue.main.asyncAfter(deadline: .now() + drawingSaveDebounce, execute: save)
        }

        private func flushDrawingBeforeCanvasRelease(_ canvasView: PKCanvasView, for page: NotePage) {
            guard hasPendingDrawingWork(for: page.id) else { return }

            pendingSaves[page.id]?.cancel()
            pendingSaves[page.id] = nil
            pendingSaveTokens[page.id] = nil
            invalidateInFlightSaves(for: page.id)

            let rootURL = parent.drawingStorage.storage.rootURL
            let drawingFileName = page.drawingFileName
            let drawing = canvasView.drawing
            notifySaveStarted()
            DrawingStorageService.cache(drawing, fileName: drawingFileName, rootURL: rootURL)

            do {
                try Self.writeDrawingSynchronously(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName
                )
                page.touch()
                dirtyPageIDs.remove(page.id)
                reportDrawingSaveSuccess()
            } catch {
                dirtyPageIDs.insert(page.id)
                reportDrawingSaveFailure(error, pageID: page.id)
            }
        }

        private static func writeDrawing(
            _ drawing: PKDrawing,
            rootURL: URL,
            drawingFileName: String,
            onSuccess: @escaping () -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            drawingWriteQueue.async {
                autoreleasepool {
                    do {
                        try writeDrawingFile(drawing, rootURL: rootURL, drawingFileName: drawingFileName)
                        DispatchQueue.main.async {
                            onSuccess()
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
        ) throws {
            if DispatchQueue.getSpecific(key: drawingWriteQueueKey) != nil {
                try writeDrawingFile(drawing, rootURL: rootURL, drawingFileName: drawingFileName)
                return
            }

            var result: Result<Void, Error> = .success(())
            drawingWriteQueue.sync {
                autoreleasepool {
                    result = Result {
                        try writeDrawingFile(drawing, rootURL: rootURL, drawingFileName: drawingFileName)
                    }
                }
            }
            try result.get()
        }

        private static func writeDrawingFile(
            _ drawing: PKDrawing,
            rootURL: URL,
            drawingFileName: String
        ) throws {
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
        }

        private func reportDrawingSaveSuccess(pageID: UUID? = nil, token: UUID? = nil) {
            if let pageID {
                if let token {
                    guard finishInFlightSave(pageID: pageID, token: token) else { return }
                }

                if pendingSaves[pageID] == nil,
                   pendingSaveTokens[pageID] == nil,
                   !hasInFlightSave(for: pageID) {
                    dirtyPageIDs.remove(pageID)
                }
            }

            guard pendingSaves.isEmpty, dirtyPageIDs.isEmpty, !hasAnyInFlightSaves else { return }
            notifySaveSucceededIfClean()
        }

        private func reportDrawingSaveFailure(_ error: Error, pageID: UUID, token: UUID? = nil) {
            if let token {
                guard finishInFlightSave(pageID: pageID, token: token) else { return }
            }

            dirtyPageIDs.insert(pageID)
            notifySaveFailed(error)
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
            if parent.toolState.temporaryEraserActive {
                temporaryEraserCanvasIDs.insert(id)
            }
            if let page = canvasPages[id] {
                pendingSaves[page.id]?.cancel()
                pendingSaves[page.id] = nil
                pendingSaveTokens[page.id] = nil
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
                    notifyDrawingChanged(pageID: page.id)
                    notifySaveStarted()
                }
                if dirtyPageIDs.contains(page.id) {
                    scheduleDrawingSave(for: page, canvasView: canvasView)
                    publishUndoRedoAvailability()
                }
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
                }
            ]
        }

        private func handleMemoryWarning() {
            containerView?.reduceMemoryFootprint()
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
                    onSuccess: { [weak self] in
                        self?.reportDrawingSaveSuccess(pageID: request.page.id, token: request.token)
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
                        try Self.writeDrawingSynchronously(
                            request.drawing,
                            rootURL: request.rootURL,
                            drawingFileName: request.drawingFileName
                        )
                        request.page.touch()
                        dirtyPageIDs.remove(request.page.id)
                        savedAtLeastOneCanvas = true
                    } catch {
                        reportDrawingSaveFailure(error, pageID: request.page.id)
                    }
                } else {
                    Self.writeDrawing(
                        request.drawing,
                        rootURL: request.rootURL,
                        drawingFileName: request.drawingFileName,
                        onSuccess: { [weak self] in
                            self?.reportDrawingSaveSuccess(pageID: request.page.id, token: request.token)
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
                deferredExportPreparationRequestID = requestID
                return
            }
            deferredExportPreparationRequestID = nil

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
                    try Self.writeDrawingSynchronously(
                        request.drawing,
                        rootURL: request.rootURL,
                        drawingFileName: request.drawingFileName
                    )
                    request.page.touch()
                    dirtyPageIDs.remove(request.page.id)
                } catch {
                    dirtyPageIDs.insert(request.page.id)
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

        private func canvasSaveRequests(
            force: Bool,
            trackInFlight: Bool = true,
            invalidateInFlight: Bool = false
        ) -> [CanvasSaveRequest] {
            let pairs = containerView?.canvasPagePairs ?? []
            var requests: [CanvasSaveRequest] = []

            for (page, canvasView) in pairs {
                guard force
                        || dirtyPageIDs.contains(page.id)
                        || pendingSaves[page.id] != nil
                        || pendingSaveTokens[page.id] != nil else { continue }

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
                let drawing = canvasView.drawing
                DrawingStorageService.cache(
                    drawing,
                    fileName: page.drawingFileName,
                    rootURL: parent.drawingStorage.storage.rootURL
                )

                requests.append(
                    CanvasSaveRequest(
                        page: page,
                        drawing: drawing,
                        rootURL: parent.drawingStorage.storage.rootURL,
                        drawingFileName: page.drawingFileName,
                        token: token
                    )
                )
            }

            return requests
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
                  parent.inputMode == .pencilOnly,
                  let containerView else { return }
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
