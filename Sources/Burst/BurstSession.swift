import AppKit

/// Burst capture: the user picks an area once, then keeps working while each
/// press of the burst hotkey grabs that area. Everything outside the area is
/// dimmed (click-through), and a menu bar counter finishes the session and
/// opens the gallery.
@MainActor
final class BurstSession {
    private let displayRect: CGRect
    private let screen: NSScreen
    private let completion: ([BurstShot]) -> Void

    private let capturerTask: Task<RegionCapturer, Error>
    private let directory = BurstShot.makeSessionDirectory()
    private let overlay: BurstOverlay
    private var statusItem: NSStatusItem?
    private var shiftTap: RightShiftTap?

    private var shots: [BurstShot] = []
    private var nextIndex = 1
    private var inFlight = 0
    private var finishing = false
    private var delivered = false

    var shotCount: Int { shots.count }

    init(
        engine: CaptureEngine,
        displayID: CGDirectDisplayID,
        displayRect: CGRect,
        screen: NSScreen,
        completion: @escaping ([BurstShot]) -> Void
    ) {
        self.displayRect = displayRect
        self.screen = screen
        self.completion = completion
        self.overlay = BurstOverlay(displayRect: displayRect, screen: screen)
        // Build the filter up front so the first shot is as fast as the rest.
        self.capturerTask = Task {
            try await engine.makeRegionCapturer(displayID: displayID, rect: displayRect)
        }
    }

    func start() {
        overlay.show()
        showStatusItem()
        let tap = RightShiftTap { [weak self] in self?.shoot() }
        tap.start()
        shiftTap = tap
    }

    /// Grabs the region. Rapid presses overlap; shots keep press order.
    func shoot() {
        guard !finishing else { return }
        let index = nextIndex
        nextIndex += 1
        inFlight += 1
        Task { @MainActor in
            defer {
                inFlight -= 1
                deliverIfDone()
            }
            do {
                let image = try await capturerTask.value.capture()
                let shot = BurstShot(index: index, image: image, directory: directory)
                let position = shots.firstIndex { $0.index > index } ?? shots.endIndex
                shots.insert(shot, at: position)
                Sound.capture()
                overlay.flash(count: shots.count, image: image)
                updateStatusItem()
            } catch {
                Sound.failure()
                NSLog("Snapi: burst shot failed: \(error)")
            }
        }
    }

    /// Tears down the chrome right away; hands shots over once in-flight
    /// captures have landed.
    func finish() {
        guard !finishing else { return }
        finishing = true
        shiftTap?.stop()
        shiftTap = nil
        overlay.hide()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        deliverIfDone()
    }

    private func deliverIfDone() {
        guard finishing, inFlight == 0, !delivered else { return }
        delivered = true
        completion(shots)
    }

    // MARK: - Menu bar

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(hierarchicalColor: .systemRed))
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Burst capture")?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Burst capture — click to finish and review"
        }
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.title = " \(shots.count)"
    }

    @objc private func statusItemClicked() {
        finish()
    }
}

// MARK: - Dim overlay

/// Click-through windows that dim every display except the burst region,
/// plus a small HUD with the shot count. Excluded from the captures.
@MainActor
private final class BurstOverlay {
    private var windows: [NSWindow] = []
    private weak var regionView: BurstOverlayView?

    init(displayRect: CGRect, screen: NSScreen) {
        for target in NSScreen.screens {
            let window = NSWindow(
                contentRect: target.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            var hole: CGRect?
            if target == screen {
                // Display-local top-left → view-local bottom-left.
                hole = CGRect(
                    x: displayRect.minX,
                    y: target.frame.height - displayRect.maxY,
                    width: displayRect.width,
                    height: displayRect.height
                )
            }
            let view = BurstOverlayView(frame: CGRect(origin: .zero, size: target.frame.size), hole: hole)
            window.contentView = view
            if hole != nil { regionView = view }
            windows.append(window)
        }
    }

    func show() {
        for window in windows {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for window in windows { window.animator().alphaValue = 1 }
        }
    }

    func hide() {
        let windows = windows
        self.windows.removeAll()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            for window in windows { window.animator().alphaValue = 0 }
        }, completionHandler: {
            for window in windows { window.orderOut(nil) }
        })
    }

    func flash(count: Int, image: CGImage) {
        regionView?.flash(count: count, image: image)
    }
}

