import AppKit
import Combine
import SwiftUI

// MARK: - Environment

/// Wires the object graph together. Created once in `main.swift`.
@MainActor
final class AppEnvironment {
    static var shared: AppEnvironment!

    let config: AppConfig
    let notifier: any NotificationSending
    let sessionStore: SessionStore
    let scheduler: ResumeScheduler
    let model: DashboardModel

    init(config: AppConfig,
         clock: any Clock = SystemClock(),
         store: (any ContinuationStoring)? = nil,
         launcher: (any ProcessLaunching)? = nil,
         notifier: (any NotificationSending)? = nil,
         usageFixture: URL? = nil) {
        self.config = config
        self.notifier = notifier ?? (config.isSandbox || config.isHeadless
            ? NullNotificationService()
            : SystemNotificationService())
        self.sessionStore = SessionStore(config: config)
        self.scheduler = ResumeScheduler(
            config: config,
            clock: clock,
            store: store,
            launcher: launcher,
            notifier: self.notifier,
            sessionStore: self.sessionStore
        )
        self.model = DashboardModel(
            config: config,
            scheduler: scheduler,
            notifier: self.notifier,
            sessionStore: sessionStore,
            usageFixture: usageFixture
        )
    }
}

// MARK: - Dashboard model

enum RefreshReason: Sendable {
    case launch
    case popover
    case manual
    case automatic
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var reading: UsageReading?
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    /// Seconds until the 5-hour window is forecast to run dry, when the data supports a forecast.
    @Published private(set) var primaryETA: TimeInterval?
    /// Current burn rate divided by the long-run baseline. `2` means twice the usual pace.
    @Published private(set) var primaryPace: Double?
    @Published private(set) var willRunDry: Bool = false
    @Published private(set) var updatedText: String = "Not loaded"
    @Published private(set) var tokenUsage: [String: TokenUsage] = [:]

    let scheduler: ResumeScheduler

    private let config: AppConfig
    private let notifier: any NotificationSending
    private let sessionStore: SessionStore
    private let service: CodexDataService
    private let usageFixture: URL?
    private var history: UsageHistory
    private var quotaNotifier: QuotaNotifier
    private var lastSuccessfulRefresh: Date?
    private var nextAutomaticRefreshAt: Date?
    private var lastScheduledResetAt: Date?

    init(config: AppConfig,
         scheduler: ResumeScheduler,
         notifier: any NotificationSending,
         sessionStore: SessionStore,
         usageFixture: URL? = nil) {
        self.config = config
        self.scheduler = scheduler
        self.notifier = notifier
        self.sessionStore = sessionStore
        self.service = CodexDataService(config: config)
        self.usageFixture = usageFixture
        self.history = UsageHistory(config: config)
        self.quotaNotifier = QuotaNotifier(config: config)
        restoreCachedReading()
    }

    // MARK: - Refresh

