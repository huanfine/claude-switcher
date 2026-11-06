"""首页主视觉的语义：圆环只回答「过没过」，不回答「多少分」。

2026-11-06 用户原话：「不要用分数让别人误会，IP 非常不干净按道理还是能启动，
但是分数也不懂」。

背景：首页圆环曾经显示四维加权总分，并按分数染色（≥85 绿 / 60–84 琥珀 / <60 红）。
于是出现过一屏两句话互相打架 —— 徽章写「可以启动」，环套琥珀色、里面写「80 分」，
因为 IP 纯净度低把总分拖到了 84 以下。用户读到的只有颜色和数字。

现在圆环里是「通过项数 / 总项数」，而且**分子分母排成一行**（「16/16」是一个整体）。
分数仍然在 `HealthSummary.score` 里算着（诊断与排序要用），但它不许回到主视觉。

这几条都是「有人顺手改回去就会立刻红」的静态断言，因为它们约束的是
**界面语义**，不是某个函数的返回值 —— 单测跑不出「颜色让人误会」。
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app/main.swift"


def block(text, start_marker, stop_marker):
    """从 start_marker 起取到下一个 stop_marker，用于只看某个属性的实现。"""
    start = text.index(start_marker)
    end = text.index(stop_marker, start + len(start_marker))
    return text[start:end]


def code_only(text):
    """去掉整行注释。

    注释里写「这里曾经有个 scoreColor」是**说明**，不是实现 ——
    断言得看代码。只剥整行注释（`//` 与 `///` 开头），不动行内 `//`，
    否则 URL 里的 `https://` 会被误伤。
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith("//")
    )


class HeroSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.text = APP.read_text(encoding="utf-8")
        self.code = code_only(self.text)

    def test_no_score_based_color_helper(self):
        """`scoreColor`（按分数分档配色）不许回来。"""
        self.assertNotIn(
            "scoreColor", self.code,
            "按分数分档的配色已经删掉：分数低不代表不能启动，"
            "颜色必须只跟 HealthSummary.Level 走。")

    def test_verdict_color_switches_on_level_only(self):
        """结论文案与圆环的颜色，唯一来源是 level。"""
        color = block(self.code, "var color: Color {", "enum Weight {")
        self.assertIn("switch level", color,
                      "HealthSummary.color 必须按 level 分档")
        for token in ("score >=", "score <", "score >"):
            self.assertNotIn(token, color,
                             f"结论色不许看分数（出现了 {token}）")

    def test_ring_shows_passed_count_not_score(self):
        """圆环里的文字是通过项数，且不带「分」字。"""
        ring = block(self.code, "private var healthRing: some View {",
                     "private var heroBadge: some View {")
        self.assertIn("passedCount", ring, "圆环要显示通过项数")
        self.assertIn('Text("/\\(vm.rows.count)")', ring,
                      "分母应是「/总项数」")
        self.assertIn('"项通过"', ring, "要有单位字「项通过」")
        self.assertNotIn('"分"', ring, "圆环里不许再出现「分」这个字")

    def test_ring_fraction_is_one_token(self):
        """「16/16」必须是一个整体：分子分母拼在同一个 Text 里，且不再拼成「/16 项」。

        旧排布是「16」+「/16 项」两行：两个 16 挨着、斜杠贴着分母往下沉，
        读的人得先解析一次才知道哪个是通过数（用户原话：「排布太丑」）。
        现在是 `Text(分子) + Text(分母)` —— 同一段文字流，基线与字距由排版引擎算。
        """
        ring = block(self.code, "private var healthRing: some View {",
                     "private var heroBadge: some View {")
        self.assertIn('+ Text("/\\(vm.rows.count)")', ring,
                      "分母要用 Text 拼接接在分子后面，不能另起一个视图")
        self.assertNotIn('项")', ring,
                         "分母后面不许再跟「项」字 —— 那会变回「/16 项」")

    def test_ring_is_continuous_not_segmented(self):
        """连续弧，不是 16 段。

        2026-11-06 试过「一段一项」的分段环：段长只比缝宽一点，整圈读起来是
        「加载中的虚线 spinner」，比原来更廉价，当场否决。这条防止有人再改回去。
        """
        ring = block(self.code, "private var healthRing: some View {",
                     "private var heroBadge: some View {")
        self.assertIn(".trim(from: 0, to: ringProgress)", ring,
                      "环应是一条连续弧")
        self.assertNotIn("ForEach", ring, "环里不许按行分段着色")
        self.assertNotIn("ringGap", self.code, "分段用的段缝常量应已删除")

    def test_ring_colour_comes_from_level(self):
        """环色只跟结论走，不按分数分档。"""
        ring = block(self.code, "private var healthRing: some View {",
                     "private var heroBadge: some View {")
        self.assertIn("healthSummary.color", ring,
                      "环色应直接取 healthSummary.color（Level 决定）")

    def test_purity_magnitude_is_labelled_as_percent(self):
        """结论里带纯净度量级时必须写成 0-100 的参照分，不能裸写「49 分」。"""
        self.assertIn('/100"', self.code,
                      "结论里的纯净度量级要写成「49/100」")
        self.assertNotIn('"\\(score) 分"', self.code,
                         "不许渲染成「49 分」——那会被读成整机得分")


if __name__ == "__main__":
    unittest.main()
