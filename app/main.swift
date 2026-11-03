import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 模型

enum RowState { case pending, ok, warn, fail, skip, config }

/// 单项修复的回执。`fix` 是全局动作,但回执必须落到具体项上 ——
/// 用户点的是「修这一项」,就该在这一行看到「修复中 / 已修复 / 修不了」,
/// 而不是一句全局的「正在修复…」然后什么都没有。
///
/// 失败必须带原因。脚本本来就吐了人话(`✗(请打开 Clash Verge 检查节点/线路)`),
/// 之前被界面丢掉了,只剩一句「需手动处理」—— 用户既不知道去哪儿改,
/// 也不知道是点了没反应还是真的改不了。
enum FixState: Equatable {
    case running
    case done(String)
    case failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    /// 回执附注。修好了常带「重启 Claude 后生效」这类前提,别让它丢了。
    var note: String {
        switch self {
        case .running: return ""
        case .done(let n), .failed(let n): return n
        }
    }
}

struct CheckRow: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    /// 用户能不能在设置里关掉这一项。8 项硬性检查不可关闭;6 项可关闭的默认也拦启动,
    /// 只是允许显式关闭或降级为警告。分组就是按这个分的,别把「可关闭」当成「不拦」。
    let canDisable: Bool
    var state: RowState = .pending
    var detail: String = ""
}

enum Phase { case checking, ready, failed, switching, done, fixing }

/// 一眼结论:分数 + 能不能启动。
///
/// 这两件事必须由同一套规则算出来。分开写就会出现「85 分」和「无法启动」
/// 同时挂在屏幕上的局面 —— 用户不知道该信哪个,而正确答案只有一个。
/// 放在模型层是为了能被测试直接喂检查行验算,不用靠肉眼看截图。
struct HealthSummary {
    enum Level {
        case ok
        case notice
        case cannotStart
    }

    let score: Int
    let level: Level
    let badge: String
    let headline: String

    var color: Color {
        switch level {
        case .ok: return ClaudeTheme.success
        case .notice: return ClaudeTheme.warning
        case .cannotStart: return ClaudeTheme.error
        }
    }

    /// 纯函数:输入 14 行检查结果,输出分数和一句话结论。
    ///
    /// 硬性项是「Claude 能不能启动」的开关,不是可以慢慢扣的分项 ——
    /// 代理内核没起来还挂着 85 分,等于告诉用户「小毛病,能用」,而实际是起不来。
    /// 所以硬性项一失败就直接塌到 30 分以下,提示项才按项扣。
    static func evaluate(_ rows: [CheckRow]) -> HealthSummary {
        let hard = rows.filter { !$0.canDisable }
        let soft = rows.filter { $0.canDisable }
        let hardBad = hard.filter { $0.state == .fail || $0.state == .config }
        let softBad = soft.filter { $0.state == .fail || $0.state == .config }
        let hardWarn = hard.filter { $0.state == .warn }.count
        let softWarn = soft.filter { $0.state == .warn }.count

        if let first = hardBad.first {
            let score = max(0, 28 - (hardBad.count - 1) * 9)
            let tail = hardBad.count > 1 ? "，另有 \(hardBad.count - 1) 项" : ""
            return HealthSummary(score: score, level: .cannotStart, badge: "无法启动",
                                 headline: "\(first.name)未通过\(tail) · Claude 不会启动")
        }

        let noticeScore = max(0, min(100, 100 - hardWarn * 12 - softBad.count * 8 - softWarn * 6))

        if let first = softBad.first {
            return HealthSummary(score: noticeScore, level: .notice, badge: "可以启动",
                                 headline: "\(first.name)未通过 · 不影响启动")
        }

        let notices = hardWarn + softWarn
        if notices > 0 {
            return HealthSummary(score: noticeScore, level: .notice, badge: "可以启动",
                                 headline: "\(notices) 项建议处理，不影响使用")
        }

        return HealthSummary(score: 100, level: .ok, badge: "正常",
                             headline: "全部通过 · Claude 可以正常启动")
    }
}

struct CoreResult {
    let output: String
    let succeeded: Bool
}

struct AccountStamp: Equatable {
    let size: String
    let date: String
}

/// 一次「真的动过手」的拦截。来自 `~/.claude-switcher/incidents.log`,
/// 脚本写、界面读。watch.log 是流水账(启动/复检/接管都在里面),这份只留拦截,
/// 否则用户想回头看「上次为什么被停」得从几百行里捞。
struct Incident: Identifiable {
    let id = UUID()
    let time: String
    let kind: String
    let reason: String
}

/// 一次生态探测的采样。脚本每次 `check` 往 rtt.log 追加一行,
/// 界面只读不写 —— 延迟数据必须是脚本真实测出来的,界面不能自己造。
struct RTTSample: Identifiable {
    let id = UUID()
    let at: Date
    let ms: Int
    let claudeCode: String
    let apiCode: String
    /// 两个端点都通了才算这次探测可用。ms 为 0 说明 curl 根本没拿到首包。
    var ok: Bool { ms > 0 && claudeCode != "000" && apiCode != "000" }
}

// 超时回调与 waitUntilExit 在不同队列上执行。
private final class ProcessDeadline {
    private let lock = NSLock()
    private var expired = false

