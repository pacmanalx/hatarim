import Foundation
import Combine

/// Roda PID + TPO no Mac e decide se a FAN deve estar ON ou OFF agora.
/// O Arduino vira só atuador (recebe `F:0`/`F:1` no protocolo serial).
final class FanController: ObservableObject {
    let store: FanConfigStore

    @Published private(set) var currentTempC: Double = 0
    @Published private(set) var currentDutyPct: Double = 0
    @Published private(set) var fanShouldBeOn: Bool = false
    @Published private(set) var lastErrorC: Double = 0
    @Published private(set) var lastDecisionAt: Date = Date()
    @Published private(set) var hardCapTriggered: Bool = false

    /// Incrementa toda vez que `mode` muda. ArduinoSender observa e força reenvio
    /// de F:0/F:1 no próximo tick, mesmo que o bool resultante coincida com o
    /// `lastFanState` em cache (pode estar dessincronizado do firmware).
    @Published private(set) var modeChangeCounter: Int = 0

    private var previousFanState: Bool? = nil  // pra detectar transições e logar

    @Published private(set) var history: [FanHistoryPoint] = []
    private static let historyCapacity = 600  // ~10min em janela 1s

    // PID state
    private var pidIntegral: Double = 0
    private var pidLastError: Double = 0
    private var pidLastSampleAt: Date = Date()
    private var cycleStartedAt: Date = Date()
    /// Duty congelado no início do ciclo TPO atual. PID continua recalculando
    /// `currentDutyPct` (proposta) a cada tick, mas a decisão ON/OFF dentro
    /// do ciclo usa este valor — evita que oscilação do PID empurre o estado
    /// pra ON/OFF arbitrário no meio do ciclo (chattering brutal pro relé).
    private var lockedCycleDuty: Double = 0
    /// Marcado true quando entra em TPO ou config muda — força captura do duty
    /// no próximo tick (sem esperar fim do ciclo atual, que está num estado vazio).
    private var cycleNeedsInit: Bool = true

    // Histerese state (memória do último estado pra não chattering)
    private var hystLastOn: Bool = false

    private var cancellable: AnyCancellable?
    private var modeCancellable: AnyCancellable?

    init(store: FanConfigStore) {
        self.store = store
        // Reset PID quando muda config (evita ratoeira de integral acumulada com ganhos novos)
        cancellable = store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pidIntegral = 0
                self?.pidLastError = 0
                self?.cycleStartedAt = Date()
                self?.cycleNeedsInit = true
            }
        // Sinaliza mudança de modo pro ArduinoSender forçar reenvio de F:.
        // dropFirst() ignora o valor inicial emitido pelo @Published na subscrição.
        modeCancellable = store.$config
            .map(\.mode)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.modeChangeCounter &+= 1
            }
    }

    /// Chamado a cada tick do `SystemStats` com a temperatura corrente.
    /// Retorna se a FAN deve estar ON neste instante.
    @discardableResult
    func update(temperatureC: Double) -> Bool {
        let cfg = store.config
        currentTempC = temperatureC
        let now = Date()
        lastDecisionAt = now

        // Hard cap thermal (overrides tudo, anti-overheat)
        if temperatureC >= cfg.thermalHardCapC {
            hardCapTriggered = true
            fanShouldBeOn = true
            currentDutyPct = 100
            recordHistory(now: now)
            return true
        }
        hardCapTriggered = false

        switch cfg.mode {
        case .alwaysOff:
            fanShouldBeOn = false
            currentDutyPct = 0
        case .alwaysOn:
            fanShouldBeOn = true
            currentDutyPct = 100
        case .pidTPO:
            fanShouldBeOn = computePIDTPO(temperatureC: temperatureC, cfg: cfg, now: now)
        case .hysteresis:
            fanShouldBeOn = computeHysteresis(temperatureC: temperatureC, cfg: cfg)
            currentDutyPct = fanShouldBeOn ? 100 : 0
        }

        // Log SOMENTE em mudanças de estado pra não floodar o err log
        if previousFanState != fanShouldBeOn {
            let modeStr = cfg.mode.rawValue
            let reason = hardCapTriggered ? "HARDCAP" : modeStr
            FileHandle.standardError.write(Data(
                "FanController: \(previousFanState.map { $0 ? "ON" : "OFF" } ?? "—") → \(fanShouldBeOn ? "ON" : "OFF")  T=\(String(format:"%.1f", temperatureC))°C  setpoint=\(cfg.setpointC)°C  duty=\(String(format:"%.0f", currentDutyPct))%  reason=\(reason)\n".utf8
            ))
            previousFanState = fanShouldBeOn
        }

        recordHistory(now: now)
        return fanShouldBeOn
    }

    private func computePIDTPO(temperatureC t: Double, cfg: FanConfig, now: Date) -> Bool {
        let error = t - cfg.setpointC   // positivo = quente demais → fan precisa atuar
        lastErrorC = error

        let dt = max(0.001, now.timeIntervalSince(pidLastSampleAt))
        pidLastSampleAt = now

        // Integral com anti-windup simples (clamp)
        pidIntegral += error * dt
        pidIntegral = max(-100, min(100, pidIntegral))

        let derivative = (error - pidLastError) / dt
        pidLastError = error

        let raw = cfg.kp * error + cfg.ki * pidIntegral + cfg.kd * derivative
        let duty = max(0, min(100, raw))
        currentDutyPct = duty

        // TPO: duty congela no início do ciclo. PID recalcula `duty` a cada tick
        // mas a decisão ON/OFF deste ciclo usa `lockedCycleDuty`, definido na
        // borda do ciclo. No próximo ciclo, lockedCycleDuty pega o duty corrente.
        let elapsed = now.timeIntervalSince(cycleStartedAt) * 1000
        if cycleNeedsInit || elapsed >= Double(cfg.cycleTimeMs) {
            cycleStartedAt = now
            lockedCycleDuty = duty
            cycleNeedsInit = false
        }
        let onMs = (lockedCycleDuty / 100.0) * Double(cfg.cycleTimeMs)
        let elapsedInCycle = now.timeIntervalSince(cycleStartedAt) * 1000
        return elapsedInCycle < onMs
    }

    private func computeHysteresis(temperatureC t: Double, cfg: FanConfig) -> Bool {
        if hystLastOn {
            // Já ligada — desliga só quando temp cai abaixo de offC
            if t < cfg.hystTempOffC { hystLastOn = false }
        } else {
            // Já desligada — liga quando passa de onC
            if t >= cfg.hystTempOnC { hystLastOn = true }
        }
        return hystLastOn
    }

    private func recordHistory(now: Date) {
        let point = FanHistoryPoint(
            timestamp: now,
            temperatureC: currentTempC,
            setpointC: store.config.setpointC,
            dutyPct: currentDutyPct,
            fanOn: fanShouldBeOn
        )
        history.append(point)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }
}
