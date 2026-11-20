// 生成 ClickToKnow 应用图标 → .icns（无需设计稿，程序化绘制：渐变圆角方形 + 白色放大镜）
// 用法：swift Scripts/make_icon.swift <输出路径.icns>
// 依赖：AppKit（离屏渲染，无窗口）+ iconutil（Xcode / CLT 自带）
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Packaging/AppIcon.icns"

let canvas: CGFloat = 1024 // 设计坐标系，渲染时按目标尺寸等比缩放

/// 在当前图形上下文中绘制图标（pixelSize 为当前上下文的边长）
func drawIcon(pixelSize: CGFloat) {
    let s = pixelSize / canvas

    // 背景：圆角方形（保留 macOS 图标标准留白），蓝→紫渐变
    let margin: CGFloat = 102 * s
    let body = NSRect(x: margin, y: margin,
                      width: pixelSize - 2 * margin, height: pixelSize - 2 * margin)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    if let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.18, green: 0.45, blue: 0.96, alpha: 1),
        ending: NSColor(srgbRed: 0.56, green: 0.28, blue: 0.92, alpha: 1)
    ) {
        gradient.draw(in: body, angle: -70)
    }
    NSGraphicsContext.restoreGraphicsState()

    // 前景：白色放大镜（圆环 + 45° 手柄），呼应菜单栏 text.magnifyingglass 符号
    let white = NSColor.white.withAlphaComponent(0.96)
    let center = NSPoint(x: 452 * s, y: 588 * s)
    let radius: CGFloat = 168 * s
    let circle = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    ))
    circle.lineWidth = 62 * s
    white.setStroke()
    circle.stroke()

    let angle = -CGFloat.pi / 4 // 指向右下
    let handleStart = NSPoint(x: center.x + (radius + 18 * s) * cos(angle),
                              y: center.y + (radius + 18 * s) * sin(angle))
    let handleEnd = NSPoint(x: center.x + (radius + 172 * s) * cos(angle),
                            y: center.y + (radius + 172 * s) * sin(angle))
    let handle = NSBezierPath()
    handle.move(to: handleStart)
    handle.line(to: handleEnd)
    handle.lineWidth = 74 * s
    handle.lineCapStyle = .round
    handle.stroke()
}

/// 离屏渲染指定边长的 PNG
func renderPNG(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(pixelSize: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// 组装 .iconset（16/32/128/256/512 各含 @2x）
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ClickToKnow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for spec in specs {
    guard let data = renderPNG(size: spec.px) else {
        FileHandle.standardError.write("渲染 \(spec.px)px 失败\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(spec.name))
}

// iconutil 合成 .icns
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", output, iconset.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("图标已生成：\(output)")
