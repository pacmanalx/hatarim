import Foundation

/// Protocolo MonitorIno v2 — linha-única + checksum XOR + ACK.
///
/// Formato wire: `TOKEN:VALOR;XX\n`
///   - `TOKEN`: 1-8 chars ASCII
///   - `VALOR`: até ~100 chars ASCII; arrays separados por `,`
///   - `XX`: XOR cumulativo de TUDO até e inclusive `;`, em hex 2 chars uppercase
///   - `\n`: terminador (LF)
///
/// ACK: receiver responde com a MESMA linha, mas com checksum XOR `0xFF`
/// (bits invertidos). Sender valida token+valor+checksum invertido exato.
enum SerialProtocol {

    /// XOR cumulativo de todos os bytes do payload (inclui o `;` final).
    static func xorChecksum(_ bytes: Data) -> UInt8 {
        var cs: UInt8 = 0
        for b in bytes { cs ^= b }
        return cs
    }

    /// Monta `TOKEN:VALOR;XX\n` em bytes ASCII.
    /// - parameter token: 1-8 chars ASCII (TEMP, CPU, FAN, ...)
    /// - parameter value: até ~100 chars ASCII; pode ser "" pra comandos sem payload
    static func encodeCommand(token: String, value: String = "") -> Data {
        let payloadStr = "\(token):\(value);"
        let payload = Data(payloadStr.utf8)
        let cs = xorChecksum(payload)
        let hex = String(format: "%02X", cs)
        var out = payload
        out.append(contentsOf: hex.utf8)
        out.append(0x0A) // \n
        return out
    }

    struct AckParseResult: Equatable {
        let token: String
        let value: String
        /// Checksum recebido (já decodificado de hex em UInt8).
        let receivedChecksum: UInt8
    }

    /// Faz parse de uma linha de ACK vinda do Arduino.
    /// Retorna nil se mal-formada (sem `:`, sem `;`, hex inválido, < 5 bytes).
    static func parseAck(_ line: Data) -> AckParseResult? {
        // Tira CR/LF do final
        var bytes = line
        while let last = bytes.last, last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }
        guard bytes.count >= 5 else { return nil }

        // Últimos 2 bytes: checksum em hex
        let csHexEnd = bytes.endIndex
        let csHexStart = bytes.index(csHexEnd, offsetBy: -2)
        let csHexData = bytes[csHexStart..<csHexEnd]
        guard let csHexStr = String(data: csHexData, encoding: .ascii),
              let cs = UInt8(csHexStr, radix: 16) else { return nil }

        // Antes do hex tem que vir `;`
        let semiIdx = bytes.index(csHexStart, offsetBy: -1)
        guard bytes[semiIdx] == 0x3B /* ';' */ else { return nil }

        // Token:Valor (sem o ';' nem o hex)
        let payloadEnd = semiIdx
        let payloadData = bytes[bytes.startIndex..<payloadEnd]

        // Acha primeiro ':'
        guard let colonIdx = payloadData.firstIndex(of: 0x3A /* ':' */) else { return nil }
        let tokenData = payloadData[payloadData.startIndex..<colonIdx]
        let valueStart = payloadData.index(after: colonIdx)
        let valueData = payloadData[valueStart..<payloadData.endIndex]

        guard let token = String(data: tokenData, encoding: .ascii),
              let value = String(data: valueData, encoding: .ascii) else { return nil }

        return AckParseResult(token: token, value: value, receivedChecksum: cs)
    }

    /// Dado o token+valor enviados, calcula qual checksum o ACK deve carregar
    /// (XOR cumulativo do payload TX, com bits invertidos).
    static func expectedAckChecksum(token: String, value: String) -> UInt8 {
        let payload = Data("\(token):\(value);".utf8)
        return xorChecksum(payload) ^ 0xFF
    }
}

/// Tokens definidos no protocolo. Mantido em paralelo ao firmware
/// (Arduino/src/main.cpp). Trocar aqui sem trocar lá quebra tudo.
enum SerialToken: String {
    case temp   = "TEMP"
    case cpu    = "CPU"
    case ecores = "ECORES"
    case gpu    = "GPU"
    case mem    = "MEM"
    case dsk    = "DSK"
    case netUp  = "NET_UP"
    case netDn  = "NET_DN"
    case fan    = "FAN"
    case host   = "HOST"
    case info   = "INFO"
    case clear  = "CLEAR"
    case clrvar = "CLRVAR"
    case reset  = "RESET"
}
