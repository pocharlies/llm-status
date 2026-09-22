// LLM Status — chip de la barra de menús del Mac.
//
// 22-09 (rediseño, Dani: «monta el diseño de la home del dashboard con UIKit
// Apple por defecto»): el desplegable NO es una lista de textos. Es un panel
// SwiftUI con las tarjetas de la home del panel — Inferencia, Generación y
// Compañía — con el sistema del DESIGN.md de la épica DGX-338: retícula de
// 8 pt, dígitos monoespaciados (`.monospacedDigit`), verde=trabajo,
// naranja=cola, gris=reposo/sin lectura, NUNCA rojo, y píldora de estado en
// cada tarjeta. Los acciones (abrir panel, actualizar, salir) siguen siendo
// ítems NATIVOS de NSMenu: atajos de teclado y comportamiento de menú intactos.
//
// Datos: UNA tanda cada 10 s contra /api/llm/live (dgx.llm.live.v1),
// /api/image/queue y /api/llm/company (dgx.llm.company.v1). Cada tarjeta se
// pinta con lo que tenga: sin lectura = guion gris, nunca pantalla de error.
import AppKit
import SwiftUI

let endpoint = ProcessInfo.processInfo.environment["LLM_LIVE_URL"]
    ?? "https://dgx.lan.e-dani.com/api/llm/live"
let dashboardURL = ProcessInfo.processInfo.environment["LLM_DASHBOARD_URL"]
    ?? "https://dgx.lan.e-dani.com/inferencia"
let imageURL = ProcessInfo.processInfo.environment["LLM_IMAGE_URL"]
    ?? "https://dgx.lan.e-dani.com/api/image/queue"
let companyURL = ProcessInfo.processInfo.environment["LLM_COMPANY_URL"]
    ?? "https://dgx.lan.e-dani.com/api/llm/company"
let companyPageURL = ProcessInfo.processInfo.environment["LLM_COMPANY_PAGE_URL"]
    ?? "https://dgx.lan.e-dani.com/claude-sessions#compania"
let pollSeconds = 10.0

// ─── modelo ──────────────────────────────────────────────────────────────────

struct LiveStats {
    var running: Int
    var waiting: Int
    var decodeNow: Double?
    var decodeAvg: Double?
    var tone: Tone {
        if waiting > 0 { return .warn }
        if running > 0 { return .up }
        return .rest
    }
}

struct ImageStats {
    var running: Int
    var queue: Int
    var current: String?
    var tone: Tone {
        if queue > 0 { return .warn }
        if running > 0 { return .up }
        return .rest
    }
}

struct CompanyStats {
    var ok: Bool            // se habló con el disparador
    var encendida: Bool     // interruptor (no es avería estar apagada)
    var servicio: Bool      // el servicio del disparador corre
    var maxActivas: Int?
    var activas: Int?
    var enCola: Int
    var epicasOk: Bool
    var curso: Int
    var backlog: Int
    var hechas: Int
    var tone: Tone {
        if !encendida { return .off }
        if enCola > 0 || !ok { return .warn }
        return .up
    }
}

enum Tone {
    case up, warn, rest, off
    var color: Color {
        switch self {
        case .up: return .green
        case .warn: return .orange
        case .rest: return .secondary
        case .off: return .secondary
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var live: LiveStats?
    @Published var image: ImageStats?
    @Published var company: CompanyStats?
    @Published var lastFetch: Date?

    var chipTitle: String {
        var parts: [String] = []
        if let l = live {
            parts.append("\(l.running) req")
            if let t = l.decodeNow ?? l.decodeAvg { parts.append("\(Int(t.rounded())) tok/s") }
        } else {
            parts.append("LLM —")
        }
        if let c = company {
            if !c.encendida { parts.append("🏢 off") }
            else if c.ok, let a = c.activas, let t = c.maxActivas { parts.append("🏢 \(a)/\(t)") }
            else { parts.append("🏢 ?") }
        }
        return parts.joined(separator: " · ")
    }

    var chipTone: Tone {
        if let l = live {
            if l.waiting > 0 || (company?.enCola ?? 0) > 0 { return .warn }
            if l.running > 0 { return .up }
        }
        return .rest
    }
}

// ─── panel (SwiftUI, sistema del DESIGN.md) ─────────────────────────────────

private let grid: CGFloat = 8

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: grid * 1.5) {
            HStack(spacing: grid) {
                Text("LLM Status")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
                if let f = model.lastFetch {
                    Text("hace \(max(0, Int(Date().timeIntervalSince(f)))) s")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            InferenciaCard(live: model.live)
            GeneracionCard(image: model.image)
            CompaniaCard(company: model.company)
        }
        .padding(grid * 1.5)
        .frame(width: 292, alignment: .leading)
    }
}

private struct Card<Content: View>: View {
    let title: String
    let tone: Tone?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: grid) {
            HStack(spacing: grid) {
                Circle()
                    .fill(tone?.color ?? Color.secondary)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            content
        }
        .padding(grid * 1.25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill).opacity(0.55))
        )
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var tone: Tone = .rest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone == .rest ? Color.primary : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func dash(_ v: Int?) -> String { v.map(String.init) ?? "—" }
private func dash(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "—" }

