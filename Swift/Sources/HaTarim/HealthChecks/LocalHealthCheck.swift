import Foundation

/// Roda comandos LOCAIS via /bin/bash -lc (login shell carrega PATH/nvm/etc).
/// Útil pra monitorar processos rodando na mesma máquina sem overhead de SSH.
/// Suporta math challenge no L3 (substitui `{{problem}}` no command).
struct LocalHealthCheck: HealthCheck {
    func perform(level: CheckLevel, service: ServiceDefinition) async -> HealthResult? {
        let cfg = service.config(for: level)
        guard cfg.enabled else { return nil }

        let userCommand = cfg.command.trimmingCharacters(in: .whitespaces)
        var actualCmd: String
        if userCommand.isEmpty {
            if level == .l1 {
                actualCmd = "true"
            } else {
                return HealthResult(status: .unknown, latencyMs: nil,
                                    detail: "\(level.shortLabel) sem comando configurado")
            }
        } else {
            actualCmd = userCommand
        }

        // Math challenge dinâmico pra L3
        var mathChallenge: MathChallenge? = nil
        var effectiveExpected = cfg.expectedSubstring.trimmingCharacters(in: .whitespaces)
        if level == .l3, cfg.useMathChallenge {
            let ch = MathChallenge.random()
            mathChallenge = ch
            actualCmd = actualCmd.replacingOccurrences(of: "{{problem}}", with: ch.problem)
            effectiveExpected = ch.answer
        }

        let commandPreview = "/bin/bash -lc \"\(actualCmd)\""

        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-lc", actualCmd]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let start = DispatchTime.now()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: HealthResult(
                        status: .fail, latencyMs: nil,
                        detail: "bash não pôde rodar: \(error.localizedDescription)",
                        commandPreview: commandPreview
                    ))
                    return
                }

                // Timeout manual: kill após service.timeoutSec*N (mais generoso pra L3 que pode demorar)
                let timeoutSec = level == .l3 ? max(service.timeoutSec, 60) : service.timeoutSec
                let killAt = DispatchTime.now() + .seconds(timeoutSec)
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: killAt, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()
                let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let exitCode = Int(process.terminationStatus)
                if process.terminationStatus == 0 {
                    let challengeNote = mathChallenge.map { " [desafio: \($0.problem)=\($0.answer)]" } ?? ""
                    if !effectiveExpected.isEmpty,
                       !outStr.localizedCaseInsensitiveContains(effectiveExpected),
                       !errStr.localizedCaseInsensitiveContains(effectiveExpected) {
                        let snippet = String(outStr.prefix(60))
                        continuation.resume(returning: HealthResult(
                            status: .degraded, latencyMs: latencyMs,
                            detail: "esperava '\(effectiveExpected)'\(challengeNote): \(snippet)",
                            commandPreview: commandPreview,
                            rawOutput: outStr, rawError: errStr, exitCode: exitCode
                        ))
                    } else {
                        let baseDetail = outStr.isEmpty ? "exit 0" : String(outStr.prefix(60))
                        continuation.resume(returning: HealthResult(
                            status: .ok, latencyMs: latencyMs,
                            detail: baseDetail + challengeNote,
                            commandPreview: commandPreview,
                            rawOutput: outStr, rawError: errStr, exitCode: exitCode
                        ))
                    }
                } else {
                    // Pode ter sido kill pelo watchdog (timeout)
                    let isTimeout = latencyMs >= timeoutSec * 1000 - 100
                    let snippet = String((errStr.isEmpty ? outStr : errStr).prefix(80))
                    continuation.resume(returning: HealthResult(
                        status: isTimeout ? .timeout : .fail, latencyMs: latencyMs,
                        detail: snippet.isEmpty ? "exit \(process.terminationStatus)" : snippet,
                        commandPreview: commandPreview,
                        rawOutput: outStr, rawError: errStr, exitCode: exitCode
                    ))
                }
            }
        }
    }
}
