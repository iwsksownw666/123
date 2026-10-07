import SwiftUI
import UIKit
import Foundation
import Security

enum KC {
    static let svc = "com.ethereal.dbm"
    static func set(_ v: String, _ k: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: svc,
                                kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
        var a = q
        a[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(a as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: svc,
                                kSecAttrAccount as String: k,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func del(_ k: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: svc,
                                kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
    }
}

struct BotUser: Codable { let id: String; let username: String }
struct Guild: Codable, Identifiable, Hashable { let id: String; let name: String }
struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: Int
    var display: String { name ?? id }
    var textable: Bool { type == 0 || type == 5 || type == 15 }
}
struct Author: Codable { let id: String; let username: String }
struct Msg: Codable, Identifiable { let id: String; let content: String; let author: Author }

enum APIErr: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let m):
            if c == 401 { return "Token 无效 (401)" }
            if c == 403 { return "无权限 (403)，检查频道权限与 Intent" }
            if c == 404 { return "找不到目标 (404)" }
            return "HTTP \(c) \(m)"
        }
    }
}

final class Discord {
    let token: String
    let base = "https://discord.com/api/v10"
    init(_ t: String) { token = t }

    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var last = ""
        for _ in 0..<5 {
            var r = URLRequest(url: URL(string: base + path)!)
            r.httpMethod = method
            r.setValue("Bot " + token, forHTTPHeaderField: "Authorization")
            r.setValue("DBM/1.0 iOS", forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 30
            if let body {
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                var w = 1.0
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = o["retry_after"] as? NSNumber {
                    w = n.doubleValue + 0.3
                }
                try? await Task.sleep(nanoseconds: UInt64(min(w, 30) * 1_000_000_000))
                continue
            }
            if code == 204 { return Data() }
            if code >= 200 && code < 300 { return data }
            last = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            if code == 400 || code == 401 || code == 403 || code == 404 { throw APIErr.http(code, last) }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        throw APIErr.http(0, last.isEmpty ? "请求失败" : last)
    }

    private func dec<T: Decodable>(_ d: Data) throws -> T { try JSONDecoder().decode(T.self, from: d) }
    func me() async throws -> BotUser {
        let d = try await call("/users/@me")
        return try dec(d)
    }
    func guilds() async throws -> [Guild] {
        let d = try await call("/users/@me/guilds")
        return try dec(d)
    }
    func channels(_ g: String) async throws -> [Channel] {
        let d = try await call("/guilds/\(g)/channels")
        return try dec(d)
    }
    func messages(_ c: String, limit: Int = 25) async throws -> [Msg] {
        let d = try await call("/channels/\(c)/messages?limit=\(limit)")
        return try dec(d)
    }
    @discardableResult
    func post(_ c: String, _ text: String) async throws -> Msg {
        let d = try await call("/channels/\(c)/messages", method: "POST", body: ["content": text, "tts": false])
        return try dec(d)
    }
}

struct LogLine: Identifiable { let id = UUID(); let t = Date(); let text: String }

struct SendJob: Codable, Identifiable {
    var id: UUID = UUID()
    var cid: String = ""
    var cname: String = ""
    var text: String = ""
    var interval: Double = 60
    var jitter: Double = 5
    var enabled: Bool = false
    var lastRun: Date = .distantPast
}

struct Rule: Codable, Identifiable {
    var id: UUID = UUID()
    var cid: String = ""
    var cname: String = ""
    var keyword: String = ""
    var reply: String = ""
    var matchAll: Bool = false
    var enabled: Bool = false
    var lastMsg: String = ""
}

@MainActor
final class Mgr: ObservableObject {
    @Published var bot: BotUser?
    @Published var guilds: [Guild] = []
    @Published var channels: [Channel] = []
    @Published var known: [Channel] = []
    @Published var guildId: String?
    @Published var channelId: String?
    @Published var msgs: [Msg] = []
    @Published var logs: [LogLine] = []
    @Published var jobs: [SendJob] = []
    @Published var rules: [Rule] = []
    @Published var busy = false
    @Published var err: String?

    var connected: Bool { bot != nil }
    private var api: Discord?
    private var timer: Timer?
    private var pollAt = Date()

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func log(_ s: String) {
        logs.insert(LogLine(text: s), at: 0)
        if logs.count > 300 { logs.removeLast(logs.count - 300) }
    }

