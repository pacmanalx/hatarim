import Foundation

struct SSHHealthCheck: HealthCheck {
    func perform(level: CheckLevel, service: ServiceDefinition) async -> HealthResult? {
        let cfg = service.config(for: level)
        guard cfg.enabled else { return nil }

        let host = service.endpoint.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "host vazio")
        }

        let userCommand = cfg.command.trimmingCharacters(in: .whitespaces)
        // L1: default = só "true" (testa SSH up). L2/L3: precisam de comando preenchido.
        var remoteCmd: String
        if userCommand.isEmpty {
            if level == .l1 {
                remoteCmd = "true"
            } else {
                return HealthResult(
                    status: .unknown,
                    latencyMs: nil,
                    detail: "\(level.shortLabel) sem comando configurado"
                )
            }
        } else {
            remoteCmd = userCommand
        }

        // Math challenge dinâmico pra L3
        var mathChallenge: MathChallenge? = nil
        var effectiveExpected = cfg.expectedSubstring.trimmingCharacters(in: .whitespaces)
        if level == .l3, cfg.useMathChallenge {
            let ch = MathChallenge.random()
            mathChallenge = ch
            remoteCmd = remoteCmd.replacingOccurrences(of: "{{problem}}", with: ch.problem)
            effectiveExpected = ch.answer
        }

        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(service.timeoutSec)",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        let extraArgs = service.sshExtraArgs.trimmingCharacters(in: .whitespaces)
        if !extraArgs.isEmpty {
            args.append(contentsOf: extraArgs.split(separator: " ").map(String.init))
        }
        args.append(host)
        args.append(remoteCmd)
        let commandPreview = "/usr/bin/ssh " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")

        let process = Process()
        process.launchPath = "/usr/bin/ssh"
        process.arguments = args

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
                        detail: "ssh não pôde rodar: \(error.localizedDescription)"
                    ))
                    return
                }

                process.waitUntilExit()
                let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let exitCode = Int(process.terminationStatus)
                if process.terminationStatus == 0 {
                    let expected = effectiveExpected
                    let challengeNote = mathChallenge.map { " [desafio: \($0.problem)=\($0.answer)]" } ?? ""
                    if !expected.isEmpty,
                       !outStr.localizedCaseInsensitiveContains(expected),
                       !errStr.localizedCaseInsensitiveContains(expected) {
                        let snippet = String(outStr.prefix(60))
                        continuation.resume(returning: HealthResult(
                            status: .degraded, latencyMs: latencyMs,
                            detail: "esperava '\(expected)'\(challengeNote): \(snippet)",
                            commandPreview: commandPreview,
                            rawOutput: outStr, rawError: errStr, exitCode: exitCode
                        ))
                    } else {
                        let baseDetail = outStr.isEmpty ? "exit 0" : String(outStr.prefix(60))
                        let detail = baseDetail + challengeNote
                        continuation.resume(returning: HealthResult(
                            status: .ok, latencyMs: latencyMs, detail: detail,
                            commandPreview: commandPreview,
                            rawOutput: outStr, rawError: errStr, exitCode: exitCode
                        ))
                    }
                } else {
                    let snippet = String(errStr.prefix(80))
                    let isTimeout = errStr.lowercased().contains("operation timed out") ||
                                    errStr.lowercased().contains("timed out")
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
