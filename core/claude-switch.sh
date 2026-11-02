#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B|C|D | checkdetail | fix | set-region | update [--check|--auto] | diagnose-proxy
set -u
export LC_ALL=en_US.UTF-8

if [ "${1:-}" = "_support" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_SUPPORT'
import datetime
import json
import os
from pathlib import Path
import platform
import re
import sys
import tempfile
import zipfile


OPTIONAL = ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性")
ALL_CHECKS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
              "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性")
DEFAULTS = {"disabled": [], "allowOptionalFailures": False, "logging": True}
LOG_LIMIT = 512 * 1024


def fail():
    print("配置或诊断参数无效", file=sys.stderr)
    raise SystemExit(2)


def paths():
    home = Path.home()
    return home / ".claude-switcher", home / "Library/Logs/claude-switcher/client.log"


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
    for key in ("allowOptionalFailures", "logging"):
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
        os.chmod(destination, 0o600)
    except OSError:
        fail()
    print("OK:诊断日志已导出（不含 IP、凭据、账号或代理配置）")


def main(args):
    if not args:
        fail()
    action = args[0]
    if action == "config" and len(args) == 1:
        config = load_config()
        print("disabled=" + ",".join(config["disabled"]))
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
        except OSError:
            fail()
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
from urllib.parse import urlsplit


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
                fail("运行规则未按策略置顶:UDP/" + str(value))
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
        return pattern.sub(lambda _: block, old, count=1)
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
    write_changes(changes)
    print("OK:全局脚本已写入(" + policy + ")")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, AttributeError):
        fail("规则配置处理失败，未确认修复；请检查配置格式与权限")
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
LOG="$HOME/Library/Logs/claude-switch.log"
ROUTE_MISSED=""
KEEP_STAGED=0
mkdir -p "$BASE/accounts"

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

# 把 fake-ip 网段换算成 case 能用的前缀:198.18.0.1/16 → "198.18."
fake_ip_prefix() {
    local range="${1:-}" a b
    a="${range%%.*}"
    b="${range#*.}"; b="${b%%.*}"
    if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$a.$b."
    else
        printf '%s\n' "198.18."
    fi
}

# 自调用 _support:一律经当前 shell 重新执行本脚本。
# 直接 "$0" 调用在脚本没有可执行位时(例如仓库里 `bash core/claude-switch.sh` 跑测试)
# 会 permission denied,被上层误判成「配置损坏」。
support() { "${BASH:-/bin/bash}" "$0" _support "$@"; }

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
                proxy_mode)    [ -n "$value" ] && PROXY_MODE="$value" ;;
                proxy_group)   PROXY_GROUP="$value" ;;
                country)       [ -n "$value" ] && COUNTRY_TARGET="$value" ;;
                timezone)      [ -n "$value" ] && TZ_TARGET="$value" ;;
                locale)        [ -n "$value" ] && LOCALE_TARGET="$value" ;;
                clash_dir)     CLASH_DIR="$value" ;;
                fake_ip_range) FAKE_IP_RANGE="$value" ;;
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
ALLOW_OPTIONAL_FAILURES=0
load_check_config() {
    local config key value
    config=$(support config 2>/dev/null) || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            disabled) CHECKS_DISABLED="$value" ;;
            allowOptionalFailures) ALLOW_OPTIONAL_FAILURES="$value" ;;
        esac
    done <<< "$config"
}
check_disabled() { case ",$CHECKS_DISABLED," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
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
tun_up() { ifconfig 2>/dev/null | grep -q "inet ${FAKE_PREFIX:-198.18.}"; }

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

# 只接受运行中内核加载的规则，不再用配置文本或 fake-ip 代替。
merge_ok() { clash_rules verify >/dev/null 2>&1; }
stun_ok() { merge_ok; }

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
            printf '配置的代理组在客户端里不存在 · 点「一键修复」重新选择' ;;
        *没有可用的当前节点*|*直连或拒绝*)
            printf '代理组当前节点是直连或拒绝 · 换一个代理节点' ;;
        *UDP*)
            printf '节点未确认支持 UDP · 换节点或改用拒绝策略' ;;
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
ip_org() {
    [ "$IP_ORG_LOOKED" = "1" ] && { printf '%s' "$IP_ORG"; return 0; }
    IP_ORG_LOOKED="1"
    [ -z "${1:-}" ] && return 0
    local ip="$1" now cip corg cts tmp
    now=$(date +%s)
    if [ -n "${BASE:-}" ] && [ -f "$BASE/org-cache" ]; then
        while IFS=$(printf '\t') read -r cip corg cts; do
            [ "$cip" = "$ip" ] && [ -n "$corg" ] || continue
            case "${cts:-}" in ''|*[!0-9]*) continue ;; esac
            if [ $((now - cts)) -lt "$ORG_CACHE_TTL" ]; then
                IP_ORG="$corg"; printf '%s' "$IP_ORG"; return 0
            fi
            break
        done < "$BASE/org-cache"
    fi
    # 必须查「实际出口 IP」的 ASN。直接查 ipinfo.io/json 取的是访问 ipinfo 自身
    # 那条链路的出口,在分流配置下可能与受保护流量的出口不是同一个 IP,
    # 从而报出不相干的 ASN(例如受保护出口是机房 A,却报成 Cloudflare)。
    IP_ORG=$(curl -s --max-time 6 "https://ipinfo.io/$1/json" 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    # 查不到就不写缓存:否则一次网络抖动会把「未知」钉住 24 小时
    if [ -n "${BASE:-}" ] && [ -n "$IP_ORG" ]; then
        tmp="$BASE/org-cache.tmp"
        { [ -f "$BASE/org-cache" ] && grep -vF "$ip"$'\t' "$BASE/org-cache"
          printf '%s\t%s\t%s\n' "$ip" "$IP_ORG" "$now"; } 2>/dev/null | tail -20 > "$tmp" \
            && mv "$tmp" "$BASE/org-cache"
    fi
    printf '%s' "$IP_ORG"
}