    func expire(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        expired = true
        process.terminate()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

final class VM: ObservableObject {
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu", canDisable: false),
        CheckRow(name: "TUN 网卡", icon: "network", canDisable: false),
        CheckRow(name: "出口 IP", icon: "globe", canDisable: false),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal", canDisable: true),
        CheckRow(name: "时区", icon: "clock", canDisable: false),
        CheckRow(name: "地区", icon: "flag", canDisable: false),
        CheckRow(name: "IPv6 关闭", icon: "6.circle", canDisable: false),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass", canDisable: true),
        CheckRow(name: "WebRTC", icon: "eye.slash", canDisable: true),
        CheckRow(name: "保镖在线", icon: "hand.raised", canDisable: false),
        CheckRow(name: "规则置顶", icon: "list.number", canDisable: false),
        CheckRow(name: "客户端语言", icon: "textformat", canDisable: true),
        CheckRow(name: "ASN 属性", icon: "building.columns", canDisable: true),
        CheckRow(name: "生态可达性", icon: "antenna.radiowaves.left.and.right", canDisable: true),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var archived: Set<String> = []
    @Published var stamps: [String: AccountStamp] = [:]
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheckSummary = "尚未检查"
    @Published var updateText = ""
    @Published var showUpdateSheet = false
    @Published private(set) var coreMissing = false
    @Published private(set) var currentClient = ""
    @Published private(set) var isSwitchingClient = false
    @Published var disabledChecks: Set<String> = []
    @Published var allowOptionalFailures = false
    @Published var loggingEnabled = true
    @Published var settingsMessage = ""
    @Published private(set) var settingsBusy = false
    @Published var showSettingsSheet = false
    /// 运行期看门狗已经动手停了 Claude。与「检查没过」不是一回事:
    /// 后者是拉起前的门禁,前者是已经放行之后又被抓回来,必须显眼到不可能忽略。
    @Published private(set) var intercepted = false
    /// 拦截历史,最新的在前。脚本写 incidents.log,这里只读。
    @Published private(set) var incidents: [Incident] = []
    /// 单项修复回执:检查项名 → 修复中/已修复/修不了。修复结束后保留一小会儿,
    /// 让用户看清哪项修好了、哪项得自己动手。
    @Published private(set) var fixStates: [String: FixState] = [:]
    /// 修复结束的一句话小结,显示在顶栏下方,几秒后自动消失。
    @Published private(set) var fixNotice = ""
    /// 正在重查的项。重查时不清空上一轮结果,只给还没回来的行挂一个小转圈 ——
    /// 整屏先变灰再一格格填回来,看着像界面在抽搐,用户会以为卡住了。
    @Published private(set) var rechecking: Set<String> = []
    /// 看门狗是不是正守着。界面上的「驻守中」呼吸动画只看这一个开关。
    @Published private(set) var guarding = false
    /// 本次驻守从什么时候开始。用来显示「已驻守 2 小时 14 分」。
    @Published private(set) var guardSince: Date?
    /// 最近一次心跳。脚本每跑完一轮巡逻吐一行 `BEAT:<epoch>` ——
    /// 动画必须由它驱动:守护断了心跳就停,动画跟着停,用户才知道出事了。
    @Published private(set) var lastBeat: Date?
    /// 心跳停了多久算失联。看门狗每 10s 一轮,连丢两轮就该报。
    let beatTimeout: TimeInterval = 26
    /// 记录文件位置。生产是固定路径,测试注入到夹具目录 —— 否则跑测试会读到
    /// 本机真实的拦截历史,断言全凭运气。
    var incidentsPath = NSHomeDirectory() + "/.claude-switcher/incidents.log"
    /// 生态探测的采样流水。脚本写,界面读;文件不存在就当作「还没有采样」。
    var rttPath = NSHomeDirectory() + "/.claude-switcher/rtt.log"
    /// 最近 7 天的探测采样,按时间升序。窗口只取自己需要的区间。
    @Published private(set) var rttSamples: [RTTSample] = []

    static let optionalChecks: [(key: String, label: String)] = [
        ("IP一致", "IP 与上次一致"),
        ("DNS", "DNS 走隧道"),
        ("WebRTC", "WebRTC"),
        ("客户端语言", "客户端语言"),
        ("ASN属性", "ASN 属性"),
        ("生态可达性", "生态可达性"),
    ]

    static let clientChoices: [(key: String, label: String)] = [
        ("clash-verge", "Clash Verge"),
        ("flclash", "FlClash"),
        ("shadowrocket", "Shadowrocket"),
        ("sing-box", "sing-box"),
        ("clashx", "ClashX"),
        ("surge", "Surge"),
    ]

    let core: String
    private let checkTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private var started = false
    private var switchRequested = false
    private var checkingUpdate = false
    private var hideAfterSwitch: DispatchWorkItem?
    var onSwitchCompleted: (() -> Void)?

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh",
         checkTimeout: TimeInterval = 45, operationTimeout: TimeInterval = 180) {
        self.core = core
        self.checkTimeout = checkTimeout
        self.operationTimeout = operationTimeout
    }

    var canQuit: Bool { !switchRequested && phase != .fixing && phase != .switching }

    /// 只因为「没配好」而不通过,没有真正的安全项失败。两者提示语必须分开:
    /// 混成一句「存在未通过项」,用户会去排查安全问题,而实际只要补齐配置。
    var configOnlyFailure: Bool {
        phase == .failed
            && rows.contains { $0.state == .config }
            && !rows.contains { $0.state == .fail }
    }

    func start() {
        guard !started else { return }
        started = true
        killOrphanWatch()
        refresh()
    }

    /// App 被强杀或崩溃时,它起的看门狗走不到 applicationWillTerminate,会留成孤儿。
    /// 这些孤儿拿着上一轮的基线继续判,既可能误伤也可能和新的守护打架。
    /// 启动时收掉;脚本那边还有 pidfile 单实例锁兜底,两层都留着。
    ///
    /// 不能用 pkill -f "claude-switch.sh watch":它匹配的是整条命令行,任何命令行里
    /// 含这串字的进程都会被误杀 —— 包括用户自己的 grep、tail,以及我们派生的诊断
    /// 命令。实测踩到过,表现为「正在跑的 shell 突然收到 SIGTERM」。pidfile 才精确。
    private func killOrphanWatch() {
        #if CLAUDE_SWITCHER_TESTS
        // 测试进程不该碰真实环境:pidfile 指向的是本机正在跑的守护,杀了就断守护。
        #else
        Self.killWatchByPidfile()
        #endif
    }

    func prepareToShow() {
        hideAfterSwitch?.cancel()
        if phase == .done { phase = .ready }
    }

    /// onLine:每产出一行就回调一次,用于「边查边显示」。它只影响观感,
    /// 判定仍然由 done 里的完整输出决定 —— 流式预览不参与任何通过/失败计算,
    /// 否则半行、重复行都会变成判定输入。
    /// timeout <= 0 表示不设超时(看门狗是常驻进程,给它一个截止时间等于定时自杀)。
    /// onStart: 进程真正起来之后把 Process 交出去,好让调用方持有引用自己收尾 ——
    /// 用 pkill -f 全局匹配去杀,会连别的实例(比如 LaunchAgent 那份)一起带走。
    private func run(_ args: [String], timeout: TimeInterval = 45,
                     onLine: ((String) -> Void)? = nil,
                     onStart: ((Process) -> Void)? = nil,
                     done: @escaping (CoreResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-out-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let fh = try? FileHandle(forWritingTo: tmp) else {
                DispatchQueue.main.async { done(CoreResult(output: "无法创建检查输出文件", succeeded: false)) }
                return
            }
            defer {
                try? fh.close()
                try? FileManager.default.removeItem(at: tmp)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [self.core] + args
            p.standardOutput = fh
            p.standardError = fh
            do { try p.run() } catch {
                DispatchQueue.main.async { done(CoreResult(output: "无法启动脚本：\(error.localizedDescription)", succeeded: false)) }
                return
            }
            if let onStart { DispatchQueue.main.async { onStart(p) } }
            let deadline = ProcessDeadline()
            let watchdog = DispatchWorkItem { deadline.expire(p) }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            }
            if let onLine {
                // 检查要跑十来秒(出口采样是三次真实往返),这段时间界面不能一片「待检查」。
                // 轮询输出文件比改 Pipe 读取风险小:输出仍然落盘,收尾仍读全量。
                var offset: UInt64 = 0
                var pending = Data()
                while p.isRunning {
                    Thread.sleep(forTimeInterval: 0.12)
                    Self.drain(tmp, offset: &offset, pending: &pending, emit: onLine)
                }
                p.waitUntilExit()
                Self.drain(tmp, offset: &offset, pending: &pending, emit: onLine)
            } else {
                p.waitUntilExit()
            }
            watchdog.cancel()
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let result: CoreResult
            if deadline.timedOut {
                result = CoreResult(output: "操作超时，请重试", succeeded: false)
            } else if p.terminationStatus != 0 {
                result = CoreResult(output: "脚本执行失败（退出码 \(p.terminationStatus)）\n\(out)", succeeded: false)
            } else {
                result = CoreResult(output: out, succeeded: true)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// 检查项名 → 界面行名。流式预览和最终解析共用一份,避免两套映射慢慢走偏。
    static let rowNameMap: [String: String] = [
        "代理内核": "代理内核", "TUN网卡": "TUN 网卡", "出口IP": "出口 IP",
        "IP一致": "IP 与上次一致", "时区": "时区", "地区": "地区",
        "IPv6": "IPv6 关闭", "DNS": "DNS 走隧道", "WebRTC": "WebRTC",
        "保镖": "保镖在线", "规则置顶": "规则置顶",
        "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "生态可达性": "生态可达性",
    ]

    /// 单行预览:只改观感,不参与判定。最终结果由 done 里的全量解析覆盖。
    private func preview(_ line: String) {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let rowName = Self.rowNameMap[parts[0]],
              let idx = rows.firstIndex(where: { $0.name == rowName }) else { return }
        let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch status.first ?? "" {
        case "ok": rows[idx].state = .ok
        case "warn": rows[idx].state = .warn
        case "skip": rows[idx].state = .skip
        case "config": rows[idx].state = .config
        default: rows[idx].state = .fail
        }
        rows[idx].detail = status.count > 1 ? status[1] : ""
        rechecking.remove(rowName)
    }

    /// 读探测采样。格式:`epoch<TAB>ms<TAB>claude 状态码<TAB>api 状态码`,
    /// 脚本每次检查追加一行。半行/坏行直接丢,不猜。
    func loadRTT() {
        guard let text = try? String(contentsOfFile: rttPath, encoding: .utf8) else {
            rttSamples = []
            return
        }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let parsed: [RTTSample] = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let epoch = Double(f[0]), let ms = Int(f[1]) else { return nil }
            let at = Date(timeIntervalSince1970: epoch)
            guard at > cutoff else { return nil }
            return RTTSample(at: at, ms: ms,
                             claudeCode: f.count > 2 ? f[2] : "000",
                             apiCode: f.count > 3 ? f[3] : "000")
        }
        rttSamples = parsed.sorted { $0.at < $1.at }
    }

    /// 读拦截历史。TAB 分隔三列:时间 / 类型 / 原因 —— 和脚本那边一一对应,
    /// 少一列就整条丢掉,宁可少显示也不显示半条错的。
    func loadIncidents() {
        guard let text = try? String(contentsOfFile: incidentsPath, encoding: .utf8) else {
            incidents = []
            return
        }
        let parsed: [Incident] = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !f[2].isEmpty else { return nil }
            return Incident(time: f[0], kind: f[1], reason: f[2])
        }
        incidents = parsed.reversed()
    }

    func refresh() {
        guard !isBusy else { return }
        hideAfterSwitch?.cancel()
        // 重新检查前先撤掉旧的守护:否则它会在检查过程中按旧结论把 Claude 关掉。
        stopWatch()
        intercepted = false
        loadIncidents()
        loadRTT()
        if !coreAvailable() { markCoreMissing(); return }
        isBusy = true
        checkEnvironment { _ in self.isBusy = false }
    }

    // ---- 运行期看门狗 ----
    // 启动门禁只覆盖「拉起那一刻」。用着用着出口被切、代理掉线,Claude 不会自己停,
    // 会拿着错误的出口继续发请求。watch 补的就是这一段:脚本负责判定和关进程,
    // 界面只负责把原因显示出来。
    private var watchActive = false
    private var watchStopping = false
    private var watchProcess: Process?

    private func startWatch() {
        guard !watchActive else { return }
        watchActive = true
        watchStopping = false
        guarding = true
        guardSince = Date()
        lastBeat = nil
        run(["watch", "10", "6"], timeout: 0,
            onLine: { [weak self] line in
                self?.handleWatchLine(line)
            },
            onStart: { [weak self] p in
                self?.watchProcess = p
            }) { [weak self] _ in
            guard let self else { return }
            self.watchActive = false
            self.watchProcess = nil
            self.guarding = false
            self.guardSince = nil
            self.lastBeat = nil
            // 我们自己停的(重新检查/退出)不报警;意外退出必须报 —— 守护断了
            // 就意味着从现在起没人盯着出口,界面不能还挂着「通过」。
            guard !self.watchStopping else { return }
            self.phase = .failed
            if self.banner.isEmpty { self.banner = "看门狗已停止，请重新检查" }
        }
    }

    private func handleWatchLine(_ line: String) {
        // 心跳:每跑完一轮巡逻来一次。界面靠它证明「它真的还在守着」,
        // 而不是靠一个自己转的动画假装在守。
        if line.hasPrefix("BEAT:") {
            lastBeat = Date()
            return
        }
        guard line.hasPrefix("STOP:") else { return }
        let reason = String(line.dropFirst(5))
        watchStopping = true
        watchActive = false
        // 不动 isBusy:看门狗停 Claude 与界面上的修复/切换是两条线,
        // 清掉忙碌标记会让 refresh 的互斥失效,可能并发跑出两个检查。
        phase = .failed
        intercepted = true
        lastCheckSummary = "已拦截"
        banner = "已自动停止 Claude：\(reason)"
        // 脚本刚写完这条记录,立刻读回来 —— 界面上的「异常记录」要和日志同步,
        // 不能等下次重新检查才出现。
        loadIncidents()
        // 界面横幅只在窗口开着时有用,而这是「已经在用」的时候出的问题 ——
        // 用户多半没开窗口。必须推一条系统通知,否则等于没提醒。
        notify(title: "已自动停止 Claude", body: reason)
    }

    /// 走 osascript 而不是 UNUserNotificationCenter:这个 App 是 ad-hoc 签名,
    /// 通知授权在重签名后会失效,而 display notification 不依赖它。
    private func notify(title: String, body: String) {
        let clean = body.replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let script = "display notification \"\(clean)\" with title \"Claude 切换器\" subtitle \"\(title)\" sound name \"Basso\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    func stopWatch() {
        guard watchActive else { return }
        watchStopping = true
        watchActive = false
        guarding = false
        guardSince = nil
        lastBeat = nil
        if let p = watchProcess, p.isRunning {
            let pid = p.processIdentifier
            p.terminate()
            // terminate() 只发 SIGTERM,而 bash 正卡在 sleep 里时不会立刻响应 ——
            // 实测能拖到下一轮(10s)。这期间新起的守护会撞上旧的,两边各拿一份
            // 基线判出口。所以半秒还不停就直接 SIGKILL:旧守护多活一秒都是风险。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        } else {
            // onStart 是主队列异步回调,极端情况下 stopWatch 会先于它执行,那时
            // watchProcess 还是 nil。按 pidfile 兜底,别让旧守护借着这个空档活下来。
            #if !CLAUDE_SWITCHER_TESTS
            Self.killWatchByPidfile()
            #endif
        }
        watchProcess = nil
    }

    private static func killWatchByPidfile() {
        let path = NSHomeDirectory() + "/.claude-switcher/watch.pid"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // pidfile 格式是「pid<TAB>BASE」,取第一段。BASE 用来区分是不是本机的记录。
        let head = raw.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            .first.map(String.init) ?? ""
        guard let pid = pid_t(head), pid > 1 else { return }
        // pid 会被复用。杀之前先确认它确实是看门狗,而不是恰好拿到同一个号的进程。
        guard isWatchProcess(pid) else { return }
        kill(pid, SIGKILL)
    }

    private static func isWatchProcess(_ pid: pid_t) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("claude-switch.sh watch")
    }

    /// 把输出文件里新增的完整行吐出去。半行留在 pending 里等下一次,不猜。
    private static func drain(_ url: URL, offset: inout UInt64, pending: inout Data,
                              emit: @escaping (String) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let chunk = try? fh.readToEnd(), !chunk.isEmpty else { return }
        offset += UInt64(chunk.count)
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                DispatchQueue.main.async { emit(line) }
            }
        }
    }

    private func coreAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: core)
    }

    private func markCoreMissing() {
        coreMissing = true
        phase = .failed
        lastCheckSummary = "未安装核心脚本"
        banner = "未安装核心脚本：请下载 installer-kit 安装包并双击 installer/安装.command，或运行源码安装"
        for i in rows.indices {
            rows[i].state = .fail
            rows[i].detail = "未安装核心脚本"
        }
    }

    func refreshAccountStatus() {
        // 菜单展开时只读取本地账号状态，不触发网络审计；启动审计优先。
        guard started, !isBusy else { return }
        isBusy = true
        run(["status"], timeout: checkTimeout) { result in
            self.updateStatus(result)
            self.isBusy = false
        }
    }

    private func checkEnvironment(done: @escaping (Bool) -> Void) {
        if !coreAvailable() {
            markCoreMissing()
            rechecking = []
            done(false)
            return
        }
        coreMissing = false
        phase = .checking
        lastCheckSummary = "检查中"
        banner = ""
        note = ""
        // 新的一轮检查开始,上一轮修复回执就该退场了。
        fixStates = [:]
        // 保留上一轮结果,只标记「这一轮还没回来」。清空的话,14 行会先集体
        // 变灰、行高骤降、窗口跟着抽一下,再一行行长回来 —— 这就是「不直觉」。
        rechecking = Set(rows.map(\.name))
        run(["checkdetail"], timeout: checkTimeout, onLine: { [weak self] line in
            self?.preview(line)
        }) { result in
            var allOk = result.succeeded
            var matched = Set<Int>()
            var duplicated = false
            // 「没配好」和「不安全」要分开说:两者都拦启动(没验证过不能当验证通过),
            // 但用户该做的事完全不同 —— 前者去补配置,后者去修环境。
            var configRows: [String] = []
            var failedRows: [String] = []
            let keyMap = Self.rowNameMap
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let rowName = keyMap[parts[0]],
                      let idx = self.rows.firstIndex(where: { $0.name == rowName }) else { continue }
                // 重复行不能补齐缺失项，也不能用后来的 ok 覆盖先前的 fail。
                guard matched.insert(idx).inserted else { allOk = false; duplicated = true; continue }
                let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                switch status.first ?? "" {
                case "ok": self.rows[idx].state = .ok
                case "warn": self.rows[idx].state = .warn
                case "skip": self.rows[idx].state = .skip
                case "config":
                    // 环境层没配好。仍然算未通过,但归到「待配置」而不是「不安全」。
                    self.rows[idx].state = .config
                    allOk = false
                    configRows.append(self.rows[idx].name)
                default:
                    self.rows[idx].state = .fail
                    allOk = false
                    failedRows.append(self.rows[idx].name)
                }
                self.rows[idx].detail = status.count > 1 ? status[1] : ""
            }
            if !result.succeeded {
                self.banner = result.output.isEmpty ? "核心脚本执行失败" : result.output
                // 脚本整体失败时每一行都没有可信结论。这时候还留着上一轮的绿勾
                // 就是在骗人 —— 对一个门禁工具,「不知道」必须显示成「不知道」。
                for i in self.rows.indices {
                    self.rows[i].state = .fail
                    self.rows[i].detail = "核心脚本执行失败"
                }
            } else if duplicated {
                self.banner = "检测输出存在重复项，请重新检查"
            } else if matched.count != self.rows.count {
                self.banner = "检测输出不完整(\(matched.count)/\(self.rows.count))，请点重新检查"
            } else if !failedRows.isEmpty {
                // 真正的安全项不达标:说清是哪几项,再给唯一的下一步。
                self.banner = "未通过：\(failedRows.joined(separator: "、"))。按行内提示处理后重试"
            } else if !configRows.isEmpty {
                // 配置没就绪:不要说成「不安全」,否则用户会去修环境而不是补配置。
                self.banner = "环境没配好：\(configRows.joined(separator: "、"))。点「一键修复」补齐后重新检查"
            }
            let passed = allOk && matched.count == self.rows.count
            // 通过之后才开守护;不通过时把旧的撤掉,免得它拿旧结论继续放行。
            if passed { self.startWatch() } else { self.stopWatch() }
            self.lastCheckSummary = passed
                ? (self.rows.contains { $0.state == .warn }
                    ? "有警告"
                    : (self.rows.contains { $0.state == .skip } ? "通过（含跳过）" : "通过"))
                : (failedRows.isEmpty && !configRows.isEmpty ? "待配置" : "失败")
            self.run(["get-client"], timeout: self.checkTimeout) { clientResult in
                self.updateClient(clientResult)
                self.run(["status"], timeout: self.checkTimeout) { status in
                    let statusOK = self.updateStatus(status)
                    if !statusOK {
                        // 只在还没有失败原因时才用「读不到账号状态」兜底。
                        // 检查超时/脚本失败已经把真正的原因写进 banner,
                        // 用这条盖掉会让用户看到与事实无关的提示。
                        if self.banner.isEmpty {
                            self.banner = "无法读取账号状态，请重新检查"
                        }
                        self.lastCheckSummary = "失败"
                    }
                    self.phase = passed && statusOK ? .ready : .failed
                    // 收尾时兜底清空:输出缺行时那些项会一直挂着转圈,
                    // 界面看起来像永远没查完。
                    self.rechecking = []
                    // 这一轮刚往 rtt.log 追加了一条采样,顺手读回来 ——
                    // 不读的话洞察窗要等下次刷新才看到新点。
                    self.loadRTT()
                    done(passed && statusOK)
                }
            }
        }
    }

    @discardableResult
    private func updateStatus(_ result: CoreResult) -> Bool {
        let fields = result.output.split(whereSeparator: { $0.isWhitespace }).reduce(into: [String: String]()) { values, field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        func reset() -> Bool {
            current = "未知"; archived = []; stamps = [:]
            return false
        }
        guard result.succeeded, let account = fields["current"],
              ["A", "B", "C", "D", "none"].contains(account) else {
            return reset()
        }
        var known = Set<String>()
        if let list = fields["accounts"] {
            if list != "none" {
                for piece in list.split(separator: ",", omittingEmptySubsequences: true) {
                    let letter = String(piece)
                    guard Self.accountLetters.contains(letter) else { return reset() }
                    known.insert(letter)
                }
            }
        } else {
            // 旧版核心只输出 current/hasA/hasB,继续兼容已安装的旧脚本。
            for letter in ["A", "B"] {
                guard let flag = fields["has\(letter)"], ["0", "1"].contains(flag) else { return reset() }
                if flag == "1" { known.insert(letter) }
            }
        }
        var parsed: [String: AccountStamp] = [:]
        for letter in Self.accountLetters {
            guard let raw = fields["acc\(letter)"] else { continue }
            let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return reset() }
            parsed[letter] = AccountStamp(size: String(parts[0]), date: String(parts[1]))
        }
        current = account == "none" ? "未初始化" : account
        stamps = parsed
        archived = known
        return true
    }

    static let accountLetters = ["A", "B", "C", "D"]

    /// 脚本真的能自动处理的检查项。不在这个集合里的(出口 IP、IP 一致性、
    /// ASN、生态可达性)只能靠人换节点/换线路,给按钮等于给假承诺。
    static let fixableNames: Set<String> = [
        "代理内核", "TUN 网卡", "时区", "地区", "IPv6 关闭",
        "DNS 走隧道", "WebRTC", "保镖在线", "规则置顶", "客户端语言",
    ]

    private func updateClient(_ result: CoreResult) {
        guard result.succeeded else { return }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 && parts[0] == "client" {
                currentClient = parts[1]
            }
        }
    }

    func loadCheckConfig() {
        guard !settingsBusy, coreAvailable() else { return }
        settingsBusy = true
        settingsMessage = "正在读取设置…"
        run(["get-check-config"]) { result in
            self.settingsBusy = false
            guard result.succeeded,
                  let data = result.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let config = object as? [String: Any],
                  let disabled = config["disabled"] as? [String],
                  let allow = config["allowOptionalFailures"] as? Bool,
                  let logging = config["logging"] as? Bool,
                  Set(disabled).count == disabled.count,
                  disabled.allSatisfy({ name in Self.optionalChecks.contains { $0.key == name } }) else {
                self.settingsMessage = "读取检查设置失败，请恢复默认后重试"
                return
            }
            self.disabledChecks = Set(disabled)
            self.allowOptionalFailures = allow
            self.loggingEnabled = logging
            self.settingsMessage = ""
        }
    }

    func saveCheckConfig() {
        guard !isBusy, !settingsBusy, coreAvailable() else { return }
        let allowed = Set(Self.optionalChecks.map { $0.key })
        guard disabledChecks.isSubset(of: allowed) else {
            settingsMessage = "包含不允许关闭的安全检查"
            return
        }
        let config: [String: Any] = [
            "disabled": Self.optionalChecks.map { $0.key }.filter { disabledChecks.contains($0) },
            "allowOptionalFailures": allowOptionalFailures,
            "logging": loggingEnabled,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsBusy = true
        settingsMessage = "正在保存…"
        run(["set-check-config", json]) { result in
            self.settingsBusy = false
            self.settingsMessage = result.succeeded ? "设置已保存，正在重新检查" : result.output
            if result.succeeded { self.refresh() }
        }
    }

    func restoreCheckDefaults() {
        disabledChecks = []
        allowOptionalFailures = false
        loggingEnabled = true
        settingsMessage = "已恢复默认选项，点击保存后生效"
    }

    func exportDiagnostics() {
        guard !settingsBusy, coreAvailable() else { return }
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断日志"
        panel.message = "仅包含检查状态、设置和脱敏操作日志，不含 IP、凭据、账号或代理配置。"
        panel.nameFieldStringValue = "claude-switcher-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        settingsBusy = true
        settingsMessage = "正在导出诊断日志…"
        run(["export-diagnostics", destination.path], timeout: operationTimeout) { result in
            self.settingsBusy = false
            let message = result.succeeded ? result.output : "导出失败：\(result.output)"
            self.settingsMessage = message
            let alert = NSAlert()
            alert.messageText = result.succeeded ? "诊断日志已导出" : "诊断日志导出失败"
            alert.informativeText = message
            alert.alertStyle = result.succeeded ? .informational : .warning
            alert.runModal()
        }
    }

    func setClient(_ key: String) {
        guard !isBusy, !isSwitchingClient else { return }
        guard Self.clientChoices.contains(where: { $0.key == key }) else { return }
        guard key != currentClient else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        isBusy = true
        isSwitchingClient = true
        banner = "正在切换代理客户端…"
        run(["set-client", key], timeout: operationTimeout) { result in
            self.isSwitchingClient = false
            guard result.succeeded else {
                self.banner = result.output
                self.isBusy = false
                return
            }
            // 切换后重新完成环境审计,刷新「代理内核」等检查项
            self.currentClient = key
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    /// focus:用户点的是哪一项的「修复」。fix 本身是全局的(脚本没有单项修复),
    /// 但回执要重点落在这一项上 —— 别让人点了「修 WebRTC」却在别处找结果。
    func fixAll(focus: String? = nil) {
        guard !isBusy else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        hideAfterSwitch?.cancel()
        isBusy = true
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        fixNotice = ""
        fixStates = [:]
        // 只给脚本真能修的项挂「修复中」。给修不了的项也挂上,用户会盯着
        // 「生态可达性 · 修复中…」等半天,最后等来一个「修不了」。
        for row in rows where row.state == .fail || row.state == .config || row.state == .warn {
            guard Self.fixableNames.contains(row.name) else { continue }
            fixStates[row.name] = .running
        }
        if let focus { fixStates[focus] = .running }
        run(["fix"], timeout: operationTimeout, onLine: { [weak self] line in
            self?.applyFixLine(line)
        }) { result in
            guard result.succeeded else {
                self.banner = result.output
                self.phase = .failed
                self.fixStates = [:]
                self.isBusy = false
                return
            }
            let done = self.fixStates.filter { $0.value.isDone }.count
            let failedRows = self.fixStates.filter { $0.value.isFailed }.map(\.key)
            if !failedRows.isEmpty {
                // 点名比数数有用:用户下一步就是去改这几项,直接告诉他改哪几个。
                let names = failedRows.count <= 3
                    ? failedRows.joined(separator: "、")
                    : "\(failedRows.prefix(3).joined(separator: "、")) 等 \(failedRows.count) 项"
                self.fixNotice = done > 0
                    ? "\(done) 项已修复 · \(names) 需要你手动处理"
                    : "\(names) 需要你手动处理"
            } else if done > 0 {
                self.fixNotice = "\(done) 项已修复"
            }
            // 留 1.6 秒让回执可见,再重新检查。立刻复查会把回执清掉,
            // 用户只看到「修复中」一闪而过,不知道到底修好了什么。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.checkEnvironment { _ in self.isBusy = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if !self.isBusy { self.fixNotice = "" }
                }
            }
        }
    }

    /// 把一行 `FIX:` 输出映射到具体检查项。脚本按组报结果(「时区/IPv6/保镖 ✓」),
    /// 所以一条输出可能同时点亮好几行。
    ///
    /// 判定顺序:先看 ✗(失败),再看 ✓(成功),最后看「无法/未能/请手动」这类
    /// 没有符号但明显是失败的人话 —— 脚本里确实有这种行(「FlClash 未能退出，
    /// 请手动退出后重试」),以前被整条丢掉,用户点了修复什么回执都没有。
    private func applyFixLine(_ line: String) {
        guard line.hasPrefix("FIX:") else { return }
        let text = String(line.dropFirst(4))
        let failed = text.contains("✗") || Self.failureWords.contains(where: { text.contains($0) })
        let ok = text.contains("✓") && !failed
        guard ok || failed else { return }
        let state: FixState = failed ? .failed(Self.fixNote(from: text)) : .done(Self.fixNote(from: text))
        for name in Self.fixTargets(of: text) {
            fixStates[name] = state
        }
    }

    /// 没有 ✗/✓ 但确实是失败的说法。宁少不多:把过程提示误判成失败,
    /// 比漏判更糟 —— 用户会去改一个其实没问题的项。
    private static let failureWords = ["无法", "未能", "请手动", "改不了", "已中止", "回滚"]

    /// 从脚本那一行里抠出给人看的原因。
    ///
    /// 规则:有 ✓/✗ 就取符号后面那段(脚本习惯把「该怎么办」写在括号里,剥掉括号
    /// 留内容);符号后面是空的就说明没什么可补充的,返回空;整行没有符号的
    /// (「FlClash 未能退出，请手动退出后重试」)就整句留着 —— 那句话本身就是原因。
    static func fixNote(from text: String) -> String {
        if let i = text.firstIndex(where: { $0 == "✗" || $0 == "✓" }) {
            var rest = String(text[text.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("("), rest.hasSuffix(")") {
                rest = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return rest
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func fixTargets(of text: String) -> [String] {
        var names: [String] = []
        if text.contains("代理内核") || text.contains("TUN") {
            names += ["代理内核", "TUN 网卡"]
        }
        if text.contains("时区") { names.append("时区") }
        if text.contains("IPv6") { names.append("IPv6 关闭") }
        if text.contains("保镖") { names.append("保镖在线") }
        if text.contains("DNS") { names.append("DNS 走隧道") }
        if text.contains("WebRTC") { names.append("WebRTC") }
        if text.contains("语言") { names.append("客户端语言") }
        if text.contains("规则") { names.append("规则置顶") }
        return names
    }

    func inspectFingerprint() {
        guard !isBusy else { return }
        isBusy = true
        fingerprint = "正在体检…"
        run(["fingerprint"], timeout: 90) { result in
            self.fingerprint = result.output
            self.isBusy = false
        }
    }

    func checkUpdate() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateText = "正在检查更新…"
        run(["update-check"], timeout: 120) { result in
            self.updateText = result.output.isEmpty
                ? (result.succeeded ? "检查完成，核心脚本没有返回结果" : "检查失败，请重试")
                : result.output
            self.checkingUpdate = false
        }
    }

    var aiPrompt: String {
        let home = NSHomeDirectory()
        let agents = home + "/.claude-switcher/AGENTS.md"
        let agentsLine = FileManager.default.fileExists(atPath: agents)
            ? "本机交接文档：\(agents)"
            : "本机交接文档：\(agents)（~/.claude-switcher 不存在或其中没有 AGENTS.md，请从仓库根目录读取 AGENTS.md）"
        return """
        这是「Claude 切换器」的 AI 交接提示词。请先完整阅读交接文档，再开始安装、配置或排障。

        仓库地址：https://github.com/huanfine/claude-switcher
        \(agentsLine)

        执行要求：
        1. 先读 AGENTS.md，按其中的安装步骤、验收标准与安全红线执行，不要只凭本段提示词猜测。
        2. 安装或排障时先跑环境审计：硬性安全项必须通过；只有显式配置的非关键项可跳过或降为警告，skip 不表示检查通过。
        3. 账号切换前先完全退出 Claude；账号快照按 AGENTS.md 的规则保留，不要改动 ~/.claude-switcher/accounts/ 的结构。
        4. 保镖等常驻脚本只放在 root 所有的系统目录，不要改回用户可写路径；需要变更时引导我重跑安装器。
        5. 不要未经我明确同意更新、覆盖或重装已安装版本（~/.local/bin、桌面 App、launchd 与系统目录），也不要执行 update 或安装器；先说明影响并征得同意。
        6. 检查新版本只运行 `~/.local/bin/claude-switch.sh update-check`，看到结果后先问我是否执行更新。
        7. 不要在日志、文档或回复里暴露我的出口 IP、代理地址或任何凭据。
        """
    }

    func switchTo(_ target: String) {
        guard !isBusy, Self.accountLetters.contains(target) else { return }
        hideAfterSwitch?.cancel()
        isBusy = true
        switchRequested = true
        // 常驻后旧检查可能已经过期。每次切换都重新审计，不使用落盘的旧结果放行。
        checkEnvironment { passed in
            guard passed else {
                self.switchRequested = false; self.isBusy = false
                return
            }
            self.performSwitch(target)
        }
    }

    private func performSwitch(_ target: String) {
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        run(["switch", target], timeout: operationTimeout) { [self] result in
            let lines = result.output.split(separator: "\n").map(String.init)
            let failure = lines.first { $0.hasPrefix("FAIL:") }
            let success = lines.contains { $0.hasPrefix("OK:") || $0.hasPrefix("INFO:") }
            guard result.succeeded, failure == nil, success else {
                self.phase = .failed
                self.banner = failure.map { String($0.dropFirst(5)) } ?? (result.output.isEmpty ? "切换未返回成功结果，请重新检查" : result.output)
                self.switchRequested = false; self.isBusy = false
                return
            }
            var extra = ""
            if target != "A" && !self.archived.contains(target) {
                extra = "\(target) 号首次使用：请在打开的 Claude 里登录 \(target) 账号，登录一次即可。"
            }
            let unchanged = lines.contains { $0.hasPrefix("INFO:") }
            if unchanged { extra = "" }
            self.current = target
            self.phase = .done
            self.banner = unchanged ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = extra
            self.switchRequested = false; self.isBusy = false
            let hide = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .done, !self.isBusy else { return }
                self.onSwitchCompleted?()
                self.phase = .ready
            }
            self.hideAfterSwitch = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: hide)
        }
    }
}

// MARK: - Claude 风格外观

enum ClaudeTheme {
    /// 深浅色成对定义。用 NSColor 的 dynamicProvider 而不是 @Environment(\.colorScheme):
    /// 后者要在每个视图里传一遍,而且菜单栏弹窗、sheet 里容易漏。这里是「一次定义,
    /// 到处自适应」,系统切换外观时不用重启也不用刷新。
    private static func dual(_ light: (Double, Double, Double),
                             _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // 基底:浅色是暖纸,深色是暖炭 —— 不用纯黑,纯黑配陶土橙会发脏
    static let bgTop = dual((0.984, 0.976, 0.961), (0.110, 0.106, 0.098))      // #FAF9F5 / #1C1B19
    static let bgBottom = dual((0.957, 0.945, 0.925), (0.086, 0.082, 0.075))   // #F4F1EC / #161513
    // 卡片面。深色下比底色提亮一档(#2A2723 vs #1C1B19) —— 没有描边之后,
    // 卡片和背景全靠这点明度差分开,差太小整屏就糊成一片。
    // 卡片面。深色下要和底色拉开到 1.25:1 才立得住 —— 去掉描边之后,
    // 「这是一张卡」全靠这点明度差。之前 #2A2725 对 #1C1B19 只有 1.17:1,
    // 亮屏能看出一点,夜里亮度调低就彻底糊成一片。
    static let card = dual((1.000, 1.000, 1.000), (0.184, 0.176, 0.161))       // #FFFFFF / #2F2D29
    static let cardBorder = dual((0.898, 0.882, 0.855), (0.208, 0.200, 0.184)) // #E5E1DA / #35332E
    static let divider = dual((0.941, 0.929, 0.910), (0.173, 0.165, 0.149))    // #F0ECE8 / #2C2A26
    static let iconWell = dual((0.965, 0.953, 0.937), (0.220, 0.212, 0.196))   // #F6F3EF / #38352F
    /// 槽位面。比卡片再退一档:浅色下是浅暖灰,深色下是提亮两档的炭。
    /// 没有描边之后,槽位和卡片全靠这一档明度差分开 —— 用 iconWell 不够,
    /// 深色下它和 card 只差 0.01,四个槽位会完全消失。
    static let slotWell = dual((0.953, 0.941, 0.925), (0.204, 0.196, 0.180))   // #F3F0EC / #34322E

    // 字体色阶
    static let ink = dual((0.165, 0.153, 0.141), (0.949, 0.937, 0.914))        // #2A2724 / #F2EFE9
    static let muted = dual((0.455, 0.435, 0.412), (0.604, 0.580, 0.549))      // #746F69 / #9A948C

    // Claude 标志性陶土橙。深色下提亮,否则在炭底上糊成一团
    static let terracotta = dual((0.847, 0.447, 0.329), (0.878, 0.541, 0.424)) // #D87254 / #E08A6C
    static let terracottaDeep = dual((0.761, 0.369, 0.259), (0.937, 0.612, 0.482)) // #C25E42 / #EF9C7B
    static let terracottaTint = dual((0.847, 0.447, 0.329), (0.878, 0.541, 0.424)).opacity(0.12)

    // 状态色
    static let success = dual((0.180, 0.490, 0.322), (0.435, 0.749, 0.557))    // #2E7D52 / #6FBF8E
    static let warning = dual((0.722, 0.431, 0.094), (0.878, 0.643, 0.361))    // #B86E18 / #E0A45C
    static let warningBorder = dual((0.961, 0.863, 0.718), (0.322, 0.259, 0.157))
    static let error = dual((0.761, 0.282, 0.212), (0.878, 0.439, 0.361))      // #C24836 / #E0705C
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClaudeTheme.bgTop, ClaudeTheme.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [ClaudeTheme.terracotta.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 辅助样式组件

struct ClaudeIconButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // 无边框,只在 hover 时浮出一块底。四个带框的小方块并排会像
            // 一排工具栏按钮,而它们只是三个次要入口 + 一个重查。
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(disabled ? ClaudeTheme.muted.opacity(0.45)
                                          : (isHovered ? ClaudeTheme.ink : ClaudeTheme.muted))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isHovered && !disabled ? ClaudeTheme.iconWell : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(help)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 主界面

private func openInBrowser(_ text: String) {
    if let url = URL(string: text) { NSWorkspace.shared.open(url) }
}

/// 行内「修复」。点下去到出结果之间有一两秒空档,这段时间按钮必须看起来
/// 「已经被按下去了」—— 没反应的话用户会连点,而 fix 是全局动作,连点会互相打断。
private struct FixActionButton: View {
    var label = "修复"
    var prominent = false
    /// 行内按钮用 quiet:默认只留文字,悬浮才铺底。
    /// 一行橙色实心胶囊会在清单里跳出来抢走全部注意力,而它只是一个可选项。
    var quiet = false
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    private var textColor: Color {
        if prominent || hovered { return .white }
        return ClaudeTheme.terracottaDeep
    }

    private var fillColor: Color {
        if prominent || hovered { return ClaudeTheme.terracotta }
        return quiet ? Color.clear : ClaudeTheme.terracotta.opacity(0.12)
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(textColor)
                .padding(.horizontal, prominent ? 14 : 11)
                .padding(.vertical, prominent ? 5.5 : 4)
                .background(Capsule().fill(fillColor))
                .scaleEffect(pressed ? 0.96 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.12)) { pressed = false } }
        )
        .accessibilityLabel(label)
    }
}

/// 底栏的纯文字按钮。默认弱化,鼠标移上去才亮。
private struct GhostTextButton: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(hovered ? ClaudeTheme.ink : ClaudeTheme.muted)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
        .accessibilityLabel(label)
    }
}