    /// Refreshes sessions and usage. Concurrent callers share one in-flight refresh.
    func refresh(reason: RefreshReason = .manual) async {
        if isRefreshing {
            AppLog.debug("refresh skipped: already refreshing", category: .usage)
            return
        }
        // Automatic refreshes are scheduled from the last result. This avoids a network request
        // on every title repaint while still using server-provided retry delays after transient
        // failures.
        if reason == .automatic,
           let next = nextAutomaticRefreshAt,
           Date() < next {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        // The scheduler and dashboard must share one ThreadDirectory, otherwise the database cwd
        // cache populated during refresh is thrown away before a continuation launches.
        let loaded = await sessionStore.loadSessions()
        sessions = loaded
        scheduler.updateSessions(loaded)
        tokenUsage = await sessionStore.loadTokenUsage(for: loaded)

        do {
            let snapshot = try await service.fetchUsage()
            apply(.success(UsageReading(snapshot: snapshot, fetchedAt: Date())))
            nextAutomaticRefreshAt = Date().addingTimeInterval(config.usageRefreshInterval)
        } catch {
            apply(.failure(error))
            let delay = (error as? CodexDataError)?.isTransient == true
                ? (error as? CodexDataError)?.retryDelay ?? config.usageRefreshInterval
                : config.usageRefreshInterval
            nextAutomaticRefreshAt = Date().addingTimeInterval(max(config.usageRefreshFloor, delay))
        }
    }

    private func apply(_ result: Result<UsageReading, Error>) {
        switch result {
        case .success(let reading):
            let previous = self.reading
            self.reading = reading
            errorMessage = nil
            lastSuccessfulRefresh = reading.fetchedAt
            cacheReading(reading)
            recordHistory(reading)
            // Only re-arm scheduling when the reset time actually moved, so opening the popover
            // repeatedly does not rebuild the continuation timers.
            if lastScheduledResetAt == nil || reading.snapshot.primary.resetAt != lastScheduledResetAt {
                lastScheduledResetAt = reading.snapshot.primary.resetAt
                scheduler.schedule(resetAt: reading.snapshot.primary.resetAt)
            }
            if previous == nil || previous?.snapshot.primary.resetAt != reading.snapshot.primary.resetAt {
                AppLog.info("usage refreshed: primary \(reading.snapshot.primary.remainingPercent)% remaining",
                            category: .usage)
            }
            for event in quotaNotifier.evaluate(reading) {
                AppLog.info("quota event \(event.kind) for \(event.title)", category: .notification)
                notifier.post(title: event.title, body: event.body,
                              identifier: event.notificationIdentifier, urgent: event.isUrgent)
            }
            persistQuotaState()
        case .failure(let error):
            // Keep the last good reading on screen and say how old it is, rather than blanking out.
            errorMessage = error.localizedDescription
            AppLog.warning("usage refresh failed: \(error.localizedDescription)", category: .usage)
        }
        refreshDerivedState()
    }

    private func recordHistory(_ reading: UsageReading) {
        let now = reading.fetchedAt
        history.record(.primary, remainingFraction: Double(reading.snapshot.primary.remainingPercent) / 100, at: now)
        history.record(.secondary, remainingFraction: Double(reading.snapshot.secondary.remainingPercent) / 100, at: now)
    }

    private func refreshDerivedState() {
        guard let reading else {
            updatedText = errorMessage ?? "Not loaded"
            primaryETA = nil
            primaryPace = nil
            willRunDry = false
            return
        }
        updatedText = TextFormat.relativeAge(Date().timeIntervalSince(reading.fetchedAt))
        let remaining = Double(reading.snapshot.primary.remainingPercent) / 100
        primaryETA = history.burnETA(.primary, remainingFraction: remaining, at: Date())
        primaryPace = history.pace(.primary, at: Date())
        willRunDry = history.willRunDry(
            .primary,
            remainingFraction: remaining,
            resetAt: reading.snapshot.primary.resetAt,
            at: Date()
        )
    }

    var totalTokenUsage: TokenUsage? {
        tokenUsage.values.reduce(nil) { partial, usage in
            partial.map { $0.adding(usage) } ?? usage
        }
    }

    /// Called on the title timer so the relative age stays honest without a network call.
    func tickPresentation() {
        refreshDerivedState()
        guard !isRefreshing,
              nextAutomaticRefreshAt.map({ Date() >= $0 }) ?? true else { return }
        Task { await self.refresh(reason: .automatic) }
    }

    // MARK: - Freshness

    func freshness(for window: UsageWindowKey) -> UsageFreshness {
        guard let reading else { return .unknown }
        let threshold = window == .primary ? config.stalePrimary : config.staleSecondary
        let age = Date().timeIntervalSince(reading.fetchedAt)
        return age > threshold ? .stale : .fresh
    }

    var isStale: Bool {
        guard reading != nil else { return false }
        return freshness(for: .primary) == .stale || freshness(for: .secondary) == .stale
    }

    // MARK: - Cached reading

    private static let cacheKey = "cachedUsageReading"
    private static let quotaKey = "quotaNotifierState"
    private static let historyKey = "usageHistory"

    private var cacheSuite: UserDefaults {
        if let suite = config.defaultsSuite, let sandbox = UserDefaults(suiteName: suite) { return sandbox }
        return .standard
    }

    private func cacheReading(_ reading: UsageReading) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        cacheSuite.set(data, forKey: Self.cacheKey)
    }