# 出口类型:residential(运营商宽带) / hosting(机房) / unknown。
# 参考 net.coffee 的 Claude Code 指南第 2 条:家宽 IP 定期变动是正常网络行为,
# 机房 IP 变动才是风控信号。所以「IP 变了」这件事不能一律同等对待 ——
# 拿同一个阈值套两种出口,结果就是家宽用户天天看到假警报、机房用户没被提醒。
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
        *) printf 'hosting' ;;
    esac
}


# IP 审查:记录出口IP并统计最近48h内不同出口个数(账号画像风险指标)
iphist_count() {
    [ -z "$1" ] && { echo 0; return; }
    local HIST="$BASE/iphistory.log"
    local now=$(date +%s) n
    echo "$1 $now" >>"$HIST"
    # 裁掉48小时(172800秒)以前的记录
    awk -v cutoff=$((now-172800)) '$2>=cutoff' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    # 按协议族分别去重后取最大值。双栈节点 v4 与 v6 是同一出口的两条腿,
    # 直接混在一起数会把一个节点算成两个;而只取某一族又会漏掉另一族的变化。
    # 取最大值:任一族换了地址就算一次变化,两条腿都没动就是 0 次新增。
    # ip_key 不带换行(给命令替换用),这里得自己补,否则多行会被 sort 当成一行。
    # read 在「最后一行没有换行」时返回非零,不补 || 判断的话整段会被跳过。
    n=$(while read -r addr _ || [ -n "$addr" ]; do
            [ -n "$addr" ] || continue
            ip_key "$addr"; echo
        done < "$HIST" | sort -u | cut -d: -f1 | uniq -c | sort -rn | head -1 | awk '{print $1}')
    echo "${n:-0}"
}

# 上次记录的出口身份,按协议族分开取。v4 与 v6 不可比 —— 拿一个去比另一个,
# 只会得出「IP 变了」,而实际只是这次连接走了另一条腿。
last_seen() {
    local fam="$1" line
    [ -f "$BASE/lastip" ] || return 0
    while read -r line || [ -n "$line" ]; do
        line=$(ip_key_migrate "$line")
        case "$line" in "$fam":*) printf '%s' "$line"; return 0 ;; esac
    done < "$BASE/lastip"
}

