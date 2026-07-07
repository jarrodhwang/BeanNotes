//
//  DrawingCanvasView.swift
//  BeanNotes
//

import Combine
import PencilKit
import SwiftUI
import UIKit

struct AttachmentImageRasterBudget: Equatable {
    private static let defaultRenderScale: CGFloat = 3
    private static let minimumPixelSize = 1_024
    private static let maximumPixelSize = 3_072
    private static let growthReloadFactor: CGFloat = 1.35
    private static let shrinkReloadFactor: CGFloat = 0.55

    let maxPixelSize: Int

    init(attachmentSize: CGSize, renderScale: CGFloat) {
        let longestEdge = max(attachmentSize.width, attachmentSize.height)
        let effectiveScale = renderScale > 0 ? renderScale : Self.defaultRenderScale
        let requestedPixelSize = Int((longestEdge * effectiveScale).rounded(.up))
        maxPixelSize = min(max(requestedPixelSize, Self.minimumPixelSize), Self.maximumPixelSize)
    }

    func shouldReplaceLoadedBudget(_ loadedBudget: AttachmentImageRasterBudget?) -> Bool {
        guard let loadedBudget else { return true }

        let loaded = CGFloat(loadedBudget.maxPixelSize)
        let requested = CGFloat(maxPixelSize)
        return requested > loaded * Self.growthReloadFactor
            || requested < loaded * Self.shrinkReloadFactor
    }
}

struct DrawingCanvasView: UIViewRepresentable {
    let pages: [NotePage]
    @Binding var selectedPageID: UUID?
    @ObservedObject var toolState: DrawingToolState
    var paletteMode: PenPaletteMode
    var inputMode: DrawingInputMode
    var renderQuality: DrawingRenderQuality
    var pageFlowMode: NoteEditorPageFlowMode
    var doubleTapAction: PencilDoubleTapAction
    var saveNowSignal: Int
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
    var drawingChanged: (UUID) -> Void
    var saveStarted: () -> Void = {}
    var saveSucceeded: () -> Void = {}
    var saveFailed: (Error) -> Void = { _ in }
    var undoRedoAvailabilityChanged: (Bool, Bool) -> Void = { _, _ in }
    var zoomScaleChanged: (CGFloat) -> Void = { _ in }
    var addPageAtBottom: () -> Void
    var topContent: AnyView?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let containerView = CanvasContainerView()
        containerView.visiblePageChanged = { [weak coordinator = context.coordinator] pageID in
            coordinator?.selectVisiblePage(pageID)
        }
        containerView.reachedBottom = { [weak coordinator = context.coordinator] in
            coordinator?.requestAddPageAtBottom()
        }

