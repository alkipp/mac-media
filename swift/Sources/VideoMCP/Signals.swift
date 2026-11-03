// Signals.swift — SIGTERM/SIGINT/SIGHUP räumen laufende Kindprozesse ab.
//
// Wird das Backend vom Gateway beendet, bekommen laufende render-mcp-Prozesse
// ein SIGTERM. Ohne diesen Handler blieben sie als Waisen zurück und würden
// weiter Frames schreiben.

import Darwin

/// Signal-Handler: Kinder beenden, dann sofort Schluss.
///
/// `_exit` statt `exit`, weil im Handler keine Aufräumroutinen laufen dürfen.
private func handleTermination(_ signalNumber: Int32) {
    ChildProcesses.terminateAll()
    _exit(1)
}

/// Installiert die Handler für TERM, INT und HUP sowie ein ignorierendes
/// SIGPIPE (ein geschlossener stdout-Pipe soll das Backend nicht beenden).
func installSignalHandlers() {
    // PID-Puffer vorab anlegen: der Handler selbst darf nichts initialisieren.
    ChildProcesses.prepare()
    for number in [SIGTERM, SIGINT, SIGHUP] {
        _ = signal(number, handleTermination)
    }
    _ = signal(SIGPIPE, SIG_IGN)
}
