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
// Cola de imagen local (ComfyUI: Krea2, FLUX.2…): /api/image/queue.
let imageURL = ProcessInfo.processInfo.environment["LLM_IMAGE_URL"]
    ?? "https://dgx.lan.e-dani.com/api/image/queue"
let pollSeconds = 10.0

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    var live: [String: Double]?
    var image: [String: Int]?
    var imageCurrent: String?
    var lastFetch: Date?
    var errorText: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
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
        fetch(endpoint) { [weak self] j in
            guard let self else { return }
            if j?["running"] is NSNumber {
                var m: [String: Double] = [:]
                for k in ["running", "waiting", "decode_tps", "decode_tps_now"] {
                    if let v = j?[k] as? NSNumber { m[k] = v.doubleValue }
                }
                self.live = m
                self.lastFetch = Date()
                self.errorText = nil
            } else {
                self.errorText = "sin lectura de /api/llm/live"
            }
            self.refreshTitle()
        }
        fetch(imageURL) { [weak self] j in
            guard let self else { return }
            if let j, j["running"] is NSNumber || j["queue_len"] is NSNumber {
                var m: [String: Int] = [:]
                for k in ["running", "queue_len", "pending"] {
                    if let v = j[k] as? NSNumber { m[k] = v.intValue }
                }
                self.image = m
                // `current` trae el job en marcha; nos quedamos con el preset o
                // el checkpoint para poder nombrarlo en el menú.
                if let cur = j["current"] as? [String: Any] {
                    self.imageCurrent = (cur["preset"] as? String)
                        ?? (cur["checkpoint"] as? String)
                        ?? ((cur["checkpoint"] as? [String: Any])?["filename"] as? String)
                } else {
                    self.imageCurrent = nil
                }
            } else {
                self.image = nil
            }
        }
    }

    private func fetch(_ urlStr: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: urlStr) else { return done(nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
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
        // Krea2 (cola de imagen local, ComfyUI): en progreso y cola.
        menu.addItem(.separator())
        if let img = image {
            let running = img["running"] ?? 0
            let cola = img["queue_len"] ?? 0
            if running > 0 {
                let que = imageCurrent.map { " — \($0)" } ?? ""
                info(menu, "Krea2: \(running) en progreso\(que)")
            } else {
                info(menu, "Krea2: ocioso")
            }
            info(menu, "Krea2 en cola: \(cola)")
        } else {
            info(menu, "Krea2: sin lectura de /api/image/queue")
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
        // Sin acción pero HABILITADAS: deshabilitadas macOS las pinta en gris
        // (queja de Dani 17-09). El clic no hace nada.
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = true
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
