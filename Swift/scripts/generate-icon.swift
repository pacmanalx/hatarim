#!/usr/bin/env swift

// Gera AppIcon.icns para MonitorINO2.
//
// Conceito: "Chip + onda térmica" — chip QFP no centro de um squircle estilo
// macOS, com plumas térmicas (gradiente laranja→amarelo→ciano→azul) subindo
// de baixo, sugerindo monitoramento de temperatura.
//
// Uso:
//   swift scripts/generate-icon.swift [output-dir]
// (default output-dir = pasta acima do script)

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Cor

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(r)/255.0,
            green: CGFloat(g)/255.0,
            blue: CGFloat(b)/255.0,
            alpha: a)
}

// MARK: - Squircle (superelipse n=5, estilo macOS Big Sur+)

func squirclePath(rect: CGRect, n: Double = 5.0, steps: Int = 360) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let exp = 2.0 / n
        let x = CGFloat((cosT >= 0 ? 1.0 : -1.0) * pow(abs(cosT), exp)) * a
        let y = CGFloat((sinT >= 0 ? 1.0 : -1.0) * pow(abs(sinT), exp)) * b
        let p = CGPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Canvas

let canvas: CGFloat = 1024

// MARK: - Desenho principal

func drawIcon(_ ctx: CGContext) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    // Encolhe um tiquinho pra deixar respiro nas bordas (padrão macOS).
    let iconRect = full.insetBy(dx: canvas * 0.04, dy: canvas * 0.04)
    let bgPath = squirclePath(rect: iconRect)

    // -------- 1. Fundo: squircle com gradiente azul-marinho → teal escuro
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let bgGrad = CGGradient(colorsSpace: cs,
                            colors: [rgb(8, 18, 38), rgb(20, 56, 78)] as CFArray,
                            locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: 0, y: canvas),
                           end: CGPoint(x: canvas, y: 0),
                           options: [])

    // -------- 2. Vinheta radial — escurece bordas
    let vignette = CGGradient(colorsSpace: cs,
                              colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.55)] as CFArray,
                              locations: [0.55, 1.0])!
    ctx.drawRadialGradient(vignette,
                           startCenter: CGPoint(x: canvas/2, y: canvas/2),
                           startRadius: 0,
                           endCenter: CGPoint(x: canvas/2, y: canvas/2),
                           endRadius: canvas * 0.72,
                           options: [])

    // -------- 3. Plumas térmicas (atrás do chip)
    drawThermalPlumes(ctx, cs: cs)

    // -------- 4. Chip QFP no centro
    drawChip(ctx, cs: cs)

    // -------- 5. Vapor frio frontal (sutil, acima do chip)
    drawCoolSteam(ctx, cs: cs)

    // -------- 6. Highlight do topo (estilo Mac)
    let topShine = CGGradient(colorsSpace: cs,
                              colors: [rgb(255, 255, 255, 0.16),
                                       rgb(255, 255, 255, 0.0)] as CFArray,
                              locations: [0.0, 0.5])!
    ctx.drawLinearGradient(topShine,
                           start: CGPoint(x: 0, y: iconRect.maxY),
                           end: CGPoint(x: 0, y: iconRect.maxY - canvas * 0.30),
                           options: [])

    ctx.restoreGState()

    // -------- 7. Borda fina branca semi-transparente
    ctx.addPath(bgPath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.12))
    ctx.setLineWidth(2.0)
    ctx.strokePath()
}

// MARK: - Plumas térmicas

