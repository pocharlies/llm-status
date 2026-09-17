// LLM Status — chip de la barra de menús del Mac con las mismas dos lecturas
// que la navbar del dashboard (DGX-96): «N req» y «X tok/s global», ambas de
// UNA sola lectura de /api/llm/live (dgx.llm.live.v1), cada 30 s.
// Tono igual que chipTone(): cola abierta = naranja, sirviendo = normal,
// sin lectura = guion. Nunca rojo.
import AppKit

let endpoint = ProcessInfo.processInfo.environment["LLM_LIVE_URL"]
    ?? "https://dgx.lan.e-dani.com/api/llm/live"
let dashboardURL = ProcessInfo.processInfo.environment["LLM_DASHBOARD_URL"]
    ?? "https://dgx.lan.e-dani.com/inferencia"
let pollSeconds = 30.0

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    var live: [String: Double]?
    var lastFetch: Date?
    var errorText: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func refreshTitle() {
        guard let b = item.button else { return }
        let running = live?["running"]
        let text: String
        if let running {
            var parts = ["\(Int(running)) req"]
            if let w = live?["waiting"], w > 0 { parts.append("\(Int(w)) en cola") }
            if let tps = live?["decode_tps_now"] ?? live?["decode_tps"] {
                parts.append("\(Int(tps.rounded())) tok/s")
            }
            text = parts.joined(separator: " · ")
        } else {
            text = "LLM —"
        }
        // Mismo criterio que chipTone() de la navbar: cola = warn, sirviendo = ok
        // (verde), todo cero o sin lectura = muted (gris). Nunca rojo.
        let color: NSColor
        if running == nil {
            color = .secondaryLabelColor
        } else if (live?["waiting"] ?? 0) > 0 {
            color = .systemOrange
        } else if running! > 0 {
            color = .systemGreen
        } else {
            color = .secondaryLabelColor
        }
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular),
        ])
    }

    func poll() {
        guard let url = URL(string: endpoint) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data,
                   let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   j["running"] is NSNumber {
                    var m: [String: Double] = [:]
                    for k in ["running", "waiting", "decode_tps", "decode_tps_now"] {
                        if let v = j[k] as? NSNumber { m[k] = v.doubleValue }
                    }
                    self.live = m
                    self.lastFetch = Date()
                    self.errorText = nil
                } else {
                    self.errorText = err?.localizedDescription ?? "respuesta inválida"
                }
                self.refreshTitle()
            }
        }.resume()
    }

    // MARK: - menú

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Abrir /inferencia", #selector(openDashboard), key: "o")
        menu.addItem(.separator())
        if let l = live {
            info(menu, "En curso: \(Int(l["running"] ?? 0))")
            info(menu, "En cola: \(Int(l["waiting"] ?? 0))")
            if let now = l["decode_tps_now"] {
                info(menu, "Decode ahora: \(Int(now.rounded())) tok/s global")
            }
            if let avg = l["decode_tps"] {
                info(menu, "Media 2 min: \(Int(avg.rounded())) tok/s")
            }
            if let f = lastFetch {
                let df = DateFormatter()
                df.dateFormat = "HH:mm:ss"
                info(menu, "Actualizado: \(df.string(from: f))")
            }
        } else {
            info(menu, "Sin lectura de /api/llm/live")
            if let e = errorText { info(menu, "Error: \(e)") }
        }
        menu.addItem(.separator())
        add(menu, "Actualizar ahora", #selector(refreshNow), key: "r")
        add(menu, "Salir", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    private func info(_ menu: NSMenu, _ text: String) {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
    }

    @objc func openDashboard() {
        if let url = URL(string: dashboardURL) { NSWorkspace.shared.open(url) }
    }
    @objc func refreshNow() { poll() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
