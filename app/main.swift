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
    /// 脚本跑完了,但这一项**没法验证** —— 不是没修成,也不是修好了。
    /// 实测来源:节点没有 IPv4 出口时,WebRTC 的 STUN 探针没有可比对象。
    /// 以前这一档被塞进 `.failed`,徽章打「需手动」并标红,可用户**没有任何
    /// 手动动作可做**;红色的「需手动」只会让他去翻设置找一个不存在的开关。
    case note(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var isNote: Bool { if case .note = self { return true }; return false }

    /// 回执附注行前面的小符号与颜色。和 `fixChip` 共用同一套语义:
    /// 绿勾 = 修好了,红叹 = 要你动手,灰问号 = 没法验证。
    var noteMark: (symbol: String, color: Color, help: String) {
        switch self {
        case .running: return ("", ClaudeTheme.muted, "")
        case .done: return ("checkmark.circle.fill", ClaudeTheme.ok, "")
        case .failed:
            return ("exclamationmark.circle.fill", ClaudeTheme.bad, "脚本没能自动修好这一项：")
        case .note:
            return ("questionmark.circle.fill", ClaudeTheme.muted, "这一项没法验证：")
        }
    }

    /// 回执附注。修好了常带「重启 Claude 后生效」这类前提,别让它丢了。
    var note: String {
        switch self {
        case .running: return ""
        case .done(let n), .failed(let n), .note(let n): return n
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

    /// 结论色只回答「能不能启动」，不再按分数分档。
    ///
    /// 曾经有过一个 `scoreColor`（≥85 绿 / 60–84 琥珀 / <60 红），本意是让高分
    /// 不套警告色。但它把两件事绑死在了一起：IP 纯净度低一点，分数掉到 80，
    /// 环就变琥珀 —— 而徽章明明写着「可以启动」。用户读到的只有颜色，
    /// 于是「能启动」被显示成「快出事了」。
    /// 2026-11-06 用户原话：「不要用分数让别人误会，IP 非常不干净按道理还是能启动」。
    /// 分数仍在 `HealthSummary.score` 里保留（诊断和排序要用），但不再进主视觉。
    var color: Color {
        switch level {
        case .ok: return ClaudeTheme.success
        case .notice: return ClaudeTheme.warning
        case .cannotStart: return ClaudeTheme.error
        }
    }

    /// 提示项的轻重顺序。分数对每个警告一视同仁(各扣 6),但「一句话结论」不能一视同仁 ——
    /// 用户看到的第一个词,决定他会不会继续往下看。
    ///
    /// 顺序按「对 Claude 账号的实际影响」排,不是按检查项编号:
    /// 出口纯净度直接决定 Claude 怎么对待这个账号,而且是唯一带 0-100 量化分的项;
    /// ASN 属性常常和它是同一个事实(机房),但只报类型、不报程度;
    /// 其余几项要么是稳定性,要么是可达性 —— 真出问题时用户自己会立刻感觉到。
    private static let warningOrder = [
        "IP纯净度", "ASN属性", "WebRTC", "DNS", "IP一致", "客户端语言", "生态可达性",
        // 「有更干净的可用节点」是建议,不是故障 —— 排最后,别抢纯净度那句话。
        "更优节点",
    ]

    /// 排序键统一去掉空格:界面显示「IP 纯净度」,检查协议里是「IP纯净度」。
    private static func severity(_ row: CheckRow) -> Int {
        let key = row.name.replacingOccurrences(of: " ", with: "")
        return warningOrder.firstIndex(of: key) ?? warningOrder.count
    }

    /// 从明细里抠出量化分。目前只有纯净度有(`评分 49/100 · 机房 · …`)。
    /// 抠不到就只报项名 —— 结论里宁可少一个数字,也不能自己编一个。
    private static func shortScore(_ detail: String) -> String? {
        guard let hit = detail.range(of: "评分 ") else { return nil }
        let digits = detail[hit.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// 同一段文字里的那个数字，返回 Int。
    private static func measuredScore(_ detail: String) -> Int? {
        shortScore(detail).flatMap(Int.init)
    }

    // 这里曾经有一条 cappedByMeasured（总分 = min(扣分结果, 各实测分)）。
    // 它解决了「88 分 vs IP 49 分」那一次，但代价是总分**等于**纯净度分 ——
    // 圈里那个数字成了 IP 分的复制品，不再是「整体」。用户第二次反馈的
    // 「不能只是拿 ip 纯净度做评分」说的就是这件事。现在换成四维加权:
    // 纯净度仍然是最重的一项（40 分里按实测折算），但不再是唯一决定项。

    /// 检查项名归一:界面用「IP 与上次一致」、检查协议用「IP一致」、测试夹具又用「IP纯净度」。
    /// 加权表按归一后的名字取项 —— 三种写法必须落到同一个 key,否则某一项在线上永远
    /// 匹配不到、静默不扣分,而测试却是绿的。
    static func key(_ name: String) -> String {
        switch name.replacingOccurrences(of: " ", with: "") {
        case "IP一致", "IP与上次一致": return "IP一致"
        case "TUN网卡": return "TUN网卡"
        case "IPv6关闭": return "IPv6"
        case "DNS走隧道": return "DNS"
        case "IP纯净度": return "IP纯净度"
        case "ASN属性": return "ASN属性"
        case "保镖在线": return "保镖"
        case "规则置顶": return "规则置顶"
        case "客户端语言": return "客户端语言"
        case "生态可达性": return "生态可达性"
        case "代理内核": return "代理内核"
        case "出口IP": return "出口IP"
        default: return name.replacingOccurrences(of: " ", with: "")
        }
    }

    /// 四个维度各自的**扣分上限**，加起来正好 100。
    ///
    /// 为什么分维度而不是「每个警告扣 6 分」:后者把「出口是转租机房、纯净度 49」
    /// 和「时区格式不对」当成同一件事,两项都只值 6 分。实测反馈就是这个 ——
    /// 「ip 评分这么低但是还有 88 分」。
    ///
    /// 权重的依据取自同类风控产品的公开口径（IPQS / Scamalytics / ip.net.coffee）:
    ///   · 归属属性是**最大的一项**。机房/托管段对消费级产品天然高风险,
    ///     实测即使是从未使用过的新机房 IP,初始风险也已到 50 上下;
    ///   · 匿名化要分类型。Tor > 住宅代理 > 商业 VPN > 机房;
    ///   · 地理位置完整性(时区/地区/语言和出口对不对得上)是独立一档,
    ///     因为它是「同一时刻自相矛盾」的证据,而不是「这个 IP 好不好」;
    ///   · 它们都不给单一因子一票否决 —— 所以这里也没有任何一项能独占 100 分。
    ///
    /// 我们的四维对应到 Claude 的场景:
    ///   身份 40  —— 出口本身:纯净度实测 + 是否机房 + 出不出海
    ///   隔离 30  —— 本机会不会把真实地址漏出去:IPv6 / DNS / WebRTC / TUN
    ///   一致 15  —— 自相矛盾:时区 / 地区 / 客户端语言 / 生态可达性
    ///   守护 15  —— 这套护栏本身还生效吗:保镖 / 规则置顶 / 内核
    enum Weight {
        static let identityCap = 40
        static let isolationCap = 30
        static let consistencyCap = 15
        static let guardCap = 15
    }

    /// 分维度扣分。返回 (总扣分, 各维度明细) —— 明细只用于注释与调试,
    /// 界面里不展示,免得又变成一屏数字。
    static func deductions(_ rows: [CheckRow]) -> (total: Int, breakdown: [String: Int]) {
        func row(_ key: String) -> CheckRow? { rows.first { self.key($0.name) == key } }
        func penalty(_ key: String, _ weight: Int) -> Int {
            guard let r = row(key) else { return 0 }
            // skip = 用户显式关掉 / 这项没验成(节点报告还没生成)。两种都不是
            // 「实测不合格」,不能算扣分 —— 否则关掉一个检查项总分反而会掉。
            return r.state == .ok || r.state == .pending || r.state == .skip ? 0 : weight
        }

        // 身份：纯净度按「离满分的距离」线性折算，这是唯一有实测分的项；
        // 其余是离散事实（机房、出口在漂）。
        var identity = 0
        if let purity = row("IP纯净度"), purity.state != .ok,
           let measured = measuredScore(purity.detail) {
            identity += Int((Double(100 - measured) * 0.4).rounded())
        } else {
            identity += penalty("IP纯净度", 6)   // 没拿到分，也说明这一项没验成
        }
        identity += penalty("ASN属性", 6)
        identity += penalty("IP一致", 4)
        // 「存在更干净且过硬门槛的可用节点」属于身份维度:它说的是这条出口
        // 还有更好的选择,不是环境漏了。4 分,不足以一票压过纯净度实测分。
        identity += penalty("更优节点", 4)
        identity = min(identity, Weight.identityCap)

        let isolation = min(
            penalty("IPv6", 10) + penalty("DNS", 8) + penalty("WebRTC", 12) + penalty("TUN网卡", 10),
            Weight.isolationCap)

        let consistency = min(
            penalty("时区", 6) + penalty("地区", 4) + penalty("客户端语言", 3) + penalty("生态可达性", 4),
            Weight.consistencyCap)

        let guardScore = min(
            penalty("保镖", 8) + penalty("规则置顶", 7) + penalty("代理内核", 8),
            Weight.guardCap)

        let breakdown = ["身份": identity, "隔离": isolation,
                         "一致": consistency, "守护": guardScore]
        return (breakdown.values.reduce(0, +), breakdown)
    }

    /// 纯函数:输入检查结果,输出分数和一句话结论。
    ///
    /// 硬性项是「Claude 能不能启动」的开关,不是可以慢慢扣的分项 ——
    /// 代理内核没起来还挂着 85 分,等于告诉用户「小毛病,能用」,而实际是起不来。
    /// 所以硬性项一失败就直接塌到 30 分以下,其余项走四维加权。
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

        // 四维加权（见 Weight）。之前是「每条警告扣 6 分」，一条提示最多 6 分，
        // 于是「出口是转租机房、纯净度 49」和「时区格式不对」等价 —— 88 分就是这么来的。
        let noticeScore = max(0, 100 - deductions(rows).total)

        if let first = softBad.first {
            return HealthSummary(score: noticeScore, level: .notice, badge: "可以启动",
                                 headline: "\(first.name)未通过 · 不影响启动")
        }

        let notices = hardWarn + softWarn
        if notices > 0 {
            // 结论要点名最重的那一项,而不是笼统地报「3 项建议处理」。
            // 实测:出口是转租机房、纯净度 49 分,而同一屏另外两个警告只是
            // 「IP 变了 4 次」和「疑似机房」;只报项数会把这些压成同一句话,
            // 用户读完「3 项建议处理,不影响使用」就不再往下看了。
            // 硬性项的警告优先:它们本来就是拦启动的项,松动了等于接近失守。
            let pool = hardWarn > 0
                ? hard.filter { $0.state == .warn }
                : soft.filter { $0.state == .warn }
            if let worst = pool.min(by: { severity($0) < severity($1) }) {
                var title = worst.name
                // 写成「49/100」而不是「49 分」：这是 IP 纯净度的百分制参照分
                // （对标 ip.net.coffee 的 Trust Score），不是整机健康分。
                // 裸写「49 分」会被读成「这台机器 49 分」，而同一屏的环里
                // 已经没有分数了，两个「分」不是一回事。
                if let score = shortScore(worst.detail) { title += " \(score)/100" }
                let tail = notices > 1 ? " · 另有 \(notices - 1) 项提示" : ""
                // 「不影响启动」而不是「不影响使用」:不拦启动是事实,
                // 但「机房出口对账号没影响」不是我们能替他打的包票。
                return HealthSummary(score: noticeScore, level: .notice, badge: "可以启动",
                                     headline: "\(title)\(tail)，不影响启动")
            }
            // 到不了这里:notices > 0 保证 pool 非空。留着只为不崩。
            return HealthSummary(score: noticeScore, level: .notice, badge: "可以启动",
                                 headline: "\(notices) 项提示，不影响启动")
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

/// 扫描报告里的一条候选出口。给「把这条线绑定到槽位」的菜单用。
/// 分数只用来在菜单里给人一个比较依据，不参与绑定判定。
struct NodeCandidate: Identifiable, Equatable {
    let leaf: String
    let score: String
    var id: String { leaf }
    /// 菜单一行要同时说清「是哪条」和「凭什么」。名字太长交给 SwiftUI 截断。
    var label: String {
        score.isEmpty ? leaf : "\(leaf) · \(score) 分"
    }
}

/// 一个槽位「还能不能直接用」。
///
/// 这个状态以前根本没有 —— 界面只有「已保存 / 未初始化」，而「已保存」说的是
/// **档案在不在**，不是**会话还有没有效**。实测两个槽位，快照都在、大小都正常，
/// 但其中一个的 Cookies 里压根没有 `sessionKey`（只剩设备类 cookie），
/// 点进去是登录页。用户看见「已保存」，以为能用，切换过去才发现要重新登录。
///
/// 判据取 Claude 桌面版自己那份 Chromium Cookies 库里的会话 cookie：
/// `sessionKey / sessionKeyLC / sessionKeyV3 / sessionKeyV3LC` 任意一条存在且
/// 未过期即为已登录。不解密内容 —— 只看名字和过期时间，这也足够回答「还能用吗」。
enum SlotLogin: Equatable {
    /// 档案不存在 / 读不出来（库被锁、格式变了）。这一档要老老实实显示未知，
    /// 不能猜成「已登录」，否则又把用户骗一次。
    case unknown
    case loggedIn
    /// 会话 cookie 还在，但已经过期。和「没有」分开显示：前者是「太久没开过」，
    /// 后者是「这个槽位从来没登过」。
    case expired
    case loggedOut
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
    // 图标怎么挑的：一列图标排在一条竖轴上，人眼对的是**着墨包围盒**和**着墨量**，
    // 不是字号。SF Symbols 同名同号，实际着墨大小差得很远 —— 换之前量过：
    //   eye.slash 19×12、textformat 15×9、hand.raised 11×15、antenna… 14×12(5.8%)，
    //   而 cpu 只有 12×12。同一列里 19 宽和 11 宽并排，怎么调字号都"不齐"。
    //
    // 现在这一列的指标（13pt / medium，32×32 画布）：宽 12–14 / 高 12–14 / 着墨 6.1–10.1%。
    // 换图标前请先量：`.font(.system(size: 13, weight: .medium))` 下着墨包围盒落在
    // 12–14pt、着墨量 6–10%，且**不要再出现「圆环里包一个符号」**（圆环外径大、
    // 内部空，光学重量和实心小图不是一回事）。
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu", canDisable: false),
        CheckRow(name: "TUN 网卡", icon: "externaldrive.connected.to.line.below", canDisable: false),
        CheckRow(name: "出口 IP", icon: "globe", canDisable: false),
        CheckRow(name: "IP 与上次一致", icon: "equal.square", canDisable: true),
        CheckRow(name: "时区", icon: "clock", canDisable: false),
        CheckRow(name: "地区", icon: "flag", canDisable: false),
        CheckRow(name: "IPv6 关闭", icon: "6.circle", canDisable: false),
        CheckRow(name: "DNS 走隧道", icon: "arrow.triangle.swap", canDisable: true),
        CheckRow(name: "WebRTC", icon: "antenna.radiowaves.left.and.right.slash", canDisable: true),
        CheckRow(name: "保镖在线", icon: "checkmark.circle", canDisable: false),
        CheckRow(name: "规则置顶", icon: "checklist", canDisable: false),
        CheckRow(name: "客户端语言", icon: "character.bubble", canDisable: true),
        CheckRow(name: "ASN 属性", icon: "building.columns", canDisable: true),
        CheckRow(name: "IP 纯净度", icon: "gauge.medium", canDisable: true),
        CheckRow(name: "生态可达性", icon: "chart.line.uptrend.xyaxis", canDisable: true),
        // 13pt/medium 下着墨盒 13.0×13.0、着墨量 8.91%,和这一列同一档
        // (实测 arrow.up.right 只有 9.5×9.5 / 3.64%,会显得缺一块)。
        CheckRow(name: "更优节点", icon: "network", canDisable: true),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var archived: Set<String> = []
    @Published var stamps: [String: AccountStamp] = [:]
    /// 槽位里那份 Claude Code 状态（~/.claude/ + ~/.claude.json）的体积和日期。
    /// 槽位现在不止搬桌面版目录，卡上得看得出来「这个槽位是全套的」。
    @Published private(set) var cliStamps: [String: AccountStamp] = [:]
    /// 每个槽位「会话还有没有效」。由 Cookies 库直接读，和脚本的 status 并行取。
    @Published var slotLogin: [String: SlotLogin] = [:]
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheckSummary = "尚未检查"
    @Published var updateText = ""
    @Published var showUpdateSheet = false
    @Published private(set) var coreMissing = false
    @Published private(set) var currentClient = ""
    /// Claude 桌面版此刻是否在运行。
    ///
    /// 槽位卡上原来写的是「当前账号 A」—— 那是**切换器的指针**，不是用户的
    /// 登录状态。Claude 没打开、甚至没登录的时候，界面照样宣称「当前账号」，
    /// 用户会以为自己在用某个账号。改成按运行态说事：没开就是「上次使用」。
    @Published private(set) var claudeRunning = false
    /// CLI 的启停没有系统通知可订阅，只能低频轮询（见 trackClaudeProcess）。
    private var cliPollTimer: Timer?
    @Published private(set) var isSwitchingClient = false
    @Published var disabledChecks: Set<String> = []
    @Published var allowOptionalFailures = false
    @Published var loggingEnabled = true
    @Published var settingsMessage = ""
    @Published private(set) var settingsBusy = false
    /// 只读节点扫描的结果。不放进 isBusy:扫描期间看门狗照常驻守,界面也
    /// 不该把「重新检查 / 修复 / 切换」全锁住 —— 这一路本来就没有副作用。
    @Published private(set) var nodeScanBusy = false
    @Published var nodeScanReport = ""
    @Published var showNodeScan = false
    /// 本机核心脚本比界面旧（典型症状:调 node-scan 回退出码 2 + 一行老 usage）。
    /// 只装了 app-only DMG、没跑安装器时必然踩到;给明确的升级指引，
    /// 别让人对着「脚本执行失败」猜。
    @Published private(set) var coreOutdated = false
    /// 最近一次扫描/应用报告的键值,只用来决定「应用最优节点」按钮该不该出现。
    @Published private(set) var nodeScanInfo: [String: String] = [:]
    /// 换槽位顺带换节点时的一句话回执:换成了哪条、或者为什么没换。
    /// 空串 = 这次切换没碰节点（没什么可换，或者扫描没跑成）。
    @Published private(set) var nodeSwitchNote = ""
    /// 槽位 → 绑定的出口节点（叶子名）。空 = 没绑。
    ///
    /// 读盘而不走核心脚本，和 `probeSlotLogin` 同一个理由：这是**显示**需求，
    /// 塞进 `status` 的输出契约里要连带改 SHA256SUMS、旧版兼容和一堆断言。
    /// 写入仍然只走 `slot-node set`，路径与格式以核心脚本为准
    /// （见 core/claude-switch.sh 的 SLOT_NODE_DIR）。
    @Published private(set) var slotNodes: [String: String] = [:]
    /// 上次扫描报告里排在最前的几条候选，给「绑定到槽位」当选项用。
    /// 只从报告里取，不自己算分 —— 分数怎么来的归核心脚本解释。
    @Published private(set) var nodeCandidates: [NodeCandidate] = []
    /// 门禁是保守并集(App 运行时通常会有守护驻守),所以这个按钮很少出现 ——
    /// 那正是用户要的形状:宁可让人去客户端点一下,不能替在用的会话换线路。
    var canApplyBestNode: Bool {
        nodeScanInfo["GATE"] == "auto-ok" && !(nodeScanInfo["BEST"] ?? "").isEmpty
    }
    @Published var showSettingsSheet = false
    /// 运行期看门狗已经动手停了 Claude。与「检查没过」不是一回事:
    /// 后者是拉起前的门禁,前者是已经放行之后又被抓回来,必须显眼到不可能忽略。
    @Published private(set) var intercepted = false
    /// 最近一次熔断的真实结果，由脚本的 KILLSTATE 行给出。
    /// nil = 还没熔断过，或者装的是不认这条的老脚本 —— 两种都要能降级。
    /// was：熔断那一刻 Claude 在不在跑；still：处理完还在不在跑。
    @Published private(set) var stopWasRunning: Bool?
    @Published private(set) var stopStillRunning: Bool?
    /// 最近一次熔断的原因原文，标题里只放结论，原因放在横幅里。
    @Published private(set) var stopReason = ""
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
        ("IP纯净度", "IP 纯净度"),
        ("生态可达性", "生态可达性"),
        ("更优节点", "更优节点"),
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

    /// 给核心脚本的进程环境。保留 App 继承到的全部变量,只把系统/brew 的
    /// 标准工具目录补进 PATH —— 不覆盖用户已有的顺序,避免把系统 curl 换成
    /// 某个同名工具。python3 由核心脚本自己按绝对路径解析,不依赖这里。
    private static func coreProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/local/sbin",
                    "/opt/homebrew/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !parts.contains(dir) { parts.append(dir) }
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
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
            // 从 Finder / LaunchAgent 启动的 App 继承的是 launchd 的极简 PATH
            // (/usr/bin:/bin:/usr/sbin:/sbin)。终端里能用的 brew、python.org
            // 解释器和代理 CLI 在 App 里全都不在 PATH 上,fix 会在前置校验里
            // 0 秒失败,而终端手动跑却是好的。在继承环境的基础上补齐常见目录。
            p.environment = Self.coreProcessEnvironment()
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
        "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "IP纯净度": "IP 纯净度",
        "生态可达性": "生态可达性", "更优节点": "更优节点",
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
        // 熔断的三条事实跟着一起清。不清的话，重新检查通过之后
        // 标题还会挂着「已熔断并关闭 Claude」—— 说的是一件已经过去的事。
        stopWasRunning = nil
        stopStillRunning = nil
        stopReason = ""
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
        // 脚本在停 Claude 的那一步会报三条事实：熔断时在不在跑、处理完还在不在。
        // 没有这条的老脚本不会发，stopWasRunning 保持 nil，文案自动退回旧说法。
        if line.hasPrefix("KILLSTATE:") {
            let parts = line.dropFirst("KILLSTATE:".count).split(separator: ":")
            if parts.count == 2 {
                stopWasRunning = parts[0] == "1"
                stopStillRunning = parts[1] == "1"
            }
            return
        }
        guard line.hasPrefix("STOP:") else { return }
        let reason = String(line.dropFirst(5))
        stopReason = reason
        watchStopping = true
        watchActive = false
        // 不动 isBusy:看门狗停 Claude 与界面上的修复/切换是两条线,
        // 清掉忙碌标记会让 refresh 的互斥失效,可能并发跑出两个检查。
        phase = .failed
        intercepted = true
        lastCheckSummary = "已拦截"
        // 以前这里无条件写「已自动停止 Claude」。脚本其实在停之前就 pgrep 过，
        // 只是没把结果传上来 —— 于是 Claude 没开、或者 pkill 之后还在跑，
        // 界面说的都是同一句。现在按真实结果分三种说法。
        banner = interceptionHeadline(reason: reason)
        // 脚本刚写完这条记录,立刻读回来 —— 界面上的「异常记录」要和日志同步,
        // 不能等下次重新检查才出现。
        loadIncidents()
        // 界面横幅只在窗口开着时有用,而这是「已经在用」的时候出的问题 ——
        // 用户多半没开窗口。必须推一条系统通知,否则等于没提醒。
        notify(title: interceptionShortTitle, body: reason)
    }

    /// 熔断的三种真实结局，一句话说清「Claude 到底关掉没有」。
    /// 旧脚本不发 KILLSTATE，这时退回原来那句中性说法，不假装知道。
    var interceptionShortTitle: String {
        guard let was = stopWasRunning else { return "已自动停止 Claude" }
        if stopStillRunning == true { return "已拦截，但 Claude 没关掉" }
        return was ? "已拦截并关闭 Claude" : "已拦截（Claude 当时没开）"
    }

    private func interceptionHeadline(reason: String) -> String {
        guard let was = stopWasRunning else { return "已自动停止 Claude：\(reason)" }
        if stopStillRunning == true {
            return "已拦截，但 Claude 仍在运行，没能关掉：\(reason)"
        }
        return was
            ? "已拦截并关闭 Claude：\(reason)"
            : "已拦截（拦截时 Claude 没有在运行）：\(reason)"
    }

    /// 走 osascript 而不是 UNUserNotificationCenter:这个 App 是 ad-hoc 签名,
    /// 通知授权在重签名后会失效,而 display notification 不依赖它。
    private func notify(title: String, body: String) {
        let clean = body.replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let script = "display notification \"\(clean)\" with title \"Claude 环境检查器\" subtitle \"\(title)\" sound name \"Basso\""
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

    /// 跟踪 Claude 的运行态。桌面版靠 NSWorkspace 的启停通知，不轮询进程表 ——
    /// 界面每次刷新都 pgrep 一遍，代价比收益大。
    ///
    /// 终端里的 Claude Code 没有启停通知可订阅，只能低频轮询：5 秒一次，
    /// 命中缓存后只跑一条 sh（约 2ms）。代价换来的是「终端里开着 claude 时
    /// 槽位卡不再写未运行」—— 原来只查桌面版 bundle id，CLI 完全隐形。
    func trackClaudeProcess() {
        claudeRunning = Self.isClaudeRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let running = Self.isClaudeRunning()
                guard running != self.claudeRunning else { return }
                self.claudeRunning = running
            }
        }
        #if !CLAUDE_SWITCHER_TESTS
        cliPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let running = Self.isClaudeRunning()
            guard running != self.claudeRunning else { return }
            self.claudeRunning = running
        }
        #endif
    }

    static func isClaudeRunning() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop"
        }) { return true }
        #if CLAUDE_SWITCHER_TESTS
        // 测试进程里不该去问真实进程表：开发机上开着 claude 就会让用例飘。
        return false
        #else
        return claudeCLIRunning()
        #endif
    }

    /// 三种装法都要认：原生二进制（brew / ~/.local/bin，argv[0] 就叫 claude）、
    /// 老 npm 包的 cli.js、以及 @anthropic-ai/claude-code。
    /// 结果缓存 2 秒 —— 这个函数会被视图求值调用，不能每次都 fork。
    private static var cliProbeAt = Date.distantPast
    private static var cliProbeValue = false

    static func claudeCLIRunning() -> Bool {
        let now = Date()
        if now.timeIntervalSince(cliProbeAt) < 2 { return cliProbeValue }
        cliProbeAt = now
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", "pgrep -x claude >/dev/null 2>&1"
            + " || pgrep -f claude-code/cli.js >/dev/null 2>&1"
            + " || pgrep -f @anthropic-ai/claude-code >/dev/null 2>&1"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch {
            cliProbeValue = false
            return false
        }
        probe.waitUntilExit()
        cliProbeValue = probe.terminationStatus == 0
        return cliProbeValue
    }

    #if CLAUDE_SWITCHER_TESTS
    /// 测试用：直接设定运行态。测试进程里没有 Claude，靠监听永远拿不到 true。
    func setClaudeRunningForTest(_ value: Bool) { claudeRunning = value }
    /// 测试用：直接灌一份扫描报告键值，验证门禁按钮与固定节点分支，不必真跑内核。
    func setNodeScanInfoForTest(_ info: [String: String]) { nodeScanInfo = info }
    #endif

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
        // 保留上一轮结果,只标记「这一轮还没回来」。清空的话,16 行会先集体
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
            current = "未知"; archived = []; stamps = [:]; cliStamps = [:]
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
        // CLI 存档是可选字段：老脚本不输出，缺了就当没有，不能因此判 status 失败。
        var cli: [String: AccountStamp] = [:]
        for letter in Self.accountLetters {
            guard let raw = fields["cli\(letter)"] else { continue }
            let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            cli[letter] = AccountStamp(size: String(parts[0]), date: String(parts[1]))
        }
        current = account == "none" ? "未初始化" : account
        stamps = parsed
        cliStamps = cli
        archived = known
        // 登录态要跟着切槽位/归档变化重算：切完之后实时档案换了一份，
        // 「当前槽位」的会话有效性也就换了。
        refreshSlotLogin()
        // 绑定是显示需求，跟着账号状态一起刷新：命令行里刚 `slot-node set`
        // 完，界面重开/重新检查一次就该看见，不必重启 App。
        loadSlotNodes()
        return true
    }

    static let accountLetters = ["A", "B", "C", "D"]

    // MARK: - 槽位登录态
    //
    // 只读 Claude 桌面版那份 Chromium Cookies 库里的**会话 cookie 名字与过期时间**，
    // 不解密内容、不碰 token。回答的是一个问题：「切过去还要不要重新登录」。
    //
    // 为什么不放进核心脚本：脚本的输出契约（current/accounts/accX）是给窗口、安装器、
    // 更新链路共用的，加字段要同步改 SHA256SUMS、旧版兼容分支和一堆测试。
    // 这件事纯粹是界面的显示需求，就在界面里做。

    /// 「当前槽位」要看实时档案，其余槽位看各自的存档副本。
    /// 切槽位的动作就是把存档整份拷到实时目录，所以两边结构一致。
    static func cookiesPath(for letter: String, current: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if letter == current {
            return home.appendingPathComponent("Library/Application Support/Claude/Cookies").path
        }
        return home.appendingPathComponent(".claude-switcher/accounts/\(letter)/Cookies").path
    }

    /// Chromium 把过期时间存成「1601-01-01 起算的微秒数」。
    private static let chromiumEpochOffset: Double = 11_644_473_600

    static func probeSlotLogin(_ letter: String, current: String) -> SlotLogin {
        let primary = cookiesPath(for: letter, current: current)
        let fallback: String? = letter == current
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-switcher/accounts/\(letter)/Cookies").path
            : nil
        if let state = readLogin(from: primary) { return state }
        // 实时档案读不出来（Claude 正在写、库被锁）时退回存档副本 ——
        // 比直接报「未知」有用，而且存档副本就是上次切换时的那份，
        // 对「要不要重新登录」这个问题通常仍然成立。
        if let fallback, let state = readLogin(from: fallback) { return state }
        return .unknown
    }

    /// 读不出来返回 nil（调用方据此降级），读得出来返回确定的状态。
    private static func readLogin(from path: String) -> SlotLogin? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [
            "-readonly", path,
            "select count(*), coalesce(max(expires_utc),0) from cookies where name like 'sessionKey%';",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "|")
        guard parts.count == 2, let count = Int(parts[0]), let raw = Double(parts[1]) else { return nil }
        guard count > 0 else { return .loggedOut }
        // 0 = 会话级 cookie（关掉 Claude 就没了，但此刻确实有效）。
        guard raw > 0 else { return .loggedIn }
        let expires = Date(timeIntervalSince1970: raw / 1_000_000 - chromiumEpochOffset)
        return expires > Date() ? .loggedIn : .expired
    }

    func refreshSlotLogin() {
        let current = self.current
        guard current != "?" else { return }
        DispatchQueue.global(qos: .utility).async {
            var map: [String: SlotLogin] = [:]
            for letter in Self.accountLetters {
                map[letter] = Self.probeSlotLogin(letter, current: current)
            }
            DispatchQueue.main.async { self.slotLogin = map }
        }
    }

    /// 脚本真的能自动处理的检查项。不在这个集合里的(出口 IP、IP 一致性、
    /// ASN、生态可达性)只能靠人换节点/换线路,给按钮等于给假承诺。
    ///
    /// 「DNS 走隧道」曾经在这个集合里,但 fix() 那一段只刷了解析缓存、不改解析路径,
    /// 它自己打印的就是「一键修复改不了这项」。界面给按钮、hero 还写「点修复即可」,
    /// 用户点完只会拿到一句修不了 —— 承诺和能力对不上。现在移出可修清单,
    /// 改由检查项自己的 detail 写明「去客户端把 DNS 设为隧道/DoH」。
    static let fixableNames: Set<String> = [
        "代理内核", "TUN 网卡", "时区", "地区", "IPv6 关闭",
        "WebRTC", "保镖在线", "规则置顶", "客户端语言",
    ]

    /// 修不了、但换节点/换线路就能解决的项。剩下的那些(DNS 没走隧道)得去
    /// 客户端改设置,笼统写成「换节点」会把用户支到错的方向。
    static let nodeBoundNames: Set<String> = [
        "ASN 属性", "IP 纯净度", "IP 与上次一致", "生态可达性", "更优节点",
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

    /// 从 node-scan 的输出里抠 `KEY=VALUE`。纯函数,便于模型测试直接喂文本。
    /// 扫描命令同时把这段写进报告文件,所以这里和 checkdetail 读的是同一套口径。
    static func parseNodeScan(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            if key.hasPrefix("EPOCH") || key.hasPrefix("GROUP") || key.hasPrefix("SELECTOR")
                || key.hasPrefix("CURRENT") || key.hasPrefix("BEST") || key.hasPrefix("DELTA")
                || key.hasPrefix("GATE") || key.hasPrefix("CANDIDATES")
                || key.hasPrefix("UNIQUE_IPS") || key.hasPrefix("UNKNOWN")
                || key.hasPrefix("ELIGIBLE") || key.hasPrefix("PREFERRED")
                || key.hasPrefix("SCAN_TIME")
                || key.hasPrefix("APPLY") || key.hasPrefix("APPLIED") {
                result[key] = String(parts[1])
            }
        }
        return result
    }

    /// 旧核心不认识 `node-scan` / `slot-node`:`run` 会把退出码 2 和脚本打印的
    /// 那行 usage 一起塞进 output。命中就别再当普通扫描失败处理。
    /// 注意 v1.7.1 的 `update` 指向旧上游仓库，升级必须走新仓库，见 upgrade-core.sh。
    static func isStaleCore(_ output: String) -> Bool {
        guard output.contains("退出码 2") else { return false }
        return output.contains("用法: claude-switch.sh")
            || output.contains("未知命令: node-scan")
            || output.contains("未知命令: slot-node")
    }

    /// 界面里所有「升级核心脚本」入口共用这一条，别在面板和文案里各写一份慢慢漂移。
    static let upgradeCoreCommand =
        "bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)"

    static let staleCoreHelp = """
    核心脚本版本过旧，不认识节点扫描命令。

    常见原因：只装了「仅 App」的 DMG/ZIP，没有同步更新核心脚本，或旧版脚本的
    自动更新仍指向原上游仓库（拉不到本仓库的新版）。

    修复：在终端执行下面这一行（会先校验 SHA256、备份旧脚本、再自检，失败自动回滚）：

    \(upgradeCoreCommand)

    完成后回到本界面点「重新检查」。
    """

    /// `TOPn=叶子|分数|出口IP|判据|说明` —— 报告里按分数排好的前三名。
    /// 只认 TOP 行，不把 BEST 混进来：BEST 是「值得换」的结论，未必是全部候选。
    static func parseNodeCandidates(_ output: String) -> [NodeCandidate] {
        var out: [NodeCandidate] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TOP") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let fields = parts[1].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let leaf = String(fields[0])
            let score = String(fields[1])
            guard !leaf.isEmpty, seen.insert(leaf).inserted else { continue }
            out.append(NodeCandidate(leaf: leaf, score: score))
        }
        return out
    }

    // MARK: - 槽位 ↔ 节点绑定

    /// 与 core/claude-switch.sh 的 `SLOT_NODE_DIR="$BASE/slot-node"` 同一处。
    /// 这里读、脚本写；两边各自拼路径，改一边必须改另一边（tests/test_node_scan.py 盯着）。
    static var slotNodeDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-switcher/slot-node").path
    }
    /// 生产走上面的固定路径；测试把它指到夹具目录，免得读到本机真实绑定。
    var slotNodeRoot: String = VM.slotNodeDir

    /// 把四个绑定文件读回来。文件格式 selector<TAB>leaf<TAB>epoch，
    /// 由核心脚本写；这里只取第二个字段，坏行/半行直接跳过。
    func loadSlotNodes() {
        var found: [String: String] = [:]
        for letter in Self.accountLetters {
            let path = "\(slotNodeRoot)/\(letter)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let line = text.split(separator: "\n").first else { continue }
            let leaf = Self.parseSlotNode(String(line))
            if !leaf.isEmpty { found[letter] = leaf }
        }
        slotNodes = found
    }

    /// 给槽位声明「就走这条线」。不改当前出口，也不切账号 ——
    /// 真正换线路发生在下次切到这个槽位时（optimizeNodeForSwitch）。
    func bindSlotNode(_ slot: String, leaf: String) {
        guard !isBusy, !leaf.isEmpty, Self.accountLetters.contains(slot), coreAvailable() else { return }
        run(["slot-node", "set", slot, leaf], timeout: 15) { [weak self] result in
            guard let self else { return }
            guard result.succeeded, !result.output.contains("FAIL:") else {
                self.note = "绑定失败：\(Self.failureLine(result.output))"
                return
            }
            self.loadSlotNodes()
            self.note = "账号\(slot) 已绑定 \(leaf)，下次切到它会先换这条出口"
        }
    }

    func clearSlotNode(_ slot: String) {
        guard !isBusy, Self.accountLetters.contains(slot), coreAvailable() else { return }
        run(["slot-node", "clear", slot], timeout: 15) { [weak self] result in
            guard let self else { return }
            guard result.succeeded, !result.output.contains("FAIL:") else {
                self.note = "解除绑定失败：\(Self.failureLine(result.output))"
                return
            }
            self.loadSlotNodes()
            self.note = "账号\(slot) 已解除节点绑定，切过去时改由本次扫描决定"
        }
    }

    /// 结论后面必须挂得上证据,不能只丢一句「没有更优节点」却看不到扫了什么。
    /// 旧格式报告缺字段时逐项省略 —— 拿 0 冒充实测值比没有数字更糟。
    /// 格式与 core/claude-switch.sh 的 checkdetail 第 16 项保持一致。
    static func nodeScanEvidence(_ info: [String: String]) -> String {
        var parts: [String] = []
        for (key, suffix) in [("CANDIDATES", " 候选"), ("UNIQUE_IPS", " 出口"), ("ELIGIBLE", " 合格")] {
            if let v = info[key], !v.isEmpty { parts.append(v + suffix) }
        }
        var out = ""
        if !parts.isEmpty { out += " · " + parts.joined(separator: "/") }
        if let v = info["CURRENT_SCORE"], !v.isEmpty { out += " · 当前 \(v) 分" }
        if let v = info["SCAN_TIME"], !v.isEmpty { out += " · \(v) 扫描" }
        return out
    }

    /// 脚本 stdout 末尾那段 KEY=VALUE 是给 App 解析的,不是给用户读的。
    /// 面板里混着十几行英文键,人话报告反而被挤到上面看不见。
    static func displayableNodeReport(_ output: String) -> String {
        let human: String
        if let marker = output.range(of: "--- 报告键值 ---") {
            human = String(output[..<marker.lowerBound])
        } else {
            human = output
        }
        return human.split(separator: "\n")
            .filter { !$0.hasPrefix("APPLY=") && !$0.hasPrefix("APPLIED=") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 扫描完就地更新「更优节点」这一行,不做整轮 refresh。
    /// refresh() 会先撤掉看门狗再检查 —— 那是「重新检查」的代价,不该让
    /// 一个只读扫描顺手把守护停掉。
    func applyNodeScan(_ info: [String: String]) {
        guard let idx = rows.firstIndex(where: { $0.name == "更优节点" }) else { return }
        let best = info["BEST"] ?? ""
        let pref = info["PREFERRED"] ?? ""
        // 优先级和 checkdetail 完全一致,否则同一屏两处会给出不同结论。
        // 提示必须和 checkdetail 的同名分支说同一件事。auto-ok 时面板里
        // 真有「应用最优节点」按钮,再叫用户「到客户端自己切」等于把新能力
        // 藏起来;反过来 report-only 时不该许诺一个不会出现的按钮。
        let autoOK = info["GATE"] == "auto-ok"
        if info["PREFERRED_MATCH"] == "0" && !pref.isEmpty {
            rows[idx].state = .warn
            rows[idx].detail = "已偏离固定节点 \(pref) · 点「扫描可用节点」重新应用"
        } else if info["PREFERRED_MATCH"] == "1" && !pref.isEmpty {
            rows[idx].state = .ok
            rows[idx].detail = "已固定在 \(pref) · 后续检查都基于这条线路"
        } else if !best.isEmpty, let delta = Int(info["DELTA"] ?? "") {
            rows[idx].state = .warn
            let hint = autoOK ? "点「扫描可用节点」→「应用最优节点」自动切换" : "到客户端手动切换"
            rows[idx].detail = "有更干净的节点 \(best)(\(info["BEST_SCORE"] ?? "?") 分,比当前高 \(delta) 分) · \(hint)"
                + Self.nodeScanEvidence(info)
        } else if info["ELIGIBLE"] == "0" {
            rows[idx].state = .skip
            rows[idx].detail = "没有过硬门槛的候选节点 · 保持当前线路" + Self.nodeScanEvidence(info)
        } else {
            rows[idx].state = .ok
            rows[idx].detail = "过硬门槛内没有更优节点" + Self.nodeScanEvidence(info)
        }
    }

    func scanNodes() {
        guard !nodeScanBusy, coreAvailable() else { return }
        nodeScanBusy = true
        // 3 个并发的纯净度查询各要 ~6s,加上内核枚举与配置解析实测 13s;
        // 给 90s,比 check 的 45s 宽,但不允许无限等。
        run(["node-scan"], timeout: 90) { [weak self] result in
            guard let self else { return }
            self.nodeScanBusy = false
            if result.succeeded {
                // 先拿完整 stdout 解析,再把人话部分留给用户看。
                let info = Self.parseNodeScan(result.output)
                self.nodeScanInfo = info
                self.nodeCandidates = Self.parseNodeCandidates(result.output)
                self.applyNodeScan(info)
                self.nodeScanReport = Self.displayableNodeReport(result.output)
                self.coreOutdated = false
            } else if Self.isStaleCore(result.output) {
                self.coreOutdated = true
                self.nodeScanReport = Self.staleCoreHelp
                self.banner = "核心脚本版本过旧，需要先更新"
            } else {
                self.nodeScanReport = "扫描失败：\(result.output.isEmpty ? "脚本没有返回结果" : result.output)"
            }
            self.showNodeScan = true
        }
    }

    /// 应用最优节点。守护由 App 自己停/起:脚本去杀 App 持有的 watch 进程,
    /// 会被当成「守护意外退出」误报成假故障。
    func applyBestNode() {
        guard canApplyBestNode, !isBusy, !nodeScanBusy, coreAvailable() else { return }
        isBusy = true
        stopWatch()
        run(["node-apply"], timeout: 120) { [weak self] result in
            guard let self else { return }
            self.nodeScanReport = Self.displayableNodeReport(result.output)
            if result.succeeded {
                let info = Self.parseNodeScan(result.output)
                self.nodeScanInfo = info
                self.nodeCandidates = Self.parseNodeCandidates(result.output)
                self.applyNodeScan(info)
            }
            // 无论切换成功与否都重新完整检查:通过会自动 startWatch(),
            // 不通过就保持停守护。切完线路到底过没过,必须重新实测再说。
            self.checkEnvironment { _ in
                self.isBusy = false
                self.showNodeScan = true
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
            // run() 的流式回调在后台队列,直接改 @Published 会让 SwiftUI 在
            // 非主线程刷新;统一丢回主线程,顺序由主队列串行保证。
            DispatchQueue.main.async { self?.applyFixLine(line) }
        }) { result in
            // 原始输出落盘,「导出诊断日志」会带上一份脱敏副本。以前诊断包里
            // 只有 client.log 的命令元数据,根本看不出 fix 卡在哪一行。
            Self.persistFixOutput(result.output)

            // 以完整输出为准重放一次:流式预览可能漏行/半行,而且它跑在
            // 另一条队列上。重放是幂等的(applyFixLine 只是覆盖同名状态牌)。
            for line in result.output.split(whereSeparator: \.isNewline) {
                self.applyFixLine(String(line))
            }

            // 关键区分:fix() 收尾那句 `FIX:修复流程结束` 只有真正走完整条
            // 流程才会打印。前置校验(WebRTC 策略/python3/旧核心)失败时它在
            // 0 秒就 return 1,永远到不了这一句。
            //   · 有它 + 退出码非 0 = 前面多半修好了,只是收尾复测(WebRTC/
            //     出口IP)判失败 —— 旧代码在这里把 fixStates 全清空、phase
            //     打成 .failed、banner 换成「脚本执行失败(退出码 1)」,用户
            //     看到的就是「点了一下修复,什么都没修」。
            //   · 没它 = 脚本根本没跑起来,这才该显示原始错误 + 可操作提示。
            let sawFinish = result.output.contains("FIX:修复流程结束")
            guard result.succeeded || sawFinish else {
                self.fixStates = [:]
                self.phase = .failed
                self.banner = Self.fixLaunchFailureHint(result.output)
                self.isBusy = false
                return
            }
            self.completeFix(succeeded: result.succeeded)
        }
    }

    /// 把 fix 的原始输出存到日志目录(0600)。导出诊断时会脱敏后才进 zip。
    private static func persistFixOutput(_ output: String) {
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/claude-switcher", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("last-fix.log")
        try? output.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 修复「没跑起来」时,别只丢一句「脚本执行失败」让人自己猜。
    private static func fixLaunchFailureHint(_ raw: String) -> String {
        if raw.contains("退出码 2") {
            return raw + "\n提示：核心脚本版本过旧，请重新双击 INSTALL.command，或在终端运行升级命令。"
        }
        if raw.contains("python3") || raw.contains("command not found") {
            return raw + "\n提示：缺少可用的 python3。请安装 Xcode 命令行工具（xcode-select --install）后重试。"
        }
        return raw + "\n提示：修复在启动阶段就退出了。可点「导出诊断日志」，或用 diagnose-fix.sh 查看逐步输出。"
    }

    /// 收尾:脚本跑完了(退出码 0,或完整流程但收尾判失败)就按真实回执结算,
    /// 不把已修好的项一笔勾销,再复查一次让行状态回到现实。
    private func completeFix(succeeded: Bool) {
        phase = .ready
        // 还有行挂着「修复中」的转圈 —— 那说明脚本**从头到尾没提过这一项**
        // (它只对真动过手的组打勾)。转圈不会自己停,直接摘掉状态牌,
        // 让后面的复查给出真实结果 —— 不编「已修复」。
        for (name, state) in fixStates where state == .running { fixStates[name] = nil }
        let done = fixStates.filter { $0.value.isDone }.count
        let notes = fixStates.filter { $0.value.isNote }.count
        let failedRows = fixStates.filter { $0.value.isFailed }.map(\.key)
        // 「未能验证」单独数一句:它既不是修好了,也不是要用户动手。
        let noteTail = notes > 0 ? " · \(notes) 项未能验证" : ""
        if !failedRows.isEmpty {
            let names = failedRows.count <= 3
                ? failedRows.joined(separator: "、")
                : "\(failedRows.prefix(3).joined(separator: "、")) 等 \(failedRows.count) 项"
            fixNotice = done > 0
                ? "\(done) 项已修复 · \(names) 需要你手动处理\(noteTail)"
                : "\(names) 需要你手动处理\(noteTail)"
        } else if done > 0 {
            fixNotice = "\(done) 项已修复" + noteTail
        } else if notes > 0 {
            fixNotice = "\(notes) 项未能验证"
        } else if !succeeded {
            fixNotice = "修复已执行，但收尾复测未通过 · 详情见诊断日志"
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

    /// 把一行 `FIX:` 输出映射到具体检查项。脚本按组报结果(「时区/IPv6/保镖 ✓」),
    /// 所以一条输出可能同时点亮好几行。
    ///
    /// 判定顺序:先看 ✗(失败),再看 ✓(成功),最后看「无法/未能/请手动」这类
    /// 没有符号但明显是失败的人话 —— 脚本里确实有这种行(「FlClash 未能退出，
    /// 请手动退出后重试」),以前被整条丢掉,用户点了修复什么回执都没有。
    private func applyFixLine(_ line: String) {
        guard line.hasPrefix("FIX:") else { return }
        let text = String(line.dropFirst(4))
        // ⚠ 要**先判**,而且必须排在 failureWords 前面。
        // 它是「脚本跑完了,但这一项没法验证」—— 文案里天然会带「无法比对」
        // 这种字眼,先跑失败词表就会把它判成 ✗ 需手动,让用户去找一个
        // 根本不存在的手动动作。三种符号各管一档:
        //   ✓ 修好了 / ✗ 没修成、要你动手 / ⚠ 修没修不知道(非泄漏)
        if text.contains("⚠") {
            for name in Self.fixTargets(of: text) {
                fixStates[name] = .note(Self.fixNote(from: text))
            }
            return
        }
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
        if let i = text.firstIndex(where: { $0 == "✗" || $0 == "✓" || $0 == "⚠" }) {
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
        // 认「TUN 网卡」之前先把 **STUN** 这个词摘掉。
        //
        // 这是个子串事故:`STUN` 里含有 `TUN`,而 `text.contains("TUN")` 分不出来。
        // 实测看到的是——WebRTC 那行报「节点无 IPv4 出口，STUN 只回 IPv4，
        // 无法比对(非泄漏)」,于是**代理内核和 TUN 网卡两行同时被打上 ✗ 需手动**,
        // 并且把 WebRTC 的原因原样挂在它们名下。用户看到的是「内核和 TUN 都坏了,
        // 理由是 STUN 只回 IPv4」——三行说同一件事,而且其中两行是冤枉的。
        let probe = text.replacingOccurrences(of: "STUN", with: "")
        if probe.contains("代理内核") || probe.contains("TUN") {
            names += ["代理内核", "TUN 网卡"]
        }
        if text.contains("时区") { names.append("时区") }
        // 「地区」以前漏在这里:脚本会打 `FIX:地区格式 → en_US ✓`,但没有任何分支
        // 认领它,于是 fixStates 里那一行永远停在「修复中」,而 done 计数也把它漏掉 ——
        // 地区是唯一问题时,用户点完修复连一句回执都看不到。
        if text.contains("地区") { names.append("地区") }
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
        这是「Claude 环境检查器」的 AI 交接提示词。请先完整阅读交接文档，再开始安装、配置或排障。

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
        nodeSwitchNote = ""
        // 常驻后旧检查可能已经过期。每次切换都重新审计，不使用落盘的旧结果放行。
        checkEnvironment { passed in
            guard passed else {
                self.switchRequested = false; self.isBusy = false
                return
            }
            self.optimizeNodeForSwitch(for: target) { safeToSwitch in
                // 换完线路审计没过就不切账号：新账号第一次连上的就是这条出口，
                // 明知不干净还切过去，等于把风险转嫁给下一个身份。
                guard safeToSwitch else {
                    self.switchRequested = false; self.isBusy = false
                    return
                }
                self.performSwitch(target)
            }
        }
    }

    /// 换槽位前顺手把出口换成更干净的那条。
    ///
    /// 以前这条链上根本没有节点这一步：切账号只换磁盘目录，出口还是原来那条
    /// 49 分的线，用户得自己点工具栏的地球图标、再在面板里点一次「应用」。
    /// 现在扫描和应用接进切换流程，切完账号直接用上最干净的出口。
    ///
    /// 槽位如果绑了固定节点（`slot-node set B <节点名>`），那条优先 ——
    /// 绑定的意思是「这个槽位就走这条线」，不该被「本次分数最高的那条」盖掉。
    ///
    /// 三道闸一道都没放宽：
    ///   · 没绑定又没 BEST（比当前高 10 分以上）就直接过，不折腾；
    ///   · 动手前先 stopWatch()，`node-apply` 自己的执行门禁还会再判一次
    ///     「Claude 在不在跑」—— 开着 Claude 时它照样拒绝，这里只是失败退出；
    ///   · 换完线路必须重新跑完整审计，没过就不切账号（fail-closed）。
    ///
    /// 报告里的 GATE 是保守并集，有守护驻守时一定是 report-only；能不能真切
    /// 由执行门禁在停完守护之后判。所以这里不看 GATE。
    private func optimizeNodeForSwitch(for target: String,
                                       done: @escaping (Bool) -> Void) {
        guard coreAvailable() else { done(true); return }
        run(["slot-node", "get", target], timeout: 10) { [weak self] bound in
            guard let self else { done(true); return }
            let leaf = bound.succeeded ? Self.parseSlotNode(bound.output) : ""
            self.applyNodeForSwitch(bound: leaf, done: done)
        }
    }

    /// `slot-node get` 的格式是 selector<TAB>leaf<TAB>epoch，没绑定输出 NONE。
    static func parseSlotNode(_ output: String) -> String {
        guard let line = output.split(separator: "\n").first else { return "" }
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count >= 2, parts[1] != "NONE" else { return "" }
        return parts[1]
    }

    private func applyNodeForSwitch(bound: String, done: @escaping (Bool) -> Void) {
        // 扫一轮实测 13s 上下。不给话就是「点完槽位卡，界面僵在那儿」——
        // 切换本身只要一两秒，这段时间全花在扫描上，必须说清楚在等什么。
        banner = "正在扫描可用节点…"
        run(["node-scan"], timeout: 90) { [weak self] result in
            guard let self else { done(true); return }
            self.banner = ""
            // 扫描失败不该拦住切账号：这一步是顺手优化，不是前置条件。
            guard result.succeeded else {
                if Self.isStaleCore(result.output) {
                    self.coreOutdated = true
                    self.banner = "核心脚本版本过旧，节点扫描已跳过"
                    self.nodeSwitchNote = "核心脚本过旧，未扫描节点（请在节点面板查看升级方法）"
                } else {
                    self.nodeSwitchNote = "节点扫描失败，已跳过"
                }
                done(true)
                return
            }
            let info = Self.parseNodeScan(result.output)
            self.nodeScanInfo = info
            self.nodeCandidates = Self.parseNodeCandidates(result.output)
            self.applyNodeScan(info)
            self.nodeScanReport = Self.displayableNodeReport(result.output)
            // 绑定优先，其次才是「本次更优」。
            let leaf = bound.isEmpty ? (info["BEST"] ?? "") : bound
            guard !leaf.isEmpty else {
                done(true)
                return
            }
            let note = bound.isEmpty ? "已切到更干净节点 \(leaf)" : "已切到槽位绑定节点 \(leaf)"
            banner = "正在切到 \(leaf)…"
            self.stopWatch()
            // 显式把叶子交给 node-apply：绑定时它可能不是本次的 BEST。
            self.run(["node-apply", leaf], timeout: 120) { [weak self] applied in
                guard let self else { done(true); return }
                self.banner = ""
                let after = Self.parseNodeScan(applied.output)
                self.nodeScanInfo = after
                self.applyNodeScan(after)
                self.nodeScanReport = Self.displayableNodeReport(applied.output)
                guard applied.succeeded else {
                    // 切节点失败不拖死账号切换：出口没变，账号照切，只把原因
                    // 留在 note 里。守护刚被停过，必须重新审计把它拉回来。
                    self.nodeSwitchNote = "节点未切换（\(Self.failureLine(applied.output))）"
                    self.checkEnvironment { _ in done(true) }
                    return
                }
                self.nodeSwitchNote = note
                self.checkEnvironment { ok in done(ok) }
            }
        }
    }

    /// 从脚本输出里捞第一条 FAIL: 的原因，捞不到就给个兜底。
    static func failureLine(_ output: String) -> String {
        for line in output.split(separator: "\n") where line.hasPrefix("FAIL:") {
            return String(line.dropFirst(5))
        }
        return "未知原因"
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
            // 节点那句话拼在回执里,而不是塞进 banner:切换本身成功与否是主句,
            // 换没换线路是附带信息,不该抢掉「已切换到账号 X」。
            var note = extra
            if !self.nodeSwitchNote.isEmpty {
                note = note.isEmpty ? self.nodeSwitchNote : note + " · " + self.nodeSwitchNote
            }
            self.note = note
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

    // MARK: 表面
    //
    // 只有两种:平底色 + 白卡。没有渐变、没有光晕、没有第三种表面。
    // 工具界面是平的 —— 一层 linear 渐变加一层 radial 光晕,是「展示页」的手法,
    // 每天看一百遍的人只会觉得脏。
    //
    // 底色的亮度是按参照图实测定的,不是凭感觉:参照图整页背景的区域中位数是
    // (249,248,246)。上一版 #F4F2EE 是 244,比它深 5 级 —— 一整屏铺开之后,
    // 白卡像是浮在一块米色的板子上,而不是浮在「纸白」上,所以整体偏重。
    // 抬到 249 之后白卡与底色的差从 11 级降到 6 级,卡片之间的分离改由阴影承担
    // （这也是参照图的做法:它的底 249 / 卡 251 只差 2 级,全靠影子分层）。
    static let bg = dual((0.976, 0.973, 0.965), (0.106, 0.102, 0.094))          // #F9F8F6 / #1B1A18
    static let card = dual((1.000, 1.000, 1.000), (0.176, 0.169, 0.157))        // #FFFFFF / #2D2B28
    /// 卡内凹槽:空槽位、图标块、输入框。比卡片低一档,不描边。
    static let inset = dual((0.965, 0.957, 0.945), (0.137, 0.132, 0.122))       // #F6F4F1 / #23211F
    /// 唯一的分隔线颜色。用得越少越好 —— 分组靠间距,不靠线。
    static let hairline = dual((0.910, 0.898, 0.882), (0.216, 0.208, 0.196))    // #E8E5E1 / #373532

    // MARK: 三级灰(每一档都过 WCAG AA 4.5:1)
    //
    // 只有三档。之前是「一个 muted 加十几种 opacity」,同一屏里出现五六种灰度,
    // 眼睛分不清哪一档代表什么,整屏就显脏。
    //
    // 三级之间要**等距**,不是「一级很深、后两级挤在一起」。原来 muted 是 6.8:1,
    // 换成亮度看:ink L*11 / muted L*39 / faint L*49 —— 第一跳到 28 级、第二跳只有
    // 10 级。屏幕上的结果就是「标题是黑,其余全是差不多的浅灰」,中间那一级立不住,
    // 读起来像只有两级。这正是「文字颜色的层级不够明显」的来源。
    //
    // 现在把 muted 往背景反方向推(A 候选),让三档在对比度上近似**每档减半**:
    //   浅色  16.8 : 8.8 : 4.6   亮度 L* 11 / 32 / 49  → 跳 21 / 17
    //   深色  12.3 : 7.5 : 4.7   亮度 L* 95 / 77 / 61  → 跳 18 / 15
    // 浅色往深推、深色往浅推 —— 同一句「次级色远离底色」,两种外观都是一条规则。
    //
    // faint 不能更浅:它是 12–13pt 的注脚,4.6:1 已经是 AA 小字的下限。
    // 所以能动的只有中间那一档,这也是它必须动的原因。
    static let ink = dual((0.122, 0.114, 0.102), (0.949, 0.937, 0.914))         // #1F1D1A / #F2EFE9 16.8:1
    static let muted = dual((0.310, 0.290, 0.267), (0.769, 0.737, 0.702))       // #4F4A44 / #C4BCB3  8.8:1
    static let faint = dual((0.478, 0.455, 0.424), (0.604, 0.576, 0.541))       // #7A746C / #9A938A  4.6:1

    // MARK: 语义色
    //
    // 只落在小号文字和图标上,**不铺底、不做彩色 pill**。
    // 铺底的彩色块是最典型的「AI 感」:颜色被当成装饰,一屏五六个色块,
    // 真正异常的那条反而淹在里面。
    static let brand = dual((0.847, 0.447, 0.329), (0.878, 0.541, 0.424))       // #D87254 / #E08A6C 图标/圆环
    static let brandText = dual((0.706, 0.325, 0.184), (0.910, 0.631, 0.514))   // #B4532F / #E8A183 4.98:1
    static let ok = dual((0.180, 0.490, 0.322), (0.435, 0.749, 0.557))          // #2E7D52 / #6FBF8E 5.2:1
    static let warn = dual((0.651, 0.373, 0.055), (0.878, 0.643, 0.361))        // #A65F0E / #E0A45C 5.0:1
    static let bad = dual((0.761, 0.282, 0.212), (0.878, 0.439, 0.361))         // #C24836 / #E0705C 4.9:1

    // 旧名字保留,只为不惊动尚未迁到的角落;新代码不要再引用。
    static let bgTop = bg
    static let bgBottom = bg
    static let iconWell = inset
    static let slotWell = inset
    static let divider = hairline
    static let cardBorder = hairline
    static let terracotta = brand
    static let terracottaDeep = brandText
    static let terracottaTint = brand.opacity(0.10)
    static let success = ok
    static let warning = warn
    static let warningBorder = hairline
    static let error = bad
}

// MARK: - 字阶
//
// 一套字号，五个档位；一套字重，三档；行距按中文给。
// 下面是**唯一真源**，界面里不再出现裸的 size/weight 字面量。
//
// 【一】字体族
//   SF Pro（拉丁与数字）+ PingFang SC（中文），两者都是系统字体、系统自动按字符
//   切换，不打包任何字体文件 —— App 里嵌字库等于分发字体，中文字体动辄几 MB，
//   授权和体积两道坑，这里一道都不碰。
//   唯一的例外是**显示级数字**（圆环里的分数、槽位字母 A/B/C）用 SF Rounded：
//   大字号下圆角数字的轮廓更饱满，和圆环的圆是同一套形状语言。它不是第二套
//   字体，是同一家族的 rounded 变体，且只出现在这两处。
//
// 【二】字号：本机实测 NSFont.preferredFont(forTextStyle:) 的值
//   largeTitle 26 / title1 22 / title2 17 / title3 15
//   headline 13 bold / body 13 / callout 12 / subheadline 11 / caption 10
//
//   26  semibold  主数字（圆环分数，一屏只有一个）   = largeTitle
//   22  semibold  次级数字（弹窗里的单指标）         = title1
//   17  semibold  页面 / 卡片 / 分区标题             = title2
//   13  →        正文、行名、读数                   = body
//   12  →        元信息、时间戳、标签               = 系统 11 / 10，中文会糊，守 12
//
//   12 与 13 只差 1pt，它们**不算两个层级**：13 是「要读的内容」，12 是「注释」，
//   分开靠的是颜色和位置，不是字号。真按字阶算，一屏只有 26 / 22 / 17 / 13 四级。
//
// 【三】字重只有三档：semibold(600) 标题 / medium(500) 强调 / regular(400) 正文。
//   没有 bold、没有 light。小字上尤其不能用 semibold —— 12pt 的中文一加粗就糊成一团。
//
// 【四】行距按中文给：汉字是密实的方块，同样行高在中文里比英文挤。
//   13pt 正文行距 4（≈1.5 倍行高），12pt 注释行距 3。英文界面常用的 1.2 倍
//   放到中文这里会粘成一坨。
//
// 上一版是 32 / 24 / 17 / 14 / 12：正文比系统大 1pt、主数字大 6pt，
// 整屏比原生窗口「胖」一圈 —— 这就是「文字大小和系统不一致」的来源。
enum Type {
    // 字号（需要参与布局计算的地方用它，别的地方直接用下面的 Font）
    static let heroNumberSize: CGFloat = 26
    static let metricSize: CGFloat = 22
    static let titleSize: CGFloat = 17
    static let bodySize: CGFloat = 13
    static let microSize: CGFloat = 12

    // 行距
    static let lineGap: CGFloat = 4        // 13pt 正文
    static let microLineGap: CGFloat = 3   // 12pt 注释

    // 显示级（唯一用 SF Rounded 的两处）
    static let heroNumberFont = Font.system(size: heroNumberSize, weight: .semibold, design: .rounded)
    static let metricFont = Font.system(size: metricSize, weight: .semibold, design: .rounded)
    static let slotLetterFont = Font.system(size: titleSize, weight: .semibold, design: .rounded)

    // 标题 / 强调 / 正文 / 注释
    static let titleFont = Font.system(size: titleSize, weight: .semibold)
    static let bodyStrongFont = Font.system(size: bodySize, weight: .semibold)
    static let labelFont = Font.system(size: bodySize, weight: .medium)
    static let bodyFont = Font.system(size: bodySize)
    static let microFont = Font.system(size: microSize)
    static let microLabelFont = Font.system(size: microSize, weight: .medium)

    // 等宽：只给「逐字符对齐本身就是信息」的东西 —— 时间戳、HTTP 状态码、
    // 域名、日志块。**界面里的值、读数、计数一律用上面的比例字 + .monospacedDigit()**。
    //
    // 上一版是按内容判定的：字符串里有 . : / 就走等宽。结果同一列里
    // 「Clash Verge 运行中」是比例字、「144.172.103.106/US」是等宽 —— 一列两种字形，
    // 扫下来就是「不齐」。字形是**位置**的属性，不是内容的属性：
    // 同一列只用一种字形，数字宽窄由 tabular 数字解决，不需要换字体。
    static let bodyMono = Font.system(size: bodySize, design: .monospaced)
    static let microMono = Font.system(size: microSize, design: .monospaced)
    static let microMonoLabel = Font.system(size: microSize, weight: .medium, design: .monospaced)
}


// MARK: - 几何
//
// 三档圆角 + 一套间距节奏。之前是 13 档圆角和 23 种 padding ——
// 「处处 20px」本身就是 AI 感:每样东西看起来同等重要。
enum Geo {
    static let cardRadius: CGFloat = 22    // 大卡
    static let innerRadius: CGFloat = 14   // 卡内块 / 图标块 / 空槽位
    static let controlRadius: CGFloat = 10 // 按钮 / 控件 / 行底
    /// 组内
    static let tight: CGFloat = 6
    static let inline: CGFloat = 10
    /// 组间
    static let group: CGFloat = 32
    static let gutter: CGFloat = 28        // 主区左右留白
}

// MARK: - 节奏
//
// 清单类界面「齐不齐」几乎全看两件事:所有图标在不在同一条竖轴上,
// 所有二级文字有没有缩到同一个位置。所以这里不是一堆散落的 padding,
// 而是一组能相乘的关系:
//
//   卡片左右内边距(cardH) + 图标列(icon) + 图标与文字之间(gap) = 文字轴
//
// 标题、行名、第二行说明全部落在这一条轴上,读者眼睛只需要跟着一列往下走。
// 之前第二行说明缩进 26,标题缩进 16,行名缩进 27 —— 三条不同的轴,
// 每行都在向左轻微地漂,整体就「乱」,但说不出哪里乱。
enum Rhythm {
    static let icon: CGFloat = 28          // 图标列宽：卡头是 28×28 块（规范 §3），行内符号居中于同一列
    static let gap: CGFloat = 8            // 图标 ↔ 文字
    static let cardH: CGFloat = 14         // 卡头左右
    static let rowH: CGFloat = 8           // 行左右(悬停底色用)
    static let listInset: CGFloat = 6      // 行容器相对卡片的内缩
    static let rowV: CGFloat = 10          // 行上下 —— 呼吸感主要来源
    static let cardTop: CGFloat = 18
    static let cardBottom: CGFloat = 14
    // 文字轴 = cardH + icon + gap = 50。上面那行关系式就是它,不再单列常量 ——
    // 原来这里有个没人用的 `textAxis = 48`,和真值差 2:一个不参与布局的常量
    // 写着「文字轴 = 48」,是账本和真源不一致,已删。
    // 第二行说明的缩进。**必须是 icon + gap**,不能手写 34 ——
    // 34 比行名左 2pt(量过:行名墨迹 50.0pt、说明 49.0,同号中文比下来就是 2),
    // 一行说明整段向左错半步,十几行叠起来左边缘就发毛。
    static let rowIndent: CGFloat = icon + gap
    /// 行名列宽。值列从这一列之后起排 —— 名字长短不再影响第二列的位置。
    static let nameColumn: CGFloat = 96
    // 这里原来还有 actionColumn = 44（行尾固定槽宽）。删掉的原因是它把
    // 「值」和「对勾」拆成了两条竖线：值 427、勾 478.5，差 51pt。
    // 行尾现在按内容取宽，值和勾共用一条右导轨。
}

// MARK: - 动效
//
// 三种,不是十二种。工具界面的动效只用来「说明状态变了」,
// 不是用来表演的:0.12 是颜色/hover,0.2 是状态切换,0.35 是强调(圆环、进度)。
// 循环动画(扫描弧、心跳涟漪)单独放,它们表达「正在进行」,不属于过渡。
enum Motion {
    /// 规范 §4：过渡 ≤140ms，且只过渡颜色类属性。
    /// 圆环、进度条这类「数值在变」的动画也收进这个区间 ——
    /// 0.35s 会让分数看起来像在表演，而不是在更新。
    static let micro: Double = 0.10
    static let state: Double = 0.14
    static let emphasis: Double = 0.14
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    // 一个平色,仅此而已。
    //
    // 原来这里是「垂直渐变 + 顶部陶土色径向光晕」—— 那是落地页的打光手法。
    // 工作台背景只需要一个值:它背后没有任何需要被照亮的东西,光晕只是
    // 让每张卡的边缘脏一点,并且逼着人眼去解析一团没有信息量的明暗。
    var body: some View {
        ClaudeTheme.bg
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
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(disabled ? ClaudeTheme.faint : (isHovered ? ClaudeTheme.ink : ClaudeTheme.faint))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                        .fill(isHovered && !disabled ? ClaudeTheme.inset : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous))
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

    // 主按钮是墨底白字，不是橙底白字。
    // 规范只允许「主按钮」有实色填充，且明确是墨底 —— 橙色留给「需要你注意」
    // 的小字和图标。一个橙色大按钮会把整屏的语义色预算一次花光。
    private var textColor: Color {
        if prominent { return ClaudeTheme.bg }          // 墨底上的字用页面底色（反色）
        return ClaudeTheme.brandText
    }

    private var fillColor: Color {
        if prominent { return ClaudeTheme.ink }
        // 行内的 quiet 按钮平时只有文字；hover 时给一层极浅底，而不是黑块。
        if hovered { return ClaudeTheme.inset }
        return quiet ? Color.clear : ClaudeTheme.inset
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Type.labelFont)
                .foregroundColor(textColor)
                .padding(.horizontal, prominent ? 12 : 9)
                .padding(.vertical, prominent ? 6 : 4)
                // 方角 10,不做胶囊。整屏唯一一块实色填充就是主按钮 ——
                // 规范里只允许「主按钮」有底,其余一律文字。
                .background(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                             style: .continuous).fill(fillColor))
                .contentShape(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        // 行内按钮的「字」要和一列结论共用同一条右导轨。
        //
        // 量过：右卡所有行尾的右边缘落在 953–954.5pt，只有「修复」停在 945.5pt ——
        // 差 8.5pt，正好是 label 的 9pt 横向内边距。也就是说标题都对齐了，
        // 唯独「可以被点的那一行」往里缩了一格；一列扫下来它就是那条歪的。
        //
        // 不能把内边距直接删掉：那 9pt 是悬浮高亮的呼吸位，也是点击区。
        // 负的尾部内边距 = 布局仍占原来的宽度，绘制往外顶 9pt ——
        // 9 < 行的右侧留白（rowH 8 + listInset 6 = 14），所以既不会碰到卡片边缘，
        // 也不会吃到隔壁内容。只在行内（quiet）生效，主按钮不动。
        .padding(.trailing, quiet ? -9 : 0)
        .onHover { inside in
            withAnimation(.easeOut(duration: Motion.micro)) { hovered = inside }
        }
        // 按下不再缩放。位移动效是演示稿的语言;一个按钮按下去,
        // 用户需要的是「它响应了」,而不是「它弹了一下」。
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
                .font(Type.microFont)
                .foregroundColor(hovered ? ClaudeTheme.ink : ClaudeTheme.faint)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: Motion.micro)) { hovered = inside } }
        .accessibilityLabel(label)
    }
}

/// 统一的卡片壳:一个圆角面,靠「面」本身的明度差和一层极轻的投影浮起来。
/// 不用描边 —— 一圈 1pt 的线在 1000pt 宽的窗口里会把每张卡切成方盒子,
/// 整屏看着像表格;去掉之后卡片之间靠留白和层次说话,才是「面」而不是「框」。
/// 全 App 唯一的卡片外观：22pt 圆角 + 一层「大半径、下沉」的柔影，无描边。
///
/// 影子的三个参数不是拍脑袋来的。用设计参照图逐像素量了卡片下沿的衰减曲线：
/// 参照图阴影相对局部底色只有 Δ4–7，但**扩散到 38pt 才归零**；
/// 上一版是 Δ7、只扩散 16pt —— 深度一样、长度只有一半，所以每一圈都像
/// 一条贴边的深色线，这就是「生硬」的来源。
///
/// 解法是「加大半径 + 加大下移 + 压低透明度」：r20/y12/.05 实测下沿扩散 33pt
/// （原来 16pt），峰值仍是 Δ8 没有变重，上沿只剩 Δ3 的一点余量 —— 影子从
/// 「描了一圈边」变成「落在卡片下面的一团」。
///
/// 之前主界面和延迟面板各写各的 —— 主界面是「双层影 + 发丝线描边」，
/// 面板是「单层 r9 影、不描边」，两张卡片挨着看就是两种材质。
/// 收成一个 modifier 之后，改一次全局生效，也免得再各调各的又对不上。
private struct CardSurface: ViewModifier {
    var radius: CGFloat = Geo.cardRadius
    var fill: Color = ClaudeTheme.card
    var shadowRadius: CGFloat = 20
    var shadowY: CGFloat = 12
    var shadowAlpha: Double = 0.05

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .shadow(color: .black.opacity(shadowAlpha), radius: shadowRadius, x: 0, y: shadowY)
    }
}

extension View {
    func cardSurface(radius: CGFloat = Geo.cardRadius,
                     fill: Color = ClaudeTheme.card,
                     shadowRadius: CGFloat = 20,
                     shadowY: CGFloat = 12,
                     shadowAlpha: Double = 0.05) -> some View {
        modifier(CardSurface(radius: radius, fill: fill,
                             shadowRadius: shadowRadius, shadowY: shadowY, shadowAlpha: shadowAlpha))
    }
}

// MARK: - 品牌标记
//
// 盾牌 + 对号。和 App 图标（assets/icon-gen.swift）用的是同一组控制点，
// 只是那边按 1024 设计稿、这边按 0–1 归一化。改一处必须同步另一处。

private struct GuardShield: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.500, 0.000))
        path.addCurve(to: p(1.000, 0.143), control1: p(0.708, 0.019), control2: p(0.943, 0.075))
        path.addLine(to: p(1.000, 0.513))
        path.addCurve(to: p(0.500, 1.000), control1: p(1.000, 0.702), control2: p(0.802, 0.887))
        path.addCurve(to: p(0.000, 0.513), control1: p(0.198, 0.887), control2: p(0.000, 0.702))
        path.addLine(to: p(0.000, 0.143))
        path.addCurve(to: p(0.500, 0.000), control1: p(0.057, 0.075), control2: p(0.292, 0.019))
        path.closeSubpath()
        return path
    }
}

