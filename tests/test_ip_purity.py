"""IP 纯净度评级的口径回归。

口径是「类型基线 − 扣分」,不是「100 减若干项」。基线对齐 ip.net.coffee 的实测落点
(住宅 100 / 机房 51~58 / VPN 61~69 / Tor 43~50),这样两边的数字可以直接比;
判定阈值则比分数严 —— 分数是 IP 信誉的宽口径,判定回答的是「能不能拿它开 Claude」。

这一项的价值全在三件事上:
1. **结论能解释** —— 分数低必须能指出是哪一项扣的(机房/代理/Tor/滥用/地理),否则
   用户拿到一个 46 分不知道该改什么。
2. **取不到数据敢说不知道** —— 数据源挂了必须报「未评级」,不能借 ok 混过去。
   一个安全工具最大的风险不是报错,是让用户以为「没告警 = 没问题」。
3. **不重复计费** —— 同一事实罚两次会让分数量纲失准,用户没法拿它跟别处对比。

夹具只 stub 外部命令,不碰真实网络与真实配置。
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


def _risk(**flags):
    d = {"is_mobile": False, "is_vpn": False, "is_tor": False,
         "is_proxy": False, "is_datacenter": False}
    d.update(flags)
    return d


def _ipquery(org, isp, city="", timezone="America/Denver", risk_score=0, **flags):
    """ipquery 的响应形状(2026-11-03 实测字段名与嵌套结构照原样)。"""
    return json.dumps({
        "ip": "203.0.113.10",
        "isp": {"asn": "AS7922", "org": org, "isp": isp},
        "location": {"country": "United States", "country_code": "US",
                     "city": city, "timezone": timezone},
        "risk": _risk(risk_score=risk_score, **flags),
    })


def _ipapi(city="", status="success", **flags):
    d = {"status": status, "city": city,
         "proxy": False, "hosting": False, "mobile": False}
    d.update(flags)
    return json.dumps(d)


def _ipinfo(org, city=""):
    d = {"ip": "203.0.113.10", "org": org}
    if city:
        d["city"] = city
    return json.dumps(d)


def _sfs(frequency):
    return json.dumps({"success": 1, "ip": {"frequency": frequency}})


# ---- 四个典型出口 ----
RESIDENTIAL = _ipquery("Comcast", "Comcast Cable Communications, LLC", city="Denver")
HOSTING = _ipquery("RouterHosting LLC", "RouterHosting LLC", city="Ogden", risk_score=20,
                   is_datacenter=True)
HOSTING_DIRTY = _ipquery("RouterHosting LLC", "RouterHosting LLC", city="Ogden", risk_score=55,
                         is_datacenter=True)
PROXY = _ipquery("Cloudflare", "Cloudflare, Inc.", city="Denver", risk_score=20,
                 is_proxy=True, is_datacenter=True)
TOR = _ipquery("Tor", "Tor Exit", city="Denver", is_tor=True)
# 风险标志全干净、且没有可供归类的运营商名 —— 用来证明「PTR 才是判型的决定性证据」。
# org/isp 留空是刻意的:只要 ipquery 报了运营商名,ip_class 就会先把它归成机房,
# PTR 那三条断言就测不到自己了。
NEUTRAL = _ipquery("", "", timezone="America/Denver")

IPINFO_RESID = _ipinfo("AS7922 Comcast Cable Communications, LLC", "Denver")
IPINFO_HOSTING = _ipinfo("AS14956 RouterHosting LLC", "Ogden")
IPINFO_PROXY = _ipinfo("AS13335 Cloudflare, Inc.", "Denver")
SFS_CLEAN = _sfs(0)


class IpPurityTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="ip-purity-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # env.json 里把目标时区写成与样本 IP 一致,让默认断言只反映「类型/代理」这一维。
        # 地理那一维单独用 test_*geo*/test_*timezone* 改 env.json 来测。
        self.write_env("America/Denver")
        env = dict(os.environ, HOME=str(self.home),
                   PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1",
                   TZ_WATCHDOG_FILE=str(self.root / "none.sh"))
        # 会话里注入的 BASH_ENV 会给 bash 挂上命令代理,把 stub 的 curl 顶掉。
        env.pop("BASH_ENV", None)
        self.env = env
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("pgrep", "exit 0")
        # 一个 dig 要同时伺候两件事:PTR(-x)决定出口类型,正向解析决定 DNS 那一项。
        # 默认 PTR 为空,免得每个样本都莫名被判成住宅。
        self.ptr = ""
        self.stub("dig", '''case "$*" in
  *" -x "*) [[ -n "%s" ]] && echo "%s" ;;
  *) echo 198.18.0.2 ;;
esac''' % (self.ptr, self.ptr))
        self.stub("defaults", '''if [[ "$*" == *AppleLocale* ]]; then echo en_US; else printf '(\\n    en-US,\\n)'; fi''')
        self.stub("networksetup", '''case "$1" in
  -listallnetworkservices) printf 'header\\nWi-Fi\\n' ;;
  *) echo "IPv6: Off" ;;
esac''')
        self.stub("launchctl", "exit 1")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/Denver")

    def write_env(self, timezone):
        (self.home / ".claude-switcher" / "env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "节点选择",
            "country": "US", "timezone": timezone, "locale": "en_US",
        }), encoding="utf-8")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def set_ptr(self, rdns):
        """改反向解析结果。PTR 是出口自己写下的身份,也是这里最硬的一条证据。"""
        self.ptr = rdns
        self.stub("dig", '''case "$*" in
  *" -x "*) [[ -n "%s" ]] && echo "%s" ;;
  *) echo 198.18.0.2 ;;
esac''' % (rdns, rdns))

    def stub_net(self, ipquery="", ipapi="", ipinfo="", sfs=SFS_CLEAN, calls=None):
        """四个源各喂一份响应;calls 传文件名则记录每次调用。"""
        files = {}
        for key, body in (("q1", ipquery), ("q2", ipapi), ("q3", ipinfo), ("q4", sfs)):
            files[key] = self.root / (key + ".json")
            files[key].write_text(body, encoding="utf-8")
        log = ""
        if calls is not None:
            log = 'echo "$*" >> "%s"\n' % (self.root / calls)
        self.stub("curl", f'''{log}case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *api.ipquery.io*) cat "{files['q1']}" ;;
  *ip-api.com*) cat "{files['q2']}" ;;
  *ipinfo.io*) cat "{files['q3']}" ;;
  *stopforumspam*) cat "{files['q4']}" ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')

    def run_detail(self, cmd="checkdetail"):
        run = subprocess.run(["/bin/bash", str(SOURCE), cmd], text=True,
                             capture_output=True, env=self.env, timeout=180)
        value = None
        for line in run.stdout.splitlines():
            if line.startswith("IP纯净度="):
                value = line.split("=", 1)[1]
        self.assertIsNotNone(value, run.stdout + run.stderr)
        state, _, detail = value.partition(":")
        return state, detail, run

    def score(self, detail):
        m = re.search(r"评分 (\d+)/100", detail)
        self.assertIsNotNone(m, detail)
        return int(m.group(1))

    # ---- 基线:类型决定上限 ----

    def test_residential_scores_full_marks(self):
        """住宅宽带是这类账号最干净的出口,应当满分且明确报 ok。"""
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertEqual(self.score(detail), 100, detail)
        self.assertIn("Comcast", detail)

    def test_datacenter_is_warn_not_fail(self):
        """机房要提示但不拦启动:大量用户就用机房节点,一票否决等于把门焊死。

        分数落在 net.coffee 实测的机房带(51~58)里,两边数字可比。
        """
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("机房", detail)
        self.assertIn(self.score(detail), range(51, 59), detail)

    def test_proxy_feature_is_fail(self):
        """代理由 ipquery 单独识别时也要拦 —— 这正是 net.coffee 判高危的主因之一。"""
        self.stub_net(PROXY, _ipapi("Denver", hosting=True), IPINFO_PROXY)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("代理/VPN", detail)

    def test_second_source_catches_what_first_misses(self):
        """ipquery 说不是代理、ip-api 说是 —— 必须以「任一报出特征」为准。

        实测 Cloudflare WARP 就落在这个缝里:ipquery 只报 datacenter,
        ip-api 报 proxy:true。只看一个源会把它判成普通机房放过。
        """
        self.stub_net(HOSTING, _ipapi("Ogden", proxy=True, hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("代理/VPN", detail)

    def test_tor_is_always_fail_whatever_the_score(self):
        """Tor 出口没有讨论余地:分数落在 43~50(对齐 net.coffee),判定必须直接 fail。

        这里刻意不把分数压成个位数 —— 压到 0 会让「35 分的 Tor」和「35 分的转租机房」
        看起来同样糟糕,而前者是不可用、后者只是不推荐。
        """
        self.stub_net(TOR, _ipapi("Denver"), _ipinfo("AS0 Tor Exit"))
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("Tor", detail)
        self.assertIn(self.score(detail), range(43, 51), detail)

    def test_tor_is_not_noised_with_geo_ambiguity(self):
        """Tor 出口的「城市」是数据中心位置,三源必然不一致 —— 不许给它挂地理标记。

        实测两个随机 Tor 出口(204.8.96.141 / 178.218.144.18)都命中了「地理模糊」,
        但那个标记对用户毫无可操作性:Tor 出口本来就不在「他家附近」。给一个已经
        fail 的结论再叠一条无法处理的提示,只会让人以为要改的东西比实际更多。
        """
        self.stub_net(TOR, _ipapi("New York"), _ipinfo("AS0 Tor Exit", "Amsterdam"))
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertNotIn("地理模糊", detail)
        self.assertNotIn("时区不符", detail)

    # ---- 扣分项:每条都要能被单独指认 ----

    def test_risk_and_abuse_are_not_double_counted(self):
        """risk_score 与滥用记录高度相关,取较大者,不能相加。

        实测 Tor 出口这两项天然同时高;相加等于同一个事实罚两次,分数线会被拉低一档,
        于是「51 分的机房」和「49 分的机房」得到相反结论。
        """
        self.stub_net(HOSTING_DIRTY, _ipapi("Ogden", hosting=True), IPINFO_HOSTING,
                      _sfs(60))
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("滥用记录", detail)
        # 基线 60 − max(风险 12, 滥用 14) = 46;若相加会是 34。
        self.assertEqual(self.score(detail), 46, detail)

    def test_timezone_mismatch_is_penalised_when_sources_agree(self):
        """三源城市一致、只有时区对不上:这是真的画像矛盾,扣分但不 fail。"""
        self.write_env("Asia/Tokyo")
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertIn("时区不符", detail)
        # 基线 60 − 风险 7 − 时区 6 = 47
        self.assertEqual(self.score(detail), 47, detail)
        self.assertEqual(state, "warn", detail)

    def test_geo_ambiguity_is_not_blamed_on_the_user(self):
        """两个源报了不同城市时,不许拿其中一个的时区去要求用户对齐。

        实测 RouterHosting 144.172.103.106:ipquery/ipinfo 报犹他、ip-api 报内华达,
        跨了州。旧口径挑一个源算时区差,直接给用户扣了 8 分「时区不符」——
        用户什么都没做错,是数据源自己不一致。
        """
        self.write_env("Asia/Tokyo")
        self.stub_net(_ipquery("RouterHosting LLC", "RouterHosting LLC", city="Ogden"),
                      _ipapi("Reno", hosting=True),
                      _ipinfo("AS14956 RouterHosting LLC", "Ogden"))
        state, detail, _ = self.run_detail()
        self.assertIn("地理模糊", detail)
        self.assertNotIn("时区不符", detail)
        self.assertEqual(self.score(detail), 56, detail)  # 60 − 4

    def test_residential_is_never_geo_penalised(self):
        """家宽的注册地与接入地本来就会不同,那不是风险,也不该扣分。

        实测 net.coffee 对住宅一律 100;我们若在这条上扣分,数字就没法跟它比,
        而且会把「出差住酒店用家宽」这种正常状态报成问题。
        """
        self.write_env("Asia/Tokyo")
        self.stub_net(_ipquery("Comcast", "Comcast Cable Communications, LLC", city="Denver"),
                      _ipapi("Denver"), IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertEqual(self.score(detail), 100, detail)
        self.assertNotIn("时区不符", detail)

    # ---- PTR:出口自曝的身份,比任何第三方评分都硬 ----

    def test_rdns_tor_exit_overrides_clean_flags(self):
        """所有标志都干净、但 PTR 写着 tor-exit:以 PTR 为准。

        实测 DFRI 的出口就是这样 —— 第三方源把它标成住宅,反向解析却老实写着
        tor-exit-read-me。只看标志会把一个 Tor 出口洗成满分住宅。
        """
        self.set_ptr("tor-exit-read-me.dfri.se")
        self.stub_net(NEUTRAL, _ipapi(), _ipinfo("AS64500 Example Networks"))
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("Tor", detail)

    def test_rdns_hosting_hostname_reveals_hosting(self):
        """ASN 认不出来时,PTR 里的 static/cloud 仍能把它定成机房。"""
        self.set_ptr("vm-01.static.cloudzy.com")
        self.stub_net(NEUTRAL, _ipapi(), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("机房", detail)

    def test_rdns_residential_hint_rescues_unknown_asn(self):
        """反向解析里的 hsd/dsl/dynamic 是运营商家宽的典型命名,能补上被漏掉的类型。"""
        self.set_ptr("c-73-158-10-5.hsd1.ca.comcast.net")
        self.stub_net(NEUTRAL, _ipapi(), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertIn("住宅宽带", detail)
        self.assertEqual(self.score(detail), 100, detail)

    # ---- 「不知道」必须说不知道 ----

    def test_no_data_is_not_a_pass(self):
        """两个源都挂时必须说「未评级」并给 warn。

        这里是最容易退化成假绿的地方:取不到数据 -> 变量为空 -> 不扣分 -> 100 分 ok。
        那等于把「不知道」伪装成「很干净」。
        """
        self.stub_net("", "", "", "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("未评级", detail)

    def test_unrecognised_address_is_not_full_marks(self):
        """数据源不认识这个地址时回的是空壳,不是「很干净」。

        ipquery 对 192.0.2.55 返回结构完整、所有标志 false、risk_score 为 0 的响应,
        和「住宅且毫无风险」长得一模一样;ip-api 则老实回 status:fail「reserved range」。
        只看 risk_score 会给这种地址 100 分 —— 这是比「取不到数据」更隐蔽的假绿。
        """
        shell = json.dumps({
            "ip": "192.0.2.55",
            "isp": {"asn": "AS0", "org": "", "isp": ""},
            "location": {"country": "", "country_code": "", "city": "", "timezone": ""},
            "risk": _risk(risk_score=0),
        })
        self.stub_net(shell, _ipapi(status="fail"), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("未评级", detail)
        self.assertNotIn("100/100", detail)

    def test_unknown_result_is_not_cached(self):
        """查不到就不写缓存 —— 否则一次网络抖动会把「未知」钉住一整天。"""
        self.stub_net("", "", "", "")
        self.run_detail()
        cache = self.home / ".claude-switcher" / "purity-cache.v3"
        if cache.exists():
            self.assertNotIn("203.0.113.10", cache.read_text(encoding="utf-8"))

    def test_ipinfo_outage_falls_back_to_ipquery_org(self):
        """ipinfo 免费额度打满(429)时,不能把一个真实家宽报成「类型不明」。

        实测连续查询就会触发 429,共享出口更容易。那时 ipinfo 与 ip_org 同时为空,
        asn_org 只剩 ipquery 响应里那份运营商名可用。不接这层兜底,一个干净的
        Comcast 出口会拿到 70 分 warn 和「建议换住宅或原生 IP」—— 对用户是彻底的误导。
        """
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertIn("住宅宽带", detail)
        self.assertEqual(self.score(detail), 100, detail)

    # ---- 风险源全挂:降级判型,而不是一句「未评级」 ----

    def test_dig_timeout_banner_is_not_a_ptr_or_evidence(self):
        """dig 超时把「;; connection timed out;」写进 stdout,不能当 PTR 或存在证据。

        本机实测:出口刚切换时四源全部超时、dig 也超时,结果这一行诊断文本被
        head -1 取成 rdns,既让 known=1(零个有效数据源照样出分),又被当成运营商
        名拼进检查项 —— 用户界面上出现「评分 60/100 · 机房 · ;; connection timed
        out;」。诊断行必须以 ;; 开头丢掉:这时正确结论是「未评级」。
        """
        self.stub_net("", "", "", "")
        self.set_ptr(";; connection timed out; no servers could be reached")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("未评级", detail)
        self.assertNotIn("connection timed out", detail)
        self.assertNotIn(";;", detail)
        self.assertNotIn("评分", detail)

    def test_degraded_score_is_labelled_as_an_estimate(self):
        """降级判型给出的分数只是类型基线,不能让人读成实测信誉分。"""
        self.stub_net("", "", IPINFO_RESID)
        _, detail, _ = self.run_detail()
        self.assertIn("风险源不可达", detail)
        self.assertIn("类型预估", detail)
        self.assertIn("未实测信誉", detail)
        self.assertEqual(self.score(detail), 70, detail)

    def test_risk_sources_down_still_types_from_operator(self):
        """ipquery 与 ip-api 同时连不上时,靠 ipinfo 的运营商名照样把类型判出来。

        实测这两个源会同时回 000(ipinfo 却是通的)。这时直接报「未评级」等于把手里的
        信息扔掉 —— 我们明明知道出口属于 Comcast。但也不能报满分:代理与滥用两个维度
        一个都没验过,所以分数封顶 70、判定封顶 warn,并在同一行里说清原因。
        """
        self.stub_net("", "", IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("住宅宽带", detail)
        self.assertIn("风险源不可达", detail)
        self.assertIn("Comcast", detail)
        self.assertEqual(self.score(detail), 70, detail)
        self.assertNotIn("100/100", detail)
        self.assertNotIn("未评级", detail)

    def test_risk_sources_down_is_not_a_failure(self):
        """降级判型不能升级成 fail:那是拿我们自己的网络抖动去堵用户。

        IP 纯净度是可关闭的软信号,不是 Kill-Switch。数据源不可达属于「我们没查到」,
        不是「用户配置有问题」,把两者混成 fail 就是拿误报换安全感。

        这里只看 `check` 的输出里有没有纯净度的失败项 —— 退出码在这个夹具里被 WebRTC /
        保镖 / 规则置顶这些没 stub 的检查污染了,拿它做断言等于在测别的东西。
        「warn 不拦启动」由 test_risk_sources_down_still_types_from_operator 的 state 保证。
        """
        self.stub_net("", "", IPINFO_RESID)
        run = subprocess.run(["/bin/bash", str(SOURCE), "check"], text=True,
                             capture_output=True, env=self.env, timeout=180)
        self.assertNotIn("出口未过使用门槛", run.stdout, run.stdout + run.stderr)

    def test_risk_sources_down_falls_back_to_ptr(self):
        """连 ipinfo 也挂了时,PTR 是最后一根线索 —— 而且它常常直接写着出口类型。

        三家 HTTP 源全空、只剩 `c-...hsd1.ca.comcast.net` 这种反向解析:能解出来就证明
        地址存在,`hsd1` 又足以判成住宅宽带。这时仍然只给 warn,并把主机名当运营商名显示,
        让用户看得见我们到底依据了什么。
        """
        self.set_ptr("c-73-158-10-5.hsd1.ca.comcast.net")
        self.stub_net("", "", "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("住宅宽带", detail)
        self.assertIn("风险源不可达", detail)
        self.assertIn("hsd1", detail)
        self.assertEqual(self.score(detail), 70, detail)

    def test_single_risk_source_is_flagged(self):
        """只剩一家风险源时照常算分,但要标明证据不全。

        实测 WARP 只有 ip-api 报 proxy:true,ipquery 只报 datacenter —— 缺了任何一家,
        代理特征就可能漏判。这不是「有警报」,是「这次的结论只基于一半证据」,
        所以只加说明、不改判定。
        """
        self.stub_net(RESIDENTIAL, _ipapi(status="fail"), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertEqual(self.score(detail), 100, detail)
        self.assertIn("仅一家风险源可达", detail)

    # ---- 与门禁、缓存的一致性 ----

    def test_cache_avoids_second_lookup(self):
        """同一出口 24h 内只查一次 —— 这是单次检查能塞进 45 秒预算的前提。"""
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID, calls="calls.log")
        self.run_detail()
        first = (self.root / "calls.log").read_text(encoding="utf-8").count("api.ipquery.io")
        self.assertGreaterEqual(first, 1)
        self.run_detail()
        total = (self.root / "calls.log").read_text(encoding="utf-8").count("api.ipquery.io")
        self.assertEqual(total, first, "第二次检查又去打了一次网络")

    def test_cache_keeps_country_code_for_node_hard_gate(self):
        """国家代码要落进缓存,离线给候选节点排名时才有硬门槛可依。

        它不能靠额外一次网络请求换来 —— ip-api 本来就在查,只是多要一个字段。
        """
        self.stub_net(RESIDENTIAL, _ipapi("Denver", countryCode="US"), IPINFO_RESID)
        self.run_detail()
        cache = self.home / ".claude-switcher" / "purity-cache.v3"
        self.assertTrue(cache.exists(), "没写 v3 缓存")
        fields = cache.read_text(encoding="utf-8").strip().split("|")
        self.assertEqual(len(fields), 7, "v3 应是 7 列,实际 %d: %s" % (len(fields), fields))
        self.assertEqual(fields[6], "US")

    def test_degraded_result_expires_quickly_instead_of_a_full_day(self):
        """风险源全挂那次的 70 分不能被钉住 24 小时。

        实测过:两家源同时超时后,缓存里一直留着「风险源不可达」,
        之后整整一天每次检查都拿这个降级结论当真,哪怕源早就恢复了。
        现在给这类结果一个「五分钟后过期」的时间戳,读侧逻辑不用分叉。
        """
        self.stub_net("", "", IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("风险源不可达", detail)
        cache = self.home / ".claude-switcher" / "purity-cache.v3"
        line = cache.read_text(encoding="utf-8").strip()
        fields = line.split("|")
        self.assertEqual(len(fields), 7, fields)
        import time
        remaining = 86400 - (int(time.time()) - int(fields[1]))
        self.assertGreater(remaining, 0, "降级结果不该已经过期")
        self.assertLessEqual(remaining, 600, "降级结果最多只该留几分钟,实际还剩 %d 秒" % remaining)

        # 负例:证据齐全的结果仍按 24h 缓存,别为了修降级把正常缓存也打短。
        # 先清掉降级那条,否则它会命中缓存、根本走不到「重新打分」这一步。
        cache.unlink()
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        self.run_detail()
        fresh = (self.home / ".claude-switcher" / "purity-cache.v3").read_text(encoding="utf-8")
        rows = [r for r in fresh.strip().splitlines() if r.startswith("203.0.113.10|")]
        self.assertEqual(len(rows), 1, "同一个 IP 不该留下两条缓存")
        remaining = 86400 - (int(time.time()) - int(rows[0].split("|")[1]))
        self.assertGreater(remaining, 80000, "证据齐全时仍应缓存接近 24h,实际 %d" % remaining)

    def test_check_and_checkdetail_agree(self):
        """门禁与明细不能各说各话:代理出口在 check 里也必须判不通过。"""
        self.stub_net(PROXY, _ipapi("Denver", proxy=True, hosting=True), IPINFO_PROXY)
        run = subprocess.run(["/bin/bash", str(SOURCE), "check"], text=True,
                             capture_output=True, env=self.env, timeout=180)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("出口未过使用门槛", run.stdout)

    def test_high_score_fail_explains_the_hard_gate(self):
        """68 分却红叉不是算错:分数是信誉分,判定是能否开 Claude 的硬门槛。

        用户原话:「我们这个纯净度为什么我看你68分会提示风险过高」。
        代理/VPN 基线 75 分,扣完风险分仍有 60~70 分,但代理特征直接判 fail。
        以前一律写「风险过高(Tor/代理特征)」,分数与结论并排看着自相矛盾;
        现在必须写清命中的门槛,并说明分数与判定是两把尺子。
        """
        self.stub_net(PROXY, _ipapi("Denver", proxy=True, hosting=True), IPINFO_PROXY)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertGreaterEqual(self.score(detail), 50, detail)
        self.assertIn("硬门槛:代理/VPN 特征", detail)
        self.assertIn("分数与判定分开", detail)
        self.assertNotIn("风险过高", detail)
        self.assertNotIn("纯净度低", detail)

    def test_tor_and_low_score_fail_name_their_own_gate(self):
        """非代理的 fail 不能被错标成「Tor/代理特征」。"""
        self.stub_net(TOR, _ipapi("Denver"), _ipinfo("AS0 Tor Exit"))
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("硬门槛:Tor 出口", detail)
        self.assertNotIn("代理/VPN 特征(信誉", detail)

    def test_warn_and_ok_never_gain_a_hard_gate_note(self):
        """只给 fail 加解释;warn / ok 不能凭空多出「硬门槛」。"""
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "ok", detail)
        self.assertNotIn("硬门槛:", detail)
        # 两次跑的是同一个夹具 IP,不删缓存第二次会直接读到住宅那条结果。
        (self.home / ".claude-switcher/purity-cache.v3").unlink(missing_ok=True)
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertNotIn("硬门槛:", detail)


if __name__ == "__main__":
    unittest.main()