# 写入本次出口身份,保留另一族的记录(两族各自维护自己的「上次」)。
last_save() {
    local k="$1" fam tmp="$BASE/lastip.tmp" line
    case "$k" in v6:*) fam=v6 ;; *) fam=v4 ;; esac
    : > "$tmp"
    if [ -f "$BASE/lastip" ]; then
        while read -r line || [ -n "$line" ]; do
            line=$(ip_key_migrate "$line")
            [ -n "$line" ] || continue
            case "$line" in "$fam":*) continue ;; esac
            printf '%s\n' "$line" >> "$tmp"
        done < "$BASE/lastip"
    fi
    printf '%s\n' "$k" >> "$tmp"
    mv "$tmp" "$BASE/lastip"
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
            changed=""
            [ -n "$lastip" ] && [ "$curkey" != "$lastip" ] && changed="1"

            # IP 审查:48h 内不同出口个数(账号画像风险指标)
            ipn=$(iphist_count "$curkey")

            # 只有「变了」或「次数到了」才去查 ASN —— 正常路径不多付一次网络请求。
            need_org=""
            [ -n "$changed" ] && need_org="1"
            case "${ipn:-0}" in ''|*[!0-9]*) ;; *) [ "$ipn" -ge 3 ] && need_org="1" ;; esac
            klass=""
            [ -n "$need_org" ] && klass=$(ip_class "$(ip_org "$ip")")

            case "$klass" in
                residential)
                    # 家宽换 IP 是运营商在正常轮换,不告警;次数多也不代表风控风险。
                    ;;
                hosting)
                    if [ -n "$changed" ]; then
                        ipwarn="注意:机房 IP 发生变动($(ip_show "$lastip") -> $(ip_show "$curkey")) · 机房出口应固定一个长期使用"
                    elif [ "${ipn:-0}" -ge 3 ] 2>/dev/null; then
                        ipwarn="注意:48h内机房出口变动${ipn}次 · 机房 IP 漂移是明确的风控信号,固定一个出口"
                    fi ;;
                *)
                    # 类型未知时按原来的保守口径:变了就提示,不猜它是家宽还是机房。
                    if [ -n "$changed" ]; then
                        ipwarn="注意:出口IP与上次不同($(ip_show "$lastip") -> $(ip_show "$curkey"))"
                    elif [ "${ipn:-0}" -ge 3 ] 2>/dev/null; then
                        ipwarn="注意:48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
                    fi ;;
            esac
            last_save "$curkey"
        fi
    fi

    # 时区/地区/目标国家缺失是环境层没配好,不是实测不达标 —— 提示语必须分开,
    # 否则用户会拿着「时区异常」去改时区,而真正错的是目标值。
    tz=$(readlink /etc/localtime 2>/dev/null); tz=${tz##*/zoneinfo/}
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

    if ! check_disabled "生态可达性"; then
        r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
        r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
        { [ "$r1" = "000" ] || [ "$r2" = "000" ]; } && optional_failure "Anthropic生态不可达($r1/$r2)"
    fi

    # 关掉某项防护是用户自己的选择,但不能是「悄悄没了」:门禁输出里必须留痕。
    # 命令行、日志、自动化这些看不到界面的地方,靠这一句才知道本次判定是降级过的。
    degrade=""
    if [ -n "${CHECKS_DISABLED:-}" ]; then
        degrade="防护降级:${CHECKS_DISABLED//,/、} 已关闭,未参与本次判定"
    fi

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:${ip:-未确认}${ipwarn:+|$ipwarn}${degrade:+|$degrade}"
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
drill() {
    local mode="auto" answer="" baseline after leaked out code result waited i arg
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
    for i in 1 2 3; do
        out=$(curl -s --max-time 4 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
        [ -n "$out" ] && leaked="$leaked $out"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --noproxy '*' http://1.1.1.1/ 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && leaked="$leaked bare-ip-http-$code"
    done
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
        echo "INFO:恢复 TUN"
        tun_set true || { echo "FAIL:恢复 TUN 失败,请在 Clash Verge 里手动开启"; return 1; }
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [ "$(tun_state)" = "true" ] && break
            sleep 1
        done
        [ "$(tun_state)" = "true" ] || { echo "FAIL:恢复 TUN 失败,请在 Clash Verge 里手动开启"; return 1; }
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
    fi
    probe_egress 3
    [ "$PROBE_STATUS" = "ok" ] || echo "WARN:内核已起但出口未恢复采样($PROBE_STATUS),请人工确认"
    if [ -n "$PROBE_IP" ] && [ "$PROBE_IP" != "$baseline" ]; then
        echo "WARN:恢复后出口与基准不同($baseline -> $PROBE_IP),节点可能已切换"
    fi
    trap - EXIT INT TERM

    echo "出口IP=${PROBE_IP:-未确认} 演练=$result"
    [ -n "$BASE" ] && echo "$(date +%s) baseline=$baseline after=${PROBE_IP:-none} result=$result" >> "$BASE/drill.log"
    [ "${result%%:*}" = "established" ]
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    python3 "$BASE/stun-probe.py" 2>/dev/null
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
                    echo "warn:出口只有 IPv6,STUN 结果无法比对"
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
    lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
    echo "ok:${lastkill:-待命}"
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
        # v6 出口单独标一下:用户看到一串冒号地址会以为哪里不对,实际只是走了 IPv6。
        case "$ip" in
            *:*) echo "出口IP=ok:$ip/$loc (IPv6 出口)" ;;
            *)   echo "出口IP=ok:$ip/$loc" ;;
        esac
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
            # IP 审查:48h 内不同出口个数(账号画像风险指标)
            ipn=$(iphist_count "$curkey")
            changed=""; [ -n "$lastip" ] && [ "$curkey" != "$lastip" ] && changed="1"
            need_org=""
            [ -n "$changed" ] && need_org="1"
            case "${ipn:-0}" in ''|*[!0-9]*) ;; *) [ "$ipn" -ge 3 ] && need_org="1" ;; esac
            klass=""
            [ -n "$need_org" ] && klass=$(ip_class "$(ip_org "$ip")")

            if [ -z "$lastip" ]; then ipst="ok"; ipdt="首次记录"
            elif [ -z "$changed" ]; then ipst="ok"
            else
                case "$klass" in
                    residential) ipst="ok"; ipdt="住宅 IP 变动 · 运营商正常轮换,不算风险" ;;
                    hosting) ipst="warn"; ipdt="机房 IP 变动:$(ip_show "$lastip") → $(ip_show "$curkey") · 机房出口应固定一个" ;;
                    *) ipst="warn"; ipdt="$(ip_show "$lastip") → $(ip_show "$curkey")" ;;
                esac
            fi
            # 次数阈值同样分类型:家宽轮换再多次也不构成风险信号。
            # 文案要说明「哪一类出口」在变 —— 只写「出口变动 7 次」,用户不知道
            # 这是家宽的正常轮换还是机房漂移,也就不知道该不该处理。
            if [ "${ipn:-0}" -ge 3 ] 2>/dev/null && [ "$klass" != "residential" ]; then
                label="出口"
                [ "$klass" = "hosting" ] && label="机房出口"
                if [ "$ipst" = "ok" ]; then
                    ipst="warn"; ipdt="48h内${label}变动${ipn}次,建议固定节点"
                else
                    ipdt="$ipdt;48h内${label}变动${ipn}次"
                fi
            fi
            last_save "$curkey"
        fi
        optional_result "IP一致" "$ipst" "$ipdt"
    fi
    # 时区/地区:报「当前值 vs 期望值」,不报 readlink 的完整路径。
    # 原来直接打印 /var/db/timezone/zoneinfo/America/Los_Angeles,看起来像系统坏了,
    # 实际只是目标值和当前值不一致 —— 用户看不出该改哪一边。
    tz=$(readlink /etc/localtime 2>/dev/null); tz=${tz##*/zoneinfo/}
    if [ -z "$TZ_TARGET" ]; then
        config_result "时区" "环境层未就绪(未取到时区目标) · 点「一键修复」"
    elif [ "$tz" != "$TZ_TARGET" ]; then
        echo "时区=fail:当前 ${tz:-未知},期望 $TZ_TARGET · 点「一键修复」对齐"
    else
        # 时区对了还不够:看门狗若守着别的目标,会在 5 分钟内把它改回去,
        # 用户只会看到「修好了又坏了」。这一条以前从来没检查过。
        wt=$(tz_watchdog_target)
        if [ -n "$wt" ] && [ "$wt" != "$TZ_TARGET" ]; then
            echo "时区=warn:当前值正确,但看门狗仍守着 $wt · 会自己改回去,点「一键修复」同步"
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
        echo 'IPv6=ok:已关闭'
    else
        echo "IPv6=fail:未关闭($v6) · 点「一键修复」"
    fi
    if check_disabled "DNS"; then
        optional_result "DNS" ok
    else
        dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsip" in
            "$FAKE_PREFIX"*) optional_result "DNS" ok "走隧道" ;;
            *) optional_result "DNS" fail "未走隧道(${dnsip:-空})" ;;
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
            *)           optional_result "ASN属性" warn "未获取" ;;
        esac
    fi
    # 14. Anthropic 生态可达性
    if check_disabled "生态可达性"; then
        optional_result "生态可达性" ok
    else
        # 首包时间顺手带上:参考里的「路径要短且干净」是一条,但我们只能观测、不能判断,
        # 所以只报数字,不替你下结论(亚洲访问 100ms 以上本来也正常)。
        r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}:%{time_starttransfer}' https://claude.ai/ 2>/dev/null)
        r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}:%{time_starttransfer}' https://api.anthropic.com/v1/models 2>/dev/null)
        c1=${r1%%:*}; t1=${r1##*:}
        c2=${r2%%:*}; t2=${r2##*:}
        [ -z "$c1" ] && c1="000"
        [ -z "$c2" ] && c2="000"
        ms2=$(awk -v t="${t2:-0}" 'BEGIN{printf "%d", t*1000+0.5}' 2>/dev/null)
        detail="claude.ai:$c1 api:$c2"
        case "${ms2:-}" in ''|*[!0-9]*|0) ;; *) detail="$detail · api 首包 ${ms2}ms" ;; esac
        if [ "$c1" != "000" ] && [ "$c2" != "000" ]; then
            optional_result "生态可达性" ok "$detail"
        else
            optional_result "生态可达性" fail "$detail · 换条线路后重新检查"
        fi
    fi
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

