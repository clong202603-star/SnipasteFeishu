import AppKit

final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ShotOverlay: NSObject {
    var onSave: ((CGImage) -> Void)?
    var onIngest: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [ShieldWindow] = []
    private var surfaces: [ShotSurface] = []
    private var keyMonitor: Any?
    private var busy = false

    init(shots: [ScreenGrabber.Shot]) {
        super.init()
        for shot in shots {
            let surface = ShotSurface(image: shot.image)
            surface.onChange = { [weak self] in self?.selectionChanged(except: surface) }
            surface.onAction = { [weak self] action in self?.handle(action, from: surface) }
            let window = ShieldWindow(
                contentRect: shot.screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hidesOnDeactivate = false
            window.contentView = surface
            windows.append(window)
            surfaces.append(surface)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        windows.first?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.cancel()
                return nil
            case 36, 76:
                self.ingestFromKeyboard()
                return nil
            default:
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "c" {
                    self.saveFromKeyboard()
                    return nil
                }
                return event
            }
        }
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        surfaces.removeAll()
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        for surface in surfaces {
            surface.setBusy(busy)
        }
    }

    private func selectionChanged(except active: ShotSurface) {
        for surface in surfaces where surface !== active {
            surface.clearSelection()
        }
    }

    private func handle(_ action: ShotAction, from surface: ShotSurface) {
        if action == .cancel {
            cancel()
            return
        }
        guard !busy, let image = surface.croppedImage() else { return }
        switch action {
        case .save:
            onSave?(image)
        case .ingest:
            onIngest?(image)
        case .cancel:
            break
        }
    }

    private func activeSurface() -> ShotSurface? {
        surfaces.first { $0.selection != nil }
    }

    private func saveFromKeyboard() {
        guard !busy, let surface = activeSurface(), let image = surface.croppedImage() else { return }
        onSave?(image)
    }

    private func ingestFromKeyboard() {
        guard !busy, let surface = activeSurface(), let image = surface.croppedImage() else { return }
        onIngest?(image)
    }

    private func cancel() {
        onCancel?()
    }
}

enum ShotAction {
    case save, ingest, cancel
}

private enum DragMode {
    case new(anchor: CGPoint)
    case move(origin: CGPoint, start: CGPoint)
    case resize(handle: Handle, origin: CGRect)
}

private enum Handle: CaseIterable {
    case nw, n, ne, e, se, s, sw, w
}

private final class ShotSurface: NSView {
    var onChange: (() -> Void)?
    var onAction: ((ShotAction) -> Void)?
    var selection: CGRect?

    private let source: CGImage
    private let imageView = NSImageView()
    private let dim = DimLayer(frame: .zero)
    private let chrome = ChromeView(frame: .zero)
    private let toolbar = ActionBar(frame: .zero)
    private var drag: DragMode?
    private var busy = false

    init(image: CGImage) {
        source = image
        super.init(frame: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = NSImage(cgImage: image, size: .zero)
        addSubview(imageView)
        addSubview(dim)
        addSubview(chrome)
        toolbar.isHidden = true
        toolbar.onSave = { [weak self] in self?.onAction?(.save) }
        toolbar.onIngest = { [weak self] in self?.onAction?(.ingest) }
        toolbar.onCancel = { [weak self] in self?.onAction?(.cancel) }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        imageView.image?.size = bounds.size
        dim.frame = bounds
        chrome.frame = bounds
        placeToolbar()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if !toolbar.isHidden {
            addCursorRect(toolbar.frame, cursor: .arrow)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !toolbar.isHidden, toolbar.frame.contains(local) {
            return super.hitTest(point)
        }
        return self
    }

    func clearSelection() {
        selection = nil
        drag = nil
        dim.selection = nil
        chrome.selection = nil
        toolbar.isHidden = true
        needsDisplay = true
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        toolbar.setBusy(busy)
    }

    func croppedImage() -> CGImage? {
        guard let selection else { return nil }
        let scale = pixelScale
        let rect = CGRect(
            x: selection.minX * scale.x,
            y: (bounds.height - selection.maxY) * scale.y,
            width: selection.width * scale.x,
            height: selection.height * scale.y
        ).integral
        let boundsRect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let cropped = rect.intersection(boundsRect)
        guard cropped.width >= 2, cropped.height >= 2 else { return nil }
        return source.cropping(to: cropped)
    }

    override func mouseDown(with event: NSEvent) {
        if busy { return }
        let point = convert(event.locationInWindow, from: nil)
        if let selection {
            if let handle = hitHandle(at: point, in: selection) {
                drag = .resize(handle: handle, origin: selection)
                return
            }
            if selection.insetBy(dx: -4, dy: -4).contains(point) {
                drag = .move(origin: selection.origin, start: point)
                return
            }
        }
        onChange?()
        drag = .new(anchor: point)
        selection = CGRect(origin: point, size: .zero)
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .new(let anchor):
            selection = rect(from: anchor, to: point)
        case .move(let origin, let start):
            guard let selection else { return }
            var moved = selection
            moved.origin = CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y)
            self.selection = clamp(moved)
        case .resize(let handle, let origin):
            selection = resized(origin, handle: handle, to: point)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            clearSelection()
            return
        }
        refresh()
        window?.invalidateCursorRects(for: self)
    }

    private var pixelScale: CGPoint {
        CGPoint(
            x: bounds.width > 0 ? CGFloat(source.width) / bounds.width : 1,
            y: bounds.height > 0 ? CGFloat(source.height) / bounds.height : 1
        )
    }

    private func refresh() {
        dim.selection = selection
        chrome.selection = selection
        chrome.pixelScale = pixelScale
        placeToolbar()
    }