/// 统一的卡片壳:一个圆角面,靠「面」本身的明度差和一层极轻的投影浮起来。
/// 不用描边 —— 一圈 1pt 的线在 1000pt 宽的窗口里会把每张卡切成方盒子,
/// 整屏看着像表格;去掉之后卡片之间靠留白和层次说话,才是「面」而不是「框」。
private struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ClaudeTheme.card))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // 投影加在裁切之后,否则会被自己裁掉一半。半径给得大、透明度给得很低:
            // 目的是让卡片「浮起来一毫米」,不是画一个阴影。
            .shadow(color: Color.black.opacity(0.055), radius: 12, x: 0, y: 3)
    }
}

/// 自绘的转圈,给「正在核对 / 正在修复 / 正在扫描」这类临时态用。
///
/// 不用系统 `ProgressView`:那个小菊花在浅色卡上是一团灰糊,粗细和整屏的
/// 细线圆角语言也不搭。这里只画一段弧,慢、细、和主题色一致。
///
/// 单独成一个视图,是因为动画必须在「它自己 appear」那一刻起。写在父视图的
/// onAppear 里改 @State,会和首帧的渲染挤进同一个事务,SwiftUI 直接把它当成
/// 初值 —— 弧线纹丝不动。
private struct SpinRing: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.5
    var duration: Double = 0.9
    var trimEnd: CGFloat = 0.24
    var color: Color = ClaudeTheme.muted
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: trimEnd)
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                angle = 0
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// 看门狗驻守条。
///
/// 为什么要有动画:这个工具的价值全在「它一直盯着」。可一个静止的绿字
/// 「保镖在线」和一张截图没区别 —— 用户没法区分「正在守」和「上次检查时还在守」。
/// 动画就是那个「现在进行时」的凭据。
///
/// 但动画不能自己转。每一圈雷达扫过的涟漪都由脚本吐的 `BEAT:` 心跳驱动:
/// 守护断了心跳就停,涟漪跟着停,条子转成警告色 —— 这时动画停下来本身就是信号。
/// 一个永远在转的假动画,比没有动画更危险。
private struct GuardBand: View {
    @ObservedObject var vm: VM
    /// 每秒走一格。只用来把「最近心跳 3 秒前」和失联判定刷新出来。
    @State private var now = Date()
    @State private var ripple = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 心跳是否新鲜。看门狗 10s 一轮,连丢两轮(26s)才算失联 ——
    /// 一次 curl 抖动不该让界面闪红。
    private var fresh: Bool {
        guard vm.guarding else { return false }
        guard let beat = vm.lastBeat else { return true }   // 刚起,第一轮还没跑完
        return now.timeIntervalSince(beat) < vm.beatTimeout
    }

