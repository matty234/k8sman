// Regenerates the DMG window background (640x400 pt, plus @2x) and the
// multi-resolution background.tiff that dmgbuild uses.
//   swift packaging/dmg/make-background.swift
// Needs only the Xcode command line tools (AppKit, tiffutil).
import AppKit

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let root = here.appendingPathComponent("../..").standardized
let iconURL = root.appendingPathComponent("frontend/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png")
let W = 640.0, H = 400.0

func render(scale: Double) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // Surface gradient (top lighter navy to near black).
    NSGradient(starting: NSColor(srgbRed: 0.105, green: 0.15, blue: 0.23, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.055, blue: 0.09, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    // Soft blue glow behind the middle.
    NSGradient(starting: NSColor(srgbRed: 0.1, green: 0.55, blue: 1, alpha: 0.10), ending: NSColor(srgbRed: 0.1, green: 0.55, blue: 1, alpha: 0))!
        .draw(fromCenter: NSPoint(x: W / 2, y: 190), radius: 0, toCenter: NSPoint(x: W / 2, y: 190), radius: 260, options: [])

    // Logo + wordmark, top centre (AppKit origin is bottom-left).
    let icon = NSImage(contentsOf: iconURL)!
    let word = NSAttributedString(string: "k8sman", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.92), .kern: 0.5])
    let ws = word.size(), iconS = 34.0, gap = 10.0
    let x0 = (W - (iconS + gap + ws.width)) / 2
    icon.draw(in: NSRect(x: x0, y: H - 30 - iconS, width: iconS, height: iconS))
    word.draw(at: NSPoint(x: x0 + iconS + gap, y: H - 30 - iconS / 2 - ws.height / 2))

    // Arrow between the icon slots (centres at x=170 and x=470, y=200 from top).
    let ay = H - 200 + 4
    ctx.setStrokeColor(NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: 0.75).cgColor)
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 9])
    ctx.move(to: CGPoint(x: 252, y: ay)); ctx.addLine(to: CGPoint(x: 376, y: ay)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: 364, y: ay + 11)); ctx.addLine(to: CGPoint(x: 388, y: ay))
    ctx.addLine(to: CGPoint(x: 364, y: ay - 11)); ctx.strokePath()

    // Light pills behind the icon labels: Finder always draws labels in dark
    // text over a custom background, which is unreadable on navy.
    for cx in [170.0, 470.0] {
        let pill = NSBezierPath(roundedRect: NSRect(x: cx - 62, y: H - 282 - 12, width: 124, height: 24), xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.86).setFill(); pill.fill()
    }

    // Caption.
    let cap = NSAttributedString(string: "Drag k8sman to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.5)])
    cap.draw(at: NSPoint(x: (W - cap.size().width) / 2, y: 58))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = here
try! render(scale: 1).write(to: dir.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", dir.appendingPathComponent("background.png").path,
               dir.appendingPathComponent("background@2x.png").path,
               "-out", dir.appendingPathComponent("background.tiff").path]
try! p.run(); p.waitUntilExit()
