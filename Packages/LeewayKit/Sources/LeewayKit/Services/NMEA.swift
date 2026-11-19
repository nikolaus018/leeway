import Foundation
import Network
import Observation

/// Instruments from the boat's own network: NMEA 0183 over Wi-Fi (TCP or UDP), as most chartplotter
/// gateways, AIS receivers and multiplexers send it. Depth from the sounder, wind from the masthead,
/// heading from the compass, and AIS targets from the boat's receiver, which work without internet.
@Observable
final class NMEAClient {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case tcp, udp
        var id: Self { self }
        var label: String { rawValue.uppercased() }
    }

    struct Settings: Codable, Equatable {
        var enabled = false
        var host = "192.168.4.1"
        var port: UInt16 = 10110
        var transport = Transport.tcp
    }

    enum State: Equatable {
        case off, connecting, receiving, failed(String)
    }

    struct Wind: Equatable {
        /// Degrees off the bow (apparent) or true direction, as the instrument sends it.
        var angle: Double
        /// Knots.
        var speed: Double
        var relative: Bool
    }

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "nmea")
            restart()
        }
    }
    private(set) var state = State.off
    private(set) var sentences = 0

    /// Metres below the surface; nil when not received in the last 10 s.
    var depth: Double? { fresh(depthReading) }
    var wind: Wind? { fresh(windReading) }
    /// Degrees true (or magnetic if that's all the compass sends).
    var heading: Double? { fresh(headingReading) }
    var waterTemperature: Double? { fresh(temperatureReading) }
    /// AIS targets heard by the boat's own receiver.
    private(set) var vessels: [Int: Vessel] = [:]

    private var depthReading: (Double, Date)?
    private var windReading: (Wind, Date)?
    private var headingReading: (Double, Date)?
    /// When a true heading (HDT) last arrived; magnetic headings defer to it.
    private var trueHeadingAt = Date.distantPast
    private var temperatureReading: (Double, Date)?
    private var connection: NWConnection?
    private var listener: NWListener?
    private var buffer = ""
    private var fragments: [String: [Int: String]] = [:]
    private var reconnect: Task<Void, Never>?
    private let queue = DispatchQueue(label: "nmea")

    init() {
        settings = UserDefaults.standard.data(forKey: "nmea").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        restart()
    }

    private func fresh<T>(_ reading: (T, Date)?) -> T? {
        guard let reading, Date.now.timeIntervalSince(reading.1) < 10 else { return nil }
        return reading.0
    }

    // MARK: Connection

    func restart() {
        reconnect?.cancel()
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        buffer = ""
        guard settings.enabled, let port = NWEndpoint.Port(rawValue: settings.port) else {
            state = .off
            return
        }
        state = .connecting
        switch settings.transport {
        case .tcp:
            let connection = NWConnection(host: NWEndpoint.Host(settings.host), port: port, using: .tcp)
            connection.stateUpdateHandler = { [weak self] new in
                Task { @MainActor in self?.handle(new) }
            }
            self.connection = connection
            connection.start(queue: queue)
            let closed: @Sendable () -> Void = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    self.state = .failed("Connection closed")
                    self.scheduleReconnect()
                }
            }
            Self.receive(on: connection, deliver: deliver, closed: closed)
        case .udp:
            do {
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: port)
                let queue = queue, deliver = deliver
                listener.newConnectionHandler = { incoming in
                    incoming.start(queue: queue)
                    Self.receiveDatagrams(on: incoming, deliver: deliver)
                }
                listener.stateUpdateHandler = { [weak self] new in
                    if case .failed(let error) = new { Task { @MainActor in self?.state = .failed(error.localizedDescription) } }
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ new: NWConnection.State) {
        switch new {
        case .failed(let error), .waiting(let error):
            state = .failed(error.localizedDescription)
            scheduleReconnect()
        default:
            break
        }
    }

    /// Gateways drop off when the boat's network restarts: keep trying.
    private func scheduleReconnect() {
        reconnect?.cancel()
        reconnect = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, settings.enabled, case .failed = state { restart() }
        }
    }

    /// Hands received text to the parser on the main actor.
    private var deliver: @Sendable (String) -> Void {
        { [weak self] text in Task { @MainActor in self?.ingest(text) } }
    }

    nonisolated private static func receive(on connection: NWConnection, deliver: @escaping @Sendable (String) -> Void,
                                            closed: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            if let data, let text = String(data: data, encoding: .ascii) { deliver(text) }
            if complete || error != nil {
                closed()
                return
            }
            receive(on: connection, deliver: deliver, closed: closed)
        }
    }

    nonisolated private static func receiveDatagrams(on connection: NWConnection, deliver: @escaping @Sendable (String) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let data, let text = String(data: data, encoding: .ascii) { deliver(text + "\r\n") }
            if error == nil { receiveDatagrams(on: connection, deliver: deliver) }
        }
    }

    // MARK: Parsing

    func ingest(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<end]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...end)
            if !line.isEmpty { parse(line) }
        }
        if buffer.count > 4096 { buffer = "" }
    }

    /// One sentence: `$IIDPT,4.2,0.5*4F` or `!AIVDM,1,1,,A,15M67FC000G?ufbE`Fep4@0<08,0*45`.
    func parse(_ line: String) {
        guard let start = line.firstIndex(where: { $0 == "$" || $0 == "!" }) else { return }
        var body = String(line[line.index(after: start)...])
        if let star = body.lastIndex(of: "*") {
            let checksum = body[body.index(after: star)...].prefix(2)
            body = String(body[..<star])
            guard let expected = UInt8(checksum, radix: 16), body.utf8.reduce(0, ^) == expected else { return }
        }
        let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let tag = fields.first, tag.count >= 5 else { return }
        sentences += 1
        if state != .receiving { state = .receiving }
        let now = Date.now
        switch tag.suffix(3) {
        case "DPT":
            guard fields.count > 1, let d = Double(fields[1]) else { return }
            let offset = fields.count > 2 ? Double(fields[2]) ?? 0 : 0
            // A positive offset is the transducer's depth below the waterline.
            depthReading = (d + max(offset, 0), now)
        case "DBT":
            if fields.count > 3, let d = Double(fields[3]) { depthReading = (d, now) }
        case "DBS":
            if fields.count > 3, let d = Double(fields[3]) { depthReading = (d, now) }
        case "MWV":
            guard fields.count > 5, fields[5] == "A", let angle = Double(fields[1]), var speed = Double(fields[3]) else { return }
            switch fields[4] {
            case "K": speed /= 1.852
            case "M": speed *= 3600 / 1852
            default: break
            }
            windReading = (Wind(angle: angle, speed: speed, relative: fields[2] == "R"), now)
        case "HDT":
            if fields.count > 1, let h = Double(fields[1]) {
                headingReading = (h, now)
                trueHeadingAt = now
            }
        case "HDG", "HDM":
            guard fields.count > 1, var h = Double(fields[1]) else { return }
            if tag.hasSuffix("HDG"), fields.count > 5, let variation = Double(fields[4]) {
                h += fields[5] == "W" ? -variation : variation
            }
            if now.timeIntervalSince(trueHeadingAt) > 2 { headingReading = (Geo.normalize(h), now) }
        case "MTW":
            if fields.count > 1, let t = Double(fields[1]) { temperatureReading = (t, now) }
        case "VDM", "VDO":
            ais(fields)
        default:
            break
        }
    }

    // MARK: AIS

    private func ais(_ fields: [String]) {
        // !AIVDM,count,number,sequence,channel,payload,fill
        guard fields.count >= 7, let count = Int(fields[1]), let number = Int(fields[2]) else { return }
        let payload: String
        if count == 1 {
            payload = fields[5]
        } else {
            let key = fields[3] + fields[4]
            // Part 1 starts a new message: parts left over from a lost one must not mix into it.
            if number == 1 { fragments[key] = [:] }
            fragments[key, default: [:]][number] = fields[5]
            guard let parts = fragments[key], parts.count == count else { return }
            payload = (1...count).compactMap { parts[$0] }.joined()
            fragments[key] = nil
        }
        var bits = AISBits(payload)
        guard let type = bits.uint(6) else { return }
        _ = bits.uint(2)
        guard let mmsi = bits.uint(30), mmsi > 0 else { return }
        var vessel = vessels[mmsi] ?? Vessel(mmsi: mmsi, name: nil, callSign: nil, destination: nil, shipType: nil, length: nil,
                                             beam: nil, lat: 0, lon: 0, sog: nil, cog: nil, heading: nil, navStatus: nil, updated: 0)
        switch type {
        case 1, 2, 3:
            let status = bits.uint(4)
            _ = bits.int(8) // rate of turn
            let sog = bits.uint(10), _ = bits.uint(1)
            let lon = bits.int(28), lat = bits.int(27)
            let cog = bits.uint(12), heading = bits.uint(9)
            guard let lat, let lon, abs(lat) <= 90 * 600_000, abs(lon) <= 180 * 600_000 else { return }
            vessel = vessel.moved(lat: Double(lat) / 600_000, lon: Double(lon) / 600_000,
                                  sog: sog.flatMap { $0 < 1023 ? Double($0) / 10 : nil },
                                  cog: cog.flatMap { $0 < 3600 ? Double($0) / 10 : nil },
                                  heading: heading.flatMap { $0 < 360 ? Double($0) : nil }, status: status)
        case 18, 19:
            _ = bits.uint(8)
            let sog = bits.uint(10), _ = bits.uint(1)
            let lon = bits.int(28), lat = bits.int(27)
            let cog = bits.uint(12), heading = bits.uint(9)
            guard let lat, let lon, abs(lat) <= 90 * 600_000, abs(lon) <= 180 * 600_000 else { return }
            vessel = vessel.moved(lat: Double(lat) / 600_000, lon: Double(lon) / 600_000,
                                  sog: sog.flatMap { $0 < 1023 ? Double($0) / 10 : nil },
                                  cog: cog.flatMap { $0 < 3600 ? Double($0) / 10 : nil },
                                  heading: heading.flatMap { $0 < 360 ? Double($0) : nil }, status: nil)
            if type == 19 {
                bits.skip(6 + 4) // second, regional
                let name = bits.text(20)
                let shipType = bits.uint(8)
                let dims = (bits.uint(9), bits.uint(9), bits.uint(6), bits.uint(6))
                vessel = vessel.described(name: name, shipType: shipType, dimensions: dims)
            }
        case 5:
            bits.skip(2 + 30)
            let callSign = bits.text(7)
            let name = bits.text(20)
            let shipType = bits.uint(8)
            let dims = (bits.uint(9), bits.uint(9), bits.uint(6), bits.uint(6))
            bits.skip(4 + 20 + 8)
            let destination = bits.text(20)
            vessel = vessel.described(name: name, shipType: shipType, dimensions: dims, callSign: callSign, destination: destination)
        case 24:
            let part = bits.uint(2)
            if part == 0 {
                vessel = vessel.described(name: bits.text(20), shipType: nil, dimensions: (nil, nil, nil, nil))
            } else {
                let shipType = bits.uint(8)
                bits.skip(42)
                let callSign = bits.text(7)
                let dims = (bits.uint(9), bits.uint(9), bits.uint(6), bits.uint(6))
                vessel = vessel.described(name: nil, shipType: shipType, dimensions: dims, callSign: callSign)
            }
        default:
            return
        }
        vessels[mmsi] = vessel
        // Forget ships not heard from for 20 minutes.
        if vessels.count > 50 {
            let cutoff = Date.now.timeIntervalSince1970 - 1200
            vessels = vessels.filter { $0.value.updated > cutoff }
        }
    }
}

