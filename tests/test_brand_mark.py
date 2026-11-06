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


def png_size(path):
    """读 PNG 的 IHDR 拿宽高，不依赖 Pillow。"""
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n" or raw[12:16] != b"IHDR":
        raise AssertionError(f"{path.name} 不是合法 PNG")
    return int.from_bytes(raw[16:20], "big"), int.from_bytes(raw[20:24], "big")


class ReadmeIconTests(unittest.TestCase):
    """README 首页那张图。

    原来两处 README 都直接引 assets/icon-2048.png，还写了 width="128" ——
    等于每打开一次仓库首页就拉 2 MB 换一个缩略图。缩略图另存一份之后，
    最怕的就是有人「顺手」把路径改回去，所以钉住。
    """

    def setUp(self):
        self.small = ROOT / "assets/icon-256.png"
        self.large = ROOT / "assets/icon-2048.png"

    def test_the_thumbnail_exists_and_is_256(self):
        self.assertTrue(self.small.exists(), "缺 assets/icon-256.png（README 用的缩略图）")
        self.assertEqual(png_size(self.small), (256, 256))

    def test_the_thumbnail_is_actually_small(self):
        # 2048 原图约 2 MB；缩略图只要几万字节。给一倍余量，正常不会逼近。
        self.assertLess(self.small.stat().st_size, 120_000,
                        f"缩略图 {self.small.stat().st_size} 字节，太大了")
        self.assertGreater(self.large.stat().st_size, self.small.stat().st_size * 10,
                           "原图反而没比缩略图大多少，缩略图可能不是从它缩出来的")

    def test_readmes_point_at_the_thumbnail(self):
        for name in ("README.md", "README.en.md"):
            text = (ROOT / name).read_text(encoding="utf-8")
            self.assertIn("assets/icon-256.png", text, f"{name} 没引用缩略图")
            self.assertNotIn('src="assets/icon-2048.png"', text,
                             f"{name} 又直接引了 2 MB 的原图")

    def test_packager_still_uses_the_full_size_original(self):
        # 打包要的是 1024+ 的源图来生成 .icns，别被缩略图替换掉。
        text = (ROOT / "scripts/package-macos.sh").read_text(encoding="utf-8")
        self.assertIn("assets/icon-2048.png", text, "打包脚本应继续用 2048 原图生成 icns")



class WebBrandMarkTests(unittest.TestCase):
    """官网那一对品牌位（标签页图标 / 页内标）也必须用同一枚星芒。

    App 图标、菜单栏、窗口标题三处 11-03 就换成了星芒，网页这边却一直停在
    「盾牌 + 对号」——用户打开官网看到对号、回到 App 看到星芒，同一家公司两枚标。
    现在两边用**逐字节相同的多边形坐标**（同一张射线表算出来的），这里把它们抠出来比。
    """

    FAVICON = ROOT / "docs/favicon.svg"
    PAGE = ROOT / "docs/index.html"
    POLY = re.compile(r'<polygon points="([^"]+)"')

    def points(self, path):
        return self.POLY.findall(path.read_text(encoding="utf-8"))

    def test_both_web_marks_draw_twelve_rays(self):
        for path in (self.FAVICON, self.PAGE):
            got = self.points(path)
            self.assertEqual(len(got), 12, f"{path.name} 里读到 {len(got)} 根射线")

    def test_web_rays_are_the_same_polygons(self):
        self.assertEqual(self.points(self.FAVICON), self.points(self.PAGE),
                         "favicon.svg 与 index.html 的星芒坐标不一致 —— "
                         "两处都是手写 SVG，漂移了没人看得出来")

    def test_checkmark_is_gone(self):
        # 旧的对号路径（页内标与 favicon 各一份），改成星芒后不该再回来。
        for path in (self.FAVICON, self.PAGE):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("m8.6 11.8", text, f"{path.name} 又画回对号了")
            self.assertNotIn("m24 32", text, f"{path.name} 又画回对号了")

    def test_page_still_links_the_favicon(self):
        text = self.PAGE.read_text(encoding="utf-8")
        self.assertIn('rel="icon"', text, "index.html 丢了 favicon 链接")
        self.assertIn("favicon.svg", text)

    def test_rays_carry_their_own_fill(self):
        """射线必须自己带填充色 —— 空手画完就上线踩过一次。

        `fill` 是可继承属性，而这枚标是「盾牌描边 + 星芒实心」的混合体：
        - favicon 的根 `<svg>` 没写 fill（默认黑），十二根射线于是全黑，
          压在紫色圆角块上，远看是一团脏点；
        - 页内标照抄旧代码把根写成 `fill="none"`，射线直接继承成透明 ——
          页面上只剩一个盾牌轮廓，看着就像「图标根本没换」。
        两处都得让射线拿到显式的填充色，不能再依赖根节点或 `style="color:…"`。
        """
        favicon = self.FAVICON.read_text(encoding="utf-8")
        self.assertRegex(favicon, r'<g fill="#[0-9A-Fa-f]{3,8}"',
                         "favicon.svg 的星芒没有显式 fill（写成 style=\"color:…\" 也不会生效）")

        page = self.PAGE.read_text(encoding="utf-8")
        brand_svg = page[page.index('class="brand-mark"'):]
        root = re.search(r"<svg[^>]*>", brand_svg)
        self.assertIsNotNone(root, "index.html 里找不到页内标的 <svg>")
        self.assertNotIn(
            'fill="none"', root.group(0),
            "页内标把根节点的 fill 写成 none，十二根射线会继承成透明",
        )
        self.assertIn("currentColor", root.group(0),
                      "页内标的射线需要 currentColor 才能跟着 .brand-mark 的文字色走")


if __name__ == "__main__":
    unittest.main()