    func load() {
        if let d = UserDefaults.standard.data(forKey: "dbm.jobs"), let v = try? JSONDecoder().decode([SendJob].self, from: d) { jobs = v }
        if let d = UserDefaults.standard.data(forKey: "dbm.rules"), let v = try? JSONDecoder().decode([Rule].self, from: d) { rules = v }
        if let g = UserDefaults.standard.string(forKey: "dbm.guild") { guildId = g }
        if let c = UserDefaults.standard.string(forKey: "dbm.channel") { channelId = c }
    }

    func save() {
        if let d = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(d, forKey: "dbm.jobs") }
        if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: "dbm.rules") }
        UserDefaults.standard.set(guildId, forKey: "dbm.guild")
        UserDefaults.standard.set(channelId, forKey: "dbm.channel")
    }

    func connect(_ raw: String) async {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        busy = true; err = nil
        KC.set(t, "token")
        let c = Discord(t)
        do {
            let u = try await c.me()
            api = c
            bot = u
            guilds = (try await c.guilds()).sorted { $0.name < $1.name }
            log("已连接 \(u.username)，服务器 \(guilds.count) 个")
        } catch {
            err = error.localizedDescription
            log("连接失败：\(error.localizedDescription)")
        }
        busy = false
    }

    func resume() async {
        guard let t = KC.get("token"), !t.isEmpty, bot == nil else { return }
        busy = true
        let c = Discord(t)
        do {
            let u = try await c.me()
            api = c; bot = u
            guilds = (try await c.guilds()).sorted { $0.name < $1.name }
            log("恢复连接 \(u.username)")
            if let g = guildId { await loadChannels(g) }
        } catch { log("自动重连失败：\(error.localizedDescription)") }
        busy = false
    }

    func disconnect() {
        api = nil; bot = nil; guilds = []; channels = []; msgs = []
        KC.del("token")
        log("已断开")
    }

    func loadChannels(_ g: String) async {
        guard let api else { return }
        guildId = g
        UserDefaults.standard.set(g, forKey: "dbm.guild")
        do {
            let all = try await api.channels(g)
            channels = all.filter { $0.textable }
            for c in channels where !known.contains(where: { $0.id == c.id }) { known.append(c) }
            save()
        } catch { log("频道加载失败：\(error.localizedDescription)") }
    }

    func loadMsgs(_ c: String) async {
        guard let api else { return }
        channelId = c
        UserDefaults.standard.set(c, forKey: "dbm.channel")
        do { msgs = try await api.messages(c, limit: 25) }
        catch { log("消息拉取失败：\(error.localizedDescription)") }
    }

    func sendNow(_ text: String, cid: String?) async {
        guard let api, let cid, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await api.post(cid, text)
            log("已发送 → \(cid)")
            if channelId == cid { await loadMsgs(cid) }
        } catch { log("发送失败：\(error.localizedDescription)") }
    }

    func tick() {
        let now = Date()
        var dirty = false
        for i in jobs.indices where jobs[i].enabled && !jobs[i].text.isEmpty && !jobs[i].cid.isEmpty {
            if now.timeIntervalSince(jobs[i].lastRun) >= jobs[i].interval {
                jobs[i].lastRun = now
                dirty = true
                let j = jobs[i]
                Task { await self.fire(j) }
            }
        }
        if dirty { save() }
        if now.timeIntervalSince(pollAt) >= 6 {
            pollAt = now
            Task { await self.poll() }
        }
    }

    private func fire(_ j: SendJob) async {
        guard let api else { return }
        if j.jitter > 0 {
            let w = Double.random(in: 0...j.jitter)
            try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000))
        }
        do { try await api.post(j.cid, j.text); log("定时发送 \(j.cname) ok") }
        catch { log("定时发送失败：\(error.localizedDescription)") }
    }

    private func poll() async {
        guard let api, let me = bot else { return }
        var dirty = false
        for i in rules.indices where rules[i].enabled && !rules[i].cid.isEmpty && !rules[i].keyword.isEmpty {
            let r = rules[i]
            do {
                let ms = try await api.messages(r.cid, limit: 20)
                var newest = r.lastMsg
                if r.lastMsg.isEmpty {
                    newest = ms.first?.id ?? ""
                    rules[i].lastMsg = newest
                    dirty = true
                    continue
                }
                var matched = false
                for m in ms where m.id > r.lastMsg {
                    if m.id > newest { newest = m.id }
                    if matched || m.author.id == me.id { continue }
                    let hit = r.matchAll || m.content.localizedCaseInsensitiveContains(r.keyword)
                    if hit {
                        matched = true
                        try await api.post(r.cid, r.reply)
                        log("自动回复 \(r.cname) ← \(m.author.username)")
                    }
                }
                rules[i].lastMsg = newest
                dirty = true
            } catch { log("轮询失败：\(error.localizedDescription)") }
        }
        if dirty { save() }
    }
}

