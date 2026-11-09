import SwiftUI
import AppKit

// MARK: - Shell + helpers
func sh(_ cmd: String, cwd: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; " + cmd]
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}
func json(_ s: String) -> Any? { s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
let isoF: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let isoP = ISO8601DateFormatter()
func parseDate(_ s: String) -> Date? { isoF.date(from: s) ?? isoP.date(from: s) }
func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s/60)m ago" }
    if s < 86400 { return "\(s/3600)h ago" }
    return "\(s/86400)d ago"
}
func inText(_ d: Date) -> String {
    let s = max(0, Int(d.timeIntervalSinceNow)); return s >= 3600 ? "in \(s/3600) hr \(s%3600/60) min" : "in \(s/60) min"
}

func openLink(_ s: String) { if !s.isEmpty, let u = URL(string: s) { NSWorkspace.shared.open(u) } }
// git remote (ssh or https) -> GitHub web URL; falls back to the local folder
func webURL(_ p: String) -> String {
    var r = sh("git remote get-url origin", cwd: p).trimmingCharacters(in: .whitespacesAndNewlines)
    if r.hasPrefix("git@") { r = "https://" + r.dropFirst(4).replacingOccurrences(of: ":", with: "/") }
    if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
    return r.hasPrefix("http") ? r : URL(fileURLWithPath: p).absoluteString
}

// MARK: - Config
struct Config {
    var fiveHourCap = 3_000_000.0   // tokens (input+output+cache writes) per 5h block
    var weekCap = 40_000_000.0
    var repos: [String] = []
    var plan = "local"
    var fivePct: Double?, fiveReset: Date?, weekPct: Double?, weekReset: Date?
    static func load() -> Config {
        var c = Config()
        let path = NSHomeDirectory() + "/.config/desk-widgets/config.json"
        if let s = try? String(contentsOfFile: path, encoding: .utf8), let j = json(s) as? [String: Any] {
            if let v = j["fiveHourCap"] as? Double { c.fiveHourCap = v }
            if let v = j["weekCap"] as? Double { c.weekCap = v }
            if let v = j["repos"] as? [String] { c.repos = v }
            if let v = j["plan"] as? String { c.plan = v }
            c.fivePct = j["fiveHourPct"] as? Double; c.weekPct = j["weekPct"] as? Double
            c.fiveReset = (j["fiveHourReset"] as? String).flatMap(parseDate); c.weekReset = (j["weekReset"] as? String).flatMap(parseDate)
        }
        return c
    }
}

// MARK: - Models
struct Usage { var fiveH = 0.0, week = 0.0, blockEnd: Date?, weekEnd: Date?, fiveTokens = 0.0, weekTokens = 0.0, exactWeek = false, fiveKnown = true, weekKnown = true }
struct RepoInfo: Identifiable { let id = UUID(); var name, branch: String; var dirty = 0, ahead = 0, behind = 0; var url = "" }
struct PR: Identifiable { let id = UUID(); var title, repo: String; var number: Int; var date: Date; var url = "" }
struct Run: Identifiable { let id = UUID(); var name, repo, branch, state: String; var date: Date; var url = "" }
struct Server: Identifiable { let id = UUID(); var name, cmd: String; var port: Int }

