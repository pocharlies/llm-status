// LLM Status — chip de la barra de menús del Mac: la home del dashboard, en vivo.
//
// 22-09 (Dani: «quiero todos los datos de dgx.e-dani.com en la primera página,
// detallados, y frescos instantáneos»): el desplegable replica las teselas de
// la home del panel — Perfil, Inferencia (con motores), Generación, Router 24 h,
// Voz, Servicios, SAI, Memoria Sparks, Sesiones y Compañía (con desglose por
// proyecto, épicas en curso y cola) — leyendo los MISMOS endpoints que usa
// home.jsx. Todos cuelgan de rutas sin SSO en LAN/tailnet: /api/llm/live,
// /api/llm/company y /api/llm/sessions (contratos dgx.llm.*.v1, proyecciones
// propias del dashboard), más /api/activity?sections=…, /api/compute/mode,
// /api/service-health y /api/image/queue.
//
// Frescura: temporizador maestro de 5 s; cada fuente en su ritmo (compañía e
// imagen cada 5 s; actividad, perfil y sesiones cada 15 s; servicios cada 20 s
// — los mismos TTL que respeta el panel). El «hace N s» del cabecero corre con
// TimelineView de un segundo: NO depende de la última renderización, así que
// siempre se ve avanzar (queja de Dani 22-09: «pone todo el rato hace 3»).
//
// Sistema visual: el del DESIGN.md de DGX-338 — retícula de 8 pt, SF Rounded
// para números con monospacedDigit, verde=trabajo, naranja=cola/atención,
// gris=reposo o sin lectura. Rojo SOLO donde la home también lo usa (SAI en
// batería, servicios caídos), con el mismo umbral.
import AppKit
import SwiftUI

let base = ProcessInfo.processInfo.environment["LLM_BASE_URL"]
    ?? "https://dgx.lan.e-dani.com"
let pollSeconds = 5.0

// ─── lectura suelta de JSON ──────────────────────────────────────────────────

func num(_ j: [String: Any]?, _ k: String) -> Double? { (j?[k] as? NSNumber)?.doubleValue }
func numIn(_ j: [String: Any], _ k: String) -> Double? { (j[k] as? NSNumber)?.doubleValue }
func boolIn(_ j: [String: Any], _ k: String) -> Bool? { (j[k] as? NSNumber)?.boolValue }
func strIn(_ j: [String: Any], _ k: String) -> String? { j[k] as? String }
func arrIn(_ j: [String: Any], _ k: String) -> [[String: Any]] { (j[k] as? [[String: Any]]) ?? [] }
func dictIn(_ j: [String: Any], _ k: String) -> [String: Any] { (j[k] as? [String: Any]) ?? [:] }

enum Tone {
    case up, accent, warn, down, rest
    var color: Color {
        switch self {
        case .up, .accent: return .green
        case .warn: return .orange
        case .down: return .red
        case .rest: return .secondary
        }
    }
}

// poolState() de home.jsx: «N de M sirviendo» por pool de tarjetas.
func poolState(_ cards: [[String: Any]]) -> (text: String, tone: Tone) {
    if cards.isEmpty { return ("sin despliegue", .rest) }
    let online = cards.filter { strIn($0, "status") == "online" && boolIn($0, "ready") != false }
    let awake = cards.filter { (numIn($0, "replicas") ?? 0) > 0 }
    if !online.isEmpty { return ("\(online.count) de \(max(awake.count, cards.count))", .up) }
    if !awake.isEmpty { return ("\(awake.count) sin Ready", .down) }
    return ("a cero", .rest)
}

// ─── modelo ──────────────────────────────────────────────────────────────────

@MainActor
final class Model: ObservableObject {
    @Published var live: [String: Any]?
    @Published var image: [String: Any]?
    @Published var company: [String: Any]?
    @Published var sessions: [String: Any]?
    @Published var activity: [String: Any]?
    @Published var mode: [String: Any]?
    @Published var health: [String: Any]?
    @Published var lastLive: Date?

    private var tick = 0

    var chipTitle: String {
        var parts: [String] = []
        if let l = live, let r = num(l, "running") {
            parts.append("\(Int(r)) req")
            if let t = (num(l, "decode_tps_now") ?? num(l, "decode_tps")) {
                parts.append("\(Int(t.rounded())) tok/s")
            }
        } else { parts.append("LLM —") }
        if let c = company {
            if boolIn(c, "encendida") == false { parts.append("🏢 off") }
            else if boolIn(c, "ok") == true, let a = num(c, "activas"), let t = num(c, "max_activas") {
                parts.append("🏢 \(Int(a))/\(Int(t))")
            } else { parts.append("🏢 ?") }
        }
        return parts.joined(separator: " · ")
    }

