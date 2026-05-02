import SwiftUI

struct SparkSeries: Identifiable {
    let id = UUID()
    let values: [Double]
    let color: Color
    let label: String?
    let filled: Bool

    init(values: [Double], color: Color, label: String? = nil, filled: Bool = true) {
        self.values = values
        self.color = color
        self.label = label
        self.filled = filled
    }
}

/// Sparkline genérico em estilo "stream chart": linha + área preenchida.
/// Aceita 1+ séries que compartilham a mesma escala vertical.
/// Sem deps externas — Path manual + GeometryReader (mesmo idioma do firmware Arduino).
struct Sparkline: View {
    let series: [SparkSeries]
    /// Escala máxima fixa (0-100 pra %); nil = auto pelo max das séries.
    var maxScale: Double? = nil
    /// Floor pra escala automática (evita amplificar ruído de baixo valor). Default 0.
    var minFloor: Double = 0
    /// Mostra grid horizontal em 25/50/75%.
    var showGrid: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showGrid {
                    ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                        Path { p in
                            let y = geo.size.height * (1 - f)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                    }
                }

                if series.allSatisfy({ $0.values.count < 2 }) {
                    Text(L.t("waiting for samples…", "aguardando amostras…"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let scale = effectiveScale
                    ForEach(series) { s in
                        spark(s: s, geo: geo, scale: scale)
                    }
                }
            }
        }
    }

    private var effectiveScale: Double {
        if let m = maxScale { return m }
        let m = series.flatMap(\.values).max() ?? 1
        return max(m, minFloor, 1)
    }

    @ViewBuilder
    private func spark(s: SparkSeries, geo: GeometryProxy, scale: Double) -> some View {
        let v = s.values
        if v.count >= 2 {
            let stepX = geo.size.width / CGFloat(max(v.count - 1, 1))
            let line = Path { p in
                for (i, val) in v.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(min(val / scale, 1)))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            if s.filled {
                let fill = Path { p in
                    for (i, val) in v.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat(min(val / scale, 1)))
                        if i == 0 {
                            p.move(to: CGPoint(x: x, y: geo.size.height))
                            p.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            p.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                fill.fill(s.color.opacity(0.15))
            }
            line.stroke(s.color, lineWidth: 1.5)
        }
    }
}
