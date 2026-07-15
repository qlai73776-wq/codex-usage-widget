import AppKit
import CryptoKit
import Foundation
import Security
import ServiceManagement
import UserNotifications
import WidgetKit

enum WidgetTheme: String {
    case system, dark, light
}

struct UsageSnapshot {
    var email = "正在连接 Codex…"
    var plan = "—"
    var remaining = 0
    var used = 0
    var resetsAt: Date?
    var lifetimeTokens: Int64?
    var todayTokens: Int64?
    var streakDays: Int64?
    var creditBalance: String?
    var resetCredits = 0
    var resetCreditID: String?
    var resetStatus: String?
    var lastUpdated: Date?
    var error: String?
}

struct SavedAccount: Codable, Identifiable {
    let id: String
    var email: String
    var plan: String
    var remaining: Int
    var used: Int
    var resetsAt: Double
    var lastUpdated: Double
}

final class AccountVault {
    static let shared = AccountVault()
    private let service = "io.github.codexusage.accounts"
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Usage", isDirectory: true)
    private var indexURL: URL { support.appendingPathComponent("accounts.json") }

    func accounts() -> [SavedAccount] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([SavedAccount].self, from: data)) ?? []
    }

    func saveCurrent(snapshot: UsageSnapshot) throws -> SavedAccount {
        guard snapshot.email.contains("@") else { throw VaultError.message("请先在 Codex 登录账号并刷新") }
        let auth = try readCurrentAuth()
        let id = accountID(for: snapshot.email)
        try storeSecret(auth, account: id)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let home = support.appendingPathComponent("Accounts/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "cli_auth_credentials_store = \"keyring\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try storeSecret(auth, service: "Codex Auth", account: codexKeychainAccount(home: home))
        var all = accounts().filter { $0.id != id }
        let item = SavedAccount(id: id, email: snapshot.email, plan: snapshot.plan, remaining: snapshot.remaining, used: snapshot.used, resetsAt: snapshot.resetsAt?.timeIntervalSince1970 ?? 0, lastUpdated: Date().timeIntervalSince1970)
        all.append(item)
        try writeIndex(all)
        return item
    }

    func importLoggedIn(snapshot: UsageSnapshot, from temporaryHome: URL) throws -> SavedAccount {
        guard snapshot.email.contains("@") else { throw VaultError.message("登录完成，但没有读取到账号信息") }
        let temporaryAccount = codexKeychainAccount(home: temporaryHome)
        guard let auth = secret(service: "Codex Auth", account: temporaryAccount) else {
            throw VaultError.message("没有读取到新账号的 Codex 登录凭据")
        }
        let id = accountID(for: snapshot.email)
        try storeSecret(auth, account: id)
        let finalHome = prepareHome(for: id)
        try storeSecret(auth, service: "Codex Auth", account: codexKeychainAccount(home: finalHome))
        var all = accounts().filter { $0.id != id }
        let item = SavedAccount(id: id, email: snapshot.email, plan: snapshot.plan, remaining: snapshot.remaining, used: snapshot.used, resetsAt: snapshot.resetsAt?.timeIntervalSince1970 ?? 0, lastUpdated: Date().timeIntervalSince1970)
        all.append(item)
        try writeIndex(all)
        return item
    }

    func update(_ account: SavedAccount) {
        var all = accounts()
        guard let position = all.firstIndex(where: { $0.id == account.id }) else { return }
        all[position] = account
        try? writeIndex(all)
    }

    func remove(_ id: String) {
        try? writeIndex(accounts().filter { $0.id != id })
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
    }

    func switchTo(_ id: String) throws {
        guard let auth = secret(account: id) else { throw VaultError.message("账号凭据不存在，请重新保存该账号") }
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try auth.write(to: codexHome.appendingPathComponent("auth.json"), options: [.atomic])
        let keyAccount = codexKeychainAccount(home: codexHome)
        try storeSecret(auth, service: "Codex Auth", account: keyAccount)
    }

    func home(for id: String) -> URL { support.appendingPathComponent("Accounts/\(id)", isDirectory: true) }

    func accountID(for email: String) -> String {
        String(SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    func prepareHome(for id: String) -> URL {
        let url = home(for: id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let config = url.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try? "cli_auth_credentials_store = \"keyring\"\n".write(to: config, atomically: true, encoding: .utf8)
        }
        return url
    }

    func makeTemporaryLoginHome() throws -> URL {
        let url = support.appendingPathComponent("Pending/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "cli_auth_credentials_store = \"keyring\"\n".write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return url
    }

    private func readCurrentAuth() throws -> Data {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw VaultError.message("没有找到 Codex 登录状态") }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw VaultError.message("Codex 登录状态格式无效") }
        return data
    }

    private func writeIndex(_ accounts: [SavedAccount]) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(accounts).write(to: indexURL, options: .atomic)
    }

    private func storeSecret(_ data: Data, account: String) throws { try storeSecret(data, service: service, account: account) }
    private func storeSecret(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VaultError.message("无法写入 macOS 钥匙串") }
        } else if status != errSecSuccess { throw VaultError.message("无法更新 macOS 钥匙串") }
    }

    private func secret(account: String) -> Data? {
        secret(service: service, account: account)
    }

    private func secret(service: String, account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func codexKeychainAccount(home: URL) -> String {
        let path = home.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|\(digest.prefix(16))"
    }

    enum VaultError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
}

