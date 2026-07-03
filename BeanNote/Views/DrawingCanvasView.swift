//
//  DrawingCanvasView.swift
//  BeanNote
//

import PencilKit
import SwiftUI

struct DrawingCanvasView: UIViewRepresentable {
    let page: NotePage
    @ObservedObject var toolState: DrawingToolState
    var paletteMode: PenPaletteMode
    var doubleTapAction: PencilDoubleTapAction
    var saveNowSignal: Int
    var drawingStorage = DrawingStorageService()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let containerView = CanvasContainerView()
        let canvasView = containerView.canvasView
        canvasView.delegate = context.coordinator
        canvasView.drawing = drawingStorage.loadDrawing(for: page)
        canvasView.tool = toolState.makePKTool()
        canvasView.drawingPolicy = .pencilOnly
        canvasView.contentSize = page.pageSize
        containerView.configurePage(size: page.pageSize)
        containerView.updateLockedImages(page.lockedImageAttachments, storage: drawingStorage.storage)

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

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        context.coordinator.canvasView = canvasView
        context.coordinator.configureToolPicker(for: canvasView, mode: paletteMode)

        return containerView
    }

    func updateUIView(_ containerView: CanvasContainerView, context: Context) {
        context.coordinator.parent = self
        let canvasView = containerView.canvasView

        if context.coordinator.pageID != page.id {
            context.coordinator.flushPendingSave()
            canvasView.drawing = drawingStorage.loadDrawing(for: page)
            context.coordinator.pageID = page.id
        }

        if context.coordinator.saveNowSignal != saveNowSignal {
            context.coordinator.flushPendingSave()
            try? drawingStorage.save(canvasView.drawing, for: page)
            context.coordinator.saveNowSignal = saveNowSignal
        }

        canvasView.contentSize = page.pageSize
        containerView.configurePage(size: page.pageSize)
        containerView.updateLockedImages(page.lockedImageAttachments, storage: drawingStorage.storage)

        if paletteMode == .custom {
            canvasView.tool = toolState.makePKTool()
        }
        context.coordinator.configureToolPicker(for: canvasView, mode: paletteMode)
    }

    static func dismantleUIView(_ containerView: CanvasContainerView, coordinator: Coordinator) {
        let canvasView = containerView.canvasView
        coordinator.flushPendingSave()
        try? coordinator.parent.drawingStorage.save(canvasView.drawing, for: coordinator.parent.page)
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvasView)
    }

    final class CanvasContainerView: UIView, UIScrollViewDelegate {
        let scrollView = UIScrollView()
        let contentView = UIView()
        let canvasView = PKCanvasView(frame: .zero)

        private var pageSize: CGSize = .zero
        private var lockedImageViews: [UUID: UIImageView] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        func configurePage(size: CGSize) {
            guard pageSize != size else {
                layoutPage()
                return
            }

            pageSize = size
            scrollView.contentSize = size
            layoutPage()
        }

        func updateLockedImages(_ attachments: [Attachment], storage: LocalStorageService) {
            let attachmentIDs = Set(attachments.map(\.id))

            for (id, imageView) in lockedImageViews where !attachmentIDs.contains(id) {
                imageView.removeFromSuperview()
                lockedImageViews[id] = nil
            }

            for attachment in attachments {
                let imageView = lockedImageViews[attachment.id] ?? {
                    let imageView = UIImageView()
                    imageView.backgroundColor = .white
                    imageView.clipsToBounds = true
                    imageView.contentMode = .scaleAspectFit
                    imageView.isUserInteractionEnabled = false
                    contentView.insertSubview(imageView, belowSubview: canvasView)
                    lockedImageViews[attachment.id] = imageView
                    return imageView
                }()

                imageView.frame = attachment.frame
                imageView.image = UIImage(contentsOfFile: storage.url(forRelativePath: attachment.storedFileName).path)
            }

            contentView.bringSubviewToFront(canvasView)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.frame = bounds
            layoutPage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerPage()
        }

        private func configure() {
            backgroundColor = .clear

            scrollView.backgroundColor = .clear
            scrollView.delegate = self
            scrollView.minimumZoomScale = 0.45
            scrollView.maximumZoomScale = 4
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = true
            scrollView.keyboardDismissMode = .interactive
            scrollView.contentInsetAdjustmentBehavior = .never
            addSubview(scrollView)

            contentView.backgroundColor = .clear
            scrollView.addSubview(contentView)

            canvasView.backgroundColor = .clear
            canvasView.isOpaque = false
            canvasView.isScrollEnabled = false
            canvasView.minimumZoomScale = 1
            canvasView.maximumZoomScale = 1
            contentView.addSubview(canvasView)
        }

        private func layoutPage() {
            guard pageSize != .zero else { return }

            contentView.frame = CGRect(origin: .zero, size: pageSize)
            canvasView.frame = contentView.bounds
            canvasView.contentSize = pageSize
            scrollView.contentSize = pageSize

            centerPage()
        }

        private func centerPage() {
            guard pageSize != .zero else { return }

            let scaledWidth = pageSize.width * scrollView.zoomScale
            let scaledHeight = pageSize.height * scrollView.zoomScale
            let horizontalInset = max((bounds.width - scaledWidth) / 2, 0)
            let verticalInset = max((bounds.height - scaledHeight) / 2, 0)

            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvasView
        var pageID: UUID
        var saveNowSignal: Int
        var toolPicker = PKToolPicker()
        var pendingSave: DispatchWorkItem?
        weak var canvasView: PKCanvasView?

        init(parent: DrawingCanvasView) {
            self.parent = parent
            self.pageID = parent.page.id
            self.saveNowSignal = parent.saveNowSignal
        }

        func configureToolPicker(for canvasView: PKCanvasView, mode: PenPaletteMode) {
            toolPicker.addObserver(canvasView)
            toolPicker.setVisible(mode == .applePencil, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            pendingSave?.cancel()
            let drawing = canvasView.drawing
            let page = parent.page
            let storage = parent.drawingStorage
            let toolState = parent.toolState

            let save = DispatchWorkItem {
                try? storage.save(drawing, for: page)

                if toolState.temporaryEraserActive {
                    Task { @MainActor in
                        toolState.restoreAfterTemporaryEraser()
                    }
                }
            }

            pendingSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: save)
        }

        func flushPendingSave() {
            guard let pendingSave else { return }
            pendingSave.perform()
            self.pendingSave = nil
        }

        @objc func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            canvasView?.undoManager?.undo()
        }

        @objc func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            canvasView?.undoManager?.redo()
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard parent.paletteMode == .custom else { return }
            parent.toolState.handleDoubleTap(action: parent.doubleTapAction)
            canvasView?.tool = parent.toolState.makePKTool()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