# 一键修复:按项自动修复,每步输出结果
fix() {
    if [ "$PROXY_MODE" = "flclash" ]; then
        fix_flclash || return 1
    fi
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        local policy_result
        if ! policy_result=$(clash_rules policy 2>&1); then
            echo "FIX:WebRTC 策略无效 ✗ $policy_result"
            return 1
        fi
        WEBRTC_POLICY="$policy_result"
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
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(ipv6_on_services)
    adminCmds=""
    [ "$tz" != "/var/db/timezone/zoneinfo/$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $TZ_TARGET; "
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
        adminCmds="${adminCmds}/usr/bin/sed -i '' 's|^TARGET=.*|TARGET=$TZ_TARGET|' '/Library/Application Support/claude-switcher/tz-watchdog.sh'; "
    fi
    # 装了 plist 却没 bootstrap(重装/系统升级后常见)时,看门狗是死的,一并拉起来
    if [ -f /Library/LaunchDaemons/local.tz-watchdog.plist ] && ! launchctl print system/local.tz-watchdog >/dev/null 2>&1; then
        adminCmds="${adminCmds}launchctl bootstrap system /Library/LaunchDaemons/local.tz-watchdog.plist; "
    fi
    echo "$v6" | grep -qi 'off' || adminCmds="${adminCmds}networksetup -setv6off Wi-Fi; "
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        adminCmds="${adminCmds}cp $HOME/.local/bin/local.claude-bodyguard.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist && launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist; "
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
        echo "FIX:写入全局扩展脚本(保留已有 main 与无关配置)..."
        local rules_result
        if ! rules_result=$(write_merge_rules 2>&1); then
            echo "FIX:置顶规则 ✗ $rules_result"
            return 1
        fi
        quit_clash_verge
        open -a "Clash Verge"
        for i in $(seq 1 40); do tun_up && break; sleep 1; done
        local loaded=0
        for i in $(seq 1 5); do
            if rules_result=$(clash_rules verify 2>&1); then loaded=1; break; fi
            sleep 1
        done
        if [ "$loaded" -ne 1 ]; then
            echo "FIX:置顶规则 ✗ 未验证内核加载:$rules_result"
            echo "FIX:请检查全局扩展脚本是否启用、代理组是否存在，以及节点 UDP 支持"
            return 1
        fi
        echo "FIX:置顶规则 ✓ 已验证内核实际加载"
    elif [ "$PROXY_MODE" != "flclash" ] && ! route_ok; then
        echo "FIX:置顶规则 ✗ 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
    fi

    # C. 复测与日常审计共用判断，空结果、非零退出及无响应不会冒充代理成功。
    local fix_failed=0
    wrip=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
    wr=$(webrtc_status "$wrip")
    case "$wr" in
        ok:*) echo "FIX:WebRTC ✓ ${wr#ok:}" ;;
        *) echo "FIX:WebRTC ✗ ${wr#fail:}"; fix_failed=1 ;;
    esac

    # D. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
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
    adminCmds="/usr/sbin/systemsetup -settimezone $ntz"
    wdsync=0
    if [ -f "$WD" ] && [ ! -w "$WD" ]; then
        adminCmds="$adminCmds; /usr/bin/sed -i '' 's|^TARGET=.*|TARGET=$ntz|' '$WD'"
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
        sed -i '' "s|^TARGET=.*|TARGET=$ntz|" "$WD" 2>/dev/null || echo "WARN:看门狗目标未同步,请运行安装器刷新"
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
        exec >>"$BASE/update.log" 2>&1
        echo "# $(date '+%F %T') update --auto 开始"
    fi

    # 更新源。本仓库是 YOURSJEYO/claude-switcher 的 fork(MIT 许可),默认指向本 fork,
    # 否则自动更新会把上游版本盖回来、本地改动全部丢失。
    # 可用 CLAUDE_SWITCHER_UPDATE_REPO=owner/name 临时改指其他仓库(例如临时对比上游)。
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
        sed -e "s|__HOME__|$UHOME|g" -e "s|__PROXY_MODE__|$PM|g" "$NEW/daemons/claude-bodyguard.sh" > "$tmpd/bg.new"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__TZ_TARGET__|$TZV|g" "$NEW/daemons/tz-watchdog.sh" > "$tmpd/tz.new"
        if ! diff -q "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh" >/dev/null 2>&1 || \
           ! diff -q "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh" >/dev/null 2>&1; then
            echo "INFO:守护进程脚本有更新,请运行 installer/安装.command 刷新(需要密码)"
        fi
    fi
    rm -rf "$tmpd"

    # 更新后自检:root(旧版 LaunchDaemon)下切回真实用户执行,避免 defaults 读到 root 的配置
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -f '%Su' "$UHOME" 2>/dev/null)
        if [ -n "$owner" ]; then out=$(sudo -H -u "$owner" "$BIN/claude-switch.sh" checkdetail 2>&1); else out=""; fi
    else
        out=$("$BIN/claude-switch.sh" checkdetail 2>&1)
    fi
    if [ -z "$out" ] || echo "$out" | grep -q '=fail'; then
        [ -f "$BIN/claude-switch.sh.bak" ] && cp "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh"
        echo "FAIL:新版自检未通过,已自动回滚"
        return 1
    fi
    echo "OK:更新完成 $(date '+%Y-%m-%d')"
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
    echo "CanvasWebGL=info:原生检查读不到 Claude Electron 的渲染特征,请打开 Web 检测页 https://yoursjeyo.github.io/claude-switcher/ 查看 Canvas/WebGL 指纹"
}