final class CodexClient {
    var onUpdate: ((UsageSnapshot) -> Void)?
    var onLoginURL: ((URL) -> Void)?
    var onLoginCompleted: ((Bool, String?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var snapshot = UsageSnapshot()
    private var timer: Timer?
    private var accountWatchTimer: Timer?
    private var resetRequestTimer: Timer?
    private var authModificationDate: Date?
    private var nextID = 1
    private let codexHome: URL?
    private let publishesWidget: Bool
    private var loginRequested = false
    private var initialized = false

    init(codexHome: URL? = nil, publishesWidget: Bool = true) {
        self.codexHome = codexHome
        self.publishesWidget = publishesWidget
    }

    func start() {
        launchServer()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        authModificationDate = modificationDate(authURL)
        accountWatchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let newDate = self.modificationDate(authURL)
            if newDate != self.authModificationDate {
                self.authModificationDate = newDate
                self.refresh()
            }
        }
        resetRequestTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.consumePendingResetRequest()
        }
    }

    func stop() {
        timer?.invalidate()
        accountWatchTimer?.invalidate()
        resetRequestTimer?.invalidate()
        process?.terminate()
    }

    func refresh() {
        guard process?.isRunning == true else {
            launchServer()
            return
        }
        send(method: "account/read", params: ["refreshToken": true], id: 2)
        send(method: "account/rateLimits/read", params: [:], id: 3)
        send(method: "account/usage/read", params: [:], id: 4)
    }

    func reloadAccount() { launchServer() }
    func republish() { publish() }
    func beginChatGPTLogin() {
        loginRequested = true
        if initialized { send(method: "account/login/start", params: ["type": "chatgpt", "appBrand": "codex", "useHostedLoginSuccessPage": true], id: 20) }
    }

    private func launchServer() {
        process?.terminate()
        buffer.removeAll(keepingCapacity: true)
        initialized = false

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            snapshot.error = "未找到 Codex，请先安装或打开 Codex"
            publish()
            return
        }

