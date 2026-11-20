"""IP 纯净度评级的口径回归。

口径是「类型基线 − 扣分」,不是「100 减若干项」。基线取 ip.net.coffee 实测区间的
中位数(住宅 100 / 机房 55 / VPN 65 / Tor 46),这样两边的数字可以直接比;
判定阈值则比分数严 —— 分数是 IP 信誉的宽口径,判定回答的是「能不能拿它开 Claude」。

2026-11-06 修订两处口径(起因:用户拿同一个 IP 和 ip.net.coffee 对,数字与结论都对不上):
  1. **类型只能由正面证据决定。** 旧口径是「运营商名不在住宅白名单 = 机房」,
     白名单又只收了 11 个国家几十家运营商,于是 GTT(AS3257)这种三家源都说
     is_datacenter:false / hosting:false / risk_score:0 的干净出口,被我们报成
     「疑似机房 · 建议换住宅节点」,而网站判它住宅 98。现在:命中住宅名单 → 住宅;
     名字里有明确的机房/云/托管词 → 机房;两家源都否认证机房且低风险 → 住宅;
     其余 → 类型不明。**「没收录」不再等于「是机房」。**
  2. **地理维度只标记、不扣分。** 它和「时区」检查项说的是同一件事,扣分等于
     重复计费,而网站那边不含这一维,多扣的几分让两边永远对不上。

这一项的价值全在三件事上:
1. **结论能解释** —— 分数低必须能指出是哪一项扣的(机房/代理/Tor/滥用),否则
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
# 真实故障样本:66.17.65.38 / AS3257 GTT。三家源一致说不是机房、没有代理特征、
# risk_score=0,只因运营商名不在住宅白名单里就被 ip_class 默认判成机房。
CARRIER_CLEAN = _ipquery("GTT Communications Inc.", "GTT Communications Inc.",
                         city="Ashburn", timezone="America/New_York")
IPINFO_CARRIER = _ipinfo("AS3257 GTT Communications Inc.", "Ashburn")

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

    def drop_cache(self):
        """删掉纯度缓存。

        缓存按 IP 存 24 小时,而夹具每次都用同一个 IP —— 同一用例里换 risk_score 再跑,
        第二次会直接命中上一次的结果,断言就永远拿第一次的数。这一条踩过:
        「连续扣分」用例五个 risk 全报 70,看起来像扣分没生效,其实是缓存。
        """
        (self.home / ".claude-switcher" / "purity-cache.v8").unlink(missing_ok=True)

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

        基线 55 取自 net.coffee 实测的机房带(51~58)中位;这个样本 risk_score=20
        按连续口径扣 4 分((20×12+30)/60),所以落在 51 —— 分数低是风险分扣的,
        不是类型基线拍脑袋。
        """
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("机房", detail)
        self.assertEqual(self.score(detail), 51, detail)

    def test_clean_datacenter_lands_in_the_published_band(self):
        """没有任何风险记录的机房,分数要落回网站实测的 51~58 —— 两边才能对比。"""
        clean = _ipquery("RouterHosting LLC", "RouterHosting LLC", city="Ogden",
                         risk_score=0, is_datacenter=True)
        self.stub_net(clean, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn(self.score(detail), range(51, 59), detail)

    def test_proxy_feature_is_fail(self):
        """代理由 ipquery 单独识别时也要拦 —— 这正是 net.coffee 判高危的主因之一。"""
        self.stub_net(PROXY, _ipapi("Denver", hosting=True), IPINFO_PROXY)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("代理/VPN", detail)

    def test_single_source_proxy_against_multi_source_hosting_is_flagged(self):
        """单源代理特征 vs 多源机房证据 = 证据冲突,标出来但不拦启动。

        实测 AS14956 的三个出口,ipquery 三份响应的每个字段都一样
        (is_datacenter:true、risk_score:85、is_proxy:false、is_vpn:false),
        只有 144.172.65.26 被 ip-api 单独标了 proxy:true —— 于是同一台机器换个 IP
        就从「warn 可启动」变成「fail 拦启动」,分数还从 43 跳到 53。
        一个来源的一个布尔不该有这种决定权,但也不能当没看见。
        """
        self.stub_net(HOSTING, _ipapi("Ogden", proxy=True, hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("代理特征(单源)", detail)
        # 类型必须落在机房上,不能被单源代理特征洗成「代理/VPN」。
        self.assertIn("机房", detail)
        self.assertNotIn("代理/VPN", detail)

    def test_two_sources_reporting_proxy_still_blocks(self):
        """两家都说有代理特征时没有讨论余地 —— 尤其 WARP 那种:ipquery 只报
        datacenter、ip-api 报 proxy:true,一旦放过去就会被当成普通机房放行。
        相互印证过的证据仍然直接拦。
        """
        both = _ipquery("Cloudflare", "Cloudflare, Inc.", city="Denver", risk_score=20,
                        is_proxy=True, is_datacenter=True)
        self.stub_net(both, _ipapi("Denver", proxy=True, hosting=True), IPINFO_PROXY)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "fail", detail)
        self.assertIn("代理/VPN", detail)
        self.assertNotIn("代理特征(单源)", detail)

    def test_ipquery_proxy_alone_is_enough(self):
        """ipquery 自己报代理特征就算硬证据:它是我们对齐的那家源,
        同一份响应里的 is_proxy/is_vpn 不该被别家的沉默抵消。
        """
        flagged = _ipquery("Cloudflare", "Cloudflare, Inc.", city="Denver",
                           risk_score=20, is_vpn=True)
        self.stub_net(flagged, _ipapi("Denver", hosting=True), IPINFO_PROXY)
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
        # 基线 55 − max(风险 12, 滥用 14) = 41;若相加会是 29。
        self.assertEqual(self.score(detail), 41, detail)

    def test_timezone_mismatch_is_flagged_but_not_charged(self):
        """三源城市一致、只有时区对不上:标出来,但不再二次扣分。

        「系统时区与出口不一致」由「时区」那一项独立判定,这里再扣 6 分是重复计费;
        而且 ip.net.coffee 的 Trust Score 不含地理维度,我们多扣的分数会让两边对不上。
        """
        self.write_env("Asia/Tokyo")
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertIn("时区不符", detail)
        # 基线 55 − 风险扣分 4 = 51(地理维度只标记,不进分数)
        self.assertEqual(self.score(detail), 51, detail)
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
        self.assertEqual(self.score(detail), 55, detail)  # 基线 55,地理维度不扣分

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
        """反向解析里的 hsd/dsl/dynamic 是运营商家宽的典型命名,能补上被漏掉的类型。

        类型救回来了,但这一份样本的 ipquery 没报运营商名(等于少一家风险源),
        风险维度只验了一半 —— 所以分数封顶 85、判定只到 warn。类型对不等于验过了。
        """
        self.set_ptr("c-73-158-10-5.hsd1.ca.comcast.net")
        self.stub_net(NEUTRAL, _ipapi(), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("住宅宽带", detail)
        self.assertEqual(self.score(detail), 85, detail)

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
        cache = self.home / ".claude-switcher" / "purity-cache.v8"
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
        """只剩一家风险源时:类型照判,但分数封顶 85、判定最多 warn。

        实测 WARP 只有 ip-api 报 proxy:true,ipquery 只报 datacenter —— 缺了任何一家,
        代理特征就可能漏判。以前这里「只加说明、不改判定」,结果是 ipquery 一超时,
        一个没验过风险的出口照样报 100/ok —— 和两家源都验过的 100 长得一模一样。
        现在分数表达「现有证据支持到这里」:封顶 85,并且不给绿勾。
        """
        self.stub_net(RESIDENTIAL, _ipapi(status="fail"), "")
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertEqual(self.score(detail), 85, detail)
        self.assertIn("仅一家风险源可达", detail)

    # ---- 精确度:分数要能表达「证据到什么程度」,而不是「落在第几档」 ----

    def test_missing_risk_score_is_capped_not_skipped(self):
        """两源都在,但 ipquery 没给 risk_score:封顶 85,不能当「0 风险」白拿满分。

        缺数据的形态是最阴的一种:字段为空 → 罚分算 0 → 100 分 ok,
        和「验过且干净」的 100 完全一样。现在 85 + 「风险未验证」,封顶和文案都诚实,
        缓存时长则和完整结论一致(都是 24h,不单独开短过期)。
        """
        no_risk = ('{"ip":"203.0.113.10","isp":{"asn":"AS7922",'
                   '"org":"Comcast Cable Communications, LLC",'
                   '"isp":"Comcast Cable Communications, LLC"},'
                   '"location":{"country_code":"US","city":"Denver",'
                   '"timezone":"America/Denver"},"risk":{"is_vpn":false}}')
        self.stub_net(no_risk, _ipapi("Denver"), IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertEqual(self.score(detail), 85, detail)
        self.assertIn("风险未验证", detail)

    def test_risk_threshold_does_not_flip_the_type(self):
        """risk_score 从 10 变 11,不许把「住宅宽带」变成「类型不明」。

        信誉维度曾经写在类型判定的条件里(risk≤10 且无滥用),于是 1 分的抖动
        同时改了类型标签、分数(67→63)和动作建议(多一句「建议换住宅」)。
        类型回答「这是什么线路」,不该被「这条线脏不脏」改口。
        """
        for risk in (10, 11):
            with self.subTest(risk=risk):
                self.drop_cache()
                self.stub_net(_ipquery("Example ISP LLC", "Example ISP LLC",
                                       city="Ashburn", risk_score=risk),
                              _ipapi("Ashburn"), "")
                state, detail, _ = self.run_detail()
                self.assertEqual(state, "warn", detail)
                self.assertIn("住宅宽带", detail)
                self.assertNotIn("类型不明", detail)
                self.assertNotIn("建议换住宅", detail)
                self.assertEqual(self.score(detail), 68, detail)

    def test_risk_penalty_is_continuous(self):
        """风险扣分是连续函数:每 +5 分风险正好 -1 分信誉,没有档口跳变。"""
        scores = {}
        for risk in (0, 5, 10, 25, 50):
            self.drop_cache()
            self.stub_net(_ipquery("Example ISP LLC", "Example ISP LLC",
                                   city="Ashburn", risk_score=risk),
                          _ipapi("Ashburn"), "")
            _, detail, _ = self.run_detail()
            scores[risk] = self.score(detail)
        # 基线 70(只靠「没查到异常」判出的住宅),扣分 (risk*12+30)/60
        self.assertEqual(scores, {0: 70, 5: 69, 10: 68, 25: 65, 50: 60}, scores)

    # ---- 与门禁、缓存的一致性 ----

    def test_checkdetail_always_reasks_even_with_a_fresh_cache(self):
        """给人看的检查必须是新结论:缓存再新鲜也要重问。

        这条是「结果只讲现在对不对」的硬约束。反过来也成立 —— 一旦允许
        checkdetail 吃缓存,用户点「重新检查」拿到的就可能是几小时前的数字,
        而他没有任何办法知道。省下的那 4 个请求,不值得换这个不确定性。
        """
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID, calls="calls.log")
        self.run_detail()
        log = self.root / "calls.log"
        first = log.read_text(encoding="utf-8").count("api.ipquery.io")
        self.assertGreaterEqual(first, 1)
        # 缓存此刻是刚写好的、24h 有效 —— 但 checkdetail 仍然必须重问。
        self.run_detail()
        total = log.read_text(encoding="utf-8").count("api.ipquery.io")
        self.assertEqual(total, first * 2,
                         "checkdetail 命中了缓存,返回的是旧结论")

    def test_background_check_reads_cache_instead_of_reasking(self):
        """后台 check 读缓存 —— 它每 60 秒跑一次,重问源就是污染的唯一来源。

        巡检要回答的是「出口此刻还过不过门槛」,不是「这条出口的信誉有没有变」。
        同一 IP 的信誉一天内不会剧变,为它每分钟敲四家源,既是浪费,也是把
        我们自己的 IP 反复送给第三方。

        这个用例自带证伪:如果 check 根本没走到纯净度那一项,「0 次请求」只是
        假阴性 —— 所以清掉缓存再跑一次,必须真的发出请求,否则视为用例不成立。
        """
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID, calls="calls.log")
        log = self.root / "calls.log"
        self.run_detail()
        log.write_text("", encoding="utf-8")

        subprocess.run(["/bin/bash", str(SOURCE), "check"], text=True,
                       capture_output=True, env=self.env, timeout=180)
        self.assertEqual(log.read_text(encoding="utf-8").count("api.ipquery.io"), 0,
                         "后台 check 又去打了一次纯净度源")

        # 证伪对照:没有缓存时 check 必须问源,否则上一条的 0 是假阴性。
        self.drop_cache()
        log.write_text("", encoding="utf-8")
        subprocess.run(["/bin/bash", str(SOURCE), "check"], text=True,
                       capture_output=True, env=self.env, timeout=180)
        self.assertGreater(log.read_text(encoding="utf-8").count("api.ipquery.io"), 0,
                           "对照失败:check 没走到纯净度项,本用例不成立")

    def test_cache_keeps_country_code_for_node_hard_gate(self):
        """国家代码要落进缓存,离线给候选节点排名时才有硬门槛可依。

        它不能靠额外一次网络请求换来 —— ip-api 本来就在查,只是多要一个字段。
        """
        self.stub_net(RESIDENTIAL, _ipapi("Denver", countryCode="US"), IPINFO_RESID)
        self.run_detail()
        cache = self.home / ".claude-switcher" / "purity-cache.v8"
        self.assertTrue(cache.exists(), "没写 v4 缓存")
        fields = cache.read_text(encoding="utf-8").strip().split("|")
        self.assertEqual(len(fields), 7, "v4 应是 7 列,实际 %d: %s" % (len(fields), fields))
        self.assertEqual(fields[6], "US")

    def test_provisional_result_is_cached_like_any_other(self):
        """证据不全的结果也按 24h 缓存 —— 它不该有自己的过期时间。

        这里原来断言「只留几分钟」,理由是「一次网络抖动不能把不确定钉一整天」。
        那个担心本身没错,但解法错了:给这类结果单独设一个短过期,等于把
        「这次没查全」变成「每 N 分钟必须再问一次」的定时任务,而问的那一方
        是每分钟都在跑 check 的巡检 —— 实测那条路径一天能打出 1152 个请求。

        现在的分工是:证据不齐只影响**文案与封顶**,不影响缓存时长;要新结论,
        由 checkdetail 显式传 force 去要。所以这里断言的就是 24h。
        """
        self.stub_net("", "", IPINFO_RESID)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("风险源不可达", detail)
        cache = self.home / ".claude-switcher" / "purity-cache.v8"
        line = cache.read_text(encoding="utf-8").strip()
        fields = line.split("|")
        self.assertEqual(len(fields), 7, fields)
        import time
        remaining = 86400 - (int(time.time()) - int(fields[1]))
        self.assertGreater(remaining, 80000,
                           "降级结果被提前作废了,实际只剩 %d 秒" % remaining)

        # 负例:证据齐全的结果同样是 24h —— 两类结果在缓存时长上没有区别,
        # 区别只在文案与封顶。谁要是又给降级结果开了个短过期,上面那条会红。
        cache.unlink()
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        self.run_detail()
        fresh = (self.home / ".claude-switcher" / "purity-cache.v8").read_text(encoding="utf-8")
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
        (self.home / ".claude-switcher/purity-cache.v8").unlink(missing_ok=True)
        self.stub_net(HOSTING, _ipapi("Ogden", hosting=True), IPINFO_HOSTING)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertNotIn("硬门槛:", detail)


    def test_clean_carrier_is_residential_but_not_full_marks(self):
        """两家源都说没问题 → 类型按住宅判(与 ip.net.coffee 同口径),但分数封顶 70。

        用户先说「其他地方检查都是住宅 ip,我们却提示是机房 ip」(11-06),
        又说「骨干网地址拿 100 分不对」(11-19)。两句都对,分开处理:
        类型跟参考站一致,分数不跟着满分 —— 100 分是给有**正面住宅证据**的出口的
        (运营商名命中白名单,或 PTR 自曝 hsd/dynamic/dhcp 这类家宽特征)。
        实测 66.17.65.38 是 AS3257 GTT 的骨干网地址,靠「没查到异常」拿到 100/100。
        """
        self.write_env("America/New_York")
        self.stub_net(CARRIER_CLEAN, _ipapi("Ashburn", countryCode="US",
                                            timezone="America/New_York"),
                      IPINFO_CARRIER)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertEqual(self.score(detail), 70, detail)
        self.assertIn("住宅宽带", detail)
        self.assertIn("无正面住宅证据", detail)
        self.assertNotIn("机房", detail)
        # 判成住宅却劝人「换住宅」是自相矛盾的:这一档的 warn 只来自证据不全。
        self.assertNotIn("建议换住宅", detail)

    def test_single_risk_source_never_labels_hosting(self):
        """只剩一家风险源时,未收录的运营商名不能变成「机房」。

        ipquery 6 秒超时很常见(免费接口)。那时 src_n=1,旧逻辑会跳过「名字与
        证据相反」的豁免,把任何不在白名单里的运营商直接判成机房 —— 白名单只覆盖
        11 个国家的几十家运营商,等于让大部分地区的家宽用户都看到「疑似机房」。
        """
        self.write_env("America/New_York")
        self.stub_net("", _ipapi("Ashburn", countryCode="US",
                                 timezone="America/New_York"),
                      IPINFO_CARRIER)
        state, detail, _ = self.run_detail()
        self.assertNotIn("机房", detail)
        self.assertEqual(state, "warn", detail)

    def test_static_ptr_alone_is_not_hosting(self):
        """PTR 里只有 static 不算机房:家宽开静态 IP 的写法就是这样。

        真正的机房主机名几乎都同时带 cloud/vps/server/dedicated(见
        test_rdns_hosting_hostname_reveals_hosting 的 cloudzy 样本)。
        """
        self.set_ptr("static-1-2-3-4.example.net")
        self.stub_net(NEUTRAL, _ipapi(), "")
        _, detail, _ = self.run_detail()
        self.assertNotIn("机房", detail)

    def test_explicit_datacenter_flag_still_wins_over_clean_org(self):
        """有明确的 is_datacenter:true 时仍要判机房 —— 别把门禁一起放松。"""
        flagged = _ipquery("GTT Communications Inc.", "GTT Communications Inc.",
                           city="Ashburn", timezone="America/New_York",
                           is_datacenter=True)
        self.write_env("America/New_York")
        self.stub_net(flagged, _ipapi("Ashburn", countryCode="US",
                                     timezone="America/New_York"),
                      IPINFO_CARRIER)
        state, detail, _ = self.run_detail()
        self.assertEqual(state, "warn", detail)
        self.assertIn("机房", detail)

    def test_stale_cache_lock_is_reclaimed(self):
        """断电/被 kill 留下的空锁目录不能让此后所有评分都写不进缓存。

        本机 11-04 06:34 留下 .purity-cache.lock 后,连续 23 小时缓存零写入,
        每次检查都重新打四个网络请求,分数随网络抖动飘 —— 这是「评分不对」的
        第二个独立来源。
        """
        base = self.home / ".claude-switcher"
        lock = base / ".purity-cache.lock"
        lock.mkdir()
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        self.run_detail()
        cache = base / "purity-cache.v8"
        self.assertTrue(cache.exists(), "陈旧锁之后仍应写入缓存")
        self.assertIn("203.0.113.10|", cache.read_text(encoding="utf-8"))
        self.assertFalse(lock.exists(), "陈旧锁应被回收")

    def test_live_cache_lock_never_drops_the_result(self):
        """别人正持锁时也不能静默丢掉本次评分:缓存可以少一行,不能一行不写。"""
        import time
        base = self.home / ".claude-switcher"
        lock = base / ".purity-cache.lock"
        lock.mkdir()
        (lock / "owner").write_text(str(int(time.time())), encoding="utf-8")
        self.stub_net(RESIDENTIAL, _ipapi("Denver"), IPINFO_RESID)
        self.run_detail()
        cache = base / "purity-cache.v8"
        self.assertTrue(cache.exists(), "抢不到锁也要落盘,不能丢掉结果")
        self.assertIn("203.0.113.10|", cache.read_text(encoding="utf-8"))
        self.assertTrue(lock.exists(), "活锁不该被别人抢走")


if __name__ == "__main__":
    unittest.main()