// 原来这里还有一枚 GuardCheck（对号）。换成星标之后它没有任何引用点了 ——
// 留着就是一段「看着像在用」的死代码，删掉。对号的路径还在 assets/icon-gen.swift
// 的历史里（以及下面 GuardMark 的注释里），要回滚不用重画。

/// Claude 的星标。
///
/// **几何是从官方图标上量下来的,不是凭印象画的。** 取 Claude.app 里那份
/// electron.icns 的 1024 稿做极坐标扫描(每 0.25° 找白色最远半径 → 半径剖面,
/// 峰即射线;再在固定半径横向扫过每根射线,把角宽换成线性宽度),得到:
///   · **12 根**,角度不等分(8.5°…333°)。等分看着像太阳/齿轮,不均匀才是这枚标;
///   · 每根**等宽**(不是花瓣形),线性宽度 0.09R…0.21R;
///   · 端头是斜切的平口,最后约 1.5% 半径收口;
///   · 中心一块实体毂,半径约 0.30R。
/// 用像素重合度(IoU)把参数打到 0.86 —— 再往上就是在拟合抗锯齿噪点了。
///
/// 上一版是「6 根、圆头、靠描边」的近似,理由写在当时:6 根在 8pt 上比 9 根清楚。
/// 但用户一眼就看出「中间那不是 Claude 的标」—— 这枚标记的品牌位价值高于那点
/// 小尺寸清晰度,而且 12 根在 20pt 上并没有比官方更糊。
private struct ClaudeBurst: Shape {
    /// (角度°, 长度/最长, 线性宽度/最长, 端头斜切方向)
    private static let rays: [(deg: CGFloat, len: CGFloat, w: CGFloat, slant: CGFloat)] = [
        (8.50, 0.881, 0.141, 0.6), (40.25, 0.908, 0.205, -0.5),
        (79.75, 0.881, 0.131, 0.5), (103.00, 0.899, 0.131, -0.7),
        (133.25, 0.908, 0.099, 0.4), (149.25, 0.881, 0.146, -0.4),
        (184.75, 0.908, 0.115, 0.7), (214.00, 0.905, 0.115, -0.6),
        (237.25, 0.875, 0.131, 0.4), (271.75, 0.926, 0.099, -0.5),
        (303.25, 0.938, 0.162, 0.6), (333.00, 1.000, 0.183, -0.4),
    ]

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let widthScale: CGFloat = 1.03, hub: CGFloat = 0.30
        let bevel: CGFloat = 0.015, capRatio: CGFloat = 0.45
        var path = Path()
        // **这里不放中心毂。** 毂由调用方另画一个圆,原因写在 GuardMark 里:
        // SwiftUI 的 `addEllipse` 和下面这些手写多边形的绕向相反,非零绕数下
        // 重叠区会被**抵消**,中心于是出现一个深色小洞(实测就是这样)。
        for ray in Self.rays {
            let a = CGFloat.pi / 2 - ray.deg * .pi / 180   // 0° = 正上,顺时针
            let tip = ray.len * R
            let w = ray.w * widthScale * R
            func q(_ r: CGFloat, _ off: CGFloat) -> CGPoint {
                CGPoint(x: c.x + cos(a) * r + cos(a + .pi / 2) * off,
                        y: c.y + sin(a) * r + sin(a + .pi / 2) * off)
            }
            let shoulder = tip - bevel * R
            let inner = hub * R * 0.6
            path.move(to: q(inner, -w / 2))
            path.addLine(to: q(shoulder, -w / 2))
            path.addLine(to: q(shoulder + ray.slant * bevel * R * 0.5, -w / 2 * capRatio))
            path.addLine(to: q(shoulder - ray.slant * bevel * R * 0.5,  w / 2 * capRatio))
            path.addLine(to: q(shoulder, w / 2))
            path.addLine(to: q(inner, w / 2))
            path.closeSubpath()
        }
        return path
    }
}

