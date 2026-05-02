import Foundation
import CoreLocation
import os.log

/// Necessário pra `CWWiFiClient.interface().ssid()` retornar o SSID em macOS 14+.
/// Sem permissão Location, SSID vem como nil. Usado apenas pra ler nome da rede,
/// não envia coordenadas pra lugar nenhum.
final class LocationPermissionHelper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionHelper()
    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: "com.pacman.monitorino2", category: "Location")

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // pior precisão pra economizar bateria
    }

    func requestIfNeeded() {
        let status = manager.authorizationStatus
        logger.info("Location authorization status: \(String(describing: status), privacy: .public)")
        switch status {
        case .notDetermined:
            // requestWhenInUseAuthorization sozinho às vezes não dispara prompt em apps ad-hoc.
            // Iniciar update força o sistema a apresentar o diálogo.
            manager.requestWhenInUseAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.manager.startUpdatingLocation()
            }
        case .denied, .restricted:
            logger.warning("Location denied — SSID won't be available")
        case .authorizedAlways, .authorized:
            logger.info("Location authorized")
            // Não precisa manter updates rodando — só queríamos a permissão concedida
            manager.stopUpdatingLocation()
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        logger.info("Location authorization changed: \(String(describing: status), privacy: .public)")
        if status == .authorizedAlways || status == .authorized {
            // Liga e desliga rapidinho — só pra confirmar e não consumir bateria/recursos
            manager.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.manager.stopUpdatingLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location error: \(error.localizedDescription, privacy: .public)")
    }
}
