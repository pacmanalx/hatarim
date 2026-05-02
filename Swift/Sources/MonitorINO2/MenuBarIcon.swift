import SwiftUI
import AppKit

/// Ícone minimalista da barra de menu — chip DIP estilizado.
///
/// É um *template image* (NSImage.isTemplate = true): o macOS recoloca
/// automaticamente em preto/branco conforme o tema do sistema.
enum MenuBarChipIcon {
    static let nsImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Body do chip: retângulo arredondado centralizado
            let body = CGRect(x: 4.0, y: 5.5, width: 10.0, height: 7.0)
            let bodyPath = CGPath(roundedRect: body,
                                  cornerWidth: 1.2, cornerHeight: 1.2,
                                  transform: nil)
            ctx.addPath(bodyPath)
            ctx.setLineWidth(1.1)
            ctx.strokePath()

            // 4 pinos topo + 4 pinos baixo
            let pinW: CGFloat = 0.9
            let pinH: CGFloat = 1.6
            let pinXs: [CGFloat] = [5.4, 7.6, 10.4, 12.6]
            for x in pinXs {
                ctx.fill(CGRect(x: x - pinW/2, y: body.maxY,        width: pinW, height: pinH))
                ctx.fill(CGRect(x: x - pinW/2, y: body.minY - pinH, width: pinW, height: pinH))
            }

            // Marker do pin 1 (canto superior esquerdo do body)
            let markerR: CGFloat = 0.85
            let markerC = CGPoint(x: body.minX + 1.6, y: body.maxY - 1.6)
            ctx.fillEllipse(in: CGRect(x: markerC.x - markerR,
                                       y: markerC.y - markerR,
                                       width: markerR * 2,
                                       height: markerR * 2))

            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarChipIconView: View {
    var body: some View {
        Image(nsImage: MenuBarChipIcon.nsImage)
    }
}
