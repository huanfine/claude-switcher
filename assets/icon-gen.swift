import Cocoa

// 应用图标生成器。产物：assets/icon-2048.png（2048×2048）。
//
// 画什么：石墨灰圆角方块 + 一枚暖白盾牌，盾牌中间用**挖空**的 Claude 星标。
//
// 为什么不再是紫靛渐变：那套颜色在 Dock 里太跳，而且和界面本身完全脱节 ——
// 主界面是暖纸白（#F9F8F6）+ 石墨字（#1F1D1A）+ 陶土橙点缀，一个紫图标
// 摆在一排暖色图标里像别人家的。现在只用「深石墨底 + 暖白盾」两级明暗，
// 不靠色相取胜：缩到 16pt 靠轮廓就认得出来，放大也不吵。
//
// 为什么换掉旧图形：旧图形是「盾牌 + 双向箭头 ⇄」，读作「切换」。
// 应用名是「环境检查」，主诉是「环境干不干净、能不能放行」，
// 而这一版再换一次（对号 → 星标）：对号说明的是「检查过了」，换个工具也一样；
// 星标是 Claude 的标，Dock 里一眼能认出这是给谁用的。守护由盾牌承担。
//
// 为什么星标是挖空而不是单独上一个颜色：挖空露出来的是底下的石墨，
// 与背景天然同色，不需要维护第二个色值；将来换底色也不用改这里。
// 实现上是把星标「描边后的轮廓」当裁切区，在原坐标上重画一遍同一片底色。
//
// 一条通用规则（两次踩坑换来）：图标里**不要叠半透明层**。0.06 的白在渐变上
// 亮不起来，只会留下一条硬边，缩到 128 就是一块来路不明的浅色方块。
// 层次只靠「实心块 + 挖空块」两级，不要第三层。

let S: CGFloat = 2048
let k = S / 1024          // 下面所有坐标都按 1024 的设计稿写，乘 k 得到实际像素

// 用固定的位图上下文，而不是 NSImage.lockFocus()：后者在 Retina 上会按
// 屏幕缩放因子出图，实测拿到 4096×4096，再降采样回 2048 白掉一层细节。
let px = Int(S)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// ---- 背景：圆角方块 + 石墨渐变 ----
// 两端只差一档明度（#3A3631 → #232120），是「有一点体积」而不是「一条渐变」；
// 饱和度压到接近 0，色相留在暖侧，和界面里的石墨字同族。
let bgRect = NSRect(x: 92 * k, y: 92 * k, width: 840 * k, height: 840 * k)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 210 * k, yRadius: 210 * k)
let grad = NSGradient(colors: [
    NSColor(red: 0.227, green: 0.212, blue: 0.192, alpha: 1),   // #3A3631 石墨
    NSColor(red: 0.129, green: 0.122, blue: 0.110, alpha: 1),   // #211F1C 深石墨
])!
grad.draw(in: bgPath, angle: -45)

// 这里原来有一层「顶部极淡白椭圆」，想让上门沿不死板。
// 删了：0.06 的白在渐变上根本不发亮，只会露出一条**弧形硬边**，
// 缩到 128 就成了图标左上角莫名其妙的一个浅色方块 —— 读起来像没画完的线框。
// 图标的层次靠「盾牌是实的、星标是挖空的」两件事就已经够了，不需要再加一层。

// ---- 盾牌轮廓 ----
// 上沿中间留一个很浅的凹点，两侧肩部略高，下沿收成一个圆尖。
// 不是直线拼出来的多边形 —— 每一段都带控制点，缩到 16pt 才不会出现折角。
func shieldPath(scale: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
    p.move(to: pt(512, 792))
    p.curve(to: pt(724, 716), controlPoint1: pt(600, 782), controlPoint2: pt(700, 752))
    p.line(to: pt(724, 520))
    p.curve(to: pt(512, 262), controlPoint1: pt(724, 420), controlPoint2: pt(640, 322))
    p.curve(to: pt(300, 520), controlPoint1: pt(384, 322), controlPoint2: pt(300, 420))
    p.line(to: pt(300, 716))
    p.curve(to: pt(512, 792), controlPoint1: pt(324, 752), controlPoint2: pt(424, 782))
    p.close()
    return p
}