@main
struct DBMApp: App {
    @StateObject private var m = Mgr()
    var body: some Scene {
        WindowGroup { Root().environmentObject(m) }
    }
}

struct Root: View {
    @EnvironmentObject var m: Mgr
    var body: some View {
        TabView {
            ConnectView().tabItem { Label("连接", systemImage: "key.fill") }
            NavigationStack { ChatView() }.tabItem { Label("频道", systemImage: "bubble.left.and.bubble.right") }
            JobsView().tabItem { Label("定时", systemImage: "clock") }
            RulesView().tabItem { Label("自动回复", systemImage: "arrow.uturn.left") }
            LogsView().tabItem { Label("日志", systemImage: "list.bullet") }
        }
        .task { await m.resume() }
    }
}

struct ConnectView: View {
    @EnvironmentObject var m: Mgr
    @State private var input = ""
    @State private var plain = false

    var body: some View {
        Form {
            Section {
                if plain {
                    TextField("MTIx...", text: $input)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none)
                } else {
                    SecureField("MTIx...", text: $input)
                }
                Toggle("明文显示", isOn: $plain)
                HStack {
                    Button("从剪贴板粘贴") { if let s = UIPasteboard.general.string { input = s } }
                    Spacer()
                    Button(m.busy ? "连接中…" : "连接") { Task { await m.connect(input) } }
                        .disabled(m.busy || input.isEmpty)
                }
            } header: { Text("Bot Token") } footer: {
                Text("Token 只保存在本机钥匙串，不会上传到任何服务器。")
            }

            if let b = m.bot {
                Section("状态") {
                    LabeledContent("Bot", value: b.username)
                    LabeledContent("服务器", value: "\(m.guilds.count) 个")
                    Button("断开并清除 Token", role: .destructive) { m.disconnect() }
                }
            }
            if let e = m.err {
                Section { Text(e).foregroundStyle(.red).font(.footnote) }
            }
            Section("使用提示") {
                Text("1. 在 Discord Developer Portal → Bot 页面开启 MESSAGE CONTENT INTENT，否则读不到消息内容。\n2. 频道页需要 Bot 有 View Channel 权限，发消息需要 Send Messages 权限。\n3. 定时与自动回复依赖 App 前台运行，锁屏或切后台会暂停。\n4. 发送间隔不要太短，Discord 限流会返回 429，App 会自动等待重试。")
                    .font(.footnote)
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var m: Mgr
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Picker("服务器", selection: Binding(get: { m.guildId }, set: { v in
                    m.guildId = v
                    if let v { Task { await m.loadChannels(v) } }
                })) {
                    Text("选择服务器").tag(Optional<String>.none)
                    ForEach(m.guilds) { g in Text(g.name).tag(Optional(g.id)) }
                }
                .pickerStyle(.menu)

                Picker("频道", selection: Binding(get: { m.channelId }, set: { v in
                    m.channelId = v
                    if let v { Task { await m.loadMsgs(v) } }
                })) {
                    Text("选择频道").tag(Optional<String>.none)
                    ForEach(m.channels) { c in Text("# " + c.display).tag(Optional(c.id)) }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                ForEach(m.msgs) { msg in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(msg.author.username).font(.caption).foregroundStyle(.secondary)
                        Text(msg.content.isEmpty ? "(空消息)" : msg.content).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)

            HStack {
                TextField("输入消息…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                Button { let t = text; text = ""; Task { await m.sendNow(t, cid: m.channelId) } } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(text.isEmpty || m.channelId == nil)
            }
            .padding()
        }
        .navigationTitle("频道")
    }
}

struct ChannelPicker: View {
    @EnvironmentObject var m: Mgr
    @Binding var cid: String
    var body: some View {
        Picker("目标频道", selection: $cid) {
            if m.known.isEmpty { Text("先去频道页加载").tag("") }
            ForEach(m.known) { c in Text("# " + c.display).tag(c.id) }
        }
    }
}

struct JobsView: View {
    @EnvironmentObject var m: Mgr
    @State private var edit: SendJob?
    @State private var newId = UUID()

    var body: some View {
        NavigationStack {
            List {
                if m.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有定时任务，点右上角 + 添加").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                ForEach($m.jobs) { $j in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.cname.isEmpty ? j.cid : "#" + j.cname).font(.subheadline.bold())
                            Text(j.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                            Text("每 \(Int(j.interval))s ± \(Int(j.jitter))s").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $j.enabled)
                            .labelsHidden()
                            .onChange(of: j.enabled) { _ in m.save() }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { edit = j }
                }
                .onDelete { m.jobs.remove(atOffsets: $0); m.save() }
            }
            .navigationTitle("定时发言")
            .toolbar {
                Button { var j = SendJob(); j.id = newId; newId = UUID(); edit = j } label: { Image(systemName: "plus") }
            }
            .sheet(item: $edit) { j in
                JobEditor(job: j) { saved in
                    if let i = m.jobs.firstIndex(where: { $0.id == saved.id }) { m.jobs[i] = saved }
                    else { m.jobs.append(saved) }
                    m.save()
                    edit = nil
                }
            }
        }
    }
}

struct JobEditor: View {
    @EnvironmentObject var m: Mgr
    @State var job: SendJob
    let done: (SendJob) -> Void

