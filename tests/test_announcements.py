"""公告功能(announcements check / read)的回归护栏。

钉住方案(2026-11-25)里的核心契约:
  1. 好 JSON → 校验通过、过期剔除、重复 id 去重、缓存落盘(fetched_at/source 注入,0600);
  2. 坏数据(非 JSON / schema 错 / severity 非法 / 缺必填)→ 明确报错、不写缓存、旧缓存不动;
  3. 拉取降级链:raw.githubusercontent 失败 → jsDelivr 兜底;
  4. TTL 频控:缓存 6h 内不打网络;网络全挂 → 降级旧缓存(允许过期),无缓存才报错;
  5. read 子命令纯读缓存,永不联网。
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


def extract(name):
    text = CORE.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^%s\(\) \{\n.*?^\}" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到函数 %s" % name)
    return match.group(0)


def extract_constants():
    text = CORE.read_text(encoding="utf-8")
    lines = re.findall(r"(?m)^ANNOUNCEMENTS_\w+=.*$", text)
    assert len(lines) >= 4, "ANNOUNCEMENTS_* 常量定义不全"
    return "\n".join(lines)


GOOD_ITEM = {
    "id": "2026-11-25-dns-leak-check",
    "severity": "info",
    "title": "第 16 项检查已换成「DNS 泄露」检测",
    "body_md": "审计 DNS 上游架构。",
    "min_app_version": "1.8.12",
    "max_app_version": "",
    "expires_at": "",
    "link": "",
}
CRITICAL_FUTURE = {
    "id": "2099-01-01-critical",
    "severity": "critical",
    "title": "紧急公告(未过期)",
    "body_md": "",
    "min_app_version": "",
    "max_app_version": "",
    "expires_at": "2099-01-01T00:00:00Z",
    "link": "",
}
EXPIRED_ITEM = {
    "id": "2020-01-01-old",
    "severity": "warn",
    "title": "早已过期",
    "body_md": "",
    "min_app_version": "",
    "max_app_version": "",
    "expires_at": "2020-01-01T00:00:00Z",
    "link": "",
}


class AnnouncementsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cs-ann-")
        self.home = Path(self.tmp) / "home"
        self.base = self.home / ".claude-switcher"
        self.base.mkdir(parents=True)
        self.cache = self.base / "announcements-cache.json"
        self.body = Path(self.tmp) / "body.json"

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- harness ----

    def run_harness(self, payload=None, *, curl_env=None, subcmd=None,
                    seed_cache=None, seed_cache_mtime_old=False):
        """隔离 HOME + 假 curl 跑 announcements_check/read。

        curl_env: dict 控制假 curl 行为
          CURL_FAIL_PRIMARY=1   → raw.githubusercontent 退出 7
          CURL_404_PRIMARY=1    → raw.githubusercontent 退出 22(-f 语义)
          CURL_FAIL_FALLBACK=1  → jsDelivr 退出 7
        """
        if payload is not None:
            self.body.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        fake_curl = r"""
