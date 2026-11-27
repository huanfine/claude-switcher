#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A–H | checkdetail | fix | set-region | update [--check|--auto] | diagnose-proxy
set -u
export LC_ALL=en_US.UTF-8

# ---- 解释器解析(必须排在 _support 分支之前) ----
# 菜单栏 App 从 Finder 启动时继承的是 launchd 的极简 PATH,终端里能用的
# brew / python.org python3 在 App 里都找不到;而安装器是在终端里做的
# `python3 --version` 前置检查,两边结论不一致 —— 表现为「终端跑 fix 正常,
# 点界面上的修复却 0 秒失败」。这里把解释器解析成绝对路径并导出,后面所有
# 内嵌 Python 统一走它,不再赌 PATH。
# 测试会显式注入 CLAUDE_SWITCHER_PYTHON=sys.executable,这里不覆盖。
python_works() {
    local c="${1:-}"
    [ -n "$c" ] || return 1
    case "$c" in
        /*) ;;
        *) c="$(command -v -- "$c" 2>/dev/null || true)"; [ -n "$c" ] || return 1 ;;
    esac
    [ -x "$c" ] || return 1
    # macOS 没装 Command Line Tools 时 /usr/bin/python3 只是个 xcrun 壳,
    # 调用它会弹「安装开发者工具」对话框并卡住。先确认开发者目录存在。
    if [ "$c" = "/usr/bin/python3" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ] \
       && command -v xcode-select >/dev/null 2>&1 \
       && ! xcode-select -p >/dev/null 2>&1; then
        return 1
    fi
    "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

resolve_python() {
    local cand
    # 先尊重当前 PATH(终端/CI 里通常是最新的解释器),保持既有行为不变;
    # 找不到或跑不起来才按绝对路径兜底 —— 极简 PATH 的 GUI 就靠这一步救回来。
    if command -v python3 >/dev/null 2>&1; then
        cand="$(command -v python3)"
        if python_works "$cand"; then printf '%s' "$cand"; return 0; fi
    fi
    for cand in /usr/local/bin/python3 /opt/homebrew/bin/python3 \
                /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
                /usr/bin/python3; do
        if python_works "$cand"; then printf '%s' "$cand"; return 0; fi
    done
    return 1
}

if [ -z "${CLAUDE_SWITCHER_PYTHON:-}" ]; then
    _resolved_py="$(resolve_python 2>/dev/null || true)"
    [ -n "$_resolved_py" ] && export CLAUDE_SWITCHER_PYTHON="$_resolved_py"
    unset _resolved_py
fi

if [ "${1:-}" = "_support" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_SUPPORT'
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import uuid
import zipfile


OPTIONAL = ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "IP纯净度", "生态可达性",
            "DNS泄露")
ALL_CHECKS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
              "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "IP纯净度", "生态可达性",
              "DNS泄露")
DEFAULTS = {"disabled": [], "allowOptionalFailures": False, "logging": True,
            "strict": [], "app_auto_update": True}
LOG_LIMIT = 512 * 1024

# 检查报告契约。文本行仍然是人读的兼容层,JSON 才是机器契约:
# 显示名可以改,ID 不能改;未知项保留而不是丢掉,方便新核心 + 旧 App 共存。
REPORT_SCHEMA = "claude-switcher-report/2"
REPORT_PROTOCOL = 2
REPORT_TTL_SECONDS = 30 * 60
LEASE_SCHEMA = "claude-switcher-lease/1"
LEASE_TTL_SECONDS = 120
PROBES_SCHEMA = "claude-switcher-probes/1"
DRILL_SCHEMA = "claude-switcher-drill/1"
# 演练证据的有效期。它证明的是「当时那套配置下代理断开不会直连」,不是永久结论:
# 换客户端、重写规则、TUN 被重置都可能让它失效。7 天是软信号的折中 ——
# 太短会天天催用户断一次网,太长会让过期证据冒充当前结论。
DRILL_EVIDENCE_TTL_SECONDS = 7 * 24 * 3600
CHECK_SPECS = (
    ("proxy_core", "代理内核", True),
    ("tun", "TUN网卡", True),
    ("egress_ip", "出口IP", True),
    ("ip_stability", "IP一致", False),
    ("timezone", "时区", True),
    ("locale", "地区", True),
    ("ipv6", "IPv6", True),
    ("dns", "DNS", False),
    ("webrtc", "WebRTC", False),
    ("bodyguard", "保镖", True),
    ("rules", "规则置顶", True),
    ("client_language", "客户端语言", False),
    ("asn", "ASN属性", False),
    ("ip_purity", "IP纯净度", False),
    ("ecosystem", "生态可达性", False),
    ("dns_leak", "DNS泄露", False),
)
CHECK_SPEC_BY_NAME = {name: (cid, critical) for cid, name, critical in CHECK_SPECS}


def fail(message=""):
    print(message or "配置或诊断参数无效", file=sys.stderr)
    raise SystemExit(2)


def paths():
    home = Path.home()
    return home / ".claude-switcher", home / "Library/Logs/claude-switcher/client.log"


def fix_log_path():
    """App 每次点「一键修复」都会把原始输出落到这里(见 persistFixOutput)。"""
    return Path.home() / "Library/Logs/claude-switcher/last-fix.log"


# ---- 环境层 ----
# 功能 / 数据 / 环境三层里的环境层。安装器和更新器都不再改写核心脚本,
# 环境值统一落在 ~/.claude-switcher/env.json,运行期由 shell 侧 load_env 读取。
# 这样发布产物 = 安装产物,SHA256 可以直接整份比对。
ENV_SCHEMA = 1
ENV_KEYS = ("proxy_mode", "proxy_group", "country", "timezone", "locale",
            "clash_dir", "fake_ip_range")


def env_path():
    return Path.home() / ".claude-switcher/env.json"


def env_read():
    """读已保存的环境值。文件缺失返回空;损坏抛 ValueError,由调用方明确报错。"""
    path = env_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError("env.json")
    if not isinstance(data, dict) or data.get("schema") != ENV_SCHEMA:
        raise ValueError("env.json")
    return {key: data[key] for key in ENV_KEYS
            if isinstance(data.get(key), str) and data[key].strip()}


def env_write(values):
    """合并写入。只收白名单键;值不能含换行,否则 shell 侧按行解析会串行。"""
    if not isinstance(values, dict):
        raise ValueError("env")
    merged = dict(env_read())
    for key, value in values.items():
        if key not in ENV_KEYS or not isinstance(value, str):
            raise ValueError("env")
        value = value.strip()
        if "\n" in value or "\r" in value or len(value) > 512:
            raise ValueError("env")
        merged[key] = value
    merged["schema"] = ENV_SCHEMA
    base, _ = paths()
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd, temporary = tempfile.mkstemp(prefix=".env-", dir=base)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(merged, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, base / "env.json")
        revoke_lease()
    except OSError:
        raise ValueError("env")
    return merged


def env_migrate(script):
    """老版本把环境值写在脚本头部,升级时把它们搬进 env.json,避免升级后代理组名为空。"""
    try:
        text = Path(script).read_text(encoding="utf-8")
    except (OSError, ValueError):
        raise ValueError("env")
    found = {}
    for key, name in (("proxy_mode", "PROXY_MODE"), ("proxy_group", "PROXY_GROUP"),
                      ("country", "COUNTRY_TARGET"), ("timezone", "TZ_TARGET"),
                      ("locale", "LOCALE_TARGET")):
        match = re.search(r'(?m)^' + name + r'="([^"]*)"', text)
        if match and match.group(1).strip():
            found[key] = match.group(1)
    return env_write(found) if found else env_read()



def validate(value):
    if not isinstance(value, dict) or set(value) - set(DEFAULTS):
        fail()
    result = dict(DEFAULTS)
    disabled = value.get("disabled", [])
    if (not isinstance(disabled, list)
            or any(not isinstance(item, str) or item not in OPTIONAL for item in disabled)
            or len(disabled) != len(set(disabled))):
        fail()
    result["disabled"] = [name for name in OPTIONAL if name in disabled]
    # strict:把原本「只提示」的可选项升成硬性基线。有些人对账号安全要求更高,
    # 例如要求「Anthropic 生态必须可达」才算能启动 —— 但这是个人选择,不能默认套给所有人。
    strict = value.get("strict", [])
    if (not isinstance(strict, list)
            or any(not isinstance(item, str) or item not in OPTIONAL for item in strict)
            or len(strict) != len(set(strict))):
        fail()
    if set(strict) & set(disabled):
        fail()   # 既关掉又要求当硬门槛,自相矛盾
    result["strict"] = [name for name in OPTIONAL if name in strict]
    for key in ("allowOptionalFailures", "logging", "app_auto_update"):
        if key in value:
            if type(value[key]) is not bool:
                fail()
            result[key] = value[key]
    return result


def load_config():
    base, _ = paths()
    path = base / "checks.json"
    if not path.exists():
        return dict(DEFAULTS)
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        fail()
    return validate(value)


def app_version():
    value = os.environ.get("CLAUDE_SWITCHER_VERSION", "").strip()
    if value and re.fullmatch(r"[A-Za-z0-9._-]{1,40}", value):
        return value
    base, _ = paths()
    try:
        value = (base / "version.txt").read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    return value if re.fullmatch(r"[A-Za-z0-9._-]{1,40}", value) else "unknown"


def report_started_at(text):
    """从 checkdetail 的 `# 时间 pid=… 开始` 头取检查时间。"""
    lines = text.splitlines()
    if not lines:
        return None
    match = re.match(r"^# (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", lines[0])
    if not match:
        return None
    try:
        return datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").astimezone()
    except ValueError:
        return None


def iso_time(value):
    return value.astimezone().isoformat(timespec="seconds")


def report_config():
    """报告生成不能因为 checks.json 坏了就整份失败;坏配置本身会在文本行里体现。"""
    try:
        return load_config()
    except SystemExit:
        return dict(DEFAULTS)


def parse_report_checks(text):
    """把文本行解析成带稳定 ID 的检查项。重复项保留第一条并单独记账。"""
    started = report_started_at(text)
    checked_at = iso_time(started) if started else iso_time(datetime.datetime.now().astimezone())
    order, observed, duplicates = [], {}, []
    for line in text.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, rest = line.partition("=")
        state, _, detail = rest.partition(":")
        name, state, detail = name.strip(), state.strip(), detail.strip()
        if not name or state not in ("ok", "warn", "fail", "skip", "config"):
            continue
        if name in observed:
            if name not in duplicates:
                duplicates.append(name)
            continue
        if state == "skip":
            evidence, remedy = detail, ""
        else:
            evidence, separator, remedy = detail.partition(" · ")
            evidence, remedy = evidence.strip(), remedy.strip() if separator else ""
        observed[name] = (state, detail, evidence, remedy)
        order.append(name)

    checks = []
    for cid, name, critical in CHECK_SPECS:
        if name not in observed:
            continue
        state, detail, evidence, remedy = observed[name]
        checks.append({"id": cid, "name": name, "critical": critical, "state": state,
                       "evidence": evidence, "remedy": remedy, "detail": detail,
                       "checked_at": checked_at, "known": True})
    present = {item["name"] for item in checks}
    for name in order:
        if name in present:
            continue
        state, detail, evidence, remedy = observed[name]
        checks.append({
            "id": "unknown-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:12],
            "name": name, "critical": False, "state": state,
            "evidence": evidence, "remedy": remedy, "detail": detail,
            "checked_at": checked_at, "known": False})
    return checks, duplicates


def report_fingerprint(environment, config, core_path):
    """报告绑定的不是时间,而是「当前环境值 + 检查开关 + 核心脚本」这三件事。"""
    core_sha = ""
    if core_path:
        try:
            core_sha = hashlib.sha256(Path(core_path).read_bytes()).hexdigest()
        except OSError:
            core_sha = ""
    payload = {
        "env": {key: environment.get(key, "") for key in ENV_KEYS},
        "checks": {
            "disabled": list(config.get("disabled", [])),
            "allowOptionalFailures": bool(config.get("allowOptionalFailures", False)),
        },
        "core_sha256": core_sha,
    }
    digest = hashlib.sha256(json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")).hexdigest()
    return digest, core_sha


def parse_timestamp(value):
    if not isinstance(value, str) or not value:
        raise ValueError("timestamp")
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.astimezone()


def report_started_marker(text):
    """报告头里的原始开始时间；用于把 sidecar 绑定到同一次 checkdetail。"""
    lines = text.splitlines()
    if not lines:
        return ""
    match = re.match(r"^# (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", lines[0])
    return match.group(1) if match else ""


def optional_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def probe_document(started_at):
    """代理链路的连通性/延迟。直连在 TUN 开启时测不出来，明确标 unknown。"""
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", started_at or ""):
        fail("探测时间格式无效")
    now = datetime.datetime.now().astimezone()
    proxy = {"status": "unknown", "target": "https://claude.ai/",
             "http_code": None, "latency_ms": None,
             "checked_at": iso_time(now)}
    try:
        run = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{time_total}",
             "--max-time", "6", "https://claude.ai/"],
            capture_output=True, text=True, timeout=8)
        parts = run.stdout.strip().split()
        if len(parts) == 2 and parts[0].isdigit():
            code = int(parts[0])
            try:
                latency = int(float(parts[1]) * 1000)
            except ValueError:
                latency = None
            proxy["http_code"] = code
            proxy["latency_ms"] = latency if code > 0 else None
            proxy["status"] = "ok" if code > 0 else "fail"
        elif run.returncode != 0:
            proxy["status"] = "fail"
    except (OSError, subprocess.SubprocessError):
        proxy["status"] = "unknown"
    direct = {"status": "unknown", "source": "drill",
              "reason": "not_measured_while_tun_up", "checked_at": iso_time(now)}
    return {"schema": PROBES_SCHEMA, "started_at": started_at,
            "created_at": iso_time(now), "proxy": proxy, "direct": direct}


def write_drill_counters(args):
    if len(args) != 14:
        fail("drill 计数器参数不完整")
    checked_at, result = args[0], args[1]
    def pair(name, status, ok, bad, elapsed):
        if status not in ("ok", "fail", "unknown"):
            fail("drill %s 状态无效" % name)
        try:
            values = [int(ok), int(bad), int(elapsed)]
        except ValueError:
            fail("drill %s 计数无效" % name)
        if status == "unknown":
            values = [None, None, None]
        return {"status": status, "success": values[0], "failure": values[1],
                "elapsed_ms": values[2]}
    document = {
        "schema": DRILL_SCHEMA,
        "checked_at": checked_at,
        "result": result,
        "tcp": pair("tcp", *args[2:6]),
        "dns": pair("dns", *args[6:10]),
        "webrtc": pair("webrtc", *args[10:14]),
    }
    base, _ = paths()
    write_json_private(base / "drill-counters.json", document)
    return document


def fail_closed_state(now=None):
    """fail-closed 到底有没有被证明过。只读演练留下的证据,不重跑、不发网络请求。

    平时 16 项全绿只说明「流量此刻走了代理」,证明不了「代理挂了会不会直连」。
    这件事必须持续可见:没有证据要说没有,不能沉默,更不能当成通过。
    它是软信号 —— 不拦启动、不进 blockers、不参与 config_fingerprint。
    """
    now = now or datetime.datetime.now().astimezone()
    base, _ = paths()
    drill = optional_json(base / "drill-counters.json")
    result, checked_at = "", ""
    if drill:
        result = str(drill.get("result") or "")
        checked_at = str(drill.get("checked_at") or "")
    if not result:
        # 老安装件只有 drill.log,没有计数器文件。最后一行形如:
        # <epoch> baseline=… after=… result=<结论> tcp=… dns=… webrtc=…
        try:
            lines = (base / "drill.log").read_text(
                encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        for line in reversed(lines):
            parts = line.split()
            if not parts or not parts[0].isdigit():
                continue
            match = re.search(r"(?:^|\s)result=(\S+)", line)
            if not match:
                continue
            result = match.group(1)
            checked_at = iso_time(
                datetime.datetime.fromtimestamp(int(parts[0])).astimezone())
            break
    state = {"status": "unverified", "result": result, "checked_at": checked_at}
    verdict = result.split(":", 1)[0]
    if verdict == "violated":
        state["status"] = "violated"
        return state
    if verdict != "established":
        return state          # 空记录或读不懂的记录一律算未验证,不猜
    try:
        moment = parse_timestamp(checked_at)
    except ValueError:
        state["status"] = "stale"
        return state
    age = int((now - moment).total_seconds())
    state["age_seconds"] = age
    state["status"] = ("established"
                       if 0 <= age <= DRILL_EVIDENCE_TTL_SECONDS else "stale")
    return state


def lease_path():
    return paths()[0] / "lease.json"


def revoke_lease():
    """配置/节点/客户端一变化，旧租约就不能再代表当前环境。"""
    try:
        lease_path().unlink()
    except FileNotFoundError:
        pass
    except OSError:
        fail("租约撤销失败")


def lease_document(report, core_path, now=None):
    """租约只从已建立的报告签发，且不能超过报告自身的有效期。"""
    if not isinstance(report, dict):
        fail("报告格式无效")
    if report.get("schema") != REPORT_SCHEMA or report.get("protocol") != REPORT_PROTOCOL:
        fail("报告不是 claude-switcher-report/2")
    summary = report.get("summary") or {}
    if report.get("verdict") != "established":
        fail("报告结论不是 established，不能签发租约")
    if summary.get("missing_critical") or summary.get("critical_blockers") \
            or summary.get("duplicates"):
        fail("报告缺少关键项或存在阻断项，不能签发租约")
    now = now or datetime.datetime.now().astimezone()
    try:
        report_expires = parse_timestamp(report.get("expires_at"))
    except ValueError:
        fail("报告有效期格式无效")
    if report_expires <= now:
        fail("报告已过期，请重新检查")
    try:
        environment = env_read()
    except ValueError:
        environment = {}
    fingerprint, core_sha = report_fingerprint(environment, report_config(), core_path)
    if report.get("config_fingerprint") != fingerprint:
        fail("报告与当前环境/核心不一致，请重新检查")
    report_id = report.get("report_id")
    if not isinstance(report_id, str) or not report_id:
        fail("报告缺少 report_id")
    expires = min(now + datetime.timedelta(seconds=LEASE_TTL_SECONDS), report_expires)
    return {
        "schema": LEASE_SCHEMA,
        "lease_id": uuid.uuid4().hex,
        "report_id": report_id,
        "run_id": report.get("run_id", ""),
        "config_fingerprint": fingerprint,
        "core_sha256": core_sha,
        "verdict": report["verdict"],
        "issued_at": iso_time(now),
        "expires_at": iso_time(expires),
        "report_expires_at": iso_time(report_expires),
    }


def write_json_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd, temporary = tempfile.mkstemp(prefix=".lease-", dir=path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except OSError:
        fail("租约写入失败")


def lease_check(core_path, now=None):
    lease = paths()[0] / "lease.json"
    try:
        document = json.loads(lease.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        fail("租约不存在或无法解析")
    if not isinstance(document, dict) or document.get("schema") != LEASE_SCHEMA:
        fail("租约格式无效")
    now = now or datetime.datetime.now().astimezone()
    try:
        expires = parse_timestamp(document.get("expires_at"))
    except ValueError:
        fail("租约有效期格式无效")
    if expires <= now:
        fail("租约已过期")
    base, _ = paths()
    try:
        report = json.loads((base / "last-report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        fail("找不到租约对应的检查报告")
    expected = lease_document(report, core_path, now)
    for key in ("report_id", "config_fingerprint", "core_sha256"):
        if document.get(key) != expected.get(key):
            fail("租约已失效（" + key + " 不匹配）")
    try:
        if parse_timestamp(document.get("expires_at")) > parse_timestamp(expected["expires_at"]):
            fail("租约有效期超过报告有效期")
    except ValueError:
        fail("租约有效期格式无效")
    print("OK:租约有效至 " + document["expires_at"])


def build_report(text, core_path=""):
    """构造 claude-switcher-report/2。判定口径与 verdict/evidence 保持一致。"""
    now = datetime.datetime.now().astimezone()
    started = report_started_at(text) or now
    checks, duplicates = parse_report_checks(text)
    expected = [name for _, name, _ in CHECK_SPECS]
    present = {item["name"] for item in checks}
    missing = [name for name in expected if name not in present]
    missing_critical = [name for _, name, critical in CHECK_SPECS
                        if critical and name not in present]
    blockers = [item["name"] for item in checks if item["state"] in ("fail", "config")]
    critical_blockers = [item["name"] for item in checks
                         if item["critical"] and item["state"] in ("fail", "config")]
    advisories = [item["name"] for item in checks if item["state"] == "warn"]
    skipped = [item["name"] for item in checks if item["state"] == "skip"]
    evidence_missing = [item["name"] for item in checks
                        if item["critical"] and item["state"] == "ok"
                        and not item["evidence"]]
    verified = [item for item in checks if item["state"] in ("ok", "warn")]
    if duplicates or blockers:
        verdict = "violated"
    elif not verified or missing_critical:
        verdict = "incomplete"
    else:
        verdict = "established"

    try:
        environment = env_read()
    except ValueError:
        environment = {}
    config = report_config()
    fingerprint, core_sha = report_fingerprint(environment, config, core_path)
    report_id = uuid.uuid4().hex
    run_id = os.environ.get("CLAUDE_SWITCHER_RUN_ID", "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", run_id):
        run_id = report_id
    probes = optional_json(paths()[0] / "probes.json")
    if not probes or probes.get("started_at") != report_started_marker(text):
        probes = None
    drill = optional_json(paths()[0] / "drill-counters.json")
    summary = {
        "expected": len(CHECK_SPECS),
        "total": len(checks),
        "passed": sum(1 for item in checks if item["state"] == "ok"),
        "warning": len(advisories),
        "failed": sum(1 for item in checks if item["state"] == "fail"),
        "config": sum(1 for item in checks if item["state"] == "config"),
        "skipped": len(skipped),
        "blockers": blockers,
        "critical_blockers": critical_blockers,
        "advisories": advisories,
        "skipped_names": skipped,
        "missing": missing,
        "missing_critical": missing_critical,
        "evidence_missing": evidence_missing,
        "duplicates": duplicates,
        "unknown": [item["name"] for item in checks if not item["known"]],
    }
    return {
        "schema": REPORT_SCHEMA,
        "protocol": REPORT_PROTOCOL,
        "report_id": report_id,
        "run_id": run_id,
        "created_at": iso_time(now),
        "expires_at": iso_time(now + datetime.timedelta(seconds=REPORT_TTL_SECONDS)),
        "config_fingerprint": fingerprint,
        "core_sha256": core_sha,
        "core_version": app_version(),
        "host": platform.node(),
        "platform": platform.system(),
        "verdict": verdict,
        "environment": {key: environment.get(key, "") for key in
                        ("proxy_mode", "proxy_group", "country", "timezone", "locale")},
        "checks": checks,
        "summary": summary,
        # 与 probes 不同,这个字段恒在:没有证据本身就是要如实报告的事实。
        # 旧报告缺它时下游按「未验证」处理,不能当成通过。
        "fail_closed": fail_closed_state(now),
        # probes 是可选 sidecar,drill 计数器却可能是上一次演练留下的:
        # 只有 drill 没有 probes 时也要出报告,不能对 None 取 .get 直接崩。
        # 离线 `report` 与 sidecar 失败这两条路都会走到这里。
        **(({"probes": {"proxy": (probes or {}).get("proxy"),
                        "direct": (probes or {}).get("direct"),
                        "drill": drill}} if probes or drill else {})),
    }


def write_log(args):
    config = load_config()
    if not config["logging"]:
        return
    if len(args) != 4 or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args[0]):
        fail()
    if not re.fullmatch(r"\d{1,3}", args[1]) or not 0 <= int(args[1]) <= 255:
        fail()
    if not re.fullmatch(r"\d{1,12}", args[2]):
        fail()
    tokens = args[3].split()
    checks = {}
    for token in tokens:
        match = re.fullmatch(r"([A-Za-z0-9\u4e00-\u9fff]+)=(ok|warn|fail|skip)", token)
        if not match or match.group(1) not in ALL_CHECKS or match.group(1) in checks:
            fail()
        checks[match.group(1)] = match.group(2)
    summary = " ".join(name + "=" + checks[name] for name in ALL_CHECKS if name in checks)
    line = (datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
            + " version=" + app_version() + " command=" + args[0]
            + " exit=" + str(int(args[1])) + " duration_ms=" + str(int(args[2]))
            + ((" " + summary) if summary else "") + "\n")
    _, log_path = paths()
    log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(log_path.parent, 0o700)
        if log_path.exists() and log_path.stat().st_size + len(line.encode("utf-8")) > LOG_LIMIT:
            os.replace(log_path, log_path.with_name("client.log.1"))
        with log_path.open("a", encoding="utf-8") as handle:
            os.chmod(log_path, 0o600)
            handle.write(line)
    except OSError:
        fail()


def recent_status():
    base, _ = paths()
    result = {}
    try:
        lines = (base / "last-check.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for line in lines:
        match = re.fullmatch(r"([^=]+)=(ok|warn|fail|skip)(?::.*)?", line)
        if match and match.group(1) in ALL_CHECKS and match.group(1) not in result:
            result[match.group(1)] = match.group(2)
    return result


def safe_log_lines():
    _, log_path = paths()
    try:
        lines = log_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    allowed = re.compile(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00 version=[A-Za-z0-9._-]+ "
        r"command=[a-z][a-z0-9-]{0,31} exit=\d{1,3} duration_ms=\d{1,12}"
        r"(?: (?:[A-Za-z0-9\u4e00-\u9fff]+=(?:ok|warn|fail|skip) ?)*)?")
    return [line for line in lines[-2000:] if allowed.fullmatch(line)]


IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IPV6_RE = re.compile(r"\b(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\b")
URL_RE = re.compile(r"https?://\S+")
SECRET_RE = re.compile(r"(?i)\b(token|secret|password|authorization|bearer)\s*[=: ]+\S+")


def safe_fix_log():
    """最近一次「一键修复」的逐步输出,只留 FIX:/错误行并脱敏。

    client.log 里只有 `command=fix exit=1 duration_ms=0` 这类元数据,看不出
    卡在哪一步 —— 这正是「点了修复没反应」一直查不动的原因。但 FIX: 原文
    可能带出口 IP、本机绝对路径,所以和 client.log 一样走白名单,不能整份塞。
    """
    try:
        lines = fix_log_path().read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    kept = []
    for line in lines:
        if not (line.startswith("FIX:") or line.startswith("FAIL:")
                or line.startswith("脚本执行失败") or line.startswith("操作超时")
                or "command not found" in line):
            continue
        line = line.replace(str(Path.home()), "~")
        line = IPV4_RE.sub("[IP]", line)
        line = IPV6_RE.sub("[IP6]", line)
        line = URL_RE.sub("[URL]", line)
        line = SECRET_RE.sub(lambda m: m.group(1) + "=[REDACTED]", line)
        kept.append(line[:300])
    return ("\n".join(kept[-200:]) + "\n") if kept else None


def export_diagnostics(args):
    if len(args) != 1 or not args[0] or "\x00" in args[0]:
        fail()
    destination = Path(args[0]).expanduser()
    base, _ = paths()
    environment = {"schema_version": 1, "platform": platform.system(),
                   "app_version": app_version(),
                   "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, value in (("environment.json", environment),
                                ("recent-status.json", {"checks": recent_status()}),
                                ("checks.json", load_config())):
                archive.writestr(name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            archive.writestr("client.log", "\n".join(safe_log_lines()) + "\n")
            # 最近一次修复的逐步回执。文件不存在(旧版 App / 还没点过修复)就跳过,
            # 不影响老客户端读取诊断包。
            fix_log = safe_fix_log()
            if fix_log is not None:
                archive.writestr("last-fix.log", fix_log)
        os.chmod(destination, 0o600)
    except OSError:
        fail()
    print("OK:诊断日志已导出（不含 IP、凭据、账号或代理配置；含脱敏后的最近一次修复逐步输出）")


def main(args):
    if not args:
        fail()
    action = args[0]
    if action == "config" and len(args) == 1:
        config = load_config()
        print("disabled=" + ",".join(config["disabled"]))
        print("strict=" + ",".join(config["strict"]))
        print("allowOptionalFailures=" + str(int(config["allowOptionalFailures"])))
        print("logging=" + str(int(config["logging"])))
    elif action == "config-get" and len(args) == 1:
        print(json.dumps(load_config(), ensure_ascii=False))
    elif action == "config-set" and len(args) == 2:
        raw = args[1].encode("utf-8")
        if len(raw) > 16384:
            fail()
        try:
            config = validate(json.loads(raw.decode("utf-8")))
        except (ValueError, UnicodeError):
            fail()
        base, _ = paths()
        try:
            base.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".checks-", dir=base)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(config, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, base / "checks.json")
            revoke_lease()
        except OSError:
            fail()
    elif action == "probe" and len(args) == 2:
        document = probe_document(args[1])
        write_json_private(paths()[0] / "probes.json", document)
        print(json.dumps(document, ensure_ascii=False, separators=(",", ":")))
    elif action == "drill-record" and len(args) == 15:
        write_drill_counters(args[1:])
        print("OK:drill 计数器已写入")
    elif action == "lease" and len(args) in (2, 3):
        core_path = args[2] if len(args) >= 3 else ""
        try:
            report = json.loads(Path(args[1]).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            fail("找不到可签发租约的检查报告")
        document = lease_document(report, core_path)
        write_json_private(lease_path(), document)
        print("OK:租约有效至 " + document["expires_at"])
    elif action == "lease-check" and len(args) in (1, 2):
        lease_check(args[1] if len(args) == 2 else "")
    elif action == "lease-revoke" and len(args) == 1:
        revoke_lease()
        print("OK:租约已撤销")
    elif action == "fail-closed" and len(args) == 1:
        # 给 bash 侧用的紧凑读法:状态|时间。门禁输出与界面读的是同一个判定。
        state = fail_closed_state()
        print(state["status"] + "|" + state.get("checked_at", ""))
    elif action == "verdict" and len(args) in (1, 2):
        # 离线复核:只读已有报告,不再探测。意义是事后能回答「当时到底过没过」,
        # 而不是只剩一条被后续日志刷掉的输出。口径与在线检查一致。
        path = Path(args[1]) if len(args) == 2 and args[1] else paths()[0] / "last-check.txt"
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            fail()
        items, order = {}, []
        for line in text.splitlines():
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, rest = line.partition("=")
            status, _, detail = rest.partition(":")
            status = status.strip()
            # config = 环境层没就绪(代理组/目标值缺失)。它和 fail 一样拦启动,
            # 所以必须计入 blockers —— 早先这里只认 ok/warn/fail/skip,config 行被
            # 直接丢掉,离线复核会把「没配好」判成 established。
            if status not in ("ok", "warn", "fail", "skip", "config"):
                continue
            name = name.strip()
            if not name:
                continue
            if name not in items:
                order.append(name)
            items[name] = (status, detail.strip())
        if not order:
            fail()
        blockers = [n for n in order if items[n][0] in ("fail", "config")]
        advisories = [n for n in order if items[n][0] == "warn"]
        skipped = [n for n in order if items[n][0] == "skip"]
        verified = [n for n in order if items[n][0] in ("ok", "warn")]
        # 三态:有 fail/config 即 violated;一项都没真正验证是 incomplete;否则 established。
        # 关键点是 warn/skip 不会被提升成 pass——和在线检查的 fail-closed 同一口径。
        # incomplete 这一档是必要的:把检查项全关掉之后,「没有失败」不等于「验过了」。
        if blockers:
            verdict = "violated"
        elif not verified:
            verdict = "incomplete"
        else:
            verdict = "established"
        print("VERDICT:" + verdict)
        print("items=" + ",".join(order))
        print("blockers=" + ",".join(blockers))
        print("advisories=" + ",".join(advisories))
        print("skipped=" + ",".join(skipped))
    elif action == "evidence" and len(args) == 2:
        # 证据落盘:把最近一次检查写成 JSON,含时间、主机、环境、逐项状态与判定。
        # 只新建、不覆盖:证据被覆盖就失去追溯意义,要留新的就换个文件名。
        base, _ = paths()
        try:
            text = (base / "last-check.txt").read_text(encoding="utf-8", errors="replace")
        except OSError:
            fail()
        items, order = {}, []
        for line in text.splitlines():
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, rest = line.partition("=")
            status, _, detail = rest.partition(":")
            status = status.strip()
            # config 也必须收:它和 fail 一样拦启动,丢掉它会让「没配好」的现场
            # 在证据里凭空消失,事后复核只剩一堆 ok。
            if status not in ("ok", "warn", "fail", "skip", "config"):
                continue
            name = name.strip()
            if not name:
                continue
            if name not in items:
                order.append(name)
            items[name] = {"status": status, "detail": detail.strip()}
        if not order:
            fail()
        try:
            env = env_read()
        except ValueError:
            env = {}
        # 判定口径必须和 verdict 命令一致:config(环境层没就绪)一样拦启动,算 blocker;
        # 一项都没真正验证过是 incomplete —— 「没有失败」不等于「验过了」。
        if any(v["status"] in ("fail", "config") for v in items.values()):
            evidence_verdict = "violated"
        elif not any(v["status"] in ("ok", "warn") for v in items.values()):
            evidence_verdict = "incomplete"
        else:
            evidence_verdict = "established"
        doc = {
            "schema_version": "claude-switcher-evidence/0.1",
            "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "host": platform.node(),
            "environment": {key: env.get(key) for key in
                            ("country", "timezone", "locale", "proxy_mode", "proxy_group")},
            "verdict": evidence_verdict,
            "items": items,
            "source": str(base / "last-check.txt"),
        }
        out = Path(args[1])
        try:
            fd = os.open(str(out), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError:
            print("目标已存在或不可写,未覆盖:" + str(out), file=sys.stderr)
            raise SystemExit(2)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
        print("OK:" + str(out))
    elif action == "report" and len(args) in (1, 2, 3):
        # 只读转换:不重新探测,不修改 last-check.txt。
        path = Path(args[1]) if len(args) >= 2 and args[1] else paths()[0] / "last-check.txt"
        core_path = args[2] if len(args) >= 3 else ""
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            fail()
        print(json.dumps(build_report(text, core_path), ensure_ascii=False,
                         separators=(",", ":")))
    elif action == "env" and len(args) == 1:
        try:
            values = env_read()
        except ValueError:
            fail()
        for key in ENV_KEYS:
            if key in values:
                print(key + "=" + values[key])
    elif action == "env-set" and len(args) >= 2:
        updates = {}
        for item in args[1:]:
            key, separator, value = item.partition("=")
            if not separator:
                fail()
            updates[key] = value
        try:
            env_write(updates)
        except ValueError:
            fail()
        print("OK:环境配置已写入")
    elif action == "env-migrate" and len(args) == 2:
        try:
            env_migrate(args[1])
        except ValueError:
            fail()
        print("OK:环境配置已迁移")
    elif action == "log":
        write_log(args[1:])
    elif action == "export-diagnostics":
        export_diagnostics(args[1:])
    else:
        fail()


if __name__ == "__main__":
    main(sys.argv[1:])
PY_SUPPORT
fi

# 随现有单脚本更新分发;在任何账号状态读写、审计/修复/启动之前分派。
if [ "${1:-}" = "diagnose-proxy" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_PROXY_DIAGNOSE'
"""Read-only transport diagnostics for an explicitly selected HTTP/SOCKS proxy."""
import argparse
import concurrent.futures
import ipaddress
import json
import math
import os
import subprocess
from urllib.parse import urlsplit


TARGETS = (
    ("anthropic_api", "https://api.anthropic.com/v1/models"),
    ("claude_web", "https://claude.ai/"),
)


def select_proxy(args, environ):
    if args.proxy is not None:
        value, source = args.proxy, "argument"
    elif args.config is not None:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict):
            raise ValueError("invalid config")
        value, source = config.get("proxy_url"), "config"
    else:
        value, source = environ.get("CLAUDE_SWITCHER_PROXY_URL"), "environment"
    if not isinstance(value, str) or not value.strip():
        raise ValueError("proxy required")
    value = value.strip()
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid proxy")
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https", "socks5", "socks5h")
            or not parsed.hostname or parsed.port is None
            or not 0 < parsed.port < 65536
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("invalid proxy")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    # Do not include proxy addresses, credentials, or private config paths in reports.
    public = {"scheme": parsed.scheme, "port": parsed.port,
              "host_scope": "loopback" if loopback else "remote",
              "authentication_configured": parsed.username is not None,
              "source": source}
    return value, public


def probe(name, url, proxy, environ):
    # -q ignores curlrc. Pass proxy credentials over stdin, never in argv/reports.
    quoted = proxy.replace("\\", "\\\\").replace('"', '\\"')
    config = 'proxy = "' + quoted + '"\n'
    args = ["curl", "-q", "--config", "-", "-sS", "-o", os.devnull,
            "--proto", "=https", "--noproxy", "", "--connect-timeout", "6",
            "--max-time", "12", "-w",
            "%{http_code}\t%{http_connect}\t%{ssl_verify_result}\t%{time_appconnect}\t%{time_total}",
            url]
    keep = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "SYSTEMROOT"}
    clean_env = {k: v for k, v in environ.items() if k in keep}
    result = {"name": name, "url": url, "transport_reached": False,
              "access": "unknown"}
    try:
        process = subprocess.run(args, input=config, env=clean_env, capture_output=True,
                                 text=True, timeout=15)
        fields = process.stdout.strip().split()
        status, connect, verify = map(int, fields[:3])
        tls, elapsed = map(float, fields[3:5])
        if (not 0 <= status <= 599 or not 0 <= connect <= 599 or verify < 0
                or not math.isfinite(tls) or not math.isfinite(elapsed)
                or tls < 0 or elapsed < 0):
            raise ValueError("invalid probe metrics")
        reached = process.returncode == 0 and status > 0 and verify == 0 and tls > 0
        access = ("unauthenticated" if status == 401 else
                  "access_restricted" if status in (403, 407) else
                  "server_error" if status >= 500 else "http_response")
        result.update(curl_exit=process.returncode, http_status=status,
                      proxy_connect_status=connect, tls_verified=reached,
                      elapsed_seconds=elapsed, transport_reached=reached,
                      access=access if reached else "unknown")
    except subprocess.TimeoutExpired:
        result["error"] = "probe_timeout"
    except OSError:
        result["error"] = "curl_unavailable"
    except (ValueError, IndexError):
        result["error"] = "invalid_probe_output"
    return result


class DiagnosticParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error can echo private URLs or paths from argv.
        raise ValueError("invalid arguments")


def main(argv=None, environ=None):
    parser = DiagnosticParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--proxy", help="explicit proxy URL including a port")
    choice.add_argument("--config", help="private JSON file containing proxy_url")
    environ = os.environ if environ is None else environ
    report = {"schema_version": 1, "mode": "proxy_diagnostics",
              "scope": "unauthenticated_transport_only",
              "account_status": "not_evaluated", "leak_protection": "not_evaluated",
              "launch_allowed": None, "application_started": False,
              "system_modified": False}
    try:
        args = parser.parse_args(argv)
        proxy, public = select_proxy(args, environ)
    except (OSError, ValueError, TypeError):
        report.update(state="configuration_error", error="invalid_or_missing_proxy",
                      hint="Use --proxy, --config, or CLAUDE_SWITCHER_PROXY_URL; an explicit port is required.")
        print(json.dumps(report, ensure_ascii=False))
        return 2
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(probe, name, url, proxy, environ) for name, url in TARGETS]
        checks = [f.result() for f in futures]
    reached = all(check["transport_reached"] for check in checks)
    report.update(proxy=public, checks=checks,
                  state="transport_reached" if reached else "transport_failed")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if reached else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY_PROXY_DIAGNOSE
fi

if [ "${1:-}" = "flclash-repair" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_FLCLASH_REPAIR'
import datetime
import json
import re
import secrets
import shutil
import sqlite3
import sys
from pathlib import Path


# >>> claude-switcher:rules generated >>>
# 由 scripts/sync-rules.py 从 data/claude-rules.json 生成,请勿手改。
# Claude Code 运行期会访问的域名与 STUN 端口。这是唯一数据源。
# 各平台代码里的清单块由 scripts/sync-rules.py 生成,不要手改生成物;
# 改完本文件跑一次 `python3 scripts/sync-rules.py`,或 `--check` 只做校验。
# 漏配一个域名就会落到 Match() → 漏网之鱼 → 自动最快组,出口 IP 和 claude.ai
# 不是同一个,这正是风控最容易抓到的「同一用户来源分裂」。
DOMAINS = (
    # clau.de 是重定向短域名,claudemcp* 是 MCP 客户端与内容分发;这三个漏了会直接换出口
    "claude.ai",
    "claude.com",
    "clau.de",
    "anthropic.com",
    "claudeusercontent.com",
    "claudemcpclient.com",
    "claudemcpcontent.com",
    # 出口 IP 审计拿 cloudflare.com/cdn-cgi/trace 当基准,它必须与受保护流量同一条链路
    "cloudflare.com",
    "challenges.cloudflare.com",
    # browser-intake-us5-datadoghq.com 的根域名是整串(中间是连字符不是点),DOMAIN-SUFFIX,datadoghq.com 抓不到它;上报 IP 与 API IP 不一致会触发异常检测。siftscience.com 是反欺诈检测,同样上报。
    "datadoghq.com",
    "browser-intake-us5-datadoghq.com",
    "sentry.io",
    "statsigapi.net",
    "segment.io",
    "siftscience.com",
    "stripe.com",
    "stripe.network",
    "stripecdn.com",
    # anthropic.com.cdn.cloudflare.net 的根是 cloudflare.net,不在 cloudflare.com 后缀里;anthropic.auth0.com 是登录认证,漏了会在登录时换出口
    "intercom.io",
    "intercomcdn.com",
    "intercomassets.com",
    "anthropic-com.ghost.io",
    "anthropic.auth0.com",
    "anthropic.com.cdn.cloudflare.net",
    "servd-anthropic-website.b-cdn.net",
    "cdn.usefathom.com",
)
PORTS = (3478, 5349, 19302)
IP_FALLBACK = ("160.79.104.0/21", "2607:6bc0::/32")
# <<< claude-switcher:rules generated <<<
REQUIRED_RULE_COLUMNS = {
    "id", "profile_id", "rule_action", "content", "rule_target",
    "rule_provider", "sub_rule", "no_resolve", "src", "order",
}


def fail(message):
    print(f"FAIL:{message}", file=sys.stderr)
    raise SystemExit(1)


def clean_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    if not value or re.search(r"[,\r\n\x00-\x1f]", value):
        fail("代理组名无效")
    return value


def select_group(config, configured):
    groups = []
    in_groups = False
    current = None
    for line in config.splitlines():
        if re.match(r"^proxy-groups:\s*(?:#.*)?$", line):
            in_groups = True
            continue
        if in_groups and re.match(r"^[A-Za-z_]", line):
            break
        if not in_groups:
            continue
        name = re.match(r"^\s*-\s*name:\s*(.+?)\s*$", line)
        if name:
            current = clean_scalar(name.group(1))
            continue
        if re.match(r"^\s*type:\s*select\s*$", line) and current:
            groups.append(current)
            current = None
    if configured in groups:
        return configured
    return groups[0] if groups else "GLOBAL"


def current_profile(home):
    path = home / "shared_preferences.json"
    try:
        values = json.loads(path.read_text(encoding="utf-8"))
        profile_id = values.get("flutter.currentProfileId")
        if type(profile_id) is not int or profile_id <= 0:
            fail("无法识别当前 Profile，已保留原配置")
        return profile_id
    except (OSError, ValueError, TypeError):
        fail("无法读取当前 Profile，已保留原配置")


def repair(home, configured):
    if not home.is_dir():
        fail("FlClash 配置目录不存在")
    database = home / "database.sqlite"
    config_path = home / "config.yaml"
    if not database.is_file() or not config_path.is_file():
        fail("缺少 FlClash 数据库或运行配置")
    profile_id = current_profile(home)
    config = config_path.read_text(encoding="utf-8")
    if not re.search(r"enhanced-mode:\s*fake-ip\b|fake-ip:\s*true\b", config, re.I):
        fail("请先在 FlClash 中启用 fake-IP，再执行修复")
    target = select_group(config, configured)
    backup = None
    try:
        with sqlite3.connect(database, timeout=5) as db:
            db.execute("PRAGMA busy_timeout=5000")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version < 17 or version > 21:
                fail("FlClash 数据库版本不受支持，已保留原配置")
            columns = {row[1] for row in db.execute("PRAGMA table_info(rules)")}
            if not REQUIRED_RULE_COLUMNS.issubset(columns):
                fail("FlClash 规则表结构不受支持，已保留原配置")
            if not db.execute("SELECT 1 FROM profiles WHERE id=?", (profile_id,)).fetchone():
                fail("当前 Profile 不在数据库中，已保留原配置")
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = home / f".claude-switcher-backup-{stamp}-{secrets.token_hex(4)}.sqlite"
            db.execute("VACUUM INTO ?", (str(backup),))
        with sqlite3.connect(database, timeout=5) as db:
            db.execute("PRAGMA busy_timeout=5000")
            db.execute("BEGIN IMMEDIATE")
            try:
                for action, content in [("DOMAIN_SUFFIX", value) for value in DOMAINS] + [("DST_PORT", str(value)) for value in PORTS]:
                    exists = db.execute(
                        "SELECT 1 FROM rules WHERE profile_id=? AND rule_action=? AND content=? AND rule_target=?",
                        (profile_id, action, content, target),
                    ).fetchone()
                    if exists:
                        continue
                    while True:
                        rule_id = secrets.randbits(62)
                        if not db.execute("SELECT 1 FROM rules WHERE id=?", (rule_id,)).fetchone():
                            break
                    db.execute(
                        'INSERT INTO rules (id, profile_id, rule_action, content, rule_target, rule_provider, sub_rule, no_resolve, src, "order") '
                        "VALUES (?, ?, ?, ?, ?, NULL, NULL, 0, 0, NULL)",
                        (rule_id, profile_id, action, content, target),
                    )
                db.commit()
            except Exception:
                db.rollback()
                raise
        print(f"BACKUP={backup}")
    except SystemExit:
        raise
    except Exception as error:
        if backup and backup.exists():
            shutil.copyfile(backup, database)
        fail(f"写入 FlClash 规则失败:{type(error).__name__}")


def rollback(home, backup_name):
    backup = Path(backup_name).resolve()
    if backup.parent != home.resolve() or not backup.name.startswith(".claude-switcher-backup-") or backup.suffix != ".sqlite" or not backup.is_file():
        fail("回滚备份无效")
    database = home / "database.sqlite"
    try:
        for suffix in ("-wal", "-shm"):
            (home / f"database.sqlite{suffix}").unlink(missing_ok=True)
        shutil.copyfile(backup, database)
        print("OK:已回滚 FlClash 配置")
    except OSError as error:
        fail(f"回滚失败:{type(error).__name__}")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "repair":
        repair(Path(sys.argv[2]), sys.argv[3])
        return
    if len(sys.argv) == 4 and sys.argv[1] == "rollback":
        rollback(Path(sys.argv[2]), sys.argv[3])
        return
    fail("用法: flclash-repair repair <配置目录> <代理组> | rollback <配置目录> <备份>")


if __name__ == "__main__":
    main()
PY_FLCLASH_REPAIR
fi

if [ "${1:-}" = "clash-rules" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_CLASH_RULES'
"""Install and verify the Clash Verge global script without trusting Merge.yaml text."""
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit, quote


# 内核控制接口限制。大规则集订阅(1 万条以上)的 /rules 响应可达数 MB,
# 原先 2MB 的硬上限会让规则校验直接失败,进而把「规则置顶」判成 fail,
# 而它是硬性检查项,最终表现为 App 拦住 Claude 启动。
# 默认放宽到 32MB;可用 CLAUDE_SWITCHER_API_MAX_BYTES(字节)覆盖。
API_TIMEOUT = 20
API_MAX_BYTES = 32 * 1024 * 1024
try:
    _api_max_env = int(os.environ.get("CLAUDE_SWITCHER_API_MAX_BYTES", ""))
    if _api_max_env > 0:
        API_MAX_BYTES = _api_max_env
except ValueError:
    pass


# >>> claude-switcher:rules generated >>>
# 由 scripts/sync-rules.py 从 data/claude-rules.json 生成,请勿手改。
# Claude Code 运行期会访问的域名与 STUN 端口。这是唯一数据源。
# 各平台代码里的清单块由 scripts/sync-rules.py 生成,不要手改生成物;
# 改完本文件跑一次 `python3 scripts/sync-rules.py`,或 `--check` 只做校验。
# 漏配一个域名就会落到 Match() → 漏网之鱼 → 自动最快组,出口 IP 和 claude.ai
# 不是同一个,这正是风控最容易抓到的「同一用户来源分裂」。
DOMAINS = (
    # clau.de 是重定向短域名,claudemcp* 是 MCP 客户端与内容分发;这三个漏了会直接换出口
    "claude.ai",
    "claude.com",
    "clau.de",
    "anthropic.com",
    "claudeusercontent.com",
    "claudemcpclient.com",
    "claudemcpcontent.com",
    # 出口 IP 审计拿 cloudflare.com/cdn-cgi/trace 当基准,它必须与受保护流量同一条链路
    "cloudflare.com",
    "challenges.cloudflare.com",
    # browser-intake-us5-datadoghq.com 的根域名是整串(中间是连字符不是点),DOMAIN-SUFFIX,datadoghq.com 抓不到它;上报 IP 与 API IP 不一致会触发异常检测。siftscience.com 是反欺诈检测,同样上报。
    "datadoghq.com",
    "browser-intake-us5-datadoghq.com",
    "sentry.io",
    "statsigapi.net",
    "segment.io",
    "siftscience.com",
    "stripe.com",
    "stripe.network",
    "stripecdn.com",
    # anthropic.com.cdn.cloudflare.net 的根是 cloudflare.net,不在 cloudflare.com 后缀里;anthropic.auth0.com 是登录认证,漏了会在登录时换出口
    "intercom.io",
    "intercomcdn.com",
    "intercomassets.com",
    "anthropic-com.ghost.io",
    "anthropic.auth0.com",
    "anthropic.com.cdn.cloudflare.net",
    "servd-anthropic-website.b-cdn.net",
    "cdn.usefathom.com",
)
PORTS = (3478, 5349, 19302)
IP_FALLBACK = ("160.79.104.0/21", "2607:6bc0::/32")
# <<< claude-switcher:rules generated <<<
SCRIPT_BEGIN = "// >>> claude-switcher managed rules >>>"
SCRIPT_END = "// <<< claude-switcher managed rules <<<"
MERGE_BEGIN = "# >>> claude-switcher pinned rules >>>"
MERGE_END = "# <<< claude-switcher pinned rules <<<"


def fail(message):
    print("FAIL:" + message, file=sys.stderr)
    raise SystemExit(1)


def read_yaml_scalar(path, key):
    if not path.exists():
        return ""
    match = re.search(r"^" + re.escape(key) + r":[ \t]*(.*)$", read_text(path), re.M)
    if not match:
        return ""
    value = match.group(1).strip()
    if value.startswith('"'):
        return json.JSONDecoder().raw_decode(value)[0]
    if value.startswith("'"):
        match = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
        if not match:
            fail("无法读取 Clash 控制接口配置")
        return match.group(1).replace("''", "'")
    value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    if value in {"", "null", "~"}:
        return ""
    if value.startswith(("|", ">", "*", "&", "[", "{")):
        fail("Clash 控制接口需要普通标量配置")
    return value


def read_text(path):
    return path.read_bytes().decode("utf-8-sig")


def controller_config(clash_dir):
    for name in ("clash-verge.yaml", "verge.yaml"):
        path = clash_dir / name
        unix_path = read_yaml_scalar(path, "external-controller-unix")
        secret = read_yaml_scalar(path, "secret")
        if "\r" in secret or "\n" in secret:
            fail("Clash 控制接口密钥格式无效")
        if unix_path and hasattr(socket, "AF_UNIX"):
            if not os.path.isabs(unix_path):
                fail("Clash Unix socket 路径必须为绝对路径")
            # 生成的配置可能记着已失效的临时 socket(Clash Verge 重启后路径会变);
            # 依次尝试配置路径与服务实际使用的用户级 socket,都存在才继续走 TCP 分支
            candidates = [unix_path]
            if hasattr(os, "getuid"):
                candidates.append(
                    "/var/run/clash-verge-service/users/%d/verge-mihomo.sock" % os.getuid())
            for candidate in candidates:
                if os.path.isabs(candidate) and Path(candidate).exists():
                    return ("unix", candidate, None), secret
        endpoint = read_yaml_scalar(path, "external-controller")
        if endpoint:
            if not endpoint.startswith(("http://", "https://")):
                endpoint = "http://" + endpoint
            parsed = urlsplit(endpoint)
            host = parsed.hostname
            if host in {"0.0.0.0", "::"}:
                host = "127.0.0.1" if host == "0.0.0.0" else "::1"
            if host != "localhost":
                try:
                    local = ipaddress.ip_address(host).is_loopback
                except ValueError:
                    local = False
                if not local:
                    fail("只允许验证本机 Clash 控制接口")
            if (parsed.scheme not in {"http", "https"} or not parsed.port
                    or parsed.username or parsed.password or parsed.path not in {"", "/"}
                    or parsed.query or parsed.fragment):
                fail("Clash 控制接口地址格式无效")
            return (parsed.scheme, host, parsed.port), secret
    fail("未找到本机 Clash 控制接口，无法验证内核规则")


def api_get(endpoint, secret, path):
    headers = {"Accept": "application/json"}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    scheme, host, port = endpoint
    connection = None
    try:
        if scheme == "unix":
            connection = http.client.HTTPConnection("localhost", timeout=API_TIMEOUT)
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(API_TIMEOUT)
            connection.sock.connect(host)
        else:
            cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            connection = cls(host, port, timeout=API_TIMEOUT)
        # http.client connects directly; inherited proxy variables are never used.
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            fail("Clash 内核接口未返回成功状态")
        data = response.read(API_MAX_BYTES + 1)
        if len(data) > API_MAX_BYTES:
            fail("Clash 内核接口响应过大(超过 %d MB,可用 CLAUDE_SWITCHER_API_MAX_BYTES 放宽)"
                 % (API_MAX_BYTES // (1024 * 1024)))
        value = json.loads(data.decode("utf-8"))
        if not isinstance(value, dict):
            fail("Clash 内核接口返回格式异常")
        return value
    except (http.client.HTTPException, OSError, ValueError) as exc:
        fail("Clash 内核接口不可用(" + exc.__class__.__name__ + ")")
    finally:
        if connection:
            connection.close()


def selected_proxy(proxies, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        fail("代理组存在循环引用")
    seen.add(name)
    item = proxies.get(name)
    if not isinstance(item, dict):
        fail("代理组不存在:" + name)
    if "all" in item or "now" in item:
        current = item.get("now")
        if not current or current == name:
            fail("代理组没有可用的当前节点:" + name)
        return selected_proxy(proxies, current, seen)
    return item


def validate_group(state, group, policy):
    proxies = state.get("proxies", {}).get("proxies", {})
    if not isinstance(proxies, dict) or group in {"DIRECT", "REJECT", "GLOBAL", "PASS"}:
        fail("请选择实际的代理组")
    if not isinstance(proxies.get(group), dict) or "all" not in proxies[group]:
        fail("配置的代理组不存在")
    selected = selected_proxy(proxies, group)
    selected_type = str(selected.get("type", "")).lower()
    if selected_type in {"direct", "reject", "block"}:
        fail("代理组当前节点为直连或拒绝，请选择代理节点")
    if policy == "proxy" and selected.get("udp") is not True:
        fail("当前节点未确认支持 UDP，请更换节点或选择 reject 策略")


def norm(value):
    return re.sub(r"[\s()_-]+", "", str(value).upper()).replace("&&", ",")


def rule_brief(rule):
    if not isinstance(rule, dict):
        return "非对象"
    return "%s|%s|%s" % (rule.get("type", "?"), rule.get("payload", "?"),
                         rule.get("proxy", "?"))


def actual_hint(rules):
    """失败时把内核首条规则原样带出来。

    「没置顶」有两种完全不同的原因:规则压根没加载(首条是别的),或者加载了但
    顺序/目标不对。只报一句「没置顶」时,这两种在日志里长得一模一样,只能再让
    用户跑一轮诊断。这里直接把首条摆出来,一眼就能分开。
    """
    if not isinstance(rules, list) or not rules:
        return "(内核规则为空)"
    return "(内核首条: " + rule_brief(rules[0]) + ")"


def expected_rules():
    rules = [("port", p) for p in PORTS]
    rules.extend(("domain", d) for d in DOMAINS)
    # IP 兜底排在域名规则之后:域名命中更快更精确,IP 只在域名没命中时才兜。
    rules.extend(("ip", c) for c in IP_FALLBACK)
    return rules


def verify_runtime(clash_dir, group, policy):
    base, secret = controller_config(clash_dir)
    state = {
        "configs": api_get(base, secret, "/configs"),
        "rules": api_get(base, secret, "/rules"),
        "proxies": api_get(base, secret, "/proxies"),
    }
    if str(state["configs"].get("mode", "")).lower() != "rule":
        fail("Clash 当前不是 rule 模式")
    validate_group(state, group, policy)
    rules = state["rules"].get("rules")
    if not isinstance(rules, list):
        fail("Clash /rules 返回格式异常")
    expected = expected_rules()
    if len(rules) < len(expected):
        fail("运行中的规则数量不足")
    for index, (kind, value) in enumerate(expected):
        if kind == "port":
            rule = rules[index]
            target = "REJECT" if policy == "reject" else group
            payload = norm(rule.get("payload", "")) if isinstance(rule, dict) else ""
            if (not isinstance(rule, dict) or str(rule.get("type", "")).upper() != "AND"
                    or payload != "NETWORK,UDP,DSTPORT," + str(value)
                    or rule.get("proxy") != target
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:UDP/" + str(value) + actual_hint(rules))
        elif kind == "ip":
            rule = rules[index]
            # mihomo 把 IP-CIDR 和 IP-CIDR6 都报成 IPCIDR,只能靠 payload 里的冒号区分。
            if (not isinstance(rule, dict)
                    or str(rule.get("type", "")).upper().replace("-", "") != "IPCIDR"
                    or str(rule.get("payload", "")).strip() != value
                    or rule.get("proxy") != group
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:IP " + value)
        else:
            rule = rules[index]
            if (not isinstance(rule, dict)
                    or str(rule.get("type", "")).upper().replace("_", "-") not in {"DOMAIN-SUFFIX", "DOMAINSUFFIX"}
                    or str(rule.get("payload", "")).strip().lower() != value
                    or rule.get("proxy") != group
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:" + value)
    return state


def rule_strings(group, policy):
    target = "REJECT" if policy == "reject" else group
    return ([f"AND,((NETWORK,UDP),(DST-PORT,{port})),{target}" for port in PORTS] +
            [f"DOMAIN-SUFFIX,{domain},{group}" for domain in DOMAINS] +
            [f"{'IP-CIDR6' if ':' in cidr else 'IP-CIDR'},{cidr},{group},no-resolve"
             for cidr in IP_FALLBACK])


def managed_block(group, policy):
    encoded = json.dumps(rule_strings(group, policy), ensure_ascii=False)
    group_json = json.dumps(group, ensure_ascii=False)
    return f"""{SCRIPT_BEGIN}
;(function () {{
  const originalMain = main;
  const pinnedRules = {encoded};
  const group = {group_json};
  main = function (config, ...args) {{
    const result = originalMain(config, ...args);
    if (!result || typeof result !== \"object\" || Array.isArray(result)) throw new Error(\"claude-switcher: original main must return a config object\");
    if (!Array.isArray(result[\"proxy-groups\"]) || !result[\"proxy-groups\"].some((item) => item && item.name === group)) throw new Error(\"claude-switcher: configured proxy group missing\");
    if (result.rules !== undefined && !Array.isArray(result.rules)) throw new Error(\"claude-switcher: rules must be an array\");
    result.rules = pinnedRules.concat((result.rules || []).filter((rule) => !pinnedRules.includes(rule)));
    return result;
  }};
}})();
{SCRIPT_END}"""


def script_text(path, group, policy):
    old = read_text(path) if path.exists() else ""
    block = managed_block(group, policy)
    if SCRIPT_BEGIN in old:
        if old.count(SCRIPT_BEGIN) != 1 or old.count(SCRIPT_END) != 1:
            fail("Script.js 中存在未闭合的 claude-switcher 管理块")
        pattern = re.compile(re.escape(SCRIPT_BEGIN) + r".*?" + re.escape(SCRIPT_END), re.S)
        if old.index(SCRIPT_END) < old.index(SCRIPT_BEGIN):
            fail("Script.js 中的管理块顺序无效")
        # 删掉旧块,再把新块追加到**文件末尾**。原地替换有个隐蔽的坏后果:
        # 用户在管理块之后又写了 main 或规则逻辑时,我们的 IIFE 会先执行,
        # 随后被后定义的 main 覆盖 —— 文件看着完全正确,内核里却没有置顶规则。
        # 实测:Script.js 5023 字节(我们那份约 2400),内核首条是用户自己的
        # ipinfo.io 规则;而脚本每次 write 都报「无变化」,因为块内容确实没变。
        old = pattern.sub("", old, count=1).rstrip() + "\n"
    if SCRIPT_END in old:
        fail("Script.js 中存在孤立的 claude-switcher 管理块")
    if not old.strip():
        old = "function main(config) { return config; }\n"
    match = re.search(r"function\s+main\s*\(", old)
    if not match:
        fail("现有 Script.js 没有可组合的 main(config)，已停止以免覆盖用户脚本")
    return old + ("" if old.endswith("\n") else "\n") + block + "\n"


def migrate_merge(path):
    if not path.exists():
        return None
    old = read_text(path)
    if MERGE_BEGIN not in old:
        if MERGE_END in old:
            fail("Merge.yaml 中存在孤立的 claude-switcher 管理块")
        return old
    if old.count(MERGE_BEGIN) != 1 or old.count(MERGE_END) != 1 or old.index(MERGE_END) < old.index(MERGE_BEGIN):
        fail("Merge.yaml 中存在未闭合的 claude-switcher 管理块")
    pattern = re.compile(r"(?ms)^[ \t]*" + re.escape(MERGE_BEGIN) + r"[ \t]*\r?\n.*?^[ \t]*" + re.escape(MERGE_END) + r"[ \t]*\r?\n?")
    new = pattern.sub("", old, count=1)
    return new


def write_changes(changes):
    changes = {path: data.encode("utf-8") for path, data in changes.items()
               if not path.exists() or path.read_bytes() != data.encode("utf-8")}
    # 返回「真正动过哪几个文件」。调用方要靠它决定**要不要重启客户端** ——
    # 内容一模一样时重启是纯损失:客户端要重新起内核、TUN 要重建,
    # 这几秒里所有走 TUN 的请求都会失败,而用户只是又点了一次「修复」。
    if not changes:
        return []
    originals, staged, replaced = {}, {}, []
    try:
        for path, data in changes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            originals[path] = path.read_bytes() if path.exists() else None
            if path.exists():
                shutil.copy2(path, path.with_name(path.name + ".bak." + str(time.time_ns())))
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".claude-switcher-", delete=False) as handle:
                staged[path] = Path(handle.name)
                handle.write(data)
            if path.exists():
                staged[path].chmod(path.stat().st_mode & 0o777)
        for path, temp in staged.items():
            os.replace(temp, path)
            replaced.append(path)
    except OSError:
        for path in reversed(replaced):
            if originals[path] is None:
                path.unlink()
            else:
                path.write_bytes(originals[path])
        raise
    finally:
        for temp in staged.values():
            if temp.exists():
                temp.unlink()
    return replaced


def assess_probe(policy, expected_ip, output, exit_code):
    if exit_code != "0":
        return "fail:STUN 探测执行失败，未确认 UDP 出口"
    try:
        expected = ipaddress.IPv4Address(expected_ip)
    except ValueError:
        return "fail:未获取有效的 IPv4 出口，无法比对 STUN 结果"
    if output == "RESULT:NONE":
        if policy == "reject":
            return "ok:常见 STUN UDP 拒绝规则已验证，探测无响应"
        return "fail:STUN 无响应，无法确认 UDP 是否经过代理"
    if not output.startswith("RESULT:"):
        return "fail:STUN 探测结果格式异常"
    try:
        addresses = [ipaddress.IPv4Address(value) for value in output[7:].split(",")]
    except ValueError:
        return "fail:STUN 探测结果格式异常"
    if policy == "reject":
        return "fail:拒绝策略下仍收到 STUN 响应，请检查运行规则"
    if any(address != expected for address in addresses):
        return "fail:STUN 暴露了非代理出口地址"
    return "ok:STUN 仅返回代理出口地址"


# ---------- 只读节点扫描 ----------
# 只看「运行中内核里有哪些可手动选的节点」+「这些节点在合并配置里的入口地址」。
# 订阅里有 uuid / password / 证书,这里一个字段都不读、更不会输出 —— 白名单解析,
# 读到的键只有下面这几个。输出里只有节点名、入口 IP、出口是否可知、UDP 标记。
_NODE_KEYS = {"server", "servername", "sni", "host", "Host", "type", "udp", "network"}


def _scalar(value):
    value = value.strip()
    if re.fullmatch(r"'(?:[^']|'')*'", value):
        return value[1:-1].replace("''", "'")
    if re.fullmatch(r'"(?:[^"\\]|\\.)*"', value):
        return value[1:-1]
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def parse_proxy_entries(config_path):
    """从合并配置的顶层 proxies: 块抠出 name → 非敏感字段。

    故意用逐行白名单,不用 YAML 解析器:这份文件里有凭据,整份反序列化等于把
    uuid/password 全读进内存,再大的输出白名单也挡不住误打印。顶层块以
    proxy-groups: 结束,后面的组定义里也有 proxies: 子键,必须截断。
    """
    entries = {}
    current = None
    in_block = False
    try:
        lines = read_text(config_path).splitlines()
    except OSError:
        return entries
    for line in lines:
        if line.startswith("proxies:"):
            in_block, current = True, None
            continue
        if line.startswith(("proxy-groups:", "proxy-providers:", "rules:", "rule-providers:")):
            break
        if not in_block:
            continue
        match = re.match(r"^-\s+name:\s*(.+?)\s*$", line)
        if match:
            name = _scalar(match.group(1))
            current = {"name": name}
            entries[name] = current
            continue
        if current is None:
            continue
        match = re.match(r"^\s+([\w-]+):\s*(.*?)\s*$", line)
        if not match or match.group(1) not in _NODE_KEYS:
            continue
        key, value = match.group(1), _scalar(match.group(2))
        if key not in current:
            current[key] = value
    return entries


def _egress_kind(entry):
    """server 是不是真实出口。

    直连型节点(实测本机的「鱼」系 75 条):server 就是落地 IP。
    CDN 前置节点(实测 292 条):server 是 Cloudflare 入口,还带 servername /
    ws-opts.headers.Host,真正出口在别处 —— 拿入口 IP 去打分是纯噪声,
    必须标成 fronted 并排除,而不是给一个看似正常的分数。
    """
    if not entry:
        return "missing", ""
    server = entry.get("server", "")
    if entry.get("servername") or entry.get("sni") or entry.get("Host") or entry.get("host"):
        return "fronted", ""
    try:
        ipaddress.ip_address(server)
    except ValueError:
        return "domain", ""
    return "known", server


def node_scan(clash_dir, group):
    base, secret = controller_config(clash_dir)
    data = api_get(base, secret, "/proxies")
    proxies = data.get("proxies")
    if not isinstance(proxies, dict):
        fail("Clash 内核 /proxies 返回格式异常")
    entries = parse_proxy_entries(clash_dir / "clash-verge.yaml")

    builtin = {"DIRECT", "REJECT", "GLOBAL", "PASS", "COMPATIBLE"}
    is_group = lambda name: isinstance(proxies.get(name), dict) and "all" in proxies[name]

    def active_leaf(name, seen=None):
        seen = set() if seen is None else seen
        item = proxies.get(name)
        if not isinstance(item, dict) or name in seen:
            return ""
        seen.add(name)
        now = str(item.get("now") or "")
        if not is_group(name):
            return name
        return active_leaf(now, seen) if now else ""

    # 只认「当前真正控路的那一个 Selector」。配置的组常常是层层嵌套的
    # (本机 🤖 OpenAi → 🧠 AI·干净IP → 叶子),而同一个订阅里还有别的
    # Selector;递归全列会给出「去改手动切换组」这种建议,等于替用户动了
    # 他没让我们碰的组。沿 now 链走到最深一层含叶子的 Selector 就停。
    def controlling_selector():
        # 顺便收集链路明细:报错只说「没有可手动选择的节点组」,用户不知道是
        # 哪一环的问题 —— 实测订阅把 Selector 改成 Fallback 后就是这句话,
        # 用户以为是我们坏了。把每个组的名字和类型列出来,一眼看出是谁变的。
        # 同时记下链路上遇到的「自动选路组」(URLTest/Fallback)及其直挂成员:
        # 那正是「没有可手动目标」时唯一有意义的答案 —— 不是报错,而是说清楚
        # 这组由内核自己挑、成员是哪几个、所以没有「更优节点」可以选。
        name, best, seen, chain = group, "", set(), []
        auto = None
        while is_group(name) and name not in seen:
            seen.add(name)
            item = proxies[name]
            children = item.get("all") or []
            itype = str(item.get("type", "")).lower()
            chain.append("%s(%s)" % (name, item.get("type", "")))
            if itype == "selector" and any(
                    child not in builtin and not is_group(child) for child in children):
                best = name
            if itype in ("urltest", "fallback"):
                leaves = [c for c in children if c not in builtin and not is_group(c)]
                auto = (name, item.get("type", ""), leaves)
            nxt = str(item.get("now") or "")
            if not nxt or not is_group(nxt):
                break
            name = nxt
        return best, chain, auto

    # 只收「直接挂在 Selector 下的叶子」。URLTest / Fallback 会自己选路,
    # 对它们 PUT /proxies 会被内核覆盖或拒绝,列进候选等于给一个按不动的建议。
    rows = []
    if not group or not is_group(group):
        fail("配置的代理组不存在或不是代理组:" + str(group))
    selector, chain_desc, auto = controlling_selector()
    if not selector:
        # 链路上没有可手动选的目标,但落点是一个自动选路的组,而且它直挂叶子 ——
        # 这不是错误,是结论:内核自己在这几个成员里挑,我们无权指定其中一个。
        # 报错会把「你的配置本来就不需要换节点」说成「工具坏了」,而且界面还会
        # 反过来催用户去点一个必然失败的按钮(2026-11-21 实测:🤖 OpenAi(Selector)
        # → 🧠 AI·干净IP(Fallback),成员是两个固定 IP)。
        if auto and auto[2]:
            print("NOCHOICE\t" + re.sub(r"[\t\r\n]", " ", auto[0])
                  + "\t" + re.sub(r"[\t\r\n]", " ", auto[1])
                  + "\t" + re.sub(r"[\t\r\n]", " ", "|".join(auto[2])))
            print("CHAIN\t" + re.sub(r"[\t\r\n]", " ", " → ".join(chain_desc)))
            return
        fail("当前链路上没有可手动选择的节点组(链路:" + " → ".join(chain_desc)
             + ";若某组是 URLTest/Fallback 自动选路,切换须改回手动选择或换组)")
    item = proxies[selector]
    for child in item.get("all") or []:
        if child in builtin or is_group(child):
            continue
        entry = entries.get(child)
        egress, server = _egress_kind(entry)
        udp = str((entry or {}).get("udp", "")).lower() == "true"
        rows.append((selector, child, server if egress == "known" else "", egress,
                     "1" if udp else "0"))
    current = active_leaf(group)

    def clean(value):
        return re.sub(r"[\t\r\n]", " ", str(value))

    print("SCANv1")
    print("GROUP\t" + clean(group))
    print("CURRENT\t" + clean(current))
    for selector, leaf, server, egress, udp in rows:
        print("\t".join(("NODE", clean(selector), clean(leaf),
                         clean(server), egress, udp)))


def node_select(clash_dir, group, selector, leaf):
    """把一个 Selector 切到指定叶子。只允许本机、只允许 Selector。

    由 node-apply 在门禁允许时调用,是 node-scan(只读)之后唯一的写操作。
    仍然只接受显式叶子名,不做自动选路。
    """
    base, secret = controller_config(clash_dir)
    proxies = api_get(base, secret, "/proxies").get("proxies")
    if not isinstance(proxies, dict):
        fail("Clash 内核 /proxies 返回格式异常")
    item = proxies.get(selector)
    if not isinstance(item, dict) or "all" not in item:
        fail("目标代理组不存在:" + selector)
    if str(item.get("type", "")).lower() != "selector":
        fail("目标代理组不是 Selector,不能手动固定节点")
    if leaf not in (item.get("all") or []):
        fail("目标节点不在该代理组里:" + leaf)
    headers = {"Content-Type": "application/json"}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    scheme, host, port = base
    connection = None
    try:
        if scheme == "unix":
            connection = http.client.HTTPConnection("localhost", timeout=API_TIMEOUT)
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(API_TIMEOUT)
            connection.sock.connect(host)
        else:
            cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            connection = cls(host, port, timeout=API_TIMEOUT)
        path = "/proxies/" + quote(selector, safe="")
        connection.request("PUT", path, body=json.dumps({"name": leaf}), headers=headers)
        response = connection.getresponse()
        response.read()
        if response.status not in (200, 204):
            fail("切换节点被内核拒绝(HTTP %d)" % response.status)
    except (http.client.HTTPException, OSError, ValueError) as exc:
        fail("切换节点失败(" + exc.__class__.__name__ + ")")
    finally:
        if connection:
            connection.close()
    print("OK:已切换到 " + leaf)


def register_script(clash_dir):
    """确保 Clash Verge 把 profiles/Script.js 当作全局脚本加载。

    只写文件是不够的:Clash Verge Rev 以 profiles.yaml 的 item 为索引,没有
    `uid: Script` / `file: Script.js` 这一项时,那个文件根本不会被读取 ——
    重启多少次内核里都没有置顶规则,verify 永远报「运行规则未按策略置顶」。
    只补缺失项,不重排、不删改其它条目。
    """
    path = clash_dir / "profiles.yaml"
    if not path.exists():
        fail("profiles.yaml 不存在,无法注册全局脚本")
    text = read_text(path)
    if re.search(r"(?m)^\s*-\s*uid:\s*Script\s*$", text):
        print("OK:全局脚本已注册")
        return 0
    match = re.search(r"(?m)^items:\s*$", text)
    if not match:
        fail("profiles.yaml 缺少 items: 段")
    block = ("- uid: Script\n  type: script\n  name: null\n"
             "  file: Script.js\n  updated: %d\n" % int(time.time()))
    rest = text[match.end():]
    new = text[:match.end()] + "\n" + block + rest.lstrip("\n")
    write_changes({path: new})
    print("OK:已补注册全局脚本(Script.js)")
    return 0


def main():
    if len(sys.argv) < 5:
        fail("内部参数不足")
    action, clash_dir, base_dir, group = sys.argv[1:5]
    clash_dir = Path(clash_dir)
    base_dir = Path(base_dir)
    policy_path = base_dir / "webrtc-policy"
    policy = sys.argv[5] if len(sys.argv) > 5 else ""
    policy = policy or (read_text(policy_path).strip() if policy_path.exists() else "proxy")
    if policy not in {"proxy", "reject"}:
        fail("WEBRTC_POLICY 只能是 proxy 或 reject")
    if action == "policy":
        print(policy)
        return 0
    if action == "assess" and len(sys.argv) == 9:
        print(assess_probe(policy, *sys.argv[6:9]))
        return 0
    if action == "mode":
        base, secret = controller_config(clash_dir)
        print(str(api_get(base, secret, "/configs").get("mode", "")).lower())
        return 0
    if action == "node-scan" and len(sys.argv) == 6:
        node_scan(clash_dir, group)
        return 0
    if action == "node-select" and len(sys.argv) == 8:
        node_select(clash_dir, group, sys.argv[6], sys.argv[7])
        return 0
    # 注册全局脚本不需要代理组,放在 group 校验之前。
    if action == "register-script":
        register_script(clash_dir)
        return 0
    if not group or any(char in group for char in ",\r\n"):
        fail("代理组名为空或包含规则分隔符")
    if action == "verify":
        verify_runtime(clash_dir, group, policy)
        print("OK:运行时规则已验证(" + policy + ")")
        return 0
    if action != "write":
        fail("未知内部动作")

    base, secret = controller_config(clash_dir)
    state = {"configs": api_get(base, secret, "/configs"),
             "proxies": api_get(base, secret, "/proxies")}
    if str(state["configs"].get("mode", "")).lower() != "rule":
        fail("Clash 当前不是 rule 模式")
    validate_group(state, group, policy)
    profiles = clash_dir / "profiles"
    script_path = profiles / "Script.js"
    merge_path = profiles / "Merge.yaml"
    new_script = script_text(script_path, group, policy)
    new_merge = migrate_merge(merge_path)
    changes = {script_path: new_script, policy_path: policy + "\n"}
    if new_merge is not None:
        changes[merge_path] = new_merge
    replaced = write_changes(changes)
    # 「无变化」要明确报出来:fix 靠这一句决定要不要重启客户端。
    # 只写「已写入」时,调用方无从知道该不该重启,只能每次都重启 ——
    # 于是「再点一次修复」也要付一次内核重启 + TUN 重建的代价。
    print("OK:全局脚本已写入(" + policy + ("，无变化)" if not replaced else "，变更 %d 处)" % len(replaced)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        # 带上是哪一类异常、说了什么。原来只有一句「规则配置处理失败,请检查格式与权限」——
        # 用户照着这句话什么也检查不了,我们自己也拿不到线索(实测就卡在这里:
        # 内核正在重启,请求打空 → OSError,那条提示却读起来像配置坏了)。
        fail("规则配置处理失败(%s: %s)；请检查配置格式与权限" % (type(exc).__name__, exc))
PY_CLASH_RULES
fi

# ============ 环境层(保底值) ============
# 本文件是发布产物,安装器与更新器都不再改写它。真实环境值一律来自
# ~/.claude-switcher/env.json,由下面的 load_env 在运行期读取。
# 这里只是「env.json 不存在或某项缺失」时的保底,不要当配置入口用。
ENV_FILE="$HOME/.claude-switcher/env.json"
PROXY_MODE="clash-verge"       # 代理客户端: clash-verge|flclash|shadowrocket|sing-box|clashx|surge|auto
PROXY_GROUP=""                 # Clash 代理组名(env.json 或探测)
COUNTRY_TARGET="US"            # 目标出口国家
TZ_TARGET="America/New_York"   # 锁定时区
LOCALE_TARGET="en_US"          # 锁定地区格式
CLASH_DIR=""                   # Clash Verge 配置目录(env.json 或探测)
FAKE_IP_RANGE=""               # fake-ip 网段(env.json 或探测)
FAKE_PREFIX="198.18."          # 由 FAKE_IP_RANGE 换算,供 case 匹配
# ==========================================

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
# 这几份日志里有出口 IP 与拦截记录。早期创建时没有设过权限,盘上留着一批 644 ——
# 同机任何用户都能读到「这台机器什么时候从哪个出口出去」。启动时顺手收紧一次,
# 只 stat 四个文件,代价可以忽略。
for _lf in watch.log rtt.log update.log drill.log; do
    [ -f "$BASE/$_lf" ] && chmod 600 "$BASE/$_lf" 2>/dev/null
done
# Claude Code 的状态不在 DATA 里:它用 ~/.claude/ 加一个顶层 ~/.claude.json。
# 槽位只搬 DATA 的话,A/B/C/D 对终端里的 claude 来说就是同一个账号 ——
# 登录态、历史、配置一份都不变。这两个路径因此也纳入槽位。
CLI_DIR="$HOME/.claude"
CLI_JSON="$HOME/.claude.json"
CLI_BASE="$BASE/cli"
# 槽位 → 节点的绑定:每个槽位可以钉一条固定出口,切槽位时按它换线路。
SLOT_NODE_DIR="$BASE/slot-node"
# 出口稳定性的判据是「现在用的出口是否等于这条实例的固定基线」(见 ip_baseline_*)。
# 这里只剩下历史证据的窗口:同一实例一周内不应该换出口,所以证据留 7 天。
# 早先的写法是「48 小时内出现 3 个出口才提示」,两个都不满足这条要求:
# 第 3 天换的出口到第 5 天就滑出窗口,统计从 2 掉回 1,看起来「一直很稳」;
# 只换一次的时候连提示都没有。窗口必须覆盖整个承诺周期。
IP_STABILITY_WINDOW=604800   # 7 天
LOG="$HOME/Library/Logs/claude-switch.log"
ROUTE_MISSED=""
KEEP_STAGED=0
# 账号快照里是 Claude 的登录态,比 ~/.claude 本身还敏感。默认 umask 022 会
# 建出 755 的目录,同机其他用户可读;这里统一收成 700/600。
umask 077 2>/dev/null || true
mkdir -p "$BASE/accounts"
chmod 700 "$BASE" "$BASE/accounts" 2>/dev/null || true

# Clash Verge 配置目录:安装方式与版本不同,路径也不同,不要写死。
# 优先级:env.json > $CLAUDE_SWITCHER_CLASH_DIR > 已知路径 > 特征文件扫描 > 主路径(便于报错定位)
detect_clash_dir() {
    local c
    [ -n "${CLAUDE_SWITCHER_CLASH_DIR:-}" ] && { printf '%s\n' "$CLAUDE_SWITCHER_CLASH_DIR"; return 0; }
    for c in \
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" \
        "$HOME/Library/Application Support/clash-verge" \
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge"; do
        [ -f "$c/clash-verge.yaml" ] && { printf '%s\n' "$c"; return 0; }
    done
    for c in "$HOME/Library/Application Support"/*/; do
        c="${c%/}"
        [ -f "$c/clash-verge.yaml" ] && [ -d "$c/profiles" ] && { printf '%s\n' "$c"; return 0; }
    done
    printf '%s\n' "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
}

# fake-ip 网段:内核接口不暴露 DNS 配置,只能从订阅里读。
# 优先级:env.json > $CLAUDE_SWITCHER_FAKE_IP_RANGE > 当前订阅 > 合并配置 > 默认 198.18.0.0/16
detect_fake_ip_range() {
    local dir uid f value
    [ -n "${CLAUDE_SWITCHER_FAKE_IP_RANGE:-}" ] && { printf '%s\n' "$CLAUDE_SWITCHER_FAKE_IP_RANGE"; return 0; }
    dir="${1:-}"
    if [ -n "$dir" ] && [ -f "$dir/profiles.yaml" ]; then
        uid=$(sed -n 's/^current:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$dir/profiles.yaml" | head -1)
        [ -n "$uid" ] && [ -f "$dir/profiles/$uid.yaml" ] && f="$dir/profiles/$uid.yaml"
    fi
    if [ -z "${f:-}" ] && [ -n "$dir" ] && [ -f "$dir/clash-verge.yaml" ]; then
        f="$dir/clash-verge.yaml"
    fi
    if [ -n "${f:-}" ] && [ -f "$f" ]; then
        value=$(sed -n 's/^[[:space:]]*fake-ip-range:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$f" | head -1)
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    fi
    printf '%s\n' "198.18.0.0/16"
}

# 把 fake-ip 网段换算成 case 能用的前缀。按掩码取整字节:
#   /16 → "198.18."，/8 → "10."，/24 → "192.168.1."。
# 原来固定取前两段,/8 与 /12 会算错(172.16.0.0/12 只认 172.16.,漏掉 172.17-31)。
# 非整字节掩码(/12)向下取整到 1 段,宁可多匹配一个 /8 也不能漏掉真实 TUN 段。
fake_ip_prefix() {
    local range="${1:-}" ip mask octets out part i
    ip="${range%%/*}"
    mask="${range#*/}"
    [ "$mask" = "$range" ] && mask=16
    case "$mask" in ''|*[!0-9]*) mask=16 ;; esac
    [ "$mask" -gt 32 ] && mask=32
    octets=$(( mask / 8 ))
    [ "$octets" -lt 1 ] && octets=1
    [ "$octets" -gt 4 ] && octets=4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    out=""; i=1
    for part in "$o1" "$o2" "$o3" "$o4"; do
        [ "$i" -le "$octets" ] || break
        case "$part" in ''|*[!0-9]*) printf '%s\n' "198.18."; return 0 ;; esac
        [ "$part" -le 255 ] || { printf '%s\n' "198.18."; return 0; }
        out="${out}${part}."
        i=$(( i + 1 ))
    done
    printf '%s\n' "${out:-198.18.}"
}

# 自调用 _support:一律经当前 shell 重新执行本脚本。
# 直接 "$0" 调用在脚本没有可执行位时(例如仓库里 `bash core/claude-switch.sh` 跑测试)
# 会 permission denied,被上层误判成「配置损坏」。
support() { "${BASH:-/bin/bash}" "$0" _support "$@"; }
lease_revoke() { support lease-revoke >/dev/null 2>&1 || true; }

# 内核控制接口的 Unix socket。Clash Verge 服务模式下 socket 在 /var/run 下,走它不需要
# sudo;配置里记的可能是重启后已失效的临时路径,所以两个都试。
# 定义在 load_env 之前:load_env 在脚本顶层就被调用,那时后面的定义还没执行。
clash_sock() {
    local cfg="$CLASH_DIR/clash-verge.yaml" s=""
    if [ -f "$cfg" ]; then
        s=$(sed -n 's/^external-controller-unix:[[:space:]]*//p' "$cfg" | tr -d '"' | head -1)
    fi
    if [ -n "$s" ] && [ -S "$s" ]; then printf '%s\n' "$s"; return 0; fi
    s="/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock"
    [ -S "$s" ] && { printf '%s\n' "$s"; return 0; }
    return 1
}

# 从运行中的内核规则反查代理组名:置顶规则的第一条就是我们的域名,它的 proxy 字段
# 就是组名。这样不用另存一份域名清单,也不会和实际生效的规则脱节。
detect_proxy_group() {
    local sock json group
    # 没有 Clash 配置目录就说明这台机器不是我们要管的环境(隔离测试、临时 HOME)。
    # 不加这道守卫会退到 /var/run 下真实内核的 socket,把测试拖进真实系统里。
    [ -f "$CLASH_DIR/clash-verge.yaml" ] || return 1
    sock=$(clash_sock 2>/dev/null) || return 1
    json=$(curl -s --max-time 10 --unix-socket "$sock" http://localhost/rules 2>/dev/null)
    [ -n "$json" ] || return 1
    group=$(printf '%s' "$json" | "${CLAUDE_SWITCHER_PYTHON:-python3}" -c '
import json, sys
try:
    rules = json.load(sys.stdin).get("rules") or []
except Exception:
    sys.exit(0)
for rule in rules:
    kind = str(rule.get("type") or "").lower()
    proxy = str(rule.get("proxy") or "")
    if kind in ("domainsuffix", "domain", "domainkeyword", "domainregex") and proxy:
        print(proxy)
        break
' 2>/dev/null)
    [ -n "$group" ] && printf '%s\n' "$group"
}

# 组名自愈:订阅更新会整份覆盖客户端配置,env.json 里记的组名可能已不存在
# (老订阅的组被上游改写/删除)。此时规则写不进、校验必失败、fix 用旧组名重试
# 永远收敛 —— 用户看到的就是「一键修复修不好」。修法:修复前从内核 /proxies
# 枚举真实代理组,按「固定IP > AI/干净 > 稳定型组」打分自动换到现存最优组,
# 写回 env.json。当前组名仍存在时优先保留,不会在订阅正常时乱换。
GROUP_RESELECTED=""
ensure_proxy_group() {
    GROUP_RESELECTED=""
    local sock json pick
    sock=$(clash_sock 2>/dev/null) || return 1
    json=$(curl -s --max-time 10 --unix-socket "$sock" http://localhost/proxies 2>/dev/null)
    [ -n "$json" ] || return 1
    pick=$(printf '%s' "$json" | "${CLAUDE_SWITCHER_PYTHON:-python3}" -c '
import json, re, sys
try:
    proxies = json.load(sys.stdin).get("proxies") or {}
except Exception:
    sys.exit(0)
BAD = {"DIRECT", "REJECT", "GLOBAL", "PASS"}
current = sys.argv[1] if len(sys.argv) > 1 else ""
best, best_score = "", -1
for name, item in proxies.items():
    if name in BAD or not isinstance(item, dict) or "all" not in item:
        continue
    # 组内全是 DIRECT/REJECT 的「组」没有代理意义,选上去也是死路
    if not [m for m in (item.get("all") or []) if m not in BAD]:
        continue
    gtype = str(item.get("type") or "").lower()
    if gtype not in ("select", "fallback", "url-test", "load-balance", "relay"):
        continue
    score = 0
    if name == current:
        score += 1000  # 现组名仍有效:无条件保留,订阅正常时不许乱换
    if re.search(r"固定|fixed", name, re.I):
        score += 100  # 产品语义:固定出口组是最优目标
    if re.search(r"ai|openai|干净|clean", name, re.I):
        score += 50
    if gtype in ("select", "fallback"):
        score += 10   # 手动/fallback 组比自动测速组更贴合「钉死规则」的用途
    if score > best_score:
        best, best_score = name, score
if best:
    print(best)
' "$PROXY_GROUP" 2>/dev/null)
    [ -n "$pick" ] || return 1
    [ "$pick" = "$PROXY_GROUP" ] && return 0
    support env-set "proxy_group=$pick" >/dev/null 2>&1 || return 1
    PROXY_GROUP="$pick"
    GROUP_RESELECTED=1
    return 0
}

# 运行配置的 DNS 段。内核 runtime 配置在 root 服务区不可读,但 Clash Verge 每次
# 应用配置都会重新生成用户目录这份(clash-verge.yaml),内容与内核加载的一致。
runtime_dns_section() {
    local cfg="$CLASH_DIR/clash-verge.yaml"
    [ -f "$cfg" ] || return 1
    awk '/^dns:/{f=1;print;next} f&&/^[^[:space:]#]/{exit} f{print}' "$cfg"
}

# 从 DNS 段提取某个列表键的条目。块形式(逐行 `  - xxx`)与内联数组
# (`fallback: [8.8.4.4]`)都支持 —— 只认块形式会把内联写法判成「空」,
# 老架构漏掉点名、干净的内联配置被误报 fail(2026-11-23 审计发现)。
dns_list_entries() {
    local section="$1" key="$2"
    printf '%s\n' "$section" | awk -v key="$key" '
        $0 ~ "^  " key ":" {
            if (match($0, /\[.*\]/)) {
                inline = substr($0, RSTART + 1, RLENGTH - 2)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", inline)
                gsub(/^"|"$/, "", inline)
                n = split(inline, parts, /,[[:space:]]*/)
                for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
                exit
            }
            block = 1; next
        }
        block && /^  [a-zA-Z]/ { exit }
        block && /^  - / { print $2 }
    '
}

# DNS 上游体检:只审计能从配置文本机械确定的泄露形态(2026-11-23 实测的泄露类):
#   1. fallback 非空 —— nameserver+fallback 并发查询,海外域名必进国内递归(泄露源头);
#   2. nameserver 含明文 UDP 上游 —— 运营商可见、可劫持;
#   3. nameserver 无海外加密上游 —— 海外域名由国内递归解析,权威侧看到国内解析器。
# 有问题输出问题列表并返回 0;无问题输出空返回 1。只对 clash-verge 生效(其余客户端
# 读不到标准 YAML 运行配置,不硬猜)。
dns_audit() {
    local section issues="" ns plain="" foreign="" u fb
    if [ "$PROXY_MODE" != "clash-verge" ]; then return 1; fi
    section=$(runtime_dns_section 2>/dev/null) || return 1
    fb=$(dns_list_entries "$section" fallback)
    [ -n "$fb" ] && issues="${issues}fallback 并发查询未清空(泄露源头) "
    ns=$(dns_list_entries "$section" nameserver)
    if [ -z "$ns" ]; then
        issues="${issues}nameserver 为空 "
    else
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            case "$u" in
                https://*|tls://*|quic://*) ;;
                *) plain="${plain}${u} " ;;
            esac
            case "$u" in
                *8.8.8.8*|*1.1.1.1*|*dns.google*|*cloudflare-dns.com*|*9.9.9.9*|*dns.quad9.net*|*dns.sb*|*dns.opendns.com*|*dns.adguard.com*) foreign=1 ;;
            esac
        done <<< "$ns"
        [ -n "$plain" ] && issues="${issues}nameserver 含明文上游(${plain% }) "
        [ -z "$foreign" ] && issues="${issues}nameserver 无海外加密上游(海外域名将由国内递归解析) "
    fi
    [ -n "$issues" ] && { printf '%s\n' "${issues% }"; return 0; }
    return 1
}

# DNS 修复块写进 Merge.yaml(全局 merge,订阅更新覆盖后仍生效)。与 Script.js 同一套
# 纪律:标记块内机器管、块外内容保留、写前备份、无变化不落盘。Merge.yaml 若有块外
# 的顶层 dns: 键必须移除 —— 同一 YAML 映射里重复的 dns: 键会让 mihomo 拒载整份配置。
write_dns_merge() {
    local merge="$CLASH_DIR/profiles/Merge.yaml"
    [ -d "$CLASH_DIR/profiles" ] || { echo "profiles 目录不存在"; return 1; }
    local block new
    block='# >>> claude-switcher managed dns >>>
# 海外域名只由海外加密上游解析,fallback 并发已清空。
# 依据 2026-11-23 实测:订阅原生架构(国内 nameserver + fallback 并发)会把海外
# 域名的解析送进国内递归,权威侧看到国内解析器(泄露)。geosite:cn/private 仍走
# 国内 DoH(国内域名直连快解析);proxy-server-nameserver 用国内 DoH 解析节点
# 服务器域名,避免「解析节点要走代理、走代理要先解析节点」的死锁。
dns:
  respect-rules: true
  nameserver:
  - https://8.8.8.8/dns-query
  - https://1.1.1.1/dns-query
  fallback: []
  proxy-server-nameserver:
  - https://doh.pub/dns-query
  - https://dns.alidns.com/dns-query
  nameserver-policy:
    geosite:cn:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
    geosite:private:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
# <<< claude-switcher managed dns <<<'
    new=$(
        if [ -f "$merge" ]; then
            awk '/# >>> claude-switcher managed dns >>>/{skip=1;next}
                 skip&&/# <<< claude-switcher managed dns <<</{skip=0;next}
                 skip{next}
                 # 块外顶层 dns: 键及其子树移除(由托管块接管,避免重复键拒载)
                 /^dns:/{d=1;next} d&&/^[^[:space:]#]/{d=0} !d{print}' "$merge"
        fi
        printf '%s\n' "$block"
    )
    if [ -f "$merge" ] && [ "$(cat "$merge")" = "$new" ]; then
        echo "无变化"
        return 0
    fi
    [ -f "$merge" ] && cp "$merge" "$merge.bak.$(date +%Y%m%d-%H%M%S)"
    printf '%s\n' "$new" > "$merge.tmp" && mv "$merge.tmp" "$merge" \
        || { echo "写入 Merge.yaml 失败"; return 1; }
    echo "已写入 Merge.yaml(重启客户端后生效)"
}

# 读取环境层。env.json 缺失 → 用保底值(首次安装与老版本升级都走这条路);
# env.json 损坏 → 明确报错,不静默降级:环境值错会直接把规则写进错误的代理组。
load_env() {
    local dump key value
    # env.json 只有安装器跑过才存在。从仓库直接跑、或升级时迁移没跑成,都会没有它 ——
    # 这时头部 PROXY_GROUP 是空的,规则校验会直接 fail 并把 Claude 拦在门外,
    # 比不检查更糟。所以缺失时先自愈:从已安装脚本头部迁移一次(升级路径)。
    if [ ! -f "$ENV_FILE" ] && [ -f "$HOME/.local/bin/claude-switch.sh" ]; then
        support env-migrate "$HOME/.local/bin/claude-switch.sh" >/dev/null 2>&1 || true
    fi
    if [ -f "$ENV_FILE" ]; then
        dump=$(support env 2>/dev/null) || {
            echo "FAIL:环境配置 $ENV_FILE 无法解析,请运行 claude-switch.sh env-set 或重跑安装器" >&2
            return 1
        }
        while IFS='=' read -r key value; do
            case "$key" in
                proxy_mode)
                    # 只挡控制字符/空白;新客户端名(或旧版遗留值)仍可读,
                    # proxy_alive / proxy_name 的默认分支会处理未知值。
                    if [ -n "$value" ]; then
                        case "$value" in
                            *[!a-z0-9-]*) echo "FAIL:env.json 中的 proxy_mode 含非法字符: $value" >&2; return 1 ;;
                            *) PROXY_MODE="$value" ;;
                        esac
                    fi ;;
                proxy_group)   PROXY_GROUP="$value" ;;
                country)       [ -n "$value" ] && COUNTRY_TARGET="$value" ;;
                timezone)
                    # 时区会进入管理员命令和 root 看门狗脚本,只接受 IANA 形状;
                    # 不校验就等于把 env.json 当成 root shell 的片段。
                    if [ -n "$value" ]; then
                        if [[ "$value" =~ ^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]; then
                            TZ_TARGET="$value"
                        else
                            echo "FAIL:env.json 中的 timezone 无效(应为 Area/City): $value" >&2
                            return 1
                        fi
                    fi ;;
                locale)        [ -n "$value" ] && LOCALE_TARGET="$value" ;;
                clash_dir)     CLASH_DIR="$value" ;;
                fake_ip_range)
                    if [ -n "$value" ]; then
                        if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                            FAKE_IP_RANGE="$value"
                        else
                            echo "FAIL:env.json 中的 fake_ip_range 无效(应为 CIDR): $value" >&2
                            return 1
                        fi
                    fi ;;
            esac
        done <<< "$dump"
    fi
    [ -z "$CLASH_DIR" ] && CLASH_DIR="$(detect_clash_dir)"
    [ -z "$FAKE_IP_RANGE" ] && FAKE_IP_RANGE="$(detect_fake_ip_range "$CLASH_DIR")"
    FAKE_PREFIX="$(fake_ip_prefix "$FAKE_IP_RANGE")"
    # 迁移没带出代理组(已安装脚本本身就是新架构、头部为空)时,从运行中的内核规则
    # 反查一次,并把结果落进 env.json,避免每次启动都重新拉 4MB 规则。
    if [ -z "$PROXY_GROUP" ]; then
        PROXY_GROUP="$(detect_proxy_group)"
        [ -n "$PROXY_GROUP" ] && support env-set "proxy_group=$PROXY_GROUP" >/dev/null 2>&1
    fi
    # 到这里仍然没有环境层:说明既没有安装记录也探测不到代理组,后面的规则校验
    # 必然 fail。把原因说出来,别让用户对着「规则置顶未生效」猜。
    if [ ! -f "$ENV_FILE" ] || [ -z "$PROXY_GROUP" ]; then
        echo "WARN:环境层缺失($ENV_FILE),环境值在用保底值;请重跑安装器或执行 claude-switch.sh env-set 补齐" >&2
    fi
    return 0
}

load_env || exit 1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

CHECKS_DISABLED=""
CHECKS_STRICT=""
ALLOW_OPTIONAL_FAILURES=0
load_check_config() {
    local config key value
    config=$(support config 2>/dev/null) || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            disabled) CHECKS_DISABLED="$value" ;;
            strict) CHECKS_STRICT="$value" ;;
            allowOptionalFailures) ALLOW_OPTIONAL_FAILURES="$value" ;;
        esac
    done <<< "$config"
}
check_disabled() { case ",$CHECKS_DISABLED," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
# 用户把某个可选项升成了硬性基线:失败要拦启动,不只是提示。
check_strict() { case ",${CHECKS_STRICT:-}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
optional_failure() {
    [ "$ALLOW_OPTIONAL_FAILURES" = "1" ] || fails="$fails;$1"
}
optional_result() {
    local name="$1" state="$2" detail="${3:-}"
    if check_disabled "$name"; then
        echo "$name=skip:用户已禁用"
    elif [ "$state" = "fail" ] && [ "$ALLOW_OPTIONAL_FAILURES" = "1" ]; then
        echo "$name=warn:非关键失败已忽略${detail:+($detail)}"
    else
        echo "$name=$state${detail:+:$detail}"
    fi
}

# 检查项不合格有三种性质,不能都揉成一个 fail:
#   config —— 环境层没配好(代理组/目标值缺失),系统根本无从判定安全性。用户该做的是
#             重新配置,不是去查规则。以前这种情况也报 fail,于是「没配置」看起来像
#             「不安全」,用户照着提示去修规则,越修越远。
#   fail   —— 已配置,但实测不达标。这才是真的安全问题,必须拦启动。
#   warn   —— 非硬性项不达标,只提示(见 optional_result)。
# 三者都拦启动(config 拦是因为「没验证过」不能当「验证通过」),区别在于提示语和动作。
config_result() {
    local name="$1" detail="${2:-}"
    echo "$name=config${detail:+:$detail}"
}
log_result() {
    local started="$1" command="$2" rc="$3" summary="${4:-}"
    "$0" _support log "$command" "$rc" "$(( ($(date +%s) - started) * 1000 ))" "$summary" >/dev/null 2>&1 || true
}

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
# TUN 是否在线:看是否有一块网卡拿到了 fake-ip 段的地址。
# 前缀跟着实际 fake-ip-range 走,不再写死 198.18. —— 用户改过网段就会误判成"TUN 没起"。
tun_up() { ifconfig 2>/dev/null | grep -qF "inet ${FAKE_PREFIX:-198.18.}"; }

# 代理客户端显示名(供检查细节输出)
proxy_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        flclash)      echo "FlClash" ;;
        shadowrocket) echo "Shadowrocket" ;;
        sing-box)     echo "sing-box" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        auto)         echo "代理客户端" ;;
        *)            echo "$PROXY_MODE" ;;
    esac
}

# 可 open -a 启动的客户端 App 名(sing-box/auto 无标准 App,返回空)
proxy_app_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        flclash)      echo "FlClash" ;;
        shadowrocket) echo "Shadowrocket" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        *)            echo "" ;;
    esac
}

# 让 Clash Verge 真的退出。只发 AppleScript quit 不够 —— 实测这个 Tauri 应用
# 会忽略它:PID 不变,紧接着的 open 只是把窗口唤到前台,运行时配置根本没重新生成,
# 用户点「一键修复」看到的是「置顶规则 ✗ 未验证内核加载」,而脚本以为已经重启过了。
# 所以等一小会儿还没退就补一个 SIGTERM(它会走自己的清理流程,把内核一起停掉)。
quit_clash_verge() {
    local pid i
    osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
    for i in $(seq 1 8); do
        pgrep -f "Clash Verge.app/Contents/MacOS/clash-verge" >/dev/null || return 0
        sleep 1
    done
    pid=$(pgrep -f "Clash Verge.app/Contents/MacOS/clash-verge" | head -1)
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 10); do
        pgrep -f "Clash Verge.app/Contents/MacOS/clash-verge" >/dev/null || return 0
        sleep 1
    done
    return 1
}

# 安装器在写完全局脚本后调用它。只重启客户端并等待内核真正加载规则,
# 不重复 fix 的时区/IPv6/账号逻辑;失败时返回非零让安装器提示用户。
restart_clash() {
    [ "$PROXY_MODE" = "clash-verge" ] || { echo "SKIP:当前客户端不是 Clash Verge"; return 0; }
    if ! quit_clash_verge; then
        echo "FAIL:Clash Verge 未能在 18 秒内退出"; return 1
    fi
    # 退出后补注册:运行中改 profiles.yaml 会被它退出时写回覆盖。
    clash_rules register-script >/dev/null 2>&1 || true
    open -a "Clash Verge" >/dev/null 2>&1 || { echo "FAIL:无法启动 Clash Verge"; return 1; }
    local i out="" loaded=0
    for i in $(seq 1 40); do tun_up && break; sleep 1; done
    for i in $(seq 1 15); do
        if out=$(clash_rules verify 2>&1); then loaded=1; break; fi
        sleep 1
    done
    if [ "$loaded" -eq 1 ]; then
        echo "OK:Clash Verge 已重启,内核已加载置顶规则"
        return 0
    fi
    echo "WARN:Clash Verge 已重启,但内核仍未加载置顶规则:${out:-未知}"
    return 1
}

# Shadowrocket 在 Mac 上表现为 VPN 配置;launchd/非图形环境下 scutil 可能查不到该行,此时以 TUN 判定为准(避免误杀)
shadowrocket_up() {
    nc=$(scutil --nc list 2>/dev/null)
    if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
        echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)'
    else
        tun_up
    fi
}

# 代理内核在线判定:按安装时识别的客户端分派;auto 时任一命中即活
proxy_alive() {
    case "$PROXY_MODE" in
        clash-verge)  pgrep -f verge-mihomo >/dev/null 2>&1 ;;
        flclash)      pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1 ;;
        shadowrocket) shadowrocket_up ;;
        sing-box)     pgrep -f sing-box >/dev/null 2>&1 ;;
        clashx)       pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 ;;
        surge)        pgrep -f Surge >/dev/null 2>&1 ;;
        auto)         pgrep -f verge-mihomo >/dev/null 2>&1 || shadowrocket_up \
                      || pgrep -f sing-box >/dev/null 2>&1 \
                      || pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 \
                      || pgrep -f Surge >/dev/null 2>&1 ;;
        *)            pgrep -f verge-mihomo >/dev/null 2>&1 ;;
    esac
}

# 单文件内嵌 Python 的隔离入口;策略从 WEBRTC_POLICY 或持久化文件读取。
clash_rules() {
    local action="$1"
    shift
    "${BASH:-/bin/bash}" "$0" clash-rules "$action" "$CLASH_DIR" "$BASE" "$PROXY_GROUP" "${WEBRTC_POLICY:-}" "$@"
}

# WebRTC UDP 策略的独立写入口。只改策略文件,不碰内核、不碰规则、不需要管理员权限。
#
# 为什么必须有它:`clash_rules write` 也会写这个文件,但它在写之前先跑
# validate_group —— proxy 策略要求当前节点 udp=true。HTTP 之类不支持 UDP 的节点上,
# 这道校验必失败,于是「把策略改成 reject」这个动作被它自己要修的校验挡死了:
# 报错建议用户「改用 reject 策略」,界面和命令行却没有任何入口能改,一键修复
# 永远在写规则那步 return 1。先给一条不经过内核校验的落盘路径解开这个自锁。
set_webrtc_policy() {
    local mode="${1:-}"
    case "$mode" in
        proxy|reject) ;;
        *) echo "FAIL:用法 set-webrtc-policy <proxy|reject>"; return 1 ;;
    esac
    mkdir -p "$BASE" || { echo "FAIL:无法写入 $BASE"; return 1; }
    printf '%s\n' "$mode" > "$BASE/webrtc-policy.tmp" \
        && mv "$BASE/webrtc-policy.tmp" "$BASE/webrtc-policy" \
        || { echo "FAIL:写入 WebRTC 策略失败"; return 1; }
    echo "OK:WebRTC 策略已设为 $mode(下次检查生效)"
}

# 只接受运行中内核加载的规则，不再用配置文本或 fake-ip 代替。
merge_ok() { clash_rules verify >/dev/null 2>&1; }

# 把内核校验的失败原因翻成「缺什么 + 点哪里」。
# verify 在第一个不匹配处就退出,只能报出首个缺失项,所以别在这里写条数
# (域名清单会长,写死的数字很快就会过期)。
rule_fix_hint() {
    local msg="${1%%$'\n'*}"
    case "$msg" in
        *未按策略置顶:UDP/*)
            printf 'UDP %s 规则没置顶 · 点「一键修复」' "${msg##*:UDP/}" ;;
        *未按策略置顶:*)
            printf '内核缺少 Claude 域名(%s 等) · 点「一键修复」' "${msg##*:}" ;;
        *不是*rule*模式*)
            printf '客户端不在规则模式 · 切到「规则」后重新检查' ;;
        *代理组不存在*|*实际的代理组*)
            printf '配置的代理组在客户端里不存在(常见于订阅更新)· 点「一键修复」会自动切换到可用组' ;;
        *没有可用的当前节点*|*直连或拒绝*)
            printf '代理组当前节点是直连或拒绝 · 换一个代理节点' ;;
        *UDP*)
            # 旧文案只叫用户换节点或换策略,可那时工具根本没有切策略的入口,
            # 用户照着做只会原地打转。改成指向真能生效的那个动作。
            printf '当前节点不支持 UDP · 点「一键修复」自动切到拒绝策略,或换支持 UDP 的节点' ;;
        *数量不足*)
            printf '内核规则条数不足 · 点「一键修复」' ;;
        *接口不可用*)
            printf '读不到内核控制接口 · 确认客户端已启动后重新检查' ;;
        "")
            printf '规则校验未通过 · 点「一键修复」' ;;
        *)
            printf '%s · 点「一键修复」' "$msg" ;;
    esac
}
# 当前 Clash 模式(rule/global/direct);读取失败返回空
clash_mode() { clash_rules mode 2>/dev/null; }

# 置顶规则行为检测:三个生态域名全部解析到 fake-ip 段($FAKE_PREFIX)即视为已置顶;未命中域名记入 ROUTE_MISSED
route_ok() {
    ROUTE_MISSED=""
    local d a
    for d in claude.ai api.anthropic.com claudeusercontent.com; do
        a=$(dig +short +time=3 +tries=1 "$d" 2>/dev/null | head -1)
        case "$a" in
            "$FAKE_PREFIX"*) ;;
            *) ROUTE_MISSED="$ROUTE_MISSED $d" ;;
        esac
    done
    [ -z "$ROUTE_MISSED" ]
}

# 国家代码 → 默认 IANA 时区(cloudflare trace 等来源不带时区时使用)
default_tz_for() {
    case "$1" in
        US) echo America/New_York ;; JP) echo Asia/Tokyo ;; TW) echo Asia/Taipei ;;
        HK) echo Asia/Hong_Kong ;; SG) echo Asia/Singapore ;; GB) echo Europe/London ;;
        DE) echo Europe/Berlin ;; FR) echo Europe/Paris ;; KR) echo Asia/Seoul ;;
        AU) echo Australia/Sydney ;; CA) echo America/Toronto ;;
        *) echo America/New_York ;;
    esac
}

# 出口探测辅助:严格校验两位大写国家码与 IANA 时区格式
_geo_valid_country() {
    case "$1" in [A-Z][A-Z]) return 0 ;; *) return 1 ;; esac
}
_geo_valid_tz() {
    [[ "$1" =~ ^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]
}
_geo_json_field() {
    printf '%s\n' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}
_geo_diag_add() {
    GEO_DIAG="${GEO_DIAG:+$GEO_DIAG; }$1"
    if [ -n "${GEO_DIAG_FILE:-}" ]; then
        printf '%s\n' "$1" >>"$GEO_DIAG_FILE"
    fi
}
# 取一个源;失败把简短原因(HTTP 码/超时)记进诊断,不打印
_geo_fetch() {
    local out rc code
    _GEO_BODY=""
    out=$(curl -s --max-time 8 -w '\n%{http_code}' "$1" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        _geo_diag_add "$2 超时/连接失败"
        return 1
    fi
    if [ -z "$out" ]; then
        _geo_diag_add "$2 无响应"
        return 1
    fi
    code=$(printf '%s\n' "$out" | tail -n 1)
    case "$code" in
        200)
            _GEO_BODY=$(printf '%s\n' "$out" | sed '$d')
            return 0 ;;
        [0-9][0-9][0-9])
            _geo_diag_add "$2 HTTP $code"
            return 1 ;;
        *)
            # 没有 -w 状态行时按成功处理(兼容 curl 替身/中间层)
            _GEO_BODY="$out"
            return 0 ;;
    esac
}
# 记录一个成功源;首个成功源优先,后续来源国家不一致只告警
_geo_consider() {
    [ -z "$1" ] && return 0
    if [ -z "$_GEO_CC" ]; then
        _GEO_CC="$1"; _GEO_TZ="$2"; _GEO_SRC="$3"
    elif [ "$1" != "$_GEO_CC" ]; then
        printf 'WARN:出口国家不一致(%s=%s %s=%s),采用优先级更高的 %s\n' \
            "$_GEO_SRC" "$_GEO_CC" "$3" "$1" "$_GEO_SRC" >&2
    fi
}

# 多源出口探测:ipinfo → ipapi → ifconfig → cloudflare trace,成功源按此优先级取首个;
# 全部失败输出 "||",各源失败原因写入 GEO_DIAG_FILE(命令替换会丢子 shell 变量)。
geo_lookup() {
    local cc tz loc
    local _GEO_BODY="" _GEO_CC="" _GEO_TZ="" _GEO_SRC=""
    GEO_DIAG=""

    if _geo_fetch "https://ipinfo.io/json" ipinfo; then
        cc=$(_geo_json_field "$_GEO_BODY" country)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipinfo
        else
            _geo_diag_add "ipinfo 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ipapi.co/json/" ipapi; then
        cc=$(_geo_json_field "$_GEO_BODY" country_code)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipapi
        else
            _geo_diag_add "ipapi 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ifconfig.co/json" ifconfig; then
        cc=$(_geo_json_field "$_GEO_BODY" country_iso)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ifconfig
        else
            _geo_diag_add "ifconfig 国家字段无效"
        fi
    fi

    if _geo_fetch "https://www.cloudflare.com/cdn-cgi/trace" cloudflare; then
        loc=$(printf '%s\n' "$_GEO_BODY" | tr -d '\r' | sed -n 's/^loc=\([A-Za-z][A-Za-z]\)$/\1/p' | head -n 1 | tr 'a-z' 'A-Z')
        if _geo_valid_country "$loc"; then
            _geo_consider "$loc" "$(default_tz_for "$loc")" cloudflare
        else
            _geo_diag_add "cloudflare loc 无效"
        fi
    fi

    if [ -z "$_GEO_CC" ]; then
        printf '||\n'
        return 1
    fi
    printf '%s|%s|%s\n' "$_GEO_CC" "$_GEO_TZ" "$_GEO_SRC"
    return 0
}

# 国家代码 → 地区格式映射(未收录的国家回退 en_US)
locale_for() {
    case "$1" in
        US) echo en_US ;; JP) echo ja_JP ;; TW) echo zh_TW ;; HK) echo zh_HK ;;
        SG) echo en_SG ;; GB) echo en_GB ;; DE) echo de_DE ;; FR) echo fr_FR ;;
        KR) echo ko_KR ;; AU) echo en_AU ;; CA) echo en_CA ;; *) echo en_US ;;
    esac
}

# 出口 IP 的归一身份。同一节点会按本次连接走的协议族报出不同形态的地址
# (IPv4 或 IPv6),拿原始串直接比,一个没动过的节点也会被判成「IP 在变」。
# 实测踩到:同一节点先后取到 144.172.103.106 和 2602:fa59:10:503::1,
# 「IP 与上次一致」报 warn、48h 变化次数虚高,而账号来源根本没变。
#   v4 → 原样
#   v6 → 取 /64 前缀做身份:隧道出口的接口标识可能轮换,网段不会
ip_key() {
    case "$1" in
        '') return 1 ;;
        *:*) printf 'v6:%s' "$(printf '%s' "$1" | cut -d: -f1-4)" ;;
        *)   printf 'v4:%s' "$1" ;;
    esac
}

# 归一身份只用于比对,展示时去掉族标记,免得界面上出现 v4:/v6: 这种内部记号。
ip_show() {
    case "$1" in
        v4:*) printf '%s' "${1#v4:}" ;;
        v6:*) printf '%s' "${1#v6:}" ;;
        *)    printf '%s' "$1" ;;
    esac
}

# 旧版本写进 lastip 的是裸地址(没有 v4:/v6: 前缀)。升级后如果直接比,
# 第一次检查必然报「IP 变了」—— 正是这个函数要消除的误报。读时统一迁移。
ip_key_migrate() {
    case "$1" in
        '') return 0 ;;
        v4:*|v6:*) printf '%s' "$1" ;;
        *) ip_key "$1" ;;
    esac
}

# 出口 ASN / 运营商。一次检查里只查一次:出口变了要判类型、ASN 检查项也要用它,
# 查两次纯属浪费,而且两次之间出口可能正好在飘。
IP_ORG=""; IP_ORG_LOOKED="0"
# org 是 IP 的固有属性,不会自己变。一次检查查一次只解决了「同一次里别查两遍」,
# 跨检查还是每次都查 —— 单次约 1.4 秒,占整轮检查的十分之一,而出口 IP 往往
# 一整天都不动。按 IP 缓存 24 小时:出口换了自然就查新的,没换就不该重复付这个钱。
ORG_CACHE_TTL=86400
# 类型证据(asn.type / company.type)同样是 ASN 的固有分类:ipinfo 判 GTT 是 isp,
# 这个判断一天内不会翻。但它只有 ipinfo 一家能给,而 ipinfo 是免费额度最小的源 ——
# 必须单独存一份,否则一次 429 就把刚查到过的证据一起丢掉(见 ip_purity)。
TYPE_CACHE_TTL=86400
ip_org() {
    [ "$IP_ORG_LOOKED" = "1" ] && { printf '%s' "$IP_ORG"; return 0; }
    IP_ORG_LOOKED="1"
    [ -z "${1:-}" ] && return 0
    local ip="$1" now cip corg cts tmp api stale=""
    now=$(date +%s)
    if [ -n "${BASE:-}" ] && [ -f "$BASE/org-cache" ]; then
        while IFS=$(printf '\t') read -r cip corg cts; do
            [ "$cip" = "$ip" ] && [ -n "$corg" ] || continue
            case "${cts:-}" in ''|*[!0-9]*) continue ;; esac
            if [ $((now - cts)) -lt "$ORG_CACHE_TTL" ]; then
                IP_ORG="$corg"; printf '%s' "$IP_ORG"; return 0
            fi
            # 过期了不丢弃:先记下来,三个源都问不出来时用它兜底(见函数末尾)。
            # org 是 IP 的固有属性,一天前查到的 GTT 今天还是 GTT。
            stale="$corg"
            break
        done < "$BASE/org-cache"
    fi
    # 必须查「实际出口 IP」的 ASN。直接查 ipinfo.io/json 取的是访问 ipinfo 自身
    # 那条链路的出口,在分流配置下可能与受保护流量的出口不是同一个 IP,
    # 从而报出不相干的 ASN(例如受保护出口是机房 A,却报成 Cloudflare)。
    #
    # **不能只赌 ipinfo 一家。** 它的免注册额度最小,而共享代理出口很容易把它打满:
    # 2026-11-21 实测同一条出口连查 8.8.8.8 / 1.1.1.1 / 66.17.65.38 全部回 429
    # (限流按调用方算,不是按被查地址),/json 与 widget 两个端点一起哑。那天
    # org-cache 里 GTT 的记录刚过 24h 不到 10 分钟,于是既没续上也没回源成功,
    # 界面从「ASN 属性:GTT Communications Inc.」掉成「未获取」,整轮少一项通过。
    # ipquery 与 ip-api 的响应里本来就带运营商名,零额外成本,必须拿它们兜底。
    IP_ORG=$(curl -s --max-time 6 "https://ipinfo.io/$ip/json" 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    [ -z "$IP_ORG" ] && IP_ORG=$(curl -s --max-time 6 "https://api.ipquery.io/$ip" 2>/dev/null \
        | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$IP_ORG" ]; then
        # ip-api 的 as 字段是「AS3257 GTT Communications Inc.」这种最完整的写法,
        # org 有时只有公司短名,isp 再退一档。
        api=$(curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,as,org,isp" 2>/dev/null)
        IP_ORG=$(printf '%s' "$api" | grep -o '"as"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -z "$IP_ORG" ] && IP_ORG=$(printf '%s' "$api" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -z "$IP_ORG" ] && IP_ORG=$(printf '%s' "$api" | grep -o '"isp"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    # 三个源全挂,但缓存里那条过期记录本身并没有说错 —— 用它,比在界面上写
    # 「未获取」诚实。**不写缓存**:没验证过的旧名不该被续命成新证据。
    if [ -z "$IP_ORG" ] && [ -n "$stale" ]; then
        IP_ORG="$stale"
        printf '%s' "$IP_ORG"; return 0
    fi
    # 查不到就不写缓存:否则一次网络抖动会把「未知」钉住 24 小时
    if [ -n "${BASE:-}" ] && [ -n "$IP_ORG" ]; then
        tmp="$BASE/org-cache.tmp"
        { [ -f "$BASE/org-cache" ] && grep -vF "$ip"$'\t' "$BASE/org-cache"
          printf '%s\t%s\t%s\n' "$ip" "$IP_ORG" "$now"; } 2>/dev/null | tail -20 > "$tmp" \
            && mv "$tmp" "$BASE/org-cache"
    fi
    printf '%s' "$IP_ORG"
}

# 出口类型:residential(运营商宽带) / hosting(机房) / unknown(未归类)。
# 参考 net.coffee 的 Claude Code 指南第 2 条:家宽 IP 定期变动是正常网络行为,
# 机房 IP 变动才是风控信号。所以「IP 变了」这件事不能一律同等对待 ——
# 拿同一个阈值套两种出口,结果就是家宽用户天天看到假警报、机房用户没被提醒。
#
# **默认值必须是 unknown,不能是 hosting。** 以前这里是「不在住宅白名单就算机房」,
# 代价在 2026-11-06 实测到了:66.17.65.38(AS3257 GTT)三家源一致说
# is_datacenter:false / hosting:false / risk_score:0,ip.net.coffee 判它
# 「住宅 98/100」,而我们的界面显示「ASN 属性:疑似机房 · 建议换住宅节点」。
# 白名单只收录 11 个国家的几十家运营商,它永远覆盖不完 —— 拿「没收录」当
# 「是机房」,等于把所有非主流运营商用户都误报一遍。
# 现在的口径:白名单命中 → residential;名字里带明确的机房/云/托管/骨干词 →
# hosting;其余 → unknown(由调用方按保守口径处理,不扣帽子)。
ip_class() {
    local o
    # 先把 org 串归一:转小写、去掉空格和逗号。
    # 两个原因:(1) ipinfo 的 org 大小写不统一("Korea Telecom" / "KOREA TELECOM");
    # (2) case 的模式是「词」,里面的空格和 & 会终止词、直接触发语法错误,
    #     归一之后模式里就不需要任何转义,也不用担心哪天名单里多个空格就崩。
    o=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -d ' ,')
    case "$o" in
        '') printf 'unknown' ;;
        # 名单按 set-region 支持的目标地区收:US/JP/KR/TW/SG/HK/GB/DE/CA/AU。
        # 误判成 residential 的方向更危险 —— 那会让真正的机房出口免于告警,
        # 所以宁可少收录,也不要用 *bt* / *m1* 这种会撞上无关公司的短词。
        # 同理不收录 1&1:ipinfo 报的是 "1&1 IONOS SE",那是它的云主机业务。
        # (模式列表里不能夹注释 —— 反斜杠续行会把注释并进同一条命令,直接语法错。)
        *comcast*|*at\&t*|*verizon*|*spectrum*|*charter*|*cox*|*t-mobile*|*cable*|*esidential*|\
        *centurylink*|*frontier*|*windstream*|*mediacom*|*suddenlink*|\
        *ntt*|*kddi*|*softbank*|*iij*|*ocn*|*so-net*|\
        *koreatelecom*|*ktcorp*|*skbroadband*|*sktelecom*|*lgu+*|*lgpowercomm*|*dacom*|\
        *hinet*|*chunghwa*|*kbro*|*taiwan*|*fareastone*|*datacommunication*|\
        *singtel*|*starhub*|*m1limited*|\
        *hkt*|*pccw*|*hkbn*|*hgc*|\
        *britishtelecom*|*btgroup*|*skybroadband*|*virginmedia*|*talktalk*|*vodafone*|\
        *deutschetelekom*|*telefonicagermany*|*o2germany*|\
        *bellcanada*|*rogers*|*telus*|*shawcommunications*|\
        *telstra*|*optus*|*tpg*|*iinet*) printf 'residential' ;;
        # 明确的机房/托管/云/骨干/IDC 关键词。这一条是「正面证据」,
        # 也是原来那个 hosting 默认值的正确用法:命中才叫机房。
        *hosting*|*datacenter*|*datacentre*|*colocation*|*colocrossing*|*server*|*vps*|\
        *cloud*|*dedicated*|*backbone*|*transit*|*cdn*|*telehouse*|*equinix*|\
        *digitalocean*|*linode*|*vultr*|*hetzner*|*ovh*|*leaseweb*|*racknerd*|\
        *choopa*|*contabo*|*amazon*|*google*|*microsoft*|*alibaba*|*tencent*) printf 'hosting' ;;
        *) printf 'unknown' ;;
    esac
}

# ---- IP 纯净度评级 ----
# 口径对齐 ip.net.coffee 的 Trust Score。实测它给:住宅 100、VPN 61~69、机房 51~58、
# Tor 43~50,结构是「按出口类型给基线分,再按滥用记录惩罚」,不是从 100 逐项减。
# 照这个结构走,我们的数字才有对照价值 —— 用户能拿它和别的检测站点比。
#
# 但「分数」和「判定」必须分开。它的 trust_score 衡量的是 IP 信誉(口径宽,连 Tor 都
# 能拿 50 分「良好」),对 Claude 的适用性由另外两层表达:ai_verdict 与受限地区强制 0。
# 我们只有一个分数决定拦不拦启动,所以分数向它对齐、判定按 Claude 风控收紧 ——
# Tor 拿 41 分照样红叉。
#
# 数据源全部免注册:
#   ipquery.io     类型标志 + risk_score + 地理
#   ip-api.com     免费版只走 http,但判别口径不同(实测 Cloudflare WARP 它报
#                  proxy:true,ipquery 只报 datacenter),所以两个都要问
#   ipinfo.io      第三个地理源,用于交叉验证
#   dig -x         PTR。实测 fake-ip 不劫持反向解析,而出口常常自曝身份:
#                  tor-exit-read-me.dfri.se / …static.cloudzy.com / …hsd1.ca.comcast.net
#   stopforumspam  滥用记录。DNSBL 这条走不通:Clash fake-ip 会把任何 A 查询接管成
#                  198.18.x,黑名单命中率全是假的,所以只能用 HTTP 接口。

# 「什么时候问源」和「一条结论能用多久」是两件事,不能塞进同一个参数。
#
# 曾经把它们绑在一起:证据不全的结果只留 5 分钟,靠「提前过期」逼出一次重查。
# 代价在 2026-11-20 量清楚了:巡检每 60 秒跑一次完整 check,而 check 每次都进
# ip_purity —— 降级态下每 5 分钟打一轮四源并发 = 1152 个请求/天,是常态
# (4 个/天)的 288 倍;更糟的是它构成负反馈:某个源限流 → 更容易降级 →
# 查得更勤 → 更容易继续限流。实测 ipinfo 已经回过 429(Rate limit hit)。
#
# 把窗口从 5 分钟调到 15 分钟只是止痛,而且换来了一个更坏的代价:用户手动
# 重查也可能拿到一刻钟前的旧数字 —— 这违背「结果只讲现在对不对」。
# 所以不再调窗口,改成把两件事拆开,用**调用方**区分:
#
#   ip_purity <ip>       读缓存。巡检(check)走这条。出口没变,同一 IP 的信誉
#                        一天内不会剧变,后台每分钟去打扰四家源是纯浪费 ——
#                        那也正是「我们的 IP 被反复送出去」的唯一来源。
#   ip_purity <ip> 1     强制重问。checkdetail 走这条。任何一次给人看的检查
#                        都必须是真结论,绝不返回几小时前的数字。
#
# 于是:出口不变时后台 0 请求;用户要看就一定最新;出口一变就是新的 key,
# 天然重查。降级结果照样按 24h 缓存 —— 它不需要「定时自愈」,用户点一次
# 重新检查就够,而那一次是显式的、他自己要的。
PURITY_CACHE_TTL=86400

# widget/scamalytics 两个源的请求头。scamalytics 对无 UA 的 curl 会回反爬页面,
# ipinfo widget 偶有同样行为;不带浏览器 UA 的响应会被当成「源挂了」,
# 类型证据悄悄缺失。写死一份 UA 不算环境值 —— 它是协议的一部分,不是机器差异。
PURITY_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

# 从扁平 JSON 取标量字段。不引入 jq:检查链路得能在只装了 Xcode 命令行工具的机器上跑,
# 多一个依赖就多一个装不上的理由。
_ipfield() {
    printf '%s' "${1:-}" | grep -o "\"$2\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '" '
}

# 「分数」和「判定」是两把尺子,别把它们揉成一句「风险过高」:
#   score   —— IP 信誉(宽口径),对齐 net.coffee 的 Trust Score,连 Tor 都能拿 50 分;
#   verdict —— 能不能拿这个出口开 Claude 的硬门槛,比分数严得多。
# 代理/VPN 基线 75 分,扣完风险分完全可能是 68 分,但代理特征本身就直接判 fail。
# 旧版 node-scan 把所有 fail 一律写成「风险过高」,还统一扣上「Tor/代理特征」
# 的帽子,于是「68 分」旁边挂着「风险过高」,用户只会以为算错了;
# 非 Tor/代理的 fail 也被一并错标。
# check / checkdetail / node-scan 统一从这里取原因,口径只留一份。
# $1=类型 $2=分数 $3=判定;只有判定为 fail 才输出。
purity_fail_reason() {
    local ptype="${1:-}" pscore="${2:-}" pver="${3:-}" gate=""
    [ "$pver" = fail ] || return 0
    case "$ptype" in
        tor)     gate="Tor 出口" ;;
        vpn)     gate="代理/VPN 特征" ;;
        hosting) gate="机房转租段" ;;
        *)       gate="信誉分偏低" ;;
    esac
    case "$pscore" in
        ''|*[!0-9]*) printf '%s' "$gate" ;;
        *)  if [ "$pscore" -ge 50 ]; then
                printf '%s(信誉 %s 分,分数与判定分开)' "$gate" "$pscore"
            else
                printf '%s(信誉 %s 分)' "$gate" "$pscore"
            fi ;;
    esac
}

# 分数落在哪个区间。用户看排名表时最常问的一句是「多少算好」——
# 只给一个 49 / 68,没有参照系,没法判断。区间只回答「分数本身好看不好看」,
# 不回答「能不能用」:后者看硬门槛,两套尺子会背离(见 purity_fail_reason)。
# 阈值与 verdict 的分数线对齐:75 是 ok 线、50 是 warn 线、30 是机房转租段的拦线。
purity_band() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '未评级' ;;
        *)  if   [ "$1" -ge 90 ]; then printf '优秀'
            elif [ "$1" -ge 75 ]; then printf '良好'
            elif [ "$1" -ge 50 ]; then printf '一般'
            elif [ "$1" -ge 30 ]; then printf '偏差'
            else printf '差'; fi ;;
    esac
}

# 输出一行: <score>|<verdict>|<flags>|<detail>|<cc>
# verdict 取 ok|warn|fail|unknown;unknown = 没拿到数据,由调用方决定怎么报。
ip_purity() {
    local ip="${1:-}" force="${2:-0}" now cip cep cver cscore ctype cdet
    # 字段分隔用 | 而不是 tab:tab 属于 IFS 空白,read 会把前导空字段整个吞掉,
    # 于是「无分数」这条路径会被解析成 score=unknown、detail 为空 —— 静默错位。
    [ -z "$ip" ] && { printf '|unknown||未取到出口IP|'; return 0; }
    now=$(date +%s)

    # 同一出口 24h 内复用结果:一次检查要打 4 个网络请求,而出口一天里不会变几十次。
    # 查不到不写缓存,否则一次网络抖动会把「未知」钉住一整天。
    # 第二个参数是「强制重问」:checkdetail 传 1,巡检不传(见 PURITY_CACHE_TTL 的说明)。
    # 跳过缓存不等同于清缓存 —— 查完仍要落盘,下一次巡检才不会重复打源。
    # 文件名带 v3:第 7 列是出口国家代码。v2 的 6 列没有它,混读会让 detail
    # 把「|US」吞进去,宁可让旧缓存作废(v3 同时清掉 v2 里被钉住 24h 的降级结果)。
    # v4:类型判定改成证据驱动(见 ip_class 与 pos_residential)。改判定的同时
    # 不换文件名,升级后 24 小时内会继续读到「类型不明 / 机房」这种旧结论 ——
    # 用户重装完还是老样子,只能以为我们又没修好。改口径必须让旧缓存失效。
    # v5/v6 同理:v5 是代理特征按源计数 + 判定词显式化;v6 是住宅档不再劝人换住宅。
    # v7:信誉维度连续扣分 + 风险未验证封顶 85。这一版**分数本身变了**(同一 IP 可能
    # 差几分),旧缓存里的数字会和新口径混着显示 —— 必须换文件名让它整体作废。
    # v8:降级结果不再有单独的短过期(一律 24h),要新结论由 checkdetail 传 force
    # 显式重问。同时把降级文案的「稍后重查」改成「点重新检查可重算」—— 缓存里存的是
    # 成品文案,不换名会让用户 24 小时内继续看到「稍后重查」,而它已经不成立了。
    # v9:类型与分数口径重做(2026-11-21,GitHub 业界口径调研后):
    #   新增 widget(ipinfo demo)与 scamalytics 两个源;住宅类型需要正面证据
    #   (asn.type=isp / 白名单 / PTR),「无正面住宅证据封顶 70」删除 —— 干净出口
    #   就是 100;widget 挂了且名字无分类时给「类型不明」而不是冒充住宅。
    #   detail 里新增「欺诈分 N」展示字段。分数语义与类型判定都变了,必须换名。
    # v10:「类型不明」不再产数字分数(用户 2026-11-21 指出:放一个猜的 70 不如
    #   不放)—— 分数列为空,detail 前缀改「未评级(类型证据缺失)」。缓存列结构
    #   没变,但分数列出现了新的合法空值,旧 v9 里数值型的 70 与新口径结论相悖,
    #   必须换名让它整体作废。
    # v11:ipinfo 被限流(429)时不再和「类型真的判不出来」共用一句话 —— 文案改成
    #   「未评级(ipinfo 限流)」+ 标记「·类型源限流」,并且不再劝人「换住宅或原生 IP」
    #   (那时我们没有任何证据说这个出口不好)。org 与类型证据都加了多源兜底与
    #   过期缓存兜底,但那两条不改变文案;改文案就必须换名,理由见下。
    # v12:新增「住宅拨号线路」(relay)一档 —— 类型库说 asn.type=isp、却有源标它机房时,
    #   不再一律判机房。这是照 xykt/IPQuality 与 sinspired/checkip(isp.go:134)的
    #   做法补的:hosting 只是笼统兜底信号,不该抢在类型库之前命中。类型集变了、
    #   标签与建议文案也变了,必须换名。
    # 注意缓存里存的是**成品文案**(第 6 列),所以任何措辞变更都得换文件名,
    # 否则用户 24 小时内看到的还是旧话 —— 这一条以后会一直踩,别再想省这个版本号。
    if [ "$force" != "1" ] && [ -n "${BASE:-}" ] && [ -f "$BASE/purity-cache.v12" ]; then
        while IFS='|' read -r cip cep cver cscore ctype cdet ccc || [ -n "$cip" ]; do
            [ "$cip" = "$ip" ] || continue
            case "${cep:-}" in ''|*[!0-9]*) continue ;; esac
            case "${cscore:-}" in ''|*[!0-9]*) [ -n "$cscore" ] && continue ;; esac
            [ $((now - cep)) -lt "$PURITY_CACHE_TTL" ] || break
            printf '%s|%s|%s|%s|%s' "$cscore" "$cver" "$ctype" "$cdet" "${ccc:-}"
            return 0
        done < "$BASE/purity-cache.v12"
    fi

    local q1 q2 q3 q4 q5 q6 b1 b2 b3 b4 b5 b6 rdns=""
    q1=$(mktemp "${TMPDIR:-/tmp}/purity1.XXXXXX") || return 0
    q2=$(mktemp "${TMPDIR:-/tmp}/purity2.XXXXXX") || { rm -f "$q1"; return 0; }
    q3=$(mktemp "${TMPDIR:-/tmp}/purity3.XXXXXX") || { rm -f "$q1" "$q2"; return 0; }
    q4=$(mktemp "${TMPDIR:-/tmp}/purity4.XXXXXX") || { rm -f "$q1" "$q2" "$q3"; return 0; }
    q5=$(mktemp "${TMPDIR:-/tmp}/purity5.XXXXXX") || { rm -f "$q1" "$q2" "$q3" "$q4"; return 0; }
    q6=$(mktemp "${TMPDIR:-/tmp}/purity6.XXXXXX") || { rm -f "$q1" "$q2" "$q3" "$q4" "$q5"; return 0; }
    # 六个源并行:串行最坏 36 秒,会顶掉 App 的 45 秒检查预算。
    # q5 = ipinfo widget demo:免费无 key,给 asn.type / company.type / privacy.*
    #      (vpn/proxy/tor/relay/hosting 五个布尔)—— 这是「正面类型证据」的主要来源,
    #      2026-11-21 实测对 GTT(AS3257)给 asn.type=isp / privacy.hosting=false,
    #      与名字关键词猜测(「GTT」不含机房词 → 落进「无正面住宅证据」)完全相反。
    # q6 = scamalytics 免费页:页面内嵌一份 JSON("score":"0","risk":"low"),
    #      提取分数做展示口径;页面里的 Server 标志在 HTML 表格里,结构一改就静默
    #      失效,不进模型(2026-11-21 实测它对同一 IP 说 Server:Yes 而 ipinfo 说 isp,
    #      多库并列的意义正在于让这种分歧可见,而不是硬选一边)。
    curl -sL --max-time 6 -H "User-Agent: $PURITY_UA" "https://api.ipquery.io/$ip" >"$q1" 2>/dev/null &
    curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,proxy,hosting,mobile,city,regionName,timezone,countryCode" >"$q2" 2>/dev/null &
    curl -sL --max-time 4 "https://ipinfo.io/$ip/json" >"$q3" 2>/dev/null &
    curl -s --max-time 4 "https://api.stopforumspam.org/api?ip=$ip&json" >"$q4" 2>/dev/null &
    curl -sL --max-time 6 -H "User-Agent: $PURITY_UA" "https://ipinfo.io/widget/demo/$ip" >"$q5" 2>/dev/null &
    curl -sL --max-time 6 -H "User-Agent: $PURITY_UA" "https://scamalytics.com/ip/$ip" >"$q6" 2>/dev/null &
    wait
    b1=$(cat "$q1" 2>/dev/null); b2=$(cat "$q2" 2>/dev/null)
    b3=$(cat "$q3" 2>/dev/null); b4=$(cat "$q4" 2>/dev/null)
    b5=$(cat "$q5" 2>/dev/null); b6=$(cat "$q6" 2>/dev/null)
    rm -f "$q1" "$q2" "$q3" "$q4" "$q5" "$q6"
    # 一次超时不等于「这个源答不上来」。ip-api 走明文 HTTP,经隧道偶发挂到 4 秒以上
    # (2026-11-21 实测 curl (28) Operation timed out after 4004 milliseconds,
    #  而同一时刻单发只要 0.12 秒);ipquery 在并发负载下也从 1.1 秒涨到 3.3 秒。
    # 这两家是 src_n 的主要来源,掉一家就会被记成「仅一家风险源可达」+ 封顶 85 ——
    # 明明是我们自己取数抖了一下,却写成了对用户线路的怀疑。空体重试一次,
    # 仍然空才认:真的要判「只有一家源」时,失败是稳定的,重试只是筛掉抖动。
    if ! printf '%s' "$b2" | grep -q '"status"'; then
        b2=$(curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,proxy,hosting,mobile,city,regionName,timezone,countryCode" 2>/dev/null)
    fi
    if ! printf '%s' "$b1" | grep -q '"ip"'; then
        b1=$(curl -sL --max-time 6 -H "User-Agent: $PURITY_UA" "https://api.ipquery.io/$ip" 2>/dev/null)
    fi
    # widget 是多行缩进 JSON,scamalytics 是 HTML 夹 JSON;_ipfield 按「一行里的
    # "key":value」找,多行会漏。压平成单行再喂给它,省得为两个字段引入 jq/python。
    b5=$(printf '%s' "$b5" | tr -d '\n \t')
    b6=$(printf '%s' "$b6" | tr -d '\n \t')
    # PTR 走本地解析器,不占网络预算。去掉结尾的点,便于按关键词匹配。
    # dig 超时/解析失败时会把诊断行「;; connection timed out; ...」写到 **stdout**,
    # +short 也挡不住。它曾一路混进 PTR:既让 known=1(等于拿一条报错当「这个 IP
    # 存在」的证据,在零个数据源可达时照样出分),又被当成运营商名拼进检查项 ——
    # 用户看到的就是「评分 60/100 · 机房 · ;; connection timed out;」。诊断行
    # 一律以 ;; 开头,先丢掉再取第一条真 PTR;sed 而不是 grep,免得空结果带出非零码。
    rdns=$(dig +short -x "$ip" +time=2 +tries=1 2>/dev/null \
           | sed -e '/^;;/d' -e '/^[[:space:]]*$/d' | head -1 | sed 's/\.$//')

    local dc="" mob="" px="" tor="" risk="" tzip="" abfreq="" cc=""
    # 代理特征按「几个独立源报出来」计数:ipquery(is_vpn/is_proxy)算一个源
    # (同一家不会自己反驳自己)、ip-api(proxy)算第二个、PTR 自曝算第三个、
    # widget 的 privacy.vpn/proxy 算第四个。计数是为了区分两种情况:多源一致的
    # 代理特征,和「只有一家说它是代理,另外几家都说这是机房」—— 后者实测会让
    # 同一个节点的不同 IP 得到一个 fail 一个 warn,用户看到的是一台机器换个
    # IP 结论就翻脸。
    local px_q="" px_a="" px_r="" px_w="" px_src=0
    case "$(_ipfield "$b1" is_vpn)" in true) px_q=1 ;; esac
    case "$(_ipfield "$b1" is_mobile)" in true) mob=1 ;; esac
    case "$(_ipfield "$b1" is_proxy)" in true) px_q=1 ;; esac
    case "$(_ipfield "$b1" is_tor)" in true) tor=1 ;; esac
    risk=$(_ipfield "$b1" risk_score)
    tzip=$(_ipfield "$b1" timezone)
    # 机房证据同样多源都收:ipquery 说 datacenter、ip-api 说 hosting、widget 的
    # privacy.hosting / is_hosting 任一成立即算 —— ipinfo 的隐私库是独立维护的,
    # 它说 hosting 时不再依赖我们拿运营商名去猜。
    case "$(_ipfield "$b1" is_datacenter)" in true) dc=1 ;; esac
    case "$(_ipfield "$b2" proxy)" in true) px_a=1 ;; esac
    case "$(_ipfield "$b2" hosting)" in true) dc=1 ;; esac
    case "$(_ipfield "$b2" mobile)" in true) mob=1 ;; esac
    # widget(q5):压平后的 JSON,privacy 四布尔与 asn/company 的 type 是关键字段。
    # asn.type=isp 是**正面 ISP 线路证据** —— 它来自 ipinfo 自己的 ASN 分类库,
    # 不靠我们在名字里找关键词。实测 GTT(AS3257):名字里没有 hosting/server 词,
    # 旧口径落进「无正面住宅证据」封顶 70;widget 明确说 asn.type=isp。
    local wi_asn_type="" wi_comp_type=""
    wi_asn_type=$(printf '%s' "$b5" | grep -o '"asn":{[^{]*' | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
    wi_comp_type=$(printf '%s' "$b5" | grep -o '"company":{[^{]*' | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)

    # ---- 类型证据按 IP 落盘 24h ----
    # asn.type / company.type 是 ASN 的固有分类,只有 ipinfo 一家能给,而 /json 与
    # widget 共用同一份免费额度:它一限流,两个端点同时哑。2026-11-21 实测就撞上了——
    # org-cache 里 GTT 的记录刚过 24h,回源吃 429,于是「运营商名」和「类型证据」
    # 一起消失,界面从 16 项通过掉到 13 项,而两个源(ipquery/ip-api)明明都通着。
    # 刚查到过的证据不该因为下一次没问到就作废,所以单独存一份,与 org 同构。
    local live_asn="$wi_asn_type" live_comp="$wi_comp_type"
    local tnow tcip tasn tcomp tts ttmp
    # ipinfo 限流时两个端点的样子不一样:/json 回 {"status":429},widget 回纯文本
    # Too Many Requests。认出来是为了让文案说实话 —— 见 score_label 与 next。
    local type_src_down=""
    printf '%s' "$b3" | grep -q '"status"[[:space:]]*:[[:space:]]*429' && type_src_down=1
    printf '%s' "$b5" | grep -qi 'too many requests' && type_src_down=1
    tnow=$(date +%s)
    if [ -n "${BASE:-}" ] && [ -f "$BASE/type-cache" ]; then
        while IFS=$(printf '\t') read -r tcip tasn tcomp tts; do
            [ "$tcip" = "$ip" ] || continue
            case "${tts:-}" in ''|*[!0-9]*) continue ;; esac
            [ $((tnow - tts)) -lt "$TYPE_CACHE_TTL" ] || break
            # 空字段写成「-」(见下面的写回):tab 属于 IFS 空白类,read 会把连续的
            # IFS 空白**合并成一个分隔符** —— 「ip<TAB>isp<TAB><TAB>ts」读回来是
            # 三段,时间戳落到 company 位、tts 为空,整行被当成无效记录跳过。
            # 实测 asn.type=isp 而 company.type 为空时,缓存写了等于没写。
            [ -z "$wi_asn_type" ] && [ "${tasn:-}" != "-" ] && wi_asn_type="${tasn:-}"
            [ -z "$wi_comp_type" ] && [ "${tcomp:-}" != "-" ] && wi_comp_type="${tcomp:-}"
            break
        done < "$BASE/type-cache"
    fi
    # 只有本次真的问到了才写回。否则「429 → 读盘 → 原样写回」会把一条旧证据
    # 无限续命,从此再也不用向 ipinfo 求证 —— 那就是拿缓存冒充实时结论。
    if [ -n "${BASE:-}" ] && { [ -n "$live_asn" ] || [ -n "$live_comp" ]; }; then
        ttmp="$BASE/type-cache.$$"
        # 空字段落成「-」而不是空串,理由见上面读回那里的注释。
        { grep -vF "$ip"$'\t' "$BASE/type-cache" 2>/dev/null
          printf '%s\t%s\t%s\t%s\n' "$ip" "${wi_asn_type:--}" "${wi_comp_type:--}" "$tnow"; } \
            2>/dev/null | tail -40 > "$ttmp" && mv "$ttmp" "$BASE/type-cache" 2>/dev/null
    fi
    # privacy.* 直接并进对应证据位:vpn/proxy/tor 是代理类证据(px_w),hosting 是
    # 机房证据(dc)。widget 是权威源,它说 true 时不需要第二家印证(px_w 直接
    # 计入 px_strong 的依据)。relay 与 is_anonymous 不在此列:iCloud 中继这类
    # 匿名通道不是恶意代理,拿它拦启动太重,只挂标记(见 flags 区)。
    case "$(_ipfield "$b5" vpn)" in true) px_w=1 ;; esac
    case "$(_ipfield "$b5" proxy)" in true) px_w=1 ;; esac
    case "$(_ipfield "$b5" tor)" in true) tor=1; px_w=1 ;; esac
    # privacy.hosting 单独记一份:它由 ipinfo 的隐私库直接给出,比 ipquery/ip-api 的
    # 通用 datacenter 布尔更具体 —— 判「住宅拨号」时要区分「谁在说机房」(见 relay)。
    local wi_priv_hosting=""
    case "$(_ipfield "$b5" hosting)" in true) dc=1; wi_priv_hosting=1 ;; esac
    case "$(_ipfield "$b5" is_hosting)" in true) dc=1; wi_priv_hosting=1 ;; esac
    case "$(_ipfield "$b5" is_mobile)" in true) mob=1 ;; esac
    local wi_relay="" wi_anon=""
    case "$(_ipfield "$b5" relay)" in true) wi_relay=1 ;; esac
    case "$(_ipfield "$b5" is_anonymous)" in true) wi_anon=1 ;; esac
    # scamalytics(q6):只取欺诈分与等级做展示口径,不参与类型与扣分 ——
    # 它与 risk/滥用记录高度相关,并入会双计。
    local sca_score="" sca_risk=""
    sca_score=$(_ipfield "$b6" score)
    sca_risk=$(_ipfield "$b6" risk)
    case "$sca_score" in ''|*[!0-9]*) sca_score="" ;; esac
    abfreq=$(_ipfield "$b4" frequency)
    # 国家代码只从已经在手的三份响应里取,不为它多发一次请求。离线给候选节点
    # 排名时,这一列是硬性门槛(COUNTRY_TARGET)的唯一依据:一个再干净的英国
    # 节点也不能排到美国前面去。取不到就留空,由调用方标「国家待验证」。
    cc=$(_ipfield "$b2" countryCode)
    [ -z "$cc" ] && cc=$(_ipfield "$b1" country_code)
    [ -z "$cc" ] && cc=$(_ipfield "$b3" country)
    cc=$(printf '%s' "$cc" | tr 'a-z' 'A-Z' | tr -cd 'A-Z')

    # PTR 自曝的特征。这一条比任何第三方评分都硬:出口自己把身份写进了反向解析。
    case "$rdns" in
        *tor-exit*|*tor-relay*|*torexit*|*.exit.*) tor=1 ;;
    esac
    case "$rdns" in
        *vpn*|*openvpn*|*wireguard*|*proxy*) px_r=1 ;;
    esac
    [ -n "$px_q" ] && px_src=$((px_src+1))
    [ -n "$px_a" ] && px_src=$((px_src+1))
    [ -n "$px_r" ] && px_src=$((px_src+1))
    [ -n "$px_w" ] && px_src=$((px_src+1))
    [ "$px_src" -ge 1 ] && px=1

    # 两件事必须分开判,混成一件就会在两侧各错一次:
    #   ① 数据源「认识」这个地址吗 —— 有的源对不存在的网段不报错,而是回一份结构完整、
    #      标志全 false、risk_score 为 0 的空壳(实测 ipquery 对 192.0.2.55 就是这样,
    #      ip-api 则老实回 status:fail「reserved range」)。空壳读起来和「住宅且毫无风险」
    #      一模一样,分不开,一个查错的地址就会拿到 100 分 —— 那是最糟的假绿。
    #   ② 我们手上有几个风险信号 —— 认识地址 ≠ 拿到了代理/滥用证据。
    #      两个风险源全挂时(实测 ipquery 与 ip-api 会同时连不上),仍可以靠 ipinfo 的
    #      运营商名把类型判出来,但分数不能报满分:那是拿「没查」冒充「查干净了」。
    #      也不能就此拦启动 —— 拿我们自己的网络抖动去堵用户,是拿误报换安全感。
    local known="" src_n=0 org3=""
    if printf '%s' "$b1" | grep -q '"org"[[:space:]]*:[[:space:]]*"[^"]' \
       || printf '%s' "$b1" | grep -q '"isp"[[:space:]]*:[[:space:]]*"[^"]'; then
        known=1; src_n=$((src_n+1))
    fi
    [ "$(_ipfield "$b2" status)" = "success" ] && { known=1; src_n=$((src_n+1)); }
    # widget 的 privacy 块是完整的风险信号组(五个布尔),它答上来了就和一个
    # 风险源等价 —— 挂了的时候类型与隐私两个维度同时缺证据,不能当没这回事。
    printf '%s' "$b5" | grep -q '"privacy"' && { known=1; src_n=$((src_n+1)); }
    # ipinfo 只说「这个地址有主」,它一个风险标志都不给,所以只参与 ①、不参与 ②。
    org3=$(printf '%s' "$b3" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$org3" ] && known=1
    # PTR 能解出来,本身就证明这个地址存在且有人给它起过名字 —— 而且反向解析常常
    # 直接写着出口类型(hsd1 / static / tor-exit)。三家 HTTP 源全挂时,它是最后一根
    # 可用的线索,不能因为「不在那四份响应里」就当作没有。
    [ -n "$rdns" ] && known=1
    if [ -z "$known" ]; then
        printf '|unknown||未取到该出口的信誉数据,本次未评级|'
        return 0
    fi
    # 一家风险源都没答上来:进入降级判型,结论只能给到类型这一层。
    local degraded=""
    [ "$src_n" = "0" ] && degraded=1

    # 代理特征够不够「硬」。三条路都算硬:
    #   · 两家以上独立源都报了(互相印证);
    #   · ipquery 自己报了 is_vpn/is_proxy —— 它是我们对齐的那家源,报错代价低;
    #   · 没有任何机房证据兜底 —— 那时单源代理特征也没有别的解释。
    # 只有「单源 ip-api + 多源都说机房」这一种落进冲突区:实测 AS14956 的三个
    # 出口,ipquery 三份响应完全一致(机房、risk 85、is_proxy:false),只有其中
    # 一个 IP 被 ip-api 标了 proxy:true,于是同一台机器换 IP 就从 warn 变成 fail
    # 拦启动。这种冲突按机房处理并留标记,不按代理一票否决。
    local px_strong="" px_conflict=""
    if [ -n "$px" ]; then
        if [ "$px_src" -ge 2 ] || [ -n "$px_q" ] || [ -n "$px_w" ]; then
            px_strong=1
        elif [ -z "$dc" ] || [ "$src_n" -lt 2 ]; then
            px_strong=1
        else
            px_conflict=1
        fi
    fi

    # 类型判定。顺序即优先级:Tor > 代理/VPN > 机房 > 移动 > 住宅。
    # 低优先级不许覆盖高优先级 —— Tor 出口常常同时被打上 residential 标记
    # (实测 DFRI 那个就是),按顺序判才不会把 Tor 洗成「住宅宽带」。
    # ASN 运营商名优先用已经拿到的 ipinfo 响应(q3),不要再去调 ip_org ——
    # 那会为同一个字段多发一次 ipinfo 请求。
    # ipinfo 免费额度被打满时会回 429(实测连续查询就会,共享出口更容易),此时
    # ip_org 也会跟着空 —— 于是类型退化成「不明」、70 分、warn,给一个真实的
    # Comcast 用户报「建议换住宅或原生 IP」,是彻底的误导。所以中间插一层:
    # ipquery 的响应里本来就带着运营商名,零成本,先拿它顶上。
    local asn_org asn_kind type="unknown" resid_hint="" host_hint=""
    asn_org="$org3"
    [ -z "$asn_org" ] && asn_org=$(printf '%s' "$b1" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$asn_org" ] && asn_org=$(ip_org "$ip")
    asn_kind=$(ip_class "$asn_org")
    case "$rdns" in
        *hsd*|*dynamic*|*dhcp*|*broadband*|*adsl*|*ppp*|*dial*|*dsl*|*fiber*|*cable*) resid_hint=1 ;;
    esac
    case "$rdns" in
        *cloud*|*vps*|*dedicated*|*server*|*hosting*|*datacenter*|*datacentre*|*colo*) host_hint=1 ;;
    esac
    # 单独一个 static 不再算机房特征。家宽开静态 IP 的 PTR 到处都是
    # `static-1-2-3-4.isp.example.net` 这种写法,拿它判机房等于给静态家宽扣帽子;
    # 真正的机房主机名几乎都同时带 cloud/vps/server/dedicated 这类词(见上一条)。
    # 名字不在住宅白名单、但两家风险源都明确答「不是机房/不是托管」时,
    # 不能按名字把人钉成机房:实测 GTT(AS3257)三份响应写着 is_datacenter:false /
    # hosting:false / risk_score:0,界面却报「机房 · 建议换住宅 IP」。
    # 这里先记一笔「名字说的和证据相反」,交给下面的类型判定去给 unknown。
    local name_only_host=""
    if [ -z "$dc" ] && [ -z "$host_hint" ] && [ "$asn_kind" = "hosting" ] \
       && [ "$src_n" -ge 2 ]; then
        name_only_host=1
    fi
    # 「民用宽带」也要正面证据,不能靠「没查到问题」默认放行:
    #   两家风险源都答了(src_n>=2) + 有运营商名 + 所有风险标志全否 + 运营商名里没有机房词。
    # **信誉维度(risk_score / 滥用记录)故意不参与类型判定。** 它们曾经参与过:
    # 条件里写着「risk≤10 且无滥用」,于是同一个出口 risk_score 从 10 变 11 时,
    # 类型从「住宅宽带」翻成「类型不明」,分数 67→63,还多挂一句「建议换住宅」——
    # 一个 1 分的抖动改了三处结论,用户看到的是「同一个 ISP 换了个说法」。
    # 类型回答的是「这是什么线路」,信誉回答的是「这条线脏不脏」;混进同一个 if
    # 就会互相冒充:脏一点被当成线路变了,线路不明又被当成脏。
    # 「住宅/ISP 线路」从 2026-11-21 起要**正面证据**,不再接受隐式推断。
    # 旧口径是「src_n>=2 且没有任何风险标志且运营商名不含机房词」就算住宅 ——
    # GTT(AS3257)靠它拿到「住宅宽带」标签,再被「无正面住宅证据」封顶 70,
    # 一个出口两次被同一套猜测摆布。widget 的 asn.type/company.type=isp 是
    # ipinfo 自己的 ASN 分类库给的判断(实测 GTT = isp),PTR 自曝家宽特征
    # (hsd/dhcp/dsl…)与白名单命中仍是正面证据;三者皆无时老老实实给
    # 「类型不明」(基线 70,同档 warn),不再冒充住宅。
    local pos_residential=""
    if [ "$wi_asn_type" = "isp" ] || [ "$wi_comp_type" = "isp" ] \
       || [ -n "$resid_hint" ] || [ "$asn_kind" = "residential" ]; then
        pos_residential=1
    fi
    # ---- 住宅拨号线路(relay):类型库说是运营商线路,却有源把它标成机房 ----
    # 这是机场「住宅 IP 池」的典型形态,两个成熟实现都单独给了它一档:
    #   xykt/IPQuality(ip.sh)同样取 widget 的 asn.type 做类型;
    #   sinspired/checkip(pkg/ipinfo/isp.go:134)写得很明确 ——
    #     case companyType == "hosting" && asnType == "isp": 住宅拨号
    #   并在注释里点明:hosting 只是笼统的兜底信号,不该抢在类型库之前命中。
    # 我们原来把 dc 布尔排在住宅之前,于是这类出口一律报「机房 · 建议换住宅」,
    # 而它其实是运营商线路下的住宅拨号出口 —— 这是「评分不对」里最实的一处误判。
    #
    # 只认类型库(asn.type=isp)说话的两条路径:
    #   a. company.type=hosting 且 asn.type=isp —— ipinfo 自己在两个维度上打架;
    #   b. asn.type=isp 且有通用机房布尔(ipquery/ip-api),但没有任何更强的反证。
    # 反证有三条,任一成立仍判机房:PTR 自曝 cloud/vps(host_hint)、widget 隐私库
    # 直接说 hosting(wi_priv_hosting)、运营商名本身命中机房词(asn_kind=hosting)。
    # PTR 与隐私库是逐 IP 的实测,比「通用 datacenter 布尔」硬,不能被类型库推翻。
    local relay="" relay_conflict=""
    if [ "$asn_kind" != "hosting" ] && [ "$wi_asn_type" = "isp" ]; then
        if [ "$wi_comp_type" = "hosting" ]; then
            relay=1
        elif [ -n "$dc" ] && [ -z "$host_hint" ] && [ -z "$wi_priv_hosting" ]; then
            relay=1; relay_conflict=1
        fi
    fi
    if [ -n "$tor" ]; then
        type=tor
    elif [ -n "$px_strong" ]; then
        type=vpn
    elif [ -n "$relay" ]; then
        type=relay
    elif [ -n "$dc" ] || [ -n "$host_hint" ] \
         || { [ "$asn_kind" = "hosting" ] && [ -z "$name_only_host" ]; }; then
        type=hosting
    elif [ -n "$mob" ]; then
        type=mobile
    elif [ -n "$pos_residential" ]; then
        type=residential
    fi

    # 基线分:取 ip.net.coffee 实测区间的中位数,让两边的数字能直接比。
    # 上一版把 VPN/机房/Tor 的基线抬高了 5~14 分(75/60/50),理由是「别把门焊死」;
    # 但判定本来就不看这几个数(代理和 Tor 直接 fail,机房固定 warn),抬基线只
    # 有一个后果:同一个 IP 我们报 60 分、网站报 55 分,用户以为我们算错了。
    # residential=100:类型现在需要正面证据(asn.type=isp / 白名单 / PTR)才给,
    # 有正面证据的干净 ISP 出口就是满分 —— Scamalytics 对 GTT 的欺诈分是 0,
    # ip.net.coffee 给 98,「无正面住宅证据封顶 70」的自造惩罚已随旧口径删除。
    local base
    case "$type" in
        tor)         base=46 ;;   # 网站实测 43~50
        vpn)         base=65 ;;   # 61~69
        hosting)     base=55 ;;   # 51~58
        # 住宅拨号介于代理与住宅之间:类型库认它是运营商线路,别的源说机房。
        # 取 75 而不是住宅的 100,也不是机房的 55 —— 这类出口通常就是机场的
        # 「住宅 IP 池」,质量比真家宽差、比纯机房好,数字要让这个差别看得见。
        relay)       base=75 ;;
        mobile)      base=85 ;;
        residential) base=100 ;;
        # 类型不明不给满分,也不当机房:70 分落在「良好」档,提示但不拦。
        *)           base=70 ;;
    esac

    local pen=0 riskpen=0 abpen=0 flags=""
    # 1) 第三方风险分:**连续扣分**,每 5 分风险约 1 分信誉分,60 分以上封顶 12。
    #    上一版是四档阶梯(1-10→3、11-25→7、26-50→9、≥51→12),坏处有两个:
    #    ① 同档内不可分辨 —— risk 1 和 10 同分、11 和 25 同分,数字看着精确其实
    #       只表达「在第几档」;② 档口会跳 —— risk 10→11 一次掉 4 分。
    #    实测把所有可能取值枚举出来只有 36 个可达分值,101 个整数里过半取不到。
    #    连续化后可达分值 69 个,32~100 每一个整数都取得到,曲线单调。
    case "${risk:-}" in
        ''|*[!0-9]*) ;;
        *) riskpen=$(( (risk * 12 + 30) / 60 ))    # 5→1 · 10→2 · 25→5 · 50→10 · 60+→12
           [ "$riskpen" -gt 12 ] && riskpen=12 ;;
    esac
    # 2) 滥用记录(stopforumspam)。实测住宅与正常机房都是 0,只有 Tor/VPN 段会命中,
    #    所以这一条几乎不会误伤 —— 命中就是真的被拿去刷过。同样连续:1 次就罚 5 分,
    #    之后按频次缓慢加码,45 次以上封顶 14。原来的 1-10→5 / 11-50→9 是阶梯,
    #    第 10 次和第 11 次之间凭空掉 4 分,没有对应的现实差异。
    case "${abfreq:-}" in
        ''|*[!0-9]*|0) ;;
        *) abpen=$(( 5 + abfreq / 5 ))
           [ "$abpen" -gt 14 ] && abpen=14
           flags="$flags ·滥用记录" ;;
    esac
    # 两个都是「历史信誉」信号,而且高度相关:Tor 出口的 risk_score 天然高、
    # 也天然被拿去刷过。相加等于同一个事实罚两次,取较大者即可。
    pen=$riskpen
    [ "$abpen" -gt "$pen" ] && pen=$abpen

    # 3) 地理一致性:三个源说了几个不同的城市?≥2 个就说明这个 IP 的地理归属本身是模糊的。
    #    实测 RouterHosting 那段 ipquery/ipinfo 报犹他、ip-api 报内华达,跨了州 ——
    #    这种情况下拿任何一个源的时区去要求用户对齐都是在冤枉人。所以只标「地理模糊」
    #    小幅扣分,不再按「时区不符」处理。只有三源一致时才比较时区。
    #    这一维只对「机房/移动/类型不明」成立:它们的出口城市是固定的基础设施位置。
    #    住宅跳过 —— 家宽的注册地与实际接入地本来就会不同(跨州搬迁、运营商池化),
    #    那既不是风险,也不该拿它去要求用户对齐;而且实测 net.coffee 对住宅一律给 100。
    #    Tor 与代理也跳过 —— 它们的「城市」本来就是数据中心位置,三个源按各自的出口点
    #    库去标必然互相不一致(实测两个随机 Tor 出口全部命中「地理模糊」),给它们挂这个
    #    标记是纯噪声:类型罚分已经说明问题了。同理「系统时区与出口不一致」另有「时区」
    #    那一项在管,这里再罚一次是重复计费。
    local c1 c2 c3 ncities
    c1=$(_ipfield "$b1" city); c2=$(_ipfield "$b2" city); c3=$(_ipfield "$b3" city)
    ncities=$(printf '%s\n%s\n%s\n' "$c1" "$c2" "$c3" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
    #    这一维只标不改分。原因是它和「时区」检查项、以及出口国家一致性都在说
    #    同一件事,扣一次分等于重复计费(2026-11-06 用户原话:「评分和网站上的不一致」——
    #    ip.net.coffee 的 Trust Score 不含地理维度,我们多扣 4~6 分,两边就没法比)。
    #    标记保留:它是「这次的地理画像本身模糊」的证据,只是不再影响分数。
    case "$type" in
        residential|relay|tor|vpn) ;;   # 这三类的城市不反映用户位置,整段跳过
        *)
            if [ "${ncities:-0}" -ge 2 ]; then
                flags="$flags ·地理模糊"
            elif [ -n "$tzip" ] && [ -n "${TZ_TARGET:-}" ] && [ "$tzip" != "$TZ_TARGET" ]; then
                flags="$flags ·时区不符"
            fi ;;
    esac

    # 证据冲突必须写在脸上:否则用户只知道「这次比上次分低」,不知道是 ip-api
    # 一个布尔在说话。分开标,分类讨论才有依据。widget 的中继/匿名标志只挂
    # 标记不扣分:iCloud 中继不是恶意代理,拦启动太重。
    [ -n "$px_conflict" ] && flags="$flags ·代理特征(单源)"
    # 冲突要写在脸上:否则用户只看到「住宅拨号」,不知道我们手上两份证据在打架。
    [ -n "$relay_conflict" ] && flags="$flags ·机房标志(与类型库冲突)"
    [ -n "$wi_relay" ] && flags="$flags ·中继出口"
    [ -n "$wi_anon" ] && [ -z "$wi_relay" ] && flags="$flags ·匿名特征"
    # scamalytics 欺诈分是展示口径:它和 risk/滥用相关但口径独立(0-100 欺诈分,
    # <20 即低风险),并排给出让用户能和业界工具直接对照。不参与扣分 —— 双计。
    case "$sca_score" in
        ''|*[!0-9]*) ;;
        *) flags="$flags ·欺诈分${sca_score}"
           case "$sca_risk" in
               low)   ;;
               *)     flags="$flags(${sca_risk:-})" ;;
           esac ;;
    esac

    # 限流不能只在分数那一栏暗示:用户看到的是「未评级」,很容易理解成「这个 IP 被判坏了」。
    # 单独挂一个标记,把「我们的取数被挡住了」和「这个出口有问题」区分开。
    # **只在「因此没评出类型」时挂。** ipinfo 的两个端点各自独立限流(实测 /json 429 而
    # widget 通),证据最后拿到了就说明限流没有影响结论 —— 在一条「100 分 · 住宅宽带」
    # 后面再缀「类型源限流」,只会让用户问「到底限没限」。
    # 判据用 $type 不用 $score:type 在上面就定了,score 要到这里之后才算得出
    # (在它声明之前引用,set -u 会直接杀掉整个子 shell,静默返回空结果)。
    [ -n "$type_src_down" ] && [ "$type" = "unknown" ] && flags="$flags ·类型源限流"
    # 降级判型时分数封顶 70。70 是本模型里「类型不明」的基线,含义正是「看着还行
    # 但没拿到证据」;带着一个没验证过的出口报 100 分,等于用「没查」冒充「查干净了」。
    # 这里不再叠任何扣分:风险分、滥用频次都取不到,地理也只剩一个源,没有可罚的依据。
    if [ -n "$degraded" ] && [ "$base" -gt 70 ]; then
        base=70
    fi

    local score=""
    if [ "$type" != "unknown" ]; then
        # 类型不明时不产数字:**没有任何正面证据的 70 是拍出来的基线,不是量出来的分**。
        # 放一个看起来精确的猜测分数,比明说「未评级」更有害 —— 用户会拿它跟
        # ip.net.coffee 的实测分对比,发现对不上只会以为我们算错了。
        # 判定不受影响:unknown 的基线 70 减去最大惩罚 14 也到不了 50 分线,
        # 本来就永远是 warn(2026-11-21 实证枚举),删数字不改变任何门禁行为。
        score=$((base - pen))
        [ "$score" -lt 0 ] && score=0
    fi

    # 「没查」不等于「查干净了」,这一条以前是**直接跳过扣分**:风险维度取不到值,
    # 罚分自然是 0,于是一个 ipquery 超时的白名单出口照样拿 100/ok —— 和两家源都
    # 验过的 100 一模一样,只在行尾挂一个小标记。实测(ipquery 空 + ip-api 正常 +
    # ipinfo 报 Comcast):`100|ok|住宅宽带|…仅一家风险源可达`,是最难发现的那种假绿。
    # 现在改成封顶 85 且判定最多到 warn:分数表达「现有证据支持到这里」,不表达满分。
    local risk_known=""
    case "${risk:-}" in ''|*[!0-9]*) ;; *) risk_known=1 ;; esac
    local unverified=""
    if [ -z "$risk_known" ] || [ "$src_n" -lt 2 ] || [ -n "$degraded" ]; then
        unverified=1
        # 空分数(类型不明)没有可封顶的数字,标记与判定降档照常生效。
        [ -n "$score" ] && [ "$score" -gt 85 ] && score=85
    fi

    # 判定比分数严:分数是 IP 信誉(宽口径),判定回答的是「能不能拿它开 Claude」。
    # 但机房要单独定档:它的分数天然比住宅低一档,按分数卡在 50 分线上,会让一个
    # 51 分和 49 分的机房段得到相反结论 —— 实测 RouterHosting 正好卡在 49,
    # 而大量用户就是在用机房节点,一票否决等于把门焊死。所以机房固定 warn,
    # 只有「机房 + 有滥用记录」这种转租段(分数掉到 30 以下)才拦。
    local verdict
    if [ -n "$tor" ] || [ -n "$px_strong" ]; then
        verdict=fail
    elif [ -z "$score" ]; then
        # 类型不明:没有量出来的分数,判定封顶在提示档。基线 70 减最大惩罚
        # 本来就到不了 50 分线(见 score 处的注释),行为与旧口径完全一致。
        verdict=warn
    elif [ -n "$degraded" ]; then
        # 降级判型:类型之外的东西一概没验证,判定封顶在 warn。
        # 拿我们自己的网络抖动去拦用户启动,是拿误报换安全感。
        verdict=warn
    elif [ "$type" = "relay" ]; then
        # 住宅拨号:证据自己就在打架(类型库说运营商线路、别的源说机房),判定封顶
        # 在提示档。分数照给(基线 75),让用户看到「比机房好、比住宅差」,但这类
        # 线路不该拿到 ok —— 拿一个内部矛盾的证据去放行,比不判更糟。
        verdict=warn
    elif [ "$type" = "hosting" ]; then
        if [ "$score" -ge 30 ]; then verdict=warn; else verdict=fail; fi
    elif [ "$score" -ge 75 ]; then
        verdict=ok
    elif [ "$score" -ge 50 ]; then
        verdict=warn
    else
        verdict=fail
    fi
    # 证据不全的结果不许报 ok:分数可能被算高了(风险维度没验过),给个绿勾等于
    # 替一次没做完的检查背书。封顶 85 已经让分数落在 warn 区间之上,这里再兜一次,
    # 免得以后调阈值时又把它放出来。
    [ -n "$unverified" ] && [ "$verdict" = ok ] && verdict=warn

    local isp="" who tlabel next
    # 冒号两侧可能有空格(不同源的 JSON 排版不一样),所以不能写死 "isp":"。
    # 外层还有一个同名 key(isp 对象本身),它后面跟的是 {,这里的引号要求正好把它排除。
    isp=$(printf '%s' "$b1" | grep -o '"isp"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    # 降级判型时 ipquery 是空的,isp 自然取不到;退到 ASN 运营商名。
    # 否则用户会看到一行「评分 70/100 · 住宅宽带 · 未知运营商」——分数、类型、运营商
    # 三处里有两处是空的,而我们其实知道它叫什么。
    [ -z "$isp" ] && isp="$asn_org"
    [ -z "$isp" ] && isp="$rdns"
    who=$(printf '%s' "${isp:-未知运营商}" | cut -c1-24)
    case "$type" in
        tor)         tlabel="Tor 出口" ;;
        vpn)         tlabel="代理/VPN" ;;
        hosting)     tlabel="机房" ;;
        relay)       tlabel="住宅拨号线路" ;;
        mobile)      tlabel="移动网络" ;;
        residential) tlabel="住宅宽带" ;;
        *)           tlabel="类型不明" ;;
    esac
    case "$type" in
        tor)     next="Tor 会被 Claude 直接标记,换普通住宅节点" ;;
        vpn)     next="代理特征明显,换住宅或原生 IP 节点" ;;
        hosting) next="机房出口风险偏高,建议换住宅 IP" ;;
        # 住宅拨号本身就是运营商线路,劝人「换住宅」是废话;也不劝「换机房」——
        # 那是把用户往更差的一档推。只在证据冲突时提示一句「可复核」。
        relay)   if [ -n "$relay_conflict" ]; then
                     next="类型库与机房标志冲突,可点重新检查复核"
                 else
                     next=""
                 fi ;;
        # 已经判成住宅还劝人「换住宅」是自相矛盾的。这一档的 warn 只来自证据不全
        # (单源/无正面证据),不是换节点能解决的事,所以不给动作建议。
        residential) next="" ;;
        *)       case "$verdict" in
                     ok)   next="" ;;
                     # 类型源限流时我们手上没有任何「它不适合」的证据,劝人换节点
                     # 等于拿自己的取数失败去指控用户的出口 —— 一个干净的 GTT 出口
                     # 会被劝去换「住宅或原生 IP」,而这恰恰是它本来就属于的那一类。
                     warn) if [ -n "$type_src_down" ]; then
                               next="ipinfo 类型库限流(429),点重新检查可重算"
                           else
                               next="建议换住宅或原生 IP"
                           fi ;;
                     *)    next="换住宅节点后再试" ;;
                 esac ;;
    esac
    if [ -n "$degraded" ]; then
        # 分数只反映「按运营商名判出来的类型」,风险维度一个都没验证过,所以不给
        # 「换节点」这类需要证据的建议 —— 否则一个真实的住宅用户会被劝去换住宅 IP。
        # 只说清发生了什么、下一步做什么。
        flags="$flags ·风险源不可达"
        next="仅按运营商名或反向解析判型,点重新检查可重算"
    elif [ "$src_n" = "1" ]; then
        # 双源交叉退化成单源:代理特征可能被漏判(实测 WARP 只有 ip-api 报 proxy:true,
        # ipquery 只报 datacenter)。分数照算,但必须让用户知道这次的证据是不全的。
        flags="$flags ·仅一家风险源可达"
    elif [ -n "$unverified" ]; then
        # 两家源都在,但 ipquery 的 risk 字段是空的 —— 风险维度没值可罚,
        # 而这正好是最容易被当成「0 风险」的形态。
        flags="$flags ·风险未验证"
    fi
    # 降级时 score 只是「按运营商名/PTR 推出的类型基线」,风险维度一个都没验证过。
    # 不加标记地报「评分 60/100」,用户会当成实测信誉分,而这个数还会在缓存里
    # 反复出现五分钟。保留「评分 N/100」前缀(下游与测试都按它取数),补上口径。
    local score_label
    if [ -z "$score" ]; then
        # 「我们被限流」和「这个 IP 的类型确实判不出来」是两件事,不能共用一句话:
        # 前者是我们手上少一份证据,后者是对这个出口下的结论。
        if [ -n "$type_src_down" ]; then
            score_label="未评级(ipinfo 限流)"
        else
            score_label="未评级(类型证据缺失)"
        fi
    elif [ -n "$degraded" ]; then
        score_label="评分 ${score}/100(类型预估·未实测信誉)"
    elif [ -n "$unverified" ]; then
        score_label="评分 ${score}/100(风险未验证·封顶)"
    else
        score_label="评分 ${score}/100"
    fi
    # 判定词单独写出来。分数是信誉分(宽口径),判定是「这次能不能开」,
    # 两者不是同一个轴 —— 实测用户会拿「这个 53 分、那个 43 分」反推「53 更安全」,
    # 而 53 那个其实是 fail。不写清楚,分数越精确越误导。
    local vlabel=""
    case "$verdict" in
        fail) vlabel="判定:拦启动" ;;
        warn) vlabel="判定:仅提示" ;;
    esac
    local detail="${score_label} · ${tlabel} · ${who}${flags}${vlabel:+ · $vlabel}${next:+ · $next}"

    # 结论一律按 24h 缓存,不再按「证据齐不齐」分两种过期时间。
    # 那套提前过期正是后台重查的发动机:它把一个「这次没查全」的观察
    # 变成了「每 N 分钟必须再问一次」的定时任务,而问的那一方是每分钟
    # 都在跑 check 的巡检,不是人。证据不齐只影响**文案与封顶**(见上),
    # 不该影响一条缓存能活多久。要新的,就由 checkdetail 显式传 force 来要。
    local cache_epoch="$now" lock="$BASE/.purity-cache.lock" got=0 i owner tmp
    if [ -n "${BASE:-}" ] && [ -d "$BASE" ]; then
        # 节点扫描会并发给多个 IP 打分,每个后台子 shell 都会落缓存;不锁的话
        # 两份 grep -v 会各自读同一份旧文件,后写的那份把先写的结果抹掉。
        # 锁目录里记下创建时间:进程被 kill / 断电会留下一把空锁,之后 5 次 mkdir
        # 全失败、缓存再也写不进去。本机实测 11-04 06:34 留下这样一把锁,之后
        # 23 小时每次检查都重新打四个网络请求,分数随网络抖动上下飘 —— 这正是
        # 「出口 IP 评分不对」的第二个来源。超过 60 秒的锁一律回收。
        for i in 1 2 3 4 5; do
            if mkdir "$lock" 2>/dev/null; then
                printf '%s' "$now" > "$lock/owner" 2>/dev/null
                got=1; break
            fi
            owner=$(cat "$lock/owner" 2>/dev/null)
            case "$owner" in ''|*[!0-9]*) owner=0 ;; esac
            if [ $((now - owner)) -gt 60 ]; then
                rm -f "$lock/owner" 2>/dev/null
                rmdir "$lock" 2>/dev/null
            fi
            sleep 1
        done
        # 即使极端情况下没抢到锁也要落盘:少一行缓存只是多查一次,静默丢掉
        # 本次结果会让「证据不全就提前重查」「24h 复用」整套口径全部失效。
        tmp="$BASE/purity-cache.v12.$$"
        { grep -vF "$ip|" "$BASE/purity-cache.v12" 2>/dev/null
          printf '%s|%s|%s|%s|%s|%s|%s\n' \
              "$ip" "$cache_epoch" "$verdict" "$score" "$type" "$detail" "$cc"
        } | tail -20 > "$tmp" 2>/dev/null \
            && mv "$tmp" "$BASE/purity-cache.v12" 2>/dev/null \
            || rm -f "$tmp" 2>/dev/null
        if [ "$got" = 1 ]; then
            rm -f "$lock/owner" 2>/dev/null
            rmdir "$lock" 2>/dev/null
        fi
    fi
    printf '%s|%s|%s|%s|%s' "$score" "$verdict" "$type" "$detail" "$cc"
}


# 当前实例标识:槽位 A-D。读不到时退回空串(老安装、测试夹具走这条路),
# 沿用旧的单份历史文件 —— 宁可少一层隔离,也不能让老记录直接读不出来。
current_instance() {
    local f="$BASE/current" s
    [ -r "$f" ] || return 0
    s=$(tr -d '[:space:]' < "$f" 2>/dev/null)
    case "$s" in [A-D]) printf '%s' "$s" ;; esac
}

# 固定出口(基线)。判定只看「现在用的出口是否等于这条基线」,
# 不再数「窗口里出现过几个出口」—— 后者会把「跳到别处、被熔断、又切回原出口」
# 这种已经纠正过的事记成一次风险,而用户真正关心的是:现在用的是不是那个固定 IP。
ip_baseline_file() {
    local inst
    inst=$(current_instance)
    if [ -n "$inst" ]; then printf '%s/ipbaseline-%s' "$BASE" "$inst"
    else printf '%s/ipbaseline' "$BASE"; fi
}

# 基线文件一行两列:身份 + 确立时间(epoch)。
# 时间不是装饰 —— 不一致时要能说「基线已固定 3 天」,否则用户没法判断
# 是「刚跳过去忘了切回」还是「这条实例本来就换了出口」。
ip_baseline_line() {
    local f
    f=$(ip_baseline_file)
    [ -r "$f" ] && head -1 "$f" 2>/dev/null
}

ip_baseline_get() {
    local line
    line=$(ip_baseline_line)
    printf '%s' "${line%% *}"
}

ip_baseline_since() {
    local line
    line=$(ip_baseline_line)
    case "$line" in *' '*) printf '%s' "${line#* }" ;; esac
}

# 基线固定了多久。旧格式(只有身份、没有时间)回「时间未知」,不编造。
ip_baseline_age() {
    local since now d
    since=$(ip_baseline_since)
    case "$since" in ''|*[!0-9]*) printf '时间未知'; return 0 ;; esac
    now=$(date +%s)
    d=$(( (now - since) / 86400 ))
    if [ "$d" -ge 1 ]; then printf '%s 天' "$d"; else printf '不到 1 天'; fi
}

# 不一致时的唯一文案来源。check 与 checkdetail 都调它 —— 时区那次就是
# 两边各写一份措辞,改了一边忘了另一边,用户看到的提示互相矛盾。
# 缺省分支的「怎么改回来」必须给命令:只说「不一致」,用户不知道去哪改。
ip_baseline_warn() {
    local cur="$1" base="$2" klass="$3" hint
    case "$klass" in
        residential) hint="家宽轮换概率大,先确认不是节点漂移" ;;
        hosting)     hint="机房出口应固定一个" ;;
        *)           hint="换回固定出口;确属永久更换就运行 claude-switch.sh ip-baseline accept" ;;
    esac
    printf '当前出口与固定基线不一致(当前 %s,基线 %s,基线已固定 %s) · %s' \
        "$(ip_show "$cur")" "$(ip_show "$base")" "$(ip_baseline_age)" "$hint"
}

ip_baseline_set() {
    local f
    [ -n "${1:-}" ] || return 1
    f=$(ip_baseline_file)
    mkdir -p "$BASE" 2>/dev/null || true
    printf '%s %s\n' "$1" "$(date +%s)" >"$f" && chmod 600 "$f" 2>/dev/null
}

# 出口历史按实例分开存。原来 A/B/C/D 共用一份:A 换节点记在 B 头上,
# 反过来 B 的稳定会盖住 A 的漂移 ——「一个实例一周不变」这条根本无从判定。
ip_history_file() {
    local inst
    inst=$(current_instance)
    if [ -n "$inst" ]; then printf '%s/iphistory-%s.log' "$BASE" "$inst"
    else printf '%s/iphistory.log' "$BASE"; fi
}

ip_lastip_file() {
    local inst
    inst=$(current_instance)
    if [ -n "$inst" ]; then printf '%s/lastip-%s' "$BASE" "$inst"
    else printf '%s/lastip' "$BASE"; fi
}

# 升级迁移:旧版只有一份 iphistory.log / lastip。第一次按实例跑时把它们
# 认给当前实例,否则刚升级完「一周内变过」的证据会凭空消失,变成一片绿。
migrate_ip_state() {
    local inst target ltarget
    inst=$(current_instance)
    [ -n "$inst" ] || return 0
    target="$BASE/iphistory-$inst.log"
    if [ ! -f "$target" ] && [ -f "$BASE/iphistory.log" ]; then
        mv "$BASE/iphistory.log" "$target" 2>/dev/null || true
    fi
    ltarget="$BASE/lastip-$inst"
    if [ ! -f "$ltarget" ] && [ -f "$BASE/lastip" ]; then
        mv "$BASE/lastip" "$ltarget" 2>/dev/null || true
    fi
}

# ---------- 出口历史 ----------
# 结论已经不再依赖历史(判据是「现在是不是那条固定基线」),历史只留作证据:
# 万一要回头查「这台机器到底换过几个出口」,得翻得到。
# 所以写入策略从「每次检查都追加 + 每次统计都重写文件」改成「出口变了才追加」:
# 稳态(一周同一个出口)下这里只做一次 tail + awk,不重写、不统计。
# 原来是每次检查都跑三趟 awk/逐行 bash 循环,实测 2000 行 1.3s / 20000 行 13s,
# 而这条信息对当次结论毫无贡献 —— 检查的热路径不该为证据付钱。
iphist_record() {
    local hist last key
    [ -z "$1" ] && return 0
    # 生产路径传进来的是 curkey(已归一),但旧调用点/手工排查会传裸地址。
    # 这里统一归一,历史文件才不会同时存在两种写法 —— 那会让族计数把
    # 同一个出口算成两个。
    key=$(ip_key_migrate "$1") || return 0
    [ -n "$key" ] || return 0
    migrate_ip_state
    hist=$(ip_history_file)
    last=$(tail -1 "$hist" 2>/dev/null | awk '{print $1}')
    [ "$last" = "$key" ] && return 0
    mkdir -p "$BASE" 2>/dev/null || true
    # 变了:追加一行,顺手把窗口外的旧行裁掉(变了才付这一次成本)。
    # 抽取式夹具不带常量,缺省按 7 天算,否则窗口会被当成 0 秒全裁光。
    awk -v cutoff=$(( $(date +%s) - ${IP_STABILITY_WINDOW:-604800} )) '
        $2 + 0 >= cutoff { print }
    ' "$hist" 2>/dev/null > "$hist.tmp" && mv "$hist.tmp" "$hist"
    printf '%s %s\n' "$key" "$(date +%s)" >>"$hist"
    chmod 600 "$hist" 2>/dev/null || true
}

# 只读:7 天窗口里出现过几个不同出口(按协议族取多的那族)。
# 双栈节点 v4/v6 是同一出口的两条腿,混在一起数会把一个节点算成两个。
# 只在「已判定与基线不一致」时才调 —— 那时用户需要知道这是第一次跳还是老在跳。
# 归一仍然要过 ip_key_migrate:升级现场的文件里还留着裸地址。
iphist_count() {
    local hist now n window tmp k
    hist=$(ip_history_file)
    [ -r "$hist" ] || { echo 0; return; }
    window="${IP_STABILITY_WINDOW:-604800}"
    now=$(date +%s)
    tmp="$hist.count.$$"
    awk -v cutoff=$((now - window)) '$2 + 0 >= cutoff {print $1}' "$hist" 2>/dev/null \
        | sort -u >"$tmp"
    : >"$tmp.n"
    # ip_key_migrate 不带换行(它是给命令替换用的),这里必须自己补 ——
    # 否则两行会粘成一行,把两个出口数成一个。
    while read -r k; do
        [ -n "$k" ] && printf '%s\n' "$(ip_key_migrate "$k")" >>"$tmp.n"
    done <"$tmp"
    # 数的是「不同出口」,不是「行数」:跳走再切回来会多两行,但出口只有一个。
    n=$(sort -u "$tmp.n" 2>/dev/null | cut -d: -f1 | sort | uniq -c | sort -rn \
        | head -1 | awk '{print $1}')
    rm -f "$tmp" "$tmp.n"
    echo "${n:-0}"
}


# 上次记录的出口身份,按协议族分开取。v4 与 v6 不可比 —— 拿一个去比另一个,
# 只会得出「IP 变了」,而实际只是这次连接走了另一条腿。
last_seen() {
    local fam="$1" line f
    migrate_ip_state
    f=$(ip_lastip_file)
    [ -f "$f" ] || return 0
    while read -r line || [ -n "$line" ]; do
        line=$(ip_key_migrate "$line")
        case "$line" in "$fam":*) printf '%s' "$line"; return 0 ;; esac
    done < "$f"
}

# 写入本次出口身份,保留另一族的记录(两族各自维护自己的「上次」)。
last_save() {
    local k="$1" fam tmp line cur
    cur=$(ip_lastip_file)
    tmp="$cur.tmp"
    case "$k" in v6:*) fam=v6 ;; *) fam=v4 ;; esac
    : > "$tmp"
    if [ -f "$cur" ]; then
        while read -r line || [ -n "$line" ]; do
            line=$(ip_key_migrate "$line")
            [ -n "$line" ] || continue
            case "$line" in "$fam":*) continue ;; esac
            printf '%s\n' "$line" >> "$tmp"
        done < "$cur"
    fi
    printf '%s\n' "$k" >> "$tmp"
    mv "$tmp" "$cur"
    chmod 600 "$cur" 2>/dev/null || true
}

# ---------- 出口采样 ----------
# 同一出口域名连采多次,只有全部一致才算 ok。两条理由,都是实测踩出来的:
#   1. 单次 curl 空返回会把网络抖动判成「出口IP异常」,进而拦住 Claude 启动;
#   2. 节点在多个出口之间漂移时,单次采样看不出来,而这正是账号画像最怕的状态。
# 结果:ok(全部一致) / unstable(采样间漂移) / unknown(一次都没取到)。
#
# 预算(第 2 个参数,秒)是这个函数存在的另一半理由:curl --max-time 6 × 采样次数
# 在网络半死时会把 check 拖到 30 秒以上,而 App 的检查超时是 45 秒 —— 一旦被吃满,
# 用户看到的是「操作超时」,真实原因只是网络在抖。所以:
#   · 采样间一旦不一致就立刻返回,再采不会让结论变好,只会更慢;
#   · 总耗时封顶在预算内,剩下的时间留给后面的检查项。
# 取不到时会在预算内继续重采,替代原来「整轮再跑一遍」的写法。
PROBE_IP=""; PROBE_LOC=""; PROBE_STATUS="unknown"; PROBE_SEEN=""
# 漂移判定按协议族分开比:同一节点双栈时,v4 与 v6 是两条腿,交替出现不是漂移。
# 原来直接比原始串,双栈节点会被判成「出口在漂移」并拦住启动。
PROBE_IP=""; PROBE_LOC=""; PROBE_STATUS="unknown"; PROBE_SEEN=""
probe_egress() {
    local want="${1:-3}" budget="${2:-10}" start elapsed per trace ip loc n=0 k
    local k4="" k6="" i4="" i6=""
    PROBE_IP=""; PROBE_LOC=""; PROBE_STATUS="unknown"; PROBE_SEEN=""
    # 采样必须跨时间:三次同时发出看到的是同一瞬间,节点正在漂移也看不出来。
    # 所以这里坚持串行 —— 快不是把观测压成一次,而是别让它在主路径上白等。
    start=$(date +%s)
    while [ "$n" -lt "$want" ]; do
        elapsed=$(( $(date +%s) - start ))
        [ "$elapsed" -ge "$budget" ] && break
        # 单次上限 6 秒,但不超过剩余预算 —— 否则最后一次采样会突破总预算。
        per=$(( budget - elapsed )); [ "$per" -gt 6 ] && per=6
        trace=$(curl -s --max-time "$per" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        n=$((n + 1))
        ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
        [ -z "$ip" ] && continue
        loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -1)
        if [ -z "$PROBE_IP" ]; then
            PROBE_IP="$ip"; PROBE_LOC="$loc"
        fi
        # 比的是归一身份,不是原始串:v6 出口可能在同一 /64 内换后缀,
        # 拿原始串比会把「网段没变」误判成漂移,进而拦住启动。
        k=$(ip_key "$ip")
        case "$k" in
            v6:*)
                if [ -n "$k6" ] && [ "$k" != "$k6" ]; then
                    # 同一协议族内换了网段 = 真的在漂移。立刻停:再采只会更慢。
                    PROBE_SEEN="$i6 $ip"; PROBE_STATUS="unstable"; return 1
                fi
                k6="$k"; i6="$ip" ;;
            *)
                if [ -n "$k4" ] && [ "$k" != "$k4" ]; then
                    PROBE_SEEN="$i4 $ip"; PROBE_STATUS="unstable"; return 1
                fi
                k4="$k"; i4="$ip" ;;
        esac
        PROBE_SEEN="${PROBE_SEEN:+$PROBE_SEEN }$ip"
    done
    [ -z "$PROBE_IP" ] && { PROBE_STATUS="unknown"; return 1; }
    PROBE_STATUS="ok"; return 0
}

# 生态可达性探测:两个站点互不依赖,也不依赖出口 IP,所以可以和出口采样同时发,
# 最后再取结果。串行时这段白占 1.3 秒多,而它本来可以完全藏在采样窗口里。
# 结果写成两行:「状态码:首包秒」。取不到就是 000。
ECOLOGY_FILE=""; ECOLOGY_PID=""
ecology_probe_start() {
    ECOLOGY_FILE="${TMPDIR:-/tmp}/claude-eco-$$"
    (
        curl -s --max-time 8 -o /dev/null -w '%{http_code}:%{time_starttransfer}' https://claude.ai/ 2>/dev/null
        printf '\n'
        curl -s --max-time 8 -o /dev/null -w '%{http_code}:%{time_starttransfer}' https://api.anthropic.com/v1/models 2>/dev/null
        printf '\n'
    ) >"$ECOLOGY_FILE" 2>/dev/null &
    ECOLOGY_PID=$!
}
ecology_probe_read() {
    [ -n "${ECOLOGY_PID:-}" ] && wait "$ECOLOGY_PID" 2>/dev/null
    ECO_CODE1=$(sed -n '1p' "$ECOLOGY_FILE" 2>/dev/null)
    ECO_CODE2=$(sed -n '2p' "$ECOLOGY_FILE" 2>/dev/null)
    rm -f "$ECOLOGY_FILE"
    ECOLOGY_FILE=""; ECOLOGY_PID=""
    [ -z "$ECO_CODE1" ] && ECO_CODE1="000:0"
    [ -z "$ECO_CODE2" ] && ECO_CODE2="000:0"
}
ecology_probe_discard() {
    [ -n "${ECOLOGY_PID:-}" ] && wait "$ECOLOGY_PID" 2>/dev/null
    [ -n "${ECOLOGY_FILE:-}" ] && rm -f "$ECOLOGY_FILE"
    ECOLOGY_FILE=""; ECOLOGY_PID=""
}

# 哪些网络服务还开着 IPv6,一行一个。
# 只看 Wi-Fi 是不够的:插网线走 Ethernet、或开着「iPhone USB」共享时,
# IPv6 会从另一条服务溜出去,而检查项照样报「已关闭」—— 最隐蔽的一类漏报。
# 停用中的服务(列表里带 * 前缀)不参与判定:它们不承载流量。
ipv6_on_services() {
    local s
    while IFS= read -r s; do
        case "$s" in ''|'*'*) continue ;; esac
        networksetup -getinfo "$s" 2>/dev/null | grep -i '^IPv6:' | grep -qiv 'Off' && printf '%s\n' "$s"
    done <<< "$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)"
}

# ---------- 安全检查 ----------
check() {
    load_check_config || { echo "FAIL:检查配置无效，请恢复默认设置"; return 1; }
    fails=""
    # 生态探测不依赖出口 IP,先发出去;出口采样串行跑在它前面的这 2 秒,
    # 正好把它的往返吃掉。
    check_disabled "生态可达性" || ecology_probe_start

    proxy_alive || fails="$fails;代理内核未运行($(proxy_name))"
    tun_up || fails="$fails;TUN网卡不在线(在客户端开启 TUN 模式)"

    # 出口采样:3 次一致才算 ok,总预算 10 秒。
    # 原来这里是「采 3 次,全空再整轮采 3 次」,网络半死时最坏 6×6=36 秒,
    # 直接吃掉 App 的 45 秒超时,用户看到的是「操作超时」而不是「网络在抖」。
    # 现在取不到会在同一个预算内继续重采,不必整轮重跑。
    probe_egress 3 10
    ip="$PROBE_IP"; loc="$PROBE_LOC"
    ipwarn=""
    case "$PROBE_STATUS" in
        unstable)
            # 采样间出口不一致 = 节点在漂移,比单点异常更危险:同一账号的来源在变。
            fails="$fails;出口IP在多次采样间漂移(${PROBE_SEEN// /\/})" ;;
        unknown)
            # 取不到 ≠ 出口错。不判 fail(否则网络抖动会拦住启动),但必须显式告知未确认。
            ipwarn="注意:多次采样均未取到出口IP,本次出口未确认" ;;
        *)
            [ "$loc" = "$COUNTRY_TARGET" ] || fails="$fails;出口IP不符(当前 ${ip:-无}/${loc:-未知},期望 $COUNTRY_TARGET)" ;;
    esac
    if ! check_disabled "IP一致"; then
        curkey=""; [ -n "$ip" ] && curkey=$(ip_key "$ip")
        if [ -n "$curkey" ]; then
            lastip=$(last_seen "${curkey%%:*}")
            # 判据是「现在用的出口是否等于这条实例的固定出口」。
            # 不数窗口里出现过几个出口:跳到别处 → 被熔断 → 切回原出口,这条链路里
            # 基线从没变过,用户回来继续用就是正常的,不该背一次「IP 变过」的记录。
            baseline=$(ip_baseline_get)
            if [ -z "$baseline" ]; then
                ip_baseline_set "$curkey"
            elif [ "$curkey" != "$baseline" ]; then
                ipn=$(iphist_count)
                ipwarn="注意:$(ip_baseline_warn "$curkey" "$baseline" "$(ip_class "$(ip_org "$ip")")")"
                # 只有一次跳变和「老在跳」是两件事:前者多半是忘了切回,后者是节点在漂。
                [ "${ipn:-0}" -ge 2 ] && ipwarn="$ipwarn(7 天内见过 $ipn 个出口)"
            fi
            last_save "$curkey"
            iphist_record "$curkey"
        fi
    fi

    # 时区/地区/目标国家缺失是环境层没配好,不是实测不达标 —— 提示语必须分开,
    # 否则用户会拿着「时区异常」去改时区,而真正错的是目标值。
    tz=$(tz_current)
    if [ -z "$TZ_TARGET" ]; then
        fails="$fails;环境未配置(时区目标缺失,点一键修复)"
    elif [ "$tz" != "$TZ_TARGET" ]; then
        fails="$fails;时区不符(当前 ${tz:-未知},期望 $TZ_TARGET)"
    fi

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ -z "$LOCALE_TARGET" ]; then
        fails="$fails;环境未配置(地区目标缺失,点一键修复)"
    elif [ "$locale" != "$LOCALE_TARGET" ]; then
        fails="$fails;地区不符(当前 ${locale:-未知},期望 $LOCALE_TARGET)"
    fi

    v6=$(ipv6_on_services | paste -sd '、' -)
    [ -n "$v6" ] && fails="$fails;IPv6未关闭($v6)"

    if ! check_disabled "DNS"; then
        dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsip" in
            "$FAKE_PREFIX"*) ;;
            *) optional_failure "DNS未走隧道" ;;
        esac
    fi

    if ! check_disabled "WebRTC"; then
        wr=$(webrtc_status "$ip")
        case "$wr" in fail:*) optional_failure "WebRTC:${wr#fail:}" ;; esac
    fi

    guard_state=$(bodyguard_status)
    case "$guard_state" in
        ok:*) ;;
        fail:未安装*) fails="$fails;保镖未安装(点一键修复)" ;;
        fail:*) fails="$fails;保镖:${guard_state#fail:}" ;;
        *) fails="$fails;保镖:状态无法验证" ;;
    esac

    # 置顶规则:Clash Verge 验证运行内核;全局模式下全部流量走代理,规则不适用;其他客户端只看行为检测
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if [ "$(clash_mode)" = "global" ]; then
            :
        elif [ -z "$PROXY_GROUP" ]; then
            fails="$fails;环境未配置(代理组缺失,点一键修复)"
        elif ! rule_err=$(clash_rules verify 2>&1 >/dev/null); then
            fails="$fails;规则置顶未生效($(rule_fix_hint "${rule_err#FAIL:}"))"
        fi
    else
        route_ok || fails="$fails;规则置顶缺失(这些域名没走隧道:${ROUTE_MISSED# })"
    fi

    if ! check_disabled "客户端语言"; then
        defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' || {
            syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
            [[ "$syslang" == en* ]] || optional_failure "客户端语言为中文"
        }
    fi

    # 纯净度只在真的判不过时才影响结论:机房出口(warn 级)不拦启动 —— 很多人就用
    # 机房节点,把它当硬失败等于把所有人挡在门外;代理特征和 Tor 才拦。
    # 取不到数据同样是 warn 级:网络抖动不该拦住启动,但也不能悄悄算通过。
    if ! check_disabled "IP纯净度"; then
        # 这里**读缓存、不重问**。check 是巡检每分钟跑一次的后台判定,它要回答的
        # 是「出口此刻还过不过门槛」,而不是「这条出口的信誉有没有变」——
        # 同一 IP 的信誉一天内不会剧变,为了它每分钟去敲四家源,既是纯浪费,
        # 也是我们自己的 IP 被反复送给第三方的唯一来源。要新结论走 checkdetail。
        IFS='|' read -r pscore pver ptype pdet pcc <<<"$(ip_purity "$ip")"
        case "${pver:-unknown}" in
            # 不能写成「纯净度低」:68 分的代理/VPN 出口是被硬门槛拦下的,
            # 分数并不低。把命中的门槛和分数口径一起写进门禁结论。
            fail) optional_failure "出口未过使用门槛 · $(purity_fail_reason "$ptype" "$pscore" "$pver")${pdet:+ · $pdet}" ;;
        esac
    fi

    if ! check_disabled "生态可达性"; then
        ecology_probe_read
        r1=${ECO_CODE1%%:*}; r2=${ECO_CODE2%%:*}
        if [ "$r1" = "000" ] || [ "$r2" = "000" ]; then
            # 用户把它设成安全基线时,这项失败和「代理没开」同级 —— 拦启动。
            if check_strict "生态可达性"; then
                fails="$fails;Anthropic生态不可达($r1/$r2)"
            else
                optional_failure "Anthropic生态不可达($r1/$r2)"
            fi
        fi
    else
        ecology_probe_discard
    fi

    # 关掉某项防护是用户自己的选择,但不能是「悄悄没了」:门禁输出里必须留痕。
    # 命令行、日志、自动化这些看不到界面的地方,靠这一句才知道本次判定是降级过的。
    degrade=""
    if [ -n "${CHECKS_DISABLED:-}" ]; then
        degrade="防护降级:${CHECKS_DISABLED//,/、} 已关闭,未参与本次判定"
    fi

    # fail-closed 有没有被证明过,和「防护降级」是同一条纪律:必须持续可见。
    # 16 项全绿只说明流量此刻走了代理,证明不了代理挂了会不会直连 —— 那件事
    # 只有 drill 能验。没有证据就说没有,不能沉默,更不能当成通过。
    # 它是软信号:不拦启动(否则等于拿我们自己的证据缺口去堵用户),但也不许消失。
    fc=""
    case "$(support fail-closed 2>/dev/null)" in
        established*) ;;
        violated*) fc="fail-closed演练未通过(代理断开可能直连,跑 drill 复验)" ;;
        stale*) fc="fail-closed证据已过期(跑 drill 复验)" ;;
        *) fc="fail-closed未验证(跑 drill 验证代理断开不会直连)" ;;
    esac

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:${ip:-未确认}${ipwarn:+|$ipwarn}${degrade:+|$degrade}${fc:+|$fc}"
    return 0
}

# ---------- 故障演练(fail-closed 验证) ----------
# 平时的检查只能证明「流量走了代理」,证明不了「代理挂了会不会直连」。这一项必须
# 真的把内核链路断掉才能验:断掉后本机应当完全断网,任何一条通路还能出去就是漏。
# 断链路有两种办法:auto 走内核接口关 TUN(不需要 sudo,可精确恢复);manual 由用户
# 手动停核(需要 sudo,断网时机由用户决定)。两条路都必须能恢复,所以全程挂着 trap。
# 当前 TUN 开关状态:true / false / unknown
# 不用 sed 的 \| 交替:macOS 自带 BSD sed 和这台机器上的 toybox sed 都不支持,
# 写了也只会静默返回空值,把"已关闭"误判成"没关掉"。
tun_state() {
    local sock json tun
    sock=$(clash_sock) || { echo "unknown"; return 1; }
    json=$(curl -s --max-time 8 --unix-socket "$sock" http://localhost/configs 2>/dev/null)
    [ -n "$json" ] || { echo "unknown"; return 1; }
    tun=$(printf '%s' "$json" | tr -d '[:space:]' | sed 's/.*"tun":{//; s/}.*//')
    case "$tun" in
        *'"enable":true'*)  echo "true" ;;
        *'"enable":false'*) echo "false" ;;
        *) echo "unknown"; return 1 ;;
    esac
}

# 运行时开关 TUN。PATCH 只改内存不落盘,重启内核即回到配置文件里的值。
tun_set() {
    local sock code
    sock=$(clash_sock) || { echo "FAIL:找不到内核控制接口,无法自动开关 TUN"; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$sock" \
        -X PATCH -H 'Content-Type: application/json' \
        -d "{\"tun\":{\"enable\":$1}}" http://localhost/configs 2>/dev/null)
    case "$code" in
        200|204) return 0 ;;
        *) echo "FAIL:内核拒绝修改 TUN(HTTP ${code:-000})"; return 1 ;;
    esac
}

# fail-closed 演练:平时检查只能证明"流量走了代理",证明不了"代理挂了会不会直连"。
# 默认 auto —— 通过内核接口关掉 TUN,效果等价于核死时路由被撤销,但可以精确恢复,
# 不需要 sudo,也不会把用户留在断网状态。--manual 保留原来的手动停核路径。
# 把 TUN 拉回来,并确认「网真的通了」。
#
# 只把 tun_state 改回 true 是不够的,实测是这样坏掉的(2026-11-19):
# 面板显示 TUN 已开、curl 和浏览器却连不上 —— 因为 TUN 断开期间那几轮失败的
# 域名解析留在了 DNS 缓存里(fake-ip 模式下尤其明显)。用户看到的现象就是
# 「演练结束后网坏了」。所以恢复分三步,少一步都不能说「已恢复」:
#   1) 拉起 TUN,并等它真的起来(最多 10s)
#   2) 清掉 DNS 缓存(这条不需要 sudo)
#   3) 真的发一次请求,最多等 20s;每 6 秒补拉一次 TUN —— 内核可能自己把它关了
drill_restore_tun() {
    local waited=0 retry=0
    tun_set true >/dev/null 2>&1 || true
    while [ "$waited" -lt 10 ]; do
        [ "$(tun_state)" = "true" ] && break
        sleep 1; waited=$((waited + 1))
    done
    if [ "$(tun_state)" != "true" ]; then
        echo "WARN:TUN 没能拉起来(内核可能已经退出了)"
        return 1
    fi
    dscacheutil -flushcache 2>/dev/null || true
    waited=0
    while :; do
        probe_egress 3 || true
        [ "$PROBE_STATUS" = "ok" ] && return 0
        [ "$waited" -ge 20 ] && break
        sleep 2; waited=$((waited + 2))
        if [ $((waited % 6)) -eq 0 ] && [ "$retry" -lt 2 ]; then
            retry=$((retry + 1))
            tun_set true >/dev/null 2>&1 || true
            dscacheutil -flushcache 2>/dev/null || true
        fi
    done
    return 1
}

# 演练:关掉代理链路,看本机是否还能直连外网(即 fail-closed 是否成立)。
drill() {
    local mode="auto" answer="" baseline after leaked out code result waited i arg restore_ok=0
    local tcp_ok=0 tcp_fail=0 tcp_status=unknown tcp_start tcp_ms=0
    local dns_ok=0 dns_fail=0 dns_status=unknown dns_start dns_ms=0
    local wr_ok=0 wr_fail=0 wr_status=unknown wr_start wr_ms=0 wr_out
    local tcp_ok_out tcp_fail_out tcp_ms_out dns_ok_out dns_fail_out dns_ms_out
    local wr_ok_out wr_fail_out wr_ms_out
    for arg in "$@"; do
        case "$arg" in
            --manual) mode="manual" ;;
            --auto)   mode="auto" ;;
            --yes)    answer="yes" ;;
        esac
    done

    proxy_alive || { echo "FAIL:代理内核未运行,先启动再演练"; return 1; }
    tun_up || { echo "FAIL:TUN网卡不在线,先修复再演练"; return 1; }
    probe_egress 3
    [ "$PROBE_STATUS" = "ok" ] || { echo "FAIL:当前出口无法采样($PROBE_STATUS),先修复再演练"; return 1; }
    baseline="$PROBE_IP"

    if [ "$mode" = "auto" ] && [ -z "$(clash_sock)" ]; then
        echo "INFO:找不到内核控制接口,退回手动停核"
        mode="manual"
    fi

    echo "INFO:演练基准出口 $baseline"
    if [ "$mode" = "auto" ]; then
        echo "INFO:方式=自动关 TUN(走内核接口,不需要 sudo,结束自动恢复)"
    else
        echo "INFO:方式=手动停核(在 Clash Verge 里退出内核)"
        echo "INFO:恢复——重新打开 Clash Verge 并确认 TUN 已开启"
    fi
    if [ -z "$answer" ]; then
        printf '继续? 输入 yes 回车: '
        read -r answer
        [ "$answer" = "yes" ] || { echo "已取消,未做任何改动"; return 2; }
    fi

    # 把用户留在断网状态是最坏的结果:不管从哪条路退出都要恢复。
    trap 'echo "WARN:演练未正常结束,正在尝试恢复 TUN"; tun_set true >/dev/null 2>&1; echo "WARN:请确认 Clash Verge 里 TUN 已开启"' EXIT INT TERM

    if [ "$mode" = "auto" ]; then
        tun_set false || { trap - EXIT INT TERM; return 1; }
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [ "$(tun_state)" = "false" ] && break
            sleep 1
        done
        if [ "$(tun_state)" != "false" ]; then
            echo "FAIL:TUN 未真正关闭,演练无效(已尝试恢复)"
            tun_set true >/dev/null 2>&1
            trap - EXIT INT TERM
            return 1
        fi
    else
        printf '停掉内核后回车(最多等 90 秒): '
        read -r answer
        waited=0
        while proxy_alive; do
            if [ "$waited" -ge 90 ]; then
                echo "FAIL:90 秒内内核仍在运行,演练未开始(未做任何改动)"
                trap - EXIT INT TERM
                return 1
            fi
            sleep 3; waited=$((waited + 3))
        done
    fi

    # 同时测域名与裸 IP:域名可能被 fake-ip 接住而"看起来"正常,裸 IP 绕不过去。
    # 裸 IP 用 HTTP 响应码判定,不解析响应内容:http://1.1.1.1/cdn-cgi/trace 会被
    # 301 到 https,而 https://1.1.1.1 的证书是 *.cloudflare-dns.com,校验必失败,
    # 按内容判定会让这一路永远取不到值——真漏了也会被误判成"没漏"。
    # 只要拿到任何响应码(含 4xx/5xx),就证明这条通路是活的。
    # 全程 --noproxy:演练要测的是内核链路,不是 HTTPS_PROXY 指向的那个端口;
    # 否则核停后代理端口一起死,会得出"没漏"的假结论。
    echo "INFO:内核链路已断开,开始探测直连通路(域名与裸 IP 各 3 次)"
    leaked=""
    tcp_start=$(date +%s)
    for i in 1 2 3; do
        out=$(curl -s --max-time 4 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
        if [ -n "$out" ]; then tcp_ok=$((tcp_ok + 1)); else tcp_fail=$((tcp_fail + 1)); fi
        [ -n "$out" ] && leaked="$leaked $out"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --noproxy '*' http://1.1.1.1/ 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            tcp_ok=$((tcp_ok + 1)); leaked="$leaked bare-ip-http-$code"
        else
            tcp_fail=$((tcp_fail + 1))
        fi
    done
    tcp_ms=$(( ($(date +%s) - tcp_start) * 1000 ))
    [ "$((tcp_ok + tcp_fail))" -gt 0 ] && {
        tcp_status=ok; [ "$tcp_ok" -eq 0 ] && tcp_status=fail
    }
    # DNS 与 STUN 也用同一条断链通路测:前者看裸解析是否还活着,后者看 UDP 是否
    # 在 TUN 撤销后仍然出去。拿不到命令/探针时写 unknown,不要用 0 冒充已验证。
    if command -v dig >/dev/null 2>&1; then
        dns_status=ok; dns_start=$(date +%s)
        for i in 1 2 3; do
            if [ -n "$(dig +short +time=2 +tries=1 www.cloudflare.com 2>/dev/null | head -1)" ]; then
                dns_ok=$((dns_ok + 1))
            else
                dns_fail=$((dns_fail + 1))
            fi
        done
        dns_ms=$(( ($(date +%s) - dns_start) * 1000 ))
        [ "$dns_ok" -eq 0 ] && dns_status=fail
    fi
    if [ -f "$BASE/stun-probe.py" ] && command -v "${CLAUDE_SWITCHER_PYTHON:-python3}" >/dev/null 2>&1; then
        wr_status=fail; wr_start=$(date +%s)
        wr_out=$(webrtc_test)
        if [ -n "$wr_out" ]; then wr_ok=1; wr_status=ok; else wr_fail=1; fi
        wr_ms=$(( ($(date +%s) - wr_start) * 1000 ))
    fi
    # unknown 时不能把 0 打给用户看:那会被读成「查过了,零成功零失败」。
    tcp_ok_out=$tcp_ok; tcp_fail_out=$tcp_fail; tcp_ms_out=$tcp_ms
    [ "$tcp_status" = unknown ] && { tcp_ok_out=unknown; tcp_fail_out=unknown; tcp_ms_out=unknown; }
    dns_ok_out=$dns_ok; dns_fail_out=$dns_fail; dns_ms_out=$dns_ms
    [ "$dns_status" = unknown ] && { dns_ok_out=unknown; dns_fail_out=unknown; dns_ms_out=unknown; }
    wr_ok_out=$wr_ok; wr_fail_out=$wr_fail; wr_ms_out=$wr_ms
    [ "$wr_status" = unknown ] && { wr_ok_out=unknown; wr_fail_out=unknown; wr_ms_out=unknown; }
    echo "PROBE:tcp=$tcp_status success=$tcp_ok_out failure=$tcp_fail_out elapsed=${tcp_ms_out}ms"
    echo "PROBE:dns=$dns_status success=$dns_ok_out failure=$dns_fail_out elapsed=${dns_ms_out}ms"
    echo "PROBE:webrtc=$wr_status success=$wr_ok_out failure=$wr_fail_out elapsed=${wr_ms_out}ms"
    if [ -n "$leaked" ]; then
        leaked=$(printf '%s\n' $leaked | sort -u | tr '\n' ' ')
        leaked="${leaked% }"
        echo "FAIL:fail-closed 不成立——内核已停,仍有直连出口: $leaked"
        result="violated:${leaked// /,}"
    else
        echo "OK:fail-closed 成立——内核已停,所有探测均无响应"
        result="established"
    fi

    if [ "$mode" = "auto" ]; then
        echo "INFO:恢复 TUN,并确认出口真的回来了(最多 30 秒)"
        drill_restore_tun && restore_ok=1
    else
        printf '重新启动内核并开启 TUN 后回车: '
        read -r answer
        waited=0
        while ! proxy_alive; do
            if [ "$waited" -ge 120 ]; then
                echo "FAIL:内核未恢复,请手动启动 Clash Verge 并开启 TUN"
                trap - EXIT INT TERM
                return 1
            fi
            sleep 3; waited=$((waited + 3))
        done
        drill_restore_tun && restore_ok=1
    fi
    if [ "$restore_ok" = "1" ]; then
        echo "OK:已恢复出口 ${PROBE_IP:-未知}"
        if [ -n "$PROBE_IP" ] && [ -n "$baseline" ] && [ "$PROBE_IP" != "$baseline" ]; then
            echo "WARN:出口与演练前不同($baseline -> $PROBE_IP),换过节点;Claude 要重启才会走新线路"
        fi
    else
        echo "FAIL:恢复后出口仍未通 —— 在 Clash Verge 里确认 TUN 已开启、节点已选好,再点「重新检查」"
    fi
    trap - EXIT INT TERM

    echo "出口IP=${PROBE_IP:-未确认} 演练=$result"
    if [ -n "$BASE" ]; then
        support drill-record "$(date '+%F %T')" "$result" \
            "$tcp_status" "$tcp_ok" "$tcp_fail" "$tcp_ms" \
            "$dns_status" "$dns_ok" "$dns_fail" "$dns_ms" \
            "$wr_status" "$wr_ok" "$wr_fail" "$wr_ms" >/dev/null 2>&1 || true
        echo "$(date +%s) baseline=$baseline after=${PROBE_IP:-none} result=$result tcp=$tcp_ok/$tcp_fail dns=$dns_ok/$dns_fail webrtc=$wr_ok/$wr_fail" >> "$BASE/drill.log"
    fi
    # 恢复失败要当成失败退出:结论记下来了,但「网没回来」比结论更要紧,
    # 退出码不能是 0 —— 否则界面上会显示「演练完成、一切正常」。
    [ "$restore_ok" = "1" ] || return 1
    [ "${result%%:*}" = "established" ]
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    "${CLAUDE_SWITCHER_PYTHON:-python3}" "$BASE/stun-probe.py" 2>/dev/null
}

# 日常检查与修复共用此判断。先确认规则，再允许探测，避免向已知直连路径发包。
webrtc_status() {
    local verified result probe_rc assessment mode leak wips w
    # STUN 探针只返回 IPv4 地址,拿 IPv6 出口没法直接比。双栈节点会在两个族之间
    # 来回报(本机实测:同一节点一会儿 144.172.103.106 一会儿 2602:fa59:10:503::1),
    # 不处理的话 WebRTC 会间歇性判「无法比对」—— 而这会拦住启动。
    # 出口是 v6 时单独取一次 v4 出口来比,因为 UDP 的 STUN 走的就是 v4。
    local exitip="$1"
    case "$exitip" in
        *:*)
            exitip=$(curl -4 -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
            # 注意 curl -4 也可能拿回 v6:节点本身是 v6-only 出口时,Cloudflare 看到的
            # 就是节点的 v6 地址,和请求的协议族无关(实测 2602:fa59:10:503::1)。
            # 所以这里不能只判空,必须确认拿到的真是 IPv4。
            case "$exitip" in
                ''|*:*)
                    # 真的没有 v4 出口:IPv4 的 STUN 结果本来就无从比对。
                    # 这不是泄漏,但也不能当作已验证 —— 明确说成 warn,不拦启动。
                    #
                    # 文案里要带「STUN 只回 IPv4」。原来写「出口只有 IPv6，STUN 结果无法比对」,
                    # 主语是「出口」,读者得到的信息是「我的出口有问题」;而且它和
                    # 「IPv6 关闭 通过」并排时像是在说检查自相矛盾。真正的因果是:
                    # 节点没有 v4 出口 → 我们的 STUN 探针(只能走 v4)没有可比对象。
                    echo "warn:节点无 IPv4 出口，STUN 只回 IPv4，无法比对(非泄漏)"
                    return ;;
            esac ;;
    esac
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        mode=$(clash_mode)
        # 全局模式不经过规则匹配,直接按"STUN 结果是否等于当前出口"判断
        if [ "$mode" = "global" ]; then
            result=$(webrtc_test)
            probe_rc=$?
            [ "$probe_rc" -ne 0 ] && { echo "fail:STUN 探测执行失败，未确认 UDP 出口"; return; }
            case "$result" in
                RESULT:NONE) echo "warn:UDP 无响应,全局模式下无法验证(可能已被节点拦截)" ;;
                RESULT:*)
                    leak=""
                    wips=${result#RESULT:}
                    OLDIFS=$IFS; IFS=','
                    for w in $wips; do [ -n "$exitip" ] && [ "$w" != "$exitip" ] && leak="$leak $w"; done
                    IFS=$OLDIFS
                    if [ -n "$leak" ]; then
                        echo "fail:暴露非代理IP:${leak# }"
                    else
                        echo "ok:仅暴露代理出口IP(全局模式)"
                    fi ;;
                *) echo "fail:STUN 探测结果格式异常" ;;
            esac
            return
        fi
        if ! verified=$(clash_rules verify 2>&1); then
            # 原样抛 verify 的错误会得到「WebRTC:运行规则未验证:运行规则未按策略置顶:clau.de」
            # —— 三层冒号、一个术语、零个动作。翻成一句话 + 动作再往上抛。
            echo "fail:$(rule_fix_hint "${verified#FAIL:}")"
            return
        fi
    fi
    result=$(webrtc_test)
    probe_rc=$?
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        assessment=$(clash_rules assess "$exitip" "$result" "$probe_rc" 2>/dev/null)
    else
        # 其他客户端的规则由用户管理，不能把 reject 的无响应视为已验证。
        assessment=$(WEBRTC_POLICY=proxy clash_rules assess "$exitip" "$result" "$probe_rc" 2>/dev/null)
    fi
    case "$assessment" in
        ok:*|warn:*|fail:*) echo "$assessment" ;;
        *) echo 'fail:无法评估 STUN 结果' ;;
    esac
}

# 保镖脚本由 root 安装，MODE 在安装时写死。核心切客户端后必须检测模式一致性，
# 否则旧保镖可能按错误的代理进程状态关闭 Claude，单看 launchctl 在线会误报成功。
bodyguard_status() {
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        echo 'fail:未安装'
        return
    fi
    local guard="/Library/Application Support/claude-switcher/claude-bodyguard.sh"
    if [ ! -r "$guard" ]; then
        echo 'fail:守护脚本不可读或缺失(请重新运行安装器)'
        return
    fi
    local guard_mode
    guard_mode=$(sed -n 's/^MODE="\([^"]*\)".*/\1/p' "$guard" | head -1)
    if [ -z "$guard_mode" ]; then
        echo 'fail:守护模式无法识别(请重新运行安装器)'
        return
    fi
    if [ "$guard_mode" != "$PROXY_MODE" ]; then
        echo "fail:客户端不一致(核心=$PROXY_MODE,保镖=$guard_mode;请重新运行安装器同步)"
        return
    fi
    local lastkill
    # 新版守护把日志写在 root 所有的 /var/log 下(避免以 root 跟随用户目录的符号链接);
    # 老安装件仍在 ~/Library/Logs,读取时两处都看。
    lastkill=$(tail -1 /var/log/claude-switcher/claude-bodyguard.log 2>/dev/null | cut -c1-40)
    [ -n "$lastkill" ] || lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
    echo "ok:${lastkill:-待命}"
}

# 当前系统时区(IANA 名,读不到就输出空)。
# 取值方式只留这一份:check()、checkdetail()、fix() 原来各写一遍
# `readlink /etc/localtime` + 剥前缀,任一处改口径就会让「检查说 ok、修复还在改」
# 这种自相矛盾的事情重新出现。只输出名字,不输出 /var/db/timezone/zoneinfo/ 前缀 ——
# 那个路径对用户没有意义,看着像系统坏了。
tz_current() {
    local tz
    tz=$(readlink /etc/localtime 2>/dev/null) || return 0
    printf '%s\n' "${tz##*/zoneinfo/}"
}

# 已安装的时区看门狗守着哪个目标值(读不到就输出空)。
# 老安装件写的是 TARGET="America/New_York",set-region 同步时写的是不带引号的
# TARGET=America/New_York,两种都得认,所以剥引号而不是匹配引号。
tz_watchdog_target() {
    # TZ_WATCHDOG_FILE 只为测试留口:默认读系统安装位置,测试指向临时文件,
    # 否则「看门狗守错目标」这条断言会随开发机的真实安装状态飘。
    local f="${1:-${TZ_WATCHDOG_FILE:-/Library/Application Support/claude-switcher/tz-watchdog.sh}}"
    [ -r "$f" ] || return 0
    sed -n 's/^TARGET=//p' "$f" 2>/dev/null | head -1 | tr -d '"'
}

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    load_check_config || { echo "检查配置无效，请恢复默认设置"; return 1; }
    # 生态探测与出口采样互不依赖:先发出去,等采样跑完再来取,不占主路径。
    check_disabled "生态可达性" || ecology_probe_start
    if proxy_alive; then
        case "$PROXY_MODE" in
            shadowrocket) echo '代理内核=ok:Shadowrocket 已连接' ;;
            *) echo "代理内核=ok:$(proxy_name) 运行中" ;;
        esac
    else
        # 客户端没开是「还没开始」,不是「不安全」;动作只有一步。
        echo "代理内核=fail:$(proxy_name) 未运行 · 启动后重新检查"
    fi
    if tun_up; then echo 'TUN网卡=ok'; else echo 'TUN网卡=fail:不在线 · 在客户端里开启 TUN 模式'; fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        # 只报「地址/地区」。原来 v6 出口会加一句「(IPv6 出口)」——
        # 地址本身就有冒号,再补一句等于同一件事说两遍;而且那句话读起来
        # 像是「你开了 IPv6」,和「IPv6 关闭」那一项当场打架。
        # 「节点侧还是本机」的区分写在 IPv6 那一行,一处交代就够。
        echo "出口IP=ok:$ip/$loc"
    elif [ -z "$COUNTRY_TARGET" ]; then
        config_result "出口IP" "环境层未就绪(未取到目标国家) · 点「一键修复」"
    else
        echo "出口IP=fail:当前 ${ip:-无}/${loc:-未知},期望 $COUNTRY_TARGET · 换到 $COUNTRY_TARGET 节点"
    fi
    if check_disabled "IP一致"; then
        optional_result "IP一致" ok
    else
        curkey=""; [ -n "$ip" ] && curkey=$(ip_key "$ip")
        ipst=""; ipdt=""
        if [ -z "$ip" ]; then ipst="fail"; ipdt="未获取到出口IP · 检查网络后重新检查"
        else
            lastip=$(last_seen "${curkey%%:*}")
            baseline=$(ip_baseline_get)
            if [ -z "$baseline" ]; then
                ip_baseline_set "$curkey"
                ipst="ok"; ipdt="已把 $(ip_show "$curkey") 记为固定出口"
            elif [ "$curkey" = "$baseline" ]; then
                ipst="ok"; ipdt="与固定出口一致(已固定 $(ip_baseline_age))"
            else
                ipn=$(iphist_count)
                ipst="warn"
                ipdt=$(ip_baseline_warn "$curkey" "$baseline" "$(ip_class "$(ip_org "$ip")")")
                [ "${ipn:-0}" -ge 2 ] && ipdt="$ipdt(7 天内见过 $ipn 个出口)"
            fi
            last_save "$curkey"
            iphist_record "$curkey"
        fi
        optional_result "IP一致" "$ipst" "$ipdt"
    fi
    # 时区/地区:报「当前值 vs 期望值」,不报 readlink 的完整路径。
    # 原来直接打印 /var/db/timezone/zoneinfo/America/Los_Angeles,看起来像系统坏了,
    # 实际只是目标值和当前值不一致 —— 用户看不出该改哪一边。
    tz=$(tz_current)
    if [ -z "$TZ_TARGET" ]; then
        config_result "时区" "环境层未就绪(未取到时区目标) · 点「一键修复」"
    elif [ "$tz" != "$TZ_TARGET" ]; then
        echo "时区=fail:当前 ${tz:-未知},期望 $TZ_TARGET · 点「一键修复」对齐"
    else
        # 时区对了还不够:看门狗若守着别的目标,会在 5 分钟内把它改回去,
        # 用户只会看到「修好了又坏了」。这一条以前从来没检查过。
        wt=$(tz_watchdog_target)
        if [ -n "$wt" ] && [ "$wt" != "$TZ_TARGET" ]; then
            echo "时区=warn:当前值正确,但时区巡检仍守着 $wt · 会自己改回去,点「一键修复」同步"
        else
            echo '时区=ok'
        fi
    fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ -z "$LOCALE_TARGET" ]; then
        config_result "地区" "环境层未就绪(未取到地区目标) · 点「一键修复」"
    elif [ "$locale" = "$LOCALE_TARGET" ]; then
        echo '地区=ok'
    else
        echo "地区=fail:当前 ${locale:-未知},期望 $LOCALE_TARGET · 点「一键修复」对齐"
    fi
    v6=$(ipv6_on_services | paste -sd '、' -)
    if [ -z "$v6" ]; then
        # 出口是 v6 时才补一句「本机 / 节点」的分层。这一行和「出口 IP」隔着两行
        # 并排显示,出口写 2602:… 时用户直接读出「说关了 IPv6,出口却是 IPv6」——
        # 两句话说的根本不是一层:这一项管的是**本机网卡**,出口是**节点侧的**。
        # 出口是 v4 时不多话:那时本来就没有可误会的地方,多写一句只是噪音。
        case "$ip" in
            *:*) echo 'IPv6=ok:本机已关闭 · 节点出口为 IPv6' ;;
            *)   echo 'IPv6=ok:已关闭' ;;
        esac
    else
        echo "IPv6=fail:未关闭($v6) · 点「一键修复」"
    fi
    if check_disabled "DNS"; then
        optional_result "DNS" ok
    else
        dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsip" in
            "$FAKE_PREFIX"*) optional_result "DNS" ok "走隧道" ;;
            # 这一项脚本修不了(见 fix() 里的说明),界面因此不再给它「修复」按钮。
            # 既然不给按钮,「怎么办」就必须写在这一行里 —— 否则用户既没有按钮,
            # 也不知道下一步做什么,只能对着一个红叉发呆。
            *) optional_result "DNS" fail "未走隧道(${dnsip:-空}) · 请在客户端把 DNS 设为隧道/DoH" ;;
        esac
    fi
    if check_disabled "WebRTC"; then
        optional_result "WebRTC" ok
    else
        wr=$(webrtc_status "$ip")
        wrst=${wr%%:*}; wrdt=""
        case "$wr" in *:*) wrdt=${wr#*:} ;; esac
        optional_result "WebRTC" "$wrst" "$wrdt"
    fi
    guard=$(bodyguard_status)
    case "$guard" in
        ok:*) echo "保镖=$guard" ;;
        # 没装 ≠ 没工作:装一下就好,别让用户去排查安全配置。
        fail:未安装*) echo '保镖=fail:未安装 · 点「一键修复」(需一次管理员授权)' ;;
        fail:*) echo "保镖=fail:${guard#fail:}" ;;
        *) echo '保镖=fail:状态无法验证 · 重新运行检查' ;;
    esac
    # 置顶规则:Clash Verge 验证运行内核;全局模式下规则不适用(全部流量已走代理)
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if [ "$(clash_mode)" = "global" ]; then
            echo '规则置顶=ok:全局模式(全部流量走代理)'
        elif [ -z "$PROXY_GROUP" ]; then
            # 代理组没取到 = 环境层没就绪,规则校验根本无从谈起。以前这里报
            # 「未生效」,把用户引去查规则;他真正要做的是把环境层补齐。
            config_result "规则置顶" "环境层未就绪(未取到代理组) · 点「一键修复」"
        elif rule_err=$(clash_rules verify 2>&1 >/dev/null); then
            echo '规则置顶=ok'
        else
            echo "规则置顶=fail:$(rule_fix_hint "${rule_err#FAIL:}")"
        fi
    else
        if route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo "规则置顶=fail:这些域名没走隧道(${ROUTE_MISSED# }) · 在 $(proxy_name) 里置顶 Claude 域名"
        fi
    fi
    # 12. Claude 客户端语言(单独设为英文,或系统首选语言为英文均可;防止 JS 层读出中文)
    if check_disabled "客户端语言"; then
        optional_result "客户端语言" ok
    else
        clang=$(defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | head -2)
        syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
        if echo "$clang" | grep -q 'en-US'; then
            optional_result "客户端语言" ok "en-US"
        elif [[ "$syslang" == en* ]]; then
            optional_result "客户端语言" ok "跟随系统(英文)"
        else
            optional_result "客户端语言" fail "当前中文 · 点「一键修复」设为英文"
        fi
    fi
    # 13. ASN 网络属性(住宅宽带 vs 机房,按目标地区收录主流运营商)
    if check_disabled "ASN属性"; then
        optional_result "ASN属性" ok
    else
        # 出口 ASN 只查一次(ip_org 有缓存),类型判定与「IP 一致」共用同一套口径。
        org=$(ip_org "$ip")
        case "$(ip_class "$org")" in
            residential) optional_result "ASN属性" ok "$org" ;;
            hosting)     optional_result "ASN属性" warn "疑似机房($org) · 建议换住宅节点" ;;
            # 名字不在名单里 ≠ 机房。以前这一支输出「未获取」,配合 ip_class 的
            # hosting 默认值,把一个三家源都说干净的 GTT 出口报成机房。
            # 现在只把「没归类」说清楚,结论交给下面那项按证据判的 IP 纯净度。
            *) if [ -n "$org" ]; then
                   optional_result "ASN属性" ok "$org · 运营商未归类(未命中机房名单)"
               else
                   optional_result "ASN属性" warn "未获取"
               fi ;;
        esac
    fi
    # 14. IP 纯净度(出口类型 × 代理特征 × Tor × 地域一致,给一个能解释的 0-100)
    if check_disabled "IP纯净度"; then
        optional_result "IP纯净度" ok
    else
        # 第二参数 1 = 强制重问。任何一次给人看的检查都必须是真的新结论:
        # 用户点「重新检查」时最不能接受的就是拿到几小时前的旧数字。
        # 代价是每次详细检查 4 个请求,而它是用户显式触发的,不是后台定时。
        IFS='|' read -r pscore pver ptype pdet pcc <<<"$(ip_purity "$ip" 1)"
        case "${pver:-unknown}" in
            # 取不到就明说没评级。这里绝不能借 ok 混过去 —— 用户看到绿勾会
            # 以为「出口干净已经验过了」,而实际上什么都没验。
            unknown) optional_result "IP纯净度" warn "${pdet:-未取到信誉数据}" ;;
            # fail 时明说命中的是哪条硬门槛。分数高却红叉时(例如 68 分的
            # 代理/VPN 出口),这一句就是用户要的解释,不能只丢一个数字。
            fail)    optional_result "IP纯净度" "$pver" \
                        "${pdet:-评分 ${pscore:-?}/100} · 硬门槛:$(purity_fail_reason "$ptype" "$pscore" "$pver")" ;;
            *)       optional_result "IP纯净度" "$pver" "$pdet" ;;
        esac
    fi
    # 15. Anthropic 生态可达性
    if check_disabled "生态可达性"; then
        optional_result "生态可达性" ok
    else
        # 首包时间顺手带上:参考里的「路径要短且干净」是一条,但我们只能观测、不能判断,
        # 所以只报数字,不替你下结论(亚洲访问 100ms 以上本来也正常)。
        ecology_probe_read
        r1="$ECO_CODE1"; r2="$ECO_CODE2"
        c1=${r1%%:*}; t1=${r1##*:}
        c2=${r2%%:*}; t2=${r2##*:}
        [ -z "$c1" ] && c1="000"
        [ -z "$c2" ] && c2="000"
        ms2=$(awk -v t="${t2:-0}" 'BEGIN{printf "%d", t*1000+0.5}' 2>/dev/null)
        detail="claude.ai:$c1 api:$c2"
        case "${ms2:-}" in ''|*[!0-9]*|0) ;; *) detail="$detail · api 首包 ${ms2}ms" ;; esac
        # 每次检查落一条采样,给界面的「24h 延迟洞察」用。
        # 只记观测值,不在这里下判断:ms 为 0 表示这次没连上,
        # 可用率就是靠它算出来的 —— 别把失败样本丢掉,否则可用率永远是 100%。
        if [ -n "${BASE:-}" ] && [ -d "$BASE" ]; then
            printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${ms2:-0}" "$c1" "$c2" >> "$BASE/rtt.log" 2>/dev/null
            # 每 10 分钟最多 60 条,24h 也就 8 千条。超过 512KB 就裁一半,
            # 不做的话日志会一直长下去。
            if [ "$(stat -f%z "$BASE/rtt.log" 2>/dev/null || echo 0)" -gt 524288 ] 2>/dev/null; then
                tail -n 3000 "$BASE/rtt.log" > "$BASE/rtt.log.tmp" 2>/dev/null \
                    && mv "$BASE/rtt.log.tmp" "$BASE/rtt.log" 2>/dev/null
            fi
        fi
        if [ "$c1" != "000" ] && [ "$c2" != "000" ]; then
            optional_result "生态可达性" ok "$detail"
        elif check_strict "生态可达性"; then
            # 设成安全基线时不接受「非关键失败」降级:说拦就拦。
            echo "生态可达性=fail:$detail · 已设为安全基线,必须可达 · 换条线路后重新检查"
        else
            optional_result "生态可达性" fail "$detail · 换条线路后重新检查"
        fi
    fi
    # 16. DNS 泄露。补「走隧道」的盲区:fake-ip 只证明查询被 TUN 劫持,
    # 证明不了上游递归是谁 —— 2026-11-23 实测,订阅 fallback 并发架构下
    # 泄露测试页标国内解析器而全项绿。两项合一:
    #   (a) 上游架构审计(dns_audit:fallback 并发/明文上游/无海外加密上游);
    #   (b) 内核解析活性(/dns/query 必须真能给出应答,证明海外加密 DoH 可达)。
    if check_disabled "DNS泄露"; then
        optional_result "DNS泄露" ok
    elif [ "$PROXY_MODE" != "clash-verge" ]; then
        optional_result "DNS泄露" skip "上游审计仅支持 Clash Verge(读不到其他客户端的标准运行配置)"
    else
        local dns_leak_issues dl_sock dl_secret dl_json
        if dns_leak_issues=$(dns_audit 2>/dev/null); then
            optional_result "DNS泄露" fail "$dns_leak_issues · 点「一键修复」"
        else
            dl_sock=$(clash_sock 2>/dev/null)
            dl_secret=$(sed -n 's/^secret:[[:space:]]*//p' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null | tr -d '"' | head -1)
            if [ -n "$dl_sock" ] && \
               dl_json=$(curl -s --max-time 8 --unix-socket "$dl_sock" \
                   -H "Authorization: Bearer ${dl_secret}" \
                   "http://localhost/dns/query?name=www.cloudflare.com&type=A" 2>/dev/null) && \
               printf '%s' "$dl_json" | grep -q '"Status":0'; then
                optional_result "DNS泄露" ok "上游架构审计通过 · 内核加密解析可达"
            else
                # 架构干净但解析器答不上话:海外 DoH 走代理出去,代理不通就查不了。
                optional_result "DNS泄露" warn "上游架构干净但内核解析未应答 · 检查节点可达性后重查"
            fi
        fi
    fi
}

# ---------- 节点扫描(只读) ----------
# 边界写在前头:不切节点、不重启客户端、不动巡检、不写 iphistory。
# ip_purity() 按 IP 打分、按 IP 缓存,和「当前出口」无关 —— 这正是离线扫描
# 不会污染 48h IP 漂移记录的原因。逐个切节点在线实测那条路会写 N 条漂移,
# 反而把「IP 与上次一致」扣分,绝不能走。
NODE_SCAN_FILE="$BASE/node-scan.txt"
PREFERRED_NODE_FILE="$BASE/preferred-node"   # selector<TAB>leaf<TAB>ip<TAB>epoch
NODE_SCAN_TTL=86400
NODE_SCAN_MARGIN=10       # 比当前高至少 10 分才值得建议换,免得天天让用户换线路
NODE_SCAN_PARALLEL=1      # 每个 ip_purity 内部已经 4 路并发,再乘 N 就是 4N 个并发
                          # 打四家免费源。原来是 3(12 并发),2026-11-20 收成 1(4 并发):
                          # 本机 11 个叶子去重后只有 3 个出口 IP,一轮只差约 8 秒。
                          # 扫描是用户显式触发的,一天顶多几次,但它一次性打出的是
                          # 最密集的突发 —— 免费源限流看的是瞬时并发,不是日总量。

# 读已固定的节点名。文件损坏/缺列一律当「没固定」,不能让半行数据把检查项卡死。
preferred_node_leaf() {
    [ -f "$PREFERRED_NODE_FILE" ] || return 0
    awk -F'\t' 'NF >= 2 && $2 != "" {print $2; exit}' "$PREFERRED_NODE_FILE" 2>/dev/null
}

# ---------- 「Claude 在不在跑」的统一判据 ----------
# 三个入口都要认,少一个就会出现「明明开着却报未运行」:
#   1. 桌面 App      <安装位置>/Claude.app/Contents/MacOS/Claude
#                      (官方默认 /Applications,也允许 ~/Applications)
#   2. 老 npm 包     .../claude-code/cli.js 与 @anthropic-ai/claude-code
#   3. 原生二进制    brew / ~/.local/bin 装的,argv[0] 就是 `claude`
#
# 第 3 种是现在的主流装法,原来完全没认 —— 实测 `claude --version` 的进程
# 命令行就是 `claude --version`,上面两条 -f 模式一条都匹配不上。后果是:
# 节点门禁判成「没在跑」,看门狗熔断时也不会去停它。
claude_app_running() {
    # 不写死 /Applications:App 被拖进 ~/Applications 时同样要认出来。
    pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1
}

claude_cli_running() {
    pgrep -x claude >/dev/null 2>&1 && return 0
    pgrep -f "claude-code/cli.js" >/dev/null 2>&1 && return 0
    pgrep -f "@anthropic-ai/claude-code" >/dev/null 2>&1 && return 0
    return 1
}

claude_running() {
    claude_app_running || claude_cli_running
}

# 能不能自动应用,只看「此刻有没有东西在用这条出口」。
#
# 这里原来还有第四条:status 里 hasA..hasD=1 —— 只要**存过**任何账号快照就判
# 「已有实例环境」。那是个死条件:槽位是常驻资产,存过一次就永远为真,于是
# node-apply 对任何用过本工具的人都是永久拒绝,和 Claude 有没有在跑无关。
# 实测 hasA=1 hasB=1 时门禁恒为 report-only,界面上「应用最优节点」从不出现。
# 现在只认「进程在跑」和「看门狗还驻守」这两个瞬时事实 —— 存着快照本身
# 不占用出口,换线路不会动到它。
node_gate() {
    local reasons="" pid=""
    if claude_running; then
        reasons="Claude 正在运行"
    fi
    pid=$(awk -F'\t' '{print $1; exit}' "$BASE/watch.pid" 2>/dev/null)
    if [ -n "$pid" ] && watch_pid_is_watchdog "$pid"; then
        reasons="${reasons:+${reasons}、}巡检驻守中"
    fi
    if [ -n "$reasons" ]; then
        printf 'report-only|%s\n' "$reasons"
    else
        printf 'auto-ok|未启动、无驻守\n'
    fi
}

# node-scan 输出的候选行: NODE <TAB> selector <TAB> leaf <TAB> ip <TAB> egress <TAB> udp
scan_nodes() {
    local raw tmp group="" selector="" current="" gate reason="" ip n=0
    local score verdict ptype detail cc leaf egress udp eligible why
    local best="" best_score=0 best_ip="" best_cc="" best_sel="" best_leaf="" best_band=""
    local cur_score=0 cur_ip="" delta=0 candidates=0 unique=0 eligible_n=0 unknown_n=0
    local epoch line
    [ -n "$PROXY_GROUP" ] || { echo "FAIL:未配置代理组,无法扫描节点" >&2; return 1; }
    # reject 策略下 UDP/3478 已在规则层 REJECT,节点支不支持 UDP 都不会泄漏。
    # 这时还拿「UDP 未标注」当硬门槛,会把用户正在用的 HTTP 节点和所有 HTTP
    # 候选一起排除 —— 与「一键修复」自动切 reject 的前提自相矛盾。
    local wpolicy="proxy"
    if [ -f "$BASE/webrtc-policy" ]; then
        wpolicy=$(tr -d ' \t\r\n' < "$BASE/webrtc-policy" 2>/dev/null)
        case "$wpolicy" in proxy|reject) ;; *) wpolicy=proxy ;; esac
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/node-scan.XXXXXX") || return 1
    raw="$tmp/raw"
    if ! clash_rules node-scan >"$raw" 2>"$tmp/err"; then
        echo "FAIL:读不到运行中的内核节点($(head -1 "$tmp/err" 2>/dev/null))" >&2
        rm -rf "$tmp"; return 1
    fi
    # 没有可手动目标时不是失败:把「这组由内核自动选路、成员是这几个」落成一条
    # 结论。报告里**不写** BEST / ELIGIBLE —— 一个候选都没比过,写 0 等于假装比过
    # (第 16 项会据 NOCHOICE 给结论,不会走到「没有过硬门槛的候选」那句)。
    if [ "$(awk -F'\t' 'NR==1{print $1}' "$raw")" = "NOCHOICE" ]; then
        local nc_group nc_type nc_members nc_chain nc_now
        nc_group=$(awk -F'\t' '$1=="NOCHOICE"{print $2; exit}' "$raw")
        nc_type=$(awk -F'\t' '$1=="NOCHOICE"{print $3; exit}' "$raw")
        nc_members=$(awk -F'\t' '$1=="NOCHOICE"{print $4; exit}' "$raw" | tr '|' '、')
        nc_chain=$(awk -F'\t' '$1=="CHAIN"{print $2; exit}' "$raw")
        nc_now=$(date +%s)
        if [ -n "${BASE:-}" ] && [ -d "$BASE" ]; then
            { printf 'EPOCH=%s\n' "$nc_now"
              printf 'NOCHOICE=1\n'
              printf 'NOCHOICE_GROUP=%s\n' "$nc_group"
              printf 'NOCHOICE_TYPE=%s\n' "$nc_type"
              printf 'NOCHOICE_MEMBERS=%s\n' "$nc_members"
              printf 'NOCHOICE_CHAIN=%s\n' "$nc_chain"
              printf 'SCAN_TIME=%s\n' "$(date '+%Y-%m-%d %H:%M')"
            } > "$NODE_SCAN_FILE.tmp" 2>/dev/null \
                && mv "$NODE_SCAN_FILE.tmp" "$NODE_SCAN_FILE" 2>/dev/null
        fi
        # node-apply 切完会静默重扫一次,那时不该把整段人话混进应用回执。
        if [ "${NODE_SCAN_QUIET:-0}" != "1" ]; then
            printf '无候选可切换:%s 是 %s 自动选路(成员:%s)\n' "$nc_group" "$nc_type" "$nc_members"
            printf '这条链上换节点等于换出口 IP,建议保持现状。\n'
        fi
        rm -rf "$tmp"; return 0
    fi
    grep -q '^SCANv1$' "$raw" || { echo "FAIL:节点枚举返回格式异常" >&2; rm -rf "$tmp"; return 1; }
    group=$(awk -F'\t' '$1=="GROUP"{print $2; exit}' "$raw")
    current=$(awk -F'\t' '$1=="CURRENT"{print $2; exit}' "$raw")
    selector=$(awk -F'\t' '$1=="NODE"{print $2; exit}' "$raw")

    # 按 IP 去重:本机 11 个叶子只对应 3 个出口,不去重就是 11 次无谓请求。
    awk -F'\t' '$1=="NODE" && $5=="known" && $4!="" {print $4}' "$raw" \
        | sort -u > "$tmp/ips"
    unique=$(wc -l < "$tmp/ips" | tr -d ' ')
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        n=$((n + 1))
        ( ip_purity "$ip" > "$tmp/p_$ip" 2>/dev/null ) &
        [ $((n % NODE_SCAN_PARALLEL)) -eq 0 ] && wait
    done < "$tmp/ips"
    wait

    : > "$tmp/ranked"
    while IFS=$'\t' read -r tag sel leaf ip egress udp; do
        [ "$tag" = "NODE" ] || continue
        candidates=$((candidates + 1))
        score=""; verdict=""; ptype=""; detail=""; cc=""; why=""; eligible=1
        case "$egress" in
            fronted) why="CDN 前置,出口未知"; eligible=0; unknown_n=$((unknown_n + 1)) ;;
            domain)  why="入口是域名,出口未知"; eligible=0; unknown_n=$((unknown_n + 1)) ;;
            missing) why="配置里没有 server"; eligible=0; unknown_n=$((unknown_n + 1)) ;;
            known)
                if [ -f "$tmp/p_$ip" ]; then
                    IFS='|' read -r score verdict ptype detail cc < "$tmp/p_$ip"
                fi
                case "$score" in
                    # 空分数不再是「取不到」,而是「未评级」这个合法结论(类型证据
                    # 缺失)。没有量出来的分就没法排名,不参与候选,但话要说对。
                    ''|*[!0-9]*) why="未评级(类型证据缺失)"; score=""; eligible=0 ;;
                esac ;;
            *) why="出口类型未知"; eligible=0 ;;
        esac
        if [ "$eligible" = 1 ]; then
            case "$verdict" in
                # 不再把所有 fail 一律叫「风险过高」:分数是信誉分,判定是硬门槛。
                # 68 分的代理/VPN 节点要写清「硬门槛:代理/VPN 特征(信誉 68 分,
                # 分数与判定分开)」,既解释高分为何被排除,也不给非代理的 fail 扣错帽子。
                fail) why="硬门槛:$(purity_fail_reason "$ptype" "${score:-}" "$verdict")"; eligible=0 ;;
            esac
        fi
        if [ "$eligible" = 1 ]; then
            if [ -z "$cc" ]; then
                why="国家待验证"; eligible=0
            elif [ -n "$COUNTRY_TARGET" ] && [ "$cc" != "$COUNTRY_TARGET" ]; then
                why="国家不符(${cc}≠${COUNTRY_TARGET})"; eligible=0
            fi
        fi
        if [ "$eligible" = 1 ] && [ "$udp" = "0" ] && [ "$wpolicy" != "reject" ]; then
            why="UDP 未标注"; eligible=0
        fi
        [ "$eligible" = 1 ] && eligible_n=$((eligible_n + 1))
        # 第 9 列是分数区间,给排名表一个参照系。放在最后,前面各列的
        # 序号和 sort 键都不受影响。
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${score:-}" "$eligible" "$leaf" "$ip" "$cc" "$verdict" "$why" "$sel" \
            "$(purity_band "${score:-}")" >> "$tmp/ranked"
        if [ "$leaf" = "$current" ]; then
            cur_ip="$ip"; cur_score="${score:-}"
        fi
    done < "$raw"
    # 当前节点没被枚举到(例如它挂在 URLTest 下)时,单独给它打一次分。
    if [ -n "$cur_ip" ] && [ -f "$tmp/p_$cur_ip" ]; then
        IFS='|' read -r score verdict ptype detail cc < "$tmp/p_$cur_ip"
        case "$score" in ''|*[!0-9]*) ;; *) cur_score="$score" ;; esac
    fi

    sort -t$'\t' -k2,2nr -k1,1nr "$tmp/ranked" > "$tmp/sorted"
    line=$(awk -F'\t' '$2==1 {print; exit}' "$tmp/sorted")
    local top_eligible=0
    if [ -n "$line" ]; then
        # 第 9 列(区间)必须有变量接住:read 的最后一个变量会吞掉剩余整段,
        # 少写一个就会把「优秀」拼进 BEST_SELECTOR,切节点时找不到那个名字。
        IFS=$'\t' read -r best_score eligible best_leaf best_ip best_cc verdict why best_sel best_band <<<"$line"
        top_eligible=$best_score
        # 当前节点没量出分数时没有比较基准 —— 拿 0 当基准会把「没查到」包装成
        # 「比当前高 N 分」,和「没查冒充查干净」是同一种错。建议整体清空,
        # 与 margin 不足走同一个出口。
        case "${cur_score:-}" in
            ''|*[!0-9]*) best_leaf=""; best_score=0; best_ip=""; best_cc=""; best_sel=""; delta=0 ;;
            *)
                delta=$((best_score - cur_score))
                # BEST 只表示「值得换」的那个节点。差距不够就把整组字段清空,
                # 别留一个 BEST= 空、BEST_IP 却有值的半截报告给界面读。
                if [ "$delta" -lt "$NODE_SCAN_MARGIN" ]; then
                    best_leaf=""; best_score=0; best_ip=""; best_cc=""; best_sel=""; delta=0
                fi ;;
        esac
    fi

    IFS='|' read -r gate reason <<<"$(node_gate)"
    # 门禁输出为空说明 node_gate 自己崩了(例如变量展开写错被 set -u 打断)。
    # 空门禁比报错更危险:界面读不到 GATE 只会静默不应用,没人知道判定其实没跑成。
    case "$gate" in
        report-only|auto-ok) ;;
        *) gate="unknown"; reason="${reason:-门禁判定失败}" ;;
    esac
    epoch=$(date +%s)
    # 「固定最优节点」落在同一份报告里,不新增检查项:当前节点是不是还等于
    # preferred-node,偏离就报警。校验只靠报告里的 CURRENT,不给 45 秒的
    # checkdetail 预算再加一次内核枚举。
    local pref="" pref_match=-1
    pref=$(preferred_node_leaf)
    if [ -n "$pref" ]; then
        if [ "$pref" = "$current" ]; then pref_match=1; else pref_match=0; fi
    fi
    {
        printf 'EPOCH=%s\n' "$epoch"
        # 给人看的时间戳。checkdetail 只读报告文件,拿不到扫描当时的本地时钟;
        # 用 EPOCH 再转一次要顾 BSD/GNU date 差异,不如写报告时直接落一份。
        printf 'SCAN_TIME=%s\n' "$(date '+%m-%d %H:%M')"
        printf 'GROUP=%s\n' "$group"
        printf 'SELECTOR=%s\n' "$selector"
        printf 'CURRENT=%s\n' "$current"
        printf 'CURRENT_SCORE=%s\n' "$cur_score"
        printf 'BEST=%s\n' "$best_leaf"
        printf 'BEST_SCORE=%s\n' "$best_score"
        printf 'BEST_IP=%s\n' "$best_ip"
        printf 'BEST_SELECTOR=%s\n' "$best_sel"
        printf 'DELTA=%s\n' "$delta"
        printf 'GATE=%s\n' "$gate"
        printf 'GATE_REASON=%s\n' "$reason"
        printf 'CANDIDATES=%s\n' "$candidates"
        printf 'UNIQUE_IPS=%s\n' "$unique"
        printf 'UNKNOWN=%s\n' "$unknown_n"
        printf 'ELIGIBLE=%s\n' "$eligible_n"
        printf 'PREFERRED=%s\n' "$pref"
        printf 'PREFERRED_MATCH=%s\n' "$pref_match"
        awk -F'\t' 'NR<=3 {printf "TOP%d=%s|%s|%s|%s|%s\n", NR, $3, $1, $5, $6, $7}' "$tmp/sorted"
    } > "$NODE_SCAN_FILE.tmp" 2>/dev/null && mv "$NODE_SCAN_FILE.tmp" "$NODE_SCAN_FILE"

    # node-apply 切完会静默重扫一次刷新报告,那时不该把整段人话混进应用回执。
    if [ "${NODE_SCAN_QUIET:-0}" != "1" ]; then
        echo "节点扫描(只读) · 组 $group · 控路 $selector"
        echo "扫描时间 $(date '+%Y-%m-%d %H:%M:%S')"
        # 当前分也带上区间:这是用户第一眼看的那行,只给数字仍然没有参照系。
        local cur_note=""
        case "${cur_score:-}" in
            ''|0|*[!0-9]*) ;;
            *) cur_note="($(purity_band "$cur_score"))" ;;
        esac
        if [ -n "${cur_score:-}" ]; then
            echo "当前 $current · 评分 ${cur_score}/100${cur_note}"
        else
            echo "当前 $current · 未评级(类型证据缺失)"
        fi
        echo "候选 $candidates 个 → 去重 $unique 个出口 · 过硬门槛 $eligible_n 个 · 出口未知 $unknown_n 个"
        echo "门禁:${gate}${reason:+($reason)}"
        if [ "$pref_match" = "1" ]; then
            echo "已固定节点:$pref(当前正在使用)"
        elif [ "$pref_match" = "0" ]; then
            echo "已偏离固定节点:$pref · 点「扫描可用节点」重新应用"
        fi
        if [ -n "$best_leaf" ]; then
            echo "建议:$best_leaf · $best_score 分 · 比当前高 $delta 分 · 出口 $best_ip/$best_cc"
        elif [ "$eligible_n" = 0 ]; then
            echo "没有过硬门槛的候选,不建议换节点"
        else
            # 只比「过硬门槛内」的候选。下面名单里那些分数更高但被硬门槛
            # 排除的,不能算进「更干净」,否则 68 分 vs 49 分看起来像自相矛盾。
            echo "过硬门槛内没有更优节点 · 合格最高 ${top_eligible} 分 / 当前 ${cur_score:-未评级} 分 · 差距 < ${NODE_SCAN_MARGIN} 分"
            local excluded_high
            excluded_high=$(awk -F'\t' -v cur="${cur_score:-0}" \
                '$2==0 && ($1+0)>(cur+0) {n++} END {print n+0}' "$tmp/sorted")
            if [ "$excluded_high" -gt 0 ]; then
                echo "另有 ${excluded_high} 个候选分数更高,但没过硬门槛(原因见下表),不参与比较"
            fi
        fi
        # 分数是宽口径 IP 信誉,不是「能不能开 Claude」。68 分的代理特征节点
        # 照样被硬门槛排除,49 分的机房反而可用 —— 用户看到的就是这个背离,
        # 所以区间和「先看哪一列」必须写在同一屏里。
        echo "口径:分数 = IP 信誉(90-100 优秀 · 75-89 良好 · 50-74 一般 · 30-49 偏差 · 0-29 差),不决定能不能用"
        local udp_gate_hint="、UDP 未标注"
        [ "$wpolicy" = "reject" ] && udp_gate_hint=" · 当前 reject 策略已直接拒绝 UDP,不查节点 UDP 支持"
        echo "读法:先看「可用/不可用」——由硬门槛决定(Tor/代理/VPN、机房转租段<30 分、信誉<50 分、国家不符${udp_gate_hint});没命中硬门槛的,分数低也仍然可用"
        # 全部候选,不是前 3 名。用户问「有没有具体内容」时,被排除的那些
        # 恰恰是最需要解释的:为什么 CDN 前置 / 国家不符 / UDP 没标注不能选。
        echo "--- 全部候选(可用优先,再按分数;含区间与排除原因) ---"
        awk -F'\t' '{printf "  %-52s %4s 分 %-6s %-3s  %-15s  %s\n", $3, $1, $9, $5, ($4=="" ? "出口未知" : $4), ($2==1 ? "可用" : ($7=="" ? "不可用" : $7))}' "$tmp/sorted"
        echo "报告:$NODE_SCAN_FILE"
        # 同一份键值也回给界面:App 就地更新「更优节点」那一行,不必整轮 refresh
        # (refresh 会先撤守护,只读扫描不该付这个代价)。
        echo "--- 报告键值 ---"
        cat "$NODE_SCAN_FILE"
    fi
    rm -rf "$tmp"
    return 0
}

# ---------- 应用最优节点(有副作用,受门禁) ----------
# 分工:node-scan 只读;只有这条命令会切线路。
# 守护不归脚本管 —— App 先 stopWatch() 再调这里,切完由 checkEnvironment
# 通过后自动 startWatch()。脚本自己去杀 App 持有的守护进程,会让 App 的
# watchProcess 收到「意外退出」而误报成守护断了,那是假故障。
#
# 门禁分两层,别混:
#   · node_gate()         报告门禁,保守并集(含「看门狗驻守」这个信号),用户选 A;
#   · node_apply_gate()   执行门禁,只按此刻的真实状态重新判定。看门狗不算
#                         「实例」,但必须**确实已经不在跑**才放行 —— 把那条
#                         从信号升级成事实,而不是放宽。
#
# 两层都不再看「存过几个槽位」。那条判据是死条件(见 node_gate 的注释),
# 留着等于让 node-apply 永久不可用。真正要防的是「有东西正在用这条出口」,
# 而槽位快照只是磁盘上的目录,不占用出口。
node_apply_gate() {
    local reasons="" pid="" i
    if claude_running; then
        reasons="Claude 正在运行"
    fi
    [ -n "$reasons" ] && { printf 'denied|%s\n' "$reasons"; return 0; }
    # stopWatch() 发完 SIGTERM 后 bash 可能还卡在 sleep 里,App 0.5s 后补 SIGKILL。
    # 给最多 3 秒等它退干净;pidfile 残留但进程已死,watch_pid_is_watchdog 会返回假。
    for i in 1 2 3 4 5 6; do
        pid=$(awk -F'\t' '{print $1; exit}' "$BASE/watch.pid" 2>/dev/null)
        if [ -z "$pid" ] || ! watch_pid_is_watchdog "$pid"; then
            printf 'allowed|未启动、无驻守\n'
            return 0
        fi
        sleep 0.5
    done
    printf 'denied|巡检仍在驻守,请先停止守护(或退出应用)\n'
}

node_apply() {
    lease_revoke
    # 可选参数:指定要切的叶子。槽位绑定走这条路 —— 「切到 B 就换 B 绑的那条线」,
    # 而不是「换成本次扫描分数最高的那条」。不给参数时维持原语义(用报告里的 BEST)。
    local want_leaf="${1:-}"
    local epoch now best="" best_score=0 best_ip="" best_sel="" selector="" current=""
    local gate reason tmp raw="" original="" now_leaf="" trace loc="" ip_after="" i verified=0
    [ -f "$NODE_SCAN_FILE" ] || { echo "FAIL:还没有扫描报告,请先运行 node-scan" >&2; return 1; }
    epoch=$(sed -n 's/^EPOCH=//p' "$NODE_SCAN_FILE" | head -1)
    now=$(date +%s)
    case "${epoch:-}" in ''|*[!0-9]*) epoch=0 ;; esac
    [ $((now - epoch)) -le "$NODE_SCAN_TTL" ] || {
        echo "FAIL:扫描报告已过期,请先重新扫描" >&2; return 1; }
    selector=$(sed -n 's/^SELECTOR=//p' "$NODE_SCAN_FILE" | head -1)
    current=$(sed -n 's/^CURRENT=//p' "$NODE_SCAN_FILE" | head -1)
    if [ -n "$want_leaf" ]; then
        # 绑定节点没有「分数」这回事,分数只用于「谁更值得换」的比较。
        best="$want_leaf"
        best_sel="$selector"
        best_ip=""
    else
        best=$(sed -n 's/^BEST=//p' "$NODE_SCAN_FILE" | head -1)
        [ -n "$best" ] || { echo "FAIL:当前没有值得切换的更优节点,无需应用" >&2; return 1; }
        best_score=$(sed -n 's/^BEST_SCORE=//p' "$NODE_SCAN_FILE" | head -1)
        best_ip=$(sed -n 's/^BEST_IP=//p' "$NODE_SCAN_FILE" | head -1)
        best_sel=$(sed -n 's/^BEST_SELECTOR=//p' "$NODE_SCAN_FILE" | head -1)
    fi
    [ -n "$best_sel" ] || best_sel="$selector"
    [ -n "$best_sel" ] || { echo "FAIL:报告里没有可用的 Selector,请重新扫描" >&2; return 1; }

    # 不信报告里的 GATE:它是扫描那一刻的快照。此刻重新判一次,才不会
    # 拿一份旧报告在用户已经开起 Claude 之后偷偷换线路。
    IFS='|' read -r gate reason <<<"$(node_apply_gate)"
    [ "$gate" = "allowed" ] || {
        echo "FAIL:当前有实例在用,按约定只出报告($reason)" >&2; return 1; }

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/node-apply.XXXXXX") || return 1
    raw="$tmp/raw"
    if ! clash_rules node-scan >"$raw" 2>"$tmp/err"; then
        echo "FAIL:读不到运行中的内核节点($(head -1 "$tmp/err" 2>/dev/null))" >&2
        rm -rf "$tmp"; return 1
    fi
    original=$(awk -F'\t' '$1=="CURRENT"{print $2; exit}' "$raw")
    [ -n "$original" ] || original="$current"
    # 订阅可能已经更新过:候选必须仍是这个 Selector 的叶子,否则 PUT 会失败,
    # 更糟的是切到一个已经不存在的名字上。
    if ! awk -F'\t' -v s="$best_sel" -v l="$best" \
         '$1=="NODE" && $2==s && $3==l {hit=1} END{exit !hit}' "$raw"; then
        echo "FAIL:候选节点已不在内核里(订阅可能更新过),请重新扫描" >&2
        rm -rf "$tmp"; return 1
    fi
    # 绑定节点时报告里没有它的 IP,从内核枚举里补一条,好让 PREFERRED 记全。
    if [ -z "$best_ip" ]; then
        best_ip=$(awk -F'\t' -v s="$best_sel" -v l="$best" \
                  '$1=="NODE" && $2==s && $3==l {print $4; exit}' "$raw")
    fi

    echo "切换:$original → $best (Selector $best_sel)"
    if ! clash_rules node-select "$best_sel" "$best" >"$tmp/out" 2>&1; then
        echo "FAIL:内核拒绝切换($(head -1 "$tmp/out"))" >&2
        rm -rf "$tmp"; return 1
    fi

    # PUT 成功不等于生效:URLTest / Fallback 会自己把选择覆盖回去。
    # 先读内核的 now 确认落在目标叶子上,再等真实出口换成目标国家。
    now_leaf=$(clash_rules node-scan 2>/dev/null \
        | awk -F'\t' '$1=="CURRENT"{print $2; exit}')
    if [ "$now_leaf" = "$best" ]; then
        for i in 1 2 3 4 5; do
            trace=$(curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
            loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -1)
            ip_after=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
            if [ -n "$loc" ] && { [ -z "$COUNTRY_TARGET" ] || [ "$loc" = "$COUNTRY_TARGET" ]; }; then
                verified=1; break
            fi
            sleep 2
        done
    fi
    if [ "$verified" != 1 ]; then
        if [ -n "$original" ]; then
            if clash_rules node-select "$best_sel" "$original" >/dev/null 2>&1; then
                echo "已回滚到 $original"
            else
                echo "WARN:回滚失败,请手动切回 $original" >&2
            fi
        fi
        echo "FAIL:切换后未能确认 $COUNTRY_TARGET 出口(内核当前 ${now_leaf:-未知},loc=${loc:-未知}),未固定节点" >&2
        rm -rf "$tmp"; return 1
    fi

    # 固定下来:后续检查靠 PREFERRED_MATCH 发现「有人把节点改回去了」。
    printf '%s\t%s\t%s\t%s\n' "$best_sel" "$best" "$best_ip" "$(date +%s)" \
        > "$PREFERRED_NODE_FILE.tmp" 2>/dev/null \
        && mv "$PREFERRED_NODE_FILE.tmp" "$PREFERRED_NODE_FILE"
    if [ -n "$best_score" ]; then
        echo "OK:已应用并固定 $best($best_score 分) · 出口 ${ip_after:-未知}/${loc:-未知}"
    else
        echo "OK:已应用并固定 $best · 出口 ${ip_after:-未知}/${loc:-未知}"
    fi
    echo "已建立的连接不会迁移;启动 Claude 前请在客户端确认线路"
    # 静默重扫:刷新 CURRENT / 门禁 / PREFERRED_MATCH,让「更优节点」立刻落成真值。
    NODE_SCAN_QUIET=1 scan_nodes >/dev/null 2>&1 || true
    echo "APPLY=OK"
    echo "APPLIED=$best"
    echo "--- 报告键值 ---"
    cat "$NODE_SCAN_FILE"
    rm -rf "$tmp"
    return 0
}

# ---------- 槽位 ↔ 节点绑定 ----------
# 一个槽位一套环境的最小可行做法:数据目录分开之外,出口也分开。
# 存 selector<TAB>leaf<TAB>epoch;切槽位时 App 读它,再用 node-apply <leaf> 切过去。
# 不存分数:分数是「谁更值得换」的比较结果,绑定是「就是这条」的声明。
slot_node_show() {
    local f="$SLOT_NODE_DIR/${1:-}"
    [ -n "${1:-}" ] && [ -f "$f" ] || { echo "NONE"; return 0; }
    awk -F'\t' 'NF>=2 && $2!="" {print; found=1; exit} END{if(!found) print "NONE"}' "$f"
}

slot_node_list() {
    local a line
    for a in A B C D; do
        line=$(slot_node_show "$a")
        [ "$line" = "NONE" ] || printf '%s\t%s\n' "$a" "$line"
    done
}

slot_node_set() {
    local slot="${1:-}" leaf="${2:-}" sel="${3:-}"
    valid_account "$slot" || return 1
    [ -n "$leaf" ] || { echo "FAIL:要指定节点名"; return 1; }
    if [ -z "$sel" ]; then
        [ -f "$NODE_SCAN_FILE" ] || { echo "FAIL:还没有扫描报告,请先运行 node-scan"; return 1; }
        sel=$(sed -n 's/^SELECTOR=//p' "$NODE_SCAN_FILE" | head -1)
    fi
    [ -n "$sel" ] || { echo "FAIL:报告里没有可用的 Selector,请先 node-scan"; return 1; }
    mkdir -p "$SLOT_NODE_DIR" || return 1
    printf '%s\t%s\t%s\n' "$sel" "$leaf" "$(date +%s)" > "$SLOT_NODE_DIR/$slot.tmp" \
        && mv "$SLOT_NODE_DIR/$slot.tmp" "$SLOT_NODE_DIR/$slot" \
        || { echo "FAIL:写入绑定失败"; return 1; }
    lease_revoke
    echo "OK:账号$slot 已绑定节点 $leaf"
}

slot_node_clear() {
    local slot="${1:-}"
    valid_account "$slot" || return 1
    rm -f "$SLOT_NODE_DIR/$slot"
    lease_revoke
    echo "OK:已解除账号$slot 的节点绑定"
}

# 保留隐藏入口供安装器调用;现在生成全局 Script.js 并迁移旧管理块。
write_merge_rules() { clash_rules write; }
flclash_repair() {
    "${BASH:-/bin/bash}" "$0" flclash-repair "$@"
}

fix_flclash() {
    local dir="$HOME/Library/Application Support/com.follow.clash"
    local result backup trace ip wr i
    [ -d "$dir" ] || { echo "FIX:FlClash 配置目录不存在，无法自动修复"; return 1; }
    if pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1; then
        osascript -e 'tell application "FlClash" to quit' >/dev/null 2>&1
        for i in $(seq 1 15); do
            pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1 || break
            sleep 1
        done
    fi
    if pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1; then
        echo "FIX:FlClash 未能退出，请手动退出后重试"
        return 1
    fi
    if ! result=$(flclash_repair repair "$dir" "$PROXY_GROUP" 2>&1); then
        echo "$result"
        echo "FIX:FlClash 未修改配置"
        return 1
    fi
    backup=$(printf '%s\n' "$result" | sed -n 's/^BACKUP=//p' | head -1)
    [ -n "$backup" ] || { echo "FIX:FlClash 未生成有效备份，已中止"; return 1; }
    open -a "FlClash"
    for i in $(seq 1 30); do
        if proxy_alive && tun_up; then break; fi
        sleep 1
    done
    sleep 2
    if route_ok; then
        trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
        wr=$(webrtc_status "$ip")
        case "$wr" in
            ok:*) echo "FIX:FlClash 域名与 STUN 规则已生效 ✓"; return 0 ;;
            warn:*) echo "FIX:FlClash 规则已写入，但 STUN 状态未确认($wr)"; return 0 ;;
        esac
    fi
    osascript -e 'tell application "FlClash" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1 || break
        sleep 1
    done
    local rollback_result
    if ! rollback_result=$(flclash_repair rollback "$dir" "$backup" 2>&1); then
        echo "$rollback_result"
        echo "FIX:FlClash 回滚失败，请手动恢复备份 $backup"
        return 1
    fi
    open -a "FlClash"
    echo "FIX:FlClash 验证失败，已回滚；请检查 fake-IP、代理组及节点 UDP 支持"
    return 1
}

# 保镖 plist 的内置副本(base64)。
# 为什么不从 ~/.local/bin 拷:那是用户可写目录,同用户进程可以把
# ProgramArguments 改成任意路径,等用户批准「一键修复」的管理员授权后以 root
# 执行。这里从脚本自身带的内容生成,不再信任用户目录里的文件。
# tests/test_daemon_contracts.py 会校验它和 daemons/local.claude-bodyguard.plist 一致。
bodyguard_plist_b64() {
    cat <<'B64'
PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHBsaXN0IFBVQkxJQyAiLS8vQXBwbGUvL0RURCBQTElTVCAxLjAvL0VOIiAiaHR0cDovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+CjwhLS0gbGF1bmNoZCDmqKHmnb86IOWuieijheWIsCAvTGlicmFyeS9MYXVuY2hEYWVtb25zO+iEmuacrOWcqCByb290IOaJgOacieeahCAvTGlicmFyeS9BcHBsaWNhdGlvbiBTdXBwb3J0L2NsYXVkZS1zd2l0Y2hlci8g5LiLKOeUqOaIt+aAgeS4jeWPr+WGmSzpmLLmj5DmnYMpIC0tPgo8cGxpc3QgdmVyc2lvbj0iMS4wIj48ZGljdD4KCTxrZXk+TGFiZWw8L2tleT48c3RyaW5nPmxvY2FsLmNsYXVkZS1ib2R5Z3VhcmQ8L3N0cmluZz4KCTxrZXk+UHJvZ3JhbUFyZ3VtZW50czwva2V5PjxhcnJheT48c3RyaW5nPi9iaW4vYmFzaDwvc3RyaW5nPjxzdHJpbmc+L0xpYnJhcnkvQXBwbGljYXRpb24gU3VwcG9ydC9jbGF1ZGUtc3dpdGNoZXIvY2xhdWRlLWJvZHlndWFyZC5zaDwvc3RyaW5nPjwvYXJyYXk+Cgk8a2V5PlN0YXJ0SW50ZXJ2YWw8L2tleT48aW50ZWdlcj4xMDwvaW50ZWdlcj4KCTxrZXk+UnVuQXRMb2FkPC9rZXk+PHRydWUvPgo8L2RpY3Q+PC9wbGlzdD4K
B64
}

# POSIX 单引号转义,给要拼进 `do shell script` 的值用。
# 不能直接用 "$TZ_TARGET":env.json 虽已校验 IANA 形状,但这里仍按不可信输入处理。
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# 一键修复:按项自动修复,每步输出结果
fix() {
    # 只有真的重启过客户端才需要在收尾复测前等路由收敛,见 C 段。
    local just_reloaded=0
    if [ "$PROXY_MODE" = "flclash" ]; then
        fix_flclash || return 1
    fi
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        local policy_result
        if ! policy_result=$(clash_rules policy 2>&1); then
            echo "FIX:WebRTC 策略无效 ✗ $policy_result"
            # 解释器没找到时 policy 的报错是「python3: command not found」;
            # 光把它塞进上面那行,用户还是不知道要装什么。这里给一句能照做的。
            # 刻意不调用顶层函数:fix() 会被测试单独抽出来跑,外部函数不存在。
            case "$policy_result" in
                *python3*|*"command not found"*)
                    echo "FIX:本机缺少可用的 python3;请在终端运行 xcode-select --install 后重试" ;;
            esac
            echo "FIX:修复在前置校验阶段退出,后面的项目一项都没动;请导出诊断日志或跑 diagnose-fix.sh"
            return 1
        fi
        WEBRTC_POLICY="$policy_result"
        # 当前节点不支持 UDP 时,proxy 策略根本无法成立:verify 会直接 fail,
        # 一键修复走到 write_merge_rules 也会因同一道 validate_group 立刻 return 1
        # (客户端日志里就是 fix exit=1 duration_ms=0)。旧文案让用户「改用 reject
        # 策略」,却没有入口可改。这里先把策略落盘,后面写规则/校验就都走 reject:
        # UDP 流量直接 REJECT,仍然不泄漏,门禁没有放松,只是换了一条能走通的路。
        if [ "$WEBRTC_POLICY" = "proxy" ]; then
            local udp_err
            if ! udp_err=$(clash_rules verify 2>&1); then
                case "$udp_err" in
                    *未确认支持*UDP*)
                        set_webrtc_policy reject >/dev/null
                        WEBRTC_POLICY=reject
                        echo "FIX:当前节点不支持 UDP · 已把 WebRTC 策略切为 reject(UDP 直接拒绝,不会泄漏)"
                        ;;
                esac
            fi
        fi
    fi
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! pgrep -f verge-mihomo >/dev/null 2>&1; then
            echo "FIX:正在启动 Clash Verge..."
            open -a "Clash Verge"
        fi
        for i in $(seq 1 40); do
            pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up && break
            sleep 1
        done
        if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            V="$CLASH_DIR/verge.yaml"
            if [ -f "$V" ] && grep -q '^enable_tun_mode: false' "$V"; then
                echo "FIX:检测到 TUN 开关被关闭,正在恢复..."
                quit_clash_verge
                sed -i '' 's/^enable_tun_mode: false/enable_tun_mode: true/' "$V"
                open -a "Clash Verge"
                for i in $(seq 1 40); do
                    tun_up && break
                    sleep 1
                done
            fi
            if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
                echo "FIX:代理内核+TUN ✓(已恢复TUN开关)"
            else
                echo "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"
            fi
        fi
    else
        app=$(proxy_app_name)
        if ! proxy_alive && [ -n "$app" ]; then
            echo "FIX:正在启动 $app..."
            open -a "$app" >/dev/null 2>&1
        fi
        for i in $(seq 1 40); do
            proxy_alive && tun_up && break
            sleep 1
        done
        if proxy_alive && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            echo "FIX:代理内核/TUN ✗(请打开 $(proxy_name) 手动检查节点/线路及TUN模式)"
        fi
    fi

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(tz_current)
    v6=$(ipv6_on_services)
    adminCmds=""
    [ "$tz" != "$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $(shq "$TZ_TARGET"); "
    # 逐条服务关 IPv6。只关 Wi-Fi 会漏掉 Ethernet/iPhone USB,检查项也就跟着漏报。
    if [ -n "$v6" ]; then
        while IFS= read -r svc; do
            [ -n "$svc" ] && adminCmds="${adminCmds}networksetup -setv6off '$svc'; "
        done <<< "$v6"
    fi
    # 看门狗是「修完能留住」的唯一保障。它守着旧目标时,上面这行改完 5 分钟内就被改回去,
    # 用户看到的就是「一键修复没生效」——所以必须和系统时区在同一次授权里一起对齐。
    wt=$(tz_watchdog_target)
    if [ -n "$wt" ] && [ "$wt" != "$TZ_TARGET" ]; then
        adminCmds="${adminCmds}/usr/bin/sed -i '' 's|^TARGET=.*|TARGET='$(shq "$TZ_TARGET")'|' '/Library/Application Support/claude-switcher/tz-watchdog.sh'; "
    fi
    # 装了 plist 却没 bootstrap(重装/系统升级后常见)时,看门狗是死的,一并拉起来
    if [ -f /Library/LaunchDaemons/local.tz-watchdog.plist ] && ! launchctl print system/local.tz-watchdog >/dev/null 2>&1; then
        adminCmds="${adminCmds}launchctl bootstrap system /Library/LaunchDaemons/local.tz-watchdog.plist; "
    fi
    # 这里原来还有一行 `echo "$v6" | grep -qi 'off' || adminCmds="…networksetup -setv6off Wi-Fi"`。
    # 删掉，因为它是**恒真**的：$v6 是「IPv6 还开着的服务列表」，列表里永远不会出现
    # 字面量 "off"（关掉的服务根本不会进这个列表），所以 grep 恒不匹配，`||` 恒执行。
    # 后果不是「多关一次 Wi-Fi」，而是 adminCmds 永远非空 → **每次点修复都弹一次
    # 管理员密码框**，哪怕一项都不用改（本机实测：v6 列表为空，照样弹）。
    # 用户看到的就是「点了修复半天没反应」—— 卡在授权框上，没输入就等到超时。
    # 逐条服务关 IPv6 上面那段 while 已经做了，包括 Wi-Fi，这一行本来就多余。
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        bg_b64=$(bodyguard_plist_b64)
        adminCmds="${adminCmds}printf '%s' '$bg_b64' | /usr/bin/base64 -D > '/Library/LaunchDaemons/local.claude-bodyguard.plist' && chmod 644 '/Library/LaunchDaemons/local.claude-bodyguard.plist' && chown root:wheel '/Library/LaunchDaemons/local.claude-bodyguard.plist' && launchctl bootstrap system '/Library/LaunchDaemons/local.claude-bodyguard.plist'; "
    fi
    if [ -n "$adminCmds" ]; then
        adminCmds="${adminCmds}dscacheutil -flushcache; killall -HUP mDNSResponder"
        echo "FIX:修复时区/IPv6/保镖(需要密码)..."
        if osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "一键修复需要管理员权限" with administrator privileges
ASEOF
        then
            echo "FIX:时区/IPv6/保镖 ✓"
        else
            echo "FIX:时区/IPv6/保镖 ✗(取消或失败)"
        fi
    else
        echo "FIX:时区/IPv6/保镖 无需修复 ✓"
    fi
    # DNS 这里只刷新了缓存,并没有改变解析路径 —— 不能跟着一起打勾。
    # 真没走隧道时必须明说「这项修不了」,否则用户看到「修复完成」却还是红叉。
    if ! check_disabled "DNS"; then
        dnsnow=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsnow" in
            "$FAKE_PREFIX"*) ;;
            *) echo "FIX:DNS 未走隧道(${dnsnow:-空}) · 一键修复改不了这项,请在客户端里把 DNS 设为隧道/DoH" ;;
        esac
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B4. 地区格式(用户级,无需密码)
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" != "$LOCALE_TARGET" ]; then
        defaults write -g AppleLocale "$LOCALE_TARGET"
        echo "FIX:地区格式 → $LOCALE_TARGET ✓"
    fi

    # B2. 更新全局脚本并检查运行规则;写入失败或未加载均不能报成功。全局模式下规则不适用。
    if [ "$PROXY_MODE" = "clash-verge" ] && [ "$(clash_mode)" = "global" ]; then
        echo "FIX:全局模式,置顶规则不适用(全部流量已走代理) ✓"
    elif [ "$PROXY_MODE" = "clash-verge" ]; then
        # 先自愈组名:订阅更新整份覆盖配置后,env.json 的组名可能已不存在,
        # 规则写入与校验会永远失败。换到现存最优组后再写,否则修复是死循环。
        if ensure_proxy_group; then
            if [ "$GROUP_RESELECTED" = "1" ]; then
                echo "FIX:原代理组已不存在(常见于订阅更新换组名)· 已自动切换到 $PROXY_GROUP ✓"
            fi
        else
            echo "FIX:读取内核代理组失败,组名校验跳过(若修复仍失败请检查客户端是否在线)"
        fi
        echo "FIX:写入全局扩展脚本(保留已有 main 与无关配置)..."
        local rules_result verify_err need_reload=0 dns_changed=0
        # DNS 上游体检:泄露架构(fallback 并发/明文上游/国内递归解析海外)当场修。
        # 托管块进 Merge.yaml(全局 merge,订阅更新覆盖后仍生效),与置顶规则互不干扰。
        local dns_issues dns_result
        if dns_issues=$(dns_audit 2>/dev/null); then
            echo "FIX:DNS 上游存在泄露架构($dns_issues)"
            if dns_result=$(write_dns_merge 2>&1); then
                echo "FIX:DNS 修复块 ✓ $dns_result"
                dns_changed=1
            else
                echo "FIX:DNS 修复块 ✗ $dns_result"
            fi
        fi
        if ! rules_result=$(write_merge_rules 2>&1); then
            echo "FIX:置顶规则 ✗ $rules_result"
            return 1
        fi
        case "$rules_result" in
            *无变化*)
                # 「配置文件没变」≠「运行中的内核已经加载了它」。客户端冷启动、
                # TUN 重建、Merge/Script 被临时关掉时,文件是对的而 /rules 里
                # UDP 3478 规则没置顶。旧逻辑在这里直接打勾跳过重启,收尾
                # webrtc_status 的 verify 又必然失败,于是「规则已是最新 ✓」和
                # 「UDP 3478 规则没置顶 ✗ · 点「一键修复」」永远同时出现,
                # 用户再点几次都停在原地。先问一次内核,只有它也认了才省下重启。
                if verify_err=$(clash_rules verify 2>&1); then
                    if [ "$dns_changed" -eq 1 ]; then
                        # DNS 修复块必须重启内核才生效,「无变化」的规则文件救不了它。
                        echo "FIX:DNS 修复块已写入,正在重启客户端使 DNS 生效..."
                        need_reload=1
                    else
                        # 重启不是免费的:内核重起、TUN 重建那十几秒里所有走 TUN 的
                        # 请求都会失败,而 fix 后面紧跟着就用 curl 验 WebRTC 和出口。
                        echo "FIX:置顶规则 ✓ 规则与内核都已就绪,未重启客户端"
                    fi
                else
                    case "$verify_err" in
                        *未按策略置顶*)
                            echo "FIX:配置没变但内核未加载规则,正在重启客户端..."
                            need_reload=1 ;;
                        *)
                            # 节点不支持 UDP / 不在 rule 模式 / 代理组不对 / 控制接口
                            # 读不到:这些重启也解决不了,别让用户白等一次 TUN 重建。
                            echo "FIX:置顶规则 ⚠ 内核校验未通过且重启无法解决:$verify_err" ;;
                    esac
                fi ;;
            *) need_reload=1 ;;
        esac
        if [ "$need_reload" -eq 1 ]; then
            just_reloaded=1
            quit_clash_verge
            # 客户端退出后再补注册:运行中改 profiles.yaml 会被它退出时写回覆盖。
            # Clash Verge 以 profiles.yaml 的 item 为索引,缺 `uid: Script` 时
            # Script.js 写了也不会被加载 —— 重启多少次内核里都没有置顶规则。
            clash_rules register-script >/dev/null 2>&1 || true
            open -a "Clash Verge"
            for i in $(seq 1 40); do tun_up && break; sleep 1; done
            local loaded=0
            # 15 次 × 1 秒:内核起来 + 加载全局脚本 + 建 TUN,实测最慢要 8~10 秒。
            # 原来只等 5 次,冷启动时必红 —— 而那正是用户最想让它成功的时候。
            for i in $(seq 1 15); do
                if rules_result=$(clash_rules verify 2>&1); then loaded=1; break; fi
                sleep 1
            done
            if [ "$loaded" -ne 1 ]; then
                echo "FIX:置顶规则 ✗ 未验证内核加载:$rules_result"
                # 失败原因直接写进日志:下次导出诊断就能定位,不用再让用户跑命令。
                local sjs="$CLASH_DIR/profiles/Script.js" managed=0
                [ -f "$sjs" ] && managed=$(grep -c 'claude-switcher managed rules' "$sjs" 2>/dev/null) || managed=0
                if [ -f "$sjs" ]; then
                    echo "FIX:诊断:Script.js $(wc -c < "$sjs" | tr -d ' ') 字节,管理块 ${managed:-0} 处"
                else
                    echo "FIX:诊断:Script.js 不存在"
                fi
                if [ -f "$CLASH_DIR/profiles.yaml" ] && grep -qE '^[[:space:]]*-[[:space:]]*uid:[[:space:]]*Script[[:space:]]*$' "$CLASH_DIR/profiles.yaml"; then
                    echo "FIX:诊断:profiles.yaml 已注册 uid:Script"
                else
                    echo "FIX:诊断:profiles.yaml 未注册 uid:Script —— Clash Verge 不会加载 Script.js"
                fi
                echo "FIX:诊断:Clash Verge 版本 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo 未知)"
                echo "FIX:请检查全局扩展脚本是否启用、代理组是否存在，以及节点 UDP 支持"
                return 1
            fi
            echo "FIX:置顶规则 ✓ 已验证内核实际加载"
            # DNS 修复块经重启后必须真正生效:运行配置重新生成后再审一次。
            if [ "$dns_changed" -eq 1 ]; then
                sleep 2
                if dns_issues=$(dns_audit 2>/dev/null); then
                    echo "FIX:DNS ⚠ 重启后运行配置仍是泄露架构($dns_issues)"
                else
                    echo "FIX:DNS ✓ 重启后上游架构已审计通过"
                fi
            fi
        fi
    elif [ "$PROXY_MODE" != "flclash" ] && ! route_ok; then
        echo "FIX:置顶规则 ✗ 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
    fi

    # C. 复测与日常审计共用判断，空结果、非零退出及无响应不会冒充代理成功。
    local fix_failed=0
    # 打三枪,但每枪 5 秒,并且**看懂空枪的原因再决定要不要接着打**。
    #
    # 原来的写法是无条件三枪、每枪 --max-time 8、枪间 sleep 3:节点没有 IPv4 出口时
    # (实测:出口是 v6,STUN 只回 v4),每一枪都要把 8 秒超时**走满**,
    # 三枪加两次 sleep = 30 秒。这段时间界面上只有一行「修复中」不动,
    # 用户读成「点了半天没修好」—— 而那正是它本来想解决的那个病。
    #
    # 现在三种空枪分开处理:
    #   rc 28(超时)  → 链路是黑洞,再打还是同一个 5 秒,直接认;
    #   TUN 起来了    → 这条线路根本没有 v4 出口,等也没用,直接认;
    #   TUN 没起来    → 内核在启动,这是唯一值得等的情况,隔 2 秒再打。
    #
    # 注意这里必须是 `tun_up && break`。写成 `tun_up || break` 会把两件事**做反**:
    # TUN 起来的连打三枪、没起来的立刻放弃 —— 实测就是这个形状
    # (起着的 6.5 秒,没起的 0.17 秒),正好是我们要的反面。
    local wrip="" trace="" rc=0 settle
    # 刚重启过客户端时,内核起来了、TUN 也在,但默认路由还要几秒才真正把流量
    # 送出去 —— tun_up 为真并不等于出口能通。实测 1.8.2-dev 的 fix 在这个窗口
    # 里拿到空 trace,于是收尾报「WebRTC ✗ 未获取有效 IPv4 出口 / 出口IP ✗ 无」
    # 并 exit=1,可规则其实已经写入并验证加载了(随后单独跑 checkdetail 两项全绿)。
    # 用户看到的就是「修复不成功」。只在这条确实重启过的路径上等;没改配置、
    # 没重启时一次请求都不多发,原来的三枪逻辑原样保留。
    if [ "$just_reloaded" -eq 1 ]; then
        for i in 1 2 3 4; do
            settle=$(curl -s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
            if printf '%s' "$settle" | grep -q '^ip='; then trace="$settle"; break; fi
            sleep 2
        done
    fi
    for i in 1 2 3; do
        if [ -z "$(printf '%s' "$trace" | grep '^ip=')" ]; then
            trace=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
            rc=$?
        fi
        wrip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
        [ -n "$wrip" ] && break
        [ "$rc" -eq 28 ] && break
        tun_up && break
        sleep 2
    done
    wr=$(webrtc_status "$wrip")
    case "$wr" in
        ok:*)   echo "FIX:WebRTC ✓ ${wr#ok:}" ;;
        # ⚠ 是第三档,不是 ✗:脚本跑完了,但这一项**没有可比对的对象**
        # (STUN 探针只回 IPv4,而这条线路是 v6 出口)。用 ✗ 会让界面把它
        # 打成红色「需手动」,而用户根本没有任何手动动作可做。
        warn:*) echo "FIX:WebRTC ⚠ ${wr#warn:}" ;;
        *)      local hint="${wr#fail:}"
                case "$hint" in
                    *规则没置顶*|*内核缺少*)
                        # 这行是刚刚那次「一键修复」的收尾;再叫用户点一次同一个
                        # 按钮,等于把「修不好」做成一个无限循环。指向真能动手的地方。
                        hint="${hint% · 点「一键修复」*} · 请在 $(proxy_name) 里确认全局扩展脚本已启用" ;;
                esac
                echo "FIX:WebRTC ✗ $hint"; fix_failed=1 ;;
    esac

    # D. 出口IP最终验证 —— 优先用刚刚那一枪的 trace,不再重打一次。
    # 这一段原来是 `sleep 2` + 再 curl 一遍(--max-time 8):同样的请求两秒内发两次,
    # 打空时白花 8 秒。中间只隔了 webrtc_status 的探针,它不改路由。
    if [ -z "$(echo "$trace" | grep '^ip=')" ]; then
        trace=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    fi
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET) — 可能是节点故障,请到 $(proxy_name) 里换条线路"
    fi
    echo "FIX:修复流程结束"
    return "$fix_failed"
}

# 更换代理客户端:改写已安装脚本头部的 PROXY_MODE(用于安装后换客户端/装错客户端)
set_client() {
    mode="${1:-}"
    case "$mode" in
        clash-verge|flclash|shadowrocket|sing-box|clashx|surge|auto) ;;
        *) echo "FAIL:用法: claude-switch.sh set-client <clash-verge|flclash|shadowrocket|sing-box|clashx|surge|auto>"; return 1 ;;
    esac
    target="${CLAUDE_SWITCHER_CORE:-}"
    if [ -z "$target" ]; then
        if [ -f "$HOME/.local/bin/claude-switch.sh" ] && [ -w "$HOME/.local/bin/claude-switch.sh" ]; then
            target="$HOME/.local/bin/claude-switch.sh"
        else
            target="$0"
        fi
    fi
    # 环境值写 env.json,不再用 sed 改写核心脚本:
    # 改写会让安装产物 ≠ 发布产物,SHA256 校验与自动更新都得为它让步。
    "${BASH:-/bin/bash}" "$target" _support env-set "proxy_mode=$mode" >/dev/null 2>&1 || { echo "FAIL:环境配置写入失败($ENV_FILE)"; return 1; }
    [ "$("${BASH:-/bin/bash}" "$target" _support env 2>/dev/null | sed -n 's/^proxy_mode=//p')" = "$mode" ] || { echo "FAIL:环境配置校验失败($ENV_FILE)"; return 1; }
    PROXY_MODE="$mode"
    echo "OK:代理客户端已设为 $mode"
    guard_state=$(bodyguard_status)
    case "$guard_state" in
        fail:未安装) echo "INFO:保镖尚未安装,checkdetail 会提示未安装" ;;
        fail:*) echo "WARN:保镖校验未通过(${guard_state#fail:});请重新运行安装器同步 root 守护脚本(需管理员权限),完成前不要启动 Claude" ;;
    esac
    echo "INFO:重新运行 checkdetail 生效;非 Clash 客户端请在应用内自行添加 Claude 域名置顶规则"
    return 0
}

# 只读输出当前代理客户端(供 UI 下拉高亮),同时列出全部支持项
get_client() {
    echo "client=$PROXY_MODE"
    echo "clients=clash-verge,flclash,shadowrocket,sing-box,clashx,surge"
}

# 地区自适应:按当前出口国家一键重设 国家/时区/地区格式(换了国家节点后运行)
set_region() {
    local geo gfile ctry ntz src nlocale rc
    gfile=$(mktemp "${TMPDIR:-/tmp}/claude-geo.XXXXXX" 2>/dev/null) || gfile=""
    GEO_DIAG_FILE="$gfile"
    geo=$(geo_lookup); rc=$?
    if [ -n "$gfile" ]; then
        GEO_DIAG=$(tr '\n' ';' < "$gfile" 2>/dev/null | sed 's/;$//')
        rm -f "$gfile"
    else
        GEO_DIAG=""
    fi
    unset GEO_DIAG_FILE
    if [ "$rc" -ne 0 ] || [ -z "$geo" ] || [ "${geo%%|*}" = "" ]; then
        echo "FAIL:所有出口探测源均失败(${GEO_DIAG:-无诊断信息})"
        echo "INFO:请确认代理已开启;若代理规则把 ipinfo/ipapi 判直连,可改为手动设置或稍后重试"
        return 1
    fi
    ctry=${geo%%|*}; geo=${geo#*|}
    ntz=${geo%%|*}; src=${geo#*|}
    if [ "$ctry" = "CN" ]; then
        echo "FAIL:出口国家为 CN(来源 $src),已中止;请先切换节点再重试"
        return 1
    fi
    [ -n "$ntz" ] || ntz=$(default_tz_for "$ctry")
    [ "$src" = "cloudflare" ] && echo "INFO:时区使用国家默认(可手动改)"
    nlocale=$(locale_for "$ctry")

    # 地区目标写 env.json(环境层),不再 sed 改写核心脚本本身
    if ! support env-set "country=$ctry" "timezone=$ntz" "locale=$nlocale" >/dev/null 2>&1; then
        echo "FAIL:环境配置写入失败($ENV_FILE)"
        return 1
    fi
    COUNTRY_TARGET="$ctry"; TZ_TARGET="$ntz"; LOCALE_TARGET="$nlocale"

    # 地区格式(用户级,无需密码)
    defaults write -g AppleLocale "$nlocale"

    # 时区(需管理员权限,会弹一次授权框);看门狗脚本在 root 目录下,顺道用同一次授权同步目标值
    WD="/Library/Application Support/claude-switcher/tz-watchdog.sh"
    adminCmds="/usr/sbin/systemsetup -settimezone $(shq "$ntz")"
    wdsync=0
    if [ -f "$WD" ] && [ ! -w "$WD" ]; then
        adminCmds="$adminCmds; /usr/bin/sed -i '' 's|^TARGET=.*|TARGET='$(shq "$ntz")'|' '$WD'"
        wdsync=1
    fi
    if ! osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "set-region 需要管理员权限以锁定时区" with administrator privileges
ASEOF
    then
        echo "FAIL:时区设置被取消或失败(国家/地区格式已更新为 $ctry/$nlocale)"
        return 1
    fi
    # 看门狗目标同步兜底(可写的老版本安装直接 sed;失败则提示运行安装器刷新)
    if [ -f "$WD" ] && [ "$wdsync" -eq 0 ]; then
        sed -i '' "s|^TARGET=.*|TARGET=$ntz|" "$WD" 2>/dev/null || echo "WARN:巡检目标未同步,请运行安装器刷新"
    fi

    echo "OK:region=$ctry tz=$ntz locale=$nlocale source=$src"
}

# 自动更新:拉取 main 分支最新代码,SHA256 校验+配置注入+自检+失败回滚
# --check 只检查不写入;--auto 供 LaunchAgent 每12小时调用(静默写 update.log)
self_update() {
    auto=0; check=0
    case "${1:-}" in
        --auto) auto=1 ;;
        --check) check=1 ;;
    esac
    # 路径全部从脚本自身位置推导,兼容旧版 LaunchDaemon(root) 混跑时 $HOME 不可靠的场景
    BIN=$(cd "$(dirname "$0")" && pwd)
    UHOME="${BIN%/.local/bin}"
    [ "$UHOME" = "$BIN" ] && UHOME="$HOME"
    if [ "$auto" -eq 1 ]; then
        mkdir -p "$BASE"
        # 先建再收紧:重定向会按 umask 新建,直接在 exec 之后没法改权限。
        : >>"$BASE/update.log" 2>/dev/null; chmod 600 "$BASE/update.log" 2>/dev/null
        exec >>"$BASE/update.log" 2>&1
        echo "# $(date '+%F %T') update --auto 开始"
    fi

    # 更新源默认指向本仓库,否则自动更新会把其它仓库的版本盖回来、本地改动全部丢失。
    # 可用 CLAUDE_SWITCHER_UPDATE_REPO=owner/name 临时改指其他仓库。
    UPD_REPO="${CLAUDE_SWITCHER_UPDATE_REPO:-huanfine/claude-switcher}"
    UPD_ZIP="https://codeload.github.com/$UPD_REPO/zip/refs/heads/main"
    UPD_SUMS="https://raw.githubusercontent.com/$UPD_REPO/main/SHA256SUMS"

    tmpd=$(mktemp -d)
    if ! curl -sL --max-time 30 "$UPD_ZIP" -o "$tmpd/main.zip" \
        || ! unzip -q "$tmpd/main.zip" -d "$tmpd" 2>/dev/null; then
        echo "FAIL:下载或解压失败(网络问题,稍后再试)"; rm -rf "$tmpd"; return 1
    fi
    NEW="$tmpd/claude-switcher-main"
    if [ ! -f "$NEW/core/claude-switch.sh" ]; then
        echo "FAIL:远程包结构异常,已中止"; rm -rf "$tmpd"; return 1
    fi

    # 工件完整性校验:逐项比对仓库 SHA256SUMS,任一不符即中止(防传输篡改;信任根为 GitHub 仓库本身)
    if ! curl -sL --max-time 15 "$UPD_SUMS" -o "$tmpd/SHA256SUMS" \
        || [ ! -s "$tmpd/SHA256SUMS" ]; then
        echo "FAIL:无法获取校验清单(SHA256SUMS),已中止"; rm -rf "$tmpd"; return 1
    fi
    bad=0
    while read -r sum rel; do
        [ -z "$sum" ] && continue
        if [ ! -f "$NEW/$rel" ] || [ "$(shasum -a 256 "$NEW/$rel" | awk '{print $1}')" != "$sum" ]; then
            bad=1; break
        fi
    done < "$tmpd/SHA256SUMS"
    if [ "$bad" -eq 1 ]; then
        echo "FAIL:工件校验失败,已中止(不排除网络篡改,可稍后重试或手动 update)"; rm -rf "$tmpd"; return 1
    fi

    # 跳过判断:核心脚本是发布产物、不含环境值,直接整份比对即可
    if [ -f "$BIN/claude-switch.sh" ] && \
       diff "$BIN/claude-switch.sh" "$NEW/core/claude-switch.sh" >/dev/null 2>&1; then
        echo "OK:已是最新版本"; rm -rf "$tmpd"; return 0
    fi

    # 只读检查:不备份、不写文件、不物化守护脚本、不触发自检/回滚
    if [ "$check" -eq 1 ]; then
        stamp=$(stat -f '%Sm' -t '%Y-%m-%d' "$NEW/core/claude-switch.sh" 2>/dev/null)
        [ -z "$stamp" ] && stamp=$(date '+%F')
        echo "INFO:发现新版本 $stamp"
        rm -rf "$tmpd"; return 0
    fi

    # 自动更新哨兵:本地安装由人工托管时,--auto 不得静默覆盖。
    # 上面的跳过判断只看「内容不同」,不看「谁新」——发布产物=安装产物,双方都是
    # main 的原样拷贝,没有可比较的版本号,所以这个简化平时成立。代价是:开发机上
    # 本地改动一旦还没推送,--auto 每 12 小时就会把远端旧版盖回来,2026-11-21
    # 实测把已经验证安装的纯净度修复降级回滚。无人值守通道必须保守:
    # touch ~/.claude-switcher/update-hold 即可让 --auto 只报告不动手。
    # 手动 update 是显式意志,不受哨兵影响;删掉哨兵文件即恢复默认行为。
    if [ "$auto" -eq 1 ] && [ -f "$BASE/update-hold" ]; then
        echo "SKIP:本地安装由 update-hold 托管,自动更新不覆盖(手动 update 可强制)"
        rm -rf "$tmpd"; return 0
    fi

    # 回归基线:换核心**之前**,用旧核心把各项状态快照下来。自检随后改成
    # 「回归对比」——只有「旧核心 ok 的项,新核心跑出 fail」才回滚。2026-11-20~27
    # 他机实测教训:地区漂移一项 fail 就把更新回滚了 7 天 14+ 轮;DNS泄露=fail
    # 更是自锁——能修它的核心(新核心才有这项检查和修复)因为它的存在装不上。
    # 环境问题回滚解决不了:旧核心 fail 的项,装回旧核心照样 fail。
    baseline=""
    if [ -f "$BIN/claude-switch.sh" ]; then
        baseline=$("${BASH:-/bin/bash}" "$BIN/claude-switch.sh" checkdetail 2>/dev/null || true)
    fi

    # 备份现有核心脚本
    [ -f "$BIN/claude-switch.sh" ] && cp "$BIN/claude-switch.sh" "$BIN/claude-switch.sh.bak"

    # 替换核心脚本。环境值已不在脚本里,不再需要回注;但从老版本(环境值写在
    # 脚本头部)升级时,必须先把它们迁进 env.json,否则升级后代理组名为空,
    # 规则会被写进错误的组——这类失败是静默的,只能在写入前挡住。
    cp "$NEW/core/claude-switch.sh" "$BIN/claude-switch.sh"
    chmod +x "$BIN/claude-switch.sh"
    PM=""; PG=""; CT=""; TZV=""; LCT=""
    if [ -f "$BIN/claude-switch.sh.bak" ]; then
        "${BASH:-/bin/bash}" "$BIN/claude-switch.sh" _support env-migrate "$BIN/claude-switch.sh.bak" >/dev/null 2>&1 || \
            echo "WARN:环境配置迁移失败,请运行 claude-switch.sh env-set 手动补齐"
    fi
    envdump=$("${BASH:-/bin/bash}" "$BIN/claude-switch.sh" _support env 2>/dev/null)
    PM=$(printf '%s\n' "$envdump" | sed -n 's/^proxy_mode=//p')
    TZV=$(printf '%s\n' "$envdump" | sed -n 's/^timezone=//p')

    # 守护进程脚本(root 所有,用户态不可写):与远程模板比对,有差异只提示不自动改
    APPDIR="/Library/Application Support/claude-switcher"
    if [ -f "$APPDIR/claude-bodyguard.sh" ] || [ -f "$APPDIR/tz-watchdog.sh" ]; then
        [ -z "$PM" ] && PM="clash-verge"
        [ -z "$TZV" ] && TZV="America/New_York"
        sed -e "s|__PROXY_MODE__|$PM|g" -e "s|__FAKE_PREFIX__|${FAKE_PREFIX:-198.18.}|g" \
            -e "s|__LOG_DIR__|/var/log/claude-switcher|g" \
            "$NEW/daemons/claude-bodyguard.sh" > "$tmpd/bg.new"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__TZ_TARGET__|$TZV|g" \
            -e "s|__LOG_DIR__|/var/log/claude-switcher|g" \
            "$NEW/daemons/tz-watchdog.sh" > "$tmpd/tz.new"
        if ! diff -q "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh" >/dev/null 2>&1 || \
           ! diff -q "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh" >/dev/null 2>&1; then
            echo "INFO:守护进程脚本有更新,请运行 installer/安装.command 刷新(需要密码)"
        fi
    fi
    rm -rf "$tmpd"

    # 更新后自检(回归对比):root(旧版 LaunchDaemon)下切回真实用户执行,避免 defaults 读到 root 的配置
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -f '%Su' "$UHOME" 2>/dev/null)
        if [ -n "$owner" ]; then out=$(sudo -H -u "$owner" "$BIN/claude-switch.sh" checkdetail 2>&1); else out=""; fi
    else
        out=$("$BIN/claude-switch.sh" checkdetail 2>&1)
    fi
    # 「无输出」仍然回滚:一行结论都拿不到说明新核心本身起不来,与环境无关。
    if [ -z "$out" ]; then
        [ -f "$BIN/claude-switch.sh.bak" ] && cp "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh"
        printf '%s|%s\n' "$(date '+%F %T')" "自检无输出" > "$BASE/update-rollback.txt" 2>/dev/null
        chmod 600 "$BASE/update-rollback.txt" 2>/dev/null
        echo "FAIL:新版自检无输出,已自动回滚"
        return 1
    fi
    # 回归判定:逐项比对新核心与基线。只有「基线 ok → 新核心 fail」才回滚;
    # 基线 fail/warn/skip/config 的项(环境漂移、旧核心同样 fail)和基线里
    # 没有的新检查项(旧核心看不见,回滚只会让它继续没人管)都不阻塞更新,
    # 但要如实交代,不能静默。
    regressed=""; new_fails=""
    while IFS= read -r line; do
        case "$line" in *=*) ;; *) continue ;; esac
        item=${line%%=*}
        state=${line#*=}; state=${state%%:*}
        [ -n "$item" ] && [ "$state" = "fail" ] || continue
        new_fails="${new_fails}${item}、"
        if [ -n "$baseline" ]; then
            bstate=$(printf '%s\n' "$baseline" | awk -F= -v k="$item" '$1==k{sub(/:.*/,"",$2); print $2; exit}')
        else
            bstate="ok"  # 旧核心跑不出基线(缺文件/起不来):退回保守一票否决
        fi
        [ "$bstate" = "ok" ] && regressed="${regressed}${item}、"
    done <<< "$out"
    if [ -n "$regressed" ]; then
        [ -f "$BIN/claude-switch.sh.bak" ] && cp "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh"
        regressed=${regressed%、}
        printf '%s|%s\n' "$(date '+%F %T')" "新核心让原本 ok 的项失败了:${regressed}" > "$BASE/update-rollback.txt" 2>/dev/null
        chmod 600 "$BASE/update-rollback.txt" 2>/dev/null
        echo "FAIL:新核心让原本 ok 的项失败了(${regressed}),已自动回滚"
        return 1
    fi
    # 成功即清掉上一次的回滚痕迹:App 靠这个文件的存在展示「上次更新被回滚」。
    rm -f "$BASE/update-rollback.txt" 2>/dev/null
    if [ -n "$new_fails" ]; then
        new_fails=${new_fails%、}
        echo "OK:更新完成(注意:${new_fails} 仍为 fail——旧核心同样 fail 或本次首次检出,属环境问题而非新核心退化,不回滚;可点一键修复)"
    else
        echo "OK:更新完成 $(date '+%Y-%m-%d')"
    fi
    return 0
}

# 设备指纹体检:字体地区特征 + GPU/虚拟机特征(Canvas/WebGL 由 Web 检测页覆盖)
fingerprint() {
    echo "# 设备指纹体检 $(date '+%F %T')"
    hits=""
    for d in /Library/Fonts "$HOME/Library/Fonts"; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            b=$(basename "$f" | tr '[:upper:]' '[:lower:]')
            case "$b" in
                *simsun*|*simhei*|*simkai*|*simfang*|*msyh*|*msjh*|*dengxian*|*wqy*|*fzshu*|*fzkai*|*fzhei*|*fangsong*) hits="$hits $b" ;;
            esac
        done < <(find "$d" -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \) 2>/dev/null)
    done
    if [ -n "$hits" ]; then
        echo "字体=warn:检测到地区特征字体:${hits# }"
        echo "建议=上述字体通常随中文办公软件安装,美区环境很少出现;不用的可在字体册停用"
    else
        echo "字体=ok:未发现中文办公字体(仅系统自带字体)"
    fi

    gpu=$(system_profiler SPDisplaysDataType 2>/dev/null)
    chip=$(echo "$gpu" | grep -m1 'Chipset Model' | sed 's/.*: //')
    res=$(echo "$gpu" | grep -m1 'Resolution' | sed 's/.*: //')
    [ -z "$chip" ] && chip="未知"
    echo "GPU=ok:${chip}"
    echo "显示=ok:${res:-未知}"
    virt=$(sysctl -n kern.hv_vmm_present 2>/dev/null)
    case "$chip" in
        *Virtual*|*VMware*|*Parallels*|*VirtualBox*|*SwiftShader*|*llvmpipe*)
            echo "虚拟机=warn:检测到虚拟 GPU($chip),这是强指纹" ;;
        *)
            [ "$virt" = "1" ] && echo "虚拟机=warn:运行在虚拟机中" || echo "虚拟机=ok:物理机" ;;
    esac
    echo "CanvasWebGL=info:原生检查读不到 Claude Electron 的渲染特征,请打开 Web 检测页 https://huanfine.github.io/claude-switcher/ 查看 Canvas/WebGL 指纹"
}

# ---------- 公告(只读拉取) ----------
# 边界:公告是纯只读功能 —— 只发 GET、只写自己的缓存文件,
# 不碰 env.json / Merge.yaml / 巡检,网络失败时静默降级用旧缓存。
# 数据源:仓库 data/announcements.json(raw.githubusercontent 为主,
# jsDelivr 兜底);缓存 ~/.claude-switcher/announcements-cache.json(0600)。
# schema 校验在核心侧把关(坏数据明确报错,不写缓存),版本过滤留给 App
# (核心不知道 App 版本,min/max_app_version 由界面侧自行剔除)。
ANNOUNCEMENTS_URL="https://raw.githubusercontent.com/huanfine/claude-switcher/main/data/announcements.json"
ANNOUNCEMENTS_URL_FALLBACK="https://cdn.jsdelivr.net/gh/huanfine/claude-switcher@main/data/announcements.json"
ANNOUNCEMENTS_CACHE="$BASE/announcements-cache.json"
ANNOUNCEMENTS_TTL=21600   # 6 小时;频控用,App 每次启动读缓存不再触发网络

announcements_validate() {
    # stdin: 源 JSON;argv[1]: 命中的源 URL(写进缓存供取证)
    # stdout: 清洗后的缓存 JSON;校验失败非 0 且不输出
    # 注意:脚本必须经 -c 执行,不能用 `python3 - <<EOF` —— heredoc 会把
    # stdin 占掉,管道进来的公告数据就到不了 json.load(sys.stdin)。
    local _py
    _py=$(cat <<'PYEOF'
import json, sys
from datetime import datetime, timezone

now = datetime.now(timezone.utc)
source = sys.argv[1] if len(sys.argv) > 1 else ""

def parse_ts(s):
    if not isinstance(s, str) or not s.strip():
        return None
    t = s.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        d = datetime.fromisoformat(t)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d

try:
    doc = json.load(sys.stdin)
except Exception:
    sys.stderr.write("公告数据不是合法 JSON\n")
    sys.exit(1)

if not isinstance(doc, dict) or doc.get("schema") != 1:
    sys.stderr.write("公告 schema 不支持(需要 schema=1)\n")
    sys.exit(1)
items = doc.get("items")
if not isinstance(items, list):
    sys.stderr.write("公告 items 缺失或不是数组\n")
    sys.exit(1)

allowed = ("info", "warn", "critical")
seen, clean = set(), []
for it in items:
    if not isinstance(it, dict):
        sys.stderr.write("公告项不是对象\n")
        sys.exit(1)
    for k in ("id", "severity", "title"):
        v = it.get(k)
        if not isinstance(v, str) or not v.strip():
            sys.stderr.write("公告项缺少必填字段: %s\n" % k)
            sys.exit(1)
    if it["severity"] not in allowed:
        sys.stderr.write("公告 severity 非法: %s\n" % it["severity"])
        sys.exit(1)
    if it["id"] in seen:
        continue
    seen.add(it["id"])
    exp = parse_ts(it.get("expires_at"))
    if exp is not None and exp <= now:
        continue
    clean.append(it)

out = {"schema": 1, "fetched_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
       "source": source, "items": clean}
sys.stdout.write(json.dumps(out, ensure_ascii=False))
PYEOF
) || return 1
    python3 -c "$_py" "$1"
}

announcements_check() {
    # 子命令:check [--force](TTL 内不打网络) / read(只读缓存,不联网)
    local sub="${1:-check}"
    local force=""
    case "$sub" in
        read)
            if [ -f "$ANNOUNCEMENTS_CACHE" ]; then
                cat "$ANNOUNCEMENTS_CACHE"
            else
                printf '{"schema":1,"fetched_at":"","source":"","items":[]}\n'
            fi
            return 0 ;;
        check|"") ;;
        --force) force=1 ;;
        *)
            echo "FAIL:announcements 支持 check [--force] | read" >&2
            return 1 ;;
    esac

    # TTL 频控:缓存够新直接用,不打网络(App 启动时的调用走这条)
    if [ -z "$force" ] && [ -f "$ANNOUNCEMENTS_CACHE" ]; then
        local age now_ts mtime
        now_ts=$(date +%s)
        mtime=$(stat -f %m "$ANNOUNCEMENTS_CACHE" 2>/dev/null || echo 0)
        age=$(( now_ts - mtime ))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$ANNOUNCEMENTS_TTL" ]; then
            cat "$ANNOUNCEMENTS_CACHE"
            return 0
        fi
    fi

    # 拉取:raw → jsDelivr 两级降级
    local raw="" src="" url
    for url in "$ANNOUNCEMENTS_URL" "$ANNOUNCEMENTS_URL_FALLBACK"; do
        if raw=$(curl -fsSL --max-time 15 "$url" 2>/dev/null) && [ -n "$raw" ]; then
            src="$url"
            break
        fi
    done
    if [ -z "$raw" ]; then
        # 网络两级全挂:降级用旧缓存(允许过期),连旧缓存都没有才报错
        if [ -f "$ANNOUNCEMENTS_CACHE" ]; then
            cat "$ANNOUNCEMENTS_CACHE"
            return 0
        fi
        echo "FAIL:公告拉取失败且无本地缓存" >&2
        return 1
    fi

    # 校验 + 清洗:坏数据明确报错、不写缓存(旧缓存保持不动)
    local clean
    if ! clean=$(printf '%s' "$raw" | announcements_validate "$src"); then
        echo "FAIL:公告数据校验未通过,保持旧缓存" >&2
        return 1
    fi

    # 原子落盘
    local tmp="$ANNOUNCEMENTS_CACHE.tmp.$$"
    if ! printf '%s\n' "$clean" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        echo "FAIL:公告缓存写入失败" >&2
        return 1
    fi
    mv "$tmp" "$ANNOUNCEMENTS_CACHE"
    chmod 600 "$ANNOUNCEMENTS_CACHE" 2>/dev/null
    echo "$clean"
}

# ---------- App 自更新(release 通道) ----------
# 边界:换装全程「同卷 rename」保证原子 —— 任何时刻磁盘上都存在一个完整
# 可启动的 bundle;绝不 kill 正在运行的 App(进程映像已在内存,下次启动即新版)。
# 与核心脚本更新(self_update,main 快照通道)是两个独立步骤,各自校验各自回滚,
# App 下载失败不影响核心照常更新。信任根 = GitHub releases 本身,
# 传输校验 = SHA256SUMS-release.txt(与安装包同一份清单)。
APP_BUNDLE_NAME="Claude 环境检查器.app"
APP_UPDATE_REPO="${CLAUDE_SWITCHER_UPDATE_REPO:-huanfine/claude-switcher}"
APP_UPDATE_MIN_DISK_MB=500    # 发版包 + 解压 + 旧版备份的余量
APP_UPDATE_FAIL_LIMIT=2       # 连续失败到该次数即熔断,防止发版事故反复重试
APP_UPDATE_FAILS="$BASE/app-update-fails"
APP_UPDATE_DISABLED="$BASE/app-update-disabled"

app_find_bundle() {
    # 按序探测已装 App;输出路径,找不到返回非 0(明确报错,不猜)
    local d
    for d in "/Applications" "$HOME/Applications" "$HOME/Desktop"; do
        if [ -d "$d/$APP_BUNDLE_NAME" ]; then
            printf '%s\n' "$d/$APP_BUNDLE_NAME"
            return 0
        fi
    done
    return 1
}

app_installed_version() {
    # argv[1]: bundle 路径;stdout: 版本号。Info.plist 缺字段 → 0.0.0
    # (方案 §5:视为最老版本,走一次换装即自愈)
    plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null || echo "0.0.0"
}

app_version_cmp() {
    # 输出 -1/0/1:语义化比较,数字段比较、- 后缀(-dev 等)忽略。
    # "1.8.2" > "1.8.10" 这类字符串陷阱必须按数值比。
    python3 - "${1%%-*}" "${2%%-*}" <<'PY'
import sys
def nums(v):
    return [int(x) if x.isdigit() else 0 for x in v.split(".")]
a, b = nums(sys.argv[1]), nums(sys.argv[2])
print("-1" if a < b else ("1" if a > b else "0"))
PY
}

latest_release_version() {
    # releases/latest 302 重定向免 API 认证;从 Location 头剥 tag。
    # 校验 tag 形态(纯字母数字._-),剥掉前导 v。
    local loc tag
    loc=$(curl -fssIL --max-time 20 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$APP_UPDATE_REPO/releases/latest" 2>/dev/null) || return 1
    tag="${loc##*/}"
    case "$tag" in
        ""|v|*[!0-9A-Za-z._-]*) return 1 ;;
    esac
    printf '%s\n' "${tag#v}"
}

app_auto_update_enabled() {
    # checks.json 的 app_auto_update,默认开;显式 false 才关。
    # 配置损坏按开处理(更新失败会自检回滚+熔断,方向安全)。
    python3 - "$BASE/checks.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    print("1"); raise SystemExit
v = doc.get("app_auto_update")
print("0" if v is False else "1")
PY
}

app_update_busy() {
    # 只读探测:检查/修复/账号切换任一进行中即视为忙。只 pgrep 不 kill,
    # 匹配的是核心脚本自己的命令行,不会误伤别的进程。
    pgrep -f 'claude-switch\.sh (check|checkdetail|fix|switch)( |$)' >/dev/null 2>&1
}

app_sync_version_txt() {
    # version.txt = 已装 App 的 Info.plist 版本。这是「安装版本」的唯一诚实来源:
    # 手装形态(App 先于本机制存在)从这里补齐,报告的 core_version 不再是 unknown。
    local bundle="$1" ver
    ver=$(app_installed_version "$bundle")
    case "$ver" in
        ""|0.0.0) return 0 ;;   # 读不到就不写,不造假数据
    esac
    printf '%s\n' "$ver" > "$BASE/version.txt"
    chmod 600 "$BASE/version.txt" 2>/dev/null
}

app_self_update() {
    # 用法:update-app [--check] | 内部:app_self_update --auto(update --auto 末尾调用)
    local mode="${1:-}"
    [ "$mode" = "--auto" ] || mode="manual"
    local check=0
    [ "${2:-}" = "--check" ] && check=1

    # 熔断哨兵:连续 2 轮换装失败后停用自动通道,防止发版事故反复重试。
    # 手动更新是显式意志,允许带哨兵执行,成功即清除。
    if [ -f "$APP_UPDATE_DISABLED" ]; then
        if [ "$mode" = "--auto" ]; then
            echo "SKIP:App 自动更新通道已熔断停用,需手动执行 update-app 或删 $APP_UPDATE_DISABLED 重置"
            return 0
        fi
        echo "INFO:自动通道此前已熔断,本次为手动更新;成功后将自动解除"
    fi

    # 自动模式还受设置开关约束;手动是显式意志,不受限
    if [ "$mode" = "--auto" ] && [ "$(app_auto_update_enabled)" != "1" ]; then
        echo "SKIP:app_auto_update 已关闭"
        return 0
    fi

    local bundle
    if ! bundle=$(app_find_bundle); then
        echo "SKIP:未找到已安装的 App(${APP_BUNDLE_NAME},/Applications ~/Applications ~/Desktop 均无)"
        return 0
    fi

    # version.txt 自愈:无论是否需要更新,先让安装版本落盘(方案 §5 兼容项)
    app_sync_version_txt "$bundle"

    local local_ver remote_ver cmp
    local_ver=$(app_installed_version "$bundle")
    if ! remote_ver=$(latest_release_version); then
        echo "FAIL:获取远端最新版本失败(releases/latest 不可达),本轮跳过"
        return 1
    fi
    cmp=$(app_version_cmp "$local_ver" "$remote_ver")
    if [ "$cmp" -ge 0 ]; then
        echo "OK:App 已是最新($local_ver)"
        return 0
    fi
    echo "INFO:App 有更新 $local_ver → $remote_ver"
    if [ "${check}" -eq 1 ]; then
        return 0
    fi

    # busy guard:检查/修复/账号切换进行中 → 本轮跳过(自动模式静默等下轮,
    # 手动模式明确告知)。换装虽是原子操作,但避开并发窗口省掉一切边界情况。
    if app_update_busy; then
        echo "SKIP:检查/修复/切换进行中,本轮跳过 App 更新"
        return 0
    fi

    # 磁盘余量:发版包 + 解压 + 旧版备份。必须用 df -m(MB) —— df -g 给的是
    # GB 数,拿 GB 数跟 MB 阈值比,199GB 会被误判成「不足 500MB」。
    local free_mb
    free_mb=$(df -m "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -z "$free_mb" ] || [ "$free_mb" -lt "$APP_UPDATE_MIN_DISK_MB" ]; then
        echo "FAIL:磁盘余量不足(需 ${APP_UPDATE_MIN_DISK_MB}MB,现有 ${free_mb:-未知}MB),本轮跳过"
        return 1
    fi

    # 下载 + 校验:app-only zip 的 sha256 对照随 release 的 SHA256SUMS-release.txt;
    # 失败重试一次,再失败放弃本轮(12h 后自然重试)
    local base_url="https://github.com/$APP_UPDATE_REPO/releases/download/v$remote_ver"
    local zip_name="ClaudeSwitcher-$remote_ver-macos-universal-app-only.zip"
    local tmpd tries zip_ok
    tmpd=$(mktemp -d)
    zip_ok=0
    for tries in 1 2; do
        if curl -fsSL --max-time 300 "$base_url/$zip_name" -o "$tmpd/app.zip" \
            && curl -fsSL --max-time 60 "$base_url/SHA256SUMS-release.txt" -o "$tmpd/sums.txt" \
            && [ -s "$tmpd/app.zip" ] && [ -s "$tmpd/sums.txt" ]; then
            local want got
            want=$(grep " $zip_name\$" "$tmpd/sums.txt" | awk '{print $1}')
            got=$(shasum -a 256 "$tmpd/app.zip" | awk '{print $1}')
            if [ -n "$want" ] && [ "$got" = "$want" ]; then
                zip_ok=1; break
            fi
            echo "WARN:第 $tries 次下载校验不符(got=$got want=$want)"
        else
            echo "WARN:第 $tries 次下载失败"
        fi
    done
    if [ "$zip_ok" -ne 1 ]; then
        echo "FAIL:发版包下载/校验两次未过,放弃本轮"
        rm -rf "$tmpd"
        return 1
    fi

    if ! unzip -q "$tmpd/app.zip" -d "$tmpd/unzipped" 2>/dev/null \
        || [ ! -d "$tmpd/unzipped/$APP_BUNDLE_NAME" ]; then
        echo "FAIL:解压失败或包内结构异常,放弃本轮"
        rm -rf "$tmpd"
        return 1
    fi
    # 下载通道会带 quarantine 属性,不清掉会撞 Gatekeeper(与安装器同一做法)
    xattr -dr com.apple.quarantine "$tmpd/unzipped/$APP_BUNDLE_NAME" 2>/dev/null

    # 原子换装:同卷 rename × 2,任何时刻都存在完整可启动的 bundle
    local oldb="$bundle.old-$$"
    if ! mv "$bundle" "$oldb" 2>/dev/null; then
        echo "FAIL:旧 bundle 改名失败(权限?),放弃本轮"
        rm -rf "$tmpd"
        return 1
    fi
    if ! mv "$tmpd/unzipped/$APP_BUNDLE_NAME" "$bundle" 2>/dev/null; then
        mv "$oldb" "$bundle"
        echo "FAIL:新 bundle 就位失败,已回滚"
        rm -rf "$tmpd"
        return 1
    fi

    # 最小自检:二进制可执行 + 签名有效 + Info.plist 版本 = 目标
    local newver ok=1
    newver=$(app_installed_version "$bundle")
    [ -x "$bundle/Contents/MacOS/ClaudeSwitcher" ] || { ok=0; echo "WARN:自检失败:二进制不存在或不可执行"; }
    [ "$ok" -eq 1 ] && ! codesign -v "$bundle" >/dev/null 2>&1 && { ok=0; echo "WARN:自检失败:codesign 校验不过"; }
    [ "$ok" -eq 1 ] && [ "$newver" != "$remote_ver" ] && { ok=0; echo "WARN:自检失败:版本号 $newver ≠ 目标 $remote_ver"; }
    if [ "$ok" -ne 1 ]; then
        rm -rf "$bundle"
        mv "$oldb" "$bundle"
        local fails
        fails=$(( $(cat "$APP_UPDATE_FAILS" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$fails" > "$APP_UPDATE_FAILS"
        chmod 600 "$APP_UPDATE_FAILS" 2>/dev/null
        if [ "$fails" -ge "$APP_UPDATE_FAIL_LIMIT" ]; then
            touch "$APP_UPDATE_DISABLED"
            echo "FAIL:换装自检未通过已回滚;连续 $fails 轮失败,App 自动更新通道已熔断停用(手动 update-app 可解除)"
        else
            echo "FAIL:换装自检未通过,已回滚到旧版(连续失败 $fails/$APP_UPDATE_FAIL_LIMIT)"
        fi
        rm -rf "$tmpd"
        return 1
    fi

    # 成功:清失败计数、解除熔断(手动成功=通道恢复)、写 version.txt
    rm -rf "$oldb" "$tmpd" "$APP_UPDATE_FAILS"
    rm -f "$APP_UPDATE_DISABLED"
    printf '%s\n' "$remote_ver" > "$BASE/version.txt"
    chmod 600 "$BASE/version.txt" 2>/dev/null
    echo "OK:App 已更新到 $remote_ver;正在运行的还是旧界面,下次启动即新版"
    return 0
}

# 账号快照加密导出/导入(macOS):AES-256 加密 DMG,密码只经 stdin 传递
# 一次性隔离浏览器:独立临时 profile,禁用非代理 UDP,关闭后销毁;URL 仅允许 http/https
# Claude Code CLI 体检:只读检测安装方式/版本/多份安装冲突,不执行卸载或重装
cli_info() {
    echo "# Claude Code CLI 体检 $(date '+%F %T')"
    path=$(command -v claude 2>/dev/null)
    if [ -n "$path" ]; then
        real=$("${CLAUDE_SWITCHER_PYTHON:-python3}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || echo "$path")
        ver=$(perl -e 'alarm 4; exec @ARGV' "$real" --version 2>/dev/null | head -1)
        [ -z "$ver" ] && ver=$(perl -e 'alarm 4; exec @ARGV' "$path" --version 2>/dev/null | head -1)
        echo "CLI=ok:$path"
        [ "$real" != "$path" ] && echo "CLI真实路径=info:$real"
        echo "版本=ok:${ver:-未获取}"
        case "$real" in
            *".claude/local"*|*".local/share/claude"*) method="native(官方安装脚本)" ;;
            *"/opt/homebrew/"*|*"/usr/local/Cellar/"*|*"/home/linuxbrew/"*) method="homebrew" ;;
            *"node_modules"*|*".npm-global"*|*"/.bun/"*) method="npm/bun" ;;
            *) method="未知(建议核对 PATH)" ;;
        esac
        echo "安装方式=info:$method"
    else
        echo "CLI=warn:PATH 中没有 claude 命令"
        echo "安装方式=info:未安装(桌面版可能自带内置 CLI,见下)"
    fi

    bundled=$(ls -d "$HOME/Library/Application Support/Claude/claude-code"/* 2>/dev/null | tail -1)
    if [ -n "$bundled" ]; then
        echo "桌面版内置=ok:$(basename "$bundled")"
    else
        echo "桌面版内置=info:未发现(Claude 桌面版未安装或版本较旧)"
    fi

    if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
        echo "npm全局包=warn:检测到 @anthropic-ai/claude-code"
    else
        echo "npm全局包=ok:未检测到"
    fi
    if command -v brew >/dev/null 2>&1 && brew list --versions claude-code >/dev/null 2>&1; then
        echo "Homebrew包=warn:$(brew list --versions claude-code 2>/dev/null | head -1)"
    else
        echo "Homebrew包=ok:未检测到"
    fi

    cfg="$HOME/.claude"
    if [ -d "$cfg" ]; then
        echo "配置目录=ok:$cfg ($(du -sh "$cfg" 2>/dev/null | cut -f1))"
    else
        echo "配置目录=info:未创建(尚未运行过 CLI)"
    fi

    [ -n "$path" ] && echo "建议=info:升级用对应包管理器(brew upgrade claude-code / npm i -g @anthropic-ai/claude-code@latest);卸载前先确认桌面版是否依赖它"
    return 0
}

open_safe() {
    url="${1:-}"
    case "$url" in
        http://*|https://*) ;;
        '') echo "FAIL:用法: claude-switch.sh open-safe <http(s)://链接>"; return 1 ;;
        *) echo "FAIL:只允许 http/https 链接"; return 1 ;;
    esac
    if [ "${CLAUDE_SWITCHER_SKIP_NET_CHECK:-0}" != "1" ] && ! tun_up && ! proxy_alive; then
        echo "FAIL:代理未就绪(TUN 未接管且客户端未运行),拒绝打开以免直连"
        return 1
    fi
    chrome="${CLAUDE_SWITCHER_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                 "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
                 "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
            [ -x "$c" ] && chrome="$c" && break
        done
    fi
    [ -n "$chrome" ] && [ -x "$chrome" ] || { echo "FAIL:未找到 Chrome/Chromium/Edge/Brave"; return 1; }

    profile=$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-safe.XXXXXX") || { echo "FAIL:无法创建临时 profile"; return 1; }
    chmod 700 "$profile"
    lang="${LOCALE_TARGET:-en_US}"; lang="${lang/_/-}"
    nohup "$chrome" \
        --user-data-dir="$profile" \
        --no-first-run --no-default-browser-check \
        --disable-sync --disable-extensions \
        --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
        --lang="$lang" \
        "$url" >/dev/null 2>&1 &
    pid=$!
    nohup bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 5; done; rm -rf "$2"' _ "$pid" "$profile" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo "OK:已在一次性隔离浏览器打开(profile 将在窗口关闭后销毁)"
    echo "INFO:该窗口不继承你日常浏览器的 cookies/插件;在其中登录产生的会话会随窗口关闭一并丢弃"
}

# 加密归档降级格式:当 DiskImages 服务异常(create/attach/verify 全部卡住或
# 报 Resource busy)时,不再赌 hdiutil,改用 openssl + tar。文件仍沿用用户给定
# 的路径,靠首行 magic 与 DMG 区分;导入端两种都认。
SNAPSHOT_ARCHIVE_MAGIC="CLAUDE-SWITCHER-ARCHIVE-1"

# ---------- 快照导出/导入辅助 ----------
# hdiutil 在部分系统版本上会卡住(实测 macOS 27 的 `create -srcfolder` 既可能
# 报 Resource busy,也可能一直不返回)。没有超时的话,界面会永远停在「导出中」,
# 用户只能强退;这里用 perl alarm 兜底(macOS 自带),并保留 stderr 供诊断。
_snapshot_timeout() {
    local secs="$1"; shift
    if command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

_snapshot_err() {
    [ -s "${1:-}" ] || return 0
    # 只留 hdiutil 自己的错误;超时被杀时 bash 会往 stderr 写 "Alarm clock"
    # 和脚本行号,那些对用户是噪声。
    grep -E '^hdiutil:' "$1" 2>/dev/null | tail -n 2 | tr '\n' ' ' | cut -c1-240
}

# macOS 的 TMPDIR 是 /var/folders/...，而 mount 输出是 /private/var/...。
# 不归一就直接 grep "on $mnt" 会永远匹配不到,于是函数以为已经卸载,
# 实际上把临时卷留在了系统里(实测一次测试留下 11 个)。
_snapshot_realpath() { (cd "${1:-}" 2>/dev/null && pwd -P) || printf '%s\n' "${1:-}"; }
_snapshot_mounted() {
    local real
    real=$(_snapshot_realpath "${1:-}")
    mount | grep -qF " on $real "
}

# 卸载失败时重试,最后 -force。挂载点还在时绝不能 rm -rf —— 那会删到镜像里的内容。
_snapshot_detach() {
    local mnt real i
    mnt="$1"
    real=$(_snapshot_realpath "$mnt")
    for i in 1 2; do
        _snapshot_mounted "$real" || return 0
        _snapshot_timeout 30 hdiutil detach "$real" >/dev/null 2>&1 && return 0
        sleep 1
    done
    # CoreDeviceService/模拟器会短暂持有新挂载的卷,普通 detach 会报
    # Resource busy;force 在实测中仍能卸载。给它更长的超时,再试一次
    # diskutil eject force(新接口)。
    _snapshot_timeout 30 hdiutil detach "$real" -force >/dev/null 2>&1 && return 0
    _snapshot_mounted "$real" || return 0
    _snapshot_timeout 30 diskutil eject force "$real" >/dev/null 2>&1
    ! _snapshot_mounted "$real"
}

# 把 stage 目录写成 "magic + AES-256-CBC(tar.gz)"。密码走 stdin 第一行,
# 不落 argv;PBKDF2 迭代次数写死在命令里,避免不同机器导出/导入参数不一致。
_snapshot_archive_write() {
    local stage="$1" out="$2" pass="$3" tmo="$4" plain rc
    command -v openssl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || return 1
    plain=$(mktemp "${TMPDIR:-/tmp}/claude-snapshot-plain.XXXXXX" 2>/dev/null) || return 1
    if ! tar -czf "$plain" -C "$stage" . 2>/dev/null; then
        rm -f "$plain"; return 1
    fi
    if ! printf '%s\n' "$SNAPSHOT_ARCHIVE_MAGIC" > "$out"; then
        rm -f "$plain" "$out"; return 1
    fi
    { printf '%s\n' "$pass"; cat "$plain"; } | _snapshot_timeout "$tmo" \
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass stdin >>"$out" 2>/dev/null
    rc=$?
    rm -f "$plain"
    [ "$rc" -eq 0 ] || { rm -f "$out"; return 1; }
    return 0
}

_snapshot_archive_check() {
    local file="$1" pass="$2" tmo="$3"
    { printf '%s\n' "$pass"; tail -c +$(( ${#SNAPSHOT_ARCHIVE_MAGIC} + 2 )) "$file"; } | \
        _snapshot_timeout "$tmo" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin 2>/dev/null | \
        tar -tzf - >/dev/null 2>&1
}

snapshot_export() {
    target="${1:-}"; out="${2:-}"; mode="${3:-}"
    # 生产环境给足时间(账号数据可能很大);测试用
    # CLAUDE_SWITCHER_SNAPSHOT_TIMEOUT 压到秒级。
    local tmo="${CLAUDE_SWITCHER_SNAPSHOT_TIMEOUT:-180}"
    valid_account "$target" || return 1
    [ -d "$BASE/accounts/$target" ] || { echo "FAIL:账号$target 没有已归档快照(先切换一次让它归档)"; return 1; }
    [ -n "$out" ] || { echo "FAIL:请指定导出文件路径"; return 1; }
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    [ -e "$out" ] && { echo "FAIL:目标文件已存在,请换一个路径"; return 1; }
    if [ "$(cat "$BASE/current" 2>/dev/null)" = "$target" ]; then
        echo "FAIL:账号$target 正在使用中,当前数据在运行目录;请先切换到另一账号(会自动归档)再导出"
        return 1
    fi

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '设置导出密码(至少 8 位): '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
        printf '再次输入: '; stty -echo 2>/dev/null; IFS= read -r pass2; stty echo 2>/dev/null; echo
        [ "$pass" = "$pass2" ] || { echo "FAIL:两次密码不一致"; return 1; }
    fi
    if [ ${#pass} -lt 8 ]; then
        unset pass pass2
        echo "FAIL:密码至少 8 位"; return 1
    fi

    stage=$(mktemp -d)
    if ! ditto "$BASE/accounts/$target/" "$stage/"; then
        rm -rf "$stage"; unset pass pass2
        echo "FAIL:复制快照失败"; return 1
    fi
    cat > "$stage/.claude-switcher-snapshot.json" <<EOF
{"format":"claude-switcher-snapshot","version":1,"account":"$target","created":"$(date '+%F %T')"}
EOF
    errlog=$(mktemp "${TMPDIR:-/tmp}/claude-snapshot.XXXXXX" 2>/dev/null) || errlog=""
    created=0
    primary_err=""; fallback_err=""
    if printf '%s\n' "$pass" | _snapshot_timeout "$tmo" hdiutil create -srcfolder "$stage" \
        -volname "ClaudeSnapshot-$target" -encryption AES-256 -stdinpass "$out" \
        >/dev/null 2>"${errlog:-/dev/null}"; then
        created=1
    else
        primary_err=$(_snapshot_err "$errlog")
        rm -f "$out"
        # 降级:先建未加密空镜像,挂载后 ditto 复制,最后转成加密 UDZO。
        # 避开 create -srcfolder 的系统回归;空镜像路径在本机实测可用。
        size_mb=$(( $(du -sk "$stage" 2>/dev/null | awk '{print $1}') / 1024 + 32 ))
        [ "$size_mb" -lt 16 ] && size_mb=16
        # 空镜像先不加密,复制完再 convert 成 UDZO+AES。直接用加密稀疏镜像
        # 虽然能挂载,但没有 UDIF 校验和,`hdiutil verify` 会报 "has no checksum";
        # 先加密再 convert 又会因为源本身加密而失败。未加密 raw → UDZO 是实测可用的顺序。
        # 必须以 .dmg 结尾:hdiutil 对无扩展名的目标会自动补 .dmg,导致后面
        # attach 找不到刚创建的文件(实测报 No such file or directory)。
        raw="${out%.dmg}.raw.$$.dmg"
        rm -f "$raw" "$raw.dmg"
        if _snapshot_timeout "$tmo" hdiutil create -size "${size_mb}m" -fs HFS+ \
            -volname "ClaudeSnapshot-$target" "$raw" >/dev/null 2>"${errlog:-/dev/null}"; then
            mnt=$(mktemp -d "${TMPDIR:-/tmp}/claude-snapshot-mnt.XXXXXX" 2>/dev/null) || mnt=""
            populated=0
            if [ -n "$mnt" ] && _snapshot_timeout "$tmo" hdiutil attach -nobrowse \
                -mountpoint "$mnt" "$raw" >/dev/null 2>"${errlog:-/dev/null}"; then
                if _snapshot_timeout "$tmo" ditto "$stage/" "$mnt/" 2>>"${errlog:-/dev/null}"; then
                    populated=1
                else
                    fallback_err=$(_snapshot_err "$errlog")
                fi
                _snapshot_detach "$mnt" || echo "WARN:临时镜像未能自动卸载: $mnt" >&2
            elif [ -n "$mnt" ] && _snapshot_mounted "$mnt"; then
                # attach 命令超时不代表没挂上:本机实测卷已出现但 hdiutil 不返回。
                # 只要挂载点真的在,就继续复制,别让一次卡住的 API 白丢整次导出。
                fallback_err=$(_snapshot_err "$errlog")
                if _snapshot_timeout "$tmo" ditto "$stage/" "$mnt/" 2>>"${errlog:-/dev/null}"; then
                    populated=1
                    fallback_err=""
                fi
                _snapshot_detach "$mnt" || echo "WARN:临时镜像未能自动卸载: $mnt" >&2
            else
                fallback_err=$(_snapshot_err "$errlog")
                [ -n "$mnt" ] && _snapshot_detach "$mnt" >/dev/null 2>&1
            fi
            # 仍然挂载时绝不能 rm -rf:那会删到镜像里的内容,而不是空的挂载点。
            if [ -n "$mnt" ] && ! _snapshot_mounted "$mnt"; then
                rm -rf "$mnt" 2>/dev/null
            elif [ -n "$mnt" ]; then
                echo "WARN:临时镜像仍挂载在 $mnt,请手动 hdiutil detach \"$mnt\" -force" >&2
            fi
            if [ "$populated" = 1 ]; then
                : >"${errlog:-/dev/null}"
                if printf '%s\n' "$pass" | _snapshot_timeout "$tmo" hdiutil convert "$raw" \
                    -format UDZO -encryption AES-256 -stdinpass -o "$out" \
                    >/dev/null 2>"${errlog:-/dev/null}"; then
                    created=1
                else
                    fallback_err=$(_snapshot_err "$errlog")
                fi
            fi
            # 仍挂载时不能删底层镜像文件;留给用户按 WARN 手动卸载后再删。
            if [ -n "$mnt" ] && _snapshot_mounted "$mnt"; then
                echo "WARN:临时镜像仍挂载,已保留 $raw" >&2
            else
                rm -f "$raw"
            fi
        else
            fallback_err=$(_snapshot_err "$errlog")
        fi
        [ "$created" = 1 ] || rm -f "$out"
    fi
    # 最后一道:完全绕开 DiskImages。本机实测 create/attach 会被模拟器的
    # CoreDeviceService 拖住;加密归档不挂载任何卷,失败面小得多。
    archive_backend=0
    if [ "$created" != 1 ]; then
        if _snapshot_archive_write "$stage" "$out" "$pass" "$tmo" && \
           _snapshot_archive_check "$out" "$pass" "$tmo"; then
            created=1; archive_backend=1
        else
            rm -f "$out"
        fi
    fi
    rm -rf "$stage"
    if [ "$created" != 1 ]; then
        rm -f "$out"; rm -f "$errlog"; unset pass pass2
        echo "FAIL:创建加密镜像失败${primary_err:+ (直接创建: $primary_err)}${fallback_err:+ (降级创建: $fallback_err)}"
        return 1
    fi
    if [ "$archive_backend" != 1 ]; then
        # 加密镜像校验必须带密码,否则 macOS 会弹出图形密码框
        : >"${errlog:-/dev/null}"
        if ! printf '%s\n' "$pass" | _snapshot_timeout "$tmo" hdiutil verify -stdinpass "$out" \
            >/dev/null 2>"${errlog:-/dev/null}"; then
            verify_err=$(_snapshot_err "$errlog")
            rm -f "$out" "$errlog"; unset pass pass2
            echo "FAIL:镜像校验失败${verify_err:+ ($verify_err)}"; return 1
        fi
    fi
    rm -f "$errlog"
    unset pass pass2
    chmod 600 "$out"
    if [ "$archive_backend" = 1 ]; then
        echo "OK:账号$target 已加密导出到 $out(兼容归档格式:本机磁盘映像服务不可用)"
    else
        echo "OK:账号$target 已加密导出到 $out"
    fi
}

snapshot_import() {
    file="${1:-}"; target="${2:-}"; mode="${3:-}"
    valid_account "$target" || return 1
    [ -f "$file" ] || { echo "FAIL:找不到镜像文件: $file"; return 1; }
    [ -e "$BASE/accounts/$target" ] && { echo "FAIL:账号$target 已有快照,请先导出或删除后再导入"; return 1; }

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '输入镜像密码: '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
    fi
    [ -n "$pass" ] || { echo "FAIL:密码为空"; return 1; }

    mnt=$(mktemp -d)
    attached=0
    local tmo="${CLAUDE_SWITCHER_SNAPSHOT_TIMEOUT:-180}"
    errlog=$(mktemp "${TMPDIR:-/tmp}/claude-snapshot.XXXXXX" 2>/dev/null) || errlog=""
    archive_magic=$(head -c $(( ${#SNAPSHOT_ARCHIVE_MAGIC} + 1 )) "$file" 2>/dev/null || true)
    if [ "$archive_magic" = "$SNAPSHOT_ARCHIVE_MAGIC" ]; then
        # 导出端在 DiskImages 不可用时写的兼容归档:tar.gz + AES-256-CBC。
        if ! command -v openssl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
            unset pass; rm -f "$errlog"; rm -rf "$mnt"
            echo "FAIL:缺少 openssl/tar,无法读取兼容归档"; return 1
        fi
        plain=$(mktemp "${TMPDIR:-/tmp}/claude-snapshot-plain.XXXXXX" 2>/dev/null) || plain=""
        if [ -z "$plain" ] || ! { printf '%s\n' "$pass"; tail -c +$(( ${#SNAPSHOT_ARCHIVE_MAGIC} + 2 )) "$file"; } | \
            _snapshot_timeout "$tmo" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin \
            >"$plain" 2>"${errlog:-/dev/null}"; then
            rm -f "$plain" "$errlog"; rm -rf "$mnt"; unset pass
            echo "FAIL:密码错误或归档损坏"; return 1
        fi
        if ! tar -xzf "$plain" -C "$mnt" 2>"${errlog:-/dev/null}"; then
            extract_err=$(_snapshot_err "$errlog")
            rm -f "$plain" "$errlog"; rm -rf "$mnt"; unset pass
            echo "FAIL:归档解压失败${extract_err:+ ($extract_err)}"; return 1
        fi
        rm -f "$plain" "$errlog"
        unset pass
    else
        if ! printf '%s\n' "$pass" | _snapshot_timeout "$tmo" hdiutil attach -stdinpass -nobrowse -readonly \
            -mountpoint "$mnt" "$file" >/dev/null 2>"${errlog:-/dev/null}"; then
            # 同导出:attach 超时但卷已挂上时继续,否则按密码错误/镜像损坏处理。
            if _snapshot_mounted "$mnt"; then
                attached=1
            else
                attach_err=$(_snapshot_err "$errlog")
                unset pass; rm -f "$errlog"; rm -rf "$mnt"
                echo "FAIL:密码错误或镜像损坏${attach_err:+ ($attach_err)}"; return 1
            fi
        else
            attached=1
        fi
        rm -f "$errlog"
        unset pass
    fi

    cleanup_import() {
        if [ "$attached" = "1" ]; then
            _snapshot_detach "$mnt" || echo "WARN:镜像未能自动卸载,请手动执行 hdiutil detach \"$mnt\"" >&2
        fi
        # 挂载点仍在时删目录会穿透到镜像里,必须先确认已卸载。
        if _snapshot_mounted "$mnt"; then
            :
        else
            rm -rf "$mnt"
        fi
        rm -rf "$BASE/accounts/$target.new"
    }

    marker="$mnt/.claude-switcher-snapshot.json"
    if [ ! -f "$marker" ]; then
        cleanup_import
        echo "FAIL:不是本项目导出的快照镜像"; return 1
    fi
    if ! "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$marker" "$target" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: meta = json.load(f)
assert meta.get("format") == "claude-switcher-snapshot"
assert meta.get("version") == 1
assert meta.get("account") in ("A", "B", "C", "D")
sys.exit(0 if meta.get("account") == sys.argv[2] else 1)
PY
    then
        cleanup_import
        echo "FAIL:镜像元数据校验失败(账号不匹配或格式不支持)"; return 1
    fi

    rm -rf "$BASE/accounts/$target.new"
    if ! ditto "$mnt" "$BASE/accounts/$target.new"; then
        cleanup_import
        echo "FAIL:复制到账号目录失败"; return 1
    fi
    rm -f "$BASE/accounts/$target.new/.claude-switcher-snapshot.json"
    chmod 700 "$BASE/accounts/$target.new"
    if ! mv "$BASE/accounts/$target.new" "$BASE/accounts/$target"; then
        cleanup_import
        echo "FAIL:写入账号目录失败"; return 1
    fi
    cleanup_import
    echo "OK:已导入为账号$target(切换时生效)"
}

status() {
    local cur="none" a dir size stamp csize cstamp accounts="" extras="" has=""
    [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    # hasX 对每个槽位都输出 0/1:旧版界面读 hasA..hasD,新版读 accounts 列表,
    # 两边都不能断。多出来的 hasE..hasH 对旧界面是未知字段,直接忽略。
    for a in $(slots); do
        dir="$BASE/accounts/$a"
        if [ -d "$dir" ]; then
            has="$has has$a=1"
            accounts="${accounts:+$accounts,}$a"
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            stamp=$(date -r "$dir" '+%Y-%m-%d' 2>/dev/null)
            extras="$extras acc$a=${size:-?}@${stamp:-?}"
            # Claude Code 那半边单独报:它不在 accounts/ 里,体积也不小(实测 151M),
            # 混进 acc 会让「这个槽位多大」对不上磁盘。
            if cli_slot_has_payload "$a"; then
                csize=$(du -sh "$CLI_BASE/$a" 2>/dev/null | awk '{print $1}')
                cstamp=$(date -r "$CLI_BASE/$a" '+%Y-%m-%d' 2>/dev/null)
                extras="$extras cli$a=${csize:-?}@${cstamp:-?}"
            fi
        else
            has="$has has$a=0"
        fi
    done
    echo "current=$cur$has accounts=${accounts:-none}$extras"
}

quit_claude() {
    # 不写死 /Applications:App 被拖进 ~/Applications 时同样要认出来。
    pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        # 不写死 /Applications:App 被拖进 ~/Applications 时同样要认出来。
    pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

# ---------- 运行期看门狗 ----------
# 启动门禁只证明「拉起 Claude 那一刻环境是对的」。用着用着代理掉线、出口被切、
# 系统更新把 IPv6 又打开 —— 这些都不会自己停下 Claude,它会拿着错误的出口
# 继续把请求发出去。watch 就是补这一段:运行期间持续复查,一有问题立刻关掉它。

watch_log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$BASE/watch.log"
    # 留最近 5000 行。这是流水账不是审计存档,但也不能无限长 ——
    # 每轮「复检、接管、检查未通过」都写一行,长期驻守时它只增不减。
    if [ "$(wc -l < "$BASE/watch.log" 2>/dev/null || echo 0)" -gt 5000 ] 2>/dev/null; then
        tail -n 5000 "$BASE/watch.log" > "$BASE/watch.log.tmp" 2>/dev/null \
            && mv "$BASE/watch.log.tmp" "$BASE/watch.log"
    fi
}

# 拦截记录:给人看的历史。watch.log 是流水账(启动、复检、接管全在里面),
# 这份只记「真的动过手」的事件,界面按它渲染「异常记录」。TAB 分隔三列:
# 时间 / 类型 / 原因 —— 界面按 TAB 切,别改成空格。
watch_incident() {
    local reason="${1:-}" kind="${2:-拦截}" f tmp
    [ -n "$reason" ] || return 0
    f="$BASE/incidents.log"; tmp="$BASE/incidents.log.tmp"
    printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$kind" "$reason" >> "$f" 2>/dev/null || return 0
    # 只留最近 50 条:这是给人看的,不是审计存档;要追溯有 watch.log。
    tail -50 "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
}

# 立刻停 Claude:先礼后兵。osascript 对这类 App 常常没反应,所以必须落到 pkill,
# 否则「已经拦住了」只是提示语上的一句好话。
#
# 顺带把「到底关没关掉」报出来。这个函数本来就会 pgrep 判断在不在跑,
# 但判断完就把结果丢了 —— 界面只能无条件写「已自动停止 Claude」,
# 而它可能压根没开、也可能 pkill 之后还在。现在这行 KILLSTATE 是给界面用的:
#   was=1 熔断时 Claude 在运行;was=0 本来就没开
#   still=1 处理完仍在运行(关不掉,保护失败);still=0 已确认退出
stop_claude_now() {
    local reason="$1" kind="${2:-拦截}" was=0 still=0 i
    # was 原来只认桌面 App,于是「终端里开着 Claude Code 被熔断」时界面会写
    # 「本来就没开」。现在三种形态都算在跑。
    claude_running && was=1
    if claude_app_running; then
        osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
        # 只给 1 秒体面退出。这是熔断路径:多等一秒就多一秒裸连重试的机会,
        # 原来「quit → 每秒探一次、探三次」最多要 3 秒才轮到 pkill。
        for i in 1 2 3 4 5; do
            claude_app_running || break
            sleep 0.2
        done
        if claude_app_running; then
            pkill -TERM -f "Claude.app/Contents/MacOS/Claude" 2>/dev/null
            sleep 0.3
            # 还不走就 SIGKILL:熔断场景下「让它自己收尾」不值这个时间。
            claude_app_running && pkill -KILL -f "Claude.app/Contents/MacOS/Claude" 2>/dev/null
        fi
    fi
    # CLI 一并停掉:后台的 claude 进程比 App 更容易悄悄重试。
    # `-x claude` 认的是原生二进制的进程名(argv[0] 就叫 claude),大小写敏感,
    # 不会误伤桌面 App 的 `Claude`。另外两条留给老 npm 装法。
    pkill -x claude 2>/dev/null
    pkill -f "claude-code/cli.js" 2>/dev/null
    pkill -f "@anthropic-ai/claude-code" 2>/dev/null
    # 给 CLI 一点退出时间,别在它还没死透时就断言「已停止」。同样只给 1 秒,
    # 到点直接 SIGKILL —— 熔断的意义是立刻断,不是排队等它收尾。
    for i in 1 2 3 4 5; do
        claude_cli_running || break
        sleep 0.2
    done
    if claude_cli_running; then
        pkill -KILL -x claude 2>/dev/null
        pkill -KILL -f "claude-code/cli.js" 2>/dev/null
    fi
    claude_running && still=1
    echo "KILLSTATE:$was:$still"
    watch_log "已停止 Claude:$reason(熔断时在运行=$was, 处理后仍在运行=$still)"
    watch_incident "$reason" "$kind"
}

# 一轮快速复查:只做「一变就必须停」的项,单次约 2 秒。
# 慢项(STUN/生态可达性)留给整轮 check,靠 full_every 兜底。
watch_cycle() {
    local ip key
    ip=$(curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
    [ -n "$ip" ] || return 2          # 采不到:交给调用方累计失败次数
    key=$(ip_key "$ip")
    case "$key" in
        v6:*)
            if [ -n "$WATCH_K6" ] && [ "$key" != "$WATCH_K6" ]; then
                WATCH_STOP="出口 IPv6 网段变了($(ip_show "$WATCH_K6") → $(ip_show "$key"))"
                return 1
            fi
            WATCH_K6="$key" ;;
        *)
            if [ -n "$WATCH_K4" ] && [ "$key" != "$WATCH_K4" ]; then
                WATCH_STOP="出口 IPv4 变了($(ip_show "$WATCH_K4") → $(ip_show "$key"))"
                return 1
            fi
            WATCH_K4="$key" ;;
    esac
    WATCH_IP="$ip"
    return 0
}

# watch [间隔秒] [整轮检查周期]
# 单实例接管。App 被强杀或崩溃时,它起的看门狗走不到 applicationWillTerminate,
# 直接变孤儿;新实例再起来就是两个守护各拿一份基线,重复报警、重复关进程,
# 而且旧那份的基线还是上一轮的。所以新实例一律接管:先收掉旧的,再占住 pidfile。
# pidfile 里只有数字,而 pid 会被复用:守护被 SIGKILL 时走不到 trap,pidfile 会残留,
# 之后这个号被别的进程拿到,新实例一接管就把无关进程杀了。所以杀之前必须确认它
# 真是看门狗。ps 不可用时宁可不接管 —— 留两个守护是脏,杀错进程是事故。
watch_pid_is_watchdog() {
    local p="${1:-}"
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$p" 2>/dev/null || return 1
    ps -p "$p" -o command= 2>/dev/null | grep -q 'claude-switch\.sh watch'
}

watch_lock() {
    local old obase i
    WATCH_PIDFILE="$BASE/watch.pid"
    if [ -r "$WATCH_PIDFILE" ]; then
        # 用 awk 而不是 cut -f2:cut 对「没有分隔符」的行会原样返回整行,
        # 旧格式(只有 pid)的 pidfile 就会被误读成「BASE 是那个 pid」,永远不接管。
        old=$(awk -F'\t' '{print $1; exit}' "$WATCH_PIDFILE" 2>/dev/null)
        obase=$(awk -F'\t' 'NF > 1 {print $2; exit}' "$WATCH_PIDFILE" 2>/dev/null)
        case "${old:-}" in
            ''|*[!0-9]*) ;;
            *)
                if [ -n "${obase:-}" ] && [ "$obase" != "$BASE" ]; then
                    # 不同 BASE 的旧记录(备份/迁移带过来的 pidfile)。那个进程服务的是
                    # 另一套环境,不该被我们杀掉 —— 实测复制一份 BASE 就误杀过真实守护。
                    :
                elif [ "$old" != "$$" ] && watch_pid_is_watchdog "$old"; then
                    watch_log "接管:停掉旧看门狗 pid=$old"
                    kill "$old" 2>/dev/null
                    for i in 1 2 3 4 5; do
                        kill -0 "$old" 2>/dev/null || break
                        sleep 0.2
                    done
                    kill -9 "$old" 2>/dev/null
                fi ;;
        esac
    fi
    printf '%s\t%s\n' "$$" "$BASE" > "$WATCH_PIDFILE"
    # 只删自己写的那份。旧实例被接管时也会跑到 EXIT,无条件 rm 会把新实例的记录带走。
    # 比的是 pidfile 第一段(pid),不是整行 —— 格式是「pid<TAB>BASE」。
    # TERM/INT 分支必须带 exit:bash 的 trap 执行完会回到被中断的地方继续跑,
    # 不 exit 的话 App 的 terminate() 压根停不下看门狗 —— 实测就是这样留下孤儿的。
    trap '[ "$(cut -f1 "$WATCH_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WATCH_PIDFILE"' EXIT
    trap '[ "$(cut -f1 "$WATCH_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WATCH_PIDFILE"; exit 143' INT TERM
}

watch() {
    local interval="${1:-10}" full_every="${2:-6}" n=0 miss=0 rc
    mkdir -p "$BASE"
    watch_lock
    WATCH_K4=""; WATCH_K6=""; WATCH_STOP=""; WATCH_IP=""
    watch_log "watch 启动 interval=${interval}s full_every=${full_every} pid=$$"
    # 每完成一轮巡逻吐一次心跳。界面靠它做「驻守中」的呼吸动画 ——
    # 心跳必须来自真的跑完一轮,不能由界面自己循环,否则守护断了动画还在跳,
    # 那比没有动画更糟:用户会以为一切正常。
    echo "BEAT:$(date +%s)"
    while :; do
        n=$((n + 1))
        watch_cycle
        rc=$?
        case "$rc" in
            1) stop_claude_now "$WATCH_STOP" "出口变化"; echo "STOP:$WATCH_STOP"; return 3 ;;
            2)
                miss=$((miss + 1))
                if [ "$miss" -ge 3 ]; then
                    stop_claude_now "出口探测连续 ${miss} 次失败(代理可能已断)" "代理断开"
                    echo "STOP:出口探测连续 ${miss} 次失败(代理可能已断)"
                    return 3
                fi ;;
            *) miss=0 ;;
        esac
        # 整轮:跑真正的门禁。任何一项不合格都停,而不是等它自己发现。
        # 但先复检一次:一次 curl 抖动就杀进程,比漏判更让人受不了。
        # 出口变了不在此列 —— 那是 watch_cycle 当场判的,不重试。
        if [ "$n" -eq 1 ] || [ $((n % full_every)) -eq 0 ]; then
            if ! out=$("${BASH:-/bin/bash}" "$0" check 2>&1); then
                sleep 5
                if ! out=$("${BASH:-/bin/bash}" "$0" check 2>&1); then
                    WATCH_STOP="运行中检查未通过:${out#FAIL:}"
                    stop_claude_now "$WATCH_STOP" "检查未通过"
                    echo "STOP:$WATCH_STOP"
                    return 3
                fi
                watch_log "整轮检查失败一次,复检通过,不处理:$out"
            fi
        fi
        # 这一轮平安落地,再吐一次心跳。
        echo "BEAT:$(date +%s)"
        sleep "$interval"
    done
}


archive_current() {
    local cur="$1"
    local t0 staged current previous moved=0 had_old=0
    t0=$(date +%s)
    staged="$BASE/accounts/$cur.new"
    current="$BASE/accounts/$cur"
    previous="$BASE/accounts/$cur.previous"

    # An interrupted archive may be the only remaining copy. Never clear it
    # automatically, or delete the previous snapshot before the new one commits.
    if [ -e "$staged" ] || [ -L "$staged" ] || [ -e "$previous" ] || [ -L "$previous" ]; then
        log "FAIL:账号$cur 存在待恢复快照，拒绝覆盖"
        return 1
    fi
    if mv "$DATA" "$staged" 2>/dev/null; then
        moved=1
    else
        # A cross-volume move may leave a partial destination on failure.
        if [ -e "$staged" ] || [ -L "$staged" ]; then
            log "FAIL:账号$cur 归档移动不完整，保留现场"
            return 1
        fi
        if ! copy_tree "$DATA" "$staged"; then
            log "FAIL:账号$cur 归档复制失败，保留现场"
            return 1
        fi
    fi

    if [ -e "$current" ] || [ -L "$current" ]; then
        if ! mv "$current" "$previous"; then
            if [ "$moved" -eq 1 ]; then
                mv "$staged" "$DATA" || log "WARN:账号$cur 数据保留在暂存位置"
            fi
            log "FAIL:账号$cur 旧快照无法安全转存"
            return 1
        fi
        had_old=1
    fi
    if ! mv "$staged" "$current"; then
        if [ "$had_old" -eq 1 ]; then
            mv "$previous" "$current" || log "WARN:账号$cur 旧快照保留在恢复位置"
        fi
        if [ "$moved" -eq 1 ]; then
            mv "$staged" "$DATA" || log "WARN:账号$cur 当前数据保留在暂存位置"
        fi
        log "FAIL:账号$cur 归档提交失败"
        return 1
    fi
    if [ "$had_old" -eq 1 ]; then
        rm -rf "$previous" || log "WARN:账号$cur 旧快照副本需手动清理"
    fi
    log "已存档账号$cur ($(( $(date +%s) - t0 ))s)"
}

# ---------- Claude Code 那半边(独立目录树,不碰 accounts/) ----------
# 为什么另起 $BASE/cli 而不是塞进 accounts/$X:
#   accounts/$X 的语义就是「~/Library/Application Support/Claude 的内容」,
#   往里面加子目录,restore 时会原样复制回 App 数据目录,凭空多出个 cli/。
#   而且老快照(用户已经存好的 A/B)没有这层,放进同一棵树就得做迁移 ——
#   迁移 473 MB 的账号快照是有风险的,不如并列放,老快照一个字节都不用动。
#
# 布局:
#   $BASE/cli/A/home/       ← ~/.claude
#   $BASE/cli/A/home.json   ← ~/.claude.json
# 两者都可能缺(老槽位没存过 CLI,或者用户从没用过 Claude Code)。

cli_slot_has_payload() {
    [ -d "$CLI_BASE/$1/home" ] || [ -f "$CLI_BASE/$1/home.json" ]
}

# 归档当前 Claude Code 状态到账号槽位。移动语义,和 archive_current 一致:
# 成功之后 ~/.claude 就不在原位了,由 restore_cli 把目标槽位的那份放回来。
archive_cli() {
    local cur="$1"
    local staged="$CLI_BASE/$cur.new" current="$CLI_BASE/$cur" previous="$CLI_BASE/$cur.previous"
    local had_old=0 moved=0
    mkdir -p "$CLI_BASE" || { log "FAIL:无法创建 Claude Code 快照目录"; return 1; }
    if [ -e "$staged" ] || [ -e "$previous" ]; then
        log "FAIL:账号$cur 存在待恢复的 Claude Code 快照,拒绝覆盖"
        return 1
    fi
    rm -rf "$staged"
    mkdir -p "$staged" || return 1

    if [ -d "$CLI_DIR" ]; then
        if mv "$CLI_DIR" "$staged/home" 2>/dev/null; then
            moved=1
        elif ! copy_tree "$CLI_DIR" "$staged/home"; then
            rm -rf "$staged"
            log "FAIL:账号$cur 的 Claude Code 目录归档失败"
            return 1
        fi
    fi
    if [ -f "$CLI_JSON" ]; then
        # 和 ~/.claude 一样是移动语义:归档完现场就该是空的,否则「归档到一半
        # 失败」时会出现 ~/.claude 没了、~/.claude.json 还在的半截状态。
        if ! { mv "$CLI_JSON" "$staged/home.json" 2>/dev/null \
               || { cp -p "$CLI_JSON" "$staged/home.json" 2>/dev/null && rm -f "$CLI_JSON"; }; }; then
            if [ "$moved" -eq 1 ]; then mv "$staged/home" "$CLI_DIR" 2>/dev/null; fi
            rm -rf "$staged"
            log "FAIL:账号$cur 的 ~/.claude.json 归档失败"
            return 1
        fi
    fi

    if [ -e "$current" ]; then
        if ! mv "$current" "$previous"; then
            if [ "$moved" -eq 1 ]; then mv "$staged/home" "$CLI_DIR" 2>/dev/null; fi
            rm -rf "$staged"
            log "FAIL:账号$cur 旧 Claude Code 快照无法转存"
            return 1
        fi
        had_old=1
    fi
    if ! mv "$staged" "$current"; then
        if [ "$had_old" -eq 1 ]; then mv "$previous" "$current" 2>/dev/null; fi
        rm -rf "$staged"
        log "FAIL:账号$cur Claude Code 快照提交失败"
        return 1
    fi
    [ "$had_old" -eq 1 ] && rm -rf "$previous"
    return 0
}

# 把目标槽位的 Claude Code 状态放回原位。目标没有存档时**清空**现场 ——
# 这才是「每个槽位一套环境」:不然没存过的槽位会接着用上一个账号的登录态。
restore_cli() {
    local target="$1"
    local src="$CLI_BASE/$1" staged="$CLI_BASE/$1.new"
    rm -rf "$staged"
    if [ -d "$src" ]; then
        copy_tree "$src" "$staged" || { log "FAIL:账号$target 的 Claude Code 快照载入失败"; return 1; }
    else
        mkdir -p "$staged" || return 1
    fi
    rm -rf "$CLI_DIR" 2>/dev/null
    rm -f "$CLI_JSON" 2>/dev/null
    if [ -d "$staged/home" ] && ! mv "$staged/home" "$CLI_DIR"; then
        log "FAIL:账号$target 的 Claude Code 目录还原失败"
        return 1
    fi
    if [ -f "$staged/home.json" ] && ! mv "$staged/home.json" "$CLI_JSON"; then
        log "FAIL:账号$target 的 ~/.claude.json 还原失败"
        return 1
    fi
    rm -rf "$staged"
    return 0
}

# 快照复制:APFS 上用 clonefile(COW) 近乎瞬时,不改写已有快照;不支持时回退 ditto 全量复制
copy_tree() {
    src="$1"; dst="$2"
    if [ "${CLAUDE_SWITCHER_NO_CLONE:-0}" != "1" ] && cp -cRp "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dst"
    ditto "$src" "$dst"
}

# 只接受 A-D 四个账号槽位
# 槽位名 = 一个大写字母,上限 8 个(A–H)。
#
# 原来写死 A|B|C|D:四个槽位是"够用"不是"必须"。实际用起来是
# 工作号 + 私人号 + 两个客户的,第五个就得先删一个才有位置 —— 而槽位是
# 一份几百兆的归档,删掉就是真丢。字母表本来就够用,没必要设这个上限。
# 用函数而不是全局变量:槽位列表被 status 和校验各用一次,写成全局的话
# 单测只抽函数会漏掉赋值,status 在 set -u 下直接报未绑定变量。
slots() {
    printf 'A B C D E F G H\n'
}

valid_account() {
    case "${1:-}" in
        [A-H]) return 0 ;;
        *) echo "FAIL:不是有效槽位(可用 A–H)"; return 1 ;;
    esac
}

# ---------- 跨身份保留(可选) ----------
# 校验相对路径的每个分量都不是符号链接,避免把 DATA 外的内容带进快照
keep_path_safe() {
    local rel="$1" prefix="$DATA" part
    while [ -n "$rel" ]; do
        part="${rel%%/*}"
        if [ "$part" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
        [ -z "$part" ] && continue
        prefix="$prefix/$part"
        [ -L "$prefix" ] && return 1
    done
    return 0
}

# 归档当前账号之前,把 keep 列表里存在的路径收进暂存目录
stage_keep_paths() {
    local keepf="$BASE/keep-in-workspace.txt"
    local stage="$BASE/keep-stage"
    local rel src dst count=0
    KEEP_STAGED=0
    [ -f "$keepf" ] || return 0
    # 上次还原失败时 stage 可能是唯一完整副本,不自动覆盖
    if [ -e "$stage" ] || [ -L "$stage" ]; then
        log "FAIL:跨身份保留暂存目录已存在，请检查或重试上次切换: $stage"
        return 1
    fi
    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel%$'\r'}"
        case "$rel" in
            ''|'#'*|[[:space:]]*'#'*) continue ;;
            /*) log "WARN:keep 路径必须是相对路径，已跳过: $rel"; continue ;;
            *..*) log "WARN:keep 路径不能包含 ..，已跳过: $rel"; continue ;;
        esac
        while [ "${rel%/}" != "$rel" ]; do rel="${rel%/}"; done
        while [ "${rel#./}" != "$rel" ]; do rel="${rel#./}"; done
        if [ -z "$rel" ] || [ "$rel" = "." ]; then
            log "WARN:keep 路径为空或指向数据目录本身，已跳过: $rel"
            continue
        fi
        if ! keep_path_safe "$rel"; then
            log "WARN:keep 路径含符号链接，已跳过: $rel"
            continue
        fi
        src="$DATA/$rel"
        [ -e "$src" ] || continue
        dst="$stage/$rel"
        if ! mkdir -p "$(dirname "$dst")" || ! ditto "$src" "$dst"; then
            rm -rf "$stage"
            log "FAIL:跨身份保留暂存失败"
            return 1
        fi
        count=$((count + 1))
    done < "$keepf"
    if [ "$count" -eq 0 ]; then
        rm -rf "$stage"
        log "跨身份保留:没有需要保留的路径"
        return 0
    fi
    KEEP_STAGED=$count
    log "跨身份保留:已收起 $count 条路径"
    return 0
}

# 还原目标账号后,把暂存内容合并回 DATA;失败时保留 stage 供排查
require_lease_for_launch() {
    # 只有新报告存在时才启用租约门禁。旧核心没有 last-report.json，
    # 不能因为升级前留下的旧环境把 CLI 切换永久卡死；
    # 没有 support 函数的是单元测试抽出的函数段，直接放行。
    [ -f "$BASE/last-report.json" ] || return 0
    [ "${CLAUDE_SWITCHER_REQUIRE_LEASE:-1}" = "1" ] || return 0
    declare -F support >/dev/null 2>&1 || return 0
    if ! support lease-check "$0" >/dev/null 2>&1; then
        echo "FAIL:启动租约无效，请先运行 checkdetail --json 并通过检查"
        return 1
    fi
    return 0
}

restore_keep_paths() {
    local stage="$BASE/keep-stage"
    [ -d "$stage" ] || return 0
    if ! ditto "$stage/" "$DATA/"; then
        log "FAIL:跨身份保留还原失败，暂存保留在 $stage"
        return 1
    fi
    rm -rf "$stage"
    log "跨身份保留:已还原 ${KEEP_STAGED:-0} 条路径到新账号"
    return 0
}

switch_to() {
    target="${1:-}"
    valid_account "$target" || return 1
    # 槽位现在也换 ~/.claude。终端里开着 claude 就动它,等于把正在写的目录
    # 抽走 —— 必须让人先退出。桌面 App 能 osascript 优雅退出,CLI 没有这个口子。
    if claude_cli_running; then
        echo "FAIL:Claude Code 正在运行，请先在终端退出（切换会换掉 ~/.claude）"
        return 1
    fi
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    just_archived=0

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current A || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:首次账号归档失败，已停止切换"; return 1
        }
        archive_cli A || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:首次归档 Claude Code 状态失败，已停止切换"; return 1
        }
        just_archived=1
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        # 归档是移动语义;首次收编或上次切换中断后,先用存档恢复 DATA
        if [ ! -d "$DATA" ]; then
            if [ ! -d "$BASE/accounts/$target" ]; then
                echo "FAIL:账号$target 数据目录缺失，已停止切换"; return 1
            fi
            if ! copy_tree "$BASE/accounts/$target" "$DATA"; then
                echo "FAIL:账号$target 还原失败，已停止切换"; return 1
            fi
        fi
        # 上次还原失败留下的 stage,在当前账号上重试合并
        if [ -d "$BASE/keep-stage" ]; then
            restore_keep_paths || { echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"; return 1; }
        fi
        # 中断后 ~/.claude 可能已经不在原位,从存档补回来。只在现场确实缺了
        # 才动手 —— restore_cli 会先清空现场,不能拿它做「顺手刷新」。
        if [ ! -d "$CLI_DIR" ] && cli_slot_has_payload "$target"; then
            restore_cli "$target" || { echo "FAIL:账号$target 的 Claude Code 状态还原失败"; return 1; }
        fi
        require_lease_for_launch || return 1
        open -a "Claude"
        lease_revoke
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }

    if [ "$just_archived" = "0" ] && [ "$cur" != "none" ] && [ -d "$DATA" ]; then
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current "$cur" || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:账号$cur 归档失败，已停止切换"; return 1
        }
        archive_cli "$cur" || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:账号$cur 的 Claude Code 状态归档失败，已停止切换"; return 1
        }
    fi

    rm -rf "$DATA.new"
    t0=$(date +%s)
    if [ -d "$BASE/accounts/$target" ]; then
        if ! copy_tree "$BASE/accounts/$target" "$DATA.new"; then
            log "FAIL:账号$target 存档载入失败"
            echo "FAIL:账号$target 存档载入失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
        log "已载入账号$target 存档 ($(( $(date +%s) - t0 ))s)"
    else
        if ! mkdir -p "$DATA.new"; then
            log "FAIL:无法创建账号$target 数据目录"
            echo "FAIL:无法创建账号$target 数据目录"
            return 1
        fi
        log "账号$target 无存档，将以全新状态初始化"
    fi
    if ! { rm -rf "$DATA" && mv "$DATA.new" "$DATA"; }; then
        log "FAIL:载入账号$target 失败"
        echo "FAIL:载入账号$target 失败，暂存保留在 $BASE/keep-stage"
        return 1
    fi
    # 目标槽位没有 Claude Code 存档时,restore_cli 会把 ~/.claude 清空 ——
    # 这是有意的:不然没存过的槽位会接着用上一个账号的登录态,等于没隔离。
    if ! restore_cli "$target"; then
        log "FAIL:账号$target 的 Claude Code 状态还原失败"
        echo "FAIL:账号$target 的 Claude Code 状态还原失败，暂存保留在 $BASE/cli"
        return 1
    fi
    echo "$target" > "$BASE/current"

    if [ -d "$BASE/keep-stage" ]; then
        if ! restore_keep_paths; then
            echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
    fi

    require_lease_for_launch || return 1
    open -a "Claude"
    lease_revoke
    log "已切换到账号$target 并启动 ($(( $(date +%s) - t0 ))s)"
    echo "OK:已切换到账号$target ($(( $(date +%s) - t0 ))s)"
    return 0
}

# 命令说明。原来的做法是把 21 个命令塞进一行 usage 里,没有分组也没有解释 ——
# 对要交给非开发者使用的工具,等于没有说明。这里按「你什么时候会用到它」分组。
help() {
    cat <<'HELP'
用法: claude-switch.sh <命令> [参数]

日常(最常用的五个)
  checkdetail          逐项检查 16 项环境,每项给出原因和下一步
  check                只输出一行 OK / FAIL,给 App 当启动前的硬性门禁
  watch [间隔] [整轮周期]
                       运行期巡检:出口一变或任一项不合格,立刻关掉 Claude
  fix                  一键修复能自动处理的问题(规则、时区、地区、保镖)
  node-scan            只读扫描当前代理组里的候选节点,按纯净度排名并出报告
                       不切节点 / 不动巡检 / 不写 IP 漂移;已有实例时只出报告
  node-apply           把报告里的最优节点切上去并固定(仅门禁允许时)
                       切前须已停守护、切后复查出口国家,不达标自动回滚
  switch A–H           切换到某个账号并启动 Claude
  status               当前账号、出口、代理状态的摘要

出问题时
  verdict [报告]       复核一份 checkdetail 报告,给出结论(fail/config 即判违反;全关掉判「未验证」)
  report [报告]        把文本检查报告转成版本化 JSON(稳定 ID / 证据 / 配置指纹,不重新探测)
  checkdetail --json   执行检查并输出版本化 JSON,同时写 last-report.json
  lease                从当前 established 报告签发短租约(默认 120 秒)
  lease-check          校验租约仍对应当前报告 / 环境 / 核心且未过期
  evidence <file>      导出一次检查的证据
  drill [--auto|--manual] [--yes]
                       演练:关掉 TUN 后看流量是否真的出不去(fail-closed)
  diagnose-proxy [--proxy URL|--config FILE]
                       代理链路诊断,定位是节点、规则还是本地代理的问题
  fingerprint          设备指纹体检(地区特征字体 / GPU / 虚拟机;Canvas/WebGL 见 Web 检测页)
  cli-info             Claude Code CLI 只读体检(版本 / 安装方式 / 多份安装冲突)

区域与客户端
  set-region           按当前出口对齐时区 / 地区 / 语言
  set-client <mode>    指定代理客户端(clash-verge / flclash / shadowrocket / sing-box …)
  ip-baseline [show]   查看本实例的固定出口;accept 把当前出口设为新的固定出口
  set-webrtc-policy <proxy|reject>   WebRTC UDP 策略;节点不支持 UDP 时用 reject(「一键修复」会自动切)
  get-client           打印当前选定的代理客户端
  open-safe <url>      在受控环境里打开链接

槽位与出口
  切换账号会连同 Claude Code 的 ~/.claude 一起换;出口可以单独声明:
  slot-node list                   列出 A–H 各自绑定的出口节点
  slot-node get <A–H>              查看某个槽位的绑定(没绑输出 NONE)
  slot-node set <A–H> <节点名>     声明固定出口(须先 node-scan,切到该槽位时生效)
  slot-node clear <A–H>            解除绑定,切过去时改由本次扫描决定

维护
  update               更新核心脚本(校验 SHA256,自检失败自动回滚)
  update-check         只检查有没有新版本,不写入(核心 + App 一起报)
  update-app [--check] 更新 App 界面(release 通道):下载校验后原子换装,
                       失败自动回滚;连续两轮失败会熔断停用自动通道,
                       手动执行成功即解除;不打断正在运行的窗口
  announcements [check|read]
                       公告拉取(6 小时频控)与缓存读取;坏数据报错不静默
  snapshot-export <A–H> <file>        导出某个账号的快照
  snapshot-import <file> <A–H>        导入快照到某个账号
  export-diagnostics <file>           导出脱敏诊断包(不含 IP、凭据、账号内容)
  get-check-config                    读取检查项开关
  set-check-config <json>             修改检查项开关

  help                 显示这份说明

检查项的结论含义
  ok      通过
  warn    有问题但不拦启动
  config  环境没配好(代理组 / 目标国家 / 时区目标缺失),系统无从判定
  fail    已配置但实测不达标 —— 硬性项失败时 Claude 不会被拉起
  skip    你显式关掉了这一项,不代表检查通过
HELP
}

operation="${1:-}"
started_at=$(date +%s)
summary=""
case "$operation" in
    check)  check ;;
    help|-h|--help) help ;;  # 分组说明;原来只有一行 usage,非开发者无从下手
    drill)  drill "${@:2}" ;;  # fail-closed 演练:默认自动关 TUN,--manual 走手动停核
    verdict) support verdict "${2:-}" ;;
    evidence) support evidence "${2:-}" ;;
    report) support report "${2:-}" "$0" ;;
    lease) support lease "$BASE/last-report.json" "$0" ;;
    lease-check) support lease-check "$0" ;;
    lease-revoke) support lease-revoke ;;  # 隐藏入口:内部状态变更时撤销旧租约
    checkdetail)
        lease_revoke
        OUT_FILE="$BASE/last-check.txt"
        if [ "${2:-}" = "--json" ]; then
            # 同一轮检查产出两份:last-check.txt 给旧客户端,last-report.json 给新契约。
            TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/claude-check.XXXXXX")"
            CHECK_STARTED_AT="$(date '+%F %T')"
            # 逐项上报进度。JSON 分支原来把整轮输出攒进文件、跑完再生成报告,
            # 界面拿到的是「16 项一起亮」—— 检查那几秒里进度条始终是 0,
            # 用户分不清「在查」和「卡死」。文本分支早就用 tee 边查边吐了,
            # 这里补上同样的能力:报告正文照旧进 TMP_OUT(JSON 由它生成),
            # 同时把每一行原样写到 fd 3 = 脚本自己的 stderr —— 那也是界面读的
            # 那一路,于是每查完一项,界面就落定一行。
            exec 3>&2
            {
                echo "# $CHECK_STARTED_AT pid=$$ 开始"
                checkdetail | while IFS= read -r line; do
                    printf '%s\n' "$line"
                    # 只转发「名=状态」的报告行:开头由 report 生成的 JSON 不带它,
                    # 带空格的行(警告/INFO)也不是检查项,别让它们冒充进度。
                    case "$line" in
                        *=*)
                            name=${line%%=*}
                            case "$name" in
                                *' '*) ;;
                                *) printf '%s\n' "$line" >&3 ;;
                            esac
                            ;;
                    esac
                done
                # 管道会把 checkdetail 放进子 shell,退出码得从 PIPESTATUS 取,
                # 否则拿到的是 while 的退出码 —— 永远是 0,失败会被吞。
                check_rc=${PIPESTATUS[0]}
                echo "# 结束"
            } >"$TMP_OUT" 2>&1
            exec 3>&-
            cp "$TMP_OUT" "$OUT_FILE"
            rm -f "$TMP_OUT"
            chmod 600 "$OUT_FILE" 2>/dev/null || true
            # 代理链路探测是可选 sidecar:失败只让报告缺 probes,不能让整轮检查失败。
            # 它用报告头同一个 started_at 绑定,避免把上一次探测混进新报告。
            support probe "$CHECK_STARTED_AT" >/dev/null 2>&1 || true
            if support report "$OUT_FILE" "$0" > "$BASE/last-report.json" 2>/dev/null; then
                cat "$BASE/last-report.json"
            else
                echo '{"schema":"claude-switcher-report/2","protocol":2,"verdict":"incomplete","error":"report generation failed"}'
                check_rc=1
            fi
            chmod 600 "$BASE/last-report.json" 2>/dev/null || true
            rc=${check_rc:-1}
            summary=$(awk -F= '{ split($2, s, ":"); if ($1 != "" && s[1] ~ /^(ok|warn|fail|skip|config)$/) print $1 "=" s[1] }' "$OUT_FILE" | tr '\n' ' ')
        else
            # 直接 tee 到 stdout,不要再「先写文件、跑完再 cat」:那等于把十几秒的检查
            # 结果压到最后一次性吐出来,界面只能干等。bash 的 echo 是逐行刷新的,
            # tee 原样转发,界面才能边查边显示。
            {
                echo "# $(date '+%F %T') pid=$$ 开始"
                checkdetail
                rc=$?
                echo "# 结束"
            } 2>&1 | tee "$OUT_FILE"
            # 输出里有出口 IP;umask 077 只影响新文件,老安装留下的 644 在这里一并收紧。
            chmod 600 "$OUT_FILE" 2>/dev/null || true
            summary=$(awk -F= '{ split($2, s, ":"); if ($1 != "" && s[1] ~ /^(ok|warn|fail|skip|config)$/) print $1 "=" s[1] }' "$OUT_FILE" | tr '\n' ' ')
        fi
        ;;
    fix) lease_revoke; fix ;;
    set-webrtc-policy) lease_revoke; set_webrtc_policy "${2:-}" ;;
    node-scan) scan_nodes ;;
    node-apply) node_apply "${2:-}" ;;
    slot-node)
        case "${2:-list}" in
            list)  slot_node_list ;;
            get)   slot_node_show "${3:-}" ;;
            set)   slot_node_set "${3:-}" "${4:-}" "${5:-}" ;;
            clear) slot_node_clear "${3:-}" ;;
            *) echo "FAIL:slot-node 支持 list | get <A–H> | set <A–H> <节点名> | clear <A–H>"; return 1 ;;
        esac ;;
    watch) watch "${2:-10}" "${3:-6}" ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    set-region) lease_revoke; set_region ;;
    set-client) set_client "${2:-}" ;;
    ip-baseline)
        case "${2:-show}" in
            show|'') b=$(ip_baseline_get)
                if [ -z "$b" ]; then printf 'NONE(还没记录)\n'
                else printf '%s  已固定 %s\n' "$(ip_show "$b")" "$(ip_baseline_age)"; fi ;;
            accept)
                _cur=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
                if [ -z "$_cur" ]; then echo "FAIL:取不到当前出口,基线未改动 · 检查代理后重试"; return 1; fi
                _k=$(ip_key "$_cur")
                if ip_baseline_set "$_k"; then
                    echo "OK:$(current_instance | sed 's/^$/默认/') 实例的固定出口已更新为 $(ip_show "$_k")"
                else
                    echo "FAIL:写入基线失败"; return 1
                fi ;;
            *)
                echo "FAIL:ip-baseline 支持 show | accept"; return 1 ;;
        esac ;;
    get-client) get_client ;;
    fake-prefix) printf '%s\n' "${FAKE_PREFIX:-198.18.}" ;;
    restart-clash) restart_clash ;;
    update) lease_revoke; self_update "${2:-}"
        # App 自更新(阶段二):--auto 时接在核心更新之后,同一份 update.log;
        # self_update --auto 的 exec 重定向是进程级的,子调用输出自然落日志。
        # 两个步骤互不阻塞:App 下载失败不影响核心已完成的更新。
        if [ "${2:-}" = "--auto" ]; then app_self_update --auto ""; fi ;;
    update-check) self_update --check; app_self_update "" "--check" ;;  # 只读检查;独立入口,避免旧版核心把 --check 当成真实更新
    announcements) announcements_check "${2:-}" ;;  # 公告:check [--force] / read
    update-app) app_self_update "manual" "${2:-}" ;;  # App 自更新:[] 或 --check
    open-safe) open_safe "${2:-}" ;;
    cli-info) cli_info ;;
    snapshot-export) snapshot_export "${2:-}" "${3:-}" "${4:-}" ;;
    snapshot-import) snapshot_import "${2:-}" "${3:-}" "${4:-}" ;;
    export-diagnostics) "$0" _support export-diagnostics "${2:-}" ;;
    get-check-config) "$0" _support config-get ;;
    set-check-config) "$0" _support config-set "${2:-}" ;;
    write-merge-rules) write_merge_rules ;;  # 隐藏入口:供安装器调用,保证两处合并逻辑一致
    fingerprint) fingerprint ;;
    # 未知命令:不再甩一行 21 个命令的 usage —— 用户多半是打错了,
    # 直接指到 help 比让他从一长串里找更省事。
    *)
        [ -n "$operation" ] && echo "未知命令: $operation" >&2
        echo "运行 claude-switch.sh help 查看全部命令" >&2
        exit 2 ;;
esac
rc=$?
case "$operation" in
    get-check-config|set-check-config|export-diagnostics) ;;
    *) log_result "$started_at" "$operation" "$rc" "$summary" ;;
esac
exit "$rc"