func drawThermalPlumes(_ ctx: CGContext, cs: CGColorSpace) {
    // 3 plumes curvas subindo
    struct Plume { let cx: CGFloat; let scale: CGFloat; let opacity: CGFloat }
    let plumes: [Plume] = [
        Plume(cx: canvas * 0.30, scale: 0.95, opacity: 0.55),
        Plume(cx: canvas * 0.50, scale: 1.20, opacity: 0.78),
        Plume(cx: canvas * 0.70, scale: 0.95, opacity: 0.55),
    ]

    for p in plumes {
        ctx.saveGState()
        let baseY: CGFloat = canvas * 0.10
        let topY: CGFloat = canvas * 0.92
        let halfW: CGFloat = 100 * p.scale

        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.cx - halfW, y: baseY))
        path.addCurve(to: CGPoint(x: p.cx, y: topY),
                      control1: CGPoint(x: p.cx - halfW * 1.3, y: canvas * 0.45),
                      control2: CGPoint(x: p.cx - 25, y: canvas * 0.85))
        path.addCurve(to: CGPoint(x: p.cx + halfW, y: baseY),
                      control1: CGPoint(x: p.cx + 25, y: canvas * 0.85),
                      control2: CGPoint(x: p.cx + halfW * 1.3, y: canvas * 0.45))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()

        let grad = CGGradient(colorsSpace: cs,
                              colors: [
                                rgb(255,  60,   0, p.opacity),
                                rgb(255, 150,  20, p.opacity * 0.90),
                                rgb(255, 220,  60, p.opacity * 0.55),
                                rgb( 80, 200, 255, p.opacity * 0.30),
                                rgb( 30,  90, 255, 0.0)
                              ] as CFArray,
                              locations: [0.0, 0.30, 0.55, 0.80, 1.0])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: baseY),
                               end: CGPoint(x: 0, y: topY),
                               options: [])
        ctx.restoreGState()
    }
}

// MARK: - Chip QFP

func drawChip(_ ctx: CGContext, cs: CGColorSpace) {
    let chipSide: CGFloat = 470
    let chipRect = CGRect(x: (canvas - chipSide) / 2,
                          y: (canvas - chipSide) / 2,
                          width: chipSide,
                          height: chipSide)
    let chipRadius: CGFloat = 38

    // Pinos: 7 por lado (28 total)
    let pinCount = 7
    let pinW: CGFloat = 16
    let pinL: CGFloat = 56
    let margin: CGFloat = 70
    let usable = chipSide - 2 * margin
    let pinSpacing = usable / CGFloat(pinCount - 1)

    for i in 0..<pinCount {
        let off = margin + CGFloat(i) * pinSpacing
        let topRect    = CGRect(x: chipRect.minX + off - pinW/2, y: chipRect.maxY,           width: pinW, height: pinL)
        let botRect    = CGRect(x: chipRect.minX + off - pinW/2, y: chipRect.minY - pinL,    width: pinW, height: pinL)
        let leftRect   = CGRect(x: chipRect.minX - pinL,         y: chipRect.minY + off - pinW/2, width: pinL, height: pinW)
        let rightRect  = CGRect(x: chipRect.maxX,                y: chipRect.minY + off - pinW/2, width: pinL, height: pinW)
        for r in [topRect, botRect, leftRect, rightRect] { drawPin(ctx, rect: r, cs: cs) }
    }

    // Sombra do chip
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10),
                  blur: 35,
                  color: rgb(0, 0, 0, 0.65))
    let chipPath = CGPath(roundedRect: chipRect,
                          cornerWidth: chipRadius,
                          cornerHeight: chipRadius,
                          transform: nil)
    ctx.addPath(chipPath)
    ctx.setFillColor(rgb(18, 18, 22))
    ctx.fillPath()
    ctx.restoreGState()

    // Body com gradient + highlight do topo + marker
    ctx.saveGState()
    ctx.addPath(chipPath)
    ctx.clip()

    let bodyGrad = CGGradient(colorsSpace: cs,
                              colors: [rgb(44, 44, 50), rgb(14, 14, 18)] as CFArray,
                              locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bodyGrad,
                           start: CGPoint(x: chipRect.minX, y: chipRect.maxY),
                           end:   CGPoint(x: chipRect.minX, y: chipRect.minY),
                           options: [])

    let chipShine = CGGradient(colorsSpace: cs,
                               colors: [rgb(255, 255, 255, 0.22),
                                        rgb(255, 255, 255, 0.0)] as CFArray,
                               locations: [0.0, 1.0])!
    ctx.drawLinearGradient(chipShine,
                           start: CGPoint(x: 0, y: chipRect.maxY),
                           end:   CGPoint(x: 0, y: chipRect.maxY - 90),
                           options: [])

    // Marker (pin 1) — circulinho concava no canto superior esquerdo
    let markerR: CGFloat = 16
    let markerC = CGPoint(x: chipRect.minX + 50, y: chipRect.maxY - 50)
    ctx.setFillColor(rgb(0, 0, 0, 0.75))
    ctx.fillEllipse(in: CGRect(x: markerC.x - markerR,
                               y: markerC.y - markerR,
                               width: markerR * 2,
                               height: markerR * 2))
    // pequeno realce no marker pra parecer côncavo
    ctx.setFillColor(rgb(255, 255, 255, 0.10))
    ctx.fillEllipse(in: CGRect(x: markerC.x - markerR + 2,
                               y: markerC.y - markerR + 8,
                               width: markerR * 2 - 4,
                               height: markerR - 4))
    ctx.restoreGState()

    // Texto "M2" centralizado
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 130, weight: .heavy),
        .foregroundColor: NSColor(white: 1.0, alpha: 0.88),
        .kern: -3.0,
    ]
    let str = NSAttributedString(string: "M2", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let tx = chipRect.midX - lineBounds.width / 2 - lineBounds.minX
    let ty = chipRect.midY - lineBounds.height / 2 - lineBounds.minY
    ctx.saveGState()
    // Sombra sutil pra dar profundidade tipo silkscreen
    ctx.setShadow(offset: CGSize(width: 0, height: -2),
                  blur: 4,
                  color: rgb(0, 0, 0, 0.6))
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func drawPin(_ ctx: CGContext, rect: CGRect, cs: CGColorSpace) {
    let path = CGPath(roundedRect: rect,
                      cornerWidth: 3, cornerHeight: 3,
                      transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let isHorizontal = rect.width > rect.height
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(140, 140, 148),
                                   rgb(225, 225, 232),
                                   rgb(110, 110, 118)] as CFArray,
                          locations: [0.0, 0.5, 1.0])!
    if isHorizontal {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: rect.minY),
                               end:   CGPoint(x: 0, y: rect.maxY),
                               options: [])
    } else {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.minX, y: 0),
                               end:   CGPoint(x: rect.maxX, y: 0),
                               options: [])
    }
    ctx.restoreGState()
}