/// Reads an AIS payload's 6-bit ASCII armouring as a bit stream.
struct AISBits {
    private var bits: [Bool] = []
    private var position = 0

    init(_ payload: String) {
        for scalar in payload.unicodeScalars {
            var v = Int(scalar.value) - 48
            if v > 40 { v -= 8 }
            guard (0..<64).contains(v) else { continue }
            for i in (0..<6).reversed() { bits.append(v >> i & 1 == 1) }
        }
    }

    mutating func skip(_ n: Int) { position += n }

    mutating func uint(_ n: Int) -> Int? {
        guard position + n <= bits.count else { return nil }
        var v = 0
        for i in position..<(position + n) { v = v << 1 | (bits[i] ? 1 : 0) }
        position += n
        return v
    }

    mutating func int(_ n: Int) -> Int? {
        guard let v = uint(n) else { return nil }
        return v & (1 << (n - 1)) != 0 ? v - (1 << n) : v
    }

    /// AIS 6-bit text, trailing `@` and spaces removed.
    mutating func text(_ characters: Int) -> String? {
        var s = ""
        for _ in 0..<characters {
            guard let c = uint(6) else { break }
            s.append(Character(UnicodeScalar(UInt8(c < 32 ? c + 64 : c))))
        }
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Vessel {
    func moved(lat: Double, lon: Double, sog: Double?, cog: Double?, heading: Double?, status: Int?) -> Vessel {
        Vessel(mmsi: mmsi, name: name, callSign: callSign, destination: destination, shipType: shipType, length: length, beam: beam,
               lat: lat, lon: lon, sog: sog, cog: cog, heading: heading, navStatus: status ?? navStatus,
               updated: Date.now.timeIntervalSince1970)
    }

    func described(name: String?, shipType: Int?, dimensions d: (Int?, Int?, Int?, Int?), callSign: String? = nil,
                   destination: String? = nil) -> Vessel {
        let length = (d.0 ?? 0) + (d.1 ?? 0), beam = (d.2 ?? 0) + (d.3 ?? 0)
        return Vessel(mmsi: mmsi, name: name ?? self.name, callSign: callSign ?? self.callSign,
                      destination: destination ?? self.destination, shipType: shipType.flatMap { $0 > 0 ? $0 : nil } ?? self.shipType,
                      length: length > 0 ? Double(length) : self.length, beam: beam > 0 ? Double(beam) : self.beam,
                      lat: lat, lon: lon, sog: sog, cog: cog, heading: heading, navStatus: navStatus, updated: updated)
    }
}
