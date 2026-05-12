import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Move o cursor e clica. Precisa de permissão de Accessibility
/// (System Settings → Privacy & Security → Accessibility → HaTarim).
enum MouseAutomation {
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let opts = [key: kCFBooleanTrue!] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    static func currentMousePosition() -> CGPoint {
        // NSEvent.mouseLocation usa origem inferior-esquerda; CGEvent usa superior-esquerda.
        // Converto pra coordenadas CG (Y invertido em relação à main screen).
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return CGPoint(x: p.x, y: p.y) }
        return CGPoint(x: p.x, y: screen.frame.maxY - p.y)
    }

    static func click(x: Double, y: Double, button: TaskMouseButton, doubleClick: Bool) -> ScheduledTaskExecutor.Result {
        guard isAccessibilityTrusted(prompt: true) else {
            return ScheduledTaskExecutor.Result(ok: false, detail: "Accessibility não autorizado — System Settings → Privacy & Security → Accessibility")
        }
        let pt = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .hidSystemState)
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up:   CGEventType = button == .left ? .leftMouseUp   : .rightMouseUp
        let btn:  CGMouseButton = button == .left ? .left : .right

        CGWarpMouseCursorPosition(pt)
        Thread.sleep(forTimeInterval: 0.05)

        guard let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: pt, mouseButton: btn),
              let u = CGEvent(mouseEventSource: src, mouseType: up,   mouseCursorPosition: pt, mouseButton: btn) else {
            return ScheduledTaskExecutor.Result(ok: false, detail: "CGEvent falhou")
        }
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)

        if doubleClick {
            Thread.sleep(forTimeInterval: 0.05)
            d.setIntegerValueField(.mouseEventClickState, value: 2)
            u.setIntegerValueField(.mouseEventClickState, value: 2)
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
        return ScheduledTaskExecutor.Result(ok: true, detail: "click @ \(Int(x)),\(Int(y))\(doubleClick ? " (double)" : "")")
    }
}