    private func restoreCachedReading() {
        guard let data = cacheSuite.data(forKey: Self.cacheKey),
              let reading = try? JSONDecoder().decode(UsageReading.self, from: data) else { return }
        self.reading = reading
        if let state = cacheSuite.data(forKey: Self.quotaKey),
           let decoded = try? JSONDecoder().decode([UsageWindowKey: QuotaChannelState].self, from: state) {
            quotaNotifier.restore(decoded)
        }
        if let state = cacheSuite.data(forKey: Self.historyKey),
           let decoded = try? JSONDecoder().decode(UsageHistory.Snapshot.self, from: state) {
            history = UsageHistory(config: config, snapshot: decoded)
        }
        refreshDerivedState()
    }

    private func persistQuotaState() {
        guard let data = try? JSONEncoder().encode(quotaNotifier.persisted) else { return }
        cacheSuite.set(data, forKey: Self.quotaKey)
        guard let historyData = try? JSONEncoder().encode(history.persisted) else { return }
        cacheSuite.set(historyData, forKey: Self.historyKey)
    }

    func open(_ session: CodexSession) { scheduler.open(session) }
}

// MARK: - Status bar delegate

/// Hosting controller that keeps the popover height adaptive: it hugs the SwiftUI content
/// height up to `maxPopoverHeight`, beyond which the inner session list scrolls.
///
/// It only reports `preferredContentSize` and lets `NSPopover` keep the arrow anchored.
/// Manually moving the popover window here fights the open animation and drifts the arrow
/// up into the menu bar.
@MainActor
final class AdaptivePopoverController: NSHostingController<MenuContent> {
    var maxPopoverHeight: CGFloat = 640
    var minPopoverHeight: CGFloat = 280
    private var lastHeight: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        let fitting = view.fittingSize
        guard fitting.height.isFinite, fitting.height > 0 else { return }
        let target = min(max(fitting.height, minPopoverHeight), maxPopoverHeight)
        guard abs(target - lastHeight) > 1 else { return }
        lastHeight = target
        preferredContentSize = NSSize(width: 520, height: target)
    }
}

