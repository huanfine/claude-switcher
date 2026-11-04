"""品牌标记的一致性：界面里的 Claude 星芒和 App 图标里那枚必须是同一枚。

几何是从 Claude.app 官方图标量出来的（12 根、角度不等分），存在两个地方：
  · app/main.swift             → 标题栏 20pt 的盾牌标记
  · assets/icon-gen.swift      → 2048 图标里挖空的那枚
两边各存一份射线表，靠注释里一句「改一处必须同步另一处」约束不住人。
这里把两张表抠出来逐项比，顺带钉住几条形状特征，免得以后被人「顺手改成
等分的 12 根」—— 等分看着是太阳/齿轮，不是 Claude 的标。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app/main.swift"
GEN = ROOT / "assets/icon-gen.swift"

# (deg: Double, len: Double, w: Double, slant: Double) / (角度, 长度, 宽度, 斜切)
ENTRY = re.compile(
    r"\(\s*(-?\d+(?:\.\d+)?)\s*,\s*"
    r"(-?\d+(?:\.\d+)?)\s*,\s*"
    r"(-?\d+(?:\.\d+)?)\s*,\s*"
    r"(-?\d+(?:\.\d+)?)\s*\)"
)


def ray_table(path):
    text = path.read_text(encoding="utf-8")
    start = text.index("let starRays:") if "let starRays:" in text else text.index("private static let rays:")
    end = text.index("\n    ]", start) if "private static let rays:" in text and start == text.index("private static let rays:") else text.index("\n]", start)
    block = text[start:end]
    return [tuple(float(x) for x in m.groups()) for m in ENTRY.finditer(block)]


class BrandMarkTests(unittest.TestCase):
    def setUp(self):
        self.app = ray_table(APP)
        self.gen = ray_table(GEN)

    def test_both_files_hold_twelve_rays(self):
        self.assertEqual(len(self.app), 12, f"界面标记应有 12 根射线，读到 {len(self.app)}")
        self.assertEqual(len(self.gen), 12, f"图标应有 12 根射线，读到 {len(self.gen)}")

    def test_tables_are_identical(self):
        self.assertEqual(self.app, self.gen,
                         "app/main.swift 与 assets/icon-gen.swift 的射线表不一致："
                         "品牌标记必须是同一枚，不是「差不多」")

    def test_angles_are_uneven(self):
        # 等分 12 根 = 每 30°，那读起来是太阳/齿轮，不是 Claude 的标。
        angles = sorted(a for a, _, _, _ in self.app)
        gaps = [angles[(i + 1) % 12] - angles[i] for i in range(11)]
        gaps.append(angles[0] + 360 - angles[11])
        self.assertGreater(max(gaps) - min(gaps), 10,
                           f"角度几乎等分（间隔 {gaps}），这枚标的辨识度就在不均匀上")

    def test_lengths_and_widths_are_measured_values(self):
        # 尖端半径几乎齐平（0.875~1.0），宽度却差一倍以上：
        # 官方那枚是「等长、粗细不均」，不是「长短不一的放射线」。
        lengths = [ln for _, ln, _, _ in self.app]
        widths = [w for _, _, w, _ in self.app]
        self.assertGreater(min(lengths), 0.85)
        self.assertLessEqual(max(lengths), 1.0)
        self.assertGreater(max(widths) / min(widths), 1.8)

    def test_hub_and_scale_match_in_both_files(self):
        # 宽度系数 / 毂半径 / 收口 / 平口宽，这四个数决定轮廓，两边也必须一样。
        keys = ("widthScale", "hub", "bevel", "capRatio")
        vals = {}
        for name, path in (("app", APP), ("gen", GEN)):
            text = path.read_text(encoding="utf-8")
            found = {}
            for key in keys:
                m = re.search(r"\b" + key + r"\s*(?::\s*CGFloat)?\s*=\s*([0-9.]+)", text)
                self.assertIsNotNone(m, f"{name} 里找不到 {key}")
                found[key] = float(m.group(1))
            vals[name] = found
        self.assertEqual(vals["app"], vals["gen"], "轮廓参数两处不一致")

    def test_menu_bar_icon_reuses_the_same_brand_geometry(self):
        """菜单栏状态图标不能退回系统符号，也不能另画一枚「差不多」的近似标。

        窗口标记与 App 图标换成 Claude 星芒之后，状态栏还挂着
        checkmark.shield.fill —— 那是三处品牌位里唯一不一致的一枚。
        """
        text = APP.read_text(encoding="utf-8")
        self.assertIn("enum MenuBarBrand", text, "菜单栏图标应走自绘品牌标")
        start = text.index("enum MenuBarBrand")
        end = text.index("// 生产应用与 UI 测试共用")
        block = text[start:end]
        for shape in ("GuardShield().path(in: shield).cgPath",
                      "ClaudeBurst().path(in: burst).cgPath"):
            self.assertIn(shape, block, f"菜单栏图标没复用 {shape}，会与窗口标漂移")
        self.assertIn("image.isTemplate = true", block,
                      "模板图才能自动适配浅色 / 深色菜单栏")
        # 负例对照：两枚系统盾牌符号都不该再出现在源码里（空状态插画用的
        # 非 fill 版 checkmark.shield 不在此列）。
        for symbol in ('"checkmark.shield.fill"', '"exclamationmark.shield.fill"'):
            self.assertNotIn(symbol, text, f"状态图标又退回系统符号 {symbol}")


if __name__ == "__main__":
    unittest.main()