// MARK: - Providers
func loadUsage(_ cfg: Config) -> Usage {
    let root = NSHomeDirectory() + "/.claude/projects"
    let cutoff = Date().addingTimeInterval(-7 * 86400)
    var seen = Set<String>(); var entries: [(Date, Double)] = []
    guard let en = FileManager.default.enumerator(atPath: root) else { return Usage() }
    for case let rel as String in en where rel.hasSuffix(".jsonl") {
        let path = root + "/" + rel
        if let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m < cutoff { continue }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where line.contains("\"usage\"") {
            guard let o = json(String(line)) as? [String: Any], let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any], let ts = (o["timestamp"] as? String).flatMap(parseDate), ts >= cutoff else { continue }
            let key = "\(msg["id"] ?? "")\(o["requestId"] ?? "")"
            if key.count > 2 { if seen.contains(key) { continue }; seen.insert(key) }
            let t = ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0.0) { $0 + ((u[$1] as? Double) ?? 0) }
            entries.append((ts, t))
        }
    }
    entries.sort { $0.0 < $1.0 }
    var r = Usage()
    r.weekTokens = entries.reduce(0) { $0 + $1.1 }
    r.weekEnd = entries.first.map { $0.0.addingTimeInterval(7 * 86400) }
    var start: Date?
    for (d, t) in entries {
        if let s = start, d < s.addingTimeInterval(5 * 3600) { _ = s } else {
            start = Date(timeIntervalSinceReferenceDate: floor(d.timeIntervalSinceReferenceDate / 3600) * 3600); r.fiveTokens = 0
        }
        r.fiveTokens += t
    }
    if let s = start, Date() < s.addingTimeInterval(5 * 3600) { r.blockEnd = s.addingTimeInterval(5 * 3600) } else { r.fiveTokens = 0 }
    r.fiveH = r.fiveTokens / cfg.fiveHourCap * 100
    r.week = r.weekTokens / cfg.weekCap * 100
    if let p = cfg.fivePct, let t = cfg.fiveReset, t > Date() { r.fiveH = p; r.blockEnd = t }
    if let p = cfg.weekPct, let t = cfg.weekReset, t > Date() { r.week = p; r.weekEnd = t; r.exactWeek = true }
    if let (fp, fr, wp, wr) = fetchRealUsage() {
        // a cached window whose reset already passed is unknown until the API answers again
        let now = Date()
        r.fiveKnown = fr.map { $0 > now } ?? true; r.weekKnown = wr.map { $0 > now } ?? true
        r.fiveH = r.fiveKnown ? fp : 0; r.blockEnd = r.fiveKnown ? fr : nil
        r.week = r.weekKnown ? wp : 0; r.weekEnd = r.weekKnown ? wr : nil; r.exactWeek = true
    }
    return r
}