    private var tone: Color {
        if !vm.guarding { return ClaudeTheme.muted }
        return fresh ? ClaudeTheme.success : ClaudeTheme.warning
    }

    private var title: String {
        if vm.intercepted { return "看门狗已拦截并停止" }
        if !vm.guarding { return "看门狗未驻守" }
        return fresh ? "运行期看门狗驻守中" : "看门狗失联"
    }

    private var subtitle: String {
        if vm.intercepted { return "下一次重新检查通过后才会继续守护" }
        if !vm.guarding { return "检查通过后自动开始守护 · 点「重新检查」" }
        if !fresh { return "超过 \(Int(vm.beatTimeout)) 秒没收到心跳 · 守护可能已中断" }
        // 「保镖在线」那一行说的是 root 装的 launchd 守护,这里说的是 App 自己
        // 起的运行期看门狗 —— 两套机制,名字必须在文案里分清,否则用户会以为
        // 同一件事被报了两次,还一好一坏。
        return "随 App 常驻 · 每 10 秒巡逻一轮，出口变化立刻停掉 Claude"
    }

    var body: some View {
        HStack(spacing: 13) {
            glyph

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(fresh ? ClaudeTheme.ink : tone)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                Text(dutyText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted)
                    .lineLimit(1)
                Text(beatText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fresh ? ClaudeTheme.success.opacity(0.9)
                                           : ClaudeTheme.muted.opacity(0.7))
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tone.opacity(fresh ? 0.075 : 0.05))
        )
        .onReceive(tick) { now = $0 }
        // 用 onReceive 订阅而不是 onChange:onChange 的单参数形式在 macOS 14
        // 已废弃,而两参数形式要 14+,这个 App 还要跑 13。
        .onReceive(vm.$guarding) { on in
            if on { pulse() }
        }
        .onReceive(vm.$lastBeat) { beat in
            if beat != nil { pulse() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)，\(dutyText)，\(beatText)")
    }

    // MARK: 图形

    private var glyph: some View {
        ZStack {
            // 底圈:告诉眼睛这里有个「雷达」
            Circle()
                .fill(tone.opacity(0.10))
                .frame(width: 34, height: 34)

            if fresh {
                // 扫描弧。慢(2.6s 一圈),慢到不会让人分心,又能看出在动。
                SpinRing(size: 34, lineWidth: 1.6, duration: 2.6, color: tone)

                // 心跳涟漪:每收到一次 BEAT 扩一圈。这一圈才是「它刚刚真的
                // 巡逻过」的证据,扫描弧只说明界面没卡死。
                Circle()
                    .stroke(tone.opacity(0.55), lineWidth: 1.1)
                    .frame(width: 34, height: 34)
                    .scaleEffect(ripple ? 1.55 : 1)
                    .opacity(ripple ? 0 : 0.9)
            }

            Image(systemName: vm.intercepted ? "hand.raised.fill" : "shield.lefthalf.filled")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(tone)
        }
        .frame(width: 34, height: 34)
    }

    /// 一圈涟漪。1.1s 扩到 1.55 倍并淡出,比扫描弧快一个量级 ——
    /// 快的那一下是「刚刚」,慢的那圈是「一直在」。
    private func pulse() {
        ripple = false
        withAnimation(.easeOut(duration: 1.1)) { ripple = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { ripple = false }
    }    // MARK: 文案

    private var dutyText: String {
        guard vm.guarding, let since = vm.guardSince else { return "未驻守" }
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "已驻守 \(s) 秒" }
        if s < 3600 { return "已驻守 \(s / 60) 分" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "已驻守 \(h) 小时" : "已驻守 \(h) 小时 \(m) 分"
    }

    private var beatText: String {
        guard vm.guarding else { return "—" }
        guard let beat = vm.lastBeat else { return "等待首次心跳" }
        let s = max(0, Int(now.timeIntervalSince(beat)))
        if s < 2 { return "心跳 刚刚" }
        if s < 60 { return "心跳 \(s) 秒前" }
        return "心跳 \(s / 60) 分钟前"
    }
}

struct ContentView: View {
    @ObservedObject var vm: VM
    /// 只用于量高度:去掉 ScrollView,让内容摊成自然高度。
    /// AppDelegate 拿它算窗口该多高,算完就丢,不显示。
    var measureOnly = false
    /// 量高时必须把宽度钉死。不钉的话 NSHostingView 会按内容理想宽度去量,
    /// 和真实窗口差几十 pt,换行数就变了,量出来的高度对不上。
    var measureWidth: CGFloat? = nil

    @State private var showNotice = false
    @State private var showFingerprint = false
    @State private var showAIPrompt = false
    @State private var showHistory = false
    /// `--latency` 直接打开洞察窗,只为了截图/回归时不用手点。
    @State private var showLatency = CommandLine.arguments.contains("--latency")
    @State private var hoveredRow: String?
    @State private var hoveredAccount: String?

