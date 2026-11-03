// ChildProcesses.swift — laufende render-mcp-Prozesse für Abbruch und Signale.
//
// Der Signal-Handler des Backends darf weder Speicher anlegen noch Sperren
// nehmen. Deshalb liegen die PIDs in einem fest vorbelegten Puffer, den der
// Handler ohne Allokation durchsieht; die Plätze werden unter normaler
// Ausführung belegt und wieder freigegeben.

import Darwin
import Foundation

/// Höchstzahl gleichzeitig geführter Kindprozesse (zwei Läufe plus Reserve).
private let childProcessCapacity = 8

/// Feste Liste der laufenden Kindprozesse.
enum ChildProcesses {
    /// `nonisolated(unsafe)`: Die Plätze sind bewusst nur mit `pid_t`-Werten
    /// belegt; Schreiben und Lesen einzelner Wörter ist auf beiden
    /// unterstützten Architekturen unteilbar, und der Handler liest höchstens.
    nonisolated(unsafe) private static let slots: UnsafeMutablePointer<pid_t> = {
        let pointer = UnsafeMutablePointer<pid_t>.allocate(capacity: childProcessCapacity)
        pointer.initialize(repeating: 0, count: childProcessCapacity)
        return pointer
    }()

    /// Legt den PID-Puffer vorab an. Muss vor der Installation der
    /// Signal-Handler laufen, damit der Handler nichts mehr initialisieren muss.
    static func prepare() {
        _ = slots
    }

    /// Nimmt eine PID auf; ohne freien Platz bleibt der Prozess unregistriert.
    static func register(_ pid: pid_t) {
        guard pid > 0 else { return }
        for index in 0..<childProcessCapacity where slots[index] == 0 {
            slots[index] = pid
            return
        }
    }

    /// Gibt eine PID wieder frei.
    static func unregister(_ pid: pid_t) {
        for index in 0..<childProcessCapacity where slots[index] == pid {
            slots[index] = 0
        }
    }

    /// SIGTERM an alle laufenden Kinder. Mehr ist im Signal-Handler nicht sicher;
    /// die Kinder beenden sich daraufhin selbst.
    static func terminateAll() {
        for index in 0..<childProcessCapacity {
            let pid = slots[index]
            if pid > 0 {
                kill(pid, SIGTERM)
            }
        }
    }
}