    private func placeToolbar() {
        guard let selection, selection.width >= 8, selection.height >= 8, drag == nil else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        var frame = CGRect(x: selection.maxX - toolbar.fittingWidth, y: selection.minY - 46, width: toolbar.fittingWidth, height: 36)
        if frame.minY < 8 {
            frame.origin.y = selection.maxY + 10
        }
        if frame.minX < 8 {
            frame.origin.x = 8
        }
        if frame.maxX > bounds.width - 8 {
            frame.origin.x = bounds.width - 8 - frame.width
        }
        if frame.maxY > bounds.height - 8 {
            frame.origin.y = bounds.height - 8 - frame.height
        }
        toolbar.frame = frame
    }

    private func hitHandle(at point: CGPoint, in rect: CGRect) -> Handle? {
        for handle in Handle.allCases where handle.point(in: rect).distance(to: point) <= 10 {
            return handle
        }
        return nil
    }

    private func resized(_ origin: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var rect = origin
        switch handle {
        case .nw: rect = self.rect(from: CGPoint(x: origin.maxX, y: origin.minY), to: point)
        case .n: rect = self.rect(from: CGPoint(x: origin.minX, y: origin.minY), to: CGPoint(x: origin.maxX, y: point.y))
        case .ne: rect = self.rect(from: CGPoint(x: origin.minX, y: origin.minY), to: point)
        case .e: rect = self.rect(from: CGPoint(x: origin.minX, y: origin.minY), to: CGPoint(x: point.x, y: origin.maxY))
        case .se: rect = self.rect(from: CGPoint(x: origin.minX, y: origin.maxY), to: point)
        case .s: rect = self.rect(from: CGPoint(x: origin.minX, y: origin.maxY), to: CGPoint(x: origin.maxX, y: point.y))
        case .sw: rect = self.rect(from: CGPoint(x: origin.maxX, y: origin.maxY), to: point)
        case .w: rect = self.rect(from: CGPoint(x: origin.maxX, y: origin.minY), to: CGPoint(x: point.x, y: origin.maxY))
        }
        return clip(rect)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func clip(_ rect: CGRect) -> CGRect {
        let next = rect.intersection(bounds)
        if next.isNull || next.isInfinite { return .zero }
        return next
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var next = rect
        if next.width > bounds.width { next.size.width = bounds.width }
        if next.height > bounds.height { next.size.height = bounds.height }
        if next.minX < 0 { next.origin.x = 0 }
        if next.minY < 0 { next.origin.y = 0 }
        if next.maxX > bounds.width { next.origin.x = bounds.width - next.width }
        if next.maxY > bounds.height { next.origin.y = bounds.height - next.height }
        return next
    }
}

private final class DimLayer: NSView {
    var selection: CGRect? {
        didSet { updateMask() }
    }
    private let shade = CALayer()
    private let hole = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        hole.fillRule = .evenOdd
        hole.fillColor = NSColor.white.cgColor
        shade.mask = hole
        layer?.addSublayer(shade)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shade.frame = bounds
        hole.frame = bounds
        updateMask()
    }

    private func updateMask() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection, selection.width > 1, selection.height > 1 {
            path.addRect(selection)
        }
        hole.path = path
    }
}

private final class ChromeView: NSView {
    var selection: CGRect? {
        didSet { needsDisplay = true }
    }
    var pixelScale = CGPoint(x: 1, y: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let selection, selection.width >= 2, selection.height >= 2 else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()
        for handle in Handle.allCases {
            let center = handle.point(in: selection)
            let knob = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
        }
        let label = "\(Int((selection.width * pixelScale.x).rounded())) × \(Int((selection.height * pixelScale.y).rounded()))"
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let size = label.size(withAttributes: attrs)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + size.height > bounds.height - 4 {
            origin.y = selection.maxY - size.height - 6
        }
        label.draw(at: origin, withAttributes: attrs)
    }
}

private final class ActionBar: NSView {
    var onSave: (() -> Void)?
    var onIngest: (() -> Void)?
    var onCancel: (() -> Void)?
    let fittingWidth: CGFloat = 228

    private let save = BarButton(title: "保存")
    private let ingest = BarButton(title: "入库")
    private let cancel = BarButton(title: "取消")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.cornerRadius = 8
        save.target = self
        save.action = #selector(saveClicked)
        ingest.target = self
        ingest.action = #selector(ingestClicked)
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        addSubview(save)
        addSubview(ingest)
        addSubview(cancel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width / 3
        save.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        ingest.frame = CGRect(x: width, y: 0, width: width, height: bounds.height)
        cancel.frame = CGRect(x: width * 2, y: 0, width: width, height: bounds.height)
    }

    func setBusy(_ busy: Bool) {
        save.isEnabled = !busy
        cancel.isEnabled = true
        ingest.isEnabled = !busy
        ingest.setTitle(busy ? "入库中…" : "入库")
    }

    @objc private func saveClicked() { onSave?() }
    @objc private func ingestClicked() { onIngest?() }
    @objc private func cancelClicked() { onCancel?() }
}

private final class BarButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        setTitle(title)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }
}

private extension Handle {
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .nw: return CGPoint(x: rect.minX, y: rect.maxY)
        case .n: return CGPoint(x: rect.midX, y: rect.maxY)
        case .ne: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .e: return CGPoint(x: rect.maxX, y: rect.midY)
        case .se: return CGPoint(x: rect.maxX, y: rect.minY)
        case .s: return CGPoint(x: rect.midX, y: rect.minY)
        case .sw: return CGPoint(x: rect.minX, y: rect.minY)
        case .w: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