@MainActor
final class StatusBarDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var ticker: Timer?
    private var observation: AnyCancellable?
    private var lastTitle: String?
    private var lastSymbolName: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Codex Resets Window"

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 520, height: 400)
        popover.contentViewController = AdaptivePopoverController(rootView: MenuContent(model: environment.model,
                                                                                   scheduler: environment.scheduler))

        observation = environment.model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: environment.config.titleRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.environment.model.tickPresentation()
                self?.updateStatusItem()
            }
        }
        // Re-render immediately when the system switches between light and dark.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(interfaceThemeChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.scheduler.shutdown()
    }

    @objc private func interfaceThemeChanged() { updateStatusItem() }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let model = environment.model
        let symbol = model.isStale ? "exclamationmark.triangle" : "circle.hexagonpath"
        // Rebuilding the image on every tick is wasteful; only swap it when the glyph changes.
        if symbol != lastSymbolName {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ChatGPT usage timer")
            lastSymbolName = symbol
        }
        let title: String
        if let primary = model.reading?.snapshot.primary {
            title = "\(primary.remainingPercent)% · \(primary.countdownText())"
        } else if model.errorMessage != nil {
            title = "Codex ?"
        } else {
            title = "Codex"
        }
        if title != lastTitle {
            button.title = title
            lastTitle = title
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await environment.model.refresh(reason: .popover) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// MARK: - Menu bar mark

struct CodexTimerMark: View {
    let progress: Double
    let stale: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .stroke(.secondary.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(stale ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: stale ? "exclamationmark.triangle" : "circle.hexagonpath")
                .font(.system(size: 10, weight: .bold))
            Image(systemName: "timer")
                .font(.system(size: 7, weight: .bold))
                .padding(1.5)
                .background(.background, in: Circle())
                .offset(x: 2, y: 2)
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel("ChatGPT usage timer")
    }
}

// MARK: - Popover content

struct MenuContent: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var scheduler: ResumeScheduler
    @State private var query = ""
    @State private var visibleCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            usageSection
            Divider()
            sessionSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Codex Resets Window").font(.headline.weight(.semibold))
            Spacer()
            if model.reading != nil {
                Text(model.updatedText)
                    .font(.caption2)
                    .foregroundStyle(model.isStale ? .orange : .secondary)
                    .help("Last successful usage refresh")
            }
            Button { Task { await model.refresh(reason: .manual) } } label: {
                Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
            .disabled(model.isRefreshing)
            .help("Refresh usage and sessions")
            .accessibilityLabel("Refresh usage and sessions")
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        if let reading = model.reading {
            HStack(spacing: 8) {
                UsageMiniCard(
                    title: "5 hours",
                    window: reading.snapshot.primary,
                    accent: Color(red: 0.96, green: 0.55, blue: 0.46),
                    showsDate: false,
                    freshness: model.freshness(for: .primary)
                )
                UsageMiniCard(
                    title: "Weekly",
                    window: reading.snapshot.secondary,
                    accent: Color(red: 0.30, green: 0.72, blue: 0.70),
                    showsDate: true,
                    freshness: model.freshness(for: .secondary)
                )
            }
            if let eta = model.primaryETA, model.willRunDry {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("Empty in ~\(TextFormat.countdown(eta))")
                    if let pace = model.primaryPace, pace > 1.3 {
                        Text("· \(String(format: "%.1f×", pace)) your usual pace")
                    }
                    Spacer()
                    Text("resets \(TextFormat.countdown(reading.snapshot.primary.resetAt.timeIntervalSinceNow))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .transition(.opacity)
            }
            if let error = model.errorMessage {
                Label("Refresh failed: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let total = model.totalTokenUsage {
                HStack(spacing: 5) {
                    Image(systemName: "number")
                    Text("Measured local tokens: \(total.compactTotal)")
                    Text("· \(model.tokenUsage.count) sessions")
                        .foregroundStyle(.secondary)
                    if let measuredAt = total.measuredAt {
                        Text("· last \(TextFormat.relativeAge(Date().timeIntervalSince(measuredAt)))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("\(total.detailDescription). Cumulative token_count totals from local Codex transcripts; quota percentages above are separate official usage data.")
            } else if !model.sessions.isEmpty {
                Label("Measured token stats unavailable in recent transcripts", systemImage: "number")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Codex only exposes token totals for transcripts that contain a structured token_count event.")
            }
        } else if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var matchedSessions: [CodexSession] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? model.sessions
            : model.sessions.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var filteredSessions: [CodexSession] {
        let base = matchedSessions
        let limit = max(initialLimit, visibleCount)
        if base.count <= limit { return base }
        // Always keep armed sessions visible, even when the list is collapsed.
        let armed = Set(model.scheduler.enabledIDs)
        var result = base.filter { armed.contains($0.id) }
        let remaining = base.filter { !armed.contains($0.id) }
        result.append(contentsOf: remaining.prefix(max(0, limit - result.count)))
        return result
    }

    private var initialLimit: Int { AppEnvironment.shared.config.recentSessionLimit }
    private var pageStep: Int { AppEnvironment.shared.config.sessionPageStep }

    @ViewBuilder
    private var sessionSection: some View {
        HStack {
            Text("Local Codex sessions").font(.headline)
            Spacer()
            Text("\(model.sessions.count)").font(.caption).foregroundStyle(.secondary)
        }
        if !model.sessions.isEmpty {
            TextField("Search sessions", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onChange(of: query) { _, _ in visibleCount = initialLimit }
        }
        if model.sessions.isEmpty {
            Text("No local sessions found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
        } else if filteredSessions.isEmpty {
            Text("No session matches “\(query)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredSessions) { session in
                        SessionRow(session: session, model: model, scheduler: scheduler)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            let hidden = matchedSessions.count - filteredSessions.count
            if hidden > 0 || visibleCount > initialLimit {
                HStack(spacing: 12) {
                    if hidden > 0 {
                        Button("More (\(hidden) remaining)") {
                            visibleCount += pageStep
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    if visibleCount > initialLimit {
                        Button("Show fewer") {
                            visibleCount = initialLimit
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Each switch is a one-time continuation with up to \(AppEnvironment.shared.config.maxAttempts) attempts. It stays remembered for \(TextFormat.countdown(AppEnvironment.shared.config.retention)), then clears automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { Task { await model.refresh(reason: .manual) } }
                    .disabled(model.isRefreshing)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: CodexSession
    @ObservedObject var model: DashboardModel
    @ObservedObject var scheduler: ResumeScheduler

    var body: some View {
        HStack(spacing: 8) {
            Button { model.open(session) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                    Text(session.displayName).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if let activity = scheduler.activity(for: session) {
                        ResumeActivityView(activity: activity)
                    }
                    if let tokens = model.tokenUsage[session.id] {
                        Label(tokens.compactTotal, systemImage: "number")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Measured local tokens for this session: \(tokens.detailDescription)")
                    }
                    Toggle("Continue after reset", isOn: Binding(
                        get: { scheduler.isEnabled(session) },
                        set: { scheduler.setEnabled($0, for: session, resetAt: model.reading?.snapshot.primary.resetAt) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Continue \(session.displayName) after reset")
                }
                if let activity = scheduler.activity(for: session) {
                    ContinuationActions(sessionID: session.id, activity: activity, scheduler: scheduler)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// Run now / Retry / Stop. Previously the only way to act on a stuck continuation was to toggle
/// the switch off and on again, which also reset the scheduled time.
struct ContinuationActions: View {
    let sessionID: String
    let activity: ResumeActivity
    @ObservedObject var scheduler: ResumeScheduler

    var body: some View {
        HStack(spacing: 8) {
            switch activity.state {
            case .queued:
                Button("Run now") { scheduler.runNow(sessionID) }
            case .running, .starting:
                Button("Stop") { scheduler.stop(sessionID) }
            case .retrying:
                Button("Retry now") { scheduler.retryNow(sessionID) }
                Button("Stop") { scheduler.stop(sessionID) }
            case .failed:
                Button("Retry") { scheduler.retryNow(sessionID) }
            case .succeeded:
                EmptyView()
            }
        }
        .buttonStyle(.link)
        .font(.caption2)
    }
}

struct ResumeActivityView: View {
    let activity: ResumeActivity

    private var tint: Color {
        switch activity.state {
        case .queued: .secondary
        case .starting, .running: .orange
        case .retrying: .purple
        case .succeeded: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch activity.state {
        case .queued:
            return activity.scheduledAt.map { "Start at \(Formatters.timeString($0))" } ?? "Queued"
        case .starting:
            return "Starting…"
        case .running:
            return activity.startedAt.map { "Running since \(Formatters.timeString($0))" } ?? "Running"
        case .retrying:
            let attempt = "Attempt \(activity.attempt)"
            if let next = activity.nextAttemptAt {
                return "\(attempt) at \(Formatters.timeString(next))"
            }
            return "\(attempt) pending"
        case .succeeded:
            return activity.finishedAt.map { "Completed \(Formatters.timeString($0))" } ?? "Completed"
        case .failed:
            if let exitCode = activity.exitCode { return "Failed (exit \(exitCode))" }
            if activity.outcome != .none { return "Failed · \(activity.outcome.label)" }
            return "Failed"
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(statusText)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)

            if let output = activity.lastOutput, activity.state != .queued {
                Text(output)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 175, alignment: .trailing)
                    .help(output)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Continuation \(statusText)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Usage cards

struct UsageMiniCard: View {
    let title: String
    let window: UsageWindow
    let accent: Color
    let showsDate: Bool
    var freshness: UsageFreshness = .fresh

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(accent)
                Spacer(minLength: 4)
                Text("\(window.remainingPercent)%")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
            PastelProgressBar(value: window.remainingPercent, accent: freshness == .stale ? .gray : accent)
            HStack(spacing: 4) {
                Image(systemName: freshness == .stale ? "clock.badge.exclamationmark" : "arrow.counterclockwise")
                Text("Resets \(showsDate ? window.resetDateText : window.resetText)")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(freshness == .stale ? .orange : .secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [accent.opacity(0.24), accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
    }
}

struct PastelProgressBar: View {
    let value: Int
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.16))
                Capsule().fill(accent)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(100, value))) / 100)
            }
        }
        .frame(height: 6)
        .accessibilityValue(Text("\(value) percent remaining"))
    }
}

// MARK: - Dashboard window

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var visibleCount = 5

    private var initialLimit: Int { AppEnvironment.shared.config.recentSessionLimit }
    private var pageStep: Int { AppEnvironment.shared.config.sessionPageStep }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.cyan.opacity(0.20), .indigo.opacity(0.14), .mint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Codex Resets Window").font(.largeTitle.bold())
                            Text("Private local usage and session companion.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await model.refresh(reason: .manual) } } label: {
                            Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh usage and sessions")
                    }

                    if let reading = model.reading {
                        HStack(spacing: 14) {
                            UsageCard(title: "5-hour window", window: reading.snapshot.primary, emphasis: true,
                                      freshness: model.freshness(for: .primary))
                            UsageCard(title: "Weekly window", window: reading.snapshot.secondary, emphasis: false,
                                      freshness: model.freshness(for: .secondary))
                        }
                        if let eta = model.primaryETA, model.willRunDry {
                            Label("Forecast: empty in ~\(TextFormat.countdown(eta)) at the current rate", systemImage: "flame.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Text("Enabled sessions receive the prompt “\(AppEnvironment.shared.config.continuationPrompt)” \(TextFormat.countdown(AppEnvironment.shared.config.resetDelay)) after the 5-hour window resets.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Usage unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ProgressView("Loading Codex usage")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local Codex sessions").font(.title2.bold())
                        ForEach(model.sessions.prefix(max(initialLimit, visibleCount))) { session in
                            SessionRow(session: session, model: model, scheduler: AppEnvironment.shared.scheduler)
                        }
                        let hidden = model.sessions.count - min(model.sessions.count, max(initialLimit, visibleCount))
                        if hidden > 0 || visibleCount > initialLimit {
                            HStack(spacing: 12) {
                                if hidden > 0 {
                                    Button("More (\(hidden) remaining)") {
                                        visibleCount += pageStep
                                    }
                                    .buttonStyle(.link)
                                }
                                if visibleCount > initialLimit {
                                    Button("Show fewer") {
                                        visibleCount = initialLimit
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

struct UsageCard: View {
    let title: String
    let window: UsageWindow
    let emphasis: Bool
    var freshness: UsageFreshness = .fresh

    private var accent: Color {
        emphasis ? Color(red: 0.96, green: 0.55, blue: 0.46) : Color(red: 0.30, green: 0.72, blue: 0.70)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                if freshness == .stale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text("\(window.remainingPercent)% remaining").font(.title.bold())
            PastelProgressBar(value: window.remainingPercent, accent: freshness == .stale ? .gray : accent)
            Text("Resets \(emphasis ? window.resetText : window.resetDateText)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.28)))
    }
}
