import Foundation
import AppKit

private let auditKeys = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"]

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
          checkdetail) delay check; cat "$root/audit"; result check ;;
          status) cat "$root/status"; result status ;;
          get-client) echo 'client=clash-verge' ;;
          get-check-config) cat "$root/check-config"; result get-config ;;
          set-check-config) printf '%s\n' "$2" > "$root/saved-config"; result set-config ;;
          switch) delay switch; cat "$root/switch-output"; result switch ;;
          fix) delay fix; echo 'FIX:演示修复完成'; result fix ;;
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
                try expect(f.calls == ["checkdetail", "get-client", "status"], "启动不应重复检查")
                try expect(vm.phase == .ready && vm.lastCheckSummary == "通过" && vm.current == "A", "初始状态不一致")
            case "multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18\n")
                try f.write("switch-output", "OK:已切换到账号 C\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.archived == Set(["A", "B", "C"]), "应解析三个已建档账号")
                try expect(vm.stamps["A"] == AccountStamp(size: "1.2G", date: "2026-10-20"), "应解析账号大小与日期")
                let card = ContentView(vm: vm)
                try expect(card.accountSubtitle("A") == "当前", "当前账号副标题不正确")
                try expect(card.accountSubtitle("B") == "已建档 · 900M · 10-19", "已建档副标题应带大小与日期")
                try expect(card.accountSubtitle("D") == "未初始化", "空槽位副标题不正确")
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
                try f.write("status", "current=A hasA=1 hasB=0 hasC=0 hasD=0 accounts=A,E\n")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "非法账号列表不可进入界面")
            case "warnings_allowed":
                try f.audit(["ASN属性": "warn:演示机房"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.lastCheckSummary == "有警告" && vm.current == "B", "警告应展示并允许切换")
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "切换前必须先完整审计")
            case "skipped_optional_allowed":
                try f.audit(["DNS": "skip:用户已禁用", "WebRTC": "skip:用户已禁用"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.phase == .done && vm.current == "B", "显式跳过的非关键项不应阻断切换")
                try expect(vm.rows.first { $0.name == "DNS 走隧道" }?.state == .skip, "跳过项必须显示 skip")
            case "settings_round_trip":
                try f.write("check-config", #"{"disabled":["DNS"],"allowOptionalFailures":true,"logging":false}"#)
                let vm = f.vm()
                vm.loadCheckConfig()
                try spin { !vm.settingsBusy }
                try expect(vm.disabledChecks == Set(["DNS"]), "应读取已禁用的 DNS 检查")
                try expect(vm.allowOptionalFailures && !vm.loggingEnabled, "应读取非关键失败与日志设置")
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
                try expect(f.calls.contains("checkdetail"), "保存成功后必须重新检查")
            case "local_status_refresh":
                let vm = f.vm()
                vm.refreshAccountStatus()
                try expect(f.calls.isEmpty, "菜单提前出现时不可抢占启动审计")
                vm.start(); try f.idle(vm)
                try f.write("status", "current=B hasA=1 hasB=1\n")
                vm.refreshAccountStatus(); try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "status"], "展开菜单只应读取本地状态")
                try expect(vm.current == "B" && vm.lastCheckSummary == "通过", "账号更新不应改变上次审计结果")
            case "fresh_audit":
                let vm = f.vm()
                vm.refresh(); try f.idle(vm)
                try f.audit(["TUN网卡": "fail:已断开"])
                try f.deniedSwitch(vm)
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 2, "不可复用上次通过结果")
            case "failed_check":
                try f.audit(["WebRTC": "fail:演示失败"])
                try f.deniedSwitch(f.vm())
            case "check_grouping":
                // 主界面不再按「能不能关」分组 —— 14 项默认全部拦启动,分组反而让人
                // 以为「有些可以不拦」。但「哪几项允许在设置里关掉」这个数据关系仍然要锁住:
                // 它必须和设置页的 6 个开关完全一致,否则会出现「关不掉」或「关了还拦」。
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.rows.count == 14, "检查项应为 14 项")
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
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "忙碌时应忽略重复操作")
                try expect(vm.canQuit && vm.current == "B", "切换完成后应允许退出")
            case "fix_guard":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                vm.fixAll()
                try expect(!vm.canQuit, "修复期间不可退出")
                vm.refresh(); vm.switchTo("B"); vm.fixAll()
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail", "get-client", "status"], "修复结束必须重新检查，不能并行执行")
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
            case "incidents_missing_file":
                let vm = f.vm()
                vm.loadIncidents()
                try expect(vm.incidents.isEmpty, "没有记录文件时应为空,不是崩掉")
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