    var chipTone: Tone {
        if let l = live {
            if (num(l, "waiting") ?? 0) > 0 { return .warn }
            if (num(l, "running") ?? 0) > 0 { return .up }
        }
        return .rest
    }

    func start() {
        poll()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll(force: Bool = false) {
        tick = force ? 0 : tick + 1
        fetch(base + "/api/llm/live") { [weak self] j in
            guard let self else { return }
            self.live = num(j, "running") != nil ? j : nil
            if self.live != nil { self.lastLive = Date() }
            self.refreshTitle()
        }
        fetch(base + "/api/image/queue") { [weak self] j in self?.image = j }
        fetch(base + "/api/llm/company") { [weak self] j in
            guard let self else { return }
            self.company = (j?["encendida"] != nil) ? j : nil
            self.refreshTitle()
        }
        if force || tick % 3 == 0 {
            fetch(base + "/api/llm/sessions") { [weak self] j in self?.sessions = j }
            fetch(base + "/api/compute/mode") { [weak self] j in self?.mode = j }
            fetch(base + "/api/activity?sections=vllm,image,gpu,routing,studio_queues,tts,stt,embedding") { [weak self] j in
                self?.activity = j
            }
        }
        if force || tick % 4 == 0 {
            fetch(base + "/api/service-health") { [weak self] j in self?.health = j }
        }
    }

    private func refreshTitle() {
        guard let b = AppHolder.item?.button else { return }
        let color: NSColor
        switch chipTone {
        case .warn: color = .systemOrange
        case .up, .accent: color = .systemGreen
        case .down: color = .systemRed
        case .rest: color = .secondaryLabelColor
        }
        b.attributedTitle = NSAttributedString(string: chipTitle, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular),
        ])
    }

    private func fetch(_ urlStr: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: urlStr) else { return done(nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
        }.resume()
    }
}

enum AppHolder { static var item: NSStatusItem? }

// ─── panel ───────────────────────────────────────────────────────────────────

private let grid: CGFloat = 8

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: grid) {
            HStack(spacing: grid) {
                Text("LLM Status")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                PerfilPill(mode: model.mode)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = model.lastLive.map { max(0, Int(ctx.date.timeIntervalSince($0))) }
                    Text(s == nil ? "leyendo…" : "hace \(s!) s")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle((s ?? 99) > 15 ? Color.orange : Color.secondary)
                }
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: grid) {
                    InferenciaCard(model: model)
                    GeneracionCard(model: model)
                    TraficoCard(model: model)
                    ServiciosCard(model: model)
                    SesionesCard(sessions: model.sessions)
                    CompaniaCard(company: model.company)
                }
            }
            .frame(maxHeight: 430)
        }
        .padding(grid * 1.5)
        .frame(width: 330)
    }
}