// ---- Claude 星标 ----
//
// 星标是 Claude 的标:Dock 里一眼能认出这是给谁用的;守护的意思由盾牌承担。
//
// **几何是从官方图标上量下来的,不是凭印象画的。**
// 取 /Applications/Claude.app/Contents/Resources/electron.icns 的 1024 稿,
// 做极坐标扫描:每 0.25° 找「白色最远到哪儿」得到半径剖面(峰=射线),
// 再在固定半径处横向扫过每根射线、把角宽换成线性宽度,得到锥度。
// 结论:12 根、角度不均匀(8.5°…333°)、每根**等宽**(不是花瓣形)、
// 端头是斜切的平口、中心一块实体毂。
// 12 根等分就变成太阳/齿轮 —— 不均匀才是这枚标的样子。
//
// 用像素重合度(IoU)把参数打到 0.86(对齐圆心后),再往上就是在拟合抗锯齿噪点了。
// 关键参数:宽度系数 1.03 / 毂半径 0.30R / 收口 0.015R / 平口宽 0.45×射線宽。
let starRays: [(deg: Double, len: Double, w: Double, slant: Double)] = [
    (8.50, 0.881, 0.141,  0.6), (40.25, 0.908, 0.205, -0.5),
    (79.75, 0.881, 0.131,  0.5), (103.00, 0.899, 0.131, -0.7),
    (133.25, 0.908, 0.099,  0.4), (149.25, 0.881, 0.146, -0.4),
    (184.75, 0.908, 0.115,  0.7), (214.00, 0.905, 0.115, -0.6),
    (237.25, 0.875, 0.131,  0.4), (271.75, 0.926, 0.099, -0.5),
    (303.25, 0.938, 0.162,  0.6), (333.00, 1.000, 0.183, -0.4),
]

func starPath(cx: CGFloat, cy: CGFloat, R: CGFloat) -> NSBezierPath {
    let widthScale: CGFloat = 1.03, hub: CGFloat = 0.30
    let bevel: CGFloat = 0.015, capRatio: CGFloat = 0.45
    let p = NSBezierPath()
    p.windingRule = .nonZero
    // 中心毂:12 根射线在中间本来就糊成一块,单独画个圆比让它们互相重叠更干净
    p.appendOval(in: NSRect(x: cx - hub * R, y: cy - hub * R,
                            width: hub * R * 2, height: hub * R * 2))
    for ray in starRays {
        let a = CGFloat.pi / 2 - CGFloat(ray.deg) * .pi / 180   // 0° = 正上,顺时针
        let tip = CGFloat(ray.len) * R
        let w = CGFloat(ray.w) * widthScale * R
        func q(_ r: CGFloat, _ off: CGFloat) -> NSPoint {
            NSPoint(x: cx + cos(a) * r + cos(a + .pi / 2) * off,
                    y: cy + sin(a) * r + sin(a + .pi / 2) * off)
        }
        let shoulder = tip - bevel * R
        let inner = hub * R * 0.6      // 起点埋进毂里,保证连成一体
        p.move(to: q(inner, -w / 2))
        p.line(to: q(shoulder, -w / 2))
        p.line(to: q(shoulder + CGFloat(ray.slant) * bevel * R * 0.5, -w / 2 * capRatio))
        p.line(to: q(shoulder - CGFloat(ray.slant) * bevel * R * 0.5,  w / 2 * capRatio))
        p.line(to: q(shoulder, w / 2))
        p.line(to: q(inner, w / 2))
        p.close()
    }
    return p
}

// 盾牌内腔:上宽下尖(300…724 横向、262…792 纵向),星标居中略偏下 ——
// 盾牌是梨形,几何中点在视觉上偏低。
let shieldCG = shieldPath(scale: k).cgPath
let starOutline = starPath(cx: 512 * k, cy: 532 * k, R: 192 * k).cgPath

// 先用盾牌填暖白（#F7F4EF，和界面里的纸白同一个色）。纯白在石墨底上会发灰、
// 显得脏，暖一档反而更像「纸」。
ctx.addPath(shieldCG)
ctx.setFillColor(NSColor(srgbRed: 0.969, green: 0.957, blue: 0.937, alpha: 1).cgColor)
ctx.fillPath()

// 再把星标挖掉。**不要**用 even-odd 把两条路径并起来填：描边轮廓在
// 交叉处会自交，even-odd 会把自交出来的那一小块当成「洞里面的实心」，
// 结果星标中心多长出一个白三角（第一版对号就是这样，放大一眼能看见）。
// 正确做法是把星标当裁切区，在原坐标上再画一遍同一片渐变 —— 露出来的
// 颜色和周围严丝合缝，因为画的就是同一个渐变。
ctx.saveGState()
ctx.addPath(starOutline)
ctx.clip()
grad.draw(in: bgPath, angle: -45)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// ---- 保存 ----
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/switcher-icon.png"
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("saved \(out) \(rep.pixelsWide)×\(rep.pixelsHigh)")
}
