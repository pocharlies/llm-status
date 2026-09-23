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
// Frescura (23-09, Dani: «refresca lento, parece lageado, quiero req y tok/s en
// directo»): req/cola/tok/s y la actividad llegan por el MISMO SSE que usa la web
// (/api/activity/stream?v=2: `vllm` cada ~1 s, `activity` completo cada 15 s,
// `studio_queues` cada 2 s). Antes salían de /api/llm/live — Prometheus con 10 s
// de caché encima del scrape — y el número se quedaba quieto 10–30 s. /api/llm/live
// queda solo de respaldo si el stream se cae. El resto sigue por sondeo con
// temporizador maestro de 5 s (compañía e imagen cada 5 s; perfil y sesiones cada
// 15 s; servicios cada 20 s). Temporizadores en `.common`: en el modo por defecto
// macOS los congela mientras el panel está abierto (el «no refresca en vivo»).
//
// Panel: NSPopover con un único NSHostingController creado al arrancar. Antes era
// un NSMenu que en cada apertura construía un NSHostingView nuevo y medía su
// fittingSize de forma síncrona (la apertura lenta), y el run loop de tracking
// del menú no dejaba repintar. El «hace N s» corre con TimelineView de un segundo.
//
// Sistema visual: el del DESIGN.md de DGX-338 — retícula de 8 pt, SF Rounded
// para números con monospacedDigit, verde=trabajo, naranja=cola/atención,
// gris=reposo o sin lectura. Rojo SOLO donde la home también lo usa (SAI en
// batería, servicios caídos), con el mismo umbral.
//
// 22-09 (Dani: «2 columnas, más grande, sin scroll»): el panel es una retícula
// SwiftUI de dos columnas (LazyVGrid) de ~640 pt — las seis teselas de la home
// caben de una vista, sin ScrollView.
import AppKit
import SwiftUI
import Charts

let base = ProcessInfo.processInfo.environment["LLM_BASE_URL"]
    ?? "https://dgx.lan.e-dani.com"
let pollSeconds = 5.0
let historyCap = 120  // muestras de tok/s en la gráfica (~2 min a 1 evento/s)
// LLM_STATUS_DEBUG=1: cada actualización del chip a stderr (fuente y título).
let debug = ProcessInfo.processInfo.environment["LLM_STATUS_DEBUG"] != nil

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

// ─── SSE ─────────────────────────────────────────────────────────────────────