/// 界面里的品牌标记。对号用底色描一遍，看上去就等于「挖空」——
/// 因为标记坐在底色上，用同一个色去描边和真打洞的效果一样，
/// 比在 SwiftUI 里做布尔运算简单，也不会碰上自交假岛那种坑。
///
/// 上一版是「墨色圆角方块 + 白盾 + 墨色对号」，缩到 20pt 出问题：
/// 盾牌只占方块 13.5pt，对号又吃掉盾牌内宽的 18%，中间那圈白只剩 2pt ——
/// 描边一糊，看着就是**一圈白线**，也就是「线框感」。三件套在 20pt 这个尺寸上
/// 根本装不下。
///
/// 现在只留两件：盾牌自己就是标记（撑满 20pt 高，墨色实心），**里面挖一枚 Claude 星标**。
/// 实心块 + 洞，没有第三个元素，也就没有可以糊成线的那一圈。
///
/// 为什么把对号换成星标:这一屏是「给 Claude 守门的工具」,标题栏那枚标记是用户
/// 唯一会正面看一眼的品牌位。对号只说明「检查过了」,换个工具也一样;星标是
/// Claude 的标,一眼能认出这是给谁用的。守护的意思由**盾牌**承担,不靠对号。
///
/// 星标画在盾牌内腔偏上:盾牌是上宽下尖的梨形,几何中点在视觉上偏低。
private struct GuardMark: View {
    var box: CGFloat
    /// 盾牌在图标里是 424×530（宽高比 0.8），拉成正方形会变胖，所以按比例给宽度。
    var body: some View {
        ZStack {
            GuardShield().fill(ClaudeTheme.ink)
            // 星芒改成实心形状之后不能再「描边挖空」——它本来就是一整块。
            // 用底色去填,坐在墨色盾牌上就等于挖出了一个洞:和图标那边
            // (拿渐变当裁切区重画一遍)是同一个做法,只是这里底色是纯色。
            //
            // 毂和射线分两次画。塞进同一个 Shape 试过:SwiftUI 的 addEllipse
            // 与手写多边形绕向相反,非零绕数下重叠区相互抵消,中心会留一个
            // 深色小洞(20pt 上就是一个黑点,像标中间被打了个洞)。
            // 同一个底色填两次,视觉上就是并集,不吃绕数规则的亏。
            Circle()
                .fill(ClaudeTheme.bg)
                .frame(width: box * 0.52 * 0.30, height: box * 0.52 * 0.30)
                .offset(y: -box * 0.04)
            ClaudeBurst()
                .fill(ClaudeTheme.bg)
                .frame(width: box * 0.52, height: box * 0.52)
                .offset(y: -box * 0.04)
        }
        .frame(width: box * 0.8, height: box)
    }
}

private struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .cardSurface()
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
        if vm.intercepted { return vm.interceptionShortTitle }
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
        HStack(spacing: Geo.inline) {
            glyph

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Type.bodyStrongFont)
                    .foregroundColor(fresh ? ClaudeTheme.ink : tone)
                Text(subtitle)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            // 两个时间戳合成一行。本来就都是「多久以前」的同一个格式,竖着码两行
            // 只是为了对齐,却让这条带子白白高了 14pt —— 而它是全屏最次要的信息。
            HStack(spacing: 4) {
                Text(dutyText)
                    .foregroundColor(ClaudeTheme.faint)
                Text("·")
                    .foregroundColor(ClaudeTheme.faint)
                Text(beatText)
                    .foregroundColor(fresh ? ClaudeTheme.ok : ClaudeTheme.faint)
            }
            .font(Type.microFont)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        // 它现在是一张独立的卡，内边距由调用点给（跟着「卡片左右 32」的规矩走，
        // 否则这枚图标会比上面那枚圆环左边缺 18pt，两张卡的左边缘对不上）。
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // 一块实心底盘，心跳一到就往外扩一圈再收回来。
            //
            // 上一版这里是三层线条：1.6pt 的扫描弧 + 1.1pt 的涟漪描边 + 半填充盾牌。
            // 30pt 的方块里塞三根 1pt 多的线，缩进菜单栏那种尺寸就只剩线框感 ——
            // 而且「在动」这件事，实心块的呼吸比细弧线更明显，还不用三条动画。
            Circle()
                .fill(tone.opacity(ripple ? 0.05 : 0.14))
                .frame(width: 30, height: 30)
                .scaleEffect(ripple ? 1.45 : 1)

            Image(systemName: vm.intercepted ? "hand.raised.fill" : "shield.fill")
                .font(Type.bodyStrongFont)
                .foregroundColor(tone)
        }
        .frame(width: 30, height: 30)
    }

    /// 一圈涟漪。1.1s 扩到 1.55 倍并淡出,比扫描弧快一个量级 ——
    /// 快的那一下是「刚刚」,慢的那圈是「一直在」。
    private func pulse() {
        ripple = false
        // ambient: 心跳涟漪是**循环动画**（每秒扩散一圈），不是状态过渡。
        // 规范 ≤140ms 管的是 hover/切换这类状态变化；把一圈涟漪压到 140ms，
        // 它就不再是「一直在守着」，而是「闪了一下」。
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

    /// 脚本只会用这几个词表达「这一项没事」。它们不携带任何新信息,
    /// 界面不该把同义词再抄一遍 —— 空串也算,那是脚本没给 detail。
    private static let confirmationWords: Set<String> = ["", "通过", "已关闭", "走隧道"]

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
        .animation(.easeInOut(duration: Motion.state), value: vm.phase)
        .animation(.easeInOut(duration: Motion.state), value: vm.intercepted)
        .animation(.easeInOut(duration: Motion.micro), value: vm.fixNotice)
        .sheet(isPresented: $showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .sheet(isPresented: $vm.showSettingsSheet) { CheckSettingsView(vm: vm) }
        .sheet(isPresented: $showNotice) { NoticeView() }
        .sheet(isPresented: $showFingerprint) { FingerprintView(text: vm.fingerprint) }
        .sheet(isPresented: $showHistory) { IncidentHistorySheet(vm: vm) }
        .sheet(isPresented: $showLatency) { LatencyInsightSheet(vm: vm) }
        .sheet(isPresented: $vm.showNodeScan) { NodeScanSheet(vm: vm) }
    }

    /// 主区内容。窗口高度就是按它量出来的,所以量高模式下必须和滚动模式
    /// 用同一份布局,否则量到的和看到的差一截。
    private var mainContent: some View {
        // 组间 32、组内 10 —— 差 3.2 倍。之前是 22 和 11,所有间距都在 20 上下,
        // 每样东西看起来同等重要,眼睛找不到分组。
        VStack(alignment: .leading, spacing: Geo.group) {
            heroCard
            accountSection
            // 两列而不是一列:16 行竖着堆,窗口要么高到离谱,要么矮到要滚动。
            // 等宽由 checkCard 末尾的 maxWidth: .infinity 保证（实测两卡均 464.5pt、间隙 10.5pt）,
            // 这里不要再包一层 frame —— 同一件事说两遍,量高时反而会改到提案高度。
            HStack(alignment: .top, spacing: Geo.inline) {
                checkCard("核心安全基线", subtitle: "不可关闭 · 每次启动都校验", rows: hardRows)
                checkCard("加固与提示", subtitle: "可关闭 · 关闭后不参与拦截", rows: softRows)
            }
        }
        .padding(.horizontal, Geo.gutter + 2)
        .padding(.top, 10)
        .padding(.bottom, Geo.group)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            // 品牌标记。原来是 SF Symbol 的盾牌 —— 那是系统图标，不是我们的图形，
            // 而且和 App 图标不是同一个东西（图标里是一枚带对号的盾，这里是一枚半填充盾），
            // 两处对不上。现在两处画的是同一个路径。
            //
            // 20pt 上不再套「墨色方块 + 白盾」两层：那个组合在 20pt 会糊成一圈白线，
            // 看着像线框图标。盾牌自己就是标记，实心墨色，对号是挖空的一笔。
            GuardMark(box: 20)
                .frame(width: 20, height: 20)

            Text("Claude 环境检查器")
                .font(Type.titleFont)
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
                HStack(alignment: .center, spacing: Geo.group) {
                healthRing

                VStack(alignment: .leading, spacing: 7) {
                    // 17pt 的标题和 13pt 的徽章放一行时，默认的垂直居中会让徽章
                    // 浮在标题的视觉中线上 —— 两行字各有各的基线，看着像没对齐。
                    // 按首行基线对齐，两个不同字号才站在同一条线上。
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(heroTitle)
                            .font(Type.titleFont)
                            .foregroundColor(ClaudeTheme.ink)
                            .lineLimit(1)
                        heroBadge
                    }
                    // 结论行原来是 17pt medium —— 和标题同号，两行一样大挤在一起，
                    // 眼睛不知道先读哪行。现在降回正文 13pt：标题 17 回答「什么状态」，
                    // 结论 13 + 状态色回答「为什么」，元信息 12。
                    // 17 / 13 / 12 正好是系统的 title2 / body / caption 三档。
                    Text(heroVerdict.text)
                        .font(Type.labelFont)
                        .foregroundColor(heroVerdict.color)
                        .lineLimit(2)
                        // 结论会折成两行，中文必须给行距，否则第二行贴着第一行。
                        .lineSpacing(Type.lineGap)
                        .fixedSize(horizontal: false, vertical: true)
                    heroMetaRow
                }

                Spacer(minLength: 16)

                HStack(spacing: 10) {
                    // 检查是这个工具的主动作,给它一个正经按钮 —— 工具栏上那个
                    // 11pt 的刷新图标,用户根本不会去找。
                    Button { vm.refresh() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text(vm.phase == .checking ? "检查中…" : "重新检查")
                                .font(Type.labelFont)
                        }
                        .foregroundColor(ClaudeTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // 方角 10,不做胶囊。胶囊是消费级 App 的默认形状,
                        // 工具里的按钮应该是方角 —— 它要看起来能按,不是能捏。
                        .background(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                                     style: .continuous)
                            .fill(ClaudeTheme.inset))
                        .contentShape(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                                       style: .continuous))
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
            // 上松下紧：上面是结论区，下面是同一张卡里的守护面。
            // 32 / 20 的不对称不是随手给的 —— 守护面自己还有 12 的内边距，
            // 加起来下沿才和上沿的 32 差不多，视觉上不会「底边更挤」。
            .padding(EdgeInsets(top: Geo.group, leading: Geo.group,
                                bottom: 20, trailing: Geo.group))
            .frame(maxWidth: .infinity, alignment: .leading)

            // 「已守护」是结论,这一条是凭据 —— 结论和「凭什么」挨着放,
            // 用户才不用猜这个绿字是哪儿来的。
            //
            // 用**一块内凹面**而不是一条发丝线来分隔：线是「线框」那套语言，
            // 一屏里每多一条 1pt 的线，界面就多一分图纸感。内凹面本身就是一个
            // 已经存在的表面色（inset），不新增颜色，只是把「换了一件事」写成
            // 「换了一层」。
            GuardBand(vm: vm)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Geo.innerRadius, style: .continuous)
                        .fill(ClaudeTheme.inset)
                )
                .padding(.horizontal, Geo.group)
                .padding(.bottom, Geo.group - 10)
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
            return Verdict(short: s.badge, text: "\(vm.interceptionShortTitle) · \(interceptedReason)", color: s.color)
        }
        switch vm.phase {
        case .checking, .fixing, .switching:
            return Verdict(short: s.badge, text: s.headline, color: ClaudeTheme.terracotta)
        case .ready, .done, .failed:
            return Verdict(short: s.badge, text: s.headline, color: s.color)
        }
    }

    private var passedCount: Int {
        vm.rows.filter { $0.state == .ok }.count
    }

    private var healthRingProgress: CGFloat {
        if vm.rows.contains(where: { $0.state == .pending }) && vm.phase == .checking { return 0 }
        guard !vm.rows.isEmpty else { return 0 }
        return CGFloat(passedCount) / CGFloat(vm.rows.count)
    }

    private var healthRingColor: Color {
        // 颜色只回答「能不能启动」。以前按分数分档（≥85 绿 / 60–84 琥珀 / <60 红），
        // 于是「IP 纯净度偏低、分数掉到 80、徽章明明写着可以启动」这一屏里，
        // 环套的是琥珀色 —— 两句话互相打架，用户只会记住「环是橙的，不行了」。
        // 2026-11-06 用户原话：「不要用分数让别人误会，IP 非常不干净按道理还是能启动」。
        // 分数是 IP 信誉的宽口径度量，和「能否启动」本来就会背离（README 里写着
        // 65 分的代理会被硬门槛排除、49 分的机房反而可用），不该拿它当红绿灯。
        healthSummary.color
    }

    /// 圆环 + 通过项数。这里**不显示分数**。
    ///
    /// 分数是一个「软信号加权」的合成分，而这一屏真正要回答的只有一件事：
    /// 现在能不能启动 Claude。把两者塞进同一个 80pt 的数字里，必然误导 ——
    /// 实测场景：IP 纯净度 49 分（转租机房），徽章写「可以启动」，
    /// 环里却是「80 分」配一圈琥珀色，用户只会得出「不能用了」。
    /// 现在环里是「15/16 项」，环的颜色只跟能不能启动走。
    private var healthRing: some View {
        ZStack {
            Circle()
                .stroke(ClaudeTheme.hairline, lineWidth: 5)
            Circle()
                .trim(from: 0, to: healthRingProgress)
                .stroke(healthRingColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: Motion.emphasis), value: healthRingProgress)
            if heroBusy {
                ProgressView().scaleEffect(0.6)
            } else {
                VStack(spacing: -2) {
                    Text("\(passedCount)")
                        .font(Type.heroNumberFont)
                        .monospacedDigit()
                        .foregroundColor(ClaudeTheme.ink)
                        .contentTransition(.numericText())
                    Text("/\(vm.rows.count) 项")
                        .font(Type.microLabelFont)
                        .foregroundColor(ClaudeTheme.faint)
                }
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityLabel("\(vm.rows.count) 项中 \(passedCount) 项通过，\(heroVerdict.text)")
    }

    /// 状态徽章:标题右边的小标签。
    ///
    /// 原来是「彩色胶囊 + 彩色字」,属于规范点名要禁的彩色填充 ——
    /// 一屏里出现五六个彩色胶囊之后,颜色就不再指示异常,只是装饰。
    /// 现在是「一个小圆点 + 着色文字」,同样的信息量,没有色块。
    private var heroBadge: some View {
        let v = heroVerdict
        return HStack(spacing: 4) {
            if vm.phase != .checking {
                Circle().fill(v.color).frame(width: 5, height: 5)
            }
            Text(v.short)
                .font(Type.labelFont)
                .foregroundColor(v.color)
        }
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
        let showRegion = !exitIP.isEmpty && !heroBusy && !exitRegion.isEmpty
        return HStack(spacing: 10) {
            if !exitIP.isEmpty && !heroBusy {
                // IP 不再套一个浅灰底块。它本来就是这行里最该被读到的值,
                // 给它一块底色只是又多了一个色块;用主墨色 + tabular 数字已经够突出。
                // 字形跟着这一行走（比例字）,不单独用等宽 —— 否则「144…」是等宽、
                // 紧挨着的「US · 13/15」是比例,一行两种字形。
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                        .foregroundColor(ClaudeTheme.faint)
                    Text(exitIP)
                        .font(Type.microFont)
                        .monospacedDigit()
                        .foregroundColor(ClaudeTheme.ink)
                        .lineLimit(1)
                }
            }
            if showRegion {
                // 原来这里是 medium + ink,和 IP 抢注意力:一行里出现两个「最重」,
                // 就等于没有最重。地区是 IP 的附属(106.US 是一个整体),降成常规重。
                Text(exitRegion)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
            }
            if !heroDetail.isEmpty {
                // 只有前面接了内容时才要点。detail 为空时(已守护态)这个点
                // 会孤零零挂在行首,看着像渲染坏了。
                if showRegion || (!exitIP.isEmpty && !heroBusy) { separatorDot }
                Text(heroDetail)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
                    .lineLimit(2)
                    .lineSpacing(Type.microLineGap)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 这里以前还有一句「13/15 项通过」。现在圆环里就是「13 / /15 项」，
            // 同一屏两个一模一样的数字，读者会以为它们不是一回事（一个讲分值、
            // 一个讲项数）。通过数只留圆环那一处。
            Spacer(minLength: 0)
        }
    }

    private var separatorDot: some View {
        Text("·").font(Type.microFont).foregroundColor(ClaudeTheme.faint)
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
        // 「修不了的」不都是「换节点」。以前一律写成「换节点」,可 DNS 没走隧道
        // 要去客户端改设置,把它说成换节点就是把用户支到错的方向。
        let nodeBound = problems.filter { VM.nodeBoundNames.contains($0.name) }.count
        let byHand = manual - nodeBound
        if fixable == 0 {
            return byHand == 0 ? "\(head) · 需要换节点或线路" : "\(head) · 需要手动处理"
        }
        if byHand == 0 { return "\(head) · \(fixable) 项可修，\(nodeBound) 项换节点" }
        return "\(head) · \(fixable) 项可修，\(byHand) 项需手动"
    }

    // MARK: 提示条

    private var noticeStrip: AnyView? {
        if vm.isBusy && !vm.banner.isEmpty && (vm.phase == .fixing || vm.phase == .switching) {
            return nil   // hero 已经把这句说清楚了,不重复
        }
        if !vm.fixNotice.isEmpty {
            return AnyView(
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(Type.microLabelFont)
                        .foregroundColor(ClaudeTheme.brand)
                    Text(vm.fixNotice)
                        .font(Type.bodyFont)
                        .foregroundColor(ClaudeTheme.ink)
                    Spacer(minLength: 8)
                    if fixableProblemCount > 0 {
                        Button { vm.fixAll() } label: {
                            Text("再修一次")
                                .font(Type.labelFont)
                                .foregroundColor(ClaudeTheme.brandText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // 提示条也改成中性底 + 着色图标:彩色底条是又一种「第三种表面」,
                // 而它承载的信息(修了几项)并不需要一整块颜色来强调。
                .background(ClaudeTheme.inset)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // 分区标题必须比内容更重。之前这里 11pt、行名 12.5pt ——
                // 标题比正文还小,读者找不到「这一块在讲什么」。
                // 前面那个橙色圆点去掉了:它不是信息,只是又一个色块,
                // 而这一屏的色块已经够多了。
                Text("隔离实例槽位")
                    .font(Type.titleFont)
                    .foregroundColor(ClaudeTheme.ink)
                Text("环境与凭据独立沙盒")
                    .font(Type.bodyFont)
                    .foregroundColor(ClaudeTheme.faint)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !vm.incidents.isEmpty {
                    Button { showHistory = true } label: {
                        HStack(spacing: 4) {
                            Text("全部记录")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(Type.bodyFont)
                        // 纯导航入口，不带状态含义 —— 让出强调色额度给
                        // 「再修一次」和 24h 两个真正需要被看见的动作（§5 一屏 ≤3 处）
                        .foregroundColor(ClaudeTheme.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                ForEach(VM.accountLetters, id: \.self) { t in
                    accountCard(t)
                }
            }

            if let inc = vm.incidents.first {
                Button { showHistory = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                        // 不写「最近拦截」的话,这行紧挨着「已守护」,很容易被当成
                        // 当前状态 —— 明明守护正常,却读出一句「检查未通过」。
                        Text("最近拦截").font(Type.microLabelFont)
                        // 类型和原因往往重复(「检查未通过」+「运行中检查未通过:…」),
                        // 两句都留就是在同一行说两遍同一件事。原因更具体,留它。
                        Text(inc.reason.isEmpty ? inc.kind : shortReason(inc.reason))
                            .font(Type.microFont)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(shortClock(inc.time))
                            .font(Type.microMono)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .foregroundColor(ClaudeTheme.faint)
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
        let subtitle = accountSubtitle(t)
        let hovered = hoveredAccount == t

        return Button { vm.switchTo(t) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // 四张卡的字母块现在是同一种材质（inset 凹槽）。
                    // 之前当前槽位挂的是墨黑底白字 —— 一屏里最深的一块，
                    // 比旁边真正的异常还抢眼，四张卡一眼看去先看到「A」，
                    // 而不是先看到「有两项提示」。参照设计图也是淡底深字。
                    //
                    // 代价是少了一个「一眼定位」的锚点，所以锚点挪到了标签上：
                    // 当前槽位的状态词用 ink + semibold，其余 muted + regular。
                    // 这里刻意绑 isCurrent 而不是「Claude 是否在运行」——
                    // 关掉 Claude 之后这个槽位仍然叫「上次使用」，它依然是
                    // 指针指向的那一个，不该跟着掉回普通档。
                    Text(t)
                        .font(Type.slotLetterFont)
                        .foregroundColor(archived || isCurrent ? ClaudeTheme.ink : ClaudeTheme.faint)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                                .fill(ClaudeTheme.inset)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountStateLabel(t))
                            .font(isCurrent ? Type.bodyStrongFont : Type.bodyFont)
                            .foregroundColor(isCurrent ? ClaudeTheme.ink : ClaudeTheme.muted)
                            .lineLimit(1)
                        // 空槽位不再写「空」:「未初始化」已经把话说完了,
                        // 底注又写着「点击绑定」—— 同一件事说三遍,
                        // 四张卡里两张显得比另外两张吵。
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(Type.microMono)
                                .monospacedDigit()
                                .foregroundColor(ClaudeTheme.faint)
                                .lineLimit(1)
                        }
                    }
                    // 角标放到第三行右端，不放这一行的行尾。
                    // 放行尾会把「348M · 10-31」挤成「348M · 10-…」——
                    // 卡片只有 226pt 宽，五样东西（字母块、状态词、角标）
                    // 挤一行必然要牺牲一样，而体积+日期是这里唯一的量化信息。
                    Spacer(minLength: 0)
                }

                HStack(spacing: 4) {
                    Image(systemName: archived ? "shield.lefthalf.filled" : "plus")
                        .font(.system(size: 9))
                    Text(archived ? "独立指纹" : "点击绑定")
                        .font(Type.microFont)
                    // 槽位现在连 Claude Code 的状态一起搬。有存档才画这个角标：
                    // 老脚本 / 从没用过 CLI 的机器不该平白多一个看不懂的 CLI。
                    if let stamp = vm.cliStamps[t] {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal").font(.system(size: 8))
                            Text("CLI").font(Type.microFont)
                        }
                        .foregroundColor(ClaudeTheme.muted)
                        .help("该槽位还存着 Claude Code 的 ~/.claude 与 ~/.claude.json"
                              + "：\(stamp.size) · \(shortDate(stamp.date))")
                    }
                    Spacer(minLength: 6)
                    // 「档案在不在」和「会话还有没有效」是两件事，以前只说了前一件。
                    // 实测有个槽位快照完好、卡片写着「已保存」，但 Cookies 里根本
                    // 没有 sessionKey —— 点进去是登录页。这个角标就是补这一句。
                    if archived { loginChip(vm.slotLogin[t] ?? .unknown) }
                }
                .foregroundColor(ClaudeTheme.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 当前槽位不再铺一层陶土色底。选中态靠「字母块是墨底白字」表达就够了 ——
            // 橙色是「需要你注意」的信号，选中不是异常，不该占用它；
            // 而四张卡里唯一的深色块，已经足够让人一眼找到「是它」。
            //
            // 圆角跟大卡、跟延迟面板里的小卡统一走 22：它们在页面上是同一个角色
            // （浮在底色上的一张面），原来这里是 14，四张小卡挨着两张 22 的大卡，
            // 一眼就能看出不是一套。
            .cardSurface(radius: Geo.cardRadius,
                         // hover 原来铺的是页面底色。页面底色抬到 249 之后，
                         // 白卡(255) → 249 只差 6 级，是原来的一半，指针划过去
                         // 几乎看不出来。改用 inset(246)：差 9 级，和改之前的
                         // 手感基本一致，而且是已有色、不新增表面。
                         fill: hovered ? ClaudeTheme.inset : ClaudeTheme.card)
            .contentShape(RoundedRectangle(cornerRadius: Geo.cardRadius, style: .continuous))
            .animation(.easeOut(duration: Motion.micro), value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
        // 绑定入口挂在卡片右上角，不藏进右键菜单：之前扫描入口放在工具栏
        // 就被用户吐槽「找不到」。这里是个常驻的小图标，绑没绑一眼看得出来。
        // overlay 而不是塞进 Button 的 label —— 嵌套的交互控件收不到点击。
        .overlay(alignment: .topTrailing) {
            slotNodeMenu(t)
                .padding(.top, 6)
                .padding(.trailing, 8)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: Motion.micro)) {
                if inside { hoveredAccount = t }
                else if hoveredAccount == t { hoveredAccount = nil }
            }
        }
        .help(isCurrent ? "当前正在使用账号 \(t)" : "切换到账号 \(t)（会先重新检查一遍环境）")
    }

    /// 槽位 → 出口的绑定菜单。选项只来自最近一次扫描报告，
    /// 没扫过就先给一个「去扫描」，不让人手敲节点名（敲错就是切到不存在的线）。
    private func slotNodeMenu(_ t: String) -> some View {
        let bound = vm.slotNodes[t] ?? ""
        let current = vm.nodeScanInfo["CURRENT"] ?? ""
        let candidates = vm.nodeCandidates
        return Menu {
            Section("账号 \(t) 切换时固定走") {
                if !current.isEmpty && !candidates.contains(where: { $0.leaf == current }) {
                    Button("当前出口 · \(current)") { vm.bindSlotNode(t, leaf: current) }
                }
                ForEach(candidates) { candidate in
                    Button(candidate.label) { vm.bindSlotNode(t, leaf: candidate.leaf) }
                }
                if candidates.isEmpty && current.isEmpty {
                    Button("先扫描可用节点…") { vm.scanNodes() }
                }
            }
            if !bound.isEmpty {
                Button("解除绑定（\(bound)）") { vm.clearSlotNode(t) }
            }
            Button("重新扫描节点…") { vm.scanNodes() }
        } label: {
            Image(systemName: bound.isEmpty ? "link.badge.plus" : "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(bound.isEmpty ? ClaudeTheme.faint : ClaudeTheme.terracottaDeep)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(vm.isBusy)
        .help(bound.isEmpty
              ? "给账号 \(t) 绑定一条固定出口"
              : "账号 \(t) 固定走 \(bound)。点这里改绑或解除")
    }

    /// 登录角标。三种确定状态各给一个图标 + 一句人话；
    /// 读不出来时**什么都不画** —— 猜一个「已登录」比不显示更糟。
    @ViewBuilder
    private func loginChip(_ state: SlotLogin) -> some View {
        switch state {
        case .loggedIn:
            loginBadge("checkmark.circle.fill", "已登录", ClaudeTheme.ok,
                       "会话有效，切过去可以直接用")
        case .expired:
            loginBadge("clock.badge.exclamationmark", "已过期", ClaudeTheme.warn,
                       "会话已过期，切过去要重新登录")
        case .loggedOut:
            loginBadge("exclamationmark.circle.fill", "未登录", ClaudeTheme.warn,
                       "这个槽位没有登录会话，切过去会停在登录页")
        case .unknown:
            EmptyView()
        }
    }

    private func loginBadge(_ symbol: String, _ text: String,
                            _ tint: Color, _ help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            // 13 号 + semibold。这一格回答的是「切过去能不能直接用」，
            // 比旁边的「独立指纹」重要，不该和脚注同号同重。
            // 13 在规范的刻度上（12/13/14/15/17），没有插值。
            Text(text)
                .font(Type.bodyStrongFont)
        }
        .foregroundColor(tint)
        .lineLimit(1)
        .fixedSize()
        .help(help)
    }

    func accountStateLabel(_ t: String) -> String {
        if vm.current == t {
            // 直接回答「Claude 这个程序现在开着没有」，不用「上次使用」这种绕的说法：
            // 「上次使用」说的是历史，用户问的是现在 —— 关着就是关着。
            // 「使用中 / 未运行」也是四张卡里唯一在描述进程状态的，其余三张
            // 描述的是档案状态（已保存 / 未初始化），两类信息不会混。
            return vm.claudeRunning ? "使用中" : "未运行"
        }
        return vm.archived.contains(t) ? "已保存" : "未初始化"
    }

    func accountSubtitle(_ t: String) -> String {
        // 空槽位返回空串,由调用方整行省略 —— 返回「空」的话,四张卡里
        // 两张会多出一行「空」,而上面已经写着「未初始化」了。
        guard vm.archived.contains(t) else { return "" }
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

    private func checkCard(_ title: String, subtitle: String,
                           rows: [CheckRow]) -> some View {
        let checking = rows.contains(where: { vm.rechecking.contains($0.name) })
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                // 头:标题、副标题、计数。**前面不放图标块**。
                //
                // 卡头原来挂着一枚 28×28 的浅灰图标块,理由是「章节标题要有指路牌」。
                // 可这一屏上「块」已经三种了:hero 是大圆环、四张槽位卡是字母块、
                // 行是裸符号 —— 再加上块,整屏第一列的形态太多,读者说不出哪里乱,
                // 只看见一排方块大小不一。标题本身就是指路牌:17pt semibold 已经是
                // 这一屏最大的字,不需要再加一个图形替它喊。
                //
                // 去掉块之后卡头从 cardH 起排,和行图标同一条起始边;
                // 行名在 50(icon + gap),标题在 14 —— 这是「标题挂左、行缩进」的
                // 常规做法,不是错位。
                HStack(alignment: .center, spacing: Rhythm.gap) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(Type.titleFont)
                            .foregroundColor(ClaudeTheme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(Type.microFont)
                            .foregroundColor(ClaudeTheme.faint)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 计数用「点 + 文字」而不是胶囊。胶囊是给需要被点、被注意的
                    // 东西用的,这里只是个数字。
                    HStack(spacing: 4) {
                        Circle()
                            .fill(countColor(rows))
                            .frame(width: 5, height: 5)
                        Text(countText(rows))
                            .font(Type.labelFont)
                            .monospacedDigit()
                            .foregroundColor(countColor(rows))
                    }
                    .fixedSize()
                }
                .padding(.horizontal, Rhythm.cardH)
                .padding(.top, Rhythm.cardTop)
                .padding(.bottom, checking ? 8 : Rhythm.cardBottom)

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
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            // 只有「更优节点」可点:其余各行点下去没有任何动作,
                            // 整行都做成按钮会让人以为到处能点,试两次就学会了不点。
                            if row.name == "更优节点" {
                                Button { vm.scanNodes() } label: {
                                    checkRow(row, index: idx)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.nodeScanBusy)
                                .help(vm.nodeScanBusy ? "正在扫描可用节点…"
                                                      : "扫描可用节点（只读，不切线路）")
                            } else {
                                checkRow(row, index: idx)
                            }
                        }
                    }
                    .padding(.horizontal, Rhythm.listInset)
                    .padding(.bottom, 12)
                }
            }
            // 两卡等高。这里撑的是**内容区**而不是外层 frame —— 只有内容先长满，
            // Card 的背景才会跟着长满；加在外面等于把卡片画小之后再套一个空框。
            //
            // 上一版为了躲「矮卡底部空 56pt 白」把等高撤了，改成各按内容收口。
            // 结果两卡高度差 26pt（448.5 / 474.5），下沿一高一低，并排摆着像做歪了。
            // 现在明确取舍：**下沿齐 > 底部可能留白**。清单卡片本来就不是等内容的容器，
            // 留白是容器属性，错边是排版事故。
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeOut(duration: Motion.state), value: checking)
    }

    /// 一条 3pt 的进度线。宽度跟着「已落定的行数」走,和逐行落定是同一个节拍 ——
    /// 两处对不上(条子走完了行还在转)会让人以为卡住了。
    private func checkProgress(_ rows: [CheckRow]) -> some View {
        let total = max(rows.count, 1)
        let done = rows.filter { !vm.rechecking.contains($0.name) }.count
        let ratio = Double(done) / Double(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.inset)
                RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                    .fill(cardAccent(rows).opacity(0.8))
                    .frame(width: max(4, geo.size.width * ratio))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: Motion.emphasis), value: ratio)
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
        // 提示项(warn)也算「要你动手」:时区不对、地区格式不对都能一键修。
        // 判定只剩这一条 —— 原来还有个 isProblem(fail/config),只用来决定行名加不加粗,
        // 结果是 warn 行和通过行字重一样;现在统一看 needsAttention。
        let needsAttention = row.state == .fail || row.state == .config || row.state == .warn
        let fix = vm.fixStates[row.name]
        // 修复回执里的附注:失败时是「为什么改不了」,成功时是「改完还要做什么」。
        // 用户点了修复之后,这一句是他唯一想看的第二句话。
        let fixNote = fix?.note ?? ""
        let fixFailed = fix?.isFailed ?? false
        // 元组标签在 `?? (…)` 这种默认值写法里会丢,所以下面按位置取(.0/.1/.2)。
        let fixMark = fix?.noteMark ?? ("", ClaudeTheme.muted, "")
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
        // 脚本对「没事」有几种说法:没有 detail、`通过`、`已关闭`、`走隧道`。
        // 这些词和左边的行名说的是同一件事(「IPv6 关闭 — 已关闭」把行名复述了一遍),
        // 一列里连着出现四五次,读下来全是同义反复,真正有内容的行反而被淹掉。
        // 统一收成一个极淡的对勾:结论还在,视觉重量几乎归零。
        let confirmOnly = row.state == .ok && ContentView.confirmationWords.contains(row.detail)
        // 右列能不能放「读数」：短详情、且这一项不需要处理。
        // 需要处理的行右端留给动作（修复）或状态词，读数已经写在第二行原因里了。
        let showsReading = !confirmOnly && !needsAttention && !detailNeedsOwnLine

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Rhythm.gap) {
                Image(systemName: row.icon)
                    // 13 / medium —— 和行名同号同重。
                    // 12 / regular 的符号放在 13/medium 的中文旁边是「一根细线配一块实心字」，
                    // 一列十几个图标扫下来整片发虚。图标字重跟着文字走，不单独定。
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(tint)
                    // 定宽 26 且居中。之前是 18 宽靠左:时钟窄、盾牌宽,
                    // 每个图标的视觉重心都在横向漂,十几行叠起来就是一条歪的虚线。
                    // 定宽居中之后图标共用一条竖轴,行名起点自然成一条直线。
                    .frame(width: Rhythm.icon)

                // 行名定宽。名字长短不一是这一列「锯齿」的总根源:
                // 「时区」后面空一大片、「IP 与上次一致」后面紧贴着值,
                // 每行的值和对勾都停在不同位置,一列扫下去找不到规律。
                // 定宽 + 左对齐之后,第二列从同一条竖线起排,读起来才是一张表。
                //
                // 字重 = 层级。原来只有 fail/config 才加粗,**warn 不加** ——
                // 于是「IP 纯净度(提示)」和「时区(通过)」两个字重一模一样,
                // 一列读下来没有任何一处是先看的。现在凡是「要你动手」的行
                // (fail / config / warn)都加粗,通过的留在 medium:
                // 一张卡里 5 行 normal + 2 行 semibold,眼睛自然先落在后两行。
                Text(row.name)
                    .font(needsAttention ? Type.bodyStrongFont : Type.labelFont)
                    .foregroundColor(ClaudeTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Rhythm.nameColumn, alignment: .leading)

                // 「更优节点」这一行自己就是入口:点它重新扫一遍候选。
                // 以前挂在工具栏的地球图标上,离这一项太远 —— 用户读着
                // 「过硬门槛内没有更优节点」,并不知道还能让它再比一次。
                if row.name == "更优节点" {
                    HStack(spacing: 3) {
                        if vm.nodeScanBusy {
                            SpinRing(size: 9, lineWidth: 1.2, duration: 0.9)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text(vm.nodeScanBusy ? "扫描中" : "扫描")
                            .font(Type.microFont)
                    }
                    .foregroundColor(ClaudeTheme.brandText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ClaudeTheme.terracottaTint))
                }

                // 弹性空隙放在结论**之前**，结论一律贴右。
                // 注意不能把弹性 frame 加在结论本身（`maxWidth:.infinity, alignment:.trailing`）：
                // 没有结论的行里那个分支是 EmptyView，不参与布局 → 列塌成 0 宽，
                // 对勾会被拽到行名后面（实测 x=238，而值在 x=518）。
                Spacer(minLength: 8)

                // 行尾「结论」——一张清单一列扫过去，右端必须每行都有东西，
                // 而且只有三种形态：读数（14pt 灰）／对勾（符号）／动作（修复·24h）。
                //
                // 上一版的问题是「有的行右边是空气」：长说明的行（保卫在线、ASN 属性、
                // IP 纯净度）把详情挪到第二行之后，右端就什么都不显示了。8 行里 4 行
                // 右边空着，读者看到的是「有些对号、有些文字、有些什么都没有」——
                // 这不是对齐问题，是每行的结论没有定义。
                //
                // 规则，自上而下命中一条即止：
                //   1 正在核对 → 转圈
                //   2 刚修过   → 回执（已修复／需手动）
                //   3 能修     → 「修复」
                //   4 24h 入口
                //   5 有短读数且不需要处理 → 读数
                //   6 通过     → 对勾
                //   7 其余     → 状态词（提示／未通过／待配置／已跳过）
                if row.state == .pending || isRechecking {
                    // 自己画的弧，不用系统 ProgressView：那个小菊花在浅色卡上
                    // 是一团灰糊，和整屏的圆角/细线语言也不搭。
                    SpinRing(size: 12, lineWidth: 1.5, duration: 0.9)
                        .transition(.opacity)
                } else if let fix {
                    fixChip(fix)
                        .transition(.opacity)
                } else if needsAttention && VM.fixableNames.contains(row.name) && !vm.isBusy {
                    FixActionButton(label: "修复", quiet: true) { vm.fixAll(focus: row.name) }
                        .help("修复这一项（脚本会一并处理其他可自动修复的项）")
                } else if row.name == "生态可达性" && !vm.isBusy {
                    // 这一行是「24h 延迟洞察」的入口 —— 数据就是它测出来的，
                    // 放在行尾比塞进工具栏更好找。字号与「修复」同号（14），
                    // 右列不出现第二种正文尺寸。
                    Button { showLatency = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 11, weight: .medium))
                            Text("24h")
                                .font(Type.labelFont)
                        }
                        .foregroundColor(ClaudeTheme.brandText)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看 24 小时延迟历史")
                } else if showsReading {
                    Text(value)
                        .font(Type.bodyFont)
                        // 读数与行名同号（14），只靠颜色降一级。
                        // 层级不是「越浅越小越高级」——该读的留在第二级灰。
                        .foregroundColor(ClaudeTheme.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.detail)
                } else if row.state == .ok {
                    // 「通过」写成字，不用对勾。
                    //
                    // 对勾的问题是**它太像一个按钮/一个可点的东西**，一列排下来
                    // 八个小绿勾，右端变成一列图标，反而比文字更吵；而且勾的颜色
                    // （语义绿 5.2:1）和左边行名的墨色几乎一样重，一列扫过去
                    // 分不清「哪边是结论」。
                    //
                    // 现在：字 + 最淡的一档灰。通过本来就不需要被读第二眼 ——
                    // 它只需要「在场」，证明这一项确实被检查过。
                    // 需要处理的行仍然是彩色（提示=橙 / 未通过=红 / 待配置=棕），
                    // 于是这一列的颜色只有两种含义：淡灰 = 没事，彩色 = 有事。
                    Text(stateWord(row.state))
                        .font(Type.bodyFont)
                        .foregroundColor(ClaudeTheme.faint)
                        .lineLimit(1)
                        .help(row.detail.isEmpty ? "通过" : row.detail)
                } else {
                    // 不通过又不给修复按钮的（出口 IP 一致、ASN、纯净度、生态），
                    // 右端至少要说清「没过」。用状态词而不是再画一个红点。
                    Text(stateWord(row.state))
                        .font(Type.labelFont)
                        .foregroundColor(tint)
                        .lineLimit(1)
                }
            }

            // 修复回执优先。修失败了,这一行的第二句必须是「为什么没修好」,
            // 而不是原来那句检查详情 —— 用户刚点完修复,关心的是结果。
            if !fixNote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: fixMark.0)
                        .font(.system(size: 10))
                        .foregroundColor(fixMark.1)
                        .padding(.top, 1.5)
                    // 颜色也跟档走:只有「没修成」才用红。没法验证用灰 ——
                    // 红色会把它读成失败,而这一条恰恰不是失败。
                    Text(fixNote)
                        .font(Type.bodyFont)
                        .foregroundColor(fixFailed ? ClaudeTheme.bad : ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(fixMark.2 + fixNote)
                }
                .padding(.leading, Rhythm.rowIndent)
                .transition(.opacity)
            } else if detailNeedsOwnLine {
                // 要动手的行把原因放到第二行整行铺开。一行放不下「当前 A,期望 B」,
                // 中间截断切掉的正好是最要紧的那半句。
                Text(row.detail)
                    // 第二行是「描述」，三级里最轻的一级：12pt + 最浅的灰。
                    //
                    // 三级各自只差一个维度，合起来一眼能分开：
                    //   名称 14 medium ink     —— 它是这一行的主语
                    //   状态 14 regular muted  —— 它是这一行的结论
                    //   描述 12 regular faint  —— 它是结论的注脚
                    // 上一版名称是 regular、描述和状态同色，只有字号差一档 ——
                    // 「一眼看不出哪句是名、哪句是状态、哪句是补充」。
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.faint)
                    .lineSpacing(Type.microLineGap)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    // 缩进 = 图标列 + 间距,正好落在行名的第一个字下面。
                    // 原来是 26 和 28 两个值,两种缩进同一张卡里并存,左边缘看着发抖。
                    .padding(.leading, Rhythm.rowIndent)
                    .transition(.opacity)
            }
        }
        // 钉在容器宽度上。不钉的话,「代理离线(内核或 TUN 丢失),已自动关闭」
        // 这种长备注会把行的理想宽度撑到卡片之外,然后被父级居中 —— 图标和行名
        // 一起右移几十点,而同一张卡里别的行纹丝不动。谁也不会想到那是「换行没触发」。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Rhythm.rowH)
        .padding(.vertical, Rhythm.rowV)
        // 只有悬浮才铺底色。之前给「要处理」的行铺一层淡色,结果同一张卡里
        // 两行有色、四行没色,看着像两个被选中的行,清单反而不像清单。
        // 「要处理」已经有三个信号了:图标着色、第二行原因、行尾修复按钮。
        .background(
            RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                // hover 用 inset 而不是页面底色：页面底色抬到 249 之后，
                // 白卡上的 hover 只剩 6 级差，太淡；inset(246) 差 9 级，
                // 和抬底色之前的手感一致，也不新增表面色。
                .fill(hoveredRow == row.name ? ClaudeTheme.inset : Color.clear)
        )
        // 逐行落定,而不是整组一起跳。检查输出是一行行回来的,给每行按顺序
        // 错开十几毫秒,眼睛能跟上「现在核到哪一项」;错开量封顶 96ms,
        // 再多就变成拖沓。
        .animation(.easeOut(duration: Motion.state).delay(Double(min(index, 8)) * 0.012),
                   value: row.state)
        .animation(.easeOut(duration: Motion.micro), value: isRechecking)
        .animation(.easeOut(duration: Motion.micro), value: row.detail)
        .onHover { inside in
            // 鼠标划过去要有一点反应,否则整张清单像一张不可点的表。
            withAnimation(.easeOut(duration: Motion.micro)) {
                if inside { hoveredRow = row.name }
                else if hoveredRow == row.name { hoveredRow = nil }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)，\(stateWord(row.state))，\(row.detail)")
    }

    /// 通过项用中性灰,只有要处理的行才着色 —— 16 行全彩等于没有重点。
    ///
    /// 这是全文件**唯一**允许用 opacity 调灰度的地方:它调的是图标不是文字,
    /// 而且「已跳过」本来就该比「通过」再退后一点。文字一律只走 ink/muted/faint
    /// 三档 —— 文字上用 opacity 会凭空造出第四第五档灰,层级立刻糊掉。
    private func iconTint(_ s: RowState) -> Color {
        switch s {
        // 通过的行：图标用 muted 而不是 faint。13pt 的符号在 faint(4.6:1) 下
        // 只剩一层虚影，和旁边的实心中文并排就像没对齐；muted(8.8:1) 让它和
        // 右边那一列读数同色 —— 同一行里「附属信息」用同一个灰，比用两个灰干净。
        case .ok: return ClaudeTheme.muted
        case .warn: return ClaudeTheme.warn
        case .fail: return ClaudeTheme.bad
        case .config: return ClaudeTheme.brandText
        case .pending, .skip: return ClaudeTheme.faint.opacity(0.6)
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
            // 「未验证」而不是「失败」:这一项的判定依赖一个当前不存在的比对对象,
            // 用红色会让用户去找一个不存在的手动动作。
            case .note: return ("未验证", ClaudeTheme.muted, "questionmark")
            }
        }()
        return HStack(spacing: 4) {
            if case .running = state {
                SpinRing(size: 10, lineWidth: 1.4, duration: 0.9)
            } else {
                Image(systemName: symbol)
                    // 11pt 图标配 14pt 字：8pt 的勾在 14pt 汉字旁边像掉了一颗芝麻，
                    // 而这一枚回执是要被读到结论的，不是装饰。
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                // 与「读数」「修复」「24h」同号，右列不出现第二种正文尺寸。
                .font(Type.labelFont)
        }
        .foregroundColor(color)
        .fixedSize()
    }

    private var setupPanel: some View {
        VStack(spacing: 10) {
            Text("还没有安装核心脚本")
                .font(Type.titleFont)
                .foregroundColor(ClaudeTheme.ink)
            Text(vm.banner)
                .font(Type.microFont)
                .foregroundColor(ClaudeTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    openInBrowser("https://github.com/huanfine/claude-switcher")
                } label: {
                    Text("打开项目主页")
                        .font(Type.microLabelFont)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.ink))
                }
                .buttonStyle(.plain)
                Button {
                    openInBrowser("https://github.com/huanfine/claude-switcher#安装")
                } label: {
                    Text("安装说明")
                        .font(Type.microLabelFont)
                        .foregroundColor(ClaudeTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.inset))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
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
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                        .foregroundColor(ClaudeTheme.faint)
                    Text(clientLabel)
                        .font(Type.microLabelFont)
                        .foregroundColor(ClaudeTheme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(ClaudeTheme.faint)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                             style: .continuous).fill(ClaudeTheme.inset))
                .contentShape(RoundedRectangle(cornerRadius: Geo.controlRadius,
                                               style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(vm.isBusy || vm.isSwitchingClient)
            .help("选择代理客户端")

            if vm.isSwitchingClient {
                ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
            }

            HStack(spacing: 6) {
                Circle().fill(footerStatusColor).frame(width: 5, height: 5)
                Text(footerStatusText)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.faint)
                    .lineLimit(1)
            }

            // 检查中时状态点后面写「检查中」,这里再挂一个「· 检查中」就是
            // 一行里说两遍同一件事。内容一样就不画。
            if vm.lastCheckSummary != "尚未检查" && vm.lastCheckSummary != footerStatusText {
                Text("· \(vm.lastCheckSummary)")
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.faint)
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
        .padding(.horizontal, Geo.gutter)
        .padding(.top, 8)
        .padding(.bottom, 14)
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
        // 括号里基本是变量的具体值:「出口 IPv4 变了(123.90.7.74 → 144.1…）」。
        // 按固定字数硬切,切出来正好是「144.1…」这种半个 IP —— 读者看到的是一段
        // 乱码,而不是一句「出口变了」。括号前那半句已经把发生了什么说完,
        // 具体数值留给悬浮提示和拦截记录页。所以长句优先在括号处断开。
        let limit = 34
        if flat.count > limit, let paren = flat.firstIndex(of: "(") {
            let head = flat[..<paren].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

/// 拦截历史。只读 —— 写是脚本的事,界面不该有能力改审计记录。
struct IncidentHistorySheet: View {
    @ObservedObject var vm: VM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: Geo.inline) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拦截记录")
                            .font(Type.titleFont)
                            .foregroundColor(ClaudeTheme.ink)
                        Text("看门狗真的动手停过 Claude 的事件，最多保留 50 条")
                            .font(Type.microFont)
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
                            .font(Type.bodyFont)
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.incidents) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.kind)
                                        .font(Type.microLabelFont)
                                        .foregroundColor(ClaudeTheme.bad)
                                        .fixedSize()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.reason)
                                            .font(Type.microFont)
                                            .foregroundColor(ClaudeTheme.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        Text(item.time)
                                            .font(Type.microFont)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("检查设置").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                        Text("安全项始终强制执行；跳过不等于通过").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .medium)).foregroundColor(ClaudeTheme.muted)
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
                                                .font(Type.microFont)
                                                .foregroundColor(ClaudeTheme.warning)
                                        }
                                    }
                                }
                                Text("默认 16 项全部拦截启动。这里关掉的项会真正跳过探测，并以灰色「已跳过」显示 —— 那不叫通过，叫放弃验证。只在本机环境确实造成误报时才关。出口国家、代理/TUN、Kill-Switch、保镖、账号归档和更新校验不可关闭。")
                                    .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("失败处理与日志") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("把上述 6 项的失败降为警告", isOn: $vm.allowOptionalFailures)
                                Text("降级后这些项仍然会跑、仍然会报，只是不再拦住启动。只影响这 6 项；不会放宽任何硬性安全项，也不会自动关闭检测。")
                                    .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
                                Text("仅记录版本、命令、退出码、耗时和检查状态，不记录 IP、凭据或账号内容。")
                                    .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("问题排查") {
                            VStack(alignment: .leading, spacing: 10) {
                                Button("导出脱敏诊断日志…") { vm.exportDiagnostics() }
                                    .disabled(vm.settingsBusy)
                                Text("日志：~/Library/Logs/claude-switcher/client.log")
                                    .font(Type.microFont).foregroundColor(ClaudeTheme.muted).textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if !vm.settingsMessage.isEmpty {
                    Text(vm.settingsMessage).font(Type.microFont).foregroundColor(ClaudeTheme.muted)
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

/// 节点扫描报告。报告本身只读;「应用最优节点」只在报告门禁为 auto-ok 且
/// 确实存在更优节点时出现(见 VM.canApplyBestNode)。
///
/// 门禁原来还看「存过几个槽位」—— 那是死条件,槽位是常驻资产,存过一次就
/// 永远为真,于是这个按钮对任何用过本工具的人都不出现。现在只看「Claude 在
/// 不在跑」和「看门狗在不在驻守」这两个瞬时事实。
///
/// 换槽位时这条链会自己走一遍(见 VM.optimizeNodeForSwitch),不必等用户点。
/// 切换动作归 VM.applyBestNode / 脚本 node-apply,面板不自己改线路。
struct NodeScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM
    @State private var copiedFix = false

    var body: some View {
        VStack(alignment: .leading, spacing: Geo.inline) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可用节点扫描").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                    Text(vm.coreOutdated ? "核心脚本版本过旧 · 只读 · 不切线路" :
                         "只读 · 不切线路 · 不写 48h IP 漂移记录")
                        .font(Type.microFont)
                        .foregroundColor(vm.coreOutdated ? ClaudeTheme.warning : ClaudeTheme.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            ScrollView {
                Text(vm.nodeScanBusy ? "正在扫描…" :
                     (vm.nodeScanReport.isEmpty ? "尚未扫描" : vm.nodeScanReport))
                    .font(Type.microMono)
                    .foregroundColor(ClaudeTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if vm.coreOutdated {
                // 报错里那句「脚本执行失败（退出码 2）」没人看得懂，
                // 这里给一条可以直接贴进终端的命令，别让人去翻文档找升级办法。
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(ClaudeTheme.warning)
                    Text("旧版脚本的自动更新指向原上游仓库，需要手动升级一次")
                        .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                    Spacer()
                    Button(copiedFix ? "已复制" : "复制升级命令") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        _ = pb.setString(VM.upgradeCoreCommand, forType: .string)
                        copiedFix = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 8) {
                if vm.canApplyBestNode {
                    Text("门禁允许自动应用 · 停守护、只切一次、复查出口")
                        .font(Type.microFont).foregroundColor(ClaudeTheme.faint)
                } else {
                    Text("Claude 在跑或看门狗仍驻守时只生成报告,不会自动切换节点")
                        .font(Type.microFont).foregroundColor(ClaudeTheme.faint)
                }
                Spacer()
                if vm.canApplyBestNode {
                    Button { vm.applyBestNode() } label: {
                        Text(vm.isBusy ? "应用中…" : "应用最优节点")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy || vm.nodeScanBusy)
                    .help("先停守护 → 只切一次 Selector → 复查出口国家 → 重新检查并恢复守护；不达标自动回滚")
                }
                Button { vm.scanNodes() } label: {
                    Text(vm.nodeScanBusy ? "扫描中…" : "重新扫描")
                }
                .disabled(vm.nodeScanBusy)
            }
        }
        .padding(20)
        .frame(width: 620, height: 430)
        .background(ClaudeTheme.bgTop)
    }
}

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Geo.inline) {
            HStack {
                Text("设备指纹体检").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(Type.microMono)
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
                        Text("版本更新").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                        Text("只检查，不写入任何文件").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .medium)).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
                        .font(Type.microMono)
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: Geo.cardRadius, style: .continuous).fill(ClaudeTheme.iconWell))

                HStack(spacing: 10) {
                    Button { vm.checkUpdate() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(Type.bodyStrongFont)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.ink))
                            .foregroundColor(ClaudeTheme.bg)
                    }
                    .buttonStyle(.plain)
                    Button { copyUpdateCommand() } label: {
                        Label(copied ? "已复制" : "复制更新命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Type.bodyStrongFont)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Text("复制后到终端执行即可更新；更新前会做 SHA256 校验，自检不通过会自动回滚。")
                    .font(Type.microFont).foregroundColor(ClaudeTheme.muted)
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
            VStack(alignment: .leading, spacing: Geo.inline) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 交接提示词").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                        Text("复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .medium)).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(text)
                        .font(Type.microMono)
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(Type.microLineGap)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Geo.cardRadius, style: .continuous).fill(ClaudeTheme.iconWell))

                HStack {
                    Button { copyPrompt() } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Type.bodyStrongFont)
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.ink))
                            .foregroundColor(ClaudeTheme.bg)
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
        ("Environment Audit 环境一致性审计", "每次启动前执行 16 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。"),
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
                        Text("安全防护体系公告").font(Type.titleFont).foregroundColor(ClaudeTheme.ink)
                        Text("Security Architecture Bulletin").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .medium)).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(Type.bodyFont)
                            .foregroundColor(ClaudeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(idx + 1). \(s.0)").font(Type.bodyStrongFont).foregroundColor(ClaudeTheme.terracottaDeep)
                                Text(s.1).font(Type.microFont).foregroundColor(ClaudeTheme.muted).lineSpacing(Type.microLineGap)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ClaudeTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(Type.microFont)
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
        HStack(alignment: .top, spacing: Geo.inline) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ClaudeTheme.terracotta)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                    .fill(ClaudeTheme.terracotta.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Anthropic 生态探测 · 延迟历史")
                        .font(Type.titleFont)
                        .foregroundColor(ClaudeTheme.ink)
                    HStack(spacing: 4) {
                        Circle().fill(samples.isEmpty ? ClaudeTheme.muted : ClaudeTheme.success)
                            .frame(width: 4.5, height: 4.5)
                        Text(samples.isEmpty ? "等待采样" : "监测中")
                            .font(Type.microLabelFont)
                            .foregroundColor(samples.isEmpty ? ClaudeTheme.muted : ClaudeTheme.success)
                    }
                }
                Text("每次环境检查都会记一条 api 首包耗时，按时间回放")
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(ranges, id: \.1) { label, h in
                    Button { hours = h } label: {
                        Text(label)
                            .font(hours == h ? Type.microLabelFont : Type.microFont)
                            .foregroundColor(hours == h ? ClaudeTheme.ink : ClaudeTheme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
                                    .fill(hours == h ? ClaudeTheme.card : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.iconWell))

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
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundColor(tint.opacity(0.85))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Type.metricFont)
                    .foregroundColor(ClaudeTheme.ink)
                Text(unit)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text(note)
                .font(Type.microFont)
                .foregroundColor(ClaudeTheme.faint)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: 曲线

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(ClaudeTheme.terracotta).frame(width: 5, height: 5)
                Text("端到端首包耗时")
                    .font(Type.microLabelFont)
                    .foregroundColor(ClaudeTheme.ink)
                Text("· 采样 \(samples.count) 个")
                    .font(Type.microFont)
                    .monospacedDigit()
                    .foregroundColor(ClaudeTheme.faint)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Rectangle().fill(ClaudeTheme.brand).frame(width: 12, height: 2)
                    Text("api 首包").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                }
                HStack(spacing: 4) {
                    Rectangle().fill(ClaudeTheme.warn.opacity(0.5)).frame(width: 12, height: 1.5)
                    Text("500ms 警戒").font(Type.microFont).foregroundColor(ClaudeTheme.muted)
                }
            }

            RTTChart(samples: samples, hours: hours)
                .frame(height: 150)
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: 端点

    private var endpointRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("端点可用性")
                    .font(Type.microLabelFont)
                    .foregroundColor(ClaudeTheme.ink)
                Spacer(minLength: 8)
                // 只有脚本真的探过这两个域,不凑数。cdn / statsig 没探就不显示。
                Text("仅统计脚本实际探测的端点")
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.faint)
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
                .font(Type.microMono)
                .foregroundColor(ClaudeTheme.ink)
            Spacer(minLength: 6)
            if let latency {
                Text("\(latency)ms")
                    .font(Type.microMono)
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text(code)
                .font(Type.microMonoLabel)
                .foregroundColor(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Geo.innerRadius, style: .continuous).fill(ClaudeTheme.iconWell))
    }

    // MARK: 事件

    private var incidentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(ClaudeTheme.muted)
                Text("关键事件")
                    .font(Type.microLabelFont)
                    .foregroundColor(ClaudeTheme.ink)
                Spacer(minLength: 8)
                Text("共 \(vm.incidents.count) 条")
                    .font(Type.microFont)
                    .monospacedDigit()
                    .foregroundColor(ClaudeTheme.faint)
            }
            if vm.incidents.isEmpty {
                Text("还没有拦截记录。看门狗没有动过手，就是最好的状态。")
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.muted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.incidents.prefix(4)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            // 中性小方块做列表标记：形状表「这是一条」，颜色不表态（§5 禁彩色糖豆）
                            Rectangle().fill(ClaudeTheme.faint)
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind)
                                    .font(Type.microLabelFont)
                                    .foregroundColor(ClaudeTheme.ink)
                                Text(item.reason)
                                    .font(Type.microFont)
                                    .foregroundColor(ClaudeTheme.muted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(clockText(item.time))
                                .font(Type.microMono)
                                .foregroundColor(ClaudeTheme.faint)
                                .fixedSize()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(ClaudeTheme.iconWell.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            Button { exportJSON() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 9))
                    Text("导出 JSON").font(Type.microLabelFont)
                }
                .foregroundColor(ClaudeTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.iconWell))
            }
            .buttonStyle(.plain)
            .disabled(samples.isEmpty)

            if !exportNote.isEmpty {
                Text(exportNote)
                    .font(Type.microFont)
                    .foregroundColor(ClaudeTheme.success)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Text("采样由 claude-switch.sh check 落盘，界面只读")
                .font(Type.microFont)
                .foregroundColor(ClaudeTheme.faint)
            Button { dismiss() } label: {
                Text("完成")
                    .font(Type.microLabelFont)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous).fill(ClaudeTheme.ink))
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
                        .foregroundColor(ClaudeTheme.faint)
                    Text("还没有采样数据")
                        .font(Type.microFont)
                        .foregroundColor(ClaudeTheme.muted)
                    Text("每次「重新检查」会记一条，多跑几次就有曲线了")
                        .font(Type.microFont)
                        .foregroundColor(ClaudeTheme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Geo.controlRadius, style: .continuous)
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

            area.fill(ClaudeTheme.brand.opacity(0.10))
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
                Text(verbatim: "\(topMS)ms")
                    .font(Type.microMono)
                    .monospacedDigit()
                    .foregroundColor(ClaudeTheme.faint)
                Spacer()
                Text("0")
                    .font(Type.microMono)
                    .monospacedDigit()
                    .foregroundColor(ClaudeTheme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(RoundedRectangle(cornerRadius: Geo.innerRadius, style: .continuous)
            .fill(ClaudeTheme.iconWell.opacity(0.5)))
    }
}