CALLS="$FAKE_DIR/curl-calls"
curl() {
    echo "$1 $*" >> "$CALLS"
    local url="" a
    for a in "$@"; do
        case "$a" in http://*|https://*) url="$a" ;; esac
    done
    case "$url" in
        *raw.githubusercontent*)
            [ "${CURL_FAIL_PRIMARY:-0}" = "1" ] && { echo "curl: (7)" >&2; exit 7; }
            [ "${CURL_404_PRIMARY:-0}" = "1" ] && { echo "curl: (22) 404" >&2; exit 22; }
            cat "$FAKE_BODY" ;;
        *jsdelivr*)
            [ "${CURL_FAIL_FALLBACK:-0}" = "1" ] && { echo "curl: (7)" >&2; exit 7; }
            cat "$FAKE_BODY" ;;
        *) echo "curl: unexpected url $url" >&2; exit 7 ;;
    esac
}
"""
        harness = "\n".join([
            'set -u',
            'BASE="%s"' % self.base,
            extract_constants(),
            'FAKE_BODY="%s"' % self.body,
            'FAKE_DIR="%s"' % self.tmp,
            'CURL_FAIL_PRIMARY=%d' % (curl_env or {}).get("CURL_FAIL_PRIMARY", 0),
            'CURL_404_PRIMARY=%d' % (curl_env or {}).get("CURL_404_PRIMARY", 0),
            'CURL_FAIL_FALLBACK=%d' % (curl_env or {}).get("CURL_FAIL_FALLBACK", 0),
            fake_curl,
            extract("announcements_validate"),
            extract("announcements_check"),
            'rm -f "$FAKE_DIR/curl-calls"',
            'announcements_check "${1:-}"',  # 实际执行:$1 来自 subcmd
        ])
        if seed_cache is not None:
            self.cache.write_text(seed_cache, encoding="utf-8")
            if seed_cache_mtime_old:
                subprocess.run(["/usr/bin/touch", "-t", "202001010000", str(self.cache)], check=True)
        args = ["/bin/bash", "-c", harness, "cs-test"]
        if subcmd:
            args.append(subcmd)  # $1=subcmd(首个额外参数是 $0)
        env = dict(os.environ, HOME=str(self.home), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        env.pop("PYTHONPATH", None)
        return subprocess.run(args, env=env, text=True, capture_output=True, timeout=30)

    # ---- 校验与清洗 ----

    def test_good_payload_is_cached_with_meta(self):
        payload = {"schema": 1, "updated_at": "2026-11-25T08:00:00Z",
                   "items": [GOOD_ITEM, CRITICAL_FUTURE]}
        run = self.run_harness(payload)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(self.cache.exists())
        mode = self.cache.stat().st_mode & 0o777
        self.assertEqual(mode, 0o600, "缓存必须 0600")
        doc = json.loads(self.cache.read_text(encoding="utf-8"))
        self.assertEqual(doc["schema"], 1)
        self.assertIn("fetched_at", doc)
        self.assertTrue(doc["fetched_at"].endswith("Z"))
        self.assertTrue(doc["source"].startswith("https://"), "source 字段记录命中源")
        self.assertEqual([i["id"] for i in doc["items"]],
                         [GOOD_ITEM["id"], CRITICAL_FUTURE["id"]])
        # stdout 与缓存内容一致
        self.assertEqual(json.loads(run.stdout), doc)

    def test_expired_items_are_dropped(self):
        payload = {"schema": 1, "items": [GOOD_ITEM, EXPIRED_ITEM]}
        run = self.run_harness(payload)
        self.assertEqual(run.returncode, 0, run.stderr)
        doc = json.loads(run.stdout)
        self.assertEqual([i["id"] for i in doc["items"]], [GOOD_ITEM["id"]],
                         "过期条目必须被剔除,不能进缓存")

    def test_duplicate_ids_dedup(self):
        payload = {"schema": 1, "items": [GOOD_ITEM, dict(GOOD_ITEM)]}
        run = self.run_harness(payload)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(json.loads(run.stdout)["items"]), 1)

    def test_bad_json_fails_without_caching(self):
        self.body.write_text("这不是 JSON{{{", encoding="utf-8")
        run = self.run_harness(None)
        self.assertNotEqual(run.returncode, 0, "坏数据必须报错,不能静默")
        self.assertFalse(self.cache.exists(), "坏数据不得写缓存")
        self.assertIn("校验未通过", run.stderr)

    def test_bad_schema_fails(self):
        run = self.run_harness({"schema": 99, "items": []})
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(self.cache.exists())
        self.assertIn("schema", run.stderr)

    def test_bad_severity_fails(self):
        item = dict(GOOD_ITEM, severity="urgent")
        run = self.run_harness({"schema": 1, "items": [item]})
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("severity", run.stderr)

    def test_missing_required_field_fails(self):
        item = {k: v for k, v in GOOD_ITEM.items() if k != "title"}
        run = self.run_harness({"schema": 1, "items": [item]})
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("title", run.stderr)

    def test_bad_data_keeps_old_cache_untouched(self):
        old = json.dumps({"schema": 1, "fetched_at": "2020-01-01T00:00:00Z",
                          "source": "old", "items": [GOOD_ITEM]}, ensure_ascii=False)
        item = {k: v for k, v in GOOD_ITEM.items() if k != "id"}
        run = self.run_harness({"schema": 1, "items": [item]},
                               seed_cache=old, seed_cache_mtime_old=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(json.loads(self.cache.read_text(encoding="utf-8"))["source"],
                         "old", "坏数据不得动旧缓存")

    # ---- 降级链与频控 ----

    def test_primary_fail_falls_back_to_jsdelivr(self):
        run = self.run_harness({"schema": 1, "items": [GOOD_ITEM]},
                               curl_env={"CURL_FAIL_PRIMARY": 1})
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("jsdelivr", json.loads(run.stdout)["source"])

    def test_primary_404_falls_back_to_jsdelivr(self):
        """未推送阶段(404)也走 jsDelivr 兜底,而不是直接失败。"""
        run = self.run_harness({"schema": 1, "items": [GOOD_ITEM]},
                               curl_env={"CURL_404_PRIMARY": 1})
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("jsdelivr", json.loads(run.stdout)["source"])

    def test_all_network_fail_uses_stale_cache(self):
        stale = json.dumps({"schema": 1, "fetched_at": "2020-01-01T00:00:00Z",
                            "source": "stale", "items": [GOOD_ITEM]}, ensure_ascii=False)
        run = self.run_harness({"schema": 1, "items": []},
                               curl_env={"CURL_FAIL_PRIMARY": 1, "CURL_FAIL_FALLBACK": 1},
                               seed_cache=stale, seed_cache_mtime_old=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["source"], "stale",
                         "网络全挂时降级用旧缓存(允许过期)")

    def test_all_network_fail_without_cache_errors(self):
        run = self.run_harness({"schema": 1, "items": []},
                               curl_env={"CURL_FAIL_PRIMARY": 1, "CURL_FAIL_FALLBACK": 1})
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("公告拉取失败", run.stderr)
        self.assertFalse(self.cache.exists())

    def test_fresh_cache_skips_network(self):
        cached = json.dumps({"schema": 1, "fetched_at": "2026-11-25T08:00:00Z",
                             "source": "fresh", "items": [GOOD_ITEM]}, ensure_ascii=False)
        run = self.run_harness({"schema": 1, "items": []},
                               curl_env={"CURL_FAIL_PRIMARY": 1, "CURL_FAIL_FALLBACK": 1},
                               seed_cache=cached)  # mtime=now,TTL 内
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["source"], "fresh")
        self.assertFalse((Path(self.tmp) / "curl-calls").exists(),
                         "TTL 内不得打网络(假 curl 计数文件不应存在)")

    def test_stale_cache_triggers_network(self):
        cached = json.dumps({"schema": 1, "fetched_at": "2020-01-01T00:00:00Z",
                             "source": "stale", "items": []}, ensure_ascii=False)
        run = self.run_harness({"schema": 1, "items": [GOOD_ITEM]},
                               seed_cache=cached, seed_cache_mtime_old=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotEqual(json.loads(run.stdout)["source"], "stale",
                            "TTL 过期必须重新拉取")

    # ---- read 子命令 ----

    def test_read_without_cache_returns_empty_skeleton(self):
        run = self.run_harness(None, subcmd="read")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["items"], [])
        self.assertFalse((Path(self.tmp) / "curl-calls").exists(),
                         "read 不得联网")

    def test_read_returns_cache_verbatim(self):
        cached = json.dumps({"schema": 1, "fetched_at": "t", "source": "s",
                             "items": [GOOD_ITEM]}, ensure_ascii=False)
        run = self.run_harness(None, subcmd="read", seed_cache=cached)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)["items"][0]["id"], GOOD_ITEM["id"])

    # ---- 接线 ----

    def test_dispatch_wires_announcements(self):
        sh = CORE.read_text(encoding="utf-8")
        self.assertIn("announcements) announcements_check", sh,
                      "命令分发必须挂 announcements 入口")
        self.assertIn('ANNOUNCEMENTS_CACHE="$BASE/announcements-cache.json"', sh)

    def test_cache_file_permissions_enforced(self):
        sh = CORE.read_text(encoding="utf-8")
        self.assertIn('chmod 600 "$ANNOUNCEMENTS_CACHE"', sh)


if __name__ == "__main__":
    unittest.main()