        context.coordinator.containerView = containerView

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
            coordinator: context.coordinator
        )
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
        context.coordinator.observeToolState(toolState)
        containerView.setTopContentView(context.coordinator.updateTopContent(topContent))

        containerView.configure(
            pages: pages,
            selectedPageID: selectedPageID,
            pageFlowMode: pageFlowMode,
            inputMode: inputMode,
            renderQuality: renderQuality,
            drawingStorage: drawingStorage,
            coordinator: context.coordinator
        )

        if context.coordinator.selectedPageID != selectedPageID,
           let selectedPageID {
            context.coordinator.selectedPageID = selectedPageID
            containerView.scrollToPage(id: selectedPageID, animated: true)
        }

        if context.coordinator.saveNowSignal != saveNowSignal {
            context.coordinator.saveAllCanvases()
            context.coordinator.saveNowSignal = saveNowSignal
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
        coordinator.performFinalDrawingFlush(reason: "Editor closed")
        coordinator.hideToolPicker()
    }

    final class CanvasContainerView: UIView, UIScrollViewDelegate {
        private struct ZoomAnchor {
            var contentPoint: CGPoint
            var viewportPoint: CGPoint
        }

        let scrollView = UIScrollView()
        let contentView = UIView()
        let autoAddFooterButton = UIButton(type: .system)

        var visiblePageChanged: ((UUID) -> Void)?
        var reachedBottom: (() -> Void)?

        private var pageViews: [UUID: PageCanvasView] = [:]
        private var pagesByID: [UUID: NotePage] = [:]
        private var orderedPageIDs: [UUID] = []
        private var pageFrames: [UUID: CGRect] = [:]
        private var documentSize: CGSize = .zero
        private weak var topContentView: UIView?
        private var pageFlowMode: NoteEditorPageFlowMode = .continuous
        private var renderQuality: DrawingRenderQuality = .highResolution
        private var layoutConfigurationSignature: String?
        private var selectedPageID: UUID?
        private var drawingStorage: DrawingStorageService?
        private weak var coordinator: Coordinator?
        private var inputMode: DrawingInputMode = DrawingInputMode.defaultMode
        private var lastFitScale: CGFloat = 1
        private var lastBackgroundRenderScale: CGFloat = 0
        private var lastDrawingRenderScale: CGFloat = 0
        private var lastImageRenderScale: CGFloat = 0
        private var didSetInitialZoom = false
        private var bottomTriggerArmed = true
        private var isPinchZooming = false
        private var lastZoomEndTime: CFTimeInterval = 0
        private let pageGap: CGFloat = 28
        private let pageMargin: CGFloat = 52
        private let autoAddFooterSize: CGFloat = 56
        private let autoAddFooterTopPadding: CGFloat = 36
        private let autoAddFooterBottomPadding: CGFloat = 42
        private let pagePreloadScreenPadding: CGFloat = 420
        private let minimumPagePreloadPadding: CGFloat = 320
        private let imagePreloadScreenPadding: CGFloat = 180
        private let minimumImagePreloadPadding: CGFloat = 96
        private let topContentHeight: CGFloat = 96
        private let zoomOutMultiplier: CGFloat = 0.46
        private let absoluteMinimumZoomScale: CGFloat = 0.12
        private let renderScaleChangeThreshold: CGFloat = 0.08
        private let fitSnapThreshold: CGFloat = 0.045
        private let tapAfterZoomIgnoreDuration: CFTimeInterval = 0.32
        private let fingerTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        var isZoomGestureActiveOrRecentlyEnded: Bool {
            let pinchState = scrollView.pinchGestureRecognizer?.state
            let pinchIsActive = pinchState == .began || pinchState == .changed
            return isPinchZooming
                || pinchIsActive
                || CACurrentMediaTime() - lastZoomEndTime < tapAfterZoomIgnoreDuration
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

        var canvasPagePairs: [(NotePage, PKCanvasView)] {
            orderedPageIDs.compactMap { id in
                guard let pageView = pageViews[id], let page = pageView.page else { return nil }
                return (page, pageView.canvasView)
            }
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
            coordinator: Coordinator
        ) {
            let qualityChanged = self.renderQuality != renderQuality
            let inputModeChanged = self.inputMode != inputMode
            self.pageFlowMode = pageFlowMode
            self.inputMode = inputMode
            self.renderQuality = renderQuality
            self.selectedPageID = selectedPageID ?? pages.first?.id
            self.drawingStorage = drawingStorage
            self.coordinator = coordinator
            let nextSignature = layoutSignature(for: pages, pageFlowMode: pageFlowMode)
            let shouldRelayout = nextSignature != layoutConfigurationSignature

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

            updateZoomScalesIfNeeded(force: qualityChanged)
            materializePagesNearViewport(forceSelectedPage: true)

            if inputModeChanged {
                applyInputModeToMaterializedPages()
            }
        }

        func scrollToPage(id: UUID, animated: Bool) {
            guard let frame = pageFrames[id], scrollView.bounds != .zero else { return }
            selectedPageID = id
            let scaledCenterX = frame.midX * scrollView.zoomScale
            let scaledTopY = frame.minY * scrollView.zoomScale
            let target = CGPoint(
                x: scaledCenterX - scrollView.bounds.width / 2,
                y: scaledTopY - scrollView.adjustedContentInset.top + 12
            )
            scrollView.setContentOffset(clampedContentOffset(target), animated: animated)
            materializePagesNearViewport(forceSelectedPage: true)
        }

        func fitSelectedPageToScreen(animated: Bool) {
            updateZoomScalesIfNeeded()
            scrollView.setZoomScale(selectedPageOverviewScale(), animated: animated)
            publishZoomScale(force: true)

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

        private func setZoomScalePreservingViewportCenter(_ targetScale: CGFloat, animated: Bool) {
            let currentScale = max(scrollView.zoomScale, 0.01)
            guard abs(targetScale - currentScale) > 0.001 else { return }

            let viewportCenter = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let contentCenter = CGPoint(
                x: viewportCenter.x / currentScale,
                y: viewportCenter.y / currentScale
            )

            let applyZoom = {
                self.scrollView.setZoomScale(targetScale, animated: false)
                self.centerDocument()

                let targetOffset = CGPoint(
                    x: contentCenter.x * targetScale - self.scrollView.bounds.width / 2,
                    y: contentCenter.y * targetScale - self.scrollView.bounds.height / 2
                )
                self.scrollView.setContentOffset(self.clampedContentOffset(targetOffset), animated: false)
                self.updateRasterScale(force: true)
                self.materializePagesNearViewport(forceSelectedPage: true)
                self.updateVisiblePage()
                self.publishZoomScale(force: true)
            }

            if animated {
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction],
                    animations: applyZoom
                )
            } else {
                applyZoom()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.frame = bounds
            updateZoomScalesIfNeeded()
            centerDocument()
            materializePagesNearViewport(forceSelectedPage: true)
            updateVisiblePage()
            publishZoomScale()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            materializePagesNearViewport()
            if !isPinchZooming {
                updateVisiblePage()
            }
            triggerBottomIfNeeded()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isPinchZooming = true
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let anchor = zoomAnchor()
            updateRasterScale()
            centerDocument()
            restoreZoomAnchor(anchor)
            materializePagesNearViewport()
            publishZoomScale()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isPinchZooming = false
            lastZoomEndTime = CACurrentMediaTime()
            updateRasterScale(force: true)
            centerDocument()
            refreshVisibleCanvasesAfterZoom()
            materializePagesNearViewport(forceSelectedPage: true)
            updateVisiblePage()
            publishZoomScale(force: true)

            guard abs(scale - lastFitScale) / max(lastFitScale, 0.01) < fitSnapThreshold else { return }
            scrollView.setZoomScale(lastFitScale, animated: true)
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
            autoAddFooterButton.configuration = footerConfiguration
            autoAddFooterButton.isHidden = true
            autoAddFooterButton.accessibilityLabel = "Add page"
            autoAddFooterButton.layer.shadowColor = UIColor.black.cgColor
            autoAddFooterButton.layer.shadowOpacity = 0.16
            autoAddFooterButton.layer.shadowRadius = 14
            autoAddFooterButton.layer.shadowOffset = CGSize(width: 0, height: 8)
            autoAddFooterButton.addTarget(self, action: #selector(handleAutoAddFooterTapped), for: .touchUpInside)
            contentView.addSubview(autoAddFooterButton)
        }

        private func layoutDocument() {
            guard !orderedPageIDs.isEmpty else {
                documentSize = .zero
                contentView.frame = .zero
                scrollView.contentSize = .zero
                return
            }

            let maxWidth = orderedPageIDs
                .compactMap { pagesByID[$0]?.pageSize.width }
                .max() ?? 0

            var y: CGFloat = 0
            var frames: [UUID: CGRect] = [:]

            if let topContentView {
                topContentView.frame = CGRect(x: 0, y: 0, width: maxWidth, height: topContentHeight)
                y = topContentHeight + pageGap
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

            if pageFlowMode.autoAddsPages {
                let footerY = y + autoAddFooterTopPadding
                autoAddFooterButton.isHidden = false
                autoAddFooterButton.frame = CGRect(
                    x: (maxWidth - autoAddFooterSize) / 2,
                    y: footerY,
                    width: autoAddFooterSize,
                    height: autoAddFooterSize
                )
                y = footerY + autoAddFooterSize + autoAddFooterBottomPadding
            } else {
                autoAddFooterButton.isHidden = true
                autoAddFooterButton.frame = .zero
            }

            pageFrames = frames
            documentSize = CGSize(width: maxWidth, height: y)
            contentView.frame = CGRect(origin: .zero, size: documentSize)
            scrollView.contentSize = documentSize
            centerDocument()
        }

        private func updateZoomScalesIfNeeded(force: Bool = false) {
            guard documentSize.width > 0, documentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }

            let selectedHeight = selectedPageID.flatMap { pageFrames[$0]?.height }
                ?? pageFrames[orderedPageIDs.first ?? UUID()]?.height
                ?? documentSize.height
            let widthFit = (bounds.width - pageMargin * 2) / documentSize.width
            let heightFit = (bounds.height - 148) / selectedHeight
            let proposedFit: CGFloat

            if pageFlowMode == .singlePage {
                proposedFit = min(widthFit, heightFit)
            } else {
                proposedFit = widthFit
            }

            let fitScale = min(max(proposedFit, 0.18), 1.35)
            let minimumZoomScale = max(fitScale * zoomOutMultiplier, absoluteMinimumZoomScale)
            let maximumZoomScale = max(renderQuality.maximumZoomScale, fitScale * renderQuality.maximumZoomFitMultiplier)
            let wasNearFitScale = abs(scrollView.zoomScale - lastFitScale) / max(lastFitScale, 0.01) < 0.05

            scrollView.minimumZoomScale = minimumZoomScale
            scrollView.maximumZoomScale = maximumZoomScale
            lastFitScale = fitScale

            if !didSetInitialZoom || wasNearFitScale {
                scrollView.setZoomScale(fitScale, animated: false)
                didSetInitialZoom = true
            } else if scrollView.zoomScale < minimumZoomScale {
                scrollView.setZoomScale(minimumZoomScale, animated: false)
            } else if scrollView.zoomScale > maximumZoomScale {
                scrollView.setZoomScale(maximumZoomScale, animated: false)
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
            let scaledHeight = documentSize.height * scrollView.zoomScale
            let horizontalInset = max((bounds.width - scaledWidth) / 2, pageMargin)
            let verticalInset: CGFloat

            if pageFlowMode == .singlePage {
                verticalInset = max((bounds.height - scaledHeight) / 2, 84)
            } else {
                verticalInset = 92
            }

            let inset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: max(120, verticalInset),
                right: horizontalInset
            )
            guard scrollView.contentInset.distance(to: inset) > 0.5 else { return }
            scrollView.contentInset = inset
        }

        private func zoomAnchor() -> ZoomAnchor? {
            guard isPinchZooming,
                  let pinchGesture = scrollView.pinchGestureRecognizer,
                  pinchGesture.numberOfTouches >= 2 else {
                return nil
            }

            let viewportPoint = pinchGesture.location(in: scrollView)
            let scale = max(scrollView.zoomScale, 0.01)
            let contentPoint = CGPoint(
                x: (scrollView.contentOffset.x + viewportPoint.x) / scale,
                y: (scrollView.contentOffset.y + viewportPoint.y) / scale
            )

            return ZoomAnchor(contentPoint: contentPoint, viewportPoint: viewportPoint)
        }

        private func restoreZoomAnchor(_ anchor: ZoomAnchor?) {
            guard let anchor else { return }

            let scale = max(scrollView.zoomScale, 0.01)
            let targetOffset = CGPoint(
                x: anchor.contentPoint.x * scale - anchor.viewportPoint.x,
                y: anchor.contentPoint.y * scale - anchor.viewportPoint.y
            )
            scrollView.setContentOffset(clampedContentOffset(targetOffset), animated: false)
        }

        private func updateRasterScale(force: Bool = false) {
            let screenScale = window?.screen.scale ?? UIScreen.main.scale
            let zoomScale = max(scrollView.zoomScale, 1)
            let targetScale = zoomScale * screenScale
            let backgroundScale = min(targetScale, screenScale * renderQuality.backgroundScaleMultiplier)
            let drawingScale = min(targetScale, screenScale * renderQuality.drawingScaleMultiplier)
            let imageScale = min(targetScale, screenScale * renderQuality.imageScaleMultiplier)
            let backgroundScaleChanged = abs(backgroundScale - lastBackgroundRenderScale) > renderScaleChangeThreshold
            let drawingScaleChanged = abs(drawingScale - lastDrawingRenderScale) > renderScaleChangeThreshold
            let imageScaleChanged = abs(imageScale - lastImageRenderScale) > renderScaleChangeThreshold

            guard force || backgroundScaleChanged || drawingScaleChanged || imageScaleChanged else { return }

            lastBackgroundRenderScale = backgroundScale
            lastDrawingRenderScale = drawingScale
            lastImageRenderScale = imageScale

            for pageView in pageViews.values {
                pageView.updateRenderScale(
                    backgroundScale: backgroundScale,
                    drawingScale: drawingScale,
                    imageScale: imageScale
                )
            }
        }

        private func materializePagesNearViewport(forceSelectedPage: Bool = false) {
            guard !orderedPageIDs.isEmpty, let drawingStorage, let coordinator else { return }

            let visibleRect = visibleContentRect()
            let verticalPadding = max(pagePreloadScreenPadding / max(scrollView.zoomScale, 0.01), minimumPagePreloadPadding)
            let activeRect = visibleRect.insetBy(dx: -documentSize.width, dy: -verticalPadding)
            let imageActiveRect = imageLoadingContentRect(visibleRect: visibleRect)
            var neededIDs = Set(pageIDsIntersecting(activeRect))

            if forceSelectedPage, let selectedPageID {
                neededIDs.insert(selectedPageID)
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
                    shouldLoadImages: shouldLoadImages
                ) {
                    didChangeMaterializedPages = true
                }
            }

            let retiredIDs = pageViews.keys.filter { !neededIDs.contains($0) }
            for id in retiredIDs {
                if let pageView = pageViews[id] {
                    retirePageView(id: id, pageView: pageView)
                    didChangeMaterializedPages = true
                }
            }

            updateImageLoading(in: imageActiveRect)
            updateRasterScale(force: didChangeMaterializedPages)
        }

        private func refreshVisibleCanvasesAfterZoom() {
            let visibleRect = visibleContentRect()

            for (id, pageView) in pageViews {
                guard pageFrames[id]?.intersects(visibleRect) == true else { continue }
                pageView.refreshDrawingRender()
            }
        }

        @discardableResult
        private func materializePageView(
            id: UUID,
            drawingStorage: DrawingStorageService,
            coordinator: Coordinator,
            shouldLoadImages: Bool
        ) -> Bool {
            guard let page = pagesByID[id], let frame = pageFrames[id] else { return false }
            let didCreatePageView = pageViews[id] == nil

            let pageView = pageViews[id] ?? {
                let pageView = PageCanvasView()
                contentView.addSubview(pageView)
                pageViews[id] = pageView
                return pageView
            }()

            pageView.frame = frame
            pageView.setImageLoadingEnabled(shouldLoadImages)
            pageView.configure(
                page: page,
                storage: drawingStorage.storage,
                drawingStorage: drawingStorage,
                inputMode: inputMode,
                coordinator: coordinator,
                attachmentChanged: { [weak coordinator] in
                    coordinator?.notifyAttachmentChanged()
                }
            )

            return didCreatePageView
        }

        private func applyInputModeToMaterializedPages() {
            for pageView in pageViews.values {
                pageView.applyInputMode(inputMode)
            }
        }

        private func retirePageView(id: UUID, pageView: PageCanvasView) {
            if let page = pageView.page {
                coordinator?.unregister(canvasView: pageView.canvasView, page: page)
            }

            pageView.releaseHeavyResources()
            pageView.removeFromSuperview()
            pageViews[id] = nil
        }

        func reduceMemoryFootprint() {
            let retainedID = selectedPageID ?? orderedPageIDs.first
            let retiredIDs = pageViews.keys.filter { $0 != retainedID }

            for id in retiredIDs {
                if let pageView = pageViews[id] {
                    retirePageView(id: id, pageView: pageView)
                }
            }

            ImageMemoryCache.shared.removeAllImages()
            DrawingStorageService.clearCache()
            updateImageLoading(in: imageLoadingContentRect(visibleRect: visibleContentRect()))
            updateRasterScale(force: true)
        }

        private func visibleContentRect() -> CGRect {
            guard scrollView.bounds != .zero else {
                return selectedPageID.flatMap { pageFrames[$0] } ?? .zero
            }

            let scale = max(scrollView.zoomScale, 0.01)
            return CGRect(
                x: scrollView.contentOffset.x / scale,
                y: scrollView.contentOffset.y / scale,
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
        }

        private func imageLoadingContentRect(visibleRect: CGRect) -> CGRect {
            let verticalPadding = max(
                imagePreloadScreenPadding / max(scrollView.zoomScale, 0.01),
                minimumImagePreloadPadding
            )
            return visibleRect.insetBy(dx: -documentSize.width, dy: -verticalPadding)
        }

        private func pageFrame(id: UUID, intersects rect: CGRect) -> Bool {
            pageFrames[id]?.intersects(rect) == true
        }

        private func updateImageLoading(in rect: CGRect) {
            for (id, pageView) in pageViews {
                pageView.setImageLoadingEnabled(pageFrame(id: id, intersects: rect))
            }
        }

        private func updateVisiblePage() {
            guard !pageFrames.isEmpty else { return }

            let visibleCenter = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let contentPoint = CGPoint(
                x: visibleCenter.x / max(scrollView.zoomScale, 0.01),
                y: visibleCenter.y / max(scrollView.zoomScale, 0.01)
            )

            let nearestID = nearestPageID(toY: contentPoint.y)

            guard let nearestID, nearestID != selectedPageID else { return }
            selectedPageID = nearestID
            visiblePageChanged?(nearestID)
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

        private func layoutSignature(for pages: [NotePage], pageFlowMode: NoteEditorPageFlowMode) -> String {
            let pageSignature = pages.map { page in
                let attachmentSignature = page.imageAttachments.map {
                    "\($0.id.uuidString):\($0.storedFileName):\($0.isLocked):\($0.rendersBehindDrawing)"
                }
                .joined(separator: ",")

                return [
                    page.id.uuidString,
                    "\(page.pageOrder)",
                    "\(Int(page.width))x\(Int(page.height))",
                    page.backgroundStyleRaw,
                    page.backgroundColorHex,
                    attachmentSignature
                ].joined(separator: ":")
            }
            .joined(separator: "|")

            return "\(pageFlowMode.rawValue)#\(topContentView == nil ? "noHeader" : "header")#\(pageSignature)"
        }

        private func triggerBottomIfNeeded() {
            guard pageFlowMode.autoAddsPages, bottomTriggerArmed, documentSize.height > 0 else { return }

            let visibleMaxY = (scrollView.contentOffset.y + scrollView.bounds.height) / max(scrollView.zoomScale, 0.01)
            let triggerDistance = autoAddFooterTopPadding + autoAddFooterSize + 180
            if visibleMaxY > documentSize.height - triggerDistance {
                bottomTriggerArmed = false
                reachedBottom?()
            }

            if visibleMaxY < documentSize.height - max(triggerDistance + 420, 640) {
                bottomTriggerArmed = true
            }
        }

        @objc private func handleAutoAddFooterTapped() {
            bottomTriggerArmed = false
            reachedBottom?()
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
    }

    final class PageCanvasView: UIView {
        let backgroundView = PageBackgroundUIView()
        let canvasView = PKCanvasView(frame: .zero)

        private var imageViews: [UUID: AttachmentImageContainerView] = [:]
        private(set) var page: NotePage?
        private var configurationSignature: String?
        private var lastBackgroundScale: CGFloat = 0
        private var lastDrawingScale: CGFloat = 0
        private var lastImageScale: CGFloat = 0
        private var isImageLoadingEnabled = true

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
            coordinator: Coordinator,
            attachmentChanged: @escaping () -> Void
        ) {
            let isNewPage = self.page?.id != page.id
            let signature = staticContentSignature(for: page)
            let needsStaticRefresh = isNewPage || signature != configurationSignature
            self.page = page

            if needsStaticRefresh {
                backgroundView.background = page.background
                backgroundView.setNeedsDisplay()
                configureImages(page.imageAttachments, storage: storage, attachmentChanged: attachmentChanged)
                configurationSignature = signature
            }

            if isNewPage {
                canvasView.drawing = drawingStorage.loadDrawing(for: page)
            }

            canvasView.delegate = coordinator
            applyInputMode(inputMode)
            canvasView.contentSize = page.pageSize
            canvasView.contentOffset = .zero
            coordinator.register(canvasView: canvasView, page: page)

            layoutPage()
        }

        func applyInputMode(_ inputMode: DrawingInputMode) {
            canvasView.drawingPolicy = inputMode.drawingPolicy
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            for view in imageViews.values {
                view.setImageLoadingEnabled(enabled)
            }
        }

        private func staticContentSignature(for page: NotePage) -> String {
            let attachments = page.imageAttachments.map {
                "\($0.id.uuidString):\($0.storedFileName):\($0.isLocked):\($0.rendersBehindDrawing):\(Int($0.width))x\(Int($0.height))"
            }
            .joined(separator: "|")

            return [
                page.backgroundStyleRaw,
                page.backgroundColorHex,
                attachments
            ].joined(separator: "#")
        }

        func layoutPage() {
            guard let page else { return }
            let bounds = CGRect(origin: .zero, size: page.pageSize)
            backgroundView.frame = bounds
            canvasView.frame = bounds
            canvasView.contentSize = bounds.size
            canvasView.contentOffset = .zero
            layer.shadowPath = UIBezierPath(rect: bounds).cgPath

            for attachment in page.imageAttachments {
                imageViews[attachment.id]?.frame = attachment.frame
            }
        }

        private func configureView() {
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

            canvasView.backgroundColor = .clear
            canvasView.isOpaque = false
            canvasView.isScrollEnabled = false
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
            addSubview(canvasView)
        }

        func updateRenderScale(backgroundScale: CGFloat, drawingScale: CGFloat, imageScale: CGFloat) {
            let backgroundChanged = abs(backgroundScale - lastBackgroundScale) > 0.05
            let drawingChanged = abs(drawingScale - lastDrawingScale) > 0.05
            let imageChanged = abs(imageScale - lastImageScale) > 0.05
            guard backgroundChanged || drawingChanged || imageChanged else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let containerScale = max(backgroundScale, drawingScale)
            contentScaleFactor = containerScale
            layer.contentsScale = containerScale
            layer.rasterizationScale = containerScale

            if backgroundChanged {
                backgroundView.updateRenderScale(backgroundScale)
                lastBackgroundScale = backgroundScale
            }

            if drawingChanged {
                canvasView.applyCanvasBackingScale(drawingScale)
                lastDrawingScale = drawingScale
            }

            if imageChanged {
                for view in imageViews.values {
                    view.updateRasterScale(imageScale)
                }
                lastImageScale = imageScale
            }

            CATransaction.commit()
        }

        func refreshDrawingRender() {
            canvasView.setNeedsDisplay()
            canvasView.layer.setNeedsDisplay()

            for subview in canvasView.subviews {
                subview.setNeedsDisplay()
                subview.layer.setNeedsDisplay()
            }
        }

        private func configureImages(
            _ attachments: [Attachment],
            storage: LocalStorageService,
            attachmentChanged: @escaping () -> Void
        ) {
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
                    addSubview(view)
                    return view
                }()

                imageView.setImageLoadingEnabled(isImageLoadingEnabled)
                imageView.configure(
                    attachment: attachment,
                    storage: storage,
                    pageSize: page?.pageSize ?? .zero,
                    changed: attachmentChanged
                )
                imageView.frame = attachment.frame
            }

            sendSubviewToBack(backgroundView)

            for attachment in attachments where attachment.rendersBehindDrawing {
                if let view = imageViews[attachment.id] {
                    insertSubview(view, aboveSubview: backgroundView)
                }
            }

            bringSubviewToFront(canvasView)

            for attachment in attachments where !attachment.rendersBehindDrawing {
                if let view = imageViews[attachment.id] {
                    bringSubviewToFront(view)
                }
            }
        }

        func releaseHeavyResources(evictCachedImages: Bool = false) {
            canvasView.delegate = nil
            canvasView.drawing = PKDrawing()

            for view in imageViews.values {
                view.releaseImage(evictCachedVariants: evictCachedImages)
                view.removeFromSuperview()
            }

            imageViews.removeAll()
        }
    }

    final class PageBackgroundUIView: UIView {
        var background: NoteBackground = .plain()

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
            NoteBackgroundRenderer.draw(background: background, in: bounds, context: context)
        }
    }

    final class AttachmentImageContainerView: UIView {
        private final class ImageLoadToken {
            private let lock = NSLock()
            private var isCancelledStorage = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return isCancelledStorage
            }

            func cancel() {
                lock.lock()
                isCancelledStorage = true
                lock.unlock()
            }
        }

        private static let imageDecodeQueue = DispatchQueue(
            label: "com.snowfox.BeanNotes.attachment-image-decode",
            qos: .utility
        )

        private let imageView = UIImageView()
        private let resizeHandle = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var dragStart: CGRect?
        private var resizeStart: CGRect?
        private var changed: (() -> Void)?
        private var imageURL: URL?
        private var loadedStoredFileName: String?
        private var loadedRasterBudget: AttachmentImageRasterBudget?
        private var loadingStoredFileName: String?
        private var loadingRasterBudget: AttachmentImageRasterBudget?
        private var imageLoadRequestID: UUID?
        private var imageLoadToken: ImageLoadToken?
        private var currentRenderScale: CGFloat = 0
        private var isImageLoadingEnabled = true

        var isRasterImageLoaded: Bool {
            imageView.image != nil
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
            changed: @escaping () -> Void
        ) {
            self.attachment = attachment
            self.pageSize = pageSize
            self.changed = changed

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

            frame = attachment.frame
            isUserInteractionEnabled = !attachment.isLocked
            resizeHandle.isHidden = attachment.isLocked
            layer.borderWidth = attachment.isLocked ? 0 : 1.5
            layer.borderColor = attachment.isLocked ? nil : UIColor.systemBlue.withAlphaComponent(0.65).cgColor
            backgroundColor = attachment.isLocked ? .clear : UIColor.secondarySystemBackground.withAlphaComponent(0.72)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            resizeHandle.frame = CGRect(
                x: bounds.maxX - 34,
                y: bounds.maxY - 34,
                width: 28,
                height: 28
            )
        }

        private func configureView() {
            clipsToBounds = true
            layer.cornerRadius = 6
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)

            resizeHandle.tintColor = .white
            resizeHandle.backgroundColor = UIColor.black.withAlphaComponent(0.62)
            resizeHandle.layer.cornerRadius = 14
            resizeHandle.contentMode = .center
            resizeHandle.isUserInteractionEnabled = true
            addSubview(resizeHandle)

            let moveGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
            moveGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(moveGesture)

            let resizeGesture = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            resizeGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            resizeHandle.addGestureRecognizer(resizeGesture)
        }

        func updateRasterScale(_ scale: CGFloat) {
            contentScaleFactor = scale
            layer.contentsScale = scale
            imageView.contentScaleFactor = scale
            imageView.layer.contentsScale = scale
            resizeHandle.contentScaleFactor = scale
            resizeHandle.layer.contentsScale = scale
            currentRenderScale = scale

            guard isImageLoadingEnabled, let imageURL, let attachment else { return }
            loadImageIfNeeded(from: imageURL, attachment: attachment)
        }

        func setImageLoadingEnabled(_ enabled: Bool) {
            guard isImageLoadingEnabled != enabled else { return }

            isImageLoadingEnabled = enabled

            if enabled {
                guard let imageURL, let attachment else { return }
                loadImageIfNeeded(from: imageURL, attachment: attachment)
            } else {
                releaseImage()
            }
        }

        private func loadImageIfNeeded(from imageURL: URL, attachment: Attachment) {
            guard isImageLoadingEnabled else { return }

            let budget = AttachmentImageRasterBudget(
                attachmentSize: CGSize(width: attachment.width, height: attachment.height),
                renderScale: currentRenderScale
            )
            let storedFileName = attachment.storedFileName
            let fileChanged = loadedStoredFileName != storedFileName
            guard fileChanged || budget.shouldReplaceLoadedBudget(loadedRasterBudget) else { return }
            guard loadingStoredFileName != storedFileName || loadingRasterBudget != budget else { return }

            if fileChanged {
                imageView.image = nil
                loadedStoredFileName = nil
                loadedRasterBudget = nil
            }

            let requestID = UUID()
            let token = ImageLoadToken()
            imageLoadToken?.cancel()
            imageLoadRequestID = requestID
            imageLoadToken = token
            loadingStoredFileName = storedFileName
            loadingRasterBudget = budget

            let maxPixelSize = CGFloat(budget.maxPixelSize)
            Self.imageDecodeQueue.async { [imageURL, requestID, token, storedFileName, budget, maxPixelSize] in
                guard !token.isCancelled else { return }

                let image = autoreleasepool {
                    ImageMemoryCache.shared.image(
                        at: imageURL,
                        maxPixelSize: maxPixelSize
                    )
                }

                guard !token.isCancelled else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.imageLoadRequestID == requestID,
                          self.imageLoadToken === token,
                          !token.isCancelled,
                          self.isImageLoadingEnabled,
                          self.imageURL == imageURL,
                          self.loadingStoredFileName == storedFileName,
                          self.loadingRasterBudget == budget else {
                        return
                    }

                    self.imageLoadRequestID = nil
                    self.imageLoadToken = nil
                    self.loadingStoredFileName = nil
                    self.loadingRasterBudget = nil
                    self.loadedStoredFileName = storedFileName
                    self.loadedRasterBudget = budget
                    self.imageView.image = image
                }
            }
        }

        func releaseImage(evictCachedVariants: Bool = false) {
            cancelPendingImageLoad()
            if evictCachedVariants, let imageURL {
                ImageMemoryCache.shared.removeImages(for: imageURL)
            }
            imageView.image = nil
            loadedStoredFileName = nil
            loadedRasterBudget = nil
        }

        private func cancelPendingImageLoad() {
            imageLoadToken?.cancel()
            imageLoadRequestID = nil
            imageLoadToken = nil
            loadingStoredFileName = nil
            loadingRasterBudget = nil
        }

        @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
            guard let attachment, let superview else { return }

            switch recognizer.state {
            case .began:
                dragStart = attachment.frame
            case .changed:
                guard let dragStart else { return }
                let translation = recognizer.translation(in: superview)
                let maxX = max(pageSize.width - dragStart.width, 0)
                let maxY = max(pageSize.height - dragStart.height, 0)
                attachment.x = min(max(dragStart.origin.x + translation.x, 0), maxX)
                attachment.y = min(max(dragStart.origin.y + translation.y, 0), maxY)
                frame = attachment.frame
            case .ended, .cancelled, .failed:
                attachment.touch()
                changed?()
                dragStart = nil
            default:
                break
            }
        }

        @objc private func handleResize(_ recognizer: UIPanGestureRecognizer) {
            guard let attachment, let superview else { return }

            switch recognizer.state {
            case .began:
                resizeStart = attachment.frame
            case .changed:
                guard let resizeStart else { return }
                let translation = recognizer.translation(in: superview)
                let width = max(120, resizeStart.width + translation.x)
                let height = max(90, resizeStart.height + translation.y)
                attachment.width = min(width, max(pageSize.width - resizeStart.minX, 120))
                attachment.height = min(height, max(pageSize.height - resizeStart.minY, 90))
                frame = attachment.frame
            case .ended, .cancelled, .failed:
                attachment.touch()
                changed?()
                resizeStart = nil
            default:
                break
            }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvasView
        var selectedPageID: UUID?
        var saveNowSignal: Int
        var fitToPageSignal: Int
        var zoomInSignal: Int
        var zoomOutSignal: Int
        var zoomToScaleSignal: Int
        var undoSignal: Int
        var redoSignal: Int
        var toolShortcutSignal: Int
        var pageIDs: Set<UUID>
        var toolPicker = PKToolPicker()
        var pendingSaves: [UUID: DispatchWorkItem] = [:]
        var pendingSaveTokens: [UUID: UUID] = [:]
        var registeredCanvasIDs: Set<ObjectIdentifier> = []
        var dirtyPageIDs: Set<UUID> = []
        var toolStateCancellable: AnyCancellable?
        weak var observedToolState: DrawingToolState?
        weak var containerView: CanvasContainerView?
        private var topContentHostingController: UIHostingController<AnyView>?
        private var lifecycleObservers: [NSObjectProtocol] = []

        private var canvasPages: [ObjectIdentifier: NotePage] = [:]
        private var pencilInteractions: [ObjectIdentifier: UIPencilInteraction] = [:]
        private var canvasToolSignatures: [ObjectIdentifier: String] = [:]
        private var lastPublishedCanUndo: Bool?
        private var lastPublishedCanRedo: Bool?
        private var lastPublishedZoomScale: CGFloat?
        private let drawingSaveDebounce: TimeInterval = 1.25
        private let zoomScalePublishThreshold: CGFloat = 0.005
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
        }

        func requestAddPageAtBottom() {
            let addPageAtBottom = parent.addPageAtBottom
            dispatchToSwiftUI(addPageAtBottom)
        }

        func notifyAttachmentChanged() {
            let attachmentChanged = parent.attachmentChanged
            dispatchToSwiftUI(attachmentChanged)
        }

        private func notifyVisiblePageChanged(_ pageID: UUID) {
            let selectedPageID = parent.$selectedPageID
            dispatchToSwiftUI {
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
                guard let self, self.pendingSaves.isEmpty, self.dirtyPageIDs.isEmpty else { return }
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
            guard scale.isFinite, scale > 0 else { return }
            let shouldPublish = force
                || (lastPublishedZoomScale.map { abs($0 - scale) > zoomScalePublishThreshold } ?? true)
            guard shouldPublish else { return }

            lastPublishedZoomScale = scale
            let zoomScaleChanged = parent.zoomScaleChanged
            dispatchToSwiftUI {
                zoomScaleChanged(scale)
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
            self.fitToPageSignal = parent.fitToPageSignal
            self.zoomInSignal = parent.zoomInSignal
            self.zoomOutSignal = parent.zoomOutSignal
            self.zoomToScaleSignal = parent.zoomToScaleSignal
            self.undoSignal = parent.undoSignal
            self.redoSignal = parent.redoSignal
            self.toolShortcutSignal = parent.toolShortcutSignal
            self.pageIDs = Set(parent.pages.map(\.id))
            super.init()
            observeApplicationLifecycle()
        }

        deinit {
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

        func register(canvasView: PKCanvasView, page: NotePage) {
            let id = ObjectIdentifier(canvasView)
            canvasPages[id] = page

            if !registeredCanvasIDs.contains(id) {
                registeredCanvasIDs.insert(id)
                toolPicker.addObserver(canvasView)
            }

            applyCurrentCustomTool(to: canvasView)
            publishUndoRedoAvailability()

            if pencilInteractions[id] == nil {
                let pencilInteraction = UIPencilInteraction()
                pencilInteraction.delegate = self
                canvasView.addInteraction(pencilInteraction)
                pencilInteractions[id] = pencilInteraction
            }
        }

        func unregister(canvasView: PKCanvasView, page: NotePage) {
            let id = ObjectIdentifier(canvasView)
            flushDrawingBeforeCanvasRelease(canvasView, for: page)
            pendingSaves[page.id]?.cancel()
            pendingSaves[page.id] = nil
            pendingSaveTokens[page.id] = nil
            toolPicker.removeObserver(canvasView)
            registeredCanvasIDs.remove(id)
            canvasPages[id] = nil
            canvasToolSignatures[id] = nil

            if let pencilInteraction = pencilInteractions[id] {
                canvasView.removeInteraction(pencilInteraction)
                pencilInteractions[id] = nil
            }
        }

        func selectVisiblePage(_ pageID: UUID) {
            selectedPageID = pageID
            notifyVisiblePageChanged(pageID)
            activeCanvasView?.becomeFirstResponder()
            applyCustomToolIfNeeded()
            configureToolPicker(mode: parent.paletteMode)
            publishUndoRedoAvailability()
        }

        func configureToolPicker(mode: PenPaletteMode) {
            guard let activeCanvasView else { return }

            if mode == .applePencil {
                canvasToolSignatures.removeAll()
                activeCanvasView.becomeFirstResponder()
                toolPicker.setVisible(true, forFirstResponder: activeCanvasView)
            } else {
                hideToolPicker()
            }
        }

        func hideToolPicker() {
            for (_, canvasView) in containerView?.canvasPagePairs ?? [] {
                toolPicker.setVisible(false, forFirstResponder: canvasView)
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
            applyCurrentCustomToolToVisibleCanvases()
        }

        func applyToolShortcutSelection() {
            let signature = parent.toolState.pkToolSignature
            let tool = parent.toolState.makePKTool()

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
            let signature = parent.toolState.pkToolSignature
            let id = ObjectIdentifier(canvasView)
            guard canvasToolSignatures[id] != signature else { return }
            canvasView.tool = parent.toolState.makePKTool()
            canvasToolSignatures[id] = signature
        }

        private func applyCurrentCustomToolToVisibleCanvases() {
            let signature = parent.toolState.pkToolSignature
            let tool = parent.toolState.makePKTool()
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
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let key = ObjectIdentifier(canvasView)
            guard let page = canvasPages[key] else { return }

            dirtyPageIDs.insert(page.id)
            notifyDrawingChanged(pageID: page.id)
            notifySaveStarted()
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
                self.dirtyPageIDs.remove(pageID)

                let drawing = canvasView.drawing
                DrawingStorageService.cache(drawing, fileName: drawingFileName, rootURL: rootURL)
                Self.writeDrawing(
                    drawing,
                    rootURL: rootURL,
                    drawingFileName: drawingFileName,
                    onSuccess: { [weak self] in
                        self?.reportDrawingSaveSuccess()
                    },
                    onFailure: { [weak self] error in
                        self?.reportDrawingSaveFailure(error, pageID: pageID)
                    }
                )
            }

            pendingSaves[pageID] = save
            DispatchQueue.main.asyncAfter(deadline: .now() + drawingSaveDebounce, execute: save)
        }

        private func flushDrawingBeforeCanvasRelease(_ canvasView: PKCanvasView, for page: NotePage) {
            guard dirtyPageIDs.contains(page.id) || pendingSaves[page.id] != nil else { return }

            pendingSaves[page.id]?.cancel()
            pendingSaves[page.id] = nil
            pendingSaveTokens[page.id] = nil

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
                notifySaveFailed(error)
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

        private func reportDrawingSaveSuccess() {
            guard pendingSaves.isEmpty, dirtyPageIDs.isEmpty else { return }
            notifySaveSucceededIfClean()
        }

        private func reportDrawingSaveFailure(_ error: Error, pageID: UUID) {
            dirtyPageIDs.insert(pageID)
            notifySaveFailed(error)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard parent.toolState.temporaryEraserActive else { return }
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
                        self?.reportDrawingSaveSuccess()
                        group.leave()
                    },
                    onFailure: { [weak self] error in
                        self?.reportDrawingSaveFailure(error, pageID: request.page.id)
                        group.leave()
                    }
                )
            }

            group.notify(queue: .main, execute: endBackgroundTask)
        }

        func saveAllCanvases(synchronously: Bool = true, force: Bool = false) {
            var savedAtLeastOneCanvas = false
            let requests = canvasSaveRequests(force: force)

            for request in requests {
                if synchronously {
                    do {
                        try Self.writeDrawingSynchronously(
                            request.drawing,
                            rootURL: request.rootURL,
                            drawingFileName: request.drawingFileName
                        )
                        request.page.touch()
                        savedAtLeastOneCanvas = true
                    } catch {
                        dirtyPageIDs.insert(request.page.id)
                        notifySaveFailed(error)
                    }
                } else {
                    Self.writeDrawing(
                        request.drawing,
                        rootURL: request.rootURL,
                        drawingFileName: request.drawingFileName,
                        onSuccess: { [weak self] in
                            self?.reportDrawingSaveSuccess()
                        },
                        onFailure: { [weak self] error in
                            self?.reportDrawingSaveFailure(error, pageID: request.page.id)
                        }
                    )
                }
            }

            if synchronously, savedAtLeastOneCanvas, dirtyPageIDs.isEmpty, pendingSaves.isEmpty {
                notifySaveSucceededIfClean()
            }
        }

        private func canvasSaveRequests(force: Bool) -> [CanvasSaveRequest] {
            let pairs = containerView?.canvasPagePairs ?? []
            var requests: [CanvasSaveRequest] = []

            for (page, canvasView) in pairs {
                guard force || dirtyPageIDs.contains(page.id) || pendingSaves[page.id] != nil else { continue }

                pendingSaves[page.id]?.cancel()
                pendingSaves[page.id] = nil
                pendingSaveTokens[page.id] = nil
                dirtyPageIDs.remove(page.id)
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
                        drawingFileName: page.drawingFileName
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

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard parent.paletteMode == .custom else { return }
            parent.toolState.handleDoubleTap(action: parent.doubleTapAction)
            applyCustomToolIfNeeded()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer {
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
    func applyCanvasBackingScale(_ scale: CGFloat) {
        var visitedLayers: Set<ObjectIdentifier> = []
        guard applyBackingScale(scale, visitedLayers: &visitedLayers) else { return }
        setNeedsDisplay()
        layer.setNeedsDisplay()
    }

    @discardableResult
    private func applyBackingScale(_ scale: CGFloat, visitedLayers: inout Set<ObjectIdentifier>) -> Bool {
        var didChange = false

        if abs(contentScaleFactor - scale) > 0.05 {
            contentScaleFactor = scale
            didChange = true
        }

        didChange = layer.applyBackingScale(scale, visitedLayers: &visitedLayers) || didChange

        for subview in subviews {
            didChange = subview.applyBackingScale(scale, visitedLayers: &visitedLayers) || didChange
        }

        if didChange {
            setNeedsDisplay()
            layer.setNeedsDisplay()
        }

        return didChange
    }
}

private extension CALayer {
    @discardableResult
    func applyBackingScale(_ scale: CGFloat, visitedLayers: inout Set<ObjectIdentifier>) -> Bool {
        guard visitedLayers.insert(ObjectIdentifier(self)).inserted else { return false }

        var didChange = false

        if abs(contentsScale - scale) > 0.05 {
            contentsScale = scale
            didChange = true
        }

        if abs(rasterizationScale - scale) > 0.05 {
            rasterizationScale = scale
            didChange = true
        }

        for sublayer in sublayers ?? [] {
            didChange = sublayer.applyBackingScale(scale, visitedLayers: &visitedLayers) || didChange
        }

        if didChange {
            setNeedsDisplay()
        }

        return didChange
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