// Cliente mínimo de text/event-stream: acumula bytes, corta por línea en blanco
// y entrega (evento, JSON) ya parseado en el hilo principal. Si la conexión se
// cierra o falla, reconecta a los 2 s; el backend manda `ping` cada 15 s, así
// que 45 s sin bytes es una conexión muerta.
final class SSEClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let onEvent: @MainActor (String, [String: Any]) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()

    init(url: URL, onEvent: @escaping @MainActor (String, [String: Any]) -> Void) {
        self.url = url
        self.onEvent = onEvent
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = .infinity
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    func connect() {
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        buffer.removeAll()
        task = session.dataTask(with: req)
        task?.resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // sse-starlette termina las líneas en \r\n. El JSON nunca lleva un \r
        // crudo (va escapado), así que quitarlos todos deja el corte en \n\n.
        buffer.append(Data(data.filter { $0 != 0x0D }))
        let sep = Data("\n\n".utf8)
        while let r = buffer.range(of: sep) {
            let block = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            dispatch(block)
        }
    }

    private func dispatch(_ block: Data) {
        guard let text = String(data: block, encoding: .utf8) else { return }
        var event = "message"
        var payload = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                if !payload.isEmpty { payload += "\n" }
                payload += line.dropFirst(5).drop { $0 == " " }
            }
        }
        guard event != "ping", !payload.isEmpty,
              let j = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        else { return }
        let cb = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(event, j) } }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }
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
    // tok/s de cada evento `vllm` (~1/s): los últimos 2 min, para la gráfica.
    @Published var tpsHistory: [Double] = []

    private var tick = 0
    private var lastVllm: Date?      // último evento `vllm` del stream
    private var lastActivity: Date?  // último `activity`/`activity_delta`
    private var sse: SSEClient?

    // El stream manda `vllm` cada ~1 s; con 8 s sin él se considera caído y el
    // chip vuelve a /api/llm/live.
    var streamFresh: Bool { lastVllm.map { Date().timeIntervalSince($0) < 8 } ?? false }

    private var onlineEngines: [[String: Any]] {
        arrIn(activity ?? [:], "vllm").filter { strIn($0, "status") == "online" }
    }

    // Los tres números del chip. Con el stream vivo salen de los motores online
    // (misma fórmula que decode_tps_now de /api/llm/live: velocidad por petición
    // × secuencias en vuelo); sin él, de /api/llm/live.
    var running: Double? {
        if streamFresh { return onlineEngines.reduce(0) { $0 + (num($1, "running") ?? 0) } }
        return num(live, "running")
    }
    var waiting: Double? {
        if streamFresh { return onlineEngines.reduce(0) { $0 + (num($1, "waiting") ?? 0) } }
        return num(live, "waiting")
    }
    var tokps: Double? {
        if streamFresh {
            return onlineEngines.reduce(0) { $0 + (num($1, "gen_speed") ?? 0) * (num($1, "running") ?? 0) }
        }
        return num(live, "decode_tps_now") ?? num(live, "decode_tps")
    }

    // Chip en dos trozos: LLM («15 req · 29 tok/s») y compañía («0/5»); cada uno
    // va detrás de su SF Symbol en la barra de menús.
    var chipLLM: String {
        guard let r = running else { return "—" }
        var s = "\(Int(r)) req"
        if let t = tokps { s += " · \(Int(t.rounded())) tok/s" }
        return s
    }

    var chipCompany: String? {
        guard let c = company else { return nil }
        if boolIn(c, "encendida") == false { return "off" }
        if boolIn(c, "ok") == true, let a = num(c, "activas"), let t = num(c, "max_activas") {
            return "\(Int(a))/\(Int(t))"
        }
        return "?"
    }

    var chipTitle: String { chipLLM + (chipCompany.map { " · CTO " + $0 } ?? "") }

    var chipTone: Tone {
        if (waiting ?? 0) > 0 { return .warn }
        if (running ?? 0) > 0 { return .up }
        return .rest
    }

    func start() {
        if let u = URL(string: base + "/api/activity/stream?v=2") {
            sse = SSEClient(url: u) { [weak self] ev, j in self?.onStream(ev, j) }
            sse?.connect()
        }
        poll()
        let t = Timer(timeInterval: pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func onStream(_ event: String, _ j: [String: Any]) {
        var a = activity ?? [:]
        switch event {
        case "activity":
            a = j
            lastActivity = Date()
        case "activity_delta":
            for (k, v) in j where k != "_meta" { a[k] = v }
            lastActivity = Date()
        case "vllm":
            a["vllm"] = j["vllm"]
            lastVllm = Date()
            lastLive = lastVllm
        case "live_requests":
            a["active_requests"] = j["active_requests"]
        case "studio_queues":
            a["studio_queues"] = j
        default:
            return
        }
        activity = a
        if event == "vllm" {
            tpsHistory.append(tokps ?? 0)
            if tpsHistory.count > historyCap { tpsHistory.removeFirst(tpsHistory.count - historyCap) }
            refreshTitle()
        }
    }

    func poll(force: Bool = false) {
        tick = force ? 0 : tick + 1
        // Respaldo: /api/llm/live solo pinta el chip si el stream está caído.
        fetch(base + "/api/llm/live") { [weak self] j in
            guard let self else { return }
            self.live = num(j, "running") != nil ? j : nil
            if self.live != nil, !self.streamFresh { self.lastLive = Date() }
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
            // La actividad llega por el stream; el sondeo solo si lleva 30 s callado.
            let stale = lastActivity.map { Date().timeIntervalSince($0) > 30 } ?? true
            if stale {
                fetch(base + "/api/activity?sections=vllm,image,gpu,routing,studio_queues,tts,stt,embedding") { [weak self] j in
                    guard let self, let j, self.lastActivity.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
                    self.activity = j
                }
            }
        }
        if force || tick % 4 == 0 {
            fetch(base + "/api/service-health") { [weak self] j in self?.health = j }
        }
    }

    private func refreshTitle() {
        if debug { FileHandle.standardError.write(Data("\(Date()) \(streamFresh ? "sse" : "poll") \(chipTitle)\n".utf8)) }
        guard let b = AppHolder.item?.button else { return }
        let color: NSColor
        switch chipTone {
        case .warn: color = .systemOrange
        case .up, .accent: color = .systemGreen
        case .down: color = .systemRed
        case .rest: color = .secondaryLabelColor
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let t = NSMutableAttributedString()
        t.append(symbol("bolt.fill", color))
        t.append(NSAttributedString(string: " " + chipLLM, attributes: [.foregroundColor: color, .font: font]))
        if let c = chipCompany {
            let cc: NSColor = c == "off" || c == "?" ? .secondaryLabelColor : .labelColor
            t.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            t.append(symbol("building.2.fill", cc))
            t.append(NSAttributedString(string: " " + c, attributes: [.foregroundColor: cc, .font: font]))
        }
        b.attributedTitle = t
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSAttributedString {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return NSAttributedString() }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = CGRect(x: 0, y: -1.5, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: att)
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
//
// 23-09 (Dani: «mejora el diseño, más moderno»): cabecero con insignia «En vivo»
// que late mientras llega el stream; tesela protagonista a todo el ancho con el
// tok/s grande, en curso/cola y la gráfica de los últimos 2 min (Swift Charts);
// motores y nodos Spark en filas con barra de KV/memoria; el resto de teselas en
// dos columnas con icono SF Symbols teñido por estado. Los números cambian con
// transición numérica en vez de saltar.

private let grid: CGFloat = 8

struct PanelActions {
    var openDashboard: () -> Void
    var openCompany: () -> Void
    var refresh: () -> Void
    var quit: () -> Void
}

struct PanelView: View {
    @ObservedObject var model: Model
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: grid * 1.5) {
            Header(model: model)
            HeroCard(model: model)
            // Dos columnas (Dani 22-09): todo a la vista, sin scroll. Grid y no
            // LazyVGrid: sin scroll no hay nada que diferir y mide de una pasada.
            Grid(alignment: .topLeading, horizontalSpacing: grid * 1.5, verticalSpacing: grid * 1.5) {
                GridRow {
                    CompaniaCard(company: model.company)
                    SesionesCard(sessions: model.sessions)
                }
                GridRow {
                    TraficoCard(model: model)
                    GeneracionCard(model: model)
                }
                GridRow {
                    ServiciosCard(model: model).gridCellColumns(2)
                }
            }
            Footer(actions: actions)
        }
        .padding(grid * 2)
        .frame(width: 680)
        .animation(.smooth(duration: 0.35), value: model.tpsHistory)
    }
}

private struct Header: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: grid * 1.25) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("DGX").font(.system(.headline, design: .rounded, weight: .bold))
                Text(URL(string: base)?.host ?? base).font(.caption2).foregroundStyle(.secondary)
            }
            PerfilPill(mode: model.mode)
            Spacer()
            LiveBadge(last: model.lastLive)
        }
    }
}

