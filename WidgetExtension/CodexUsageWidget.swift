import SwiftUI
import WidgetKit
import AppIntents

private let liveDirectory = URL(fileURLWithPath: "/private/tmp/io.github.codexusage", isDirectory: true)

struct ArmResetIntent: AppIntent {
    static var title: LocalizedStringResource = "使用 Codex 重置券"
    static var description = IntentDescription("准备使用一次 Codex 官方重置券。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let payload = try JSONSerialization.data(withJSONObject: ["armedAt": Date().timeIntervalSince1970])
        try payload.write(to: liveDirectory.appendingPathComponent("reset-armed.json"), options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
        return .result()
    }
}

struct ConfirmResetIntent: AppIntent {
    static var title: LocalizedStringResource = "确认重置 Codex 额度"
    static var description = IntentDescription("消耗一次 Codex 官方重置券并重置可用额度。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let payload = try JSONSerialization.data(withJSONObject: ["idempotencyKey": UUID().uuidString])
        try payload.write(to: liveDirectory.appendingPathComponent("reset-request.json"), options: .atomic)
        try? FileManager.default.removeItem(at: liveDirectory.appendingPathComponent("reset-armed.json"))
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
        return .result()
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let email: String
    let plan: String
    let remaining: Int
    let used: Int
    let resetsAt: Date?
    let lifetimeTokens: Int64
    let todayTokens: Int64
    let streakDays: Int64
    let resetCredits: Int
    let resetStatus: String
    let resetArmed: Bool
    let updatedAt: Date?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, email: "Codex 账户", plan: "PLUS", remaining: 88, used: 12, resetsAt: .now.addingTimeInterval(5 * 86400), lifetimeTokens: 128_000_000, todayTokens: 420_000, streakDays: 6, resetCredits: 1, resetStatus: "", resetArmed: false, updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = read()
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60))))
    }

    private func read() -> UsageEntry {
        var fileValues: [String: Any] = [:]
        let liveURL = URL(fileURLWithPath: "/private/tmp/io.github.codexusage/usage.json")
        if let data = try? Data(contentsOf: liveURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fileValues = json
        }
        let armedURL = liveDirectory.appendingPathComponent("reset-armed.json")
        var resetArmed = false
        if let data = try? Data(contentsOf: armedURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let armedAt = json["armedAt"] as? TimeInterval,
           Date().timeIntervalSince1970 - armedAt < 30 {
            resetArmed = true
        } else {
            try? FileManager.default.removeItem(at: armedURL)
        }
        func value(_ key: String) -> Any? { fileValues[key] }
        func int64(_ key: String) -> Int64 {
            if let n = value(key) as? NSNumber { return n.int64Value }
            return 0
        }
        func date(_ key: String) -> Date? {
            guard let timestamp = value(key) as? NSNumber, timestamp.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp.doubleValue)
        }
        return UsageEntry(
            date: .now,
            email: value("email") as? String ?? "打开“Codex 用量”同步",
            plan: value("plan") as? String ?? "—",
            remaining: (value("remaining") as? NSNumber)?.intValue ?? 0,
            used: (value("used") as? NSNumber)?.intValue ?? 0,
            resetsAt: date("resetsAt"),
            lifetimeTokens: int64("lifetimeTokens"),
            todayTokens: int64("todayTokens"),
            streakDays: int64("streakDays"),
            resetCredits: (value("resetCredits") as? NSNumber)?.intValue ?? 0,
            resetStatus: value("resetStatus") as? String ?? "",
            resetArmed: resetArmed,
            updatedAt: date("lastUpdated")
        )
    }
}

struct CodexUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if family == .systemSmall { small } else { detailed }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.green)
                Spacer()
                resetControl(compact: true)
            }
            Spacer()
            Text("\(entry.remaining)%").font(.system(size: 42, weight: .bold, design: .rounded)).minimumScaleFactor(0.7)
            Text("周额度剩余").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(entry.remaining), total: 100).tint(entry.remaining <= 20 ? .orange : .green)
            Text(resetText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var detailed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.email).font(.headline).lineLimit(1)
                    Text("Codex · \(entry.plan)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(entry.remaining)%").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(entry.remaining <= 20 ? .orange : .green)
                    resetControl(compact: false)
                }
            }
            ProgressView(value: Double(entry.remaining), total: 100).tint(entry.remaining <= 20 ? .orange : .green)
            HStack {
                metric("已用", "\(entry.used)%")
                metric("今日 Tokens", compact(entry.todayTokens))
                metric("累计 Tokens", compact(entry.lifetimeTokens))
                if family == .systemLarge { metric("连续使用", "\(entry.streakDays) 天") }
            }
            Spacer(minLength: 0)
            HStack {
                Label(resetText, systemImage: "clock.arrow.circlepath")
                Spacer()
                if !entry.resetStatus.isEmpty { Text(entry.resetStatus) }
                else if let updated = entry.updatedAt { Text(updated, style: .time) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func resetControl(compact: Bool) -> some View {
        if entry.resetCredits > 0 {
            if entry.resetArmed {
                Button(intent: ConfirmResetIntent()) {
                    Label(compact ? "确认" : "确认重置", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .font(.caption2.bold())
            } else {
                Button(intent: ArmResetIntent()) {
                    Label(compact ? "\(entry.resetCredits)" : "重置券 \(entry.resetCredits)", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.bordered)
                .font(.caption2.bold())
            }
        } else {
            Label(compact ? "0" : "重置券 0", systemImage: "arrow.counterclockwise.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetText: String {
        guard let reset = entry.resetsAt else { return "等待同步" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm 重置"
        return f.string(from: reset)
    }

    private func compact(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 用量")
        .description("查看当前账户的周额度、重置时间和 Token 用量。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageWidget() }
}
