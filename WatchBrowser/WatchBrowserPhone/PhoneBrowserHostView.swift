import SwiftUI
import UIKit
import WebKit

/// A real, on-screen render surface for the single phone-local WKWebView.
/// The browser keeps its Watch-sized logical bounds while this view scales the
/// presentation to fit the pinned preview panel.
@MainActor
final class PhoneBrowserRenderHostView: UIView {
    weak var controller: PhoneSessionController?

    private weak var browserView: WKWebView?
    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.text = "从 Apple Watch 打开网页后，\n本地 WebKit 画面会显示在这里。"
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Apple Watch 本地网页预览"

        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        controller?.browserRenderHostWindowDidChange(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let browserView else { return }

        let logicalSize = browserView.bounds.size
        guard logicalSize.width > 0,
              logicalSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let scale = min(
            bounds.width / logicalSize.width,
            bounds.height / logicalSize.height
        )
        browserView.transform = .identity
        browserView.bounds = CGRect(origin: .zero, size: logicalSize)
        browserView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        browserView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    func display(_ webView: WKWebView?) {
        if let current = browserView, current !== webView {
            current.removeFromSuperview()
        }
        browserView = webView

        if let webView, webView.superview !== self {
            webView.removeFromSuperview()
            addSubview(webView)
        }
        placeholderLabel.isHidden = webView != nil
        bringSubviewToFront(placeholderLabel)
        setNeedsLayout()
    }
}

@MainActor
struct PhoneBrowserHostView: UIViewRepresentable {
    let controller: PhoneSessionController

    func makeUIView(context: Context) -> PhoneBrowserRenderHostView {
        let host = PhoneBrowserRenderHostView()
        host.controller = controller
        controller.attachBrowserRenderHost(host)
        return host
    }

    func updateUIView(_ host: PhoneBrowserRenderHostView, context: Context) {
        if host.controller !== controller {
            host.controller?.detachBrowserRenderHost(host)
            host.controller = controller
        }
        controller.attachBrowserRenderHost(host)
    }

    static func dismantleUIView(
        _ host: PhoneBrowserRenderHostView,
        coordinator: Void
    ) {
        host.controller?.detachBrowserRenderHost(host)
        host.controller = nil
    }
}
