import AppKit

/// Glue between hotkeys/menu and the capture pipeline.
final class CaptureController {
    private let engine = CaptureEngine()
    private var areaSession: AreaSelectionSession?
    private var windowSession: WindowSelectionSession?
    private var scrollController: ScrollCaptureController?
    private var burstSession: BurstSession?

    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    // MARK: - Entry points

    func beginAreaCapture() {
        selectArea { [weak self] result in
            self?.rememberArea(result)
            self?.route(result.image)
        }
    }

    func captureFullscreen() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let capture = try await engine.captureDisplayUnderMouse()
                route(capture.image)
            } catch {
                NSLog("Snapi: fullscreen capture failed: \(error)")
            }
        }
    }

    func delayedFullscreen(seconds: Double) {
        NSSound(named: "Tink")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.captureFullscreen()
        }
    }

    func beginWindowCapture() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            guard windowSession == nil else { return }
            do {
                async let capturesTask = engine.captureAllDisplays()
                async let windowsTask = engine.selectableWindows()
                let (captures, candidates) = try await (capturesTask, windowsTask)
                let session = WindowSelectionSession(captures: captures, candidates: candidates) { [weak self] window in
                    guard let self else { return }
                    self.windowSession = nil
                    guard let window else { return }
                    Task { @MainActor in
                        do {
                            let image = try await self.engine.captureWindow(window)
                            self.route(image)
                        } catch {
                            NSLog("Snapi: window capture failed: \(error)")
                        }
                    }
                }
                windowSession = session
                session.begin()
            } catch {
                NSLog("Snapi: window capture setup failed: \(error)")
            }
        }
    }

    func beginScrollingCapture() {
        selectArea { [weak self] result in
            guard let self, let displayID = result.screen.displayID else { return }
            Task { @MainActor in
                let controller = ScrollCaptureController(
                    engine: self.engine,
                    displayID: displayID,
                    displayRect: result.displayRect,
                    screen: result.screen
                ) { [weak self] stitched in
                    self?.scrollController = nil
                    if let stitched {
                        self?.route(stitched)
                    }
                }
                self.scrollController = controller
                controller.start()
            }
        }
    }

    /// One hotkey drives burst mode: the first press selects the area, every
    /// later press grabs it. The menu bar counter (or `finishBurst`) ends it.
    func burstCaptureOrShoot() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let burstSession {
                burstSession.shoot()
                return
            }
            // Selection activates Snapi; hand focus back so the user can keep working.
            let previousApp = NSWorkspace.shared.frontmostApplication
            selectArea { [weak self] result in
                guard let self, let displayID = result.screen.displayID else { return }
                self.rememberArea(result)
                Task { @MainActor in
                    let session = BurstSession(
                        engine: self.engine,
                        displayID: displayID,
                        displayRect: result.displayRect,
                        screen: result.screen
                    ) { shots in
                        self.burstSession = nil
                        if !shots.isEmpty {
                            BurstGalleryController.present(shots: shots)
                        }
                    }
                    self.burstSession = session
                    session.start()
                    if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        previousApp?.activate()
                    }
                }
            }
        }
    }

    func finishBurst() {
        Task { @MainActor in
            burstSession?.finish()
        }
    }

    @MainActor var burstShotCount: Int? { burstSession?.shotCount }

    func beginOCRCapture() {
        selectArea { result in
            Task { @MainActor in
                do {
                    let text = try await OCRService.recognizeText(in: result.image)
                    guard !text.isEmpty else {
                        Sound.failure()
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Sound.success()
                } catch {
                    NSLog("Snapi: OCR failed: \(error)")
                }
            }
        }
    }

    func pinClipboardOrArea() {
        Task { @MainActor in
            if PinManager.shared.pinFromClipboard() { return }
            selectArea { result in
                Task { @MainActor in
                    PinManager.shared.pin(image: result.image)
                }
            }
        }
    }

    func repeatLastArea() {
        guard let lastArea else {
            beginAreaCapture()
            return
        }
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let image = try await engine.captureRegion(displayID: lastArea.displayID, rect: lastArea.rect)
                route(image)
            } catch {
                NSLog("Snapi: repeat capture failed: \(error)")
            }
        }
    }

    // MARK: - Shared plumbing

    private func selectArea(then handler: @escaping (AreaSelectionResult) -> Void) {
        guard ensurePermission() else { return }
        Task { @MainActor in
            guard areaSession == nil else { return }
            do {
                let captures = try await engine.captureAllDisplays()
                let session = AreaSelectionSession(captures: captures) { [weak self] result in
                    self?.areaSession = nil
                    if let result {
                        handler(result)
                    }
                }
                areaSession = session
                session.begin()
            } catch {
                NSLog("Snapi: area selection failed: \(error)")
            }
        }
    }

    private func rememberArea(_ result: AreaSelectionResult) {
        guard let displayID = result.screen.displayID else { return }
        lastArea = (displayID, result.displayRect)
    }

    private func route(_ image: CGImage) {
        Sound.capture()
        let historyURL = HistoryStore.shared.add(image)
        DispatchQueue.main.async {
            if SettingsStore.shared.showEditor {
                EditorWindowController.present(image: image, historyURL: historyURL)
            } else {
                ExportService.shared.export(image)
            }
        }
    }

    private func ensurePermission() -> Bool {
        guard ScreenPermission.isGranted else {
            ScreenPermission.ensure()
            return false
        }
        return true
    }
}