// Real limits: token read from the login Keychain by this app only, sent only to api.anthropic.com
var usageExpired = false
var usageCache: (Double, Date?, Double, Date?)?
var usageNextTry = Date.distantPast
var usageFetchedAt: Date?, usageRateLimited = false, usageRetryAfter: TimeInterval = 0
func fetchRealUsage() -> (Double, Date?, Double, Date?)? {
    // API rate-limits (429): poll at most every 10 min, honor Retry-After, keep last good value
    if Date() < usageNextTry { return usageCache }
    usageNextTry = Date().addingTimeInterval(600)
    let path = NSHomeDirectory() + "/.config/desk-widgets/last-usage.json"
    if usageCache == nil, let t = try? String(contentsOfFile: path, encoding: .utf8), let j = json(t) as? [String: Double] {
        usageCache = (j["f"] ?? 0, j["fr"].map { Date(timeIntervalSince1970: $0) }, j["w"] ?? 0, j["wr"].map { Date(timeIntervalSince1970: $0) })
        usageFetchedAt = j["t"].map { Date(timeIntervalSince1970: $0) }
    }
    if let r = fetchRealUsageNow() {
        usageCache = r; usageFetchedAt = Date()
        var j: [String: Double] = ["f": r.0, "w": r.2, "t": Date().timeIntervalSince1970]
        if let d = r.1 { j["fr"] = d.timeIntervalSince1970 }; if let d = r.3 { j["wr"] = d.timeIntervalSince1970 }
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: URL(fileURLWithPath: path)) }
        return r
    }
    usageNextTry = Date().addingTimeInterval(usageExpired ? 60 : max(900, usageRetryAfter))
    return usageCache
}
// Claude Code's login lives in the Keychain item below; it is read and written only through
// /usr/bin/security (the same tool Claude Code uses) and tokens are never logged
let credService = "Claude Code-credentials"
let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
func usageLog(_ m: String) {
    let line = "\(Date()) \(m)\n", path = "/tmp/dw-usage.log"
    if let h = FileHandle(forWritingAtPath: path), (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0) ?? 0 < 20_000 {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}
func runTool(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}
func readCreds() -> (acct: String, root: [String: Any])? {
    let (c, raw) = runTool("/usr/bin/security", ["find-generic-password", "-s", credService, "-w"])
    guard c == 0, let root = json(raw.trimmingCharacters(in: .whitespacesAndNewlines)) as? [String: Any] else { return nil }
    let (_, attrs) = runTool("/usr/bin/security", ["find-generic-password", "-s", credService])
    let acct = attrs.split(separator: "\n").first { $0.contains("\"acct\"") }
        .flatMap { l in l.range(of: #"="(.*)"$"#, options: .regularExpression).map { String(l[$0].dropFirst(2).dropLast()) } } ?? ""
    return (acct, root)
}
func post(_ url: String, _ body: [String: Any]) -> (Int, [String: Any]?) {
    var req = URLRequest(url: URL(string: url)!); req.httpMethod = "POST"; req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0); var code = -1; var obj: [String: Any]?
    URLSession.shared.dataTask(with: req) { d, r, _ in
        code = (r as? HTTPURLResponse)?.statusCode ?? -1
        obj = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }; sem.signal() }.resume()
    sem.wait(); return (code, obj)
}
// Trade the refresh token for a new access token and save it back so Claude Code keeps working too
func refreshAccessToken() -> String? {
    guard let (acct, root) = readCreds(), !acct.isEmpty, var o = root["claudeAiOauth"] as? [String: Any],
          let rt = o["refreshToken"] as? String else { usageLog("refresh: no refresh token in keychain"); return nil }
    let (c, r) = post("https://console.anthropic.com/v1/oauth/token", ["grant_type": "refresh_token", "refresh_token": rt, "client_id": oauthClientID])
    guard c == 200, let r, let at = r["access_token"] as? String else {
        usageLog("refresh: http \(c) \((r?["error"] as? String) ?? "")"); return nil }
    o["accessToken"] = at
    if let nrt = r["refresh_token"] as? String { o["refreshToken"] = nrt }
    if let exp = r["expires_in"] as? Double { o["expiresAt"] = Int((Date().timeIntervalSince1970 + exp) * 1000) }
    var newRoot = root; newRoot["claudeAiOauth"] = o
    guard let d = try? JSONSerialization.data(withJSONObject: newRoot), let str = String(data: d, encoding: .utf8) else { return at }
    let (w, _) = runTool("/usr/bin/security", ["add-generic-password", "-U", "-a", acct, "-s", credService, "-w", str])
    usageLog(w == 0 ? "refresh: ok, saved to keychain" : "refresh: ok but keychain write failed (\(w)); run claude and /login")
    return at
}
func currentAccessToken() -> String? {
    guard let (_, root) = readCreds(), let o = root["claudeAiOauth"] as? [String: Any], let at = o["accessToken"] as? String else {
        usageLog("no token in keychain"); return nil }
    // refresh 5 min before expiry
    if let exp = o["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 + 300 { return refreshAccessToken() ?? at }
    return at
}
func fetchRealUsageNow() -> (Double, Date?, Double, Date?)? {
    guard var tok = currentAccessToken() else { return nil }
    for attempt in 0..<2 {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeMacWidgets/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0); var data: Data?; var c = -1
        URLSession.shared.dataTask(with: req) { d, r, e in
            let h = r as? HTTPURLResponse; c = h?.statusCode ?? -1
            let ra = h?.value(forHTTPHeaderField: "Retry-After") ?? "-"
            usageLog("usage: http \(c) retry-after \(ra) \(e?.localizedDescription ?? "")")
            usageRateLimited = (c == 429); usageRetryAfter = Double(ra) ?? 0
            if c == 200 { data = d }; sem.signal() }.resume()
        sem.wait()
        if c == 401, attempt == 0, let t = refreshAccessToken() { tok = t; continue }
        usageExpired = (c == 401)
        guard let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let f = o["five_hour"] as? [String: Any], let w = o["seven_day"] as? [String: Any] else { return nil }
        func dt(_ x: [String: Any]) -> Date? { (x["resets_at"] as? String).flatMap(parseDate) }
        return ((f["utilization"] as? Double) ?? 0, dt(f), (w["utilization"] as? Double) ?? 0, dt(w))
    }
    return nil
}

func findRepos(_ cfg: Config) -> [String] {
    if !cfg.repos.isEmpty { return cfg.repos.map { ($0 as NSString).expandingTildeInPath } }
    let out = sh("find ~ -maxdepth 3 -name .git -type d -not -path '*/Library/*' -not -path '*/node_modules/*' -not -path '*/.*/*' 2>/dev/null")
    let paths = out.split(separator: "\n").map { String($0).replacingOccurrences(of: "/.git", with: "") }
    let dated = paths.map { p -> (String, Date) in
        let m = (try? FileManager.default.attributesOfItem(atPath: p + "/.git"))?[.modificationDate] as? Date
        return (p, m ?? .distantPast)
    }
    return dated.sorted { $0.1 > $1.1 }.prefix(4).map { $0.0 }
}

func loadGit(_ repos: [String]) -> [RepoInfo] {
    repos.prefix(3).map { p in
        let lines = sh("git status -sb", cwd: p).split(separator: "\n").map(String.init)
        var r = RepoInfo(name: (p as NSString).lastPathComponent, branch: "?", url: webURL(p))
        guard let h = lines.first else { return r }
        let head = h.dropFirst(3)
        r.branch = String(head.split(separator: ".").first ?? "?").trimmingCharacters(in: .whitespaces)
        if let m = h.range(of: #"ahead (\d+)"#, options: .regularExpression) { r.ahead = Int(h[m].dropFirst(6)) ?? 0 }
        if let m = h.range(of: #"behind (\d+)"#, options: .regularExpression) { r.behind = Int(h[m].dropFirst(7)) ?? 0 }
        r.dirty = lines.count - 1
        return r
    }
}

func loadPRs() -> [PR] {
    guard let a = json(sh("gh search prs --review-requested=@me --state=open -L 5 --json title,repository,number,updatedAt,url")) as? [[String: Any]] else { return [] }
    return a.compactMap { o in
        guard let t = o["title"] as? String, let n = o["number"] as? Int else { return nil }
        let repo = ((o["repository"] as? [String: Any])?["name"] as? String) ?? ""
        return PR(title: t, repo: repo, number: n, date: (o["updatedAt"] as? String).flatMap(parseDate) ?? Date(), url: o["url"] as? String ?? "")
    }
}

func loadRuns(_ repos: [String]) -> [Run] {
    var all: [Run] = []
    for p in repos.prefix(4) {
        guard let a = json(sh("gh run list -L 3 --json name,status,conclusion,headBranch,updatedAt,url", cwd: p)) as? [[String: Any]] else { continue }
        for o in a {
            let st = (o["status"] as? String) == "completed" ? ((o["conclusion"] as? String) ?? "") : "running"
            all.append(Run(name: o["name"] as? String ?? "", repo: (p as NSString).lastPathComponent, branch: o["headBranch"] as? String ?? "",
                           state: st, date: (o["updatedAt"] as? String).flatMap(parseDate) ?? Date(), url: o["url"] as? String ?? ""))
        }
    }
    return Array(all.sorted { $0.date > $1.date }.prefix(3))
}

func loadServers() -> [Server] {
    let out = sh("lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null")
    let dev = ["node", "python", "python3", "ruby", "bun", "deno", "vite", "next", "php", "uvicorn", "go", "java"]
    var seen = Set<Int>(); var res: [Server] = []
    for l in out.split(separator: "\n").dropFirst() {
        let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 9, dev.contains(f[0].lowercased()), let port = Int(f[8].split(separator: ":").last ?? "") , !seen.contains(port) else { continue }
        seen.insert(port)
        let cwd = sh("lsof -p \(f[1]) -a -d cwd -Fn 2>/dev/null").split(separator: "\n").first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) } ?? ""
        res.append(Server(name: cwd.isEmpty ? f[0] : (cwd as NSString).lastPathComponent, cmd: f[0], port: port))
    }
    return Array(res.sorted { $0.port < $1.port }.prefix(3))
}

func loadContrib() -> (Int, [[Int]]) {
    let q = "query{viewer{contributionsCollection{contributionCalendar{totalContributions weeks{contributionDays{contributionCount}}}}}}"
    guard let j = json(sh("gh api graphql -f query='\(q)'")) as? [String: Any],
          let cal = (((j["data"] as? [String: Any])?["viewer"] as? [String: Any])?["contributionsCollection"] as? [String: Any])?["contributionCalendar"] as? [String: Any],
          let total = cal["totalContributions"] as? Int, let weeks = cal["weeks"] as? [[String: Any]] else { return (0, []) }
    let grid = weeks.suffix(26).map { w in ((w["contributionDays"] as? [[String: Any]]) ?? []).map { $0["contributionCount"] as? Int ?? 0 } }
    return (total, grid)
}

// MARK: - Store
@MainActor final class Store: ObservableObject {
    @Published var usage = Usage(); @Published var repos: [RepoInfo] = []; @Published var prs: [PR] = []
    @Published var runs: [Run] = []; @Published var servers: [Server] = []
    @Published var total = 0; @Published var grid: [[Int]] = []; @Published var updated = Date(); @Published var login = ""
    var cfg = Config.load()
    func refresh() {
        let cfg = Config.load(); self.cfg = cfg
        Task.detached { [self] in
            let repos = findRepos(cfg)
            let login = sh("gh api user --jq .login").trimmingCharacters(in: .whitespacesAndNewlines)
            async let u = loadUsage(cfg), g = loadGit(repos), p = loadPRs(), r = loadRuns(repos), s = loadServers(), c = loadContrib()
            let (u1, g1, p1, r1, s1, c1) = await (u, g, p, r, s, c)
            await MainActor.run { usage = u1; self.repos = g1; prs = p1; runs = r1; servers = s1; total = c1.0; grid = c1.1; updated = Date(); self.login = login }
        }
    }
}

// MARK: - Views
struct Card<C: View>: View {
    let title: String, icon: String, tint: Color; var trailing = ""; var link = ""; @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Spacer()
                Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 330, height: 190, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.06, opacity: 0.92)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 24)).onTapGesture { openLink(link) }
    }
}
struct Meter: View {
    let label: String, pct: Double, sub: String
    var color: Color { pct >= 80 ? .orange : .white }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).font(.system(size: 13)); Spacer(); Text("\(Int(min(pct, 999)))%").font(.system(size: 13, weight: .semibold)).foregroundStyle(color) }
            GeometryReader { g in ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)); Capsule().fill(color).frame(width: g.size.width * min(1, pct / 100))
            } }.frame(height: 5)
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Claude card
let claudeCoral = Color(red: 0.851, green: 0.467, blue: 0.341)
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        let lens: [CGFloat] = [1, 0.74, 0.92, 0.68, 1, 0.8, 0.95, 0.7, 0.98, 0.76, 0.9, 0.72]
        for i in 0..<12 {
            let a = Double(i) / 12 * 2 * .pi - .pi / 2
            p.move(to: CGPoint(x: c.x + cos(a) * R * 0.16, y: c.y + sin(a) * R * 0.16))
            p.addLine(to: CGPoint(x: c.x + cos(a) * R * lens[i], y: c.y + sin(a) * R * lens[i]))
        }
        return p
    }
}
struct ClaudeLogo: View {
    var size: CGFloat = 22
    var body: some View { ClaudeMark().stroke(claudeCoral, style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round)).frame(width: size, height: size) }
}
struct Ring: View {
    let label: String, pct: Double, sub: String; var known = true
    var color: Color { !known ? .gray : pct >= 90 ? Color(red: 0.92, green: 0.27, blue: 0.27) : pct >= 70 ? Color(red: 1.0, green: 0.58, blue: 0.2) : pct >= 40 ? Color(red: 0.98, green: 0.80, blue: 0.2) : Color(red: 0.3, green: 0.82, blue: 0.45) }
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                Circle().trim(from: 0, to: min(1, pct / 100)).stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(known ? "\(Int(min(pct, 999)))%" : "—").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }.frame(width: 72, height: 72)
            Text(label).font(.system(size: 12, weight: .semibold))
            Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
}
struct ClaudeCard: View {
    let plan: String, updated: Date, u: Usage
    // age of the last real API answer, not of the widget refresh
    var status: String {
        if usageExpired { return "run claude to sign in" }
        let age = usageFetchedAt.map(ago) ?? "never"
        return usageRateLimited ? "rate limited · \(age)" : age
    }
    func reset(_ d: Date?, long: Bool) -> String {
        guard let d else { return "No active block" }
        return long ? "Resets \(d.formatted(.dateTime.weekday().hour().minute()))" : "Resets \(d.formatted(date: .omitted, time: .shortened))\n\(inText(d))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ClaudeLogo(size: 22)
                Text("Claude Code").font(.system(size: 14, weight: .semibold))
                Text(plan).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(claudeCoral.opacity(0.22))).foregroundStyle(claudeCoral)
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(usageExpired || usageRateLimited ? .orange : .secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Ring(label: "5 hours", pct: u.fiveH, sub: u.fiveKnown ? reset(u.blockEnd, long: false) : "Waiting for data", known: u.fiveKnown)
                Ring(label: "This week", pct: u.week, sub: u.weekKnown ? reset(u.weekEnd, long: true) : "Waiting for data", known: u.weekKnown)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 330, height: 190, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.08, opacity: 0.94), Color(white: 0.06, opacity: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(claudeCoral.opacity(0.25)))
        .contentShape(RoundedRectangle(cornerRadius: 24)).onTapGesture { openLink("https://claude.ai/settings/usage") }
    }
}
struct Dot: View { let c: Color; var body: some View { Circle().fill(c).frame(width: 9, height: 9) } }
func stateColor(_ s: String) -> Color { s == "success" ? .green : s == "running" || s == "in_progress" ? .orange : s == "" ? .gray : .red }

