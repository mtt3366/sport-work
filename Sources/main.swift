import AppKit
import Foundation
import UserNotifications

enum ReminderMode: String, Codable {
    case flash
    case systemNotification

    var menuLabel: String {
        switch self {
        case .flash:
            return "菜单栏闪一下"
        case .systemNotification:
            return "系统通知"
        }
    }
}

enum FlashBehavior: String, Codable {
    case untilClicked
    case threeBlinks

    var menuLabel: String {
        switch self {
        case .untilClicked:
            return "持续闪烁，点一下才停止"
        case .threeBlinks:
            return "闪三下后自动停止"
        }
    }
}

enum CyclePhase: String, Codable {
    case focus
    case exercise

    var duration: TimeInterval {
        switch self {
        case .focus:
            return 27 * 60
        case .exercise:
            return 3 * 60
        }
    }

    var displayName: String {
        switch self {
        case .focus:
            return "专注"
        case .exercise:
            return "活动"
        }
    }
}

struct TimerState: Codable {
    var phase: CyclePhase
    var phaseStartedAt: Date
    var pausedRemaining: TimeInterval?
    var isPaused: Bool
    var focusDurationMinutes: Int
    var exerciseDurationMinutes: Int
    var showCountdownInMenuBar: Bool
    var microRemindersEnabled: Bool
    var majorReminderMode: ReminderMode
    var microReminderMode: ReminderMode
    var majorFlashBehavior: FlashBehavior
    var microFlashBehavior: FlashBehavior
}

final class LaunchAgentManager {
    private let identifier = "com.lucas.sportwork.launcher"