# 账号快照加密导出/导入(macOS):AES-256 加密 DMG,密码只经 stdin 传递
# 一次性隔离浏览器:独立临时 profile,禁用非代理 UDP,关闭后销毁;URL 仅允许 http/https
# Claude Code CLI 体检:只读检测安装方式/版本/多份安装冲突,不执行卸载或重装
cli_info() {
    echo "# Claude Code CLI 体检 $(date '+%F %T')"
    path=$(command -v claude 2>/dev/null)
    if [ -n "$path" ]; then
        real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || echo "$path")
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

snapshot_export() {
    target="${1:-}"; out="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
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
    if ! printf '%s\n' "$pass" | hdiutil create -srcfolder "$stage" -volname "ClaudeSnapshot-$target" \
        -encryption AES-256 -stdinpass "$out" >/dev/null 2>&1; then
        rm -rf "$stage"; rm -f "$out"; unset pass pass2
        echo "FAIL:创建加密镜像失败"; return 1
    fi
    rm -rf "$stage"
    # 加密镜像校验必须带密码,否则 macOS 会弹出图形密码框
    if ! printf '%s\n' "$pass" | hdiutil verify -stdinpass "$out" >/dev/null 2>&1; then
        rm -f "$out"; unset pass pass2
        echo "FAIL:镜像校验失败"; return 1
    fi
    unset pass pass2
    chmod 600 "$out"
    echo "OK:账号$target 已加密导出到 $out"
}