        let task = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server"]
        if let codexHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            task.environment = environment
        }
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.launchServer() }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }

        do {
            try task.run()
            process = task
            input = stdinPipe.fileHandleForWriting
            send(method: "initialize", params: [
                "clientInfo": ["name": "codex-usage-widget", "title": "Codex 用量", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ], id: 1)
        } catch {
            snapshot.error = "无法连接 Codex：\(error.localizedDescription)"
            publish()
        }
    }

    private func send(method: String, params: [String: Any], id: Int? = nil) {
        var object: [String: Any] = ["method": method, "params": params]
        if let id { object["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        input?.write(data)
        input?.write(Data([0x0A]))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(json)
        }
    }

    private func handle(_ json: [String: Any]) {
        if let id = json["id"] as? Int, id == 1 {
            initialized = true
            send(method: "initialized", params: [:])
            if loginRequested { send(method: "account/login/start", params: ["type": "chatgpt", "appBrand": "codex", "useHostedLoginSuccessPage": true], id: 20) }
            refresh()
            return
        }
        if let id = json["id"] as? Int, let result = json["result"] as? [String: Any] {
            if id == 2 { parseAccount(result) }
            if id == 3 { parseLimits(result) }
            if id == 4 { parseUsage(result) }
            if id == 5 { parseResetOutcome(result) }
            if id == 20, let value = result["authUrl"] as? String, let url = URL(string: value) { onLoginURL?(url) }
            return
        }
        if let method = json["method"] as? String {
            if method == "account/login/completed" {
                let params = json["params"] as? [String: Any]
                let success = params?["success"] as? Bool ?? false
                onLoginCompleted?(success, params?["error"] as? String)
                if success { refresh() }
            } else if method == "account/updated" {
                refresh()
            } else if method == "account/rateLimits/updated",
                      let params = json["params"] as? [String: Any],
                      let limits = params["rateLimits"] as? [String: Any] {
                parseLimitSnapshot(limits)
            }
        }
    }

    private func parseAccount(_ result: [String: Any]) {
        guard let account = result["account"] as? [String: Any] else {
            snapshot.email = "未登录 Codex"
            snapshot.plan = "—"
            snapshot.error = "请先在 Codex 中登录"
            publish()
            return
        }
        snapshot.email = account["email"] as? String ?? "API Key 账户"
        snapshot.plan = (account["planType"] as? String ?? "unknown").uppercased()
        snapshot.error = nil
        publish()
    }

    private func parseLimits(_ result: [String: Any]) {
        if let limits = result["rateLimits"] as? [String: Any] { parseLimitSnapshot(limits) }
        if let reset = result["rateLimitResetCredits"] as? [String: Any] {
            snapshot.resetCredits = reset["availableCount"] as? Int ?? (reset["availableCount"] as? NSNumber)?.intValue ?? 0
            if let credits = reset["credits"] as? [[String: Any]] {
                snapshot.resetCreditID = credits.first?["id"] as? String
            } else {
                snapshot.resetCreditID = nil
            }
        }
        publish()
    }

    private func parseLimitSnapshot(_ limits: [String: Any]) {
        snapshot.plan = (limits["planType"] as? String ?? snapshot.plan).uppercased()
        if let primary = limits["primary"] as? [String: Any] {
            snapshot.used = primary["usedPercent"] as? Int ?? 0
            snapshot.remaining = max(0, 100 - snapshot.used)
            if let timestamp = primary["resetsAt"] as? TimeInterval {
                snapshot.resetsAt = Date(timeIntervalSince1970: timestamp)
            } else if let timestamp = primary["resetsAt"] as? Int {
                snapshot.resetsAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
        }
        if let credits = limits["credits"] as? [String: Any] {
            snapshot.creditBalance = credits["balance"] as? String
        }
        snapshot.lastUpdated = Date()
        publish()
    }

    private func parseUsage(_ result: [String: Any]) {
        if let summary = result["summary"] as? [String: Any] {
            snapshot.lifetimeTokens = number(summary["lifetimeTokens"])
            snapshot.streakDays = number(summary["currentStreakDays"])
        }
        if let buckets = result["dailyUsageBuckets"] as? [[String: Any]] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from: Date())
            snapshot.todayTokens = buckets.first(where: { $0["startDate"] as? String == today }).flatMap { number($0["tokens"]) } ?? 0
        }
        publish()
    }

    private func consumePendingResetRequest() {
        let url = URL(fileURLWithPath: "/private/tmp/io.github.codexusage/reset-request.json")
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = request["idempotencyKey"] as? String else { return }
        try? FileManager.default.removeItem(at: url)
        var params: [String: Any] = ["idempotencyKey": key]
        if let creditID = snapshot.resetCreditID { params["creditId"] = creditID }
        snapshot.resetStatus = "正在重置…"
        publish()
        send(method: "account/rateLimitResetCredit/consume", params: params, id: 5)
    }

    private func parseResetOutcome(_ result: [String: Any]) {
        let outcome = result["outcome"] as? String ?? "unknown"
        snapshot.resetStatus = [
            "reset": "重置成功",
            "nothingToReset": "当前无需重置",
            "noCredit": "没有可用重置券",
            "alreadyRedeemed": "本次重置已完成"
        ][outcome] ?? "重置结果未知"
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    private func number(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func publish() {
        var saved = AccountVault.shared.accounts()
        let currentID = AccountVault.shared.accountID(for: snapshot.email)
        if let position = saved.firstIndex(where: { $0.id == currentID || $0.email.caseInsensitiveCompare(snapshot.email) == .orderedSame }), snapshot.lastUpdated != nil {
            saved[position].email = snapshot.email
            saved[position].plan = snapshot.plan
            saved[position].remaining = snapshot.remaining
            saved[position].used = snapshot.used
            saved[position].resetsAt = snapshot.resetsAt?.timeIntervalSince1970 ?? 0
            saved[position].lastUpdated = snapshot.lastUpdated?.timeIntervalSince1970 ?? 0
            AccountVault.shared.update(saved[position])
        }
        let accountValues: [[String: Any]] = saved.map { ["id": $0.id, "email": $0.email, "plan": $0.plan, "remaining": $0.remaining, "used": $0.used, "resetsAt": $0.resetsAt, "lastUpdated": $0.lastUpdated, "current": $0.email.caseInsensitiveCompare(snapshot.email) == .orderedSame] }
        let values: [String: Any] = [
            "email": snapshot.email,
            "plan": snapshot.plan,
            "remaining": snapshot.remaining,
            "used": snapshot.used,
            "resetsAt": snapshot.resetsAt?.timeIntervalSince1970 ?? 0,
            "lifetimeTokens": snapshot.lifetimeTokens ?? 0,
            "todayTokens": snapshot.todayTokens ?? 0,
            "streakDays": snapshot.streakDays ?? 0,
            "resetCredits": snapshot.resetCredits,
            "resetCreditID": snapshot.resetCreditID ?? "",
            "resetStatus": snapshot.resetStatus ?? "",
            "lastUpdated": snapshot.lastUpdated?.timeIntervalSince1970 ?? 0,
            "accounts": accountValues
        ]
        if publishesWidget, let data = try? JSONSerialization.data(withJSONObject: values) {
            let liveDirectory = URL(fileURLWithPath: "/private/tmp/io.github.codexusage", isDirectory: true)
            try? FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
            try? data.write(to: liveDirectory.appendingPathComponent("usage.json"), options: .atomic)
        }
        if publishesWidget { WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget") }
        onUpdate?(snapshot)
    }
}

final class UsageView: NSView {
    static let notificationDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
    var snapshot = UsageSnapshot() { didSet { needsDisplay = true } }
    var theme: WidgetTheme = .system { didSet { needsDisplay = true } }
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        if let error = snapshot.error {
            text("Codex 用量", at: NSPoint(x: 22, y: 22), size: 17, weight: .semibold, color: foreground)
            text(error, at: NSPoint(x: 22, y: 59), size: 13, weight: .regular, color: NSColor.systemOrange)
            text("点按菜单栏图标可刷新", at: NSPoint(x: 22, y: 90), size: 12, weight: .regular, color: muted)
            return
        }

        text(snapshot.email, at: NSPoint(x: 22, y: 20), size: 15, weight: .semibold, color: foreground, maxWidth: 235)
        pill(snapshot.plan, rect: NSRect(x: 275, y: 17, width: 62, height: 25))

        let center = NSPoint(x: 76, y: 103)
        ring(center: center, radius: 40, progress: CGFloat(snapshot.remaining) / 100)
        centered("\(snapshot.remaining)%", center: NSPoint(x: center.x, y: center.y - 10), size: 24, weight: .bold, color: foreground)
        centered("剩余", center: NSPoint(x: center.x, y: center.y + 17), size: 11, weight: .medium, color: muted)

        text("每周用量", at: NSPoint(x: 135, y: 65), size: 12, weight: .medium, color: muted)
        text("已用 \(snapshot.used)%", at: NSPoint(x: 135, y: 85), size: 20, weight: .semibold, color: foreground)
        if let reset = snapshot.resetsAt {
            text("重置  \(dateFormatter.string(from: reset))", at: NSPoint(x: 135, y: 116), size: 12, weight: .regular, color: muted)
            text("还有 \(relative(reset))", at: NSPoint(x: 135, y: 137), size: 12, weight: .regular, color: NSColor.systemGreen)
        }

        separator.setFill()
        NSBezierPath(rect: NSRect(x: 22, y: 169, width: 316, height: 1)).fill()

        metric(title: "今日 Tokens", value: compact(snapshot.todayTokens), x: 22)
        metric(title: "累计 Tokens", value: compact(snapshot.lifetimeTokens), x: 132)
        metric(title: "连续使用", value: snapshot.streakDays.map { "\($0) 天" } ?? "—", x: 246)

        let footer = snapshot.lastUpdated.map { "更新于 " + time($0) } ?? "正在获取数据…"
        text(footer, at: NSPoint(x: 22, y: 232), size: 10.5, weight: .regular, color: muted.withAlphaComponent(0.65))
    }

    private var isLight: Bool {
        if theme == .light { return true }
        if theme == .dark { return false }
        return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }
    private var background: NSColor { isLight ? NSColor(calibratedWhite: 0.98, alpha: 0.94) : NSColor(calibratedWhite: 0.08, alpha: 0.91) }
    private var foreground: NSColor { isLight ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white }
    private var muted: NSColor { isLight ? NSColor(calibratedWhite: 0.18, alpha: 0.60) : NSColor(calibratedWhite: 1, alpha: 0.58) }
    private var border: NSColor { isLight ? NSColor(calibratedWhite: 0, alpha: 0.12) : NSColor(calibratedWhite: 1, alpha: 0.12) }
    private var separator: NSColor { isLight ? NSColor(calibratedWhite: 0, alpha: 0.10) : NSColor(calibratedWhite: 1, alpha: 0.10) }

    private func ring(center: NSPoint, radius: CGFloat, progress: CGFloat) {
        let base = NSBezierPath()
        base.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 450)
        base.lineWidth = 9
        base.lineCapStyle = .round
        (isLight ? NSColor(calibratedWhite: 0, alpha: 0.10) : NSColor(calibratedWhite: 1, alpha: 0.12)).setStroke()
        base.stroke()
        let active = NSBezierPath()
        active.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.015, progress), clockwise: true)
        active.lineWidth = 9
        active.lineCapStyle = .round
        (progress > 0.2 ? NSColor.systemGreen : NSColor.systemOrange).setStroke()
        active.stroke()
    }

    private func pill(_ value: String, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor.systemGreen.withAlphaComponent(0.18).setFill()
        path.fill()
        centered(value, center: NSPoint(x: rect.midX, y: rect.midY - 7), size: 11.5, weight: .semibold, color: NSColor.systemGreen)
    }

    private func metric(title: String, value: String, x: CGFloat) {
        text(title, at: NSPoint(x: x, y: 184), size: 10.5, weight: .regular, color: muted)
        text(value, at: NSPoint(x: x, y: 205), size: 14, weight: .semibold, color: foreground, maxWidth: 96)
    }

    private func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat = 300) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        NSAttributedString(string: string, attributes: attrs).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: size + 7))
    }

    private func centered(_ string: String, center: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let s = NSAttributedString(string: string, attributes: attrs)
        s.draw(at: NSPoint(x: center.x - s.size().width / 2, y: center.y))
    }

    private func compact(_ number: Int64?) -> String {
        guard let n = number else { return "—" }
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func relative(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        return days > 0 ? "\(days)天 \(hours)小时" : "\(hours)小时 \(minutes)分"
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let client = CodexClient()
    private let usageView = UsageView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var launchItem: NSMenuItem!
    private var alertItem: NSMenuItem!
    private var statusDetailItem: NSMenuItem!
    private var sizeItems: [NSMenuItem] = []
    private var themeItems: [NSMenuItem] = []
    private var accountsMenu = NSMenu(title: "Codex 账号")
    private var accountClients: [String: CodexClient] = [:]
    private var switchRequestTimer: Timer?
    private var latestSnapshot = UsageSnapshot()
    private var pendingLoginClient: CodexClient?
    private var pendingLoginHome: URL?
    private var pendingLoginSucceeded = false
    private let defaults = UserDefaults.standard
    private let baseSize = NSSize(width: 360, height: 260)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        createPanel()
        createStatusItem()
        applySavedPreferences()
        client.onUpdate = { [weak self] snapshot in
            self?.latestSnapshot = snapshot
            self?.usageView.snapshot = snapshot
            self?.statusItem.button?.title = "  \(snapshot.remaining)%"
            self?.statusDetailItem.title = "\(snapshot.email) · \(snapshot.plan) · 剩余 \(snapshot.remaining)%"
            self?.checkUsageAlert(snapshot)
            self?.rebuildAccountsMenu()
        }
        client.start()
        startSavedAccountClients()
        switchRequestTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.consumeSwitchRequest() }
    }

    func applicationWillTerminate(_ notification: Notification) { client.stop(); accountClients.values.forEach { $0.stop() } }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func createPanel() {
        let size = NSSize(width: 360, height: 260)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 28, y: visible.maxY - size.height - 28)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = usageView
        panel.orderOut(nil)
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Codex 用量")
        statusItem.button?.title = "  —"
        let menu = NSMenu()
        statusDetailItem = NSMenuItem(title: "正在读取 Codex 数据…", action: nil, keyEquivalent: "")
        statusDetailItem.isEnabled = false
        menu.addItem(statusDetailItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        let add = NSMenuItem(title: "添加另一个 Codex 账号…", action: #selector(addAnotherAccount), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let save = NSMenuItem(title: "保存当前 Codex 账号", action: #selector(saveCurrentAccount), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        let accounts = NSMenuItem(title: "Codex 账号", action: nil, keyEquivalent: "")
        accounts.submenu = accountsMenu
        menu.addItem(accounts)
        alertItem = NSMenuItem(title: "用量提醒（20% / 10%）", action: #selector(toggleAlerts), keyEquivalent: "")
        alertItem.target = self
        menu.addItem(alertItem)
        launchItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex 用量", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func refresh() { client.refresh() }

    @objc private func saveCurrentAccount() {
        do {
            let account = try AccountVault.shared.saveCurrent(snapshot: latestSnapshot)
            startClient(for: account)
            rebuildAccountsMenu()
            client.refresh()
        } catch { showAccountError(error.localizedDescription) }
    }

    @objc private func addAnotherAccount() {
        guard pendingLoginClient == nil else {
            showAccountError("已有一个登录流程正在进行，请先在浏览器完成登录。")
            return
        }
        do {
            let home = try AccountVault.shared.makeTemporaryLoginHome()
            let loginClient = CodexClient(codexHome: home, publishesWidget: false)
            pendingLoginHome = home
            pendingLoginClient = loginClient
            pendingLoginSucceeded = false
            loginClient.onLoginURL = { url in NSWorkspace.shared.open(url) }
            loginClient.onLoginCompleted = { [weak self] success, error in
                guard let self else { return }
                if success {
                    self.pendingLoginSucceeded = true
                } else {
                    self.finishPendingLogin(error: error ?? "Codex 登录没有完成")
                }
            }
            loginClient.onUpdate = { [weak self] snapshot in
                guard let self, self.pendingLoginSucceeded, snapshot.lastUpdated != nil, snapshot.email.contains("@"), let home = self.pendingLoginHome else { return }
                do {
                    let account = try AccountVault.shared.importLoggedIn(snapshot: snapshot, from: home)
                    self.finishPendingLogin(error: nil)
                    self.startClient(for: account)
                    self.rebuildAccountsMenu()
                    self.client.republish()
                    let notice = NSUserNotification()
                    notice.title = "Codex 账号已添加"
                    notice.informativeText = "已保存新账号，可在小组件中直接切换。"
                    NSUserNotificationCenter.default.deliver(notice)
                } catch {
                    self.finishPendingLogin(error: error.localizedDescription)
                }
            }
            loginClient.start()
            loginClient.beginChatGPTLogin()
        } catch { showAccountError(error.localizedDescription) }
    }

    private func finishPendingLogin(error: String?) {
        pendingLoginClient?.stop()
        pendingLoginClient = nil
        pendingLoginHome = nil
        pendingLoginSucceeded = false
        if let error { showAccountError(error) }
    }

    @objc private func selectAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switchAccount(id)
    }

    @objc private func deleteAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        accountClients.removeValue(forKey: id)?.stop()
        AccountVault.shared.remove(id)
        rebuildAccountsMenu()
        client.refresh()
    }

    private func switchAccount(_ id: String) {
        do {
            try AccountVault.shared.switchTo(id)
            client.reloadAccount()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.client.refresh() }
        } catch { showAccountError(error.localizedDescription) }
    }

    private func startSavedAccountClients() { AccountVault.shared.accounts().forEach(startClient) }

    private func startClient(for account: SavedAccount) {
        guard accountClients[account.id] == nil else { return }
        let probe = CodexClient(codexHome: AccountVault.shared.prepareHome(for: account.id), publishesWidget: false)
        probe.onUpdate = { [weak self] snapshot in
            guard snapshot.lastUpdated != nil, snapshot.email.contains("@") else { return }
            var updated = account
            updated.email = snapshot.email
            updated.plan = snapshot.plan
            updated.remaining = snapshot.remaining
            updated.used = snapshot.used
            updated.resetsAt = snapshot.resetsAt?.timeIntervalSince1970 ?? 0
            updated.lastUpdated = snapshot.lastUpdated?.timeIntervalSince1970 ?? 0
            AccountVault.shared.update(updated)
            self?.rebuildAccountsMenu()
            self?.client.republish()
        }
        accountClients[account.id] = probe
        probe.start()
    }

    private func rebuildAccountsMenu() {
        accountsMenu.removeAllItems()
        let saved = AccountVault.shared.accounts()
        if saved.isEmpty {
            let empty = NSMenuItem(title: "尚未保存账号", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            accountsMenu.addItem(empty)
            return
        }
        for account in saved.sorted(by: { $0.remaining > $1.remaining }) {
            let current = account.email.caseInsensitiveCompare(latestSnapshot.email) == .orderedSame
            let item = NSMenuItem(title: "\(current ? "✓ " : "")\(account.email) · 剩余 \(account.remaining)%", action: #selector(selectAccount), keyEquivalent: "")
            item.target = self; item.representedObject = account.id
            accountsMenu.addItem(item)
            let remove = NSMenuItem(title: "    移除 \(account.email)", action: #selector(deleteAccount), keyEquivalent: "")
            remove.target = self; remove.representedObject = account.id
            accountsMenu.addItem(remove)
        }
    }

    private func consumeSwitchRequest() {
        let url = URL(fileURLWithPath: "/private/tmp/io.github.codexusage/switch-request.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["accountID"] as? String else { return }
        try? FileManager.default.removeItem(at: url)
        switchAccount(id)
    }

    private func showAccountError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Codex 账号操作失败"; alert.informativeText = message; alert.runModal()
    }
    @objc private func showPanel() { panel.orderFrontRegardless() }
    @objc private func hidePanel() { panel.orderOut(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func applySavedPreferences() {
        if defaults.object(forKey: "usageAlerts") == nil { defaults.set(true, forKey: "usageAlerts") }
        alertItem.state = defaults.bool(forKey: "usageAlerts") ? .on : .off
        if defaults.object(forKey: "launchPreferenceInitialized") == nil {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                defaults.set(true, forKey: "launchPreferenceInitialized")
            } catch {
                NSLog("Unable to enable launch at login: \(error.localizedDescription)")
            }
        }
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if alertItem.state == .on { requestNotificationPermission() }
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        defaults.set(scale, forKey: "widgetScale")
        setScale(scale)
    }

    private func setScale(_ scale: Double) {
        let newSize = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        var frame = panel.frame
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        panel.setFrame(frame, display: true, animate: true)
        usageView.setBoundsSize(baseSize)
        for item in sizeItems {
            let value = item.representedObject as? Double ?? 0
            item.state = abs(value - scale) < 0.01 ? .on : .off
        }
    }

    @objc private func changeTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = WidgetTheme(rawValue: raw) else { return }
        defaults.set(raw, forKey: "widgetTheme")
        setTheme(theme)
    }

    private func setTheme(_ theme: WidgetTheme) {
        usageView.theme = theme
        for item in themeItems { item.state = item.representedObject as? String == theme.rawValue ? .on : .off }
    }

    @objc private func toggleAlerts() {
        let enabled = !defaults.bool(forKey: "usageAlerts")
        defaults.set(enabled, forKey: "usageAlerts")
        alertItem.state = enabled ? .on : .off
        if enabled { requestNotificationPermission() }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkUsageAlert(_ snapshot: UsageSnapshot) {
        guard defaults.bool(forKey: "usageAlerts"), snapshot.lastUpdated != nil else { return }
        let threshold: Int? = snapshot.remaining <= 10 ? 10 : (snapshot.remaining <= 20 ? 20 : nil)
        guard let threshold else { return }
        let resetKey = snapshot.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        let key = "alerted.\(snapshot.email).\(resetKey).\(threshold)"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "Codex 周额度剩余 \(snapshot.remaining)%"
        content.body = snapshot.resetsAt.map { "将在 \(UsageView.notificationDateFormatter.string(from: $0)) 重置。" } ?? "请留意接下来的使用量。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                launchItem.state = .on
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改自动启动设置"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
