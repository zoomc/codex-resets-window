import SwiftUI

@main
struct CodexWindowApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .task { await model.refresh() }
        } label: {
            Label(model.menuTitle, systemImage: "clock.badge.checkmark")
        }
        .menuBarExtraStyle(.window)

        Window("Codex Window", id: "dashboard") {
            DashboardView(model: model)
                .task { await model.refresh() }
        }
        .defaultSize(width: 680, height: 720)
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var sessions: [CodexSession] = []
    @Published var errorMessage: String?
    let service = CodexDataService()
    let scheduler = ResumeScheduler()

    var menuTitle: String {
        guard let primary = usage?.primary else { return "Codex" }
        return "\(primary.remainingPercent)% · \(primary.resetText)"
    }

    func refresh() async {
        sessions = await service.loadSessions()
        do {
            usage = try await service.fetchUsage()
            errorMessage = nil
            scheduler.schedule(resetAt: usage?.primary.resetAt, sessions: sessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let usage = model.usage {
                Text("5 小时：\(usage.primary.remainingPercent)% 剩余 · \(usage.primary.resetText) 重置")
                Text("每周：\(usage.secondary.remainingPercent)% 剩余 · \(usage.secondary.resetAt.formatted(date: .abbreviated, time: .shortened)) 重置")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.errorMessage ?? "正在读取用量…")
            }
            Divider()
            Button("打开 Codex Window") { NSApp.activate(ignoringOtherApps: true) }
            Button("刷新") { Task { await model.refresh() } }
            Button("退出") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 360)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [.cyan.opacity(0.24), .indigo.opacity(0.18), .mint.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Codex Window").font(.largeTitle.bold())
                            Text("本地、私密的用量与会话助手").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.bordered)
                    }

                    if let usage = model.usage {
                        HStack(spacing: 16) {
                            UsageCard(title: "5 小时使用限额", window: usage.primary, emphasis: true)
                            UsageCard(title: "每周使用限额", window: usage.secondary, emphasis: false)
                        }
                        Text("已开启的会话会在 5 小时窗口重置后的 5 分钟，于本机尝试恢复。不会发送新的提示词。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("无法读取用量", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ProgressView("正在读取 Codex 用量")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("本地 Codex 对话").font(.title2.bold())
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, model: model)
                        }
                    }
                }
                .padding(28)
            }
        }
    }
}

struct UsageCard: View {
    let title: String
    let window: UsageWindow
    let emphasis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Text("\(window.remainingPercent)% 剩余").font(.title.bold())
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(emphasis ? .green : .mint)
            Text("重置时间：\(window.resetAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.38)))
    }
}

struct SessionRow: View {
    let session: CodexSession
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName).lineLimit(1)
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("恢复后继续", isOn: Binding(
                get: { model.scheduler.isEnabled(session) },
                set: { model.scheduler.setEnabled($0, for: session, resetAt: model.usage?.primary.resetAt) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("在恢复后继续 \(session.displayName)")
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
