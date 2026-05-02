import Foundation
import Darwin

final class SerialPort {
    let path: String
    private var fd: Int32 = -1

    var isOpen: Bool { fd >= 0 }

    init?(path: String, baud: speed_t = 115200) {
        self.path = path
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return nil }

        // Lock exclusivo: evita conflito com outros consumidores (ex.: Arduino IDE Monitor)
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return nil
        }

        var tty = termios()
        if tcgetattr(f, &tty) != 0 {
            close(f)
            return nil
        }

        cfmakeraw(&tty)
        cfsetispeed(&tty, baud)
        cfsetospeed(&tty, baud)

        // 8N1, no flow control, ler sempre que houver
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        tty.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        tty.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)

        // VMIN=0, VTIME=1 (100ms timeout em reads)
        withUnsafeMutablePointer(to: &tty.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { arr in
                arr[Int(VMIN)] = 0
                arr[Int(VTIME)] = 1
            }
        }

        if tcsetattr(f, TCSANOW, &tty) != 0 {
            close(f)
            return nil
        }

        self.fd = f
        FileHandle.standardError.write(Data("SerialPort: OPEN \(path) fd=\(f)\n".utf8))
    }

    deinit { closePort() }

    func closePort() {
        if fd >= 0 {
            FileHandle.standardError.write(Data("SerialPort: CLOSE \(path) fd=\(fd)\n".utf8))
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Drena bytes pendentes no buffer de leitura. Equivalente a
    /// `serial.reset_input_buffer()` do pyserial. Usado antes de cada send
    /// pra evitar ack órfão de comando anterior contaminar a leitura do próximo.
    func drainInput() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIFLUSH)
    }

    /// Bloqueia até todos os bytes pendentes no buffer de TRANSMISSÃO terem
    /// saído de fato no fio (kernel + USB). Equivalente a `ser.flush()` do
    /// pyserial. Sem isso, `write()` pode retornar com bytes ainda no buffer
    /// USB, e o readLine subsequente espera ack antes do byte sair.
    func flush() {
        guard fd >= 0 else { return }
        _ = tcdrain(fd)
    }

    /// Escreve `data` na porta GARANTINDO que TODOS os bytes vão (ou nada vai).
    /// Em buffer cheio (EAGAIN), espera 2ms e tenta de novo, até 50 tentativas (~100ms).
    @discardableResult
    func write(_ data: Data) -> Int {
        guard fd >= 0 else { return -1 }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var totalWritten = 0
            let total = raw.count
            var emptyAttempts = 0
            while totalWritten < total {
                let remaining = total - totalWritten
                let cursor = base.advanced(by: totalWritten)
                let n = Darwin.write(fd, cursor, remaining)
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if emptyAttempts >= 50 {
                            FileHandle.standardError.write(Data(
                                "SerialPort.write: timeout EAGAIN após \(totalWritten)/\(total) bytes\n".utf8
                            ))
                            return totalWritten > 0 ? -1 : 0
                        }
                        emptyAttempts += 1
                        usleep(2000)
                        continue
                    }
                    return totalWritten > 0 ? -1 : -1
                }
                if n == 0 {
                    emptyAttempts += 1
                    if emptyAttempts >= 50 { return -1 }
                    usleep(2000)
                    continue
                }
                totalWritten += n
                emptyAttempts = 0
            }
            return totalWritten
        }
    }

    @discardableResult
    func writeString(_ s: String) -> Int {
        return write(Data(s.utf8))
    }

    /// Lê uma linha (terminada em `\n`) com timeout total em milissegundos.
    /// Retorna nil se não chega `\n` dentro do timeout, ou erro de I/O.
    /// Não inclui o `\n` na resposta. Faz polling com select() — fd é non-blocking.
    func readLine(timeoutMs: Int) -> Data? {
        guard fd >= 0 else { return nil }
        var buf = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var byte: UInt8 = 0

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }

            // select() com timeout pequeno — espera fd ficar legível
            var readSet = fd_set()
            withUnsafeMutablePointer(to: &readSet) { ptr in
                __darwin_fd_zero(ptr)
                __darwin_fd_set(fd, ptr)
            }
            let waitMs = min(50, Int(remaining * 1000))
            var tv = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(waitMs * 1000))
            let sel = select(fd + 1, &readSet, nil, nil, &tv)
            if sel < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if sel == 0 { continue } // timeout do select; loop checa deadline

            // Lê 1 byte por vez até achar \n ou esgotar disponível
            while true {
                let n = Darwin.read(fd, &byte, 1)
                if n == 1 {
                    if byte == 0x0A {
                        return buf
                    }
                    if byte != 0x0D {
                        buf.append(byte)
                    }
                    if buf.count > 256 {
                        // linha gigante = lixo; aborta
                        return nil
                    }
                    continue
                }
                if n == 0 { break }   // sem mais bytes agora
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return nil
                }
            }
        }
        return nil
    }
}

// MARK: - fd_set helpers (Darwin não exporta as macros C)

@inline(__always)
private func __darwin_fd_zero(_ set: UnsafeMutablePointer<fd_set>) {
    set.pointee = fd_set()
}

@inline(__always)
private func __darwin_fd_set(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask = Int32(1 << bitOffset)
    withUnsafeMutablePointer(to: &set.pointee.fds_bits) { bitsPtr in
        bitsPtr.withMemoryRebound(to: Int32.self, capacity: 32) { arr in
            arr[intOffset] |= mask
        }
    }
}