private struct PerfilPill: View {
    let mode: [String: Any]?
    var body: some View {
        let m = mode ?? [:]
        let eff = strIn(m, "effective_mode")
        let phase = strIn(m, "phase")
        let tone: Tone = phase == "ready" ? .up : (phase == nil ? .rest : .warn)
        let pill = eff.map { $0 + "·" + (strIn(m, "phase") ?? "?") }
        if let pill {
            Text(pill)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(tone.color)
                .padding(.horizontal, grid - 2).padding(.vertical, 1)
                .background(Capsule().stroke(tone.color.opacity(0.5), lineWidth: 1))
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    var tone: Tone = .rest
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: grid - 2) {
            HStack(spacing: grid - 2) {
                Circle().fill(tone.color).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(grid + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill).opacity(0.55)))
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var tone: Tone = .rest
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit().foregroundStyle(tone == .rest ? Color.primary : tone.color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KV: View {  // fila etiqueta·valor suelta
    let k: String
    let v: String
    var tone: Tone = .rest
    var body: some View {
        HStack(spacing: 4) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(v).font(.system(.caption2, design: .rounded)).monospacedDigit()
                .foregroundStyle(tone == .rest ? Color.primary : tone.color)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

private func di(_ j: [String: Any]?, _ k: String) -> String {
    (num(j ?? [:], k)).map { String(Int($0.rounded())) } ?? "—"
}

private struct InferenciaCard: View {
    let model: Model
    var body: some View {
        let l = model.live ?? [:]
        let engines = arrIn(model.activity ?? [:], "vllm").filter { strIn($0, "status") == "online" }
        let waiting = num(l, "waiting") ?? 0
        let running = num(l, "running") ?? 0
        let kvs = engines.compactMap { num($0, "kv_cache_pct") }
        let kvMax = kvs.max()
        let kvTxt = "KV " + (kvMax.map { String(Int($0.rounded())) + "%" } ?? "—")
        let kvColor: Color = (kvMax ?? 0) > 90 ? Tone.down.color : (kvMax ?? 0) > 75 ? Tone.warn.color : Color.secondary
        Card(title: "Inferencia",
             tone: waiting > 0 ? .warn : (running > 0 ? .up : .rest),
             trailing: AnyView(Text(kvTxt)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(kvColor))) {
            HStack(alignment: .top, spacing: grid) {
                Metric(value: di(model.live, "running"), label: "en curso", tone: running > 0 ? .up : .rest)
                Metric(value: di(model.live, "waiting"), label: "en cola", tone: waiting > 0 ? .warn : .rest)
                Metric(value: (num(l, "decode_tps_now") ?? num(l, "decode_tps")).map { String(Int($0.rounded())) } ?? "—",
                       label: "tok/s global", tone: .up)
            }
            ForEach(Array(engines.enumerated()), id: \.offset) { _, e in
                let er = Int(num(e, "running") ?? 0)
                let ew = Int(num(e, "waiting") ?? 0)
                let es = Int((num(e, "gen_speed_total") ?? 0).rounded())
                KV(k: strIn(e, "name") ?? "motor",
                   v: "\(er)r·\(ew)c · \(es) tok/s",
                   tone: er > 0 ? .up : .rest)
            }
            let mem = arrIn(model.activity ?? [:], "gpu").first { ($0["type"] as? String) != "ups" && num($0, "sys_mem_total_mb") != nil }
            if let mem, let used = num(mem, "sys_mem_used_mb"), let tot = num(mem, "sys_mem_total_mb"), tot > 0 {
                let pct = 100 * used / tot
                let memLabel = "Memoria " + (strIn(mem, "node") ?? "Spark") + " · " + String(Int(tot / 1024)) + " GiB"
                KV(k: memLabel,
                   v: String(format: "%.0f%%", pct),
                   tone: pct > 95 ? .down : pct > 85 ? .warn : .rest)
            }
        }
    }
}

private struct GeneracionCard: View {
    let model: Model
    var body: some View {
        let m = model.mode ?? [:]
        let eff = strIn(m, "effective_mode") ?? "llm-tp"
        let laneId = eff == "creative" ? "comfyui" : "comfyui-rtx"
        let lanes = arrIn(model.activity ?? [:], "image")
        let lane = lanes.first { strIn($0, "id") == laneId }
        let lr = num(lane ?? [:], "queue_running") ?? 0
        let lp = num(lane ?? [:], "queue_pending") ?? 0
        let phase = strIn(m, "phase")
        let kreaTone: Tone = (phase != nil && phase != "ready") ? .rest
            : lr > 0 ? .up : lp > 0 ? .warn : .rest
        let cq = dictIn(m, "creative_queue")
        let sum = dictIn(dictIn(model.activity ?? [:], "studio_queues"), "summary")
        let cqRun = num(cq, "running") ?? num(sum, "running") ?? 0
        let cqPend = num(cq, "pending") ?? num(sum, "pending") ?? 0
        let busy = arrIn(dictIn(model.activity ?? [:], "studio_queues"), "queues")
            .first { (num($0, "running") ?? 0) > 0 }
        let cur = dictIn(model.image ?? [:], "current")
        let curName = strIn(cur, "preset") ?? strIn(dictIn(cur, "checkpoint"), "filename")
        Card(title: "Generación", tone: kreaTone == .rest && cqRun > 0 ? .up : kreaTone) {
            KV(k: "Krea 2 · \(laneId == "comfyui" ? "DGX2" : "RTX")",
               v: lr > 0 ? "generando" : lp > 0 ? "\(Int(lp)) en cola"
                  : strIn(lane ?? [:], "status") == "online" ? "lista" : "en reposo",
               tone: kreaTone)
            if lr > 0, let curName { KV(k: "job", v: curName, tone: .up) }
            KV(k: "Cola creativa",
               v: cqRun > 0 ? "\(Int(cqRun)) en curso" : cqPend > 0 ? "\(Int(cqPend)) en cola" : "nada",
               tone: cqRun > 0 ? .up : cqPend > 0 ? .warn : .rest)
            if let busy, let cur = busy["current"] as? [String: Any] {
                KV(k: strIn(busy, "service_id") ?? "lane",
                   v: strIn(cur, "label") ?? strIn(cur, "operation") ?? "trabajando", tone: .up)
            }
        }
    }
}

private struct TraficoCard: View {
    let model: Model
    var body: some View {
        let routing = arrIn(model.activity ?? [:], "routing").filter { strIn($0, "model_name") != nil }
        let req24 = routing.reduce(0.0) { $0 + (num($1, "total_24h") ?? 0) }
        let fail24 = routing.reduce(0.0) { $0 + (num($1, "failures_24h") ?? 0) }
        let err = req24 > 0 ? 100 * fail24 / req24 : nil
        let top = routing.max { (num($0, "total_24h") ?? 0) < (num($1, "total_24h") ?? 0) }
        let live = arrIn(model.activity ?? [:], "active_requests").count
        let voice = [("TTS", poolState(arrIn(model.activity ?? [:], "tts"))),
                     ("STT", poolState(arrIn(model.activity ?? [:], "stt"))),
                     ("Embedder", poolState(arrIn(model.activity ?? [:], "embedding").filter { strIn($0, "type") != "reranker" })),
                     ("Reranker", poolState(arrIn(model.activity ?? [:], "embedding").filter { strIn($0, "type") == "reranker" }))]
        let voiceDown = voice.filter { $0.1.tone == .down }.count
        let ups = arrIn(model.activity ?? [:], "gpu").first { strIn($0, "type") == "ups" }
        let upsTone: Tone = ups == nil ? .rest : boolIn(ups!, "ups_online") == false ? .down : boolIn(ups!, "low_battery") == true ? .warn : .up
        Card(title: "Tráfico y voz", tone: (err ?? 0) > 10 ? .down : (err ?? 0) > 2 || voiceDown > 0 ? .warn : .up) {
            HStack(alignment: .top, spacing: grid) {
                Metric(value: req24 > 0 ? String(Int(req24)) : "—", label: "req 24 h", tone: .rest)
                Metric(value: err.map { String(format: "%.1f%%", $0) } ?? "—", label: "error 24 h",
                       tone: (err ?? 0) > 10 ? .down : (err ?? 0) > 2 ? .warn : .rest)
                Metric(value: String(live), label: "vivos ahora", tone: live > 0 ? .up : .rest)
            }
            if let top {
                let t = (strIn(top, "model_name") ?? "") + " · " + String(Int(num(top, "total_24h") ?? 0))
                KV(k: "top", v: t, tone: .rest)
            }
            KV(k: "voz", v: voice.map { "\($0.0) \($0.1.text)" }.joined(separator: " · "),
               tone: voiceDown > 0 ? .down : .rest)
            KV(k: "SAI", v: ups.map { boolIn($0, "ups_online") == false ? "EN BATERÍA" : "en red" } ?? "sin lectura",
               tone: upsTone)
        }
    }
}

private struct ServiciosCard: View {
    let model: Model
    var body: some View {
        let h = model.health ?? [:]
        let groups = arrIn(h, "groups")
        let att = groups.filter { ["down", "degraded", "unknown"].contains(strIn($0, "state") ?? "") }
        let tone: Tone = strIn(h, "state") == "up" ? .up : strIn(h, "state") == "down" ? .down : h.isEmpty ? .rest : .warn
        Card(title: "Servicios", tone: tone) {
            HStack(spacing: grid - 2) {
                Text(groups.isEmpty ? "—" : "\(groups.count - att.count)/\(groups.count)")
                    .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                Text(att.isEmpty ? "todo operativo" : "\(att.count) con problema")
                    .font(.caption2).foregroundStyle(att.isEmpty ? Color.secondary : Color.orange)
                Spacer()
            }
            ForEach(Array(att.prefix(4).enumerated()), id: \.offset) { _, g in
                KV(k: strIn(g, "label") ?? strIn(g, "id") ?? "grupo",
                   v: strIn(g, "state") ?? "",
                   tone: strIn(g, "state") == "down" ? .down : .warn)
            }
        }
    }
}

private struct SesionesCard: View {
    let sessions: [String: Any]?
    var body: some View {
        let s = sessions ?? [:]
        let marcha = num(s, "en_marcha") ?? 0
        let espera = num(s, "te_espera") ?? 0
        Card(title: "Sesiones Claude", tone: espera > 0 ? .warn : marcha > 0 ? .up : .rest) {
            HStack(alignment: .top, spacing: grid) {
                Metric(value: di(s, "en_marcha"), label: "en marcha", tone: marcha > 0 ? .up : .rest)
                Metric(value: di(s, "te_espera"), label: "te esperan", tone: espera > 0 ? .warn : .rest)
                Metric(value: di(s, "sin_contestar"), label: "sin contestar", tone: .rest)
                Metric(value: di(s, "terminada_hoy"), label: "hoy", tone: .rest)
            }
        }
    }
}

private struct CompaniaCard: View {
    let company: [String: Any]?
    var body: some View {
        let c = company ?? [:]
        let encendida = boolIn(c, "encendida") == true
        let ok = boolIn(c, "ok") == true
        let cola = num(c, "en_cola") ?? 0
        let tone: Tone = c.isEmpty ? .rest : !encendida ? .rest : (cola > 0 || !ok) ? .warn : .up
        Card(title: "Compañía", tone: tone) {
            if c.isEmpty {
                Text("sin lectura de /api/llm/company").font(.caption2).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: grid - 2) {
                    Pill(text: encendida ? "encendida" : "apagada", tone: encendida ? .up : .rest)
                    if encendida && !ok {
                        Pill(text: boolIn(c, "servicio") == false ? "disparador caído" : "sin lectura", tone: .warn)
                    }
                    Spacer()
                    if encendida, ok, let a = num(c, "activas"), let t = num(c, "max_activas") {
                        Text("CTO \(Int(a))/\(Int(t))")
                            .font(.system(.callout, design: .rounded)).monospacedDigit()
                    }
                }
                let ep = dictIn(c, "epicas")
                if boolIn(ep, "ok") == true {
                    let tab = di(ep, "curso") + " curso · " + di(ep, "backlog") + " backlog · " + di(ep, "hechas") + " hechas"
                    KV(k: "tablero", v: tab, tone: .rest)
                }
                let proy = c["proyectos"] as? [String: Any] ?? [:]
                if proy.count > 1 {
                    KV(k: "proyectos",
                       v: proy.keys.sorted().compactMap { k -> String? in
                            guard let p = proy[k] as? [String: Any] else { return nil }
                            return k + " " + String(Int(num(p, "activas") ?? 0)) + "/" + String(Int(num(p, "max") ?? 0))
                       }.joined(separator: " · "), tone: .rest)
                }
                let curso = arrIn(c, "en_curso")
                if !curso.isEmpty {
                    KV(k: "en curso", v: curso.compactMap { strIn($0, "key") }.prefix(8).joined(separator: " "),
                       tone: .up)
                    if curso.contains(where: { boolIn($0, "pregunta") == true }) {
                        KV(k: "⚠", v: "hay épica con pregunta pendiente", tone: .warn)
                    }
                }
                let keys = (c["en_cola_keys"] as? [String]) ?? []
                if !keys.isEmpty {
                    KV(k: "en cola", v: keys.prefix(8).joined(separator: " "), tone: .warn)
                }
                if (num(c, "requests") ?? 0) > 0 {
                    let rq = di(c, "requests") + " (" + di(c, "activas_it") + " activas)"
                    KV(k: "requests IT", v: rq, tone: .rest)
                }
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
            .padding(.horizontal, grid).padding(.vertical, 2)
            .background(Capsule().stroke(tone.color.opacity(0.5), lineWidth: 1))
    }
}

// ─── app ─────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let model = Model()

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        AppHolder.item = item
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        model.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let host = NSMenuItem()
        let panel = NSHostingView(rootView: PanelView(model: model))
        panel.layoutSubtreeIfNeeded()
        // NSMenu ignora el intrinsic size de los views: sin frame explícito el
        // item colapsa a alto cero (medido 22-09). El alto se fija al de la
        // última medición; el ScrollView interior absorbe lo que sobre.
        let h = panel.fittingSize.height > 10 ? min(panel.fittingSize.height, 560) : 480
        panel.frame = NSRect(x: 0, y: 0, width: 330, height: h)
        host.view = panel
        menu.addItem(host)
        menu.addItem(.separator())
        add(menu, "Abrir el panel", #selector(openDashboard), key: "o")
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

    @objc func openDashboard() { NSWorkspace.shared.open(URL(string: base + "/")!) }
    @objc func openCompany() { NSWorkspace.shared.open(URL(string: base + "/claude-sessions#compania")!) }
    @objc func refreshNow() { model.poll(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
// El arranque de NSApplication corre SIEMPRE en el hilo principal.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