// MARK: - App

// MARK: - 程序坞兜底

/// LSUIElement 的 App 不常驻程序坞,唯一常驻入口就是菜单栏那一项。菜单栏塞满时
/// macOS 会静默折叠多余的项(没有提示),用户看到的就是「双击了、进程在跑、
/// 哪里都没有图标」。这里给一个用户能自己扳回来的开关,并持久化到 UserDefaults,
/// 这样即使菜单栏项已经看不见,也能用一条 defaults write 救回来。
enum DockPreference {
    static let key = "showInDock"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        apply()
    }

    /// 启动时和切换开关时都要走这里,避免两处各写一遍激活策略。
    static func apply() {
        NSApplication.shared.setActivationPolicy(enabled ? .regular : .accessory)
    }
}

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
        DockPreference.apply()
        vm.onSwitchCompleted = { [weak self] in self?.mainWindow?.orderOut(nil) }
        showMainWindow()
        vm.start()
        vm.trackClaudeProcess()
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
            window.title = "Claude 环境检查器"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 860, height: 560)
            window.contentView = NSHostingView(rootView: ContentView(vm: vm))
            window.delegate = self
            window.center()
            mainWindow = window
            // 这里不量高。此刻还没开始检查,16 行全是空的,量出来只有 507pt,
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
        Text("Claude 环境检查器")
        Text("当前槽位：\(vm.current)")
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
        // 菜单栏项被系统折叠后,这是唯一还能把入口找回来的办法 ——
        // 前提是用户还能看见这个菜单,所以同时提供 defaults write 的救急路径。
        Toggle("在程序坞显示图标", isOn: Binding(
            get: { DockPreference.enabled },
            set: { DockPreference.setEnabled($0) }
        ))
        .disabled(vm.isBusy)
        Button("导出诊断日志") { vm.exportDiagnostics() }
            .disabled(vm.settingsBusy)
        Divider()
        Button("退出 Claude 环境检查器") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(!vm.canQuit)
            .onAppear { vm.refreshAccountStatus() }
    }
}