struct Dashboard: View {
    @ObservedObject var s: Store
    var body: some View {
        let u = s.usage
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ClaudeCard(plan: s.cfg.plan, updated: s.updated, u: u)
                Card(title: "GIT", icon: "arrow.triangle.branch", tint: .orange, link: s.login.isEmpty ? "" : "https://github.com/\(s.login)"+"?tab=repositories") {
                    ForEach(s.repos) { r in
                        HStack { VStack(alignment: .leading) { Text(r.name).font(.system(size: 14, weight: .medium)); Text(r.branch).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            if r.dirty == 0 && r.ahead == 0 && r.behind == 0 { Text("Up to date").foregroundStyle(.green).font(.system(size: 12)) }
                            else { Text("✎\(r.dirty) ↑\(r.ahead) ↓\(r.behind)").font(.system(size: 12)).foregroundStyle(.orange) } }
                        .contentShape(Rectangle()).onTapGesture { openLink(r.url) }
                    }
                }
            }
            HStack(spacing: 14) {
                Card(title: "GITHUB", icon: "arrow.triangle.pull", tint: .indigo, trailing: "\(s.prs.count) to review", link: "https://github.com/pulls/review-requested") {
                    if s.prs.isEmpty { Text("Nothing to review").foregroundStyle(.secondary) }
                    ForEach(s.prs.prefix(3)) { p in
                        VStack(alignment: .leading) { Text(p.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(ago(p.date)) · \(p.repo)#\(p.number)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        .contentShape(Rectangle()).onTapGesture { openLink(p.url) }
                    }
                }
                Card(title: "GITHUB ACTIONS", icon: "play.circle", tint: .indigo, link: s.repos.first.map { $0.url.hasPrefix("http") ? $0.url + "/actions" : "" } ?? "") {
                    if s.runs.isEmpty { Text("No runs").foregroundStyle(.secondary) }
                    ForEach(s.runs) { r in
                        HStack(spacing: 8) { Dot(c: stateColor(r.state))
                            VStack(alignment: .leading) { Text(r.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(r.repo) · \(r.branch)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(); Text(r.state == "running" ? "Running" : ago(r.date)).font(.system(size: 11)).foregroundStyle(stateColor(r.state)) }
                        .contentShape(Rectangle()).onTapGesture { openLink(r.url) }
                    }
                }
            }
            HStack(spacing: 14) {
                Card(title: "DEV SERVERS", icon: "server.rack", tint: .cyan, trailing: "\(s.servers.count) running") {
                    if s.servers.isEmpty { Text("None listening").foregroundStyle(.secondary) }
                    ForEach(s.servers) { v in
                        HStack { VStack(alignment: .leading) { Text(v.name).font(.system(size: 13, weight: .medium)); Text(v.cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                            Spacer(); Text(":\(v.port)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.green) }
                        .contentShape(Rectangle()).onTapGesture { openLink("http://localhost:\(v.port)") }
                    }
                }
                Card(title: "\(s.total) contributions", icon: "square.grid.3x3.fill", tint: .green, trailing: "last year", link: s.login.isEmpty ? "" : "https://github.com/\(s.login)") {
                    HStack(spacing: 3) {
                        ForEach(Array(s.grid.enumerated()), id: \.offset) { _, w in
                            VStack(spacing: 3) { ForEach(Array(w.enumerated()), id: \.offset) { _, n in
                                RoundedRectangle(cornerRadius: 2).fill(n == 0 ? Color.white.opacity(0.08) : Color.green.opacity(min(1, 0.3 + Double(n) / 10)))
                                    .frame(width: 8, height: 8) } }
                        }
                    }
                }
            }
        }
        .padding(8).preferredColorScheme(.dark)
    }
}

// MARK: - App
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var win: NSWindow!; var item: NSStatusItem!; let store = Store(); var timer: Timer?
    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: Dashboard(s: store))
        let size = host.fittingSize
        win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host; win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isMovableByWindowBackground = true
        win.setFrameAutosaveName("DeskWidgets")
        if !win.setFrameUsingName("DeskWidgets"), let f = NSScreen.main?.visibleFrame { win.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.maxY - size.height - 20)) }
        win.orderFrontRegardless()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Widgets")
        let m = NSMenu()
        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"); r.target = self; m.addItem(r)
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.store.refresh() }
    }
    @objc func refresh() { store.refresh() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let del = AppDelegate()
    app.delegate = del
    app.setActivationPolicy(.accessory)
    app.run()
}
