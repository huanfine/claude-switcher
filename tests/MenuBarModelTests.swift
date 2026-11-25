import Foundation
import AppKit

private let auditKeys = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "IP纯净度", "生态可达性", "DNS泄露"]
private let auditIDs = ["proxy_core", "tun", "egress_ip", "ip_stability", "timezone", "locale", "ipv6", "dns", "webrtc", "bodyguard", "rules", "client_language", "asn", "ip_purity", "ecosystem", "dns_leak"]

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func spin(until condition: () -> Bool, timeout: TimeInterval = 6) throws {
    let limit = Date().addingTimeInterval(timeout)
    while !condition(), Date() < limit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(condition(), "等待异步结果超时")
}

private func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private final class Fixture {
    let root: URL
    let core: URL

    init() throws {
        let trash = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_trash")
        root = trash.appendingPathComponent("menu-bar-model-\(UUID().uuidString)")
        core = root.appendingPathComponent("fake-core.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("audit", auditKeys.map { "\($0)=ok" }.joined(separator: "\n") + "\n")
        try write("status", "current=A hasA=1 hasB=0\n")
        try write("switch-output", "OK:已切换到账号 B\n")
        try write("core-script", """
        #!/bin/bash
        root="$(cd "$(dirname "$0")" && pwd)"
        printf '%s\\n' "$*" >> "$root/calls"
        delay() { if [ -f "$root/$1-delay" ]; then /bin/sleep "$(cat "$root/$1-delay")"; fi; }
        result() { if [ -f "$root/$1-exit" ]; then exit "$(cat "$root/$1-exit")"; fi; }
        case "$1" in
          checkdetail) delay check
            if [ "$2" = "--json" ] && [ -f "$root/check-json-exit" ]; then
              echo '用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|C|D|set-region' >&2
              exit "$(cat "$root/check-json-exit")"
            fi
            if [ "$2" = "--json" ] && [ -f "$root/report-json" ]; then cat "$root/report-json"
            else cat "$root/audit"; fi
            result check ;;
          status) cat "$root/status"; result status ;;
          get-client) echo 'client=clash-verge' ;;
          get-check-config) cat "$root/check-config"; result get-config ;;
          set-check-config) printf '%s\n' "$2" > "$root/saved-config"; result set-config ;;
          switch) delay switch; cat "$root/switch-output"; result switch ;;
          lease) echo 'OK:租约有效至 2099-01-01T00:00:00+00:00' ;;
          # 切槽位现在会先扫一遍节点。默认报告里 BEST 为空 = 没什么可换,
          # 切换流程照旧往下走,不会平白多出一次 node-apply。
          node-scan) delay node-scan
            # 旧核心的表现：不认识这个命令，甩一行老 usage 后 exit 2。
            if [ -f "$root/stale-core" ]; then
              echo '用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|C|D|set-region' >&2
              exit 2
            fi
            if [ -f "$root/node-scan" ]; then cat "$root/node-scan"
            else printf 'CURRENT=A\nCURRENT_SCORE=49\nBEST=\nGATE=auto-ok\n'; fi
            result node-scan ;;
          node-apply) delay node-apply
            if [ -f "$root/node-apply" ]; then cat "$root/node-apply"
            else echo 'FAIL:演示环境没有可应用节点'; fi
            result node-apply ;;
          # 槽位绑定的节点。没有绑定就回 NONE,切换流程照旧走「本次更优」。
          slot-node) case "$2" in
              get) if [ -f "$root/slot-node-$3" ]; then cat "$root/slot-node-$3"; else echo NONE; fi ;;
              set) printf 'SEL\t%s\t%s\n' "$4" "$(date +%s)" > "$root/slot-node-$3"
                   # 界面直接读盘(VM.loadSlotNodes),写两份好让两边看到同一状态。
                   cp "$root/slot-node-$3" "$root/$3"
                   echo "OK:账号$3 已绑定节点 $4" ;;
              clear) rm -f "$root/slot-node-$3" "$root/$3"
                     echo "OK:已解除账号$3 的节点绑定" ;;
              *) exit 2 ;;
            esac ;;
          fix) delay fix; if [ -f "$root/fix-output" ]; then cat "$root/fix-output"; else echo 'FIX:演示修复完成'; fi; result fix ;;
          fingerprint) delay fingerprint; echo 'GPU=ok:演示设备' ;;
          watch)
            # 常驻,直到测试写出 watch-stop 才吐 STOP 行。真脚本靠 curl 判定,
            # 这里只需要验证「界面收到 STOP: 之后怎么反应」。
            # 必须自带寿命上限:场景进程退出后这个子进程会变孤儿,活得越久
            # fork 越多,后面场景就越容易超时失败 —— 表现为「随机某个断言挂了」。
            echo $$ > "$root/watch-pid"
            n=0
            while [ "$n" -lt 50 ]; do
              if [ -f "$root/watch-stop" ]; then
                # 真脚本在 stop_claude_now 里写这一行,这里照着写,界面才读得到。
                printf '%s\t%s\t%s\n' "$(date '+%F %T')" "出口变化" "$(cat "$root/watch-stop")" >> "$root/incidents.log"
                echo "STOP:$(cat "$root/watch-stop")"
                exit 3
              fi
              /bin/sleep 0.1
              n=$((n + 1))
            done
            exit 0 ;;
          *) exit 2 ;;
        esac
        """)
        try FileManager.default.moveItem(at: root.appendingPathComponent("core-script"), to: core)
    }

    deinit {
        // 场景结束必须把后台 watch 收掉。它自己也有寿命上限,这里只是提前收,
        // 别让几十个场景的残留叠在一起抢 CPU。pid 由 fake core 自己写出来,
        // 按 pid 杀比按命令行模糊匹配可靠。
        let pidFile = root.appendingPathComponent("watch-pid")
        if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", root.path]
        if (try? killer.run()) != nil { killer.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func audit(_ changes: [String: String] = [:]) throws {
        try write("audit", auditKeys.map { "\($0)=\(changes[$0] ?? "ok")" }.joined(separator: "\n") + "\n")
    }

    /// 让假核心返回 `claude-switcher-report/2`，用于验证界面优先读 JSON。
    func jsonReport(_ states: [String: String] = [:], verdict: String = "established") throws {
        let checks: [[String: Any]] = zip(auditIDs, auditKeys).map { pair in
            let (id, name) = pair
            let state = states[id] ?? "ok"
            return ["id": id, "name": name, "state": state,
                    "detail": "JSON:\(state)", "known": true]
        }
        let report: [String: Any] = [
            "schema": "claude-switcher-report/2", "protocol": 2,
            "verdict": verdict, "checks": checks,
            "summary": ["missing": [], "missing_critical": [], "duplicates": []],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        // 真实核心可能先在 stderr 打一行环境警告，run() 会把 stdout/stderr 合并。
        // 这里把警告也带上，锁住“只取最后一条 JSON”的解析行为。
        try write("report-json", "WARN:环境层缺失,使用保底值\n"
                 + String(decoding: data, as: UTF8.self) + "\n")
    }

    func vm(checkTimeout: TimeInterval = 2, operationTimeout: TimeInterval = 2) -> VM {
        let model = VM(core: core.path, checkTimeout: checkTimeout, operationTimeout: operationTimeout)
        // 拦截记录指到夹具目录:真实路径里是本机真实历史,断言会随环境飘。
        model.incidentsPath = root.appendingPathComponent("incidents.log").path
        return model
    }

    var rawCalls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// 用户/流程动作。看门狗是后台守护,由检查结果自动启停,不属于用户发起的动作序列 ——
    /// 混进来会让「启动不应重复检查」这类断言失去意义。要查它用 rawCalls。
    var calls: [String] { rawCalls.filter { !$0.hasPrefix("watch ") } }

    func idle(_ vm: VM) throws { try spin { !vm.isBusy } }

    func deniedSwitch(_ vm: VM) throws {
        vm.switchTo("B")
        try idle(vm)
        try expect(vm.phase == .failed, "审计异常应阻断切换")
        try expect(!calls.contains { $0.hasPrefix("switch ") }, "审计异常仍执行了 switch")
        try expect(vm.canQuit, "失败后应该可以退出")
    }
}

@main
struct MenuBarModelTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw TestFailure(description: "缺少测试场景") }
            let name = CommandLine.arguments[1]
            let f = try Fixture()
            switch name {
            case "startup_once":
                let vm = f.vm()
                vm.start(); vm.start()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail --json", "get-client", "status"], "启动不应重复检查")
                try expect(vm.phase == .ready && vm.lastCheckSummary == "通过" && vm.current == "A", "初始状态不一致")
            case "json_report_preferred":
                // 核心给 JSON 时按稳定 ID 填行，不再依赖中文文本；
                // 这里故意让文本审计全绿、JSON 的出口 IP 为 fail。
                try f.jsonReport(["egress_ip": "fail"], verdict: "violated")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                guard let egress = vm.rows.first(where: { $0.name == "出口 IP" }) else {
                    throw TestFailure(description: "找不到「出口 IP」行")
                }
                try expect(egress.state == .fail, "JSON 的 fail 应传入界面")
                try expect(egress.detail.contains("JSON:fail"), "应使用 JSON detail，实际 \(egress.detail)")
                try expect(vm.phase == .failed, "violated 报告不应放行")
                try expect(f.calls == ["checkdetail --json", "get-client", "status"],
                           "JSON 成功时只能检查一次，实际 \(f.calls)")
            case "stale_checkdetail_falls_back":
                // 旧核心不认识 --json，退出码 2 + usage；必须补跑文本命令，
                // 不能把版本不兼容误报成安全项失败。
                try f.write("check-json-exit", "2")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.phase == .ready, "旧核心回退文本后应通过")
                try expect(f.calls == ["checkdetail --json", "checkdetail", "get-client", "status"],
                           "旧核心只应多补跑一次文本检查，实际 \(f.calls)")
            case "json_pass_issues_lease":
                // JSON 检查通过后必须先签发租约，再允许切换/拉起。
                try f.jsonReport()
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.phase == .ready, "JSON 通过后应就绪")
                try expect(f.calls == ["checkdetail --json", "get-client", "status", "lease"],
                           "通过后必须签发一次租约，实际 \(f.calls)")
            case "json_all_skipped_blocks":
                // 全部 skip 时报告是 incomplete；16/16 行都有值也不能放行。
                try f.jsonReport(Dictionary(uniqueKeysWithValues: auditIDs.map { ($0, "skip") }),
                                 verdict: "incomplete")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.phase == .failed, "全 skip 的 incomplete 报告必须拦启动")
                try expect(vm.banner.contains("没有任何项目被真正验证"),
                           "要说清为什么不能启动，实际 \(vm.banner)")
                try expect(vm.lastCheckSummary == "失败", "摘要不能写成通过（含跳过）")
            case "multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18 cliA=151M@2026-11-04\n")
                try f.write("switch-output", "OK:已切换到账号 C\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.archived == Set(["A", "B", "C"]), "应解析三个已建档账号")
                try expect(vm.stamps["A"] == AccountStamp(size: "1.2G", date: "2026-10-20"), "应解析账号大小与日期")
                try expect(vm.cliStamps["A"] == AccountStamp(size: "151M", date: "2026-11-04"),
                           "槽位里的 Claude Code 存档体积要单独解析，实际 \(vm.cliStamps)")
                try expect(vm.cliStamps["B"] == nil, "没有 CLI 存档的槽位不该冒出角标")
                let card = ContentView(vm: vm)
                // 卡片是两行:第一行状态,第二行体积和日期。两行都要断言,
                // 否则状态和它的存档信息对不上也发现不了。
                //
                // 状态词描述的是**槽位此刻的事实**,不是「你在用哪个账号」,
                // 也不是「登录了没有」—— 登录态是右边那条独立的小字。
                // 所以它带「当前」前缀把轴说明白:
                //   当前 · 运行中 = 这个槽位在用,Claude 开着
                //   当前 · 未启动 = 这个槽位在用,但 Claude 没开
                // 原来写「使用中 / 未运行」:前者和右边的「已登录」读起来像同一类
                // 结论,后者又像在说这个槽位坏了。
                try expect(card.accountStateLabel("A") == "当前 · 未启动" && card.accountSubtitle("A") == "1.2G · 10-20",
                           "Claude 未启动时,当前槽位应写「当前 · 未启动」")
                #if CLAUDE_SWITCHER_TESTS
                vm.setClaudeRunningForTest(true)
                try expect(card.accountStateLabel("A") == "当前 · 运行中",
                           "Claude 在运行时,当前槽位应写「当前 · 运行中」")
                try expect(card.accountStateLabel("B") == "已保存",
                           "非当前槽位不该跟着变成「当前 · 运行中」")
                vm.setClaudeRunningForTest(false)
                #endif
                try expect(card.accountStateLabel("B") == "已保存" && card.accountSubtitle("B") == "900M · 10-19",
                           "已保存的槽位应带大小与日期")
                // 空槽位不再给占位文字:卡片上「未初始化」+「点击绑定」已经说完了,
                // 再来一行「空」是同一件事的第三种说法。副标题返回空串,视图整行省略。
                try expect(card.accountStateLabel("D") == "未初始化" && card.accountSubtitle("D").isEmpty,
                           "空槽位不应再有第三句「空」")
                vm.switchTo("C"); try f.idle(vm)
                try expect(vm.current == "C" && vm.note.isEmpty, "已建档的 C 不应提示首次登录")
                try expect(f.calls.contains("switch C"), "C 应被允许切换")
            case "first_use_cd_note":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C\n")
                try f.write("switch-output", "OK:已切换到账号 D\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                vm.switchTo("D"); try f.idle(vm)
                try expect(vm.current == "D", "D 应被允许切换")
                try expect(vm.note.contains("D 号首次使用") && vm.note.contains("登录"), "D 首次使用应提示登录")
            case "legacy_status_fallback":
                try f.write("status", "current=B hasA=1 hasB=1\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.current == "B" && vm.archived == Set(["A", "B"]), "旧版 status 应回退为 A/B")
            case "invalid_multi_account_status":
                // 用 Z 当非法值:E 现在是合法槽位(A–H),拿它当反例会静默失效。
                try f.write("status", "current=A hasA=1 hasB=0 hasC=0 hasD=0 accounts=A,Z\n")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "非法账号列表不可进入界面")
            case "warnings_allowed":
                try f.audit(["ASN属性": "warn:演示机房"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.lastCheckSummary == "有警告" && vm.current == "B", "警告应展示并允许切换")
                try expect(f.calls == ["checkdetail --json", "get-client", "status", "slot-node get B",
                                  "node-scan", "switch B"],
                           "切换前必须先完整审计,再扫一遍节点")
            case "skipped_optional_allowed":
                try f.audit(["DNS": "skip:用户已禁用", "WebRTC": "skip:用户已禁用"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.phase == .done && vm.current == "B", "显式跳过的非关键项不应阻断切换")
                try expect(vm.rows.first { $0.name == "DNS 走隧道" }?.state == .skip, "跳过项必须显示 skip")
            case "settings_round_trip":
                try f.write("check-config", #"{"disabled":["DNS"],"allowOptionalFailures":true,"logging":false,"strict":["生态可达性"]}"#)
                let vm = f.vm()
                vm.loadCheckConfig()
                try spin { !vm.settingsBusy }
                try expect(vm.disabledChecks == Set(["DNS"]), "应读取已禁用的 DNS 检查")
                try expect(vm.allowOptionalFailures && !vm.loggingEnabled, "应读取非关键失败与日志设置")
                try expect(vm.strictChecks == Set(["生态可达性"]), "应读取被设成安全基线的项")
                vm.disabledChecks.insert("WebRTC")
                vm.saveCheckConfig()
                try spin { !vm.settingsBusy }
                try f.idle(vm)
                let saved = try String(contentsOf: f.root.appendingPathComponent("saved-config"), encoding: .utf8)
                guard let data = saved.data(using: .utf8) else { throw TestFailure(description: "配置不是有效 UTF-8") }
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let disabled = config?["disabled"] as? [String]
                try expect(Set(disabled ?? []) == Set(["DNS", "WebRTC"]), "保存必须保留已有禁用项并加入 WebRTC")
                try expect(config?["allowOptionalFailures"] as? Bool == true, "保存必须保留非关键失败设置")
                try expect(config?["logging"] as? Bool == false, "保存必须保留日志开关")
                // 保存时若把 strict 丢了,用户设过的安全基线会静默失效,界面还看不出来。
                let strict = config?["strict"] as? [String]
                try expect(strict == ["生态可达性"], "保存必须原样带回安全基线")
                try expect(f.calls.contains("checkdetail --json"), "保存成功后必须重新检查")
            case "local_status_refresh":
                let vm = f.vm()
                vm.refreshAccountStatus()
                try expect(f.calls.isEmpty, "菜单提前出现时不可抢占启动审计")
                vm.start(); try f.idle(vm)
                try f.write("status", "current=B hasA=1 hasB=1\n")
                vm.refreshAccountStatus(); try f.idle(vm)
                try expect(f.calls == ["checkdetail --json", "get-client", "status", "status"], "展开菜单只应读取本地状态")
                try expect(vm.current == "B" && vm.lastCheckSummary == "通过", "账号更新不应改变上次审计结果")
            case "fresh_audit":
                let vm = f.vm()
                vm.refresh(); try f.idle(vm)
                try f.audit(["TUN网卡": "fail:已断开"])
                try f.deniedSwitch(vm)
                try expect(f.calls.filter { $0.hasPrefix("checkdetail") }.count == 2, "不可复用上次通过结果")
            case "failed_check":
                try f.audit(["WebRTC": "fail:演示失败"])
                try f.deniedSwitch(f.vm())
            case "check_grouping":
                // 主界面不再按「能不能关」分组 —— 默认全部拦启动,分组反而让人
                // 以为「有些可以不拦」。但「哪几项允许在设置里关掉」这个数据关系仍然要锁住:
                // 它必须和设置页的开关完全一致,否则会出现「关不掉」或「关了还拦」。
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.rows.count == 16, "检查项应为 16 项(含「DNS泄露」)")
                let soft = Set(vm.rows.filter { $0.canDisable }.map { $0.name })
                let expected = Set(VM.optionalChecks.map { $0.label })
                try expect(soft == expected, "可关闭项与设置页不一致:\(soft.sorted()) vs \(expected.sorted())")
                try expect(vm.rows.filter { !$0.canDisable }.count == 8, "硬性项应为 8 项")
                try expect(vm.disabledChecks.isEmpty, "默认不该有任何一项被关闭")
            case "config_only_failure":
                // 环境层没配好 ≠ 不安全。仍然拦启动(没验证过不能当通过),
                // 但提示语必须指向「补配置」,不能让用户去排查安全问题。
                try f.audit(["规则置顶": "config:环境层未就绪(未取到代理组) · 点「一键修复」"])
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.rows.first { $0.name == "规则置顶" }?.state == .config, "行状态应为 config")
                try expect(vm.configOnlyFailure, "只缺配置时应识别为待配置")
                try expect(vm.lastCheckSummary == "待配置", "摘要应写待配置,不是失败")
                try expect(vm.banner.contains("环境没配好"), "提示语不能说成不安全")
            case "config_and_fail":
                // 真实失败优先:有安全项不达标时,不能只说「待配置」。
                try f.audit(["规则置顶": "config:环境层未就绪 · 点「一键修复」",
                             "出口IP": "fail:当前 1.2.3.4/JP,期望 US · 换到 US 节点"])
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(!vm.configOnlyFailure, "有真实失败时不能只说待配置")
                try expect(vm.lastCheckSummary == "失败", "有真实失败时摘要应为失败")
                try expect(vm.banner.contains("未通过") && vm.banner.contains("出口 IP"),
                           "应点名真实失败项")
                try expect(!vm.banner.contains("环境没配好"), "真实失败不应被配置问题盖住")
            case "incomplete_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n"))
                try f.deniedSwitch(f.vm())
            case "duplicate_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n") + "\n代理内核=ok\n")
                try f.deniedSwitch(f.vm())
            case "duplicate_overwrite":
                try f.audit(["TUN网卡": "fail:断开"])
                let s = try String(contentsOf: f.root.appendingPathComponent("audit"), encoding: .utf8)
                try f.write("audit", s + "TUN网卡=ok\n")
                try f.deniedSwitch(f.vm())
            case "empty_check":
                try f.write("audit", "")
                try f.deniedSwitch(f.vm())
            case "unknown_check_code":
                try f.audit(["TUN网卡": "unknown"])
                try f.deniedSwitch(f.vm())
            case "empty_check_code":
                try f.audit(["TUN网卡": ""])
                try f.deniedSwitch(f.vm())
            case "nonzero_check":
                try f.write("check-exit", "7")
                try f.deniedSwitch(f.vm())
            case "timeout_check":
                try f.write("check-delay", "3")
                let vm = f.vm(checkTimeout: 0.1)
                try f.deniedSwitch(vm)
                try expect(vm.lastCheckSummary == "失败" && vm.banner.contains("超时"), "超时不可展示通过")
            case "invalid_status":
                try f.write("status", "current=B hasB=1")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "账号读取失败不可沿用旧状态")
                try expect(vm.lastCheckSummary == "失败", "账号读取失败时菜单不可显示通过")
            case "nonzero_status":
                try f.write("status-exit", "1")
                try f.deniedSwitch(f.vm())
            case "switch_note_then_failure":
                try f.write("switch-output", "NOTE:开始切换\nFAIL:模拟归档失败\n")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "NOTE 后的 FAIL 不可当作成功")
            case "empty_switch":
                try f.write("switch-output", "")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "空切换结果不可当作成功")
            case "nonzero_switch":
                try f.write("switch-exit", "4")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "非零退出即使打印 OK 也不可当作成功")
            case "timeout_switch":
                try f.write("switch-delay", "3")
                let vm = f.vm(operationTimeout: 0.1)
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A" && vm.canQuit, "切换超时应恢复可操作状态")
            case "busy_guard":
                try f.write("switch-delay", "0.2")
                let vm = f.vm()
                vm.switchTo("B")
                try expect(!vm.canQuit, "切换请求开始后不可退出")
                vm.switchTo("A"); vm.refresh(); vm.fixAll(); vm.inspectFingerprint()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail --json", "get-client", "status", "slot-node get B",
                                  "node-scan", "switch B"],
                           "忙碌时应忽略重复操作")
                try expect(vm.canQuit && vm.current == "B", "切换完成后应允许退出")
            case "fix_guard":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                vm.fixAll()
                try expect(!vm.canQuit, "修复期间不可退出")
                vm.refresh(); vm.switchTo("B"); vm.fixAll()
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail --json", "get-client", "status"], "修复结束必须重新检查，不能并行执行")
                try expect(vm.canQuit && vm.phase == .ready, "修复后应该可以退出")
            case "watch_after_pass":
                // 启动门禁只管拉起那一刻。通过之后必须立刻把运行期守护挂上,
                // 否则「用着用着出口被换」这条路上没人看。
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try spin { f.rawCalls.contains("watch 10 6") }
                try expect(vm.phase == .ready, "守护启动不该改变检查结论")
                try expect(!vm.intercepted, "正常守护期间不该显示拦截态")
                try expect(vm.lastCheckSummary == "通过", "摘要仍应是检查结果")
            case "watch_not_started_on_failure":
                // 没通过就不该起守护:拿一个已经失效的结论去守护,比不守护更糟。
                try f.audit(["WebRTC": "fail:演示失败"])
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                pump(0.4)
                try expect(!f.rawCalls.contains { $0.hasPrefix("watch ") }, "检查未通过不该起守护")
            case "watch_blocks_on_stop":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try spin { f.rawCalls.contains("watch 10 6") }
                try f.write("watch-stop", "出口 IPv4 变了(1.2.3.4 → 5.6.7.8)")
                try spin { vm.phase == .failed }
                try expect(vm.banner.contains("出口 IPv4 变了"), "必须说清为什么停掉 Claude")
                try expect(vm.lastCheckSummary == "已拦截", "摘要应写已拦截,不能还挂着通过")
                try expect(vm.intercepted, "拦截态必须置位,菜单栏图标要跟着变")
                try expect(vm.canQuit, "拦截后应允许退出")
                // 拦截原因不能只活在 banner 里:用户关掉窗口再回来就没了。
                try expect(vm.incidents.count == 1, "拦截后应立刻读到刚写的记录")
                try expect(vm.incidents.first?.kind == "出口变化", "类型应来自脚本")
                try expect(vm.incidents.first?.reason.contains("1.2.3.4") == true, "原因应完整")
                // 重新检查要把拦截态清掉,否则修好之后界面还挂着红色的「已拦截」。
                // 先撤掉 watch-stop,否则新起的守护会立刻再读一次、又把自己停掉。
                try? FileManager.default.removeItem(at: f.root.appendingPathComponent("watch-stop"))
                vm.refresh(); try f.idle(vm)
                try expect(!vm.intercepted, "重新检查后应清除拦截态")
            case "watch_restart_drops_old_guard":
                // 重新检查时旧守护必须撤掉。否则它会拿上一轮的出口基线继续比对,
                // 检查还没跑完就先按旧结论把 Claude 关了。
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try spin { f.rawCalls.contains("watch 10 6") }
                vm.refresh(); try f.idle(vm)
                try expect(vm.phase == .ready, "重新检查后仍应就绪")
                try expect(vm.lastCheckSummary == "通过", "重新检查应重新得出结论")
            case "watch_stop_kills_process":
                // 「发了 SIGTERM」不等于「进程停了」。实测 bash 卡在 sleep 里时能拖到
                // 下一轮,这期间新守护撞上旧的,两边各拿一份基线判出口。
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try spin { f.rawCalls.contains("watch 10 6") }
                let pidFile = f.root.appendingPathComponent("watch-pid")
                var raw = ""
                for _ in 0..<60 {
                    raw = (try? String(contentsOf: pidFile, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !raw.isEmpty { break }
                    pump(0.05)
                }
                guard let vpid = pid_t(raw), vpid > 1 else { throw TestFailure(description: "看门狗没写出 pid") }
                vm.stopWatch()
                try spin(until: { kill(vpid, 0) != 0 }, timeout: 4)
            case "incidents_loaded":
                try f.write("incidents.log",
                            "2026-11-02 11:48:57\t出口变化\t1.2.3.4 → 5.6.7.8\n"
                            + "2026-11-02 11:54:01\t检查未通过\t时区不符\n")
                let vm = f.vm()
                vm.loadIncidents()
                try expect(vm.incidents.count == 2, "应解析两条记录")
                try expect(vm.incidents.first?.kind == "检查未通过", "最新的排在最前")
                try expect(vm.incidents.first?.reason == "时区不符", "原因列应完整")
                try expect(vm.incidents.last?.kind == "出口变化", "最旧的排在最后")
            case "incidents_malformed_ignored":
                // 缺列的行整条丢掉:显示半条比不显示更糟,用户会以为原因就这些。
                try f.write("incidents.log",
                            "只有一列\n"
                            + "2026-11-02 11:00:00\t出口变化\n"
                            + "2026-11-02 11:01:00\t代理断开\t探测连续 3 次失败\n")
                let vm = f.vm()
                vm.loadIncidents()
                try expect(vm.incidents.count == 1, "缺列的行应被丢掉")
                try expect(vm.incidents.first?.kind == "代理断开", "保留的那条应完整")
            case "announcements_parse_and_filter":
                // 公告缓存 → 界面列表:schema/字段守门、版本过滤、severity 排序
                let payload: [String: Any] = [
                    "schema": 1,
                    "items": [
                        ["id": "2026-01-01-info", "severity": "info", "title": "通知",
                         "body_md": "", "min_app_version": "1.8.12", "max_app_version": ""],
                        ["id": "2026-01-02-crit", "severity": "critical", "title": "紧急",
                         "body_md": "x", "min_app_version": "", "max_app_version": ""],
                        ["id": "2026-01-03-old", "severity": "warn", "title": "旧版可见",
                         "body_md": "", "min_app_version": "9.9.9", "max_app_version": ""],
                        // 缺 title 必须丢弃,不能让界面崩
                        ["id": "2026-01-04-bad", "severity": "info"],
                    ] as [[String: Any]],
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let parsed = AnnouncementStore.parseCache(data, appVersion: "1.8.13")
                try expect(parsed.count == 2, "应只剩 2 条(min 过滤 + 坏数据丢弃),实际 \(parsed.count)")
                try expect(parsed[0].severity == "critical", "critical 必须排最前")
                try expect(parsed[1].id == "2026-01-01-info", "第二条应是 info")
                // schema 非 1 → 整包拒绝
                let badSchema = try JSONSerialization.data(withJSONObject: ["schema": 2, "items": []])
                try expect(AnnouncementStore.parseCache(badSchema, appVersion: "1.8.13").isEmpty,
                           "schema 非 1 必须整包拒绝")
                // 非法 JSON → 空,不是崩
                try expect(AnnouncementStore.parseCache(Data("{{{".utf8), appVersion: "1.8.13").isEmpty,
                           "坏 JSON 必须返回空列表")
            case "announcements_version_gate":
                // 版本门:边界值(含/不含)、-dev 后缀、空版本不误杀
                try expect(AnnouncementStore.versionOK(minV: "1.8.12", maxV: "", current: "1.8.13"),
                           "当前高于 min 应可见")
                try expect(!AnnouncementStore.versionOK(minV: "1.8.13", maxV: "", current: "1.8.12"),
                           "当前低于 min 应被滤掉")
                try expect(!AnnouncementStore.versionOK(minV: "", maxV: "1.8.10", current: "1.8.12"),
                           "高于 max 应被滤掉")
                try expect(AnnouncementStore.versionOK(minV: "", maxV: "1.8.12", current: "1.8.12"),
                           "等于 max 应可见(闭区间)")
                try expect(AnnouncementStore.versionCompare("1.8.13-dev", "1.8.13") == 0,
                           "-dev 后缀应被忽略")
                try expect(AnnouncementStore.versionCompare("1.8.2", "1.8.10") == -1,
                           "必须按数值比较,不是字符串(2 < 10 但 \"2\" > \"10\")")
                try expect(AnnouncementStore.versionOK(minV: "1.8.12", maxV: "", current: ""),
                           "拿不到版本时不应误杀公告")
            case "announcements_unread_and_critical_gate":
                // 未读判定 + critical 限频:24h 至多打扰一次
                let a = Announcement(id: "x", severity: "critical", title: "t", body: "", link: "")
                let b = Announcement(id: "y", severity: "info", title: "t", body: "", link: "")
                let seen: Set<String> = [AnnouncementStore.sha256Hex("y")]
                let unread = AnnouncementStore.unreadIDs(items: [a, b], seen: seen)
                try expect(unread == ["x"], "已读 y 不该再算未读,实际 \(unread)")
                let sev = ["x": "critical", "y": "info"]
                try expect(AnnouncementStore.shouldAutoOpenCritical(now: 1000, last: nil,
                                                                   unread: unread, severities: sev),
                           "首次 critical 未读应允许弹窗")
                try expect(!AnnouncementStore.shouldAutoOpenCritical(now: 1000 + 3600, last: 1000,
                                                                     unread: unread, severities: sev),
                           "24h 内已弹过就不该再弹")
                try expect(AnnouncementStore.shouldAutoOpenCritical(now: 1000 + 24 * 3600, last: 1000,
                                                                    unread: unread, severities: sev),
                           "过 24h 应允许再次弹窗")
                // 只有 info 未读 → 永不自动弹窗
                let infoOnly = AnnouncementStore.unreadIDs(items: [b], seen: [])
                try expect(!AnnouncementStore.shouldAutoOpenCritical(now: 1000, last: nil,
                                                                     unread: infoOnly,
                                                                     severities: ["y": "info"]),
                           "info 级不应触发自动弹窗")
                try expect(AnnouncementStore.severityRank("critical") < AnnouncementStore.severityRank("warn")
                           && AnnouncementStore.severityRank("warn") < AnnouncementStore.severityRank("info"),
                           "severity 排序权重:critical < warn < info")
            case "incidents_missing_file":
                let vm = f.vm()
                vm.loadIncidents()
                try expect(vm.incidents.isEmpty, "没有记录文件时应为空,不是崩掉")
            case "health_score_gates_on_hard_failure":
                // 首页那个大数字是用户唯一会看的结论。曾经硬性项全挂还显示 85 分,
                // 因为分数只按「项数」扣 —— 等于告诉用户「小毛病,能用」。
                // 硬性项(不可关闭的那 8 项)是「Claude 能不能启动」的开关,
                // 一失败就必须塌到低位,并且结论要直说「不会启动」。
                func rows(_ overrides: [String: RowState],
                          details: [String: String] = [:]) -> [CheckRow] {
                    let hard = ["代理内核", "TUN网卡", "出口IP", "时区", "地区", "IPv6", "保镖", "规则置顶"]
                    let soft = ["IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "IP纯净度", "生态可达性", "DNS泄露"]
                    return (hard.map { ($0, false) } + soft.map { ($0, true) }).map { name, disable in
                        CheckRow(name: name, icon: "circle", canDisable: disable,
                                 state: overrides[name] ?? .ok,
                                 detail: details[name] ?? "")
                    }
                }

                // 全通过 = 100
                let clean = HealthSummary.evaluate(rows([:]))
                try expect(clean.score == 100 && clean.level == .ok, "全通过应满分且判定为 ok")
                try expect(clean.headline.contains("可以正常启动"), "全通过要直说能启动")

                // 只掉提示项:还能启动,分数只是略降。
                //
                // 四维加权之后这一格是 90(旧口径是「每条警告一律 6 分」→ 88):
                //   · ASN 属性  → 身份维度 −6
                //   · 生态可达性 → 一致维度 −4
                // 两条都是「离散事实」,没有实测分可折算,所以按固定权重扣。
                // 旧口径的毛病不在数字大小,在于**所有警告等价** —— 车库里那台
                // 转租机房(纯净度 49)和「时区格式不对」扣一样多,于是最该被看见的
                // 那件事被摊平了。现在重的东西在身份维度里按实测分折算,见下一格。
                let notices = HealthSummary.evaluate(rows(["ASN属性": .warn, "生态可达性": .warn]))
                try expect(notices.level == .notice, "提示项不该被判成无法启动")
                try expect(notices.score == 90, "ASN −6、生态 −4，应为 90，实际 \(notices.score)")
                try expect(notices.badge == "可以启动", "提示项的徽章要直说「可以启动」")
                // 结论要点名最重的那一项,而不是只报项数 ——
                // 只报「2 项建议处理」等于让用户自己去猜哪个要紧。
                try expect(notices.headline.contains("ASN属性"), "结论要点最重的那一项，实际 \(notices.headline)")
                try expect(notices.headline.contains("另有 1 项提示"), "其余项一句话带过，实际 \(notices.headline)")
                try expect(notices.headline.contains("不影响启动"), "要说清不拦启动，实际 \(notices.headline)")

                // 真机那一次:三个警告,最重的是纯净度 49 分(转租机房)。
                // 旧结论只说「3 项建议处理,不影响使用」,把「出口是机房」这件事压掉了 ——
                // 这正是用户当场质疑「49 分和 82 分放一起不合理」的地方。
                //
                // 第一次修只改了结论那句话(点名纯净度),分数仍是 82 —— 用户的
                // 第二次反馈是「我们 ip 评分这么低但是还有 88 分,会误会以为特别安全」。
                // 第二次修把总分压成 min(扣分结果, 各实测分) = 49,结果用户第三次说
                // 「不能只是拿 ip 纯净度做评分」—— 那个写法等于总分**就是**纯净度分,
                // 一个维度吞掉了另外三个。
                //
                // 现在是四维加权,这一格的算术(可以逐项复核):
                //   身份:纯净度 round((100−49) × 0.4) = 20  ← 单项里最重的一笔
                //        + ASN 属性 6 + IP 一致 4 = 30
                //   其余三维全通过 = 0
                //   → 100 − 30 = 70
                // 也就是说:纯净度 49 分这件事**确实**把总分从 94 拖到 70(比两条
                // 提示加起来还重四倍),但它不再是全部 —— 这正是「综合考量」要的形状。
                let three = HealthSummary.evaluate(rows(
                    ["IP一致": .warn, "ASN属性": .warn, "IP纯净度": .warn],
                    details: ["IP纯净度": "评分 49/100 · 机房 · RouterHosting LLC · 地理模糊"]))
                try expect(three.score == 70, "纯净度 49 → 身份 30 分，应为 70，实际 \(three.score)")
                try expect(three.headline.contains("IP 纯净度") || three.headline.contains("IP纯净度"),
                           "结论要点纯净度，实际 \(three.headline)")
                // 2026-11-06:这里改成「49/100」而不是「49 分」。首页的环里已经
                // 不再有任何分数,这句话如果再裸写「49 分」,读者会把它当成
                // 「这台机器 49 分」—— 又回到「分数让人误会」那个坑里。
                // 量级仍然必须带出来,只是要标明它是百分制参照分。
                try expect(three.headline.contains("49/100"),
                           "量级要带出来，且标明是百分制参照分，实际 \(three.headline)")
                try expect(three.headline.contains("另有 2 项提示"), "另外两项一句话带过，实际 \(three.headline)")

                // 权重的三条性质,分开钉住 —— 以后谁调权重,这几条会立刻告诉他
                // 调坏了哪一条:
                //
                // (1) 幂等:分数只由行状态决定,和顺序无关。
                let reordered = HealthSummary.evaluate(rows(
                    ["IP纯净度": .warn, "ASN属性": .warn, "IP一致": .warn],
                    details: ["IP纯净度": "评分 49/100 · 机房 · RouterHosting LLC · 地理模糊"]))
                try expect(reordered.score == three.score, "同样的行换个顺序不该换分数")

                // (2) 纯净度是**单项最重**:它一个人(80)比两条离散提示加起来(90)还低。
                let purityOnly = HealthSummary.evaluate(rows(
                    ["IP纯净度": .warn], details: ["IP纯净度": "评分 49/100 · 机房"]))
                try expect(purityOnly.score == 80, "纯净度 49 单独应为 80，实际 \(purityOnly.score)")
                try expect(purityOnly.score < notices.score,
                           "纯净度 49 一个人要比两条提示加起来更重（\(purityOnly.score) vs \(notices.score)）")

                // (3) 四个维度的上限加起来正好 100:每个维度都打到上限时总分归零,
                //     不会出现「什么都错了还剩 40 分」这种事。
                //     注意这里全用 warn 而不是 fail —— 硬性项一 fail 就走短路(≤28),
                //     走不到加权分支;能让四个维度同时打满的只有「一堆 warn + 几个软 fail」。
                let everythingBad = HealthSummary.evaluate(rows([
                    // 身份 = 40(纯净度 0 分折算满) + 6 + 4 = 50 → 封顶 40
                    "IP纯净度": .warn, "ASN属性": .warn, "IP一致": .warn,
                    // 隔离 = 10 + 10 + 8 + 12 = 40 → 封顶 30
                    "IPv6": .warn, "TUN网卡": .warn, "DNS": .fail, "WebRTC": .fail,
                    // 一致 = 6 + 4 + 3 + 4 = 17 → 封顶 15
                    "时区": .warn, "地区": .warn, "客户端语言": .fail, "生态可达性": .warn,
                    // 守护 = 8 + 7 + 8 = 23 → 封顶 15
                    "保镖": .warn, "规则置顶": .warn, "代理内核": .warn,
                ], details: ["IP纯净度": "评分 0/100 · 机房"]))
                try expect(everythingBad.score == 0, "四维全打满应归零，实际 \(everythingBad.score)")

                // (4) 「DNS泄露」进身份维度,权重 4;它是可修复项不是故障,
                //     而且用户关掉(可关闭项)绝不能算扣分。
                let betterNode = HealthSummary.evaluate(rows(["DNS泄露": .warn]))
                try expect(betterNode.score == 96, "DNS泄露 warn 应只扣 4 分，实际 \(betterNode.score)")
                let notScanned = HealthSummary.evaluate(rows(["DNS泄露": .skip]))
                try expect(notScanned.score == 100, "用户关闭的项不该扣分，实际 \(notScanned.score)")
                let disabled = HealthSummary.evaluate(rows(["IP一致": .skip]))
                try expect(disabled.score == 100, "用户关掉的检查项不该拉低总分，实际 \(disabled.score)")

                // 硬性项一旦松动,压过任何提示项 —— 它本来就是拦启动的开关
                let hardWarnFirst = HealthSummary.evaluate(rows(
                    ["时区": .warn, "IP纯净度": .warn],
                    details: ["IP纯净度": "评分 49/100 · 机房"]))
                try expect(hardWarnFirst.headline.contains("时区"),
                           "硬性项的警告要先说，实际 \(hardWarnFirst.headline)")

                // 硬性项失败:必须塌到 30 分以下,并且说「不会启动」
                let broken = HealthSummary.evaluate(rows(["代理内核": .fail]))
                try expect(broken.level == .cannotStart, "硬性项失败必须判定为无法启动")
                try expect(broken.score < 30, "无法启动时分数必须塌到 30 以下，实际 \(broken.score)")
                try expect(broken.headline.contains("代理内核"), "结论要点名是哪一项没过")
                try expect(broken.headline.contains("不会启动"), "结论要说清后果，不能只说「未通过」")

                // 再多挂一项硬性,分数只会更低,不会反弹
                let worse = HealthSummary.evaluate(rows(["代理内核": .fail, "TUN网卡": .fail]))
                try expect(worse.score < broken.score, "硬性项挂得越多分越低")
                try expect(worse.headline.contains("另有"), "多项失败要说清还有几项")

                // 硬性项失败 + 提示项一堆,依然是「无法启动」,不能被提示项稀释
                let mixed = HealthSummary.evaluate(rows(["出口IP": .fail, "DNS": .warn,
                                                         "ASN属性": .warn, "WebRTC": .warn]))
                try expect(mixed.level == .cannotStart && mixed.score < 30,
                           "提示项再多也不能把「无法启动」抬回可启动")
            case "fix_note_explains_failure":
                // 修不了的时候只写「需手动处理」等于没说。脚本本来就把原因写在
                // ✗ 后面,界面必须把它捞出来显示。
                try expect(VM.fixNote(from: "代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)")
                           == "请打开 Clash Verge 检查节点/线路", "✗ 后面的括号内容就是原因")
                try expect(VM.fixNote(from: "时区/IPv6/保镖 ✗(取消或失败)") == "取消或失败",
                           "括号要剥掉")
                try expect(VM.fixNote(from: "置顶规则 ✗ 未验证内核加载:ok") == "未验证内核加载:ok",
                           "没有括号就取符号后面整段")
                try expect(VM.fixNote(from: "Claude 客户端语言 → en-US ✓(重启 Claude 后生效)")
                           == "重启 Claude 后生效", "成功也要带前提")
                try expect(VM.fixNote(from: "时区/IPv6/保镖 无需修复 ✓").isEmpty,
                           "符号后面没内容就不该编一句附注")
                // 没有 ✓/✗ 但明显是失败的行(脚本里真有),整句就是原因
                try expect(VM.fixNote(from: "FlClash 未能退出，请手动退出后重试")
                           == "FlClash 未能退出，请手动退出后重试", "无符号的失败行要整句保留")
            case "fix_warn_is_note":
                // ⚠ 这一档既不是「已修复」也不是「需手动」。
                // 实测:节点没有 IPv4 出口时 WebRTC 打的是「无法比对(非泄漏)」——
                // 它天然带「无法」两个字,先跑失败词表就会判成 ✗ 需手动,红色徽章,
                // 而用户没有任何手动动作可做。
                try f.write("fix-output", """
                FIX:WebRTC ⚠ 节点无 IPv4 出口，STUN 只回 IPv4，无法比对(非泄漏)
                FIX:出口IP ✓ (144.172.103.106/US)
                """)
                let vm = f.vm()
                vm.fixAll()
                // 回执只活在「修复跑完 → 1.6 秒后再查」这个窗口里:
                // checkEnvironment 一开跑就会清空 fixStates(那是设计)。所以
                // 状态断言必须落在这个窗口内,不能等 idle。
                try spin(until: { vm.fixStates["WebRTC"] != nil })
                guard case .note(let note)? = vm.fixStates["WebRTC"] else {
                    throw TestFailure(description: "⚠ 应落成「未验证」这一档，实际 \(String(describing: vm.fixStates["WebRTC"]))")
                }
                try expect(note.contains("非泄漏"), "附注要带出原因，实际 \(note)")
                try expect(!(vm.fixStates["代理内核"]?.isFailed ?? false),
                           "STUN 不该把代理内核打成失败")
                try f.idle(vm)
                try expect(vm.phase != .failed, "⚠ 不算整轮失败，实际 \(vm.phase)")
                try expect(vm.fixNotice.contains("未能验证"), "汇总要单独说未能验证，实际 \(vm.fixNotice)")
                try expect(!vm.fixNotice.contains("需要你手动处理"), "没有可手动动作时不该甩一句「需手动」")
            case "fix_targets_cover_fixable_names":
                // 可修清单里的每一项,都得有至少一条 FIX 输出能认领它。漏一个,
                // 那一行就永远停在「修复中」,「N 项已修复」的计数也把它漏掉 ——
                // 地区就漏过:它是唯一问题时,用户点完修复连一句回执都看不到。
                let lines = [
                    "代理内核+TUN ✓",
                    "修复时区/IPv6/保镖(需要密码) ✓",
                    "地区格式 → en_US ✓",
                    "Claude 客户端语言 → en-US ✓",
                    "置顶规则 ✓ 已验证内核加载",
                    "WebRTC ✓ 仅返回代理出口地址",
                ]
                let reached = Set(lines.flatMap { VM.fixTargets(of: $0) })
                let missed = VM.fixableNames.subtracting(reached)
                try expect(missed.isEmpty, "可修清单里这些项没有能认领它的 FIX 输出:\(missed.sorted())")

                // DNS 修不了,所以不该在可修清单里(给了按钮就是假承诺);
                // 但 fix() 仍会为它打一句「改不了」,这句必须还能落到 DNS 那一行,
                // 用户才知道为什么点了没变化、下一步该去哪儿改。
                try expect(!VM.fixableNames.contains("DNS 走隧道"), "修不了的项不该给「修复」按钮")
                try expect(VM.fixTargets(of: "DNS 未走隧道(8.8.8.8) · 一键修复改不了这项")
                           == ["DNS 走隧道"], "修不了也要把回执落到对应行")

                // 「修不了」不等于「换节点」:DNS 要去客户端改设置,别把用户支错方向。
                try expect(!VM.nodeBoundNames.contains("DNS 走隧道"), "DNS 不属于换节点就能解决的项")
                try expect(VM.nodeBoundNames.contains("IP 纯净度"), "机房 IP 只能靠换住宅节点")

                // STUN ≠ TUN。`STUN` 里含 `TUN`,用子串认领会把 WebRTC 的结果
                // **同时挂到代理内核和 TUN 网卡名下**——实测那一屏是三行说同一件事,
                // 其中两行还是冤的(内核和 TUN 明明都好的)。这一条钉住它。
                for line in ["WebRTC ✗ 节点无 IPv4 出口，STUN 只回 IPv4，无法比对(非泄漏)",
                             "WebRTC ✓ STUN 仅返回代理出口地址"] {
                    try expect(VM.fixTargets(of: line) == ["WebRTC"],
                               "STUN 不该被认成 TUN 网卡:\(line) → \(VM.fixTargets(of: line))")
                }
                // 反过来:真的报 TUN 的那两句还得认得出(代理内核+TUN / 代理内核/TUN)。
                for line in ["代理内核+TUN ✓", "代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"] {
                    try expect(Set(VM.fixTargets(of: line)) == ["代理内核", "TUN 网卡"],
                               "内核/TUN 那一行要认领两项:\(line)")
                }
            case "failed_fix":
                try f.write("fix-exit", "1")
                let vm = f.vm()
                vm.fixAll(); try f.idle(vm)
                try expect(vm.phase == .failed && vm.canQuit && f.calls == ["fix"], "修复失败不可被后续状态覆盖")
            case "checking_allows_quit":
                try f.write("check-delay", "0.2")
                let vm = f.vm()
                vm.refresh()
                try expect(vm.canQuit, "普通检查期间应允许退出")
                try f.idle(vm)
            case "hide_after_success":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .done && !hidden, "成功提示应该短暂保留")
                try spin(until: { hidden })
                try expect(vm.phase == .ready && vm.current == "B", "成功后应恢复就绪，不应退出进程")
            case "reopen_cancels_hide":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                vm.prepareToShow()
                pump(2.4)
                try expect(!hidden && vm.phase == .ready, "主动重开窗口后不能被旧回调隐藏")
            case "window_lifecycle":
                let vm = f.vm()
                let app = NSApplication.shared
                let delegate = AppDelegate(vm: vm)
                app.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                let first = delegate.mainWindow
                try expect(first?.isVisible == true, "首次启动应该显示窗口")
                first?.performClose(nil)
                try expect(first?.isVisible == false, "关窗应该隐藏")
                try expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "关窗不应退出")
                delegate.showMainWindow()
                try expect(delegate.mainWindow === first && first?.isVisible == true, "重开应该复用同一窗口")
                delegate.mainWindow?.miniaturize(nil)
                delegate.showMainWindow()
                try expect(first?.isMiniaturized == false, "重开应该恢复最小化窗口")
                first?.orderOut(nil)
            case "termination_guard":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                let app = NSApplication.shared
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "空闲时应该允许退出")
                try f.write("fix-delay", "0.2")
                vm.fixAll()
                try expect(delegate.applicationShouldTerminate(app) == .terminateCancel, "系统退出也必须保护修复操作")
                try f.idle(vm)
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "修复结束应该解除退出保护")
            case "switch_scans_and_applies_better_node":
                // 切槽位必须自己扫一遍节点,发现有更干净的就先换线路再切账号。
                // 以前这条链上根本没有节点这一步:用户得自己点工具栏图标、
                // 再在面板里点一次「应用」,而那个按钮因为门禁死条件从不出现。
                try f.audit()
                try f.write("node-scan", """
                CURRENT=鱼1·美国-犹他州
                CURRENT_SCORE=49
                BEST=鱼3·美国-犹他州
                BEST_SCORE=88
                DELTA=39
                GATE=report-only
                ELIGIBLE=4
                """)
                try f.write("node-apply", "OK:已切到 鱼3·美国-犹他州\nBEST=鱼3·美国-犹他州\n")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(f.calls.contains("node-scan"), "切槽位时应扫描节点: \(f.calls)")
                // 断言必须是前缀匹配:真正发出去的调用带叶子名(`node-apply <节点>`),
                // 精确相等会永远不成立 —— 而这正是「有没有真的切」要验的东西。
                try expect(f.calls.contains { $0.hasPrefix("node-apply ") }, "发现更优节点时应先换线路: \(f.calls)")
                try expect(f.calls.contains("node-apply 鱼3·美国-犹他州"),
                           "应用时应把本次最优叶子显式传下去: \(f.calls)")
                try expect(vm.current == "B", "换完节点仍要切账号")
                try expect(vm.note.contains("已切到更干净节点 鱼3·美国-犹他州"),
                           "回执要说清换了哪条,实际 \(vm.note)")
                // 换完线路必须重新审计:不能拿换之前那份结果放行。
                let audits = f.calls.filter { $0.hasPrefix("checkdetail") }.count
                try expect(audits == 2, "换完节点要重新审计一遍,实际 \(audits) 次")

            case "switch_survives_node_apply_failure":
                // 换节点失败不该把账号切换一起拖死:出口没变,账号照切,
                // 但原因必须写进回执,不能让人以为一切顺利。
                try f.audit()
                try f.write("node-scan", """
                CURRENT=鱼1·美国-犹他州
                CURRENT_SCORE=49
                BEST=鱼3·美国-犹他州
                BEST_SCORE=88
                DELTA=39
                GATE=report-only
                ELIGIBLE=4
                """)
                try f.write("node-apply", "FAIL:候选节点已不在内核里\n")
                try f.write("node-apply-exit", "1")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.current == "B", "节点切换失败仍应切账号")
                try expect(vm.note.contains("节点未切换"), "回执要说明节点没换,实际 \(vm.note)")

            case "switch_prefers_slot_bound_node":
                // 槽位绑了节点就认绑定,不认本次扫描的 BEST。
                // 两者语义不同:BEST 是「现在谁更干净」,绑定是「这个身份就该走这条线」。
                // 后者是用户对身份-出口关系的声明,不能被一次扫描结果盖掉。
                try f.audit()
                try f.write("node-scan", """
                CURRENT=鱼1·美国-犹他州
                CURRENT_SCORE=49
                BEST=鱼3·美国-犹他州
                BEST_SCORE=88
                DELTA=39
                GATE=report-only
                ELIGIBLE=4
                """)
                try f.write("node-apply", "OK:已切到 鱼9·日本-东京\n")
                try f.write("slot-node-B", "🧠 AI·干净IP\t鱼9·日本-东京\t1793859910\n")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(f.calls.contains("node-apply 鱼9·日本-东京"),
                           "绑定了节点就必须走绑定的那条: \(f.calls)")
                try expect(!f.calls.contains("node-apply 鱼3·美国-犹他州"),
                           "绑定优先时不该再去切本次 BEST: \(f.calls)")
                try expect(vm.note.contains("已切到槽位绑定节点 鱼9·日本-东京"),
                           "回执要说明走的是绑定节点,实际 \(vm.note)")
                try expect(vm.current == "B", "换完节点仍要切账号")

            case "slot_node_binding_round_trip":
                // 槽位 ↔ 节点绑定要在界面里能设、能看、能解除。
                // 以前只有命令行 `slot-node set B <节点名>`，界面上没有任何线索。
                let vm = f.vm()
                vm.slotNodeRoot = f.root.path
                try f.write("B", "SEL\t鱼7·日本-东京\t1793859910\n")
                vm.start(); try f.idle(vm)
                try expect(vm.slotNodes["B"] == "鱼7·日本-东京",
                           "启动时应把已有绑定读回来，实际 \(vm.slotNodes)")

                // 报告里的 TOP 行是绑定菜单的唯一选项来源。
                let candidates = VM.parseNodeCandidates("""
                TOP1=鱼3·美国-犹他州|88|1.2.3.4|优秀|住宅
                TOP2=鱼5·德国|75|5.6.7.8|良好|机房
                TOP3=鱼3·美国-犹他州|88|1.2.3.4|优秀|重复行
                BAD=不该被读进来
                """)
                try expect(candidates.map(\.leaf) == ["鱼3·美国-犹他州", "鱼5·德国"],
                           "候选要去重且只认 TOP 行，实际 \(candidates)")
                try expect(candidates.first?.label == "鱼3·美国-犹他州 · 88 分",
                           "菜单行要带分数，实际 \(candidates.first?.label ?? "")")

                vm.bindSlotNode("B", leaf: "鱼3·美国-犹他州")
                try spin { vm.slotNodes["B"] == "鱼3·美国-犹他州" }
                try expect(f.calls.contains("slot-node set B 鱼3·美国-犹他州"),
                           "绑定应写进核心脚本: \(f.calls)")
                try expect(vm.note.contains("账号B 已绑定"), "绑定要有回执，实际 \(vm.note)")

                vm.clearSlotNode("B")
                try spin { vm.slotNodes.isEmpty }
                try expect(f.calls.contains("slot-node clear B"), "解除绑定应写进核心脚本: \(f.calls)")

            case "stale_core_scan_explains_upgrade":
                // 只装了 app-only 包的人：界面新、核心旧，扫描回退出码 2 + 老 usage。
                // 报错必须说清「版本不对」并给一条能直接贴进终端的升级命令。
                let vm = f.vm()
                try f.write("stale-core", "1")
                vm.start(); try f.idle(vm)
                try expect(VM.isStaleCore("脚本执行失败（退出码 2）\n用法: claude-switch.sh check|status"),
                           "退出码 2 + usage 应判成旧核心")
                try expect(!VM.isStaleCore("脚本执行失败（退出码 1）\n扫描超时"),
                           "普通失败不该误判成版本问题")
                vm.scanNodes()
                try spin { !vm.nodeScanBusy }
                try expect(vm.coreOutdated, "应标记为旧核心")
                try expect(vm.nodeScanReport.contains("核心脚本版本过旧"),
                           "报告要说明原因，实际 \(vm.nodeScanReport)")
                try expect(vm.nodeScanReport.contains(VM.upgradeCoreCommand),
                           "报告要给出可直接执行的升级命令")
                try expect(vm.banner.contains("版本过旧"), "横幅要点明版本问题，实际 \(vm.banner)")

                // 旧核心不能把切账号一起拖死：扫描是顺手优化，不是前置条件。
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.current == "B", "旧核心下仍应完成账号切换")
                try expect(vm.note.contains("核心脚本过旧"), "回执要说明跳过了节点扫描，实际 \(vm.note)")

            case "node_scan_report_updates_row":
                // 「更优节点」检查行已换成「DNS泄露」(2026-11-24):applyNodeScan
                // 不再有落行目标,必须是安全空转,不许崩、不许改别的行。
                // 解析与证据拼装逻辑仍在(报告面板用),行为继续钉住。
                let vm = f.vm()
                let before = vm.rows.map { $0.name }
                let best = """
                GROUP=🤖 OpenAi
                CURRENT=鱼1·美国-犹他州
                CURRENT_SCORE=49
                BEST=鱼3·美国-犹他州
                BEST_SCORE=88
                DELTA=39
                GATE=report-only
                ELIGIBLE=4
                """
                let info = VM.parseNodeScan(best)
                try expect(info["BEST"] == "鱼3·美国-犹他州", "没解析出最优节点")
                try expect(info["BEST_SCORE"] == "88", "没解析出最优节点分数")
                vm.applyNodeScan(info)
                try expect(vm.rows.map { $0.name } == before, "收据落行已撤下,不许动到任何检查行")

                // 证据拼装:结论必须挂得上证据,旧格式缺字段时逐项省略。
                let evidenceLine = VM.nodeScanEvidence(VM.parseNodeScan(
                    "CANDIDATES=11\nUNIQUE_IPS=3\nELIGIBLE=4\nCURRENT_SCORE=49\nSCAN_TIME=11-04 09:52\n"))
                for piece in ["11 候选", "3 出口", "4 合格", "当前 49 分", "11-04 09:52 扫描"] {
                    try expect(evidenceLine.contains(piece), "证据里缺 \(piece)，实际 \(evidenceLine)")
                }
                // 负例:旧格式报告没这些字段,不能拿 0 冒充实测值。
                try expect(!VM.nodeScanEvidence(VM.parseNodeScan("BEST=\nDELTA=0\nELIGIBLE=4\n")).contains("0 候选"),
                           "旧报告不该凭空造数字")
                try expect(VM.nodeScanEvidence([:]).isEmpty, "空报告不该造出证据")

                // 面板只给人话:脚本 stdout 末尾的 KEY=VALUE 是给 App 解析的。
                let fullOutput = "节点扫描(只读)\n候选 11 个\n--- 报告键值 ---\nBEST=\nEPOCH=1\n"
                let shown = VM.displayableNodeReport(fullOutput)
                try expect(shown.contains("候选 11 个") && !shown.contains("EPOCH="),
                           "面板不该把机器键值混给人看，实际 \(shown)")
                try expect(!VM.displayableNodeReport("OK:已应用\nAPPLY=OK\nAPPLIED=鱼3\n")
                            .contains("APPLY="), "应用回执里的机器行也要收掉")

                // 负例:解析不认无关行,免得界面把人话读成键值。
                let noise = VM.parseNodeScan("节点扫描(只读) · 组 🤖 OpenAi\n门禁:report-only(已有账号槽位)\n")
                try expect(noise.isEmpty, "人话行不该被当成机器字段: \(noise)")
            case "menu_bar_brand_icon":
                // 菜单栏图标以前是系统符号 checkmark.shield.fill；窗口标记与 App 图标
                // 换成 Claude 星芒后它成了唯一一枚「盾牌 + 对号」。这里锁住新的自绘图标：
                // 两态同一枚盾牌、同一种「实心 + 挖空」画法、都能当模板图渲染；
                // 正常态挖的是 Claude 星芒，拦截态换成一枚大感叹号。
                let normalImage = MenuBarBrand.image(intercepted: false)
                let blockedImage = MenuBarBrand.image(intercepted: true)
                // 放在断言之前：断言失败时也要能拿到图做人工复核。
                if let dir = ProcessInfo.processInfo.environment["CS_ICON_DUMP"] {
                    for (name, image) in [("normal", normalImage), ("blocked", blockedImage)] {
                        if let r = image.representations.first as? NSBitmapImageRep,
                           let data = r.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: dir)
                                .appendingPathComponent("menubar-\(name).png"))
                        }
                    }
                }
                for image in [normalImage, blockedImage] {
                    try expect(abs(image.size.width - MenuBarBrand.side) < 0.01
                               && abs(image.size.height - MenuBarBrand.side) < 0.01,
                               "菜单栏图标应是 \(MenuBarBrand.side)pt 正方形，实际 \(image.size)")
                    try expect(image.isTemplate, "菜单栏图标必须是模板图，否则深色菜单栏会糊成黑块")
                }
                func rep(_ image: NSImage) throws -> NSBitmapImageRep {
                    guard let r = image.representations.first as? NSBitmapImageRep else {
                        throw TestFailure(description: "菜单栏图标没有位图表示")
                    }
                    return r
                }
                let normalRep = try rep(normalImage)
                let blockedRep = try rep(blockedImage)
                for r in [normalRep, blockedRep] {
                    try expect(r.pixelsWide == 36 && r.pixelsHigh == 36,
                               "18pt 图标应出 2x 位图，实际 \(r.pixelsWide)×\(r.pixelsHigh)")
                }
                // 逐像素统计：不透明像素数 / 中央区透明像素数 / 整图 alpha 指纹。
                func stats(_ r: NSBitmapImageRep) -> (Int, Int, [UInt8]) {
                    var opaque = 0, clearCenter = 0, alpha: [UInt8] = []
                    for y in 0..<r.pixelsHigh {
                        for x in 0..<r.pixelsWide {
                            let a = r.colorAt(x: x, y: y)?.alphaComponent ?? 0
                            let byte = UInt8(min(255, max(0, Int(a * 255))))
                            alpha.append(byte)
                            if byte > 216 { opaque += 1 }
                            if x >= 12 && x < 24 && y >= 12 && y < 24 && byte < 38 {
                                clearCenter += 1
                            }
                        }
                    }
                    return (opaque, clearCenter, alpha)
                }
                let (normalOpaque, normalHole, normalAlpha) = stats(normalRep)
                let (blockedOpaque, blockedHole, blockedAlpha) = stats(blockedRep)
                try expect(normalOpaque > 200,
                           "盾牌应是实心块，实际只有 \(normalOpaque) 个不透明像素")
                // 负例对照：如果星芒没画（或挖空被绕向抵消），中心区就是一整块实心，
                // clearCenter 会是 0 —— 这正是上一版中心留洞 / 无星芒会露出的破绽。
                try expect(normalHole > 10,
                           "中心区应有被挖空的 Claude 星芒，实际透明像素 \(normalHole)")
                try expect(blockedHole > 10,
                           "拦截态该有一枚挖空的感叹号，实际透明像素 \(blockedHole)")
                try expect(blockedOpaque != normalOpaque,
                           "两态的孔不能是同一块，实际 \(blockedOpaque) vs \(normalOpaque)")
                try expect(blockedAlpha != normalAlpha, "两态图标不能长得一模一样")
            default:
                throw TestFailure(description: "未知测试场景：\(name)")
            }
            print("PASS \(name)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