snapshot_import() {
    file="${1:-}"; target="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
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
    if ! printf '%s\n' "$pass" | hdiutil attach -stdinpass -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null 2>&1; then
        unset pass; rm -rf "$mnt"
        echo "FAIL:密码错误或镜像损坏"; return 1
    fi
    attached=1
    unset pass

    cleanup_import() {
        [ "$attached" = "1" ] && hdiutil detach "$mnt" >/dev/null 2>&1
        rm -rf "$mnt" "$BASE/accounts/$target.new"
    }

    marker="$mnt/.claude-switcher-snapshot.json"
    if [ ! -f "$marker" ]; then
        cleanup_import
        echo "FAIL:不是本项目导出的快照镜像"; return 1
    fi
    if ! python3 - "$marker" "$target" <<'PY'
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
    local cur="none" hasA=0 hasB=0 hasC=0 hasD=0 a dir size stamp accounts="" extras=""
    [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    [ -d "$BASE/accounts/A" ] && hasA=1
    [ -d "$BASE/accounts/B" ] && hasB=1
    [ -d "$BASE/accounts/C" ] && hasC=1
    [ -d "$BASE/accounts/D" ] && hasD=1
    for a in A B C D; do
        dir="$BASE/accounts/$a"
        [ -d "$dir" ] || continue
        accounts="${accounts:+$accounts,}$a"
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        stamp=$(date -r "$dir" '+%Y-%m-%d' 2>/dev/null)
        extras="$extras acc$a=${size:-?}@${stamp:-?}"
    done
    echo "current=$cur hasA=$hasA hasB=$hasB hasC=$hasC hasD=$hasD accounts=${accounts:-none}$extras"
}

quit_claude() {
    pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
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
valid_account() {
    case "${1:-}" in
        A|B|C|D) return 0 ;;
        *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;;
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
        open -a "Claude"
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
    echo "$target" > "$BASE/current"

    if [ -d "$BASE/keep-stage" ]; then
        if ! restore_keep_paths; then
            echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
    fi

    open -a "Claude"
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
  checkdetail          逐项检查 14 项环境,每项给出原因和下一步
  check                只输出一行 OK / FAIL,给 App 当启动前的硬性门禁
  fix                  一键修复能自动处理的问题(规则、时区、地区、保镖)
  switch A|B|C|D       切换到某个账号并启动 Claude
  status               当前账号、出口、代理状态的摘要

出问题时
  verdict [报告]       复核一份 checkdetail 报告,给出结论(fail/config 即判违反;全关掉判「未验证」)
  evidence <file>      导出一次检查的证据
  drill [--auto|--manual] [--yes]
                       演练:关掉 TUN 后看流量是否真的出不去(fail-closed)
  diagnose-proxy [--proxy URL|--config FILE]
                       代理链路诊断,定位是节点、规则还是本地代理的问题
  fingerprint          打印环境指纹(时区、地区、语言、出口、客户端版本)
  cli-info             当前代理客户端的版本与配置路径

区域与客户端
  set-region           按当前出口对齐时区 / 地区 / 语言
  set-client <mode>    指定代理客户端(clash-verge / shadowrocket / sing-box …)
  get-client           打印当前选定的代理客户端
  open-safe <url>      在受控环境里打开链接

维护
  update               更新核心脚本(校验 SHA256,自检失败自动回滚)
  update-check         只检查有没有新版本,不写入
  snapshot-export <A|B|C|D> <file>    导出某个账号的快照
  snapshot-import <file> <A|B|C|D>    导入快照到某个账号
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
    checkdetail)
        OUT_FILE="$BASE/last-check.txt"
        # 直接 tee 到 stdout,不要再「先写文件、跑完再 cat」:那等于把十几秒的检查
        # 结果压到最后一次性吐出来,界面只能干等。bash 的 echo 是逐行刷新的,
        # tee 原样转发,界面才能边查边显示。
        {
            echo "# $(date '+%F %T') pid=$$ 开始"
            checkdetail
            rc=$?
            echo "# 结束"
        } 2>&1 | tee "$OUT_FILE"
        summary=$(awk -F= '{ split($2, s, ":"); if ($1 != "" && s[1] ~ /^(ok|warn|fail|skip|config)$/) print $1 "=" s[1] }' "$OUT_FILE" | tr '\n' ' ')
        ;;
    fix) fix ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    set-region) set_region ;;
    set-client) set_client "${2:-}" ;;
    get-client) get_client ;;
    update) self_update "${2:-}" ;;
    update-check) self_update --check ;;  # 只读检查;独立入口,避免旧版核心把 --check 当成真实更新
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