    static let width: CGFloat = 1000
    static let height: CGFloat = 660

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 0) {
                toolbar
                if let strip = noticeStrip {
                    strip.transition(.opacity.combined(with: .move(edge: .top)))
                }

                if measureOnly {
                    mainContent
                } else {
                    ScrollView(.vertical, showsIndicators: true) { mainContent }
                }

                footer
            }
        }
        // 窗口用 fullSizeContentView,SwiftUI 会替标题栏留一条安全区。
        // 量高的探针没有窗口,拿不到这条安全区,量出来就比真实内容矮一截。
        // 干脆两边都不要安全区,布局自己让开红绿灯(工具栏左侧 86pt 就是干这个的)。
        .ignoresSafeArea()
        .frame(minWidth: measureOnly ? 0 : 860, minHeight: measureOnly ? 0 : 560)
        .frame(width: measureWidth)
        .animation(.easeInOut(duration: 0.22), value: vm.phase)
        .animation(.easeInOut(duration: 0.22), value: vm.intercepted)
        .animation(.easeInOut(duration: 0.18), value: vm.fixNotice)
        .sheet(isPresented: $showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .sheet(isPresented: $vm.showSettingsSheet) { CheckSettingsView(vm: vm) }
        .sheet(isPresented: $showNotice) { NoticeView() }
        .sheet(isPresented: $showFingerprint) { FingerprintView(text: vm.fingerprint) }
        .sheet(isPresented: $showHistory) { IncidentHistorySheet(vm: vm) }
        .sheet(isPresented: $showLatency) { LatencyInsightSheet(vm: vm) }
    }

    /// 主区内容。窗口高度就是按它量出来的,所以量高模式下必须和滚动模式
    /// 用同一份布局,否则量到的和看到的差一截。
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            heroCard
            accountSection
            // 两列而不是一列:14 行竖着堆,窗口要么高到离谱,要么矮到要滚动。
            HStack(alignment: .top, spacing: 20) {
                checkCard("核心安全基线", subtitle: "不可关闭 · 每次启动都校验",
                          symbol: "shield.lefthalf.filled", rows: hardRows)
                checkCard("加固与提示", subtitle: "可关闭 · 关闭后不参与拦截",
                          symbol: "slider.horizontal.3", rows: softRows)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 9) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep],
                                             startPoint: .top, endPoint: .bottom))
                )

            Text("Claude 切换器")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(ClaudeTheme.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            ClaudeIconButton(systemName: "arrow.clockwise", help: "重新检查环境", disabled: vm.isBusy) {
                vm.refresh()
            }
            ClaudeIconButton(systemName: "waveform.path.ecg", help: "设备指纹体检(字体/GPU/虚拟机)", disabled: vm.isBusy) {
                showFingerprint = true
                vm.inspectFingerprint()
            }
            ClaudeIconButton(systemName: "gearshape", help: "检查设置与诊断日志") {
                vm.showSettingsSheet = true
            }
            ClaudeIconButton(systemName: "info.circle", help: "安全防护体系公告") {
                showNotice = true
            }
        }
        .padding(.leading, 86)   // 让开红绿灯
        .padding(.trailing, 20)
        .padding(.top, 3)        // 与红绿灯同一行:标题栏就是工具栏
        .padding(.bottom, 12)
    }

    // MARK: 主视觉:一眼看到「现在到底什么状态」

    private var heroCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 18) {
                healthRing

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(heroTitle)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(ClaudeTheme.ink)
                            .lineLimit(1)
                        heroBadge
                    }
                    // 结论单独一行、给到 12.5pt 半粗:这一屏最该被读到的一句话。
                    // 埋在 meta 行的小灰字里,等于没写。
                    Text(heroVerdict.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(heroVerdict.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    heroMetaRow
                }

                Spacer(minLength: 14)

                HStack(spacing: 8) {
                    // 检查是这个工具的主动作,给它一个正经按钮 —— 工具栏上那个
                    // 12pt 的刷新图标,用户根本不会去找。
                    Button { vm.refresh() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text(vm.phase == .checking ? "检查中…" : "重新检查")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(ClaudeTheme.ink)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(ClaudeTheme.iconWell))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                    .opacity(vm.isBusy ? 0.55 : 1)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("重新逐项检查环境（⌘R）")

                    if fixableProblemCount > 0 && !vm.isBusy {
                        // 按钮带上数字:5 项问题里只有 2 项能自动修,写「一键修复」
                        // 会让人以为点完就全绿了。已守护时处理的是提示项,不是故障。
                        FixActionButton(label: vm.phase == .ready
                                            ? "处理 \(fixableProblemCount) 项提示"
                                            : "修复 \(fixableProblemCount) 项",
                                        prominent: true) { vm.fixAll() }
                    }
                }
                .fixedSize()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)

                // 「已守护」是结论,这一条是凭据 —— 结论和「凭什么」挨着放,
                // 用户才不用猜这个绿字是哪儿来的。
                GuardBand(vm: vm)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
            }
        }
    }

    /// 结论:一句话说清「现在能不能用」。
    /// 分数是给一眼扫的,结论是给做决定的 —— 85 分配一句「无法启动」比
    /// 只有分数有用得多,之前两样都没有。
    private struct Verdict {
        let short: String
        let text: String
        let color: Color
    }

    /// 唯一的结论来源。检查落定后一律走 `HealthSummary.evaluate`,
    /// 视图这边只负责把「进行中」的几种临时态翻译成人话。
    private var healthSummary: HealthSummary {
        if vm.intercepted { return HealthSummary(score: 0, level: .cannotStart, badge: "已拦截",
                                                 headline: "已自动停止 Claude") }
        switch vm.phase {
        case .checking:
            // 标题已经写了「正在检查」,徽章再写一遍就是重复;换成进度更有用。
            let done = vm.rows.filter { !vm.rechecking.contains($0.name) }.count
            return HealthSummary(score: 0, level: .notice,
                                 badge: "\(done)/\(vm.rows.count)",
                                 headline: "正在逐项核对 \(vm.rows.count) 项")
        case .fixing:
            return HealthSummary(score: 0, level: .notice, badge: "处理中",
                                 headline: "正在修复可自动处理的问题")
        case .switching:
            return HealthSummary(score: 0, level: .notice, badge: "切换中",
                                 headline: "正在切换账号，随后会重新检查")
        case .ready, .done, .failed:
            return HealthSummary.evaluate(vm.rows)
        }
    }

    private var heroVerdict: Verdict {
        let s = healthSummary
        if vm.intercepted {
            return Verdict(short: s.badge, text: "已自动停止 Claude · \(interceptedReason)", color: s.color)
        }
        switch vm.phase {
        case .checking, .fixing, .switching:
            return Verdict(short: s.badge, text: s.headline, color: ClaudeTheme.terracotta)
        case .ready, .done, .failed:
            return Verdict(short: s.badge, text: s.headline, color: s.color)
        }
    }

    private var healthScore: Int { healthSummary.score }

    private var healthRingProgress: CGFloat {
        if vm.rows.contains(where: { $0.state == .pending }) && vm.phase == .checking { return 0 }
        return CGFloat(healthScore) / 100
    }

    private var healthRingColor: Color {
        // 全绿时用品牌陶土橙,不用绿色 —— 一屏绿色比一个陶土环更像「报表」。
        // 有问题时才切到状态色,红色环和红色结论一起出现,指向同一件事。
        healthSummary.level == .ok ? ClaudeTheme.terracotta : healthSummary.color
    }

    /// 圆环 + 分数。比一个大图标更能一眼看出「离满分还差多少」。
    private var healthRing: some View {
        ZStack {
            Circle()
                .stroke(ClaudeTheme.cardBorder.opacity(0.7), lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: healthRingProgress)
                .stroke(healthRingColor, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.55), value: healthRingProgress)
            if heroBusy {
                ProgressView().scaleEffect(0.6)
            } else {
                VStack(spacing: -1) {
                    Text("\(healthScore)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(ClaudeTheme.ink)
                        .contentTransition(.numericText())
                    Text("分")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(ClaudeTheme.muted)
                }
            }
        }
        .frame(width: 62, height: 62)
        .accessibilityLabel("健康分 \(healthScore) 分，\(heroVerdict.text)")
    }

    /// 状态徽章:标题右边的 pill。文字直接取结论的短标签 ——
    /// 之前这里写「3 项待确认」、下面再写一句「3 项提示」,同一个数字说两遍。
    private var heroBadge: some View {
        let v = heroVerdict
        return pill(v.short, color: v.color, dot: vm.phase != .checking)
    }

    private func pill(_ text: String, color: Color, dot: Bool) -> some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(color).frame(width: 4.5, height: 4.5)
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.13)))
        .fixedSize()
    }

    /// 出口 IP 单独拎出来做 chip:这是用户最常看的一行,埋在一句话里读不快。
    /// 脚本真实输出是 `144.172.103.106/US`,夹具和旧版是 `144.172.103.106 (US)` ——
    /// 两种都得拆开,否则整个「IP (US)」会挤进 chip,把后面的正文挤折行。
    private var exitParts: (ip: String, region: String) {
        let raw = vm.rows.first { $0.name == "出口 IP" }?.detail ?? ""
        if let slash = raw.firstIndex(of: "/") {
            let ip = String(raw[raw.startIndex..<slash])
            let rest = raw[raw.index(after: slash)...]
            let region = rest.split(separator: " ").first.map(String.init) ?? ""
            return (ip, region)
        }
        if let paren = raw.firstIndex(of: "(") {
            let ip = raw[raw.startIndex..<paren].trimmingCharacters(in: .whitespaces)
            let rest = raw[raw.index(after: paren)...]
            let region = rest.split(separator: ")").first.map(String.init) ?? ""
            return (ip, region)
        }
        return (raw, "")
    }

    private var exitIP: String { exitParts.ip }
    private var exitRegion: String { exitParts.region }

    private var heroMetaRow: some View {
        let ok = vm.rows.filter { $0.state == .ok }.count
        let showCount = !heroBusy && !vm.intercepted
        let showRegion = !exitIP.isEmpty && !heroBusy && !exitRegion.isEmpty
        return HStack(spacing: 6) {
            if !exitIP.isEmpty && !heroBusy {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 8.5))
                        .foregroundColor(ClaudeTheme.muted)
                    Text(exitIP)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ClaudeTheme.iconWell))
            }
            if showRegion {
                Text(exitRegion)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(ClaudeTheme.ink)
            }
            if !heroDetail.isEmpty {
                // 只有前面接了内容时才要点。detail 为空时(已守护态)这个点
                // 会孤零零挂在行首,看着像渲染坏了。
                if showRegion || (!exitIP.isEmpty && !heroBusy) { separatorDot }
                Text(heroDetail)
                    .font(.system(size: 11))
                    .foregroundColor(ClaudeTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 通过数跟着元信息走,不甩到卡片最右边 —— 隔着一整个屏宽,
            // 读者要横跨半个窗口才能把它和 IP 关联起来。
            if showCount {
                if !heroDetail.isEmpty || showRegion { separatorDot }
                Text("\(ok)/\(vm.rows.count) 项通过")
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.9))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private var separatorDot: some View {
        Text("·").font(.system(size: 10)).foregroundColor(ClaudeTheme.muted.opacity(0.5))
    }

    private var problemCount: Int {
        vm.rows.filter { $0.state == .fail || $0.state == .config || $0.state == .warn }.count
    }

    /// 有多少项是脚本真能修的。全是手动项时不显示「一键修复」——
    /// 点了也修不了,不如不给这个按钮。
    private var fixableProblemCount: Int {
        vm.rows.filter {
            ($0.state == .fail || $0.state == .config || $0.state == .warn) && VM.fixableNames.contains($0.name)
        }.count
    }

    private var heroBusy: Bool {
        switch vm.phase {
        case .checking, .fixing, .switching: return true
        default: return false
        }
    }

    /// 标题只写「状态」,结论写「能不能用」。两者分工,不互相重复:
    /// 之前标题和徽章都写「已拦截」,同一句话说两遍。
    private var heroTitle: String {
        if vm.intercepted { return "已停止" }
        switch vm.phase {
        case .checking: return "正在检查"
        case .fixing: return "正在修复"
        case .switching: return "正在切换账号"
        case .done: return vm.banner.isEmpty ? "已切换" : vm.banner
        case .failed: return vm.coreMissing ? "未安装核心脚本" : "检查未通过"
        case .ready: return "已守护"
        }
    }

    private var heroDetail: String {
        if vm.intercepted { return interceptedReason }
        switch vm.phase {
        case .checking:
            // 结论句已经写了「正在逐项核对 N 项」,这里再来一句「正在核对 N 项
            // 环境指标」就是同一句话说两遍。检查中时元信息行留空。
            return ""
        case .fixing:
            return vm.banner.isEmpty ? "正在自动修复，若弹出密码框请输入开机密码" : vm.banner
        case .switching:
            return vm.banner.isEmpty ? "切换前会重新检查一遍环境" : vm.banner
        case .done:
            return "账号 \(vm.current) 已就绪"
        case .failed:
            if vm.coreMissing { return "请先安装 claude-switch.sh，装好后点右上角重新检查" }
            return pendingSummary()
        case .ready:
            // 出口 IP、通过数都已经拆成 chip 和右侧计数,这里再说一遍是重复。
            return ""
        }
    }

    /// 顶部只丢一个「N 项未通过」,用户还得自己数是哪几项、更不知道下一步做什么。
    /// 这里直接点名,并且把「能修几项、几项得自己动手」说清楚 —— 只说
    /// 「点一键修复」最坑:点了还剩三项红的,用户会以为按钮坏了。
    private func pendingSummary() -> String {
        let problems = vm.rows.filter { $0.state == .fail || $0.state == .config || $0.state == .warn }
        guard !problems.isEmpty else { return "Claude 不会启动" }
        let names = problems.map(\.name)
        let head = names.count <= 2
            ? names.joined(separator: "、")
            : "\(names.prefix(2).joined(separator: "、")) 共 \(names.count) 项"
        let fixable = problems.filter { VM.fixableNames.contains($0.name) }.count
        let manual = problems.count - fixable
        if manual == 0 { return "\(head) · 点「修复」即可" }
        if fixable == 0 { return "\(head) · 需要换节点或线路" }
        return "\(head) · \(fixable) 项可修，\(manual) 项换节点"
    }

    // MARK: 提示条

    private var noticeStrip: AnyView? {
        if vm.isBusy && !vm.banner.isEmpty && (vm.phase == .fixing || vm.phase == .switching) {
            return nil   // hero 已经把这句说清楚了,不重复
        }
        if !vm.fixNotice.isEmpty {
            return AnyView(
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ClaudeTheme.terracotta)
                    Text(vm.fixNotice)
                        .font(.system(size: 12))
                        .foregroundColor(ClaudeTheme.ink)
                    Spacer(minLength: 8)
                    if fixableProblemCount > 0 {
                        Button { vm.fixAll() } label: {
                            Text("再修一次")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(ClaudeTheme.terracottaDeep)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(ClaudeTheme.terracotta.opacity(0.10))
            )
        }
        return nil
    }

    /// banner 里带「已自动停止 Claude：」前缀,hero 已经说了这件事,去掉免得念两遍。
    private var interceptedReason: String {
        let prefix = "已自动停止 Claude："
        return vm.banner.hasPrefix(prefix) ? String(vm.banner.dropFirst(prefix.count)) : vm.banner
    }

    // MARK: 账号

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(ClaudeTheme.terracotta)
                    .frame(width: 5, height: 5)
                    .offset(y: -2)
                // 分区标题必须比内容更重。之前这里 11pt、行名 12.5pt ——
                // 标题比正文还小,读者找不到「这一块在讲什么」。
                Text("隔离实例槽位")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(ClaudeTheme.ink)
                Text("环境与凭据独立沙盒")
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !vm.incidents.isEmpty {
                    Button { showHistory = true } label: {
                        HStack(spacing: 3) {
                            Text("全部记录")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7.5, weight: .semibold))
                        }
                        .font(.system(size: 10.5))
                        .foregroundColor(ClaudeTheme.terracotta)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ForEach(VM.accountLetters, id: \.self) { t in
                    accountCard(t)
                }
            }

            if let inc = vm.incidents.first {
                Button { showHistory = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 9.5))
                        // 不写「最近拦截」的话,这行紧挨着「已守护」,很容易被当成
                        // 当前状态 —— 明明守护正常,却读出一句「检查未通过」。
                        Text("最近拦截").font(.system(size: 10.5, weight: .medium))
                        // 类型和原因往往重复(「检查未通过」+「运行中检查未通过:…」),
                        // 两句都留就是在同一行说两遍同一件事。原因更具体,留它。
                        Text(inc.reason.isEmpty ? inc.kind : shortReason(inc.reason))
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(shortClock(inc.time))
                            .font(.system(size: 10, design: .monospaced))
                            .fixedSize()
                    }
                    .foregroundColor(ClaudeTheme.muted.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(inc.reason.isEmpty ? "查看全部拦截记录" : "\(inc.reason)\n\n点击查看全部拦截记录")
            }
        }
    }

    /// 槽位卡:字母方块 + 状态 + 体积日期 + 一行底注。
    /// 之前是一条扁 chip,「A 1.2G · 10-20」挤在一起,看不出哪个是当前、哪个是空的。
    /// 现在是四张独立的卡 —— 有面、有投影、有悬浮抬起,不是一个白框里的四段文字。
    private func accountCard(_ t: String) -> some View {
        let isCurrent = vm.current == t
        let archived = vm.archived.contains(t)
        let hovered = hoveredAccount == t

        return Button { vm.switchTo(t) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(t)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(isCurrent ? .white : (archived ? ClaudeTheme.ink : ClaudeTheme.muted.opacity(0.55)))
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(isCurrent ? ClaudeTheme.terracotta : ClaudeTheme.slotWell)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountStateLabel(t))
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                            .foregroundColor(isCurrent ? ClaudeTheme.ink : ClaudeTheme.muted)
                            .lineLimit(1)
                        Text(accountSubtitle(t))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(ClaudeTheme.muted.opacity(archived ? 0.8 : 0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ClaudeTheme.terracotta)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: archived ? "shield.lefthalf.filled" : "plus")
                        .font(.system(size: 8.5))
                    Text(archived ? "独立指纹" : "点击绑定")
                        .font(.system(size: 10))
                }
                .foregroundColor(ClaudeTheme.muted.opacity(archived ? 0.7 : 0.5))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isCurrent ? ClaudeTheme.terracotta.opacity(0.10) : ClaudeTheme.card)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            // 没有描边,「这是一张卡」全靠投影说。当前账号给得更重一点,
            // 一眼就能从四张里挑出来。
            .shadow(color: Color.black.opacity(hovered ? 0.09 : (isCurrent ? 0.06 : 0.045)),
                    radius: hovered ? 10 : 8, x: 0, y: hovered ? 4 : 2)
            .animation(.easeOut(duration: 0.14), value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hoveredAccount = t }
                else if hoveredAccount == t { hoveredAccount = nil }
            }
        }
        .help(isCurrent ? "当前正在使用账号 \(t)" : "切换到账号 \(t)（会先重新检查一遍环境）")
    }

    func accountStateLabel(_ t: String) -> String {
        if vm.current == t { return "当前账号" }
        return vm.archived.contains(t) ? "已建档" : "未初始化"
    }

    func accountSubtitle(_ t: String) -> String {
        guard vm.archived.contains(t) else { return "空" }
        guard let stamp = vm.stamps[t] else { return "已建档" }
        return "\(stamp.size) · \(shortDate(stamp.date))"
    }

    private func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4 else { return value }
        return "\(parts[1])-\(parts[2])"
    }

    // MARK: 检查清单

    private var hardRows: [CheckRow] { vm.rows.filter { !$0.canDisable } }
    private var softRows: [CheckRow] { vm.rows.filter { $0.canDisable } }

    private func checkCard(_ title: String, subtitle: String, symbol: String,
                           rows: [CheckRow]) -> some View {
        let checking = rows.contains(where: { vm.rechecking.contains($0.name) })
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                // 头:图标、标题、副标题、计数。四样东西挤在一行,靠「谁粗谁细」
                // 分层,不靠色块 —— 之前图标有底、计数有胶囊,一行两个方块,
                // 加上左右各一列边框感,卡头比内容还热闹。
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(cardAccent(rows))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(cardAccent(rows).opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ClaudeTheme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundColor(ClaudeTheme.muted.opacity(0.72))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 计数用「点 + 文字」而不是胶囊。胶囊是给需要被点、被注意的
                    // 东西用的,这里只是个数字。
                    HStack(spacing: 5) {
                        Circle()
                            .fill(countColor(rows))
                            .frame(width: 5, height: 5)
                        Text(countText(rows))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(countColor(rows))
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, checking ? 9 : 11)

                // 检查进度。整轮要两三秒,没有进度感的话用户只看到一堆行在闪。
                // 只在核对时出现,平时不占位 —— 一条常驻的细线会被读成分隔线。
                if checking {
                    checkProgress(rows)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 9)
                        .transition(.opacity)
                }

                if vm.coreMissing {
                    setupPanel
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            checkRow(row, index: idx)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            // 两列行数不同,底边就会错开一截,看着像没对齐。撑到等高让下沿齐平。
            // 量高探针里不能撑 —— 那里没有确定的父高度,撑成无穷大会量出天文数字。
            .frame(maxHeight: measureOnly ? nil : .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: checking)
    }

    /// 一条 3pt 的进度线。宽度跟着「已落定的行数」走,和逐行落定是同一个节拍 ——
    /// 两处对不上(条子走完了行还在转)会让人以为卡住了。
    private func checkProgress(_ rows: [CheckRow]) -> some View {
        let total = max(rows.count, 1)
        let done = rows.filter { !vm.rechecking.contains($0.name) }.count
        let ratio = Double(done) / Double(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ClaudeTheme.iconWell)
                Capsule()
                    .fill(cardAccent(rows).opacity(0.8))
                    .frame(width: max(4, geo.size.width * ratio))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.3), value: ratio)
        .accessibilityLabel("检查进度 \(done)/\(total)")
    }

    /// 卡片头的图标底色跟着这一组的状态走:全绿就是绿,有红就红。
    private func cardAccent(_ rows: [CheckRow]) -> Color {
        let bad = rows.filter { $0.state == .fail || $0.state == .config }.count
        if bad > 0 { return ClaudeTheme.error }
        let warn = rows.filter { $0.state == .warn }.count
        if warn > 0 { return ClaudeTheme.warning }
        return ClaudeTheme.success
    }

    private func countText(_ rows: [CheckRow]) -> String {
        // 重查期间这一列的数字是上一轮的,不能当成结论显示;但光写「核对中」
        // 又浪费了「到底核到第几项」这个信息,干脆显示已落定/总数。
        let pending = rows.filter { vm.rechecking.contains($0.name) }.count
        if pending > 0 { return "\(rows.count - pending)/\(rows.count)" }
        let bad = rows.filter { $0.state == .fail || $0.state == .config }.count
        let warn = rows.filter { $0.state == .warn }.count
        let ok = rows.filter { $0.state == .ok }.count
        let waiting = rows.filter { $0.state == .pending }.count
        if waiting > 0 { return "\(waiting) 项检查中" }
        if bad > 0 { return "\(bad) 项未通过" }
        if warn > 0 { return "\(warn) 项提示" }
        return "\(ok) 项通过"
    }

    private func countColor(_ rows: [CheckRow]) -> Color {
        if rows.contains(where: { vm.rechecking.contains($0.name) }) { return ClaudeTheme.muted }
        let bad = rows.filter { $0.state == .fail || $0.state == .config }.count
        if bad > 0 { return ClaudeTheme.error }
        let warn = rows.filter { $0.state == .warn }.count
        if warn > 0 { return ClaudeTheme.warning }
        return ClaudeTheme.muted
    }

    private func checkRow(_ row: CheckRow, index: Int = 0) -> some View {
        let isProblem = row.state == .fail || row.state == .config
        // 提示项(warn)也算「要你动手」:时区不对、DNS 没走隧道都能一键修。
        let needsAttention = isProblem || row.state == .warn
        let fix = vm.fixStates[row.name]
        // 修复回执里的附注:失败时是「为什么改不了」,成功时是「改完还要做什么」。
        // 用户点了修复之后,这一句是他唯一想看的第二句话。
        let fixNote = fix?.note ?? ""
        let fixFailed = fix?.isFailed ?? false
        // 「保镖在线」的 detail 只有「待命」两个字时,单看像「还没上岗」。
        // 实际含义是「launchd 守护在线、还没拦过任何东西」—— 补上「在线」,
        // 免得和上面那条「运行期看门狗驻守中」看起来互相矛盾。
        let value = (row.name == "保镖在线" && row.detail == "待命")
            ? "在线 · 待命"
            : (row.detail.isEmpty ? stateWord(row.state) : row.detail)
        let tint = iconTint(row.state)
        // 行尾一行放不下就截断,而截掉的往往正好是结论 —— 「api:401 · ap…」
        // 后面到底是哪个域挂了、首包多少毫秒,全没了。超过 24 字的详情改放
        // 第二行:宁可这一行高一点,也不能把检查结果吞掉。
        let detailNeedsOwnLine = !row.detail.isEmpty && (needsAttention || row.detail.count > 24)
        // 重查中的行不清空旧值,只在行尾挂个小转圈。用户能看到「这一项正在核对」,
        // 而不用面对一整屏突然变灰。
        let isRechecking = vm.rechecking.contains(row.name)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Image(systemName: row.icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(tint)
                    .frame(width: 17, alignment: .leading)

                Text(row.name)
                    .font(.system(size: 12.5, weight: isProblem ? .medium : .regular))
                    .foregroundColor(ClaudeTheme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                if !needsAttention && !detailNeedsOwnLine && row.state != .pending && !isRechecking {
                    Text(value)
                        .font(.system(size: 11.5, design: isMonospace(value) ? .monospaced : .default))
                        // 通过项的值再压一档。「通过」重复八遍、颜色和真结果一样重,
                        // 整列读起来全是噪声,反而看不出哪一行有信息。
                        .foregroundColor(ClaudeTheme.muted.opacity(row.state == .ok ? 0.62 : 1))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.detail)
                }

                if row.state == .pending || isRechecking {
                    // 自己画的弧,不用系统 ProgressView:那个小菊花在浅色卡上
                    // 是一团灰糊,和整屏的圆角/细线语言也不搭。
                    SpinRing(size: 12, lineWidth: 1.5, duration: 0.9)
                        .transition(.opacity)
                } else if let fix {
                    fixChip(fix)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if needsAttention && VM.fixableNames.contains(row.name) && !vm.isBusy {
                    FixActionButton(label: "修复", quiet: true) { vm.fixAll(focus: row.name) }
                        .help("修复这一项（脚本会一并处理其他可自动修复的项）")
                }

                // 生态探测这一行是「24h 延迟洞察」的入口 —— 数据就是它测出来的,
                // 放在这里比塞进工具栏更好找。
                if row.name == "生态可达性" && !vm.isBusy && row.state != .pending {
                    Button { showLatency = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 8.5, weight: .medium))
                            Text("24h")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundColor(ClaudeTheme.terracotta)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(ClaudeTheme.terracotta.opacity(0.09)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("查看 24 小时延迟历史")
                }
            }

            // 修复回执优先。修失败了,这一行的第二句必须是「为什么没修好」,
            // 而不是原来那句检查详情 —— 用户刚点完修复,关心的是结果。
            if !fixNote.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: fixFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(fixFailed ? ClaudeTheme.error : ClaudeTheme.success)
                        .padding(.top, 1.5)
                    Text(fixNote)
                        .font(.system(size: 11))
                        .foregroundColor(fixFailed ? ClaudeTheme.error : ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(fixFailed ? "脚本没能自动修好这一项：\(fixNote)" : fixNote)
                }
                .padding(.leading, 26)
                .transition(.opacity)
            } else if detailNeedsOwnLine {
                // 要动手的行把原因放到第二行整行铺开。一行放不下「当前 A,期望 B」,
                // 中间截断切掉的正好是最要紧的那半句。
                Text(row.detail)
                    .font(.system(size: 11, design: isMonospace(row.detail) ? .monospaced : .default))
                    .foregroundColor(ClaudeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        // 只有悬浮才铺底色。之前给「要处理」的行铺一层淡色,结果同一张卡里
        // 两行有色、四行没色,看着像两个被选中的行,清单反而不像清单。
        // 「要处理」已经有三个信号了:图标着色、第二行原因、行尾修复按钮。
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hoveredRow == row.name ? ClaudeTheme.iconWell.opacity(0.75) : Color.clear)
        )
        // 逐行落定,而不是整组一起跳。检查输出是一行行回来的,给每行按顺序
        // 错开十几毫秒,眼睛能跟上「现在核到哪一项」;错开量封顶 96ms,
        // 再多就变成拖沓。
        .animation(.easeOut(duration: 0.2).delay(Double(min(index, 8)) * 0.012), value: row.state)
        .animation(.easeOut(duration: 0.16), value: isRechecking)
        .animation(.easeOut(duration: 0.16), value: row.detail)
        .onHover { inside in
            // 鼠标划过去要有一点反应,否则整张清单像一张不可点的表。
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hoveredRow = row.name }
                else if hoveredRow == row.name { hoveredRow = nil }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)，\(stateWord(row.state))，\(row.detail)")
    }

    /// 通过项用中性灰,只有要处理的行才着色 —— 14 行全彩等于没有重点。
    private func iconTint(_ s: RowState) -> Color {
        switch s {
        case .ok: return ClaudeTheme.muted.opacity(0.7)
        case .warn: return ClaudeTheme.warning
        case .fail: return ClaudeTheme.error
        case .config: return ClaudeTheme.terracotta
        case .pending, .skip: return ClaudeTheme.muted.opacity(0.5)
        }
    }

    /// 状态必须有文字形态:只靠颜色区分,色弱用户和灰度截图都读不出来。
    private func stateWord(_ s: RowState) -> String {
        switch s {
        case .ok: return "通过"
        case .warn: return "提示"
        case .fail: return "未通过"
        case .config: return "待配置"
        case .skip: return "已跳过"
        case .pending: return "检查中"
        }
    }

    /// 修复回执的「徽章」。文字 + 一个小符号,不用底色胶囊 ——
    /// 一行里已经有值、按钮、详情,再加一个色块就太吵了。
    private func fixChip(_ state: FixState) -> some View {
        let (text, color, symbol): (String, Color, String) = {
            switch state {
            case .running: return ("修复中", ClaudeTheme.muted, "")
            case .done: return ("已修复", ClaudeTheme.success, "checkmark")
            case .failed: return ("需手动", ClaudeTheme.error, "exclamationmark")
            }
        }()
        return HStack(spacing: 3) {
            if case .running = state {
                SpinRing(size: 10, lineWidth: 1.4, duration: 0.9)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .fixedSize()
    }

    private var setupPanel: some View {
        VStack(spacing: 10) {
            Text("还没有安装核心脚本")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ClaudeTheme.ink)
            Text(vm.banner)
                .font(.system(size: 11.5))
                .foregroundColor(ClaudeTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    openInBrowser("https://github.com/huanfine/claude-switcher")
                } label: {
                    Text("打开项目主页")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(ClaudeTheme.terracotta))
                }
                .buttonStyle(.plain)
                Button {
                    openInBrowser("https://github.com/huanfine/claude-switcher#安装")
                } label: {
                    Text("安装说明")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(ClaudeTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(ClaudeTheme.iconWell))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private func isMonospace(_ str: String) -> Bool {
        str.contains(".") || str.contains(":") || str.contains("/")
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            // 代理客户端是全局设置,放底栏而不是主区 —— 主区留给「现在什么状态」。
            // 用 Menu 而不是 Picker:Picker 自带一圈系统边框,套不进自定义胶囊,
            // 会出现「框里套框」。
            Menu {
                ForEach(VM.clientChoices, id: \.key) { choice in
                    Button(choice.label) { vm.setClient(choice.key) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 9.5))
                        .foregroundColor(ClaudeTheme.terracotta)
                    Text(clientLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ClaudeTheme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 6.5, weight: .semibold))
                        .foregroundColor(ClaudeTheme.muted.opacity(0.7))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ClaudeTheme.slotWell))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(vm.isBusy || vm.isSwitchingClient)
            .help("选择代理客户端")

            if vm.isSwitchingClient {
                ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
            }

            HStack(spacing: 4) {
                Circle().fill(footerStatusColor).frame(width: 4.5, height: 4.5)
                Text(footerStatusText)
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted)
                    .lineLimit(1)
            }

            // 检查中时状态点后面写「检查中」,这里再挂一个「· 检查中」就是
            // 一行里说两遍同一件事。内容一样就不画。
            if vm.lastCheckSummary != "尚未检查" && vm.lastCheckSummary != footerStatusText {
                Text("· \(vm.lastCheckSummary)")
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            GhostTextButton(label: "检查更新") {
                vm.checkUpdate()
                vm.showUpdateSheet = true
            }
            GhostTextButton(label: "AI 配置") { showAIPrompt = true }
            GhostTextButton(label: "诊断") { vm.showSettingsSheet = true }
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 16)
        .sheet(isPresented: $vm.showUpdateSheet) { UpdateSheet(vm: vm) }
    }

    private var clientLabel: String {
        if vm.currentClient.isEmpty { return "未识别" }
        return VM.clientChoices.first { $0.key == vm.currentClient }?.label ?? vm.currentClient
    }

    private var footerStatusColor: Color {
        if vm.isBusy { return ClaudeTheme.warning }
        if vm.intercepted { return ClaudeTheme.error }
        return vm.phase == .failed ? ClaudeTheme.error : ClaudeTheme.success
    }

    private var footerStatusText: String {
        if vm.isBusy { return "检查中" }
        if vm.intercepted { return "已拦截" }
        return vm.phase == .failed ? "未通过" : "已就绪"
    }

    /// 2026-11-02 12:20:43 → 11-02 12:20
    private func shortClock(_ value: String) -> String {
        let halves = value.split(separator: " ")
        guard halves.count == 2 else { return value }
        let date = halves[0].split(separator: "-")
        let time = halves[1].split(separator: ":")
        guard date.count == 3, time.count >= 2 else { return value }
        return "\(date[1])-\(date[2]) \(time[0]):\(time[1])"
    }

    /// 拦截原因掐到一行读得完的长度。原文是十几项检查拼起来的一句话,
    /// 动辄两三百字,原样铺开就成了满屏跑马灯。
    private func shortReason(_ value: String) -> String {
        let flat = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > 30 else { return flat }
        return String(flat.prefix(30)) + "…"
    }
}