private struct LiveBadge: View {
    let last: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = last.map { max(0, Int(ctx.date.timeIntervalSince($0))) }
            let live = (s ?? 99) <= 5
            let c: Color = s == nil ? .secondary : live ? .green : .orange
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .symbolEffect(.pulse, options: .repeating, isActive: live)
                Text(s == nil ? "conectando…" : live ? "En vivo" : "hace \(s!) s")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(c)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(c.opacity(0.14), in: Capsule())
        }
    }
}

private struct PerfilPill: View {
    let mode: [String: Any]?
    var body: some View {
        let m = mode ?? [:]
        let phase = strIn(m, "phase")
        let tone: Tone = phase == "ready" ? .up : (phase == nil ? .rest : .warn)
        if let eff = strIn(m, "effective_mode") {
            Pill(text: eff + (phase.map { " · " + $0 } ?? ""), tone: tone,
                 icon: "gauge.with.dots.needle.67percent")
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    var icon: String = "square.grid.2x2.fill"
    var tone: Tone = .rest
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let tint = tone == .rest ? Color.secondary : tone.color
        VStack(alignment: .leading, spacing: grid) {
            HStack(spacing: grid) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(grid * 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045))
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var tone: Tone = .rest
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit().foregroundStyle(tone == .rest ? Color.primary : tone.color)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(v).font(.system(.caption, design: .rounded, weight: .medium)).monospacedDigit()
                .foregroundStyle(tone == .rest ? Color.primary : tone.color)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// Barra de ocupación con umbrales: verde, naranja >75 %, rojo >90 % (los de la home).
private struct Meter: View {
    let label: String
    let pct: Double?
    var warn: Double = 75
    var crit: Double = 90
    var body: some View {
        let p = min(max(pct ?? 0, 0), 100)
        let c: Color = pct == nil ? .secondary : p > crit ? .red : p > warn ? .orange : .green
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(c.gradient).frame(width: g.size.width * p / 100)
                }
            }
            .frame(height: 5)
            Text(pct.map { String(Int($0.rounded())) + "%" } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private func di(_ j: [String: Any]?, _ k: String) -> String {
    (num(j ?? [:], k)).map { String(Int($0.rounded())) } ?? "—"
}

private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        let top = max((values.max() ?? 0) * 1.15, 1)
        Chart(Array(values.enumerated()), id: \.offset) { p in
            AreaMark(x: .value("t", p.offset), y: .value("tok/s", p.element))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.35), .green.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", p.offset), y: .value("tok/s", p.element))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...(historyCap - 1))
        .chartYScale(domain: 0...top)
    }
}

private struct HeroCard: View {
    @ObservedObject var model: Model
    var body: some View {
        let engines = arrIn(model.activity ?? [:], "vllm").filter { strIn($0, "status") == "online" }
        let nodes = arrIn(model.activity ?? [:], "gpu").filter { strIn($0, "type") != "ups" && num($0, "sys_mem_total_mb") != nil }
        let running = model.running ?? 0
        let waiting = model.waiting ?? 0
        let tps = model.tokps
        let peak = model.tpsHistory.max()
        Card(title: "Inferencia", icon: "bolt.fill",
             tone: waiting > 0 ? .warn : (running > 0 ? .up : .rest),
             trailing: AnyView(Text(model.streamFresh ? "stream · 1 s" : "sondeo · 5 s")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary))) {
            HStack(alignment: .center, spacing: grid * 3) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(tps.map { String(Int($0.rounded())) } ?? "—")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: tps ?? 0))
                        Text("tok/s").font(.system(.title3, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("decode global").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: grid) {
                    Metric(value: String(Int(running)), label: "en curso", tone: running > 0 ? .up : .rest)
                    Metric(value: String(Int(waiting)), label: "en cola", tone: waiting > 0 ? .warn : .rest)
                }
                .frame(width: 70)
                VStack(alignment: .trailing, spacing: 2) {
                    Sparkline(values: model.tpsHistory).frame(height: 64)
                    Text("últimos 2 min" + (peak.map { " · pico \(Int($0.rounded()))" } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            if !engines.isEmpty || !nodes.isEmpty { Divider().opacity(0.6) }
            ForEach(Array(engines.enumerated()), id: \.offset) { _, e in EngineRow(e: e) }
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, n in NodeRow(n: n) }
        }
    }
}

private struct EngineRow: View {
    let e: [String: Any]
    var body: some View {
        let er = Int(num(e, "running") ?? 0)
        let ew = Int(num(e, "waiting") ?? 0)
        let es = Int(((num(e, "gen_speed") ?? 0) * Double(er)).rounded())
        HStack(spacing: grid) {
            Image(systemName: "server.rack")
                .font(.system(size: 11)).foregroundStyle(er > 0 ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(strIn(e, "name") ?? "motor").font(.system(.callout, weight: .medium)).lineLimit(1)
            Text(strIn(e, "node") ?? "").font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: grid)
            Label("\(er)", systemImage: "play.fill").foregroundStyle(er > 0 ? Color.green : Color.secondary)
            Label("\(ew)", systemImage: "hourglass").foregroundStyle(ew > 0 ? Color.orange : Color.secondary)
            Text("\(es) tok/s").frame(width: 62, alignment: .trailing)
            Meter(label: "KV", pct: num(e, "kv_cache_pct")).frame(width: 130)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .labelStyle(CompactLabel())
    }
}

private struct NodeRow: View {
    let n: [String: Any]
    var body: some View {
        let used = num(n, "sys_mem_used_mb") ?? 0
        let tot = num(n, "sys_mem_total_mb") ?? 0
        let pct = tot > 0 ? 100 * used / tot : nil
        let temp = num(n, "temp_c")
        HStack(spacing: grid) {
            Image(systemName: "memorychip")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(strIn(n, "node") ?? "Spark").font(.system(.callout, weight: .medium))
            Text(tot > 0 ? "\(Int(tot / 1024)) GiB" : "").font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: grid)
            Label(temp.map { "\(Int($0.rounded()))°" } ?? "—", systemImage: "thermometer.medium")
                .foregroundStyle((temp ?? 0) > 85 ? Color.orange : Color.secondary)
            Label(num(n, "util_pct").map { "\(Int($0.rounded()))%" } ?? "—", systemImage: "cpu")
                .foregroundStyle(.secondary)
            Label(num(n, "power_w").map { "\(Int($0.rounded())) W" } ?? "—", systemImage: "bolt")
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            // Umbrales de memoria de la home: naranja >85 %, rojo >95 %.
            Meter(label: "RAM", pct: pct, warn: 85, crit: 95).frame(width: 130)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .labelStyle(CompactLabel())
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

private struct Footer: View {
    let actions: PanelActions
    var body: some View {
        HStack(spacing: grid) {
            Button(action: actions.openDashboard) { Label("Panel", systemImage: "safari") }
                .keyboardShortcut("o")
            Button(action: actions.openCompany) { Label("Compañía", systemImage: "building.2") }
            Spacer()
            Button(action: actions.refresh) { Label("Actualizar", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
            Button(action: actions.quit) { Label("Salir", systemImage: "power") }
                .keyboardShortcut("q")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
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
        Card(title: "Generación", icon: "wand.and.stars", tone: kreaTone == .rest && cqRun > 0 ? .up : kreaTone) {
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
        Card(title: "Tráfico y voz", icon: "waveform", tone: (err ?? 0) > 10 ? .down : (err ?? 0) > 2 || voiceDown > 0 ? .warn : .up) {
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
        Card(title: "Servicios", icon: "checkmark.shield.fill", tone: tone) {
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
        Card(title: "Sesiones Claude", icon: "terminal.fill", tone: espera > 0 ? .warn : marcha > 0 ? .up : .rest) {
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
        Card(title: "Compañía", icon: "building.2.fill", tone: tone) {
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
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(.caption, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, grid + 1).padding(.vertical, 3)
        .background(tone.color.opacity(0.14), in: Capsule())
    }
}

// ─── app ─────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    let model = Model()

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        AppHolder.item = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        // Un solo hosting controller para toda la vida de la app: abrir el panel
        // es mostrarlo, no reconstruirlo ni medirlo. Se mantiene suscrito al
        // modelo con el panel cerrado, así al abrir ya está al día.
        let actions = PanelActions(
            openDashboard: { [weak self] in self?.open(base + "/") },
            openCompany: { [weak self] in self?.open(base + "/claude-sessions#compania") },
            refresh: { [weak self] in self?.model.poll(force: true) },
            quit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: PanelView(model: model, actions: actions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        model.start()
    }

    @objc func togglePanel() {
        guard let b = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func open(_ url: String) {
        popover.performClose(nil)
        NSWorkspace.shared.open(URL(string: url)!)
    }
}

let app = NSApplication.shared
// El arranque de NSApplication corre SIEMPRE en el hilo principal.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