// MARK: - Vapor frio frontal

func drawCoolSteam(_ ctx: CGContext, cs: CGColorSpace) {
    let chipTop: CGFloat = (canvas + 470) / 2
    ctx.saveGState()

    let path = CGMutablePath()
    let leftX  = canvas * 0.40
    let rightX = canvas * 0.60
    let topY   = chipTop + 180
    path.move(to: CGPoint(x: leftX, y: chipTop))
    path.addCurve(to: CGPoint(x: rightX, y: chipTop),
                  control1: CGPoint(x: leftX - 30, y: topY),
                  control2: CGPoint(x: rightX + 30, y: topY))
    path.closeSubpath()

    ctx.addPath(path)
    ctx.clip()

    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(140, 230, 255, 0.45),
                                   rgb(140, 230, 255, 0.0)] as CFArray,
                          locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: chipTop),
                           end:   CGPoint(x: 0, y: chipTop + 200),
                           options: [])
    ctx.restoreGState()
}

// MARK: - Render

func renderPNG(size: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil,
                        width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: bitmapInfo)!
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    drawIcon(ctx)

    let cgImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Main

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
let defaultOut = scriptPath.deletingLastPathComponent().deletingLastPathComponent()
let outDir: URL = CommandLine.arguments.count >= 2
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultOut

let fm = FileManager.default
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

print("==> Renderizando \(entries.count) PNGs em \(iconset.path)")
for (name, size) in entries {
    let data = renderPNG(size: size)
    let url = iconset.appendingPathComponent(name)
    try data.write(to: url)
    print("   ✓ \(name) (\(size)×\(size), \(data.count) bytes)")
}

let icns = outDir.appendingPathComponent("AppIcon.icns")
try? fm.removeItem(at: icns)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("ERRO: iconutil retornou \(task.terminationStatus)\n".utf8))
    exit(1)
}

print("==> AppIcon.icns gerado em \(icns.path)")