    private var plistURL: URL {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return launchAgents.appendingPathComponent("\(identifier).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func enable(appPath: String) throws {
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": identifier,
            "ProgramArguments": [appPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
        try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "launchctl failed"
            throw NSError(
                domain: "SportWorkLaunchAgent",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                NSLog("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    func post(title: String, body: String, sound: UNNotificationSound? = .default) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                NSLog("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

final class CycleEngine: NSObject {
    private let notificationManager: NotificationManager
    private let persistenceURL: URL
    private let onTick: (TimerState, TimeInterval) -> Void
    private let onPhaseChange: (CyclePhase) -> Void
    private let onMajorReminder: (String, String) -> Void
    private let onMicroReminder: (String, String) -> Void
    private var timer: Timer?
    private var lastMicroReminderIndex = 0

    private(set) var state: TimerState {
        didSet {
            saveState()
        }
    }

    init(
        notificationManager: NotificationManager,
        persistenceURL: URL,
        onTick: @escaping (TimerState, TimeInterval) -> Void,
        onPhaseChange: @escaping (CyclePhase) -> Void,
        onMajorReminder: @escaping (String, String) -> Void,
        onMicroReminder: @escaping (String, String) -> Void
    ) {
        self.notificationManager = notificationManager
        self.persistenceURL = persistenceURL
        self.onTick = onTick
        self.onPhaseChange = onPhaseChange
        self.onMajorReminder = onMajorReminder
        self.onMicroReminder = onMicroReminder

        if let persisted = Self.loadState(from: persistenceURL) {
            self.state = persisted
        } else {
            self.state = TimerState(
                phase: .focus,
                phaseStartedAt: Date(),
                pausedRemaining: nil,
                isPaused: false,
                focusDurationMinutes: 27,
                exerciseDurationMinutes: 3,
                showCountdownInMenuBar: false,
                microRemindersEnabled: true,
                majorReminderMode: .flash,
                microReminderMode: .flash,
                majorFlashBehavior: .untilClicked,
                microFlashBehavior: .threeBlinks
            )
        }

        super.init()
        normalizeStateAfterLaunch()
    }

    func start() {
        scheduleTimer()
        emitTick()
    }

    func togglePause() {
        if state.isPaused {
            resume()
        } else {
            pause()
        }
    }

    func pause() {
        guard !state.isPaused else { return }
        state.pausedRemaining = remainingTime
        state.isPaused = true
        invalidateTimer()
        emitTick()
    }

    func resume() {
        guard state.isPaused else { return }
        let duration = duration(for: state.phase)
        let remaining = state.pausedRemaining ?? duration
        state.phaseStartedAt = Date().addingTimeInterval(-1 * (duration - remaining))
        state.pausedRemaining = nil
        state.isPaused = false
        if state.phase == .focus {
            let elapsed = duration - remaining
            lastMicroReminderIndex = Int(elapsed / (3 * 60))
        }
        scheduleTimer()
        emitTick()
    }

    func reset() {
        state.phase = .focus
        state.phaseStartedAt = Date()
        state.pausedRemaining = nil
        state.isPaused = false
        lastMicroReminderIndex = 0
        scheduleTimer()
        onPhaseChange(.focus)
        emitTick()
    }

    func startExerciseNow() {
        transition(to: .exercise, notify: true, body: "现在开始活动 3 分钟。你可以站起来、走路、拉伸或喝水。")
    }

    func updateDurations(focusMinutes: Int, exerciseMinutes: Int) {
        state.focusDurationMinutes = max(1, focusMinutes)
        state.exerciseDurationMinutes = max(1, exerciseMinutes)
        reset()
    }

    func setMicroRemindersEnabled(_ enabled: Bool) {
        state.microRemindersEnabled = enabled
    }

    func setMajorReminderMode(_ mode: ReminderMode) {
        state.majorReminderMode = mode
    }

    func setMicroReminderMode(_ mode: ReminderMode) {
        state.microReminderMode = mode
    }

    func setShowCountdownInMenuBar(_ enabled: Bool) {
        state.showCountdownInMenuBar = enabled
    }

    func setMajorFlashBehavior(_ behavior: FlashBehavior) {
        state.majorFlashBehavior = behavior
    }

    func setMicroFlashBehavior(_ behavior: FlashBehavior) {
        state.microFlashBehavior = behavior
    }

    var remainingTime: TimeInterval {
        if state.isPaused {
            return max(0, state.pausedRemaining ?? duration(for: state.phase))
        }
        let elapsed = Date().timeIntervalSince(state.phaseStartedAt)
        return max(0, duration(for: state.phase) - elapsed)
    }

    private func scheduleTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(handleTickTimer),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func handleTickTimer() {
        handleTick()
    }

    private func handleTick() {
        emitTick()
        guard !state.isPaused else { return }

        if state.phase == .focus {
            handleMicroReminderIfNeeded()
        }

        if remainingTime <= 0 {
            advancePhase()
        }
    }

    private func emitTick() {
        onTick(state, remainingTime)
    }

    private func handleMicroReminderIfNeeded() {
        guard state.microRemindersEnabled else { return }

        let elapsed = Int(duration(for: state.phase) - remainingTime)
        let interval = 3 * 60
        guard elapsed >= interval else { return }

        let reminderIndex = elapsed / interval
        guard reminderIndex > lastMicroReminderIndex else { return }

        // Skip the terminal reminder because the full move cycle takes over at 27 minutes.
        guard elapsed < Int(duration(for: .focus)) else { return }

        lastMicroReminderIndex = reminderIndex
        deliverMicroReminder(
            title: "5 秒回神",
            body: "停 5 秒，把注意力拉回当前目标。"
        )
    }

    private func advancePhase() {
        switch state.phase {
        case .focus:
            transition(
                to: .exercise,
                notify: true,
                body: "专注时间到了，现在活动 3 分钟。"
            )
        case .exercise:
            transition(
                to: .focus,
                notify: true,
                body: "活动结束，开始新一轮专注。"
            )
        }
    }

    private func transition(to phase: CyclePhase, notify: Bool, body: String) {
        state.phase = phase
        state.phaseStartedAt = Date()
        state.pausedRemaining = nil
        state.isPaused = false
        lastMicroReminderIndex = 0
        scheduleTimer()
        onPhaseChange(phase)
        if notify {
            let title = phase == .exercise ? "该活动了" : "开始专注"
            deliverMajorReminder(title: title, body: body)
        }
        emitTick()
    }

    private func deliverMajorReminder(title: String, body: String) {
        switch state.majorReminderMode {
        case .flash:
            onMajorReminder(title, body)
        case .systemNotification:
            notificationManager.post(title: title, body: body)
        }
    }

    private func deliverMicroReminder(title: String, body: String) {
        switch state.microReminderMode {
        case .flash:
            onMicroReminder(title, body)
        case .systemNotification:
            notificationManager.post(title: title, body: body, sound: nil)
        }
    }

    private func normalizeStateAfterLaunch() {
        guard !state.isPaused else { return }

        var phase = state.phase
        var startedAt = state.phaseStartedAt
        var elapsed = Date().timeIntervalSince(startedAt)

        while elapsed >= duration(for: phase) {
            elapsed -= duration(for: phase)
            phase = (phase == .focus) ? .exercise : .focus
            startedAt = Date().addingTimeInterval(-elapsed)
        }

        state.phase = phase
        state.phaseStartedAt = startedAt

        if phase == .focus {
            lastMicroReminderIndex = Int(elapsed / (3 * 60))
        } else {
            lastMicroReminderIndex = 0
        }
    }

    private func saveState() {
        do {
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("Failed to save timer state: \(error.localizedDescription)")
        }
    }

    private static func loadState(from url: URL) -> TimerState? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(TimerState.self, from: data)
    }

    private func duration(for phase: CyclePhase) -> TimeInterval {
        switch phase {
        case .focus:
            return TimeInterval(state.focusDurationMinutes * 60)
        case .exercise:
            return TimeInterval(state.exerciseDurationMinutes * 60)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct FlashState {
        let message: String
        var isVisible: Bool
        var blinksRemaining: Int?
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let notificationManager = NotificationManager()
    private let launchAgentManager = LaunchAgentManager()
    private var engine: CycleEngine!
    private var flashState: FlashState?
    private var flashTimer: Timer?
    private var controlWindow: NSWindow!
    private var phaseCardView: NSView!
    private var flashBannerLabel: NSTextField!
    private var countdownValueLabel: NSTextField!
    private var controlStatusLabel: NSTextField!
    private var controlHintLabel: NSTextField!
    private var pauseResumeButton: NSButton!
    private var microReminderCheckbox: NSButton!
    private var startupCheckbox: NSButton!
    private var menuCountdownCheckbox: NSButton!
    private var focusMinutesField: NSTextField!
    private var exerciseMinutesField: NSTextField!
    private var majorModePopup: NSPopUpButton!
    private var microModePopup: NSPopUpButton!
    private var majorFlashBehaviorPopup: NSPopUpButton!
    private var microFlashBehaviorPopup: NSPopUpButton!

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let showWindowItem = NSMenuItem(title: "显示控制窗口", action: #selector(showControlWindow), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()
        setupControlWindow()
        setupStatusItem()
        setupMenu()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stateURL = appSupport
            .appendingPathComponent("SportWork", isDirectory: true)
            .appendingPathComponent("state.json")

        engine = CycleEngine(
            notificationManager: notificationManager,
            persistenceURL: stateURL,
            onTick: { [weak self] state, remaining in
                self?.updateUI(for: state, remaining: remaining)
            },
            onPhaseChange: { _ in },
            onMajorReminder: { [weak self] title, _ in
                self?.flashMenuBar(
                    with: title == "该活动了" ? "动一动" : "专注",
                    behavior: self?.engine.state.majorFlashBehavior ?? .untilClicked
                )
            },
            onMicroReminder: { [weak self] _, _ in
                self?.flashMenuBar(
                    with: "回神",
                    behavior: self?.engine.state.microFlashBehavior ?? .threeBlinks
                )
            }
        )

        engine.start()
        showControlWindow()
        showFirstLaunchHintIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        flashTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    @objc private func togglePause() {
        engine.togglePause()
    }

    @objc private func toggleMicroReminders() {
        let enabled = !engine.state.microRemindersEnabled
        engine.setMicroRemindersEnabled(enabled)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func toggleLaunchAtLoginFromCheckbox() {
        toggleLaunchAtLogin()
    }

    @objc private func toggleMenuCountdownVisibility() {
        engine.setShowCountdownInMenuBar(menuCountdownCheckbox.state == .on)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAgentManager.isEnabled {
                try launchAgentManager.disable()
            } else {
                try launchAgentManager.enable(appPath: Bundle.main.bundleURL.path)
            }
            updateUI(for: engine.state, remaining: engine.remainingTime)
        } catch {
            presentInfoAlert(title: "无法修改开机启动设置", message: error.localizedDescription)
        }
    }

    @objc private func applyDurationsFromWindow() {
        let focusValue = Int(focusMinutesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let exerciseValue = Int(exerciseMinutesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        guard let focusValue, let exerciseValue, focusValue > 0, exerciseValue > 0 else {
            presentInfoAlert(title: "输入无效", message: "请输入大于 0 的整数分钟数。")
            return
        }

        engine.updateDurations(focusMinutes: focusValue, exerciseMinutes: exerciseValue)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func majorReminderModeChanged() {
        let mode: ReminderMode = majorModePopup.indexOfSelectedItem == 0 ? .flash : .systemNotification
        engine.setMajorReminderMode(mode)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func microReminderModeChanged() {
        let mode: ReminderMode = microModePopup.indexOfSelectedItem == 0 ? .flash : .systemNotification
        engine.setMicroReminderMode(mode)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func majorFlashBehaviorChanged() {
        let behavior: FlashBehavior = majorFlashBehaviorPopup.indexOfSelectedItem == 0 ? .untilClicked : .threeBlinks
        engine.setMajorFlashBehavior(behavior)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func microFlashBehaviorChanged() {
        let behavior: FlashBehavior = microFlashBehaviorPopup.indexOfSelectedItem == 0 ? .untilClicked : .threeBlinks
        engine.setMicroFlashBehavior(behavior)
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    @objc private func startMoveNow() {
        engine.startExerciseNow()
    }

    @objc private func resetCycle() {
        engine.reset()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showControlWindow() {
        stopFlashingIfNeeded()
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func hideControlWindow() {
        controlWindow.orderOut(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        stopFlashingIfNeeded()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "figure.walk.circle.fill", accessibilityDescription: "SportWork")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " 专注"
        }
        statusItem.menu = menu
        menu.delegate = self
    }

    private func setupMenu() {
        statusLineItem.isEnabled = false

        showWindowItem.target = self
        quitItem.target = self

        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(showWindowItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    private func updateUI(for state: TimerState, remaining: TimeInterval) {
        let countdown = Self.formatTime(remaining)
        let phaseLabel = state.phase == .focus ? "专注" : "活动"
        let menuLabel = state.phase == .focus ? "专注" : "活动"
        let pausedSuffix = state.isPaused ? "（已暂停）" : ""

        statusLineItem.title = "当前阶段：\(phaseLabel)\(pausedSuffix)"
        controlStatusLabel.stringValue = "当前阶段：\(phaseLabel)\(pausedSuffix)"
        controlHintLabel.stringValue = state.showCountdownInMenuBar
            ? "菜单栏显示：\(menuLabel) \(countdown)"
            : "菜单栏显示：\(menuLabel)"

        countdownValueLabel.stringValue = countdown
        countdownValueLabel.textColor = state.isPaused ? .secondaryLabelColor : .labelColor
        pauseResumeButton.title = state.isPaused ? "继续计时" : "暂停计时"
        microReminderCheckbox.state = state.microRemindersEnabled ? .on : .off
        startupCheckbox.state = launchAgentManager.isEnabled ? .on : .off
        menuCountdownCheckbox.state = state.showCountdownInMenuBar ? .on : .off
        focusMinutesField.stringValue = String(state.focusDurationMinutes)
        exerciseMinutesField.stringValue = String(state.exerciseDurationMinutes)
        majorModePopup.selectItem(at: state.majorReminderMode == .flash ? 0 : 1)
        microModePopup.selectItem(at: state.microReminderMode == .flash ? 0 : 1)
        majorFlashBehaviorPopup.selectItem(at: state.majorFlashBehavior == .untilClicked ? 0 : 1)
        microFlashBehaviorPopup.selectItem(at: state.microFlashBehavior == .untilClicked ? 0 : 1)
        phaseCardView.wantsLayer = true
        phaseCardView.layer?.backgroundColor = (state.phase == .focus
            ? NSColor.systemBlue.withAlphaComponent(0.12)
            : NSColor.systemGreen.withAlphaComponent(0.12)).cgColor

        if let button = statusItem.button {
            if let flashState {
                button.title = flashState.isVisible ? " \(flashState.message)" : "      "
            } else {
                self.flashState = nil
                stopFlashTimer()
                button.title = state.showCountdownInMenuBar ? " \(menuLabel) \(countdown)" : " \(menuLabel)"
            }
            button.toolTip = "SportWork - \(phaseLabel)\(pausedSuffix)"
        }
    }

    private func flashMenuBar(with message: String, behavior: FlashBehavior) {
        flashState = FlashState(
            message: message,
            isVisible: true,
            blinksRemaining: behavior == .threeBlinks ? 6 : nil
        )
        flashBannerLabel.stringValue = message
        flashBannerLabel.isHidden = false
        flashBannerLabel.textColor = .white
        flashBannerLabel.backgroundColor = message == "回神" ? .systemOrange : .systemBlue
        flashBannerLabel.drawsBackground = true
        startFlashTimer()
        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    private func stopFlashingIfNeeded() {
        guard flashState != nil else { return }
        flashState = nil
        flashBannerLabel.isHidden = true
        updateUI(for: engine.state, remaining: engine.remainingTime)
        stopFlashTimer()
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func showFirstLaunchHintIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "hasShownMenuBarHint"
        guard defaults.bool(forKey: key) == false else { return }

        let alert = NSAlert()
        alert.messageText = "SportWork 已启动"
        alert.informativeText = "这个应用会显示主窗口，并在菜单栏显示当前阶段。Dock 中不会显示图标，主要操作请直接使用主窗口。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "我知道了")
        alert.runModal()

        defaults.set(true, forKey: key)
    }

    private func setupControlWindow() {
        let rect = NSRect(x: 0, y: 0, width: 960, height: 720)
        controlWindow = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        controlWindow.titlebarAppearsTransparent = true
        controlWindow.title = ""
        controlWindow.isMovableByWindowBackground = true
        controlWindow.center()
        controlWindow.isReleasedWhenClosed = false

        let effectView = NSVisualEffectView(frame: rect)
        effectView.material = .underWindowBackground
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        controlWindow.contentView = effectView

        flashBannerLabel = NSTextField(labelWithString: "")
        flashBannerLabel.alignment = .center
        flashBannerLabel.font = .boldSystemFont(ofSize: 18)
        flashBannerLabel.textColor = .white
        flashBannerLabel.wantsLayer = true
        flashBannerLabel.layer?.cornerRadius = 12
        flashBannerLabel.layer?.masksToBounds = true
        flashBannerLabel.drawsBackground = true
        flashBannerLabel.isHidden = true
        flashBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(flashBannerLabel)

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            flashBannerLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 18),
            flashBannerLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            flashBannerLabel.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            flashBannerLabel.heightAnchor.constraint(equalToConstant: 44),

            contentStack.topAnchor.constraint(equalTo: flashBannerLabel.bottomAnchor, constant: 22),
            contentStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -28),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: effectView.bottomAnchor, constant: -28)
        ])

        let titleLabel = NSTextField(labelWithString: "SportWork")
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: "极简专注节奏控制台")
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        contentStack.addArrangedSubview(headerStack)

        phaseCardView = makeCard(frame: .zero)
        phaseCardView.translatesAutoresizingMaskIntoConstraints = false
        phaseCardView.widthAnchor.constraint(equalToConstant: 904).isActive = true
        phaseCardView.heightAnchor.constraint(equalToConstant: 156).isActive = true

        let phaseCardTitle = makeSectionTitle("当前状态", origin: .zero)
        controlStatusLabel = NSTextField(labelWithString: "状态载入中…")
        controlStatusLabel.font = .systemFont(ofSize: 30, weight: .bold)
        controlStatusLabel.textColor = .labelColor
        controlStatusLabel.isBordered = false
        controlStatusLabel.drawsBackground = false

        countdownValueLabel = NSTextField(labelWithString: "00:00")
        countdownValueLabel.font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        countdownValueLabel.textColor = .labelColor
        countdownValueLabel.isBordered = false
        countdownValueLabel.drawsBackground = false

        controlHintLabel = NSTextField(labelWithString: "菜单栏将显示当前阶段")
        controlHintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        controlHintLabel.textColor = .secondaryLabelColor
        controlHintLabel.isBordered = false
        controlHintLabel.drawsBackground = false

        let helpLabel = NSTextField(wrappingLabelWithString: "菜单栏默认只显示当前阶段，避免分散注意力。所有设置都集中在主窗口里：先看状态，再做操作，再调整提醒与时长。")
        helpLabel.font = .systemFont(ofSize: 13)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.maximumNumberOfLines = 2
        helpLabel.preferredMaxLayoutWidth = 420

        let phaseLeftStack = NSStackView(views: [phaseCardTitle, controlStatusLabel, countdownValueLabel])
        phaseLeftStack.orientation = NSUserInterfaceLayoutOrientation.vertical
        phaseLeftStack.alignment = NSLayoutConstraint.Attribute.leading
        phaseLeftStack.spacing = 8

        let phaseRightStack = NSStackView(views: [controlHintLabel, helpLabel])
        phaseRightStack.orientation = NSUserInterfaceLayoutOrientation.vertical
        phaseRightStack.alignment = NSLayoutConstraint.Attribute.leading
        phaseRightStack.spacing = 14

        let phaseContent = NSStackView(views: [phaseLeftStack, phaseRightStack])
        phaseContent.orientation = NSUserInterfaceLayoutOrientation.horizontal
        phaseContent.alignment = NSLayoutConstraint.Attribute.top
        phaseContent.distribution = NSStackView.Distribution.fillEqually
        phaseContent.spacing = 36
        phaseContent.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        phaseContent.translatesAutoresizingMaskIntoConstraints = false
        phaseCardView.addSubview(phaseContent)

        NSLayoutConstraint.activate([
            phaseContent.topAnchor.constraint(equalTo: phaseCardView.topAnchor),
            phaseContent.leadingAnchor.constraint(equalTo: phaseCardView.leadingAnchor),
            phaseContent.trailingAnchor.constraint(equalTo: phaseCardView.trailingAnchor),
            phaseContent.bottomAnchor.constraint(equalTo: phaseCardView.bottomAnchor)
        ])

        contentStack.addArrangedSubview(phaseCardView)

        let quickCard = makeCard(frame: .zero)
        quickCard.translatesAutoresizingMaskIntoConstraints = false
        quickCard.widthAnchor.constraint(equalToConstant: 904).isActive = true
        quickCard.heightAnchor.constraint(equalToConstant: 96).isActive = true
        quickCard.addSubview(makeSectionTitle("快速操作", origin: NSPoint(x: 24, y: 62)))

        pauseResumeButton = NSButton(title: "暂停计时", target: self, action: #selector(togglePause))
        let moveNowButton = NSButton(title: "立即切到活动", target: self, action: #selector(startMoveNow))
        let resetButton = NSButton(title: "重置循环", target: self, action: #selector(resetCycle))
        let hideButton = NSButton(title: "隐藏窗口", target: self, action: #selector(hideControlWindow))
        let quitButton = NSButton(title: "退出应用", target: self, action: #selector(quit))

        [pauseResumeButton, moveNowButton, resetButton, hideButton, quitButton].forEach { button in
            styleButton(button, primary: button == pauseResumeButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: button == moveNowButton ? 148 : 128).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }

        let quickButtons = NSStackView(views: [pauseResumeButton, moveNowButton, resetButton, hideButton, quitButton].compactMap { $0 })
        quickButtons.orientation = .horizontal
        quickButtons.alignment = .centerY
        quickButtons.spacing = 14
        quickButtons.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 18, right: 24)
        quickButtons.translatesAutoresizingMaskIntoConstraints = false
        quickCard.addSubview(quickButtons)

        NSLayoutConstraint.activate([
            quickButtons.leadingAnchor.constraint(equalTo: quickCard.leadingAnchor),
            quickButtons.trailingAnchor.constraint(lessThanOrEqualTo: quickCard.trailingAnchor),
            quickButtons.bottomAnchor.constraint(equalTo: quickCard.bottomAnchor)
        ])

        contentStack.addArrangedSubview(quickCard)

        let lowerRow = NSStackView()
        lowerRow.orientation = .horizontal
        lowerRow.alignment = .top
        lowerRow.spacing = 22
        lowerRow.distribution = .fillEqually
        lowerRow.translatesAutoresizingMaskIntoConstraints = false

        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 22

        let displayCard = makeCard(frame: .zero)
        displayCard.translatesAutoresizingMaskIntoConstraints = false
        displayCard.widthAnchor.constraint(equalToConstant: 441).isActive = true
        displayCard.heightAnchor.constraint(equalToConstant: 144).isActive = true
        displayCard.addSubview(makeSectionTitle("显示与启动", origin: NSPoint(x: 24, y: 102)))

        menuCountdownCheckbox = NSButton(checkboxWithTitle: "菜单栏显示倒计时", target: self, action: #selector(toggleMenuCountdownVisibility))
        startupCheckbox = NSButton(checkboxWithTitle: "开机自动启动", target: self, action: #selector(toggleLaunchAtLoginFromCheckbox))
        [menuCountdownCheckbox, startupCheckbox].forEach { checkbox in
            styleCheckbox(checkbox)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
        }

        let displayOptions = NSStackView(views: [menuCountdownCheckbox, startupCheckbox])
        displayOptions.orientation = .vertical
        displayOptions.alignment = .leading
        displayOptions.spacing = 14
        displayOptions.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 20, right: 24)
        displayOptions.translatesAutoresizingMaskIntoConstraints = false
        displayCard.addSubview(displayOptions)

        NSLayoutConstraint.activate([
            displayOptions.leadingAnchor.constraint(equalTo: displayCard.leadingAnchor),
            displayOptions.trailingAnchor.constraint(lessThanOrEqualTo: displayCard.trailingAnchor),
            displayOptions.bottomAnchor.constraint(equalTo: displayCard.bottomAnchor)
        ])

        let durationCard = makeCard(frame: .zero)
        durationCard.translatesAutoresizingMaskIntoConstraints = false
        durationCard.widthAnchor.constraint(equalToConstant: 441).isActive = true
        durationCard.heightAnchor.constraint(equalToConstant: 124).isActive = true
        durationCard.addSubview(makeSectionTitle("时长设置", origin: NSPoint(x: 24, y: 82)))

        let focusLabel = makeFieldLabel("专注分钟数")
        let exerciseLabel = makeFieldLabel("活动分钟数")

        focusMinutesField = NSTextField(string: "")
        exerciseMinutesField = NSTextField(string: "")
        [focusMinutesField, exerciseMinutesField].forEach { field in
            styleTextField(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        let applyButton = NSButton(title: "应用时长", target: self, action: #selector(applyDurationsFromWindow))
        styleButton(applyButton, primary: true)
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        applyButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let durationRow = NSStackView()
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.spacing = 12
        durationRow.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 18, right: 24)
        durationRow.translatesAutoresizingMaskIntoConstraints = false

        [focusLabel, focusMinutesField, exerciseLabel, exerciseMinutesField, applyButton].forEach {
            durationRow.addArrangedSubview($0)
        }
        durationCard.addSubview(durationRow)

        NSLayoutConstraint.activate([
            durationRow.leadingAnchor.constraint(equalTo: durationCard.leadingAnchor),
            durationRow.trailingAnchor.constraint(lessThanOrEqualTo: durationCard.trailingAnchor, constant: -24),
            durationRow.bottomAnchor.constraint(equalTo: durationCard.bottomAnchor)
        ])

        leftColumn.addArrangedSubview(displayCard)
        leftColumn.addArrangedSubview(durationCard)

        let reminderCard = makeCard(frame: .zero)
        reminderCard.translatesAutoresizingMaskIntoConstraints = false
        reminderCard.widthAnchor.constraint(equalToConstant: 441).isActive = true
        reminderCard.heightAnchor.constraint(equalToConstant: 290).isActive = true
        reminderCard.addSubview(makeSectionTitle("提醒策略", origin: NSPoint(x: 24, y: 248)))

        microReminderCheckbox = NSButton(checkboxWithTitle: "开启每 3 分钟回神提醒", target: self, action: #selector(toggleMicroReminders))
        styleCheckbox(microReminderCheckbox)
        microReminderCheckbox.translatesAutoresizingMaskIntoConstraints = false
        reminderCard.addSubview(microReminderCheckbox)

        majorModePopup = createPopup(items: [ReminderMode.flash.menuLabel, ReminderMode.systemNotification.menuLabel], action: #selector(majorReminderModeChanged))
        majorFlashBehaviorPopup = createPopup(items: [FlashBehavior.untilClicked.menuLabel, FlashBehavior.threeBlinks.menuLabel], action: #selector(majorFlashBehaviorChanged))
        microModePopup = createPopup(items: [ReminderMode.flash.menuLabel, ReminderMode.systemNotification.menuLabel], action: #selector(microReminderModeChanged))
        microFlashBehaviorPopup = createPopup(items: [FlashBehavior.untilClicked.menuLabel, FlashBehavior.threeBlinks.menuLabel], action: #selector(microFlashBehaviorChanged))

        [majorModePopup, majorFlashBehaviorPopup, microModePopup, microFlashBehaviorPopup].forEach { popup in
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 252).isActive = true
            popup.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        let reminderGrid = NSGridView(views: [
            [makeFieldLabel("阶段切换提醒"), majorModePopup],
            [makeFieldLabel("阶段切换闪烁"), majorFlashBehaviorPopup],
            [makeFieldLabel("回神提醒"), microModePopup],
            [makeFieldLabel("回神闪烁"), microFlashBehaviorPopup]
        ])
        reminderGrid.rowSpacing = 14
        reminderGrid.columnSpacing = 18
        reminderGrid.translatesAutoresizingMaskIntoConstraints = false
        reminderCard.addSubview(reminderGrid)

        NSLayoutConstraint.activate([
            microReminderCheckbox.leadingAnchor.constraint(equalTo: reminderCard.leadingAnchor, constant: 24),
            microReminderCheckbox.topAnchor.constraint(equalTo: reminderCard.topAnchor, constant: 56),

            reminderGrid.leadingAnchor.constraint(equalTo: reminderCard.leadingAnchor, constant: 24),
            reminderGrid.topAnchor.constraint(equalTo: microReminderCheckbox.bottomAnchor, constant: 18)
        ])

        lowerRow.addArrangedSubview(leftColumn)
        lowerRow.addArrangedSubview(reminderCard)
        contentStack.addArrangedSubview(lowerRow)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeSectionTitle(_ text: String, origin: NSPoint) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(origin: origin, size: NSSize(width: 180, height: 20))
        return label
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        label.frame = NSRect(x: 0, y: 0, width: 110, height: 20)
        return label
    }

    private func createPopup(items: [String], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = action
        popup.font = .systemFont(ofSize: 13)
        return popup
    }

    private func makeCard(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.06).cgColor
        return view
    }

    private func styleButton(_ button: NSButton, primary: Bool) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        if primary {
            button.contentTintColor = .controlAccentColor
        }
    }

    private func styleTextField(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.alignment = .center
    }

    private func styleCheckbox(_ checkbox: NSButton) {
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
    }

    private func startFlashTimer() {
        stopFlashTimer()
        flashTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(handleFlashTimer),
            userInfo: nil,
            repeats: true
        )

        if let flashTimer {
            RunLoop.main.add(flashTimer, forMode: .common)
        }
    }

    private func stopFlashTimer() {
        flashTimer?.invalidate()
        flashTimer = nil
    }

    @objc private func handleFlashTimer() {
        guard var flashState else {
            flashBannerLabel.isHidden = true
            stopFlashTimer()
            return
        }

        flashState.isVisible.toggle()

        if let remaining = flashState.blinksRemaining {
            let nextValue = remaining - 1
            flashState.blinksRemaining = nextValue
            if nextValue <= 0 {
                self.flashState = nil
                flashBannerLabel.isHidden = true
                updateUI(for: engine.state, remaining: engine.remainingTime)
                stopFlashTimer()
                return
            }
        }

        self.flashState = flashState
        flashBannerLabel.isHidden = !flashState.isVisible

        if flashState.blinksRemaining == nil {
            updateUI(for: engine.state, remaining: engine.remainingTime)
            return
        }

        updateUI(for: engine.state, remaining: engine.remainingTime)
    }

    private static func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