/// 拦截历史。只读 —— 写是脚本的事,界面不该有能力改审计记录。
struct IncidentHistorySheet: View {
    @ObservedObject var vm: VM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拦截记录")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(ClaudeTheme.ink)
                        Text("看门狗真的动手停过 Claude 的事件，最多保留 50 条")
                            .font(.system(size: 10.5))
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                if vm.incidents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 22))
                            .foregroundColor(ClaudeTheme.success.opacity(0.6))
                        Text("还没有拦截记录")
                            .font(.system(size: 12))
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.incidents) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.kind)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(ClaudeTheme.error)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(ClaudeTheme.error.opacity(0.10)))
                                        .fixedSize()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.reason)
                                            .font(.system(size: 11.5))
                                            .foregroundColor(ClaudeTheme.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        Text(item.time)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(ClaudeTheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(ClaudeTheme.iconWell)
                                )
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
    }
}

// MARK: - 检查设置与诊断

struct CheckSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("检查设置").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("安全项始终强制执行；跳过不等于通过").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("降级防护（不推荐）") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(VM.optionalChecks, id: \.key) { item in
                                    HStack(spacing: 8) {
                                        Toggle(item.label, isOn: Binding(
                                            get: { !vm.disabledChecks.contains(item.key) },
                                            set: { enabled in
                                                if enabled { vm.disabledChecks.remove(item.key) }
                                                else { vm.disabledChecks.insert(item.key) }
                                            }
                                        ))
                                        if vm.disabledChecks.contains(item.key) {
                                            Text("已关闭 · 不再拦截启动")
                                                .font(.caption2)
                                                .foregroundColor(ClaudeTheme.warning)
                                        }
                                    }
                                }
                                Text("默认 14 项全部拦截启动。这里关掉的项会真正跳过探测，并以灰色「已跳过」显示 —— 那不叫通过，叫放弃验证。只在本机环境确实造成误报时才关。出口国家、代理/TUN、Kill-Switch、保镖、账号归档和更新校验不可关闭。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("失败处理与日志") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("把上述 6 项的失败降为警告", isOn: $vm.allowOptionalFailures)
                                Text("降级后这些项仍然会跑、仍然会报，只是不再拦住启动。只影响这 6 项；不会放宽任何硬性安全项，也不会自动关闭检测。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
                                Text("仅记录版本、命令、退出码、耗时和检查状态，不记录 IP、凭据或账号内容。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("问题排查") {
                            VStack(alignment: .leading, spacing: 9) {
                                Button("导出脱敏诊断日志…") { vm.exportDiagnostics() }
                                    .disabled(vm.settingsBusy)
                                Text("日志：~/Library/Logs/claude-switcher/client.log")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted).textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if !vm.settingsMessage.isEmpty {
                    Text(vm.settingsMessage).font(.caption).foregroundColor(ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("恢复默认") { vm.restoreCheckDefaults() }.disabled(vm.settingsBusy)
                    Spacer()
                    if vm.settingsBusy { ProgressView().scaleEffect(0.65) }
                    Button("保存并重新检查") { vm.saveCheckConfig() }
                        .buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
                        .disabled(vm.settingsBusy || vm.isBusy)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 610)
        .onAppear { vm.loadCheckConfig() }
    }
}

// MARK: - 设备指纹体检

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备指纹体检").font(.headline).foregroundColor(ClaudeTheme.ink)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(.caption).foregroundColor(ClaudeTheme.muted)
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(ClaudeTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .background(ClaudeTheme.bgTop)
    }
}

// MARK: - 版本更新

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("版本更新").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("只检查，不写入任何文件").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClaudeTheme.iconWell))

                HStack(spacing: 10) {
                    Button { vm.checkUpdate() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { copyUpdateCommand() } label: {
                        Label(copied ? "已复制" : "复制更新命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Text("复制后到终端执行即可更新；更新前会做 SHA256 校验，自检不通过会自动回滚。")
                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .padding(20)
        }
        .frame(width: 520, height: 300)
    }

    private func copyUpdateCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString("~/.local/bin/claude-switch.sh update", forType: .string)
        copied = true
    }
}