// MARK: - 菜单栏品牌图标
//
// 之前这里直接拿系统符号 checkmark.shield.fill / exclamationmark.shield.fill。
// 窗口标记和 App 图标都换成 Claude 星芒之后，它是唯一还停在「盾牌 + 对号」的地方，
// 偏偏又一直挂在菜单栏上 —— 于是成了最显眼的那枚「不对」的图标。
//
// 现在自绘：复用 GuardShield / ClaudeBurst 两张几何表，把星芒用 destinationOut
// 挖成透明孔，交给 macOS 当模板图渲染（isTemplate）—— 浅色 / 深色菜单栏、点按高亮
// 都自动适配，不需要为两种外观各存一份颜色。
//
// 不用 NSImage.lockFocus()：它按当前屏幕的 backing scale 出图，非 Retina 机器上
// 会掉一半分辨率。这里显式建 2x 位图，几何全部按 pt 写。
enum MenuBarBrand {
    static let side: CGFloat = 18
    private static let scale: CGFloat = 2

    static func image(intercepted: Bool) -> NSImage {
        let px = Int(side * scale)
        // 不能用 NSGraphicsContext(bitmapImageRep:)：它会按 rep.size 自己装一层
        // 2x CTM，再叠一次缩放 + 翻转就会把图标放大到画布外（实测两态都只剩
        // 同一块黑角）。直接建 CGContext，坐标系完全由这里说了算。
        let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 原点在左下；翻成「pt、y 向下」，和 SwiftUI Shape 的坐标一致。
        cg.translateBy(x: 0, y: side * scale)
        cg.scaleBy(x: scale, y: -scale)
        let opaque = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        cg.setFillColor(opaque)
        cg.setAllowsAntialiasing(true)

        // 盾牌 16pt 高、宽高比 0.8，和窗口里 GuardMark 是同一套比例。
        let height = side - 2
        let shieldWidth = height * 0.8
        let shield = CGRect(x: (side - shieldWidth) / 2, y: 1,
                            width: shieldWidth, height: height)
        cg.addPath(GuardShield().path(in: shield).cgPath)
        cg.fillPath()

        // 中间那块孔：正常态是 Claude 星芒，拦截态换成一枚大感叹号。
        // 两态共用同一枚盾牌、同一种「实心块 + 挖空」画法，所以不会像两个应用
        // （11-03 两态字重不统一踩的就是这个坑）。
        //
        // 试过在星芒右下角叠一枚小徽章：18pt 里徽章会盖住星芒右侧的射线，
        // 而且黑徽章压在黑盾上根本看不出轮廓，只剩一根来路不明的感叹号。
        // 直接换孔比叠元素清楚得多。
        cg.setBlendMode(.destinationOut)
        if intercepted {
            let bar: CGFloat = 2.2
            cg.fill(CGRect(x: side / 2 - bar / 2, y: 4.2,
                           width: bar, height: 5.4))
            cg.fillEllipse(in: CGRect(x: side / 2 - bar / 2, y: 11.0,
                                      width: bar, height: bar))
        } else {
            // 毂单挖一次：塞进同一个 Shape 会碰上 addEllipse 与手写多边形
            // 绕向相反、重叠区被抵消的老问题。
            let burstSide = height * 0.52
            let centerY = 1 + height / 2 - height * 0.04
            let burst = CGRect(x: (side - burstSide) / 2, y: centerY - burstSide / 2,
                               width: burstSide, height: burstSide)
            cg.addPath(ClaudeBurst().path(in: burst).cgPath)
            cg.fillPath()
            let hub = height * 0.156
            cg.fillEllipse(in: CGRect(x: side / 2 - hub / 2, y: centerY - hub / 2,
                                      width: hub, height: hub))
        }
        cg.setBlendMode(.normal)

        let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
        rep.size = NSSize(width: side, height: side)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

// 生产应用与 UI 测试共用完全相同的菜单和窗口管理。
struct SwitcherMenu: Scene {
    @ObservedObject var vm: VM
    let controller: AppDelegate

    /// 菜单栏图标是窗口关着时唯一一直可见的品牌符号，所以必须和窗口 / App 图标
    /// 是同一枚标（盾牌 + Claude 星芒），不能再退回系统符号。
    private static let normalImage = MenuBarBrand.image(intercepted: false)

    /// 被拦截时加一枚感叹号徽章，星芒仍在。窗口关着的时候，这是用户唯一能察觉
    /// 「出事了」的入口。
    private static let blockedImage = MenuBarBrand.image(intercepted: true)

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(vm: vm, showWindow: controller.showMainWindow)
        } label: {
            Image(nsImage: vm.intercepted ? Self.blockedImage : Self.normalImage)
                .accessibilityLabel(vm.intercepted ? "Claude 环境检查器：已拦截" : "Claude 环境检查器")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claude 环境检查器") { NSApplication.shared.terminate(nil) }
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
