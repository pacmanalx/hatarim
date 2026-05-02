import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct AboutWindow: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 18) {
                appHeader
                Divider().padding(.horizontal, 40)
                licenseBlock
                Divider().padding(.horizontal, 40)
                groupsBlock
                Divider().padding(.horizontal, 40)
                copyrightFooter
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 600, idealHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var appHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
            Text("HaTarim")
                .font(.system(size: 26, weight: .bold))
            Text(L.t("Version \(version)", "Versão \(version)"))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(L.t(
                "Real-time system monitor with Arduino TFT companion display",
                "Monitor de sistema em tempo real com display TFT Arduino acoplado"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var licenseBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(.green)
                Text(L.t("Free and Open Source Software",
                         "Software Livre e de Código Aberto"))
                    .font(.headline)
            }
            Text(L.t(
                "Distributed under the GNU General Public License v3.0 (GPLv3).\nAnyone is free to use, study, modify and redistribute, provided derivative works remain under the same license.",
                "Distribuído sob a Licença Pública Geral GNU v3.0 (GPLv3).\nQualquer pessoa pode usar, estudar, modificar e redistribuir, desde que trabalhos derivados permaneçam sob a mesma licença."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var groupsBlock: some View {
        VStack(spacing: 14) {
            Text(L.t("A production of", "Uma produção do"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(1.5)

            HStack(alignment: .top, spacing: 28) {
                groupCard(
                    imageName: "renegados",
                    title: "Renegados Hacker Clube",
                    subtitle: L.t("Retro hardware preservation collective",
                                  "Coletivo de preservação de hardware retrô")
                )
                groupCard(
                    imageName: "bytecrackers",
                    title: "Bytecrackers",
                    subtitle: L.t("Logo by Claudio H. Piccolo",
                                  "Logotipo por Claudio H. Piccolo")
                )
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func groupCard(imageName: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            if let img = NSImage(named: imageName) ?? bundleImage(named: imageName) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 130)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 180, height: 130)
                    .overlay(Text("?").font(.title))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
    }

    private func bundleImage(named name: String) -> NSImage? {
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            switch name {
            case "renegados":   return img   // já vem com fundo transparente (pré-processado)
            default:            return Self.removingBlackBackground(img)
            }
        }
        return nil
    }

    /// Inverso do filtro escuro: alpha = 4·(1 − luminance), clampado.
    /// Pixels brancos (luminance=1) → alpha 0 (transparente).
    /// Pixels pretos/coloridos médios → alpha 1 (opaco).
    private static func removingLightBackground(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return image }
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        // alpha = -4·luminance + 4 (com bias 4)
        filter.setValue(CIVector(x: -0.299 * 4, y: -0.587 * 4, z: -0.114 * 4, w: 0),
                        forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 4), forKey: "inputBiasVector")
        guard let output = filter.outputImage else { return image }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: NSSize(width: ci.extent.width, height: ci.extent.height))
        result.addRepresentation(rep)
        return result
    }

    /// Mapeia luminância → alpha multiplicada por 4 (clamp), tornando pixels pretos
    /// transparentes e mantendo cores claras opacas. Bom pra logos com fundo preto.
    private static func removingBlackBackground(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return image }
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        // alpha = clamp(luminance * 4) — pretos → 0, qualquer cor visível → 1
        filter.setValue(CIVector(x: 0.299 * 4, y: 0.587 * 4, z: 0.114 * 4, w: 0),
                        forKey: "inputAVector")
        guard let output = filter.outputImage else { return image }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: NSSize(width: ci.extent.width, height: ci.extent.height))
        result.addRepresentation(rep)
        return result
    }

    @ViewBuilder
    private var copyrightFooter: some View {
        VStack(spacing: 4) {
            Text("© 2026 Pacman · Renegados Hacker Clube")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L.t("Built with Swift, SwiftUI, AppKit and a lot of MSX nostalgia",
                     "Feito com Swift, SwiftUI, AppKit e muita nostalgia de MSX"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .italic()
        }
    }
}