// MARK: - AI 交接提示词

struct AIPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 交接提示词").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClaudeTheme.iconWell))

                HStack {
                    Button { copyPrompt() } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(ClaudeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(ClaudeTheme.terracottaDeep)
                                Text(s.1).font(.caption).foregroundColor(ClaudeTheme.muted).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ClaudeTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(ClaudeTheme.muted)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
    }
}

// MARK: - 24 小时延迟洞察

/// 数据全部来自脚本每次 `check` 落盘的一条采样(`~/.claude-switcher/rtt.log`)。
/// 界面不生成任何数字 —— 没有采样就显示「还没有采样」,绝不画一条假曲线。
/// 一个门禁工具里,编出来的「峰值 870ms」比空白危险得多。
struct LatencyInsightSheet: View {
    @ObservedObject var vm: VM
    @Environment(\.dismiss) private var dismiss

    @State private var hours: Double = 24
    @State private var exportNote = ""

    private var samples: [RTTSample] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return vm.rttSamples.filter { $0.at > cutoff }
    }
    private var okCount: Int { samples.filter { $0.ok }.count }
    private var avgMS: Int {
        let v = samples.map(\.ms).filter { $0 > 0 }
        guard !v.isEmpty else { return 0 }
        return v.reduce(0, +) / v.count
    }
    private var peak: RTTSample? {
        samples.filter { $0.ms > 0 }.max { $0.ms < $1.ms }
    }
    private var availability: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(okCount) / Double(samples.count)
    }

    private let ranges: [(String, Double)] = [
        ("近 1 小时", 1), ("近 6 小时", 6), ("24 小时", 24), ("7 天", 168),
    ]

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statRow
                        chartCard
                        endpointRow
                        incidentCard
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                }
                footer
            }
        }
        .frame(width: 880, height: 660)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ClaudeTheme.terracotta)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ClaudeTheme.terracotta.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Anthropic 生态探测 · 延迟历史")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ClaudeTheme.ink)
                    HStack(spacing: 4) {
                        Circle().fill(samples.isEmpty ? ClaudeTheme.muted : ClaudeTheme.success)
                            .frame(width: 4.5, height: 4.5)
                        Text(samples.isEmpty ? "等待采样" : "监测中")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(samples.isEmpty ? ClaudeTheme.muted : ClaudeTheme.success)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((samples.isEmpty ? ClaudeTheme.muted : ClaudeTheme.success).opacity(0.10)))
                }
                Text("每次环境检查都会记一条 api 首包耗时，按时间回放")
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(ranges, id: \.1) { label, h in
                    Button { hours = h } label: {
                        Text(label)
                            .font(.system(size: 10.5, weight: hours == h ? .semibold : .regular))
                            .foregroundColor(hours == h ? ClaudeTheme.ink : ClaudeTheme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(hours == h ? ClaudeTheme.card : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ClaudeTheme.iconWell))

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ClaudeTheme.muted)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ClaudeTheme.iconWell))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: 四个指标

    private var statRow: some View {
        HStack(spacing: 10) {
            statTile("平均首包", avgMS > 0 ? "\(avgMS)" : "—", unit: "ms",
                     note: samples.isEmpty ? "暂无采样" : "\(samples.count) 个采样点",
                     tint: ClaudeTheme.terracotta, symbol: "bolt.fill")
            statTile("可用率", samples.isEmpty ? "—" : String(format: "%.1f", availability * 100), unit: "%",
                     note: samples.isEmpty ? "暂无采样" : "\(okCount)/\(samples.count) 次双端可达",
                     tint: ClaudeTheme.success, symbol: "checkmark.circle.fill")
            statTile("峰值延迟", peak.map { "\($0.ms)" } ?? "—", unit: "ms",
                     note: peak.map { clockText($0.at) } ?? "暂无采样",
                     tint: ClaudeTheme.warning, symbol: "exclamationmark.triangle.fill")
            statTile("累计拦截", "\(vm.incidents.count)", unit: "次",
                     note: vm.incidents.isEmpty ? "无记录" : "看门狗实际动手过",
                     tint: ClaudeTheme.error, symbol: "shield.lefthalf.filled")
        }
    }

    private func statTile(_ title: String, _ value: String, unit: String,
                          note: String, tint: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.system(size: 8.5))
                    .foregroundColor(tint.opacity(0.85))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(ClaudeTheme.ink)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text(note)
                .font(.system(size: 9.5))
                .foregroundColor(ClaudeTheme.muted.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(ClaudeTheme.card))
        .shadow(color: Color.black.opacity(0.05), radius: 9, x: 0, y: 2)
    }

    // MARK: 曲线

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(ClaudeTheme.terracotta).frame(width: 5, height: 5)
                Text("端到端首包耗时")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(ClaudeTheme.ink)
                Text("· 采样 \(samples.count) 个")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.8))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(ClaudeTheme.terracotta).frame(width: 12, height: 2)
                    Text("api 首包").font(.system(size: 9.5)).foregroundColor(ClaudeTheme.muted)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(ClaudeTheme.warning.opacity(0.5)).frame(width: 12, height: 1.5)
                    Text("500ms 警戒").font(.system(size: 9.5)).foregroundColor(ClaudeTheme.muted)
                }
            }

            RTTChart(samples: samples, hours: hours)
                .frame(height: 150)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(ClaudeTheme.card))
        .shadow(color: Color.black.opacity(0.05), radius: 9, x: 0, y: 2)
    }

    // MARK: 端点

    private var endpointRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("端点可用性")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(ClaudeTheme.ink)
                Spacer(minLength: 8)
                // 只有脚本真的探过这两个域,不凑数。cdn / statsig 没探就不显示。
                Text("仅统计脚本实际探测的端点")
                    .font(.system(size: 9.5))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.75))
            }
            HStack(spacing: 10) {
                endpointTile("claude.ai", code: samples.last?.claudeCode ?? "—",
                             latency: nil, symbol: "lock.fill")
                endpointTile("api.anthropic.com", code: samples.last?.apiCode ?? "—",
                             latency: avgMS > 0 ? avgMS : nil, symbol: "bolt.fill")
            }
        }
    }

    private func endpointTile(_ host: String, code: String, latency: Int?, symbol: String) -> some View {
        let good = code.hasPrefix("2") || code.hasPrefix("4")
        let tint: Color = good ? ClaudeTheme.success : ClaudeTheme.error
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundColor(ClaudeTheme.muted)
            Text(host)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(ClaudeTheme.ink)
            Spacer(minLength: 6)
            if let latency {
                Text("\(latency)ms")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text(code)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(tint.opacity(0.10)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClaudeTheme.iconWell))
    }

    // MARK: 事件

    private var incidentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9.5))
                    .foregroundColor(ClaudeTheme.muted)
                Text("关键事件")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(ClaudeTheme.ink)
                Spacer(minLength: 8)
                Text("共 \(vm.incidents.count) 条")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.8))
            }
            if vm.incidents.isEmpty {
                Text("还没有拦截记录。看门狗没有动过手，就是最好的状态。")
                    .font(.system(size: 10.5))
                    .foregroundColor(ClaudeTheme.muted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.incidents.prefix(4)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(ClaudeTheme.error.opacity(0.8))
                                .frame(width: 5, height: 5)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.kind)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(ClaudeTheme.ink)
                                Text(item.reason)
                                    .font(.system(size: 10))
                                    .foregroundColor(ClaudeTheme.muted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(clockText(item.time))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(ClaudeTheme.muted.opacity(0.75))
                                .fixedSize()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(ClaudeTheme.iconWell.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            Button { exportJSON() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 9.5))
                    Text("导出 JSON").font(.system(size: 10.5, weight: .medium))
                }
                .foregroundColor(ClaudeTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ClaudeTheme.iconWell))
            }
            .buttonStyle(.plain)
            .disabled(samples.isEmpty)

            if !exportNote.isEmpty {
                Text(exportNote)
                    .font(.system(size: 9.5))
                    .foregroundColor(ClaudeTheme.success)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Text("采样由 claude-switch.sh check 落盘，界面只读")
                .font(.system(size: 9.5))
                .foregroundColor(ClaudeTheme.muted.opacity(0.7))
            Button { dismiss() } label: {
                Text("完成")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(ClaudeTheme.terracotta))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        // 底栏不用一条顶边线分区。改成一块更浅的实面,靠色差把「工具区」
        // 和上面的内容分开 —— 一条 1pt 的横线在这屏里像表格的分隔栏。
        .background(ClaudeTheme.iconWell.opacity(0.55))
    }

    private func exportJSON() {
        let rows = samples.map { s in
            "{\"t\":\"\(ISO8601DateFormatter().string(from: s.at))\",\"ms\":\(s.ms),\"claude\":\"\(s.claudeCode)\",\"api\":\"\(s.apiCode)\"}"
        }.joined(separator: ",\n  ")
        let json = "{\n  \"rangeHours\": \(Int(hours)),\n  \"samples\": [\n  \(rows)\n  ]\n}\n"
        let name = "claude-rtt-\(Int(Date().timeIntervalSince1970)).json"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(name)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            exportNote = "已导出到桌面"
        } catch {
            exportNote = "导出失败"
        }
    }

    private func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        // 必须钉 locale:跟随系统时 HH 会被改写成 12 小时制,出现「1:06 PM」,
        // 和界面其它地方的 24 小时时间对不上。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// incidents 里的时间是字符串,原样截断成「MM-dd HH:mm」。
    private func clockText(_ raw: String) -> String {
        let halves = raw.split(separator: " ")
        guard halves.count == 2 else { return raw }
        let d = halves[0].split(separator: "-")
        let t = halves[1].split(separator: ":")
        guard d.count == 3, t.count >= 2 else { return raw }
        return "\(d[1])-\(d[2]) \(t[0]):\(t[1])"
    }
}