private struct InferenciaCard: View {
    let live: LiveStats?
    var body: some View {
        Card(title: "Inferencia", tone: live?.tone) {
            HStack(alignment: .top, spacing: grid) {
                Metric(value: dash(live?.running), label: "en curso",
                       tone: (live?.running ?? 0) > 0 ? .up : .rest)
                Metric(value: dash(live?.waiting), label: "en cola",
                       tone: (live?.waiting ?? 0) > 0 ? .warn : .rest)
                Metric(value: dash(live.flatMap { $0.decodeNow ?? $0.decodeAvg }),
                       label: "tok/s", tone: (live?.decodeNow ?? live?.decodeAvg) != nil ? .up : .rest)
            }
            if let avg = live?.decodeAvg, let now = live?.decodeNow, now != avg {
                Text("media 2 min \(Int(avg.rounded())) tok/s")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct GeneracionCard: View {
    let image: ImageStats?
    var body: some View {
        Card(title: "Generación · Krea2", tone: image?.tone) {
            HStack(alignment: .top, spacing: grid) {
                Metric(value: dash(image?.running), label: "en progreso",
                       tone: (image?.running ?? 0) > 0 ? .up : .rest)
                Metric(value: dash(image?.queue), label: "en cola",
                       tone: (image?.queue ?? 0) > 0 ? .warn : .rest)
                Spacer()
            }
            if let cur = image?.current, (image?.running ?? 0) > 0 {
                Text(cur).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct CompaniaCard: View {
    let company: CompanyStats?
    var body: some View {
        Card(title: "Compañía", tone: company?.tone) {
            if let c = company {
                HStack(spacing: grid) {
                    Pill(text: c.encendida ? "encendida" : "apagada",
                         tone: c.encendida ? .up : .off)
                    if c.encendida && !c.ok {
                        Pill(text: c.servicio ? "sin lectura" : "disparador caído", tone: .warn)
                    }
                    Spacer()
                    if c.encendida, c.ok {
                        Text("CTO \(dash(c.activas))/\(dash(c.maxActivas))")
                            .font(.system(.callout, design: .rounded)).monospacedDigit()
                    }
                }
                HStack(alignment: .top, spacing: grid) {
                    Metric(value: dash(c.curso), label: "en curso",
                           tone: c.curso > 0 ? .up : .rest)
                    Metric(value: dash(c.backlog), label: "backlog", tone: .rest)
                    Metric(value: dash(c.hechas), label: "hechas", tone: .rest)
                    Metric(value: dash(c.enCola), label: "en cola",
                           tone: c.enCola > 0 ? .warn : .rest)
                }
                if !c.epicasOk {
                    Text("tablero Jira sin lectura")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text("sin lectura del panel de compañía")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let tone: Tone
    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, grid)
            .padding(.vertical, 2)
            .background(Capsule().stroke(tone.color.opacity(0.5), lineWidth: 1))
    }
}

// ─── app ─────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let model = Model()
    var timer: Timer?

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
        let color: NSColor
        switch model.chipTone {
        case .warn: color = .systemOrange
        case .up: color = .systemGreen
        default: color = .secondaryLabelColor
        }
        b.attributedTitle = NSAttributedString(string: model.chipTitle, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular),
        ])
    }

    func poll() {
        fetch(endpoint) { [weak self] j in
            guard let self, let j, j["running"] is NSNumber else {
                self?.refreshTitle(); return
            }
            let n = { (k: String) -> Double? in (j[k] as? NSNumber)?.doubleValue }
            self.model.live = LiveStats(
                running: Int(n("running") ?? 0),
                waiting: Int(n("waiting") ?? 0),
                decodeNow: n("decode_tps_now"),
                decodeAvg: n("decode_tps"))
            self.model.lastFetch = Date()
            self.refreshTitle()
        }
        fetch(imageURL) { [weak self] j in
            guard let self, let j, j["running"] is NSNumber || j["queue_len"] is NSNumber else { return }
            let i = { (k: String) -> Int in ((j[k] as? NSNumber)?.intValue) ?? 0 }
            var current: String?
            if let cur = j["current"] as? [String: Any] {
                current = (cur["preset"] as? String) ?? (cur["checkpoint"] as? String)
                    ?? ((cur["checkpoint"] as? [String: Any])?["filename"] as? String)
            }
            self.model.image = ImageStats(running: i("running"), queue: i("queue_len"), current: current)
        }
        fetch(companyURL) { [weak self] j in
            guard let self else { return }
            guard let j, j["encendida"] != nil else {
                self.model.company = nil
                self.refreshTitle()
                return
            }
            let b = { (k: String) -> Bool in ((j[k] as? NSNumber)?.boolValue) ?? false }
            let n = { (k: String) -> Int? in (j[k] as? NSNumber).map { Int(truncating: $0) } }
            let ep = (j["epicas"] as? [String: Any]) ?? [:]
            let epn = { (k: String) -> Int in ((ep[k] as? NSNumber)?.intValue) ?? 0 }
            self.model.company = CompanyStats(
                ok: b("ok"), encendida: b("encendida"), servicio: b("servicio"),
                maxActivas: n("max_activas"), activas: n("activas"),
                enCola: n("en_cola") ?? 0,
                epicasOk: (ep["ok"] as? Bool) ?? false,
                curso: epn("curso"), backlog: epn("backlog"), hechas: epn("hechas"))
            self.refreshTitle()
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

        let host = NSMenuItem()
        host.view = NSHostingView(rootView: PanelView(model: model))
        menu.addItem(host)
        menu.addItem(.separator())

        add(menu, "Abrir /inferencia", #selector(openDashboard), key: "o")
        add(menu, "Abrir compañía", #selector(openCompany), key: "c")
        menu.addItem(.separator())
        add(menu, "Actualizar ahora", #selector(refreshNow), key: "r")
        add(menu, "Salir", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    @objc func openDashboard() {
        if let url = URL(string: dashboardURL) { NSWorkspace.shared.open(url) }
    }
    @objc func openCompany() {
        if let url = URL(string: companyPageURL) { NSWorkspace.shared.open(url) }
    }
    @objc func refreshNow() { poll() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
// El arranque de NSApplication corre SIEMPRE en el hilo principal: el cast es
// legítimo y el compilador no lo sabe en código top-level de main.swift.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