private final class BurstOverlayView: NSView {
    private let hole: CGRect?
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let flashLayer = CALayer()
    private let hud = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "")

    init(frame: CGRect, hole: CGRect?) {
        self.hole = hole
        super.init(frame: frame)
        wantsLayer = true

        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addRect(hole) }
        dimLayer.path = path
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.addSublayer(dimLayer)

        guard let hole else { return }

        // Border sits just outside the region.
        borderLayer.path = CGPath(rect: hole.insetBy(dx: -1, dy: -1), transform: nil)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.5
        borderLayer.shadowRadius = 3
        borderLayer.shadowOffset = .zero
        layer?.addSublayer(borderLayer)

        flashLayer.frame = hole
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)

        setUpHUD(below: hole)
        updateHUD(count: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shutter feedback: white flash over the region, border pulse, and a
    /// thumbnail of the shot that shrinks and drops into the HUD counter.
    func flash(count: Int, image: CGImage) {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.65
        flash.toValue = 0
        flash.duration = 0.28
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(flash, forKey: "flash")

        let pulse = CABasicAnimation(keyPath: "lineWidth")
        pulse.fromValue = 5
        pulse.toValue = 1.5
        pulse.duration = 0.3
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        borderLayer.add(pulse, forKey: "pulse")

        let pulseColor = CABasicAnimation(keyPath: "strokeColor")
        pulseColor.fromValue = NSColor.systemRed.cgColor
        pulseColor.duration = 0.3
        borderLayer.add(pulseColor, forKey: "pulseColor")

        flyThumbnail(image)
        updateHUD(count: count)
        bounceHUD()
    }

    private func flyThumbnail(_ image: CGImage) {
        guard let hole else { return }
        let thumb = CALayer()
        thumb.contents = image
        thumb.contentsGravity = .resizeAspectFill
        thumb.masksToBounds = true
        thumb.cornerRadius = 6
        thumb.borderWidth = 2
        thumb.borderColor = NSColor.white.cgColor

        let aspect = hole.width / max(1, hole.height)
        let endHeight: CGFloat = 28
        let endSize = CGSize(width: min(endHeight * aspect, 60), height: endHeight)
        let endCenter = CGPoint(x: hud.frame.minX + 22, y: hud.frame.midY)
        thumb.bounds = CGRect(origin: .zero, size: endSize)
        thumb.position = endCenter
        thumb.opacity = 0
        layer?.addSublayer(thumb)

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = CGPoint(x: hole.midX, y: hole.midY)
        move.toValue = endCenter
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = hole.size
        size.toValue = endSize
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.75, 1]

        let group = CAAnimationGroup()
        group.animations = [move, size, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { thumb.removeFromSuperlayer() }
        thumb.add(group, forKey: "fly")
        CATransaction.commit()
    }

    /// Pops the HUD around its center once the thumbnail lands.
    private func bounceHUD() {
        guard let hudLayer = hud.layer else { return }
        let center = CGPoint(x: hud.bounds.midX, y: hud.bounds.midY)
        var grow = CATransform3DMakeTranslation(center.x, center.y, 0)
        grow = CATransform3DScale(grow, 1.12, 1.12, 1)
        grow = CATransform3DTranslate(grow, -center.x, -center.y, 0)
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [CATransform3DIdentity, grow, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        bounce.keyTimes = [0, 0.4, 1]
        bounce.beginTime = CACurrentMediaTime() + 0.3
        bounce.duration = 0.25
        hudLayer.add(bounce, forKey: "bounce")
    }

    private func setUpHUD(below hole: CGRect) {
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.appearance = NSAppearance(named: .darkAqua)
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 15
        hud.layer?.masksToBounds = true

        hudLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hudLabel.textColor = .white
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(hudLabel)
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 14),
            hudLabel.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -14),
            hudLabel.centerYAnchor.constraint(equalTo: hud.centerYAnchor),
        ])
        addSubview(hud)
    }

    private func updateHUD(count: Int) {
        guard let hole else { return }
        let key = SettingsStore.shared.hotkey(for: .burst).display
        let shots = count == 1 ? "1 shot" : "\(count) shots"
        hudLabel.stringValue = "● \(shots)   ·   tap right ⇧ or \(key) to capture   ·   click ● in menu bar to finish"
        let size = CGSize(width: hudLabel.intrinsicContentSize.width + 28, height: 30)

        // Below the region, else above, else inside its bottom edge.
        var origin = CGPoint(x: hole.midX - size.width / 2, y: hole.minY - size.height - 10)
        if origin.y < 8 {
            origin.y = hole.maxY + 10
            if origin.y + size.height > bounds.height - 30 {
                origin.y = hole.minY + 10
            }
        }
        origin.x = min(max(8, origin.x), bounds.width - size.width - 8)
        hud.frame = CGRect(origin: origin, size: size)
    }
}
