import Foundation

struct HTTPHealthCheck: HealthCheck {
    func perform(level: CheckLevel, service: ServiceDefinition) async -> HealthResult? {
        let cfg = service.config(for: level)
        guard cfg.enabled else { return nil }
        // L3 deep e2e não se aplica a HTTP genérico — pra isso use kind=ollama ou um endpoint custom.
        if level == .l3 {
            return HealthResult(status: .unknown, latencyMs: nil, detail: "L3 não disponível para HTTP")
        }

        guard let url = URL(string: service.endpoint) else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "URL inválida")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(service.timeoutSec)
        req.httpMethod = "GET"

        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            guard let http = resp as? HTTPURLResponse else {
                return HealthResult(status: .ok, latencyMs: latencyMs, detail: "respondeu (não-HTTP)")
            }
            if http.statusCode != service.expectedHTTPStatus {
                return HealthResult(status: .degraded, latencyMs: latencyMs,
                                    detail: "HTTP \(http.statusCode) (esperava \(service.expectedHTTPStatus))")
            }
            let expected = cfg.expectedSubstring.trimmingCharacters(in: .whitespaces)
            if !expected.isEmpty {
                let body = String(data: data, encoding: .utf8) ?? ""
                if !body.localizedCaseInsensitiveContains(expected) {
                    return HealthResult(status: .degraded, latencyMs: latencyMs,
                                        detail: "body sem '\(expected)'")
                }
            }
            return HealthResult(status: .ok, latencyMs: latencyMs, detail: "HTTP \(http.statusCode)")
        } catch let e as URLError where e.code == .timedOut {
            return HealthResult(status: .timeout, latencyMs: nil, detail: "timeout \(service.timeoutSec)s")
        } catch {
            return HealthResult(status: .fail, latencyMs: nil, detail: error.localizedDescription)
        }
    }
}
