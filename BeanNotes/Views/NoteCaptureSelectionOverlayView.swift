//
//  NoteCaptureSelectionOverlayView.swift
//  BeanNotes
//

import UIKit

final class NoteCaptureSelectionOverlayView: UIView, UIGestureRecognizerDelegate {
    private let selectionLayer = CAShapeLayer()
    private let copyButton = UIButton(type: .system)
    private var handleViews: [NoteCaptureResizeHandle: UIView] = [:]
    private var resizeRecognizers: [ObjectIdentifier: NoteCaptureResizeHandle] = [:]
    private var moveStartFrame: CGRect = .zero
    private var resizeStartFrame: CGRect = .zero
    private var allowedBounds: CGRect = .zero
    private var copyAction: ((CGRect) -> Void)?
    private var feedbackResetWorkItem: DispatchWorkItem?

    private lazy var moveRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    deinit {
        feedbackResetWorkItem?.cancel()
    }

    func configure(
        selectionFrame: CGRect,
        within allowedBounds: CGRect,
        copyAction: @escaping (CGRect) -> Void
    ) {
        self.allowedBounds = allowedBounds.standardized
        self.copyAction = copyAction
        frame = selectionFrame
        isHidden = false
        setNeedsLayout()
    }

    func setCopying(_ isCopying: Bool) {
        copyButton.isEnabled = !isCopying
        var configuration = copyButton.configuration
        configuration?.showsActivityIndicator = isCopying
        configuration?.title = isCopying ? "Copying" : "Copy"
        configuration?.image = isCopying ? nil : UIImage(systemName: "doc.on.clipboard")
        copyButton.configuration = configuration
    }

    func showCopySucceeded() {
        feedbackResetWorkItem?.cancel()
        setCopying(false)
        var configuration = copyButton.configuration
        configuration?.title = "Copied"
        configuration?.image = UIImage(systemName: "checkmark")
        copyButton.configuration = configuration
        UIAccessibility.post(notification: .announcement, argument: "Note selection copied")

        let reset = DispatchWorkItem { [weak self] in
            self?.setCopying(false)
        }
        feedbackResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }

    func showCopyFailed() {
        setCopying(false)
        UIAccessibility.post(notification: .announcement, argument: "Could not copy note selection")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionLayer.frame = bounds
        selectionLayer.path = UIBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath

        let handleSize = CGSize(width: 30, height: 30)
        handleViews[.topLeft]?.frame = CGRect(
            x: -2,
            y: -2,
            width: handleSize.width,
            height: handleSize.height
        )
        handleViews[.topRight]?.frame = CGRect(
            x: bounds.width - handleSize.width + 2,
            y: -2,
            width: handleSize.width,
            height: handleSize.height
        )
        handleViews[.bottomRight]?.frame = CGRect(
            x: bounds.width - handleSize.width + 2,
            y: bounds.height - handleSize.height + 2,
            width: handleSize.width,
            height: handleSize.height
        )
        handleViews[.bottomLeft]?.frame = CGRect(
            x: -2,
            y: bounds.height - handleSize.height + 2,
            width: handleSize.width,
            height: handleSize.height
        )

        let buttonWidth = min(max(bounds.width - 72, 76), 112)
        copyButton.frame = CGRect(
            x: bounds.midX - buttonWidth / 2,
            y: 10,
            width: buttonWidth,
            height: 36
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === moveRecognizer, let touchedView = touch.view else { return true }
        if touchedView === copyButton || touchedView.isDescendant(of: copyButton) {
            return false
        }
        return !handleViews.values.contains {
            touchedView === $0 || touchedView.isDescendant(of: $0)
        }
    }

    @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView = superview else { return }
        switch recognizer.state {
        case .began:
            moveStartFrame = frame
        case .changed:
            let translation = recognizer.translation(in: hostView)
            frame = NoteCaptureSelectionGeometry.movedFrame(
                from: moveStartFrame,
                translation: CGPoint(x: translation.x, y: translation.y),
                in: allowedBounds
            )
        default:
            break
        }
    }

    @objc private func handleResize(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView = superview,
              let handle = resizeRecognizers[ObjectIdentifier(recognizer)] else {
            return
        }

        switch recognizer.state {
        case .began:
            resizeStartFrame = frame
        case .changed:
            let translation = recognizer.translation(in: hostView)
            frame = NoteCaptureSelectionGeometry.resizedFrame(
                from: resizeStartFrame,
                translation: CGPoint(x: translation.x, y: translation.y),
                handle: handle,
                in: allowedBounds
            )
        default:
            break
        }
    }

    @objc private func copySelection() {
        guard copyButton.isEnabled else { return }
        copyAction?(frame)
    }

    private func configureView() {
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.06)
        clipsToBounds = false
        accessibilityIdentifier = "noteCaptureSelection"
        accessibilityLabel = "Capture selection"
        accessibilityHint = "Drag to move the selection or drag a corner to resize it"
        shouldGroupAccessibilityChildren = true

        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 3
        selectionLayer.lineDashPattern = [8, 5]
        selectionLayer.shadowColor = UIColor.black.cgColor
        selectionLayer.shadowOpacity = 0.16
        selectionLayer.shadowRadius = 2
        layer.addSublayer(selectionLayer)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Copy"
        configuration.image = UIImage(systemName: "doc.on.clipboard")
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white
        copyButton.configuration = configuration
        copyButton.accessibilityIdentifier = "noteCaptureCopyButton"
        copyButton.accessibilityLabel = "Copy selected note area"
        copyButton.addTarget(self, action: #selector(copySelection), for: .touchUpInside)
        addSubview(copyButton)

        for handle in NoteCaptureResizeHandle.allCases {
            let handleView = makeHandleView(handle)
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            recognizer.cancelsTouchesInView = true
            handleView.addGestureRecognizer(recognizer)
            resizeRecognizers[ObjectIdentifier(recognizer)] = handle
            handleViews[handle] = handleView
            addSubview(handleView)
        }

        addGestureRecognizer(moveRecognizer)
    }

    private func makeHandleView(_ handle: NoteCaptureResizeHandle) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Resize capture from \(handle.accessibilityPosition)"

        let dot = UIView(frame: CGRect(x: 8, y: 8, width: 14, height: 14))
        dot.backgroundColor = .white
        dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = 7
        dot.layer.borderColor = UIColor.systemBlue.cgColor
        dot.layer.borderWidth = 3
        view.addSubview(dot)
        return view
    }
}

private extension NoteCaptureResizeHandle {
    var accessibilityPosition: String {
        switch self {
        case .topLeft:
            "top left"
        case .topRight:
            "top right"
        case .bottomRight:
            "bottom right"
        case .bottomLeft:
            "bottom left"
        }
    }
}
