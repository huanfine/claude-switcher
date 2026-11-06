"""首页主视觉的语义：圆环只回答「过没过」，不回答「多少分」。

2026-11-06 用户原话：「不要用分数让别人误会，IP 非常不干净按道理还是能启动，
但是分数也不懂」。

背景：首页圆环曾经显示四维加权总分，并按分数染色（≥85 绿 / 60–84 琥珀 / <60 红）。
于是出现过一屏两句话互相打架 —— 徽章写「可以启动」，环套琥珀色、里面写「80 分」，
因为 IP 纯净度低把总分拖到了 84 以下。用户读到的只有颜色和数字。

现在圆环里是「通过项数 / 总项数」，而且是**一段一项**：16 段弧，每段的颜色
取那一项自己的状态（绿 / 琥珀 / 红 / 浅灰）。分数仍然在 `HealthSummary.score`
里算着（诊断与排序要用），但它不许回到主视觉。

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
                     "private static let ringGap")
        self.assertIn("passedCount", ring, "圆环要显示通过项数")
        self.assertIn('Text("/\\(vm.rows.count)")', ring,
                      "分母应是「/总项数」")
        self.assertIn('"项通过"', ring, "要有单位字「项通过」")
        self.assertNotIn('"分"', ring, "圆环里不许再出现「分」这个字")

    def test_ring_is_one_segment_per_check(self):
        """一段一项：分段数必须等于行数，不能写死成固定刻度。

        连续进度弧在 15/16 时只差 6%，看不出少了一项 —— 那正是这一版换掉它的原因。
        """
        ring = block(self.code, "private var healthRing: some View {",
                     "private static let ringGap")
        self.assertIn("vm.rows.indices", ring, "每一段要从 vm.rows 里来")
        self.assertIn("ringStateColor(vm.rows[i].state)", ring,
                      "每段的颜色要取那一项自己的状态")

    def test_segment_color_comes_from_item_state(self):
        """每段颜色只看该项状态，分数进不来。"""
        color = block(self.code, "private func ringStateColor(_ state: RowState) -> Color {",
                      "private var heroBadge: some View {")
        self.assertIn("switch state", color, "按行状态分派颜色")
        self.assertNotIn("score", color, "分段颜色不许看分数")
        for state in (".ok", ".warn", ".fail", ".skip"):
            self.assertIn(state, color, f"{state} 要有明确颜色")

    def test_purity_magnitude_is_labelled_as_percent(self):
        """结论里带纯净度量级时必须写成 0-100 的参照分，不能裸写「49 分」。"""
        self.assertIn('/100"', self.code,
                      "结论里的纯净度量级要写成「49/100」")
        self.assertNotIn('"\\(score) 分"', self.code,
                         "不许渲染成「49 分」——那会被读成整机得分")


if __name__ == "__main__":
    unittest.main()