/// 折线图。没有采样时不留白框,直接说「还没有采样」——
/// 一条平的假线比空状态更容易被误读成「网络很好」。
private struct RTTChart: View {
    let samples: [RTTSample]
    let hours: Double

    var body: some View {
        GeometryReader { geo in
            if samples.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 18))
                        .foregroundColor(ClaudeTheme.muted.opacity(0.5))
                    Text("还没有采样数据")
                        .font(.system(size: 10.5))
                        .foregroundColor(ClaudeTheme.muted)
                    Text("每次「重新检查」会记一条，多跑几次就有曲线了")
                        .font(.system(size: 9.5))
                        .foregroundColor(ClaudeTheme.muted.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ClaudeTheme.iconWell.opacity(0.45)))
            } else {
                chart(in: geo.size)
            }
        }
    }

    private func chart(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let now = Date()
        let span = hours * 3600
        let start = now.addingTimeInterval(-span)
        let peakMS = samples.map(\.ms).max() ?? 0
        let topMS = max(600, Int(Double(peakMS) * 1.15))

        func px(_ d: Date) -> CGFloat {
            let r = d.timeIntervalSince(start) / span
            return CGFloat(min(max(r, 0), 1)) * w
        }
        func py(_ ms: Int) -> CGFloat {
            h - CGFloat(Double(ms) / Double(topMS)) * h
        }

        let pts = samples.map { CGPoint(x: px($0.at), y: py($0.ms)) }
        var line = Path()
        if let first = pts.first {
            line.move(to: first)
            for p in pts.dropFirst() { line.addLine(to: p) }
        }
        var area = line
        if let first = pts.first, let last = pts.last {
            area.addLine(to: CGPoint(x: last.x, y: h))
            area.addLine(to: CGPoint(x: first.x, y: h))
            area.closeSubpath()
        }

        return ZStack(alignment: .topLeading) {
            // 网格
            ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * f))
                    p.addLine(to: CGPoint(x: w, y: h * f))
                }
                .stroke(ClaudeTheme.cardBorder.opacity(0.45), lineWidth: 0.6)
            }
            // 500ms 警戒线
            if topMS > 500 {
                let y = py(500)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(ClaudeTheme.warning.opacity(0.45), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            }

            area.fill(LinearGradient(colors: [ClaudeTheme.terracotta.opacity(0.20),
                                              ClaudeTheme.terracotta.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
            line.stroke(ClaudeTheme.terracotta, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

            if let last = pts.last {
                Circle()
                    .fill(ClaudeTheme.terracotta)
                    .frame(width: 5, height: 5)
                    .position(last)
            }

            // 右侧刻度。用 verbatim:Text 的字符串插值会走本地化数字格式,
            // 四位数会被加上千分位,显示成「1,680ms」。
            VStack {
                Text(verbatim: "\(topMS)ms").font(.system(size: 8.5, design: .monospaced))                    .foregroundColor(ClaudeTheme.muted.opacity(0.6))
                Spacer()
                Text("0").font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(ClaudeTheme.iconWell.opacity(0.5)))
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let vm: VM
    private(set) var mainWindow: NSWindow?
    /// 用户亲手拖过窗口之后,就不再按内容自动调高度。
    private var userResizedWindow = false
    /// 区分「程序自己 setFrame」和「人手拖」。
    private var isFitting = false
    private var heightObserver: AnyCancellable?

    override init() {
        vm = VM()
        super.init()
    }

    // 隔离测试可注入假核心脚本，不需要修改 HOME 或接触真实账号。
    init(vm: VM) {
        self.vm = vm
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        vm.onSwitchCompleted = { [weak self] in self?.mainWindow?.orderOut(nil) }
        showMainWindow()
        vm.start()
        // 检查结果一变,内容高度就变,窗口跟着收放。debounce 是因为一次检查
        // 会连发十几个 objectWillChange,每次都重量等于白烧 CPU。
        heightObserver = vm.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                // 280ms 是为了等 phase 切换的 0.22s 动画走完再量。量早了拿到的是
                // 动画中间态,窗口会比内容矮一截,底部就被裁掉。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { self?.fitWindowToContent() }
            }
    }

    func showMainWindow() {
        vm.prepareToShow()
        if mainWindow == nil {
            // .resizable 是必须的:之前按内容算高度把缩放整个关掉了,窗口一旦
            // 被系统压小就再也拉不回来,用户只能看着检查清单被裁。
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0,
                                    width: ContentView.width,
                                    height: min(ContentView.height, visible.height - 80)),
                styleMask: style,
                backing: .buffered, defer: false
            )
            window.title = "Claude切换器"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 860, height: 560)
            window.contentView = NSHostingView(rootView: ContentView(vm: vm))
            window.delegate = self
            window.center()
            mainWindow = window
            // 这里不量高。此刻还没开始检查,14 行全是空的,量出来只有 507pt,
            // 窗口一缩就再也长不回来 —— 整轮检查都裁在底边外面。
            // 交给检查落定后的观察者调。
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 用一个不显示的探针视图量内容的自然高度,再改窗口。
    /// 不走 SwiftUI 的 GeometryReader + PreferenceKey:那条路在 ScrollView
    /// 里量出来的永远是 0(背景层的几何信息不会回流成偏好值),试过,没用。
    func fitWindowToContent() {
        guard let window = mainWindow, !userResizedWindow else { return }
        let width = window.frame.width
        let probe = NSHostingView(rootView: ContentView(vm: vm, measureOnly: true, measureWidth: width))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        probe.layoutSubtreeIfNeeded()
        let ideal = probe.fittingSize.height
        guard ideal > 200 else { return }

        let screen = window.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 900
        let target = min(max(ideal, window.minSize.height), visibleHeight - 40)
        let current = window.frame.height
        // 检查/修复/切换过程中只许往大调,不许缩。首轮检查的内容是一行行
        // 长出来的,这时按「眼下就这么点」把窗口缩了,整轮检查都会裁在底边
        // 外面(实测缩到 507pt,下面两行直接看不见)。等落定后再精确对齐一次。
        if vm.isBusy && target < current - 1 { return }
        guard abs(current - target) > 1 else { return }
        isFitting = true
        var frame = window.frame
        frame.origin.y -= (target - current)   // AppKit 原点在左下角,不然窗口从底部往上缩
        frame.size.height = target
        // 变高时窗口是「向上长」的,原来贴着屏幕顶就会长到屏幕外面去 ——
        // 表现是标题栏和红绿灯被切掉一半,而且怎么拖都回不来。长出界就整体下移。
        if let vf = screen?.visibleFrame {
            if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.height }
            if frame.minY < vf.minY { frame.origin.y = vf.minY }
        }
        // 动画而不是瞬移:首轮检查结束时窗口要从 660 收到实际高度,
        // 直接跳会像闪了一下,补间 0.2s 读起来是「收拢」而不是「跳变」。
        window.setFrame(frame, display: true, animate: true)
        isFitting = false
    }

    /// 只认「人手拖的」。程序自己 setFrame 也会走到这里,用 inLiveResize 区分。
    /// 用户亲手调过之后就不再自动改高度 —— 他刚拉大,内容一变又被弹回去,很烦。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if sender.inLiveResize && !isFitting { userResizedWindow = true }
        return frameSize
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm.canQuit ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // App 关了但 watch 还在跑,是最坏的组合:它照样会杀 Claude,而用户
        // 看不到任何原因。退出时必须把守护一起收掉。
        vm.stopWatch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }
}

struct MenuBarContent: View {
    @ObservedObject var vm: VM
    let showWindow: () -> Void

    var body: some View {
        Text("Claude 切换器")
        Text("当前账号：\(vm.current)")
        if vm.intercepted {
            // 拦截后「最近检查：通过」是事实,但完全不是用户现在该看的东西。
            Text(vm.banner).foregroundStyle(.red)
        } else {
            Text("最近检查：\(vm.lastCheckSummary)")
        }
        // 菜单栏是窗口关着时唯一能瞄一眼的地方,给一行历史,别让人非得开窗口。
        if let latest = vm.incidents.first {
            Text("最近拦截：\(latest.time) · \(latest.kind)")
        }
        if vm.phase == .fixing { Text("正在修复…") }
        if vm.phase == .switching { Text("正在切换账号…") }
        Divider()
        Button("打开主窗口", action: showWindow)
            .keyboardShortcut("o")
        Button("重新检查") {
            showWindow()
            vm.refresh()
        }
        .disabled(vm.isBusy)
        Button("检查更新") {
            showWindow()
            vm.checkUpdate()
            vm.showUpdateSheet = true
        }
        Button("检查设置") {
            showWindow()
            vm.showSettingsSheet = true
        }
        Button("导出诊断日志") { vm.exportDiagnostics() }
            .disabled(vm.settingsBusy)
        Divider()
        Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(!vm.canQuit)
            .onAppear { vm.refreshAccountStatus() }
    }
}

// 生产应用与 UI 测试共用完全相同的菜单和窗口管理。
struct SwitcherMenu: Scene {
    @ObservedObject var vm: VM
    let controller: AppDelegate

    private static let normalImage: NSImage = {
        let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Claude 切换器")!
        image.isTemplate = true
        return image
    }()

    /// 被拦截时换图标。菜单栏图标是唯一一直可见的东西 —— 窗口关着的时候,
    /// 它是用户唯一能察觉「出事了」的入口。
    private static let blockedImage: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.shield.fill", accessibilityDescription: "已拦截")!
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(vm: vm, showWindow: controller.showMainWindow)
        } label: {
            Image(nsImage: vm.intercepted ? Self.blockedImage : Self.normalImage)
                .accessibilityLabel(vm.intercepted ? "Claude 切换器：已拦截" : "Claude 切换器")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(!vm.canQuit)
            }
        }
    }
}

#if !CLAUDE_SWITCHER_TESTS
@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
    }
}
#endif