    var body: some View {
        NavigationStack {
            Form {
                ChannelPicker(cid: $job.cid)
                TextField("频道 ID（手动覆盖）", text: $job.cid)
                    .font(.system(.footnote, design: .monospaced))
                    .autocapitalization(.none)
                Section("内容") {
                    TextField("要发送的消息", text: $job.text, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("节奏") {
                    HStack { Text("间隔"); Slider(value: $job.interval, in: 10...3600, step: 10); Text("\(Int(job.interval))s").monospacedDigit() }
                    HStack { Text("抖动"); Slider(value: $job.jitter, in: 0...60, step: 1); Text("±\(Int(job.jitter))s").monospacedDigit() }
                }
                Toggle("立即启用", isOn: $job.enabled)
            }
            .navigationTitle("定时任务")
            .toolbar {
                Button("保存") {
                    job.lastRun = Date()
                    done(job)
                }
            }
        }
    }
}

struct RulesView: View {
    @EnvironmentObject var m: Mgr
    @State private var edit: Rule?
    @State private var newId = UUID()

    var body: some View {
        NavigationStack {
            List {
                if m.rules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.left").font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有自动回复规则，点右上角 + 添加").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                ForEach($m.rules) { $r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.cname.isEmpty ? r.cid : "#" + r.cname).font(.subheadline.bold())
                            Text("触发：" + (r.matchAll ? "任意消息" : r.keyword)).font(.caption)
                            Text("回复：" + r.reply).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $r.enabled)
                            .labelsHidden()
                            .onChange(of: r.enabled) { _ in m.save() }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { edit = r }
                }
                .onDelete { m.rules.remove(atOffsets: $0); m.save() }
            }
            .navigationTitle("自动回复")
            .toolbar {
                Button { var r = Rule(); r.id = newId; newId = UUID(); edit = r } label: { Image(systemName: "plus") }
            }
            .sheet(item: $edit) { r in
                RuleEditor(rule: r) { saved in
                    if let i = m.rules.firstIndex(where: { $0.id == saved.id }) { m.rules[i].keyword = saved.keyword; m.rules[i].reply = saved.reply; m.rules[i].cid = saved.cid; m.rules[i].matchAll = saved.matchAll; m.rules[i].enabled = saved.enabled }
                    else { m.rules.append(saved) }
                    m.save()
                    edit = nil
                }
            }
        }
    }
}

struct RuleEditor: View {
    @EnvironmentObject var m: Mgr
    @State var rule: Rule
    let done: (Rule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                ChannelPicker(cid: $rule.cid)
                TextField("频道 ID（手动覆盖）", text: $rule.cid)
                    .font(.system(.footnote, design: .monospaced))
                    .autocapitalization(.none)
                TextField("关键词", text: $rule.keyword)
                Toggle("任意消息都回复", isOn: $rule.matchAll)
                Section("回复内容") {
                    TextField("回复文本", text: $rule.reply, axis: .vertical).lineLimit(3...8)
                }
                Toggle("启用", isOn: $rule.enabled)
                Section { Text("需要在 Developer Portal 开启 MESSAGE CONTENT INTENT，否则读不到消息。").font(.footnote) }
            }
            .navigationTitle("自动回复规则")
            .toolbar {
                Button("保存") { done(rule) }
            }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var m: Mgr
    static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        NavigationStack {
            List(m.logs) { l in
                HStack(alignment: .top, spacing: 6) {
                    Text(Self.df.string(from: l.t)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Text(l.text).font(.caption)
                }
            }
            .listStyle(.plain)
            .navigationTitle("日志")
            .toolbar { Button("清空") { m.logs.removeAll() } }
        }
    }
}
