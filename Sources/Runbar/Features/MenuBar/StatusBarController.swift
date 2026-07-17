import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private static let compactStatusItemLength: CGFloat = 16
    private static let idleImage = StatusBarDotRenderer.makeFrame(activeStep: nil)
    private static let activityFrames = StatusBarDotRenderer.makeActivityFrames()

    private let model: SettingsModel
    private let statusItem: NSStatusItem
    private let panel = StatusBarPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var modelObservation: AnyCancellable?
    private var activityTimer: Timer?
    private var activityFrameIndex = 0
    private var displayedState: MenuBarIconState?
    private var appliedAppearance: AppearancePreference?
    private(set) var settingsWindow: NSWindow?

    init(model: SettingsModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusButton()
        configurePanel()
        observeModel()
        updateStatusItem(force: true)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp])
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    }

    private func configurePanel() {
        let rootView = RunbarPanelRootView(model: model) { [weak self] in
            self?.presentSettings()
        }
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window is fully transparent; the card's glass, corner radius,
        // and shadow are all drawn by RunbarPanelRootView.
        panel.hasShadow = false
    }

    private func observeModel() {
        modelObservation = model.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    private func updateStatusItem(force: Bool = false) {
        applyAppearancePreference()
        let state = model.menuBarIconState
        guard force || state != displayedState else { return }
        let isFirstRender = displayedState == nil
        displayedState = state

        guard let button = statusItem.button else { return }
        if !force, !isFirstRender {
            crossfade(button)
        }
        button.toolTip = state.accessibilityLabel
        button.setAccessibilityLabel(state.accessibilityLabel)

        switch state {
        case .running:
            showRunning()
        case .idle:
            stopActivityAnimation()
            statusItem.length = Self.compactStatusItemLength
            button.title = ""
            button.image = Self.idleImage
            button.imagePosition = .imageOnly
        case .recentFailure, .degraded, .authenticationRequired:
            stopActivityAnimation()
            statusItem.length = Self.compactStatusItemLength
            button.title = ""
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            button.image = NSImage(
                systemSymbolName: state.systemImage,
                accessibilityDescription: state.accessibilityLabel
            )?.withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
        }
    }

    private func showRunning() {
        guard let button = statusItem.button else { return }
        statusItem.length = Self.compactStatusItemLength
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = Self.activityFrames[activityFrameIndex]
        guard activityTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1 / MenuBarActivityIndicatorStyle.animationFramesPerSecond,
            target: self,
            selector: #selector(advanceActivityFrame),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    /// Crossfades the status button's next redraw so state changes (e.g. the
    /// failure badge clearing back to the idle dots) ease in instead of
    /// swapping abruptly.
    private func crossfade(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.35
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "statusStateCrossfade")
    }

    private func applyAppearancePreference() {
        let preference = model.appearancePreference
        guard preference != appliedAppearance else { return }
        appliedAppearance = preference
        NSApplication.shared.appearance = preference.nsAppearance
    }

    private func stopActivityAnimation() {
        activityTimer?.invalidate()
        activityTimer = nil
        activityFrameIndex = 0
    }

    @objc
    private func advanceActivityFrame() {
        activityFrameIndex = (activityFrameIndex + 1) % Self.activityFrames.count
        statusItem.button?.image = Self.activityFrames[activityFrameIndex]
    }

    @objc
    private func togglePanel(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: sender)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let verticalMargins = RunbarPanelMetrics.topMargin + RunbarPanelMetrics.bottomMargin
        let horizontalMargin = RunbarPanelMetrics.horizontalMargin
        let fittingSize = panel.contentViewController?.view.fittingSize
            ?? NSSize(width: RunbarPanelMetrics.cardWidth + horizontalMargin * 2, height: 700)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? buttonRect

        // The window is larger than the visible card: transparent margins on
        // every side leave room for the SwiftUI-drawn shadow.
        let cardHeight = min(
            max(fittingSize.height - verticalMargins, 180),
            max(180, visibleFrame.height - 16)
        )
        let panelSize = NSSize(
            width: RunbarPanelMetrics.cardWidth + horizontalMargin * 2,
            height: cardHeight + verticalMargins
        )
        let x = min(
            max(buttonRect.midX - panelSize.width / 2, visibleFrame.minX + 8 - horizontalMargin),
            visibleFrame.maxX - panelSize.width + horizontalMargin - 8
        )
        let y = max(
            visibleFrame.minY + 8 - RunbarPanelMetrics.bottomMargin,
            buttonRect.minY - panelSize.height
        )

        panel.setContentSize(panelSize)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Driven from AppKit rather than SwiftUI onAppear/onDisappear: the
        // hosting view stays in the ordered-out panel between opens, so its
        // appearance callbacks are not reliable for show/hide tracking.
        model.menuBarDidAppear()
    }

    private func closePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.menuBarDidDisappear()
    }

    func presentSettings() {
        closePanel()
        let application = NSApplication.shared
        let window = settingsWindowForPresentation()
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        Task { @MainActor in
            // LSUIElement apps can finish activation one run-loop turn after the
            // status panel closes. Reassert key status once activation settles.
            try? await Task.sleep(for: .milliseconds(50))
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func settingsWindowForPresentation() -> NSWindow {
        if let settingsWindow { return settingsWindow }

        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Runbar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsUI.windowSize)
        window.center()
        settingsWindow = window
        return window
    }
}

private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum StatusBarDotRenderer {
    static func makeActivityFrames() -> [NSImage] {
        (0 ..< MenuBarActivityIndicatorStyle.animationFrameCount).map { step in
            makeFrame(activeStep: step)
        }
    }

    static func makeFrame(activeStep: Int?) -> NSImage {
        let size = NSSize(
            width: MenuBarActivityIndicatorStyle.width,
            height: MenuBarActivityIndicatorStyle.height
        )
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setShouldAntialias(true)

            for index in 0 ..< 6 {
                let opacity = opacity(for: index, activeStep: activeStep)
                context.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
                context.fillEllipse(in: dotRect(index: index, bounds: rect))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func opacity(for index: Int, activeStep: Int?) -> CGFloat {
        MenuBarActivityIndicatorStyle.dotOpacity(index: index, activeStep: activeStep)
    }

    private static func dotRect(index: Int, bounds: CGRect) -> CGRect {
        let column = index / 3
        let row = index % 3
        let diameter = MenuBarActivityIndicatorStyle.dotDiameter
        let gridWidth = diameter * 2 + MenuBarActivityIndicatorStyle.columnSpacing
        let gridHeight = diameter * 3 + MenuBarActivityIndicatorStyle.rowSpacing * 2
        let x = bounds.midX - gridWidth / 2
            + CGFloat(column) * (diameter + MenuBarActivityIndicatorStyle.columnSpacing)
        let y = bounds.midY + gridHeight / 2 - diameter
            - CGFloat(row) * (diameter + MenuBarActivityIndicatorStyle.rowSpacing)
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }
}
