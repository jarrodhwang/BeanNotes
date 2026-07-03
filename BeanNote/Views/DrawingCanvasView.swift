//
//  DrawingCanvasView.swift
//  BeanNote
//

import Combine
import PencilKit
import SwiftUI

struct DrawingCanvasView: UIViewRepresentable {
    let pages: [NotePage]
    @Binding var selectedPageID: UUID?
    @ObservedObject var toolState: DrawingToolState
    var paletteMode: PenPaletteMode
    var pageFlowMode: NoteEditorPageFlowMode
    var doubleTapAction: PencilDoubleTapAction
    var saveNowSignal: Int
    var fitToPageSignal: Int
    var drawingStorage = DrawingStorageService()
    var attachmentChanged: () -> Void
    var addPageAtBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let containerView = CanvasContainerView()
        containerView.visiblePageChanged = { [weak coordinator = context.coordinator] pageID in
            coordinator?.selectVisiblePage(pageID)
        }
        containerView.reachedBottom = { [weak coordinator = context.coordinator] in
            coordinator?.parent.addPageAtBottom()
        }

        context.coordinator.containerView = containerView

        let twoFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap(_:))
        )
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.delegate = context.coordinator
        containerView.addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerTap(_:))
        )
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.delegate = context.coordinator
        containerView.addGestureRecognizer(threeFingerTap)

        context.coordinator.observeToolState(toolState)
        containerView.configure(
            pages: pages,
            selectedPageID: selectedPageID,
            pageFlowMode: pageFlowMode,
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

        containerView.configure(
            pages: pages,
            selectedPageID: selectedPageID,
            pageFlowMode: pageFlowMode,
            drawingStorage: drawingStorage,
            coordinator: context.coordinator
        )

        if context.coordinator.selectedPageID != selectedPageID,
           let selectedPageID {
            context.coordinator.selectedPageID = selectedPageID
            containerView.scrollToPage(id: selectedPageID, animated: true)
        }

        if context.coordinator.saveNowSignal != saveNowSignal {
            context.coordinator.flushPendingSave()
            context.coordinator.saveAllCanvases()
            context.coordinator.saveNowSignal = saveNowSignal
        }

        if context.coordinator.fitToPageSignal != fitToPageSignal {
            containerView.fitSelectedPageToScreen(animated: true)
            context.coordinator.fitToPageSignal = fitToPageSignal
        }

        context.coordinator.applyCustomToolIfNeeded()
        context.coordinator.configureToolPicker(mode: paletteMode)
    }

    static func dismantleUIView(_ containerView: CanvasContainerView, coordinator: Coordinator) {
        coordinator.flushPendingSave()
        coordinator.saveAllCanvases()
        coordinator.hideToolPicker()
    }

    final class CanvasContainerView: UIView, UIScrollViewDelegate {
        let scrollView = UIScrollView()
        let contentView = UIView()

        var visiblePageChanged: ((UUID) -> Void)?
        var reachedBottom: (() -> Void)?

        private var pageViews: [UUID: PageCanvasView] = [:]
        private var orderedPageIDs: [UUID] = []
        private var pageFrames: [UUID: CGRect] = [:]
        private var documentSize: CGSize = .zero
        private var pageFlowMode: NoteEditorPageFlowMode = .continuous
        private var selectedPageID: UUID?
        private var lastFitScale: CGFloat = 1
        private var didSetInitialZoom = false
        private var bottomTriggerArmed = true
        private let pageGap: CGFloat = 28
        private let pageMargin: CGFloat = 52

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

        func configure(
            pages: [NotePage],
            selectedPageID: UUID?,
            pageFlowMode: NoteEditorPageFlowMode,
            drawingStorage: DrawingStorageService,
            coordinator: Coordinator
        ) {
            self.pageFlowMode = pageFlowMode
            self.selectedPageID = selectedPageID ?? pages.first?.id

            let incomingIDs = Set(pages.map(\.id))
            for (id, pageView) in pageViews where !incomingIDs.contains(id) {
                pageView.removeFromSuperview()
                pageViews[id] = nil
            }

            orderedPageIDs = pages.map(\.id)

            for page in pages {
                let pageView = pageViews[page.id] ?? {
                    let pageView = PageCanvasView()
                    contentView.addSubview(pageView)
                    pageViews[page.id] = pageView
                    return pageView
                }()

                pageView.configure(
                    page: page,
                    storage: drawingStorage.storage,
                    drawingStorage: drawingStorage,
                    coordinator: coordinator,
                    attachmentChanged: coordinator.parent.attachmentChanged
                )
            }

            layoutDocument()
            updateZoomScalesIfNeeded()
            setNeedsLayout()
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
        }

        func fitSelectedPageToScreen(animated: Bool) {
            updateZoomScalesIfNeeded(force: true)
            scrollView.setZoomScale(lastFitScale, animated: animated)

            if let selectedPageID {
                scrollToPage(id: selectedPageID, animated: animated)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.frame = bounds
            updateZoomScalesIfNeeded()
            centerDocument()
            updateVisiblePage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisiblePage()
            triggerBottomIfNeeded()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateRasterScale()
            centerDocument()
            updateVisiblePage()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard abs(scale - lastFitScale) / max(lastFitScale, 0.01) < 0.08 else { return }
            scrollView.setZoomScale(lastFitScale, animated: true)
        }

        private func configureView() {
            backgroundColor = .systemGroupedBackground

            scrollView.delegate = self
            scrollView.backgroundColor = .clear
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = true
            scrollView.keyboardDismissMode = .interactive
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            addSubview(scrollView)

            contentView.backgroundColor = .clear
            scrollView.addSubview(contentView)
        }

        private func layoutDocument() {
            guard !orderedPageIDs.isEmpty else {
                documentSize = .zero
                contentView.frame = .zero
                scrollView.contentSize = .zero
                return
            }

            let maxWidth = orderedPageIDs
                .compactMap { pageViews[$0]?.page?.pageSize.width }
                .max() ?? 0

            var y: CGFloat = 0
            var frames: [UUID: CGRect] = [:]

            for id in orderedPageIDs {
                guard let pageView = pageViews[id], let page = pageView.page else { continue }
                let size = page.pageSize
                let frame = CGRect(
                    x: (maxWidth - size.width) / 2,
                    y: y,
                    width: size.width,
                    height: size.height
                )
                pageView.frame = frame
                pageView.layoutPage()
                frames[id] = frame
                y += size.height + pageGap
            }

            if y > 0 {
                y -= pageGap
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

            let fitScale = min(max(proposedFit, 0.22), 1.35)
            let shouldPreserveFit = abs(scrollView.zoomScale - lastFitScale) / max(lastFitScale, 0.01) < 0.05

            scrollView.minimumZoomScale = fitScale
            scrollView.maximumZoomScale = max(4, fitScale * 4)
            lastFitScale = fitScale

            if force || !didSetInitialZoom || shouldPreserveFit || scrollView.zoomScale < fitScale {
                scrollView.setZoomScale(fitScale, animated: false)
                didSetInitialZoom = true
            }

            updateRasterScale()
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

            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: max(120, verticalInset),
                right: horizontalInset
            )
        }

        private func updateRasterScale() {
            let screenScale = window?.screen.scale ?? UIScreen.main.scale
            let effectiveScale = min(max(scrollView.zoomScale, 1), 3) * screenScale

            for pageView in pageViews.values {
                pageView.updateRasterScale(effectiveScale)
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

            let nearestID = orderedPageIDs.min { lhs, rhs in
                let lhsFrame = pageFrames[lhs] ?? .zero
                let rhsFrame = pageFrames[rhs] ?? .zero
                return abs(lhsFrame.midY - contentPoint.y) < abs(rhsFrame.midY - contentPoint.y)
            }

            guard let nearestID, nearestID != selectedPageID else { return }
            selectedPageID = nearestID
            visiblePageChanged?(nearestID)
        }

        private func triggerBottomIfNeeded() {
            guard pageFlowMode.autoAddsPages, bottomTriggerArmed, documentSize.height > 0 else { return }

            let visibleMaxY = (scrollView.contentOffset.y + scrollView.bounds.height) / max(scrollView.zoomScale, 0.01)
            if visibleMaxY > documentSize.height - 220 {
                bottomTriggerArmed = false
                reachedBottom?()
            }

            if visibleMaxY < documentSize.height - 640 {
                bottomTriggerArmed = true
            }
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
    }

    final class PageCanvasView: UIView {
        let backgroundView = PageBackgroundUIView()
        let canvasView = PKCanvasView(frame: .zero)

        private var imageViews: [UUID: AttachmentImageContainerView] = [:]
        private(set) var page: NotePage?

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
            coordinator: Coordinator,
            attachmentChanged: @escaping () -> Void
        ) {
            let isNewPage = self.page?.id != page.id
            self.page = page

            backgroundView.background = page.background
            backgroundView.setNeedsDisplay()

            if isNewPage {
                canvasView.drawing = drawingStorage.loadDrawing(for: page)
            }

            canvasView.delegate = coordinator
            canvasView.drawingPolicy = .pencilOnly
            canvasView.contentSize = page.pageSize
            coordinator.register(canvasView: canvasView, page: page)

            configureImages(page.imageAttachments, storage: storage, attachmentChanged: attachmentChanged)
            layoutPage()
        }

        func layoutPage() {
            guard let page else { return }
            let bounds = CGRect(origin: .zero, size: page.pageSize)
            backgroundView.frame = bounds
            canvasView.frame = bounds
            canvasView.contentSize = bounds.size
            layer.shadowPath = UIBezierPath(rect: bounds).cgPath

            for attachment in page.imageAttachments {
                imageViews[attachment.id]?.frame = attachment.frame
            }
        }

        private func configureView() {
            clipsToBounds = false
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 8)

            backgroundView.isUserInteractionEnabled = false
            addSubview(backgroundView)

            canvasView.backgroundColor = .clear
            canvasView.isOpaque = false
            canvasView.isScrollEnabled = false
            canvasView.minimumZoomScale = 1
            canvasView.maximumZoomScale = 1
            canvasView.contentScaleFactor = UIScreen.main.scale
            canvasView.layer.contentsScale = UIScreen.main.scale
            canvasView.layer.allowsEdgeAntialiasing = true
            addSubview(canvasView)
        }

        func updateRasterScale(_ scale: CGFloat) {
            backgroundView.contentScaleFactor = scale
            backgroundView.layer.contentsScale = scale
            canvasView.contentScaleFactor = scale
            canvasView.layer.contentsScale = scale

            for view in imageViews.values {
                view.updateRasterScale(scale)
            }
        }

        private func configureImages(
            _ attachments: [Attachment],
            storage: LocalStorageService,
            attachmentChanged: @escaping () -> Void
        ) {
            let attachmentIDs = Set(attachments.map(\.id))
            for (id, view) in imageViews where !attachmentIDs.contains(id) {
                view.removeFromSuperview()
                imageViews[id] = nil
            }

            for attachment in attachments {
                let imageView = imageViews[attachment.id] ?? {
                    let view = AttachmentImageContainerView()
                    imageViews[attachment.id] = view
                    addSubview(view)
                    return view
                }()

                imageView.configure(
                    attachment: attachment,
                    storage: storage,
                    pageSize: page?.pageSize ?? .zero,
                    changed: attachmentChanged
                )
                imageView.frame = attachment.frame
            }

            sendSubviewToBack(backgroundView)

            for attachment in attachments where attachment.isLocked {
                if let view = imageViews[attachment.id] {
                    insertSubview(view, aboveSubview: backgroundView)
                }
            }

            bringSubviewToFront(canvasView)

            for attachment in attachments where !attachment.isLocked {
                if let view = imageViews[attachment.id] {
                    bringSubviewToFront(view)
                }
            }
        }
    }

    final class PageBackgroundUIView: UIView {
        var background: NoteBackground = .plain()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.drawsAsynchronously = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = true
            contentMode = .redraw
            contentScaleFactor = UIScreen.main.scale
            layer.drawsAsynchronously = true
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }

            UIColor(hex: background.colorHex).setFill()
            context.fill(bounds)

            let lineColor = UIColor.secondaryLabel.withAlphaComponent(0.24)
            lineColor.setStroke()
            context.setLineWidth(1)

            switch background.style {
            case .plain:
                return
            case .grid:
                drawGrid(in: bounds, spacing: 32, context: context)
            case .dotted:
                drawDots(in: bounds, spacing: 28, context: context)
            case .lined:
                drawLines(in: bounds, spacing: 36, context: context)
            }
        }

        private func drawGrid(in rect: CGRect, spacing: CGFloat, context: CGContext) {
            var x = rect.minX
            while x <= rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += spacing
            }

            var y = rect.minY
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
        }

        private func drawLines(in rect: CGRect, spacing: CGFloat, context: CGContext) {
            var y = rect.minY + spacing
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
        }

        private func drawDots(in rect: CGRect, spacing: CGFloat, context: CGContext) {
            let dotColor = UIColor.secondaryLabel.withAlphaComponent(0.34)
            dotColor.setFill()

            var x = rect.minX + spacing
            while x <= rect.maxX {
                var y = rect.minY + spacing
                while y <= rect.maxY {
                    context.fillEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                    y += spacing
                }
                x += spacing
            }
        }
    }

    final class AttachmentImageContainerView: UIView {
        private let imageView = UIImageView()
        private let resizeHandle = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        private weak var attachment: Attachment?
        private var pageSize: CGSize = .zero
        private var dragStart: CGRect?
        private var resizeStart: CGRect?
        private var changed: (() -> Void)?
        private var loadedStoredFileName: String?

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
            storage: LocalStorageService,
            pageSize: CGSize,
            changed: @escaping () -> Void
        ) {
            self.attachment = attachment
            self.pageSize = pageSize
            self.changed = changed

            if loadedStoredFileName != attachment.storedFileName {
                loadedStoredFileName = attachment.storedFileName
                imageView.image = UIImage(contentsOfFile: storage.url(forRelativePath: attachment.storedFileName).path)
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
            addGestureRecognizer(moveGesture)

            let resizeGesture = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            resizeHandle.addGestureRecognizer(resizeGesture)
        }

        func updateRasterScale(_ scale: CGFloat) {
            contentScaleFactor = scale
            layer.contentsScale = scale
            imageView.contentScaleFactor = scale
            imageView.layer.contentsScale = scale
            resizeHandle.contentScaleFactor = scale
            resizeHandle.layer.contentsScale = scale
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
        var pageIDs: Set<UUID>
        var toolPicker = PKToolPicker()
        var pendingSaves: [UUID: DispatchWorkItem] = [:]
        var registeredCanvasIDs: Set<ObjectIdentifier> = []
        var toolStateCancellable: AnyCancellable?
        weak var observedToolState: DrawingToolState?
        weak var containerView: CanvasContainerView?

        private var canvasPages: [ObjectIdentifier: NotePage] = [:]
        private var pencilInteractions: [ObjectIdentifier: UIPencilInteraction] = [:]

        var activeCanvasView: PKCanvasView? {
            containerView?.activeCanvasView
        }

        init(parent: DrawingCanvasView) {
            self.parent = parent
            self.selectedPageID = parent.selectedPageID
            self.saveNowSignal = parent.saveNowSignal
            self.fitToPageSignal = parent.fitToPageSignal
            self.pageIDs = Set(parent.pages.map(\.id))
        }

        func register(canvasView: PKCanvasView, page: NotePage) {
            let id = ObjectIdentifier(canvasView)
            canvasPages[id] = page

            if !registeredCanvasIDs.contains(id) {
                registeredCanvasIDs.insert(id)
                toolPicker.addObserver(canvasView)
                canvasView.tool = parent.toolState.makePKTool()
            }

            if pencilInteractions[id] == nil {
                let pencilInteraction = UIPencilInteraction()
                pencilInteraction.delegate = self
                canvasView.addInteraction(pencilInteraction)
                pencilInteractions[id] = pencilInteraction
            }
        }

        func selectVisiblePage(_ pageID: UUID) {
            selectedPageID = pageID
            parent.selectedPageID = pageID
            activeCanvasView?.becomeFirstResponder()
            applyCustomToolIfNeeded()
            configureToolPicker(mode: parent.paletteMode)
        }

        func configureToolPicker(mode: PenPaletteMode) {
            guard let activeCanvasView else { return }

            if mode == .applePencil {
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
            activeCanvasView?.tool = parent.toolState.makePKTool()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let key = ObjectIdentifier(canvasView)
            guard let page = canvasPages[key] else { return }

            pendingSaves[page.id]?.cancel()
            let drawing = canvasView.drawing
            let rootURL = parent.drawingStorage.storage.rootURL
            let drawingFileName = page.drawingFileName

            let save = DispatchWorkItem {
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let drawingsURL = rootURL.appendingPathComponent(StorageDirectory.drawings.rawValue, isDirectory: true)
                        try FileManager.default.createDirectory(at: drawingsURL, withIntermediateDirectories: true)
                        let data = drawing.dataRepresentation()
                        try data.write(to: drawingsURL.appendingPathComponent(drawingFileName), options: [.atomic])
                    } catch {
                        return
                    }
                }
            }

            pendingSaves[page.id] = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: save)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard parent.toolState.temporaryEraserActive else { return }
            parent.toolState.restoreAfterTemporaryEraser()
        }

        func flushPendingSave() {
            let saves = Array(pendingSaves.values)
            pendingSaves.removeAll()
            saves.forEach { $0.perform() }
        }

        func saveAllCanvases() {
            for (page, canvasView) in containerView?.canvasPagePairs ?? [] {
                try? parent.drawingStorage.save(canvasView.drawing, for: page)
            }
        }

        @objc func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            activeCanvasView?.undoManager?.undo()
        }

        @objc func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            activeCanvasView?.undoManager?.redo()
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard parent.paletteMode == .custom else { return }
            parent.toolState.handleDoubleTap(action: parent.doubleTapAction)
            activeCanvasView?.tool = parent.toolState.makePKTool()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
