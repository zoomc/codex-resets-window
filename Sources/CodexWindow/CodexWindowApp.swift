import SwiftUI

@main
struct CodexWindowApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .onAppear { Task { await model.refresh() } }
        } label: {
            TopBarLabel(primary: model.usage?.primary)
        }
        .menuBarExtraStyle(.window)

        Window("Codex Window", id: "dashboard") {
            DashboardView(model: model)
                .onAppear { Task { await model.refresh() } }
        }
        .defaultSize(width: 680, height: 720)
    }
}

struct TopBarLabel: View {
    let primary: UsageWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 4) {
                CodexTimerMark(progress: Double(primary?.remainingPercent ?? 0) / 100)
                if let primary {
                    Text("\(primary.remainingPercent)% · \(primary.countdownText)")
                        .monospacedDigit()
                } else {
                    Text("Codex")
                }
            }
        }
    }
}

struct CodexTimerMark: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .stroke(.secondary.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "circle.hexagonpath")
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

@MainActor
final class DashboardModel: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var sessions: [CodexSession] = []
    @Published var errorMessage: String?
    let service = CodexDataService()
    let scheduler = ResumeScheduler()

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        sessions = await service.loadSessions()
        scheduler.updateSessions(sessions)
        do {
            usage = try await service.fetchUsage()
            errorMessage = nil
            scheduler.schedule(resetAt: usage?.primary.resetAt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ session: CodexSession) {
        scheduler.open(session)
    }
}

struct MenuContent: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex Window").font(.headline.weight(.semibold))
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Refresh usage and sessions")
                .accessibilityLabel("Refresh usage and sessions")
            }

            if let usage = model.usage {
                HStack(spacing: 8) {
                    UsageMiniCard(title: "5 hours", window: usage.primary, accent: Color(red: 0.36, green: 0.58, blue: 0.50))
                    UsageMiniCard(title: "Weekly", window: usage.secondary, accent: Color(red: 0.50, green: 0.47, blue: 0.64))
                }
            } else {
                Text(model.errorMessage ?? "Loading usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("Local Codex sessions").font(.headline)
                Spacer()
                Text("\(model.sessions.count)").font(.caption).foregroundStyle(.secondary)
            }

            if model.sessions.isEmpty {
                Text("No local sessions found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, model: model)
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 390)
            }

            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 520)
    }
}

struct UsageMiniCard: View {
    let title: String
    let window: UsageWindow
    let accent: Color

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
            Text("Remaining")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(accent)
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                Text("Resets \(window.resetText)")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [.cyan.opacity(0.20), .indigo.opacity(0.14), .mint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Codex Window").font(.largeTitle.bold())
                            Text("Private local usage and session companion.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await model.refresh() } } label: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh usage and sessions")
                    }

                    if let usage = model.usage {
                        HStack(spacing: 14) {
                            UsageCard(title: "5-hour window", window: usage.primary, emphasis: true)
                            UsageCard(title: "Weekly window", window: usage.secondary, emphasis: false)
                        }
                        Text("Enabled sessions receive the English prompt \"continue\" five minutes after the 5-hour window resets.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Usage unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ProgressView("Loading Codex usage")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local Codex sessions").font(.title2.bold())
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, model: model)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Text("\(window.remainingPercent)% remaining").font(.title.bold())
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(emphasis ? Color(red: 0.36, green: 0.58, blue: 0.50) : Color(red: 0.50, green: 0.47, blue: 0.64))
            Text("Resets \(window.resetText)")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.30)))
    }
}

struct SessionRow: View {
    let session: CodexSession
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.open(session) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName).lineLimit(1)
                        Text(session.updatedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Toggle("Continue after reset", isOn: Binding(
                    get: { model.scheduler.isEnabled(session) },
                    set: { model.scheduler.setEnabled($0, for: session, resetAt: model.usage?.primary.resetAt) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Continue \(session.displayName) after reset")
                if model.scheduler.isEnabled(session), let continuation = model.scheduler.continuationDate(resetAt: model.usage?.primary.resetAt) {
                    Text("Task continues \(englishTime(continuation))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private func englishTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
