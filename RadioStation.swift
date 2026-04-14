// RadioVisualizer.swift
// Single-file drop-in. Delete default ContentView.swift and AppNameApp.swift.
// Signing & Capabilities -> App Sandbox -> enable "Outgoing Connections (Client)".

import SwiftUI
import AVFoundation
import AudioToolbox
import Accelerate
import Combine
import CoreVideo
import UniformTypeIdentifiers

// MARK: - Radio Station Model

struct RadioStation: Identifiable, Decodable {
    let id: String
    let name: String
    let url: String
    let favicon: String
    let tags: String
    let country: String
    let codec: String
    let bitrate: Int
    let votes: Int

    enum CodingKeys: String, CodingKey {
        case id = "stationuuid"
        case name, url, favicon, tags, country, codec, bitrate, votes
    }

    /// Manual init for hardcoded favorites
    init(id: String, name: String, url: String, favicon: String = "", tags: String = "", country: String = "", codec: String = "MP3", bitrate: Int = 128, votes: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.favicon = favicon
        self.tags = tags
        self.country = country
        self.codec = codec
        self.bitrate = bitrate
        self.votes = votes
    }
}

// MARK: - Hardcoded Favorites

struct FavoriteStations {
    static let all: [RadioStation] = [
        RadioStation(
            id: "fav1",
            name: "SomaFM Groove Salad",
            url: "https://ice2.somafm.com/groovesalad-128-mp3",
            tags: "ambient,chill", country: "US", bitrate: 128
        ),
        RadioStation(
            id: "fav2",
            name: "KEXP 90.3 FM Seattle",
            url: "https://kexp-mp3-128.streamguys1.com/kexp128.mp3",
            tags: "indie,eclectic", country: "US", bitrate: 128
        ),
        RadioStation(
            id: "fav3",
            name: "NTS Radio 1",
            url: "https://stream-relay-geo.ntslive.net/stream",
            tags: "eclectic,electronic", country: "UK", bitrate: 128
        ),
        RadioStation(
            id: "fav4",
            name: "dublab",
            url: "https://dublab.out.airtime.pro/dublab_a",
            tags: "freeform,experimental", country: "US", bitrate: 128
        ),
    ]
}

// MARK: - Radio Browser Service

@MainActor
class RadioBrowserService: ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let baseURL = "https://de1.api.radio-browser.info/json"
    nonisolated init() {}

    func fetchTopStations(limit: Int = 40) async {
        isLoading = true
        errorMessage = nil
        let urlStr = "\(baseURL)/stations/search?limit=\(limit)&hidebroken=true&order=votes&reverse=true&codec=MP3&bitrateMin=96"
        guard let url = URL(string: urlStr) else { isLoading = false; return }
        var req = URLRequest(url: url)
        req.setValue("RadioVisualizerApp/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            stations = try JSONDecoder().decode([RadioStation].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func fetchByGenre(_ genre: String, limit: Int = 40) async {
        isLoading = true
        errorMessage = nil
        let enc = genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre
        let urlStr = "\(baseURL)/stations/search?tag=\(enc)&limit=\(limit)&hidebroken=true&order=votes&reverse=true&codec=MP3&bitrateMin=96"
        guard let url = URL(string: urlStr) else { isLoading = false; return }
        var req = URLRequest(url: url)
        req.setValue("RadioVisualizerApp/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            stations = try JSONDecoder().decode([RadioStation].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - All Stations State

@MainActor
class AllStationsState: ObservableObject {
    let genres = ["All Stations", "News", "Jazz", "Rock"]
    let countries = ["US", "GB", "IL"]

    @Published var selectedGenreIndex = 0
    @Published var previousGenreIndex = 0
    @Published var selectedStationIndex = 0
    @Published var isSearching = false
    @Published var searchText = ""
    @Published var localFavorites: Set<String> = []
    @Published var isLoading = false
    @Published var currentStations: [RadioStation] = []

    private var genreCache: [Int: [RadioStation]] = [:]
    private let baseURL = "https://de1.api.radio-browser.info/json"

    var filteredStations: [RadioStation] {
        if isSearching && !searchText.isEmpty {
            return currentStations.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return currentStations
    }

    func setGenre(to index: Int) {
        if index >= 0 && index < genres.count {
            previousGenreIndex = selectedGenreIndex
            selectedGenreIndex = index
        }
        selectedStationIndex = 0
        
        let targetIndex = selectedGenreIndex
        
        if let cached = genreCache[targetIndex] {
            currentStations = cached
            isLoading = false
        } else {
            currentStations = []
            isLoading = true
            Task { await fetchGenre(for: targetIndex) }
        }
    }
    
    private func fetchGenre(for index: Int) async {
        let stations: [RadioStation]
        if index == 0 {
            stations = await fetchTopFromCountries(limitPerCountry: 17)
        } else {
            let genre = genres[index].lowercased()
            stations = await fetchGenreFromCountries(genre: genre, limitPerCountry: 10)
        }
        
        if selectedGenreIndex == index {
            genreCache[index] = stations
            currentStations = stations
            isLoading = false
        } else {
            genreCache[index] = stations
        }
    }

    private func fetchTopFromCountries(limitPerCountry: Int) async -> [RadioStation] {
        var all: [RadioStation] = []
        await withTaskGroup(of: [RadioStation].self) { group in
            for country in countries {
                group.addTask { await self.fetchStations(country: country, tag: nil, limit: limitPerCountry) }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return deduplicate(all, limit: 50)
    }

    private func fetchGenreFromCountries(genre: String, limitPerCountry: Int) async -> [RadioStation] {
        var all: [RadioStation] = []
        await withTaskGroup(of: [RadioStation].self) { group in
            for country in countries {
                group.addTask { await self.fetchStations(country: country, tag: genre, limit: limitPerCountry) }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return deduplicate(all, limit: 30)
    }

    nonisolated private func fetchStations(country: String, tag: String?, limit: Int) async -> [RadioStation] {
        var urlStr = "\(baseURL)/stations/search?limit=\(limit)&hidebroken=true&order=votes&reverse=true&codec=MP3&bitrateMin=96&countrycode=\(country)"
        if let tag = tag {
            let enc = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
            urlStr += "&tag=\(enc)"
        }
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("RadioVisualizerApp/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode([RadioStation].self, from: data)
        } catch { return [] }
    }

    private func deduplicate(_ stations: [RadioStation], limit: Int) -> [RadioStation] {
        var seen = Set<String>()
        var unique: [RadioStation] = []
        for s in stations {
            if !seen.contains(s.id) { seen.insert(s.id); unique.append(s) }
        }
        return Array(unique.prefix(limit))
    }

    func reset() {
        previousGenreIndex = selectedGenreIndex
        selectedGenreIndex = 0
        selectedStationIndex = 0
        isSearching = false
        searchText = ""
        genreCache = [:]
        currentStations = []
        isLoading = false
    }

    func toggleFavorite() {
        let stations = filteredStations
        guard selectedStationIndex < stations.count else { return }
        let id = stations[selectedStationIndex].id
        if localFavorites.contains(id) { localFavorites.remove(id) }
        else { localFavorites.insert(id) }
    }
}

// MARK: - Visualizer Settings

struct VisualizerPreset: Identifiable {
    let id = UUID()
    let name: String
    let smoothness: CGFloat
    let uniformity: CGFloat
    let sensitivity: CGFloat
    let scaleMultiplier: CGFloat
    let baseSize: CGFloat
    let spacing: CGFloat
    let yLimit: CGFloat
}

class VisualizerSettings: ObservableObject {
    @Published var smoothness: CGFloat      = 0.75
    @Published var uniformity: CGFloat      = 0.07
    @Published var sensitivity: CGFloat     = 0.11
    @Published var scaleMultiplier: CGFloat = 1.00
    @Published var baseSize: CGFloat        = 5.00
    @Published var spacing: CGFloat         = 12.50
    @Published var yOffsetMax: CGFloat      = 500.00
    @Published var currentPresetIndex: Int  = 0

    let colors: [Color] = [
        Color(red: 0.98, green: 0.25, blue: 0.65),
        Color(red: 0.55, green: 0.55, blue: 1.0),
        Color(red: 0.78, green: 0.85, blue: 0.20),
        Color(red: 1.0,  green: 0.45, blue: 0.35),
        Color(red: 0.92, green: 0.85, blue: 0.75),
        Color(red: 0.25, green: 0.75, blue: 0.50)
    ]

    static let presets: [VisualizerPreset] = [
        VisualizerPreset(
            name: "Pulsar Bloom",
            smoothness: 0.75, uniformity: 0.07, sensitivity: 0.11,
            scaleMultiplier: 1.00, baseSize: 5.00, spacing: 12.50, yLimit: 500
        ),
        VisualizerPreset(
            name: "Fixed Grow",
            smoothness: 0.70, uniformity: 0.00, sensitivity: 0.00,
            scaleMultiplier: 2.5, baseSize: 5.00, spacing: 17.00, yLimit: 500
        ),
        VisualizerPreset(
            name: "Kinetic Weave",
            smoothness: 0.70, uniformity: 0.055, sensitivity: 0.07,
            scaleMultiplier: 0.00, baseSize: 10.35, spacing: 12.75, yLimit: 500
        )
    ]

    var currentPresetName: String {
        Self.presets[currentPresetIndex].name
    }

    func apply(preset: VisualizerPreset) {
        // Animate all parameter changes together with a damped spring
        // (Spatial Shift: 300ms, critically damped — per microanimations spec §4)
        withAnimation(.interpolatingSpring(stiffness: 100, damping: 20)) {
            smoothness      = preset.smoothness
            uniformity      = preset.uniformity
            sensitivity     = preset.sensitivity
            scaleMultiplier = preset.scaleMultiplier
            baseSize        = preset.baseSize
            spacing         = preset.spacing
            yOffsetMax      = preset.yLimit
        }
    }

    func cyclePreset() {
        currentPresetIndex = (currentPresetIndex + 1) % Self.presets.count
        apply(preset: Self.presets[currentPresetIndex])
    }
}

// MARK: - Stream Audio Engine

class StreamAudioEngine: NSObject, URLSessionDataDelegate {

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let destFormat: AVAudioFormat
    private var rollingPeak: Float = 1.0

    private var fileStream: AudioFileStreamID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var maxPktSize: Int = 8192

    private struct CPacket {
        let data: Data
        let desc: AudioStreamPacketDescription?
    }
    private var queue: [CPacket] = []
    private let qLock            = NSLock()
    private var bytesBuffered    = 0
    private let prebuffer        = 32_768
    private var prebufferDone    = false

    /// Incremented on every stopStream(). Callbacks capture their generation at
    /// call-site; if it no longer matches the current one they are silently dropped.
    private var generation: Int = 0

    /// All decode+schedule work runs serially on this queue to prevent concurrent
    /// scheduleBuffer calls from flooding the player node.
    private let decodeQueue = DispatchQueue(label: "radio.decode", qos: .userInitiated)

    /// The generation value that was active when the current stream was opened.
    /// Checked in onProperty/onPackets to drop stale callbacks after stopStream().
    private var activeGeneration: Int = -1

    private var session: URLSession?
    private var task: URLSessionDataTask?

    private let fftSize  = 1024
    private let fftLog2n : vDSP_Length
    private let fftSetup : FFTSetup
    var onAmplitudes: (([Float]) -> Void)?

    override init() {
        fftLog2n = vDSP_Length(log2(Double(1024)))
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(1024))), Int32(kFFTRadix2))!
        destFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!
        super.init()
        buildEngine()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Debug logging flag — set to true to see FFT/decode diagnostics in console
    var debugLogging = true
    private var fftCallCount = 0
    private var fftLastLogTime = Date()
    private var decodeCallCount = 0
    private var decodeLastLogTime = Date()

    private func buildEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: destFormat)
        // Mixer tap: captures audio at the exact output moment for perfect alignment
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: UInt32(fftSize),
            format: nil
        ) { [weak self] buf, _ in
            self?.runFFT(buffer: buf)
        }
        do {
            try engine.start()
        } catch {
            print("StreamEngine start error: \(error)")
        }
        playerNode.play()
    }

    func play(url: URL) {
        stopStream()  // increments generation, cancels session, drains queue
        prebufferDone = false
        bytesBuffered = 0

        // Record the generation for this stream BEFORE opening.
        // onProperty/onPackets check self.activeGeneration — no capture needed.
        activeGeneration = generation
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        let propCB: AudioFileStream_PropertyListenerProc = { clientData, sid, pid, _ in
            Unmanaged<StreamAudioEngine>.fromOpaque(clientData).takeUnretainedValue()
                .onProperty(stream: sid, id: pid)
        }

        let pktCB: AudioFileStream_PacketsProc = { clientData, nBytes, nPkts, data, descs in
            Unmanaged<StreamAudioEngine>.fromOpaque(clientData).takeUnretainedValue()
                .onPackets(numBytes: nBytes, numPackets: nPkts, data: data, descs: descs)
        }

        let st = AudioFileStreamOpen(ptr, propCB, pktCB, 0, &fileStream)
        guard st == noErr else {
            print("AudioFileStreamOpen failed: \(st)")
            return
        }

        var cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task    = session?.dataTask(with: url)
        task?.resume()
    }

    func stopStream() {
        // Bump generation FIRST so any in-flight callbacks from the old session
        // see a mismatched generation and bail out immediately.
        generation += 1

        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil

        if let s = fileStream {
            AudioFileStreamClose(s)
            fileStream = nil
        }

        converter    = nil
        sourceFormat = nil

        // Drain the packet queue before stopping the node to avoid scheduling
        // stale buffers on the new session.
        qLock.lock()
        queue.removeAll()
        bytesBuffered = 0
        qLock.unlock()

        // Wait for any in-progress decodeAndSchedule to finish, then reset node.
        decodeQueue.sync {
            playerNode.stop()
            playerNode.play()   // keep engine running
        }

        // Zero out visuals since the pre-analysis FFT no longer runs
        onAmplitudes?(Array(repeating: 0, count: 6))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let stream = fileStream else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            AudioFileStreamParseBytes(stream, UInt32(data.count), base, [])
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            print("Stream error: \(e.localizedDescription)")
        }
    }

    private func onProperty(stream: AudioFileStreamID, id: AudioFileStreamPropertyID) {
        guard generation == activeGeneration else { return }
        switch id {
        case kAudioFileStreamProperty_DataFormat:
            var sz   = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var asbd = AudioStreamBasicDescription()
            guard AudioFileStreamGetProperty(stream, id, &sz, &asbd) == noErr else { return }
            var mAsbd = asbd
            sourceFormat = AVAudioFormat(streamDescription: &mAsbd)
            if let src = sourceFormat {
                converter = AVAudioConverter(from: src, to: destFormat)
            }

        case kAudioFileStreamProperty_PacketSizeUpperBound,
             kAudioFileStreamProperty_MaximumPacketSize:
            var sz  = UInt32(MemoryLayout<UInt32>.size)
            var val = UInt32(0)
            AudioFileStreamGetProperty(stream, id, &sz, &val)
            if val > 0 { maxPktSize = Int(val) }

        default:
            break
        }
    }

    private func onPackets(
        numBytes: UInt32,
        numPackets: UInt32,
        data: UnsafeRawPointer,
        descs: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard generation == activeGeneration else { return }
        qLock.lock()

        if let descs = descs {
            for i in 0..<Int(numPackets) {
                let d     = descs[i]
                let bytes = Data(
                    bytes: data.advanced(by: Int(d.mStartOffset)),
                    count: Int(d.mDataByteSize)
                )
                let pktDesc = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: d.mVariableFramesInPacket,
                    mDataByteSize: d.mDataByteSize
                )
                queue.append(CPacket(data: bytes, desc: pktDesc))
                bytesBuffered += Int(d.mDataByteSize)
            }
        } else {
            let bytes = Data(bytes: data, count: Int(numBytes))
            queue.append(CPacket(data: bytes, desc: nil))
            bytesBuffered += Int(numBytes)
        }

        let total = bytesBuffered
        qLock.unlock()

        if !prebufferDone && total >= prebuffer {
            prebufferDone = true
            let gen = generation
            decodeQueue.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.decodeAndSchedule(gen: gen)
            }
        } else if prebufferDone {
            let gen = generation
            decodeQueue.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.decodeAndSchedule(gen: gen)
            }
        }
    }

    private func decodeAndSchedule(gen: Int) {
        guard generation == gen else { return }   // drop if we've been superseded
        guard let conv = converter, let srcFmt = sourceFormat else { return }

        qLock.lock()
        let batch = queue
        queue.removeAll()
        qLock.unlock()

        guard !batch.isEmpty else { return }

        var idx     = 0
        let pktSize = maxPktSize

        let inputBlock: AVAudioConverterInputBlock = { [srcFmt, pktSize] _, status -> AVAudioBuffer? in
            guard idx < batch.count else {
                status.pointee = .noDataNow
                return nil
            }
            let pkt = batch[idx]
            idx += 1

            let bufSize = max(pktSize, pkt.data.count)
            let cb = AVAudioCompressedBuffer(
                format: srcFmt,
                packetCapacity: 1,
                maximumPacketSize: bufSize
            )

            pkt.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                cb.data.copyMemory(from: base, byteCount: pkt.data.count)
            }
            cb.byteLength  = UInt32(pkt.data.count)
            cb.packetCount = 1
            if let d = pkt.desc, let ptr = cb.packetDescriptions {
                ptr.pointee = d
            }

            status.pointee = .haveData
            return cb
        }

        let fpkt         = Int(srcFmt.streamDescription.pointee.mFramesPerPacket)
        let framesPerPkt = fpkt > 0 ? fpkt : 1152
        let capacity     = AVAudioFrameCount(framesPerPkt * batch.count + 4096)

        guard let out = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        let result = conv.convert(to: out, error: &error, withInputFrom: inputBlock)
        if result != .error && out.frameLength > 0 {
            playerNode.scheduleBuffer(out)

            // Debug: log decode cadence
            if debugLogging {
                decodeCallCount += 1
                let now = Date()
                let dt = now.timeIntervalSince(decodeLastLogTime)
                if dt >= 1.0 {
                    print("DECODE: \(decodeCallCount) calls/s, batch=\(batch.count) pkts, frames=\(out.frameLength)")
                    decodeCallCount = 0
                    decodeLastLogTime = now
                }
            }
        }
    }

    private func runFFT(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let n = min(count, fftSize)
        var real = Array(UnsafeBufferPointer(start: ch, count: n))
        if real.count < fftSize {
            real += [Float](repeating: 0, count: fftSize - real.count)
        }
        var imag = [Float](repeating: 0, count: fftSize)
        var mags = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(fftSetup, &sc, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&sc, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Logarithmic frequency bands matching musical content distribution.
        // At 44100 Hz / 1024 FFT, each bin ≈ 43 Hz.
        //   Band 0: Sub-bass    ~60–150 Hz   (kick, rumble)
        //   Band 1: Bass        ~150–400 Hz  (bass guitar, warmth)
        //   Band 2: Low-mid     ~400–1 kHz   (vocals, snare body)
        //   Band 3: Mid         ~1–2.5 kHz   (vocal presence, guitar)
        //   Band 4: Presence    ~2.5–6 kHz   (clarity, attack)
        //   Band 5: Brilliance  ~6–16 kHz    (cymbals, air, sibilance)
        let ranges: [ClosedRange<Int>] = [
            1...3,       // ~43–129 Hz
            4...9,       // ~172–387 Hz
            10...23,     // ~430–989 Hz
            24...58,     // ~1032–2494 Hz
            59...139,    // ~2537–5977 Hz
            140...372    // ~6020–15996 Hz
        ]
        // Aggressive treble compensation — high bands have far less spectral energy
        let weights: [Float] = [1.0, 1.4, 2.2, 3.5, 6.0, 10.0]
        var bands = [Float](repeating: 0, count: 6)

        for (i, r) in ranges.enumerated() {
            let v    = r.clamped(to: 0...(mags.count - 1))
            // Use peak (max) instead of average for better transient response
            var peak: Float = 0
            for bin in v { peak = max(peak, mags[bin]) }
            let avg  = v.reduce(Float(0)) { $0 + mags[$1] } / Float(v.count)
            // Blend 60% peak + 40% average for punchy-but-smooth response
            bands[i] = (peak * 0.6 + avg * 0.4) * weights[i]
        }

        // Auto-gain removed to prevent visualizer from mellowing out over time
        for i in 0..<6 { bands[i] *= 1.0 }

        // Debug: log FFT fire rate
        if debugLogging {
            fftCallCount += 1
            let now = Date()
            let dt = now.timeIntervalSince(fftLastLogTime)
            if dt >= 2.0 {
                let rate = Double(fftCallCount) / dt
                let bandStr = bands.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                print("FFT: \(String(format: "%.0f", rate)) Hz  bands: [\(bandStr)]")
                fftCallCount = 0
                fftLastLogTime = now
            }
        }

        onAmplitudes?(bands)
    }
}

// MARK: - Audio Manager

class AudioManager: NSObject, ObservableObject {

    @Published var amplitudes: [Float]      = Array(repeating: 0, count: 6)
    @Published var isPlaying                = false
    @Published var isPaused                 = false
    @Published var currentStation: RadioStation?
    @Published var fileName: String         = "No file selected"

    private let streamEngine = StreamAudioEngine()

    private var fileEngine = AVAudioEngine()
    private var filePlayer = AVAudioPlayerNode()
    private let fftSize    = 1024
    private var rollingPeak: Float = 1.0
    private var log2n      : vDSP_Length
    private var fftSetup   : FFTSetup

    override init() {
        log2n    = vDSP_Length(log2(Double(1024)))
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(1024))), Int32(kFFTRadix2))!
        super.init()
        streamEngine.onAmplitudes = { [weak self] bands in
            DispatchQueue.main.async { self?.amplitudes = bands }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: Radio stream

    func playStation(_ station: RadioStation) {
        stopFilePlayback()
        guard let url = URL(string: station.url) else {
            DispatchQueue.main.async { self.fileName = "Invalid URL" }
            return
        }
        streamEngine.play(url: url)
        DispatchQueue.main.async {
            self.isPlaying      = true
            self.isPaused       = false
            self.currentStation = station
            self.fileName       = station.name
        }
    }

    func togglePause() {
        guard isPlaying else { return }
        if isPaused {
            // Resume — replay current station
            if let station = currentStation, let url = URL(string: station.url) {
                streamEngine.play(url: url)
            }
            DispatchQueue.main.async {
                self.isPaused = false
            }
        } else {
            streamEngine.stopStream()
            DispatchQueue.main.async {
                self.isPaused   = true
                self.amplitudes = Array(repeating: 0, count: 6)
            }
        }
    }

    // MARK: Local file

    func loadAudio(url: URL) {
        streamEngine.stopStream()
        stopFilePlayback()

        fileEngine = AVAudioEngine()
        filePlayer = AVAudioPlayerNode()
        fileEngine.attach(filePlayer)
        fileEngine.connect(filePlayer, to: fileEngine.mainMixerNode, format: nil)

        do {
            let file   = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            fileEngine.connect(filePlayer, to: fileEngine.mainMixerNode, format: format)
            filePlayer.scheduleFile(file, at: nil, completionHandler: nil)

            fileEngine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: UInt32(fftSize),
                format: format
            ) { [weak self] buf, _ in
                self?.analyzeFFT(buffer: buf)
            }

            try fileEngine.start()
            filePlayer.play()

            DispatchQueue.main.async {
                self.isPlaying      = true
                self.isPaused       = false
                self.currentStation = nil
                self.fileName       = url.lastPathComponent
            }
        } catch {
            print("File error: \(error)")
        }
    }

    func stopAll() {
        streamEngine.stopStream()
        stopFilePlayback()
        DispatchQueue.main.async {
            self.isPlaying      = false
            self.isPaused       = false
            self.currentStation = nil
            self.amplitudes     = Array(repeating: 0, count: 6)
        }
    }

    private func stopFilePlayback() {
        fileEngine.mainMixerNode.removeTap(onBus: 0)
        if fileEngine.isRunning { fileEngine.stop() }
        filePlayer.stop()
    }

    private func analyzeFFT(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let n = min(count, fftSize)
        var real = Array(UnsafeBufferPointer(start: ch, count: n))
        if real.count < fftSize {
            real += [Float](repeating: 0, count: fftSize - real.count)
        }
        var imag = [Float](repeating: 0, count: fftSize)
        var mags = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(fftSetup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&sc, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        let ranges: [ClosedRange<Int>] = [
            1...3, 4...9, 10...23, 24...58, 59...139, 140...372
        ]
        let weights: [Float] = [1.0, 1.4, 2.2, 3.5, 6.0, 10.0]
        var bands = [Float](repeating: 0, count: 6)

        for (i, r) in ranges.enumerated() {
            let v    = r.clamped(to: 0...(mags.count - 1))
            var peak: Float = 0
            for bin in v { peak = max(peak, mags[bin]) }
            let avg  = v.reduce(Float(0)) { $0 + mags[$1] } / Float(v.count)
            bands[i] = (peak * 0.6 + avg * 0.4) * weights[i]
        }

        // Auto-gain removed to prevent visualizer from mellowing out over time
        for i in 0..<6 { bands[i] *= 1.0 }

        DispatchQueue.main.async { self.amplitudes = bands }
    }
}

// MARK: - Keyboard Event Handler

class KeyboardEventHandler: ObservableObject {
    var onKeyEvent: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.onKeyEvent?(event) == true {
                return nil // consumed
            }
            return event
        }
    }

    func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        uninstall()
    }
}

// MARK: - Thin Divider (matches Figma)

struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(height: 1)
    }
}

// MARK: - Tweak Slider (for Debug Window)

struct TweakSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).bold()
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

// MARK: - Debug Panel Controller (NSPanel-based floating window)

class DebugPanelController: ObservableObject {
    private var panel: NSPanel?

    func toggle(settings: VisualizerSettings, audio: AudioManager) {
        if let p = panel, p.isVisible {
            p.close()
            panel = nil
        } else {
            let view = DebugWindowView(settings: settings, audio: audio)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 560)

            let p = NSPanel(
                contentRect: NSRect(x: 200, y: 200, width: 300, height: 560),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.title = "Tweak Suite"
            p.contentView = hostingView
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.orderFront(nil)
            panel = p
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}

// MARK: - Debug Window View

struct DebugWindowView: View {
    @ObservedObject var settings: VisualizerSettings
    @ObservedObject var audio: AudioManager
    @State private var currentFPS: Int = 0
    @State private var lastFrameTime = Date()
    private let frameTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tweak Suite")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
                Text(settings.currentPresetName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan)
                Text("\(currentFPS) FPS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(currentFPS > 50 ? .green : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(4)
            }

            VStack(spacing: 8) {
                Button(action: selectFile) {
                    Label("Open File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(audio.fileName)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PRESETS (press V to cycle)")
                        .font(.caption2)
                        .bold()
                        .foregroundColor(.secondary)
                    HStack {
                        ForEach(Array(VisualizerSettings.presets.enumerated()), id: \.element.id) { idx, p in
                            Button(p.name) {
                                settings.currentPresetIndex = idx
                                settings.apply(preset: p)
                            }
                            .buttonStyle(.bordered)
                            .tint(idx == settings.currentPresetIndex ? .cyan : nil)
                        }
                    }
                }

                Divider()

                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MOTION ENGINE")
                            .font(.caption2).bold().foregroundColor(.secondary)
                        TweakSlider(label: "Smoothness",    value: $settings.smoothness,      range: 0...0.99)
                        TweakSlider(label: "Uniformity",    value: $settings.uniformity,       range: 0...1.0)
                        TweakSlider(label: "Y-Sensitivity", value: $settings.sensitivity,      range: 0...50)
                        TweakSlider(label: "Scale Power",   value: $settings.scaleMultiplier,  range: 0...5)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("GEOMETRY")
                            .font(.caption2).bold().foregroundColor(.secondary)
                        TweakSlider(label: "Base Size", value: $settings.baseSize,    range: 5...100)
                        TweakSlider(label: "Spacing",   value: $settings.spacing,     range: 0...100)
                        TweakSlider(label: "Y-Limit",   value: $settings.yOffsetMax,  range: 10...500)
                    }
                }
                .padding(.trailing, 10)

                Divider()

                // Live amplitude readout
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE AMPLITUDES")
                        .font(.caption2).bold().foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        ForEach(0..<6, id: \.self) { i in
                            VStack(spacing: 2) {
                                Text(String(format: "%.1f", audio.amplitudes[i]))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.secondary)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(settings.colors[i])
                                    .frame(width: 30, height: CGFloat(min(audio.amplitudes[i] * 3, 50)))
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 300, minHeight: 500)
        .onReceive(frameTimer) { _ in
            let now = Date()
            let dt  = now.timeIntervalSince(lastFrameTime)
            if dt > 0 { currentFPS = Int(1.0 / dt) }
            lastFrameTime = now
        }
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3]
        if panel.runModal() == .OK, let url = panel.url {
            audio.loadAudio(url: url)
        }
    }
}

// MARK: - Marquee Display Link (shared frame driver)

/// A single shared display-link that drives ALL marquee instances.
/// Each `MarqueeText` registers a callback; removes it on disappear.
/// This avoids N timers for N rows and keeps every marquee in lockstep.
final class MarqueeDisplayLink: ObservableObject {
    static let shared = MarqueeDisplayLink()

    private var displayLink: CVDisplayLink?
    private var callbacks: [UUID: (TimeInterval) -> Void] = [:]
    private var lastTime: TimeInterval = 0
    private let lock = NSLock()

    private init() { start() }

    private func start() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }

        let cb: CVDisplayLinkOutputCallback = { _, inNow, _, _, _, ctx -> CVReturn in
            let self_ = Unmanaged<MarqueeDisplayLink>.fromOpaque(ctx!).takeUnretainedValue()
            let now = TimeInterval(inNow.pointee.videoTime) / TimeInterval(inNow.pointee.videoTimeScale)
            self_.tick(now: now)
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(dl, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func tick(now: TimeInterval) {
        let dt: TimeInterval
        if lastTime == 0 { dt = 1.0 / 120.0 } else { dt = min(now - lastTime, 1.0 / 30.0) }
        lastTime = now

        lock.lock()
        let cbs = callbacks
        lock.unlock()

        DispatchQueue.main.async {
            for (_, cb) in cbs { cb(dt) }
        }
    }

    func register(id: UUID, callback: @escaping (TimeInterval) -> Void) {
        lock.lock()
        callbacks[id] = callback
        lock.unlock()
    }

    func unregister(id: UUID) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        lock.unlock()
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }
}

// MARK: - Marquee Text

/// A self-contained marquee that scrolls long text when `isActive` is true.
/// Driven entirely by manual per-frame offset accumulation — no SwiftUI animations
/// for the scroll itself, so interruptions are always seamless (zero jumps).
///
/// **State machine:**
/// ```
/// idle ─[selected]─▶ delaying ─[1s]─▶ scrolling ─[cycle done]─▶ pausing ─[1s]─▶ scrolling
///                        │                 │
///                   [deselected]       [deselected]
///                        ▼                 ▼
///                      idle           finishing ─[reaches end]─▶ idle
///                                          │
///                                     [reselected]
///                                          ▼
///                                      scrolling (seamless)
/// ```
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let isActive: Bool
    let speed: CGFloat          // points per second
    let startDelay: TimeInterval
    let cycleDelay: TimeInterval

    let spacing: CGFloat = 40 // gap between text copies

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var phase: Phase = .idle
    @State private var phaseTimer: TimeInterval = 0
    @State private var linkID = UUID()

    enum Phase { case idle, delaying, scrolling, finishing, pausing }

    private var needsScroll: Bool { textWidth > containerWidth }
    private var scrollDistance: CGFloat { textWidth + spacing }

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width

            HStack(spacing: spacing) {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { tp in
                            Color.clear.onAppear {
                                textWidth = tp.size.width
                                containerWidth = cw
                            }
                            .onChange(of: tp.size.width) { textWidth = $0 }
                            .onChange(of: cw) { containerWidth = $0 }
                        }
                    )

                if needsScroll {
                    Text(text)
                        .font(font)
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .offset(x: -offset)
            .frame(width: cw, alignment: .leading)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: needsScroll ? .clear : .black, location: 0),
                        .init(color: .black, location: 0.05),
                        .init(color: .black, location: 0.95),
                        .init(color: needsScroll ? .clear : .black, location: 1)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .onChange(of: isActive)  { handleActive($0) }
        .onChange(of: textWidth) { _ in checkAutoStart() }
        .onChange(of: text)      { _ in resetForNewText() }
        .onAppear {
            MarqueeDisplayLink.shared.register(id: linkID) { [self] dt in
                self.tick(dt: dt)
            }
        }
        .onDisappear {
            MarqueeDisplayLink.shared.unregister(id: linkID)
        }
    }

    // ── Frame tick (called ~120 Hz from shared display link) ──

    private func tick(dt: TimeInterval) {
        switch phase {
        case .idle:
            break

        case .delaying:
            phaseTimer += dt
            if phaseTimer >= startDelay {
                phase = .scrolling
                phaseTimer = 0
            }

        case .scrolling, .finishing:
            guard needsScroll else { phase = .idle; return }
            let increment = speed * CGFloat(dt)
            offset += increment

            if offset >= scrollDistance {
                // Completed a full cycle — snap back seamlessly
                offset = 0
                if phase == .finishing {
                    // Was finishing (deselected mid-scroll) → go idle
                    phase = .idle
                } else {
                    // Normal cycle end → pause before next cycle
                    phase = .pausing
                    phaseTimer = 0
                }
            }

        case .pausing:
            phaseTimer += dt
            if phaseTimer >= cycleDelay {
                phase = .scrolling
                phaseTimer = 0
            }
        }
    }

    // ── State transitions ──

    private func handleActive(_ active: Bool) {
        if active {
            switch phase {
            case .idle:
                // Fresh selection → start delay
                offset = 0
                phase = .delaying
                phaseTimer = 0
            case .finishing:
                // Re-selected while finishing → seamless continue scrolling
                phase = .scrolling
            case .delaying, .scrolling, .pausing:
                // Already active — do nothing, no jumps
                break
            }
        } else {
            switch phase {
            case .delaying:
                // Deselected before delay finished → cancel, no scroll happened
                phase = .idle
                phaseTimer = 0
            case .scrolling:
                // Deselected mid-scroll → finish current scroll gracefully
                phase = .finishing
            case .pausing:
                // Deselected during pause → just go idle (offset is already 0)
                phase = .idle
                phaseTimer = 0
            case .idle, .finishing:
                // Already idle or finishing — do nothing
                break
            }
        }
    }

    private func checkAutoStart() {
        if isActive && needsScroll && phase == .idle {
            offset = 0
            phase = .delaying
            phaseTimer = 0
        }
    }

    private func resetForNewText() {
        phase = .idle
        phaseTimer = 0
        offset = 0
        if isActive && needsScroll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                checkAutoStart()
            }
        }
    }
}

// MARK: - Terminal Station Row

struct TerminalStationRow: View {
    let station: RadioStation
    let index: Int
    @Binding var selectedIndex: Int
    @ObservedObject var audio: AudioManager
    let terminalFont: Font

    @State private var scale: CGFloat = 1.0

    private var isSelected: Bool { index == selectedIndex }
    private var isPlaying: Bool {
        audio.currentStation?.id == station.id && audio.isPlaying
    }

    private let pushSpring = Animation.interpolatingSpring(stiffness: 280, damping: 28)
    private let squishSpring = Animation.interpolatingSpring(stiffness: 600, damping: 40)

    var body: some View {
        HStack(spacing: 0) {
            // Chevron — slides in and pushes the text right
            Text(">")
                .font(terminalFont)
                .foregroundColor(.white)
                .opacity(isSelected ? 1 : 0)
                .offset(y: -1) // Subtly center aligned vertically against text
                .frame(width: isSelected ? 10 : 0, alignment: .leading)
                .clipped()
                .animation(pushSpring, value: isSelected)

            // Station name — marquees when selected
            MarqueeText(
                text: station.name,
                font: terminalFont,
                color: isPlaying ? Color(red: 0.98, green: 0.25, blue: 0.65) : .white,
                isActive: isSelected,
                speed: 30,
                startDelay: 1.0,
                cycleDelay: 1.0
            )
            .animation(pushSpring, value: isSelected)
        }
        .scaleEffect(scale, anchor: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            scale = 0.97
            selectedIndex = index
            audio.playStation(station)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(squishSpring) { scale = 1.0 }
            }
        }
    }
}

// MARK: - Favorite Star Shape (from Star 1.svg)

struct FavoriteStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let outer = min(rect.width, rect.height) / 2 * 0.95
        let inner = outer * 0.38
        var path = Path()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4.0 - .pi / 2.0
            let r = i % 2 == 0 ? outer : inner
            let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Play Triangle

struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Tag Pill

struct TagPill: View {
    let text: String
    let font: Font

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(4)
            .background(Color(red: 0.812, green: 0.812, blue: 0.812)) // #cfcfcf
            .cornerRadius(2)
    }
}

// MARK: - Liquid Scroll State (Spring-Physics Driven)

@MainActor
class LiquidScrollState: ObservableObject {
    /// Current animated scroll offset (pixels from top)
    @Published var offset: CGFloat = 0
    /// Current scroll velocity (px/s) — used for motion blur
    @Published var velocity: CGFloat = 0

    /// Spring parameters — critically damped (ζ ≥ 1.0, no jiggle per Bible Law #2)
    private let stiffness: CGFloat = 300
    private let damping: CGFloat = 32

    /// Rubber-band parameters (§2A: 15% max stretch, logarithmic resistance)
    private let rubberBandMaxFraction: CGFloat = 0.15

    private var targetOffset: CGFloat = 0
    private var springVelocity: CGFloat = 0
    private var isAnimating = false
    private let linkID = UUID()

    private(set) var contentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0

    /// Estimated row height (updated dynamically from first measurement)
    var estimatedRowHeight: CGFloat = 32
    /// Spacing between rows
    var rowSpacing: CGFloat = 5

    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    func updateGeometry(contentHeight: CGFloat, viewportHeight: CGFloat) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
    }

    /// Scroll to center a given item index in the viewport
    func scrollToIndex(_ index: Int, totalItems: Int) {
        guard totalItems > 0 else { return }
        let itemY = CGFloat(index) * (estimatedRowHeight + rowSpacing)
        let desiredOffset = itemY - viewportHeight / 2 + estimatedRowHeight / 2
        let clamped = min(max(desiredOffset, 0), maxOffset)
        retarget(clamped)
    }

    /// Instantly jump to offset (no animation) — for genre switches
    func jumpToTop() {
        stopAnimating()
        offset = 0
        targetOffset = 0
        springVelocity = 0
        velocity = 0
    }

    private func retarget(_ target: CGFloat) {
        targetOffset = target
        startAnimating()
    }

    private func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        MarqueeDisplayLink.shared.register(id: linkID) { [weak self] dt in
            self?.tick(dt: dt)
        }
    }

    private func stopAnimating() {
        isAnimating = false
        MarqueeDisplayLink.shared.unregister(id: linkID)
    }

    private func tick(dt: TimeInterval) {
        let dtCG = CGFloat(min(dt, 1.0 / 30.0)) // cap dt to avoid explosion on frame drops

        // Spring force: F = -k * displacement - c * velocity
        let displacement = offset - targetOffset
        let springForce = -stiffness * displacement - damping * springVelocity

        springVelocity += springForce * dtCG
        offset += springVelocity * dtCG

        // Rubber-band: if offset goes out of bounds, apply logarithmic resistance
        let maxOff = maxOffset
        if offset < 0 {
            let maxStretch = max(viewportHeight * rubberBandMaxFraction, 30)
            let overscroll = -offset
            let rubberOffset = maxStretch * log2(1 + overscroll / maxStretch)
            offset = -rubberOffset
            springVelocity *= 0.80
        } else if offset > maxOff && maxOff > 0 {
            let maxStretch = max(viewportHeight * rubberBandMaxFraction, 30)
            let overscroll = offset - maxOff
            let rubberOffset = maxStretch * log2(1 + overscroll / maxStretch)
            offset = maxOff + rubberOffset
            springVelocity *= 0.80
        }

        // Update public velocity for motion blur calculation
        velocity = springVelocity

        // Settle: stop if close enough and slow enough
        if abs(displacement) < 0.5 && abs(springVelocity) < 2.0 {
            offset = targetOffset
            springVelocity = 0
            velocity = 0
            stopAnimating()
        }
    }

    deinit {
        // Note: deinit won't run on MainActor, but the display link
        // will simply find a nil weak self and stop calling.
    }
}

// MARK: - All Stations Station Row

struct AllStationsStationRow: View {
    let station: RadioStation
    let isSelected: Bool
    let isPlaying: Bool
    let isFavorite: Bool
    let terminalFont: Font

    private let cardColor = Color.white
    private let textColor = Color(red: 0.126, green: 0.126, blue: 0.126) // #202020
    private let selectSpring = Animation.interpolatingSpring(stiffness: 600, damping: 40)

    var body: some View {
        HStack(spacing: 5) {
            Text(">")
                .font(terminalFont)
                .foregroundColor(textColor)
                .opacity(isSelected ? 1 : 0)
                .offset(y: -1)
                .frame(width: isSelected ? 10 : 0, alignment: .leading)
                .clipped()
                .animation(selectSpring, value: isSelected)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if isFavorite {
                        FavoriteStarShape()
                            .fill(textColor)
                            .frame(width: 10, height: 10)
                    }
                    if isPlaying {
                        PlayTriangle()
                            .fill(textColor)
                            .frame(width: 7, height: 8)
                    }
                    MarqueeText(
                        text: station.name,
                        font: terminalFont,
                        color: textColor,
                        isActive: isSelected,
                        speed: 30,
                        startDelay: 1.0,
                        cycleDelay: 1.0
                    )
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardColor)
            .cornerRadius(2)
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0.05), radius: isSelected ? 3 : 1, x: 0, y: isSelected ? 1 : 0)
        }
        .animation(selectSpring, value: isSelected)
    }
}

// MARK: - All Stations View

struct AllStationsView: View {
    @ObservedObject var state: AllStationsState
    @ObservedObject var audio: AudioManager
    let terminalFont: Font

    private let bgColor = Color(red: 0.941, green: 0.941, blue: 0.941) // #f0f0f0
    private let textColor = Color(red: 0.157, green: 0.157, blue: 0.157) // #282828
    // Spatial Shift: 300ms Out-Quart
    private let searchSpring = Animation.timingCurve(0.15, 0, 0, 1, duration: 0.3)
    
    @State private var cursorVisible = true

    // Spatial Shift transition: whole list slides in the direction of navigation
    private var genreTransition: AnyTransition {
        let movingRight = state.selectedGenreIndex > state.previousGenreIndex
        return .asymmetric(
            insertion: .move(edge: movingRight ? .trailing : .leading),
            removal:   .move(edge: movingRight ? .leading : .trailing)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar (conditional, animated)
            if state.isSearching {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.bottom, 12)
            }

            // Genre tabs (always visible)
            genreBar
                .padding(.bottom, 12)

            // Content area — whole block swipes, no per-item animation
            ZStack(alignment: .topLeading) {
                contentForCurrentGenre
                    .id(state.selectedGenreIndex)
                    .transition(genreTransition)
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgColor)
        .animation(searchSpring, value: state.isSearching)
        .animation(searchSpring, value: state.selectedGenreIndex)
    }

    /// Single view for the current genre — loading, empty, or station list.
    /// Treated as one opaque block so the entire thing swipes together.
    @ViewBuilder
    private var contentForCurrentGenre: some View {
        if state.isLoading {
            loadingView
        } else if state.filteredStations.isEmpty {
            emptyView
        } else {
            stationList
        }
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Text(state.searchText.isEmpty ? "Search" : state.searchText)
                .font(terminalFont)
                .foregroundColor(textColor.opacity(state.searchText.isEmpty ? 0.5 : 1.0))
                .lineLimit(1)
            
            // Blinking Block Cursor
            Rectangle()
                .fill(textColor.opacity(0.8))
                .frame(width: 6, height: 12)
                .opacity(cursorVisible ? 1 : 0)
                .onAppear {
                    withAnimation(Animation.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                        cursorVisible = false
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(textColor.opacity(0.06))
        )
    }

    private var genreBar: some View {
        HStack(spacing: 12) {
            ForEach(Array(state.genres.enumerated()), id: \.offset) { idx, genre in
                Text(genre)
                    .font(terminalFont)
                    .foregroundColor(textColor)
                    .opacity(idx == state.selectedGenreIndex ? 1.0 : 0.5)
                    .animation(.easeOut(duration: 0.1), value: state.selectedGenreIndex)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Loading")
                .font(terminalFont)
                .foregroundColor(textColor)
            Text("☻")
                .font(terminalFont)
                .foregroundColor(textColor)
                .rotationEffect(.degrees(180))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No stations")
                .font(terminalFont)
                .foregroundColor(textColor)
            Text("☻")
                .font(terminalFont)
                .foregroundColor(textColor)
                .rotationEffect(.degrees(180))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @StateObject private var liquidScroll = LiquidScrollState()

    private var stationList: some View {
        GeometryReader { outerGeo in
            let viewportH = outerGeo.size.height

            // Custom spring-driven scroll — no ScrollView, the VStack moves via offset
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(state.filteredStations.enumerated()), id: \.element.id) { idx, station in
                    AllStationsStationRow(
                        station: station,
                        isSelected: idx == state.selectedStationIndex,
                        isPlaying: audio.currentStation?.id == station.id && audio.isPlaying,
                        isFavorite: state.localFavorites.contains(station.id),
                        terminalFont: terminalFont
                    )
                    .onTapGesture {
                        state.selectedStationIndex = idx
                        audio.playStation(station)
                    }
                }
            }
            .background(
                GeometryReader { contentGeo in
                    Color.clear
                        .onAppear {
                            liquidScroll.updateGeometry(
                                contentHeight: contentGeo.size.height,
                                viewportHeight: viewportH
                            )
                        }
                        .onChange(of: contentGeo.size.height) { h in
                            liquidScroll.updateGeometry(
                                contentHeight: h,
                                viewportHeight: viewportH
                            )
                        }
                }
            )
            .offset(y: -liquidScroll.offset)  // Spring-driven scroll offset
            .frame(width: outerGeo.size.width, height: viewportH, alignment: .topLeading)
            .clipped()  // Clip content outside viewport
            .onChange(of: state.selectedStationIndex) { newIdx in
                liquidScroll.scrollToIndex(
                    newIdx,
                    totalItems: state.filteredStations.count
                )
            }
            .onChange(of: state.filteredStations.count) { _ in
                // When stations change (genre switch, search), jump to top
                liquidScroll.jumpToTop()
            }
            .onAppear {
                liquidScroll.updateGeometry(
                    contentHeight: liquidScroll.contentHeight,
                    viewportHeight: viewportH
                )
            }
        }
    }
}

// MARK: - Main Content View (Terminal-Style Figma Design)

struct ContentView: View {
    @StateObject private var audio    = AudioManager()
    @StateObject private var settings = VisualizerSettings()
    @StateObject private var radio    = RadioBrowserService()
    @StateObject private var keyboard = KeyboardEventHandler()
    @StateObject private var allStationsState = AllStationsState()

    @State private var displayAmplitudes: [CGFloat] = Array(repeating: 0, count: 6)
    @State private var selectedIndex: Int = 0
    @State private var showAllStations: Bool = false


    private let favorites = FavoriteStations.all
    private let debugPanel = DebugPanelController()
    private let frameTimer = Timer.publish(every: 1.0 / 120.0, on: .main, in: .common).autoconnect()

    private let terminalFont = Font.custom("TheBasics_Corporate-Thin", size: 14)
    private let panelBG = Color(red: 0.157, green: 0.157, blue: 0.157) // #282828
    private let outerBG = Color(red: 0.812, green: 0.812, blue: 0.812) // #cfcfcf

    // Spatial Shift: 300ms Out-Quart (microanimations.md §3 Portals / §4 Timing)
    private let portalCurve = Animation.timingCurve(0.15, 0, 0, 1, duration: 0.3)

    // Shared widget dimensions — both panels always match
    private static let widgetWidth: CGFloat = 300
    private static let widgetHeight: CGFloat = 520
    private static let widgetCornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            // ─── NOW PLAYING + FAVORITES (always visible) ───
            VStack(spacing: 4) {
                nowPlayingSection
                favoritesSection
            }
            .padding(4)
            .frame(width: Self.widgetWidth, height: Self.widgetHeight)
            .background(outerBG)
            .clipShape(RoundedRectangle(cornerRadius: Self.widgetCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)

            // ─── ALL STATIONS (slides in to the right) ───
            if showAllStations {
                AllStationsView(state: allStationsState, audio: audio, terminalFont: terminalFont)
                    .frame(width: Self.widgetWidth, height: Self.widgetHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.widgetCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(portalCurve, value: showAllStations)
        .fixedSize()
        .onReceive(frameTimer) { _ in
            updateVisuals()
        }
        .background(WindowAccessor())
        .onAppear {
            installKeyboard()
        }
        .onDisappear {
            keyboard.uninstall()
        }
    }

    // MARK: - Now Playing Section

    private var nowPlayingSection: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                MarqueeText(
                    text: audio.isPlaying && !audio.isPaused
                         ? (audio.currentStation?.name ?? "Playing")
                         : "Not Playing",
                    font: terminalFont,
                    color: .white,
                    isActive: audio.isPlaying && !audio.isPaused,
                    speed: 30,
                    startDelay: 10.0,
                    cycleDelay: 10.0
                )
                Spacer()
            }

            ThinDivider()

            // Visualizer area
            GeometryReader { geo in
                ZStack {
                    // Visualizer dots — animate geometry changes for smooth preset transitions
                    let presetSpring = Animation.interpolatingSpring(stiffness: 100, damping: 20)
                    HStack(spacing: settings.spacing) {
                        ForEach(0..<6, id: \.self) { i in
                            Circle()
                                .fill(settings.colors[i])
                                .frame(width: settings.baseSize, height: settings.baseSize)
                                .animation(presetSpring, value: settings.baseSize)
                                .scaleEffect(safeScale(i, geo.size.height))
                                .offset(y: safeOffset(i, geo.size.height))
                        }
                    }
                    .animation(presetSpring, value: settings.spacing)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 180)

            ThinDivider()

            // << and >> navigation
            HStack {
                Text("<<")
                    .font(terminalFont)
                    .foregroundColor(.white)
                Spacer()
                Text(">>")
                    .font(terminalFont)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        let pushSpring = Animation.interpolatingSpring(stiffness: 280, damping: 28)
        return VStack(spacing: 8) {
            // Header
            HStack {
                Text("Favorites")
                    .font(terminalFont)
                    .foregroundColor(.white)
                Spacer()
            }

            ThinDivider()

            // Station list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(favorites.enumerated()), id: \.element.id) { idx, station in
                    TerminalStationRow(
                        station: station,
                        index: idx,
                        selectedIndex: $selectedIndex,
                        audio: audio,
                        terminalFont: terminalFont
                    )
                }
            }

            ThinDivider()

            // All Stations entry point (keyboard navigable)
            HStack(spacing: 0) {
                Text(">")
                    .font(terminalFont)
                    .foregroundColor(.white)
                    .opacity(selectedIndex == favorites.count ? 1 : 0)
                    .frame(width: selectedIndex == favorites.count ? 10 : 0, alignment: .leading)
                    .clipped()
                    .animation(pushSpring, value: selectedIndex == favorites.count)
                Text("All Stations")
                    .font(terminalFont)
                    .foregroundColor(.white)
                    .animation(pushSpring, value: selectedIndex == favorites.count)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                enterAllStations()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Station Row

    // MARK: - Station Row (terminal-style with animated chevron push)
    // Replaced by TerminalStationRow struct below

    // MARK: - Keyboard Handling

    private func installKeyboard() {
        keyboard.onKeyEvent = { event in
            // Route to all-stations handler when active
            if showAllStations {
                return handleAllStationsKey(event)
            }

            let shift = event.modifierFlags.contains(.shift)

            switch event.keyCode {
            case 126: // Up arrow
                if selectedIndex > 0 {
                    selectedIndex -= 1
                }
                return true

            case 125: // Down arrow
                if selectedIndex < favorites.count {
                    selectedIndex += 1
                }
                return true

            case 36: // Enter / Return
                if selectedIndex == favorites.count {
                    enterAllStations()
                    return true
                }
                if selectedIndex < favorites.count {
                    audio.playStation(favorites[selectedIndex])
                }
                return true

            case 49: // Space
                audio.togglePause()
                return true

            case 123: // Left arrow
                if shift {
                    sweepStation(direction: -1)
                    return true
                }
                return false

            case 124: // Right arrow
                if shift {
                    sweepStation(direction: 1)
                    return true
                }
                return false

            case 2: // 'D' key — toggle debug panel
                debugPanel.toggle(settings: settings, audio: audio)
                return true

            case 9: // 'V' key — cycle visualizer preset
                settings.cyclePreset()
                return true

            default:
                return false
            }
        }
        keyboard.install()
    }

    // MARK: - All Stations Key Handling

    private func handleAllStationsKey(_ event: NSEvent) -> Bool {
        if allStationsState.isSearching {
            return handleSearchKey(event)
        }
        return handleAllStationsNavKey(event)
    }

    private func handleSearchKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape — close search only
            withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                allStationsState.isSearching = false
                allStationsState.searchText = ""
                allStationsState.selectedStationIndex = 0
            }
            return true
        case 36: // Enter — play selected
            let stations = allStationsState.filteredStations
            if allStationsState.selectedStationIndex < stations.count {
                audio.playStation(stations[allStationsState.selectedStationIndex])
            }
            return true
        case 126: // Up
            if allStationsState.selectedStationIndex > 0 {
                allStationsState.selectedStationIndex -= 1
            }
            return true
        case 125: // Down
            if allStationsState.selectedStationIndex < allStationsState.filteredStations.count - 1 {
                allStationsState.selectedStationIndex += 1
            }
            return true
        case 51: // Backspace
            if !allStationsState.searchText.isEmpty {
                allStationsState.searchText.removeLast()
                allStationsState.selectedStationIndex = 0
            } else {
                withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                    allStationsState.isSearching = false
                }
            }
            return true
        default:
            if let chars = event.characters?.filter({ $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } }), !chars.isEmpty {
                allStationsState.searchText += chars
                allStationsState.selectedStationIndex = 0
            }
            return true
        }
    }

    private func handleAllStationsNavKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape — exit all stations
            exitAllStations()
            return true
        case 126: // Up
            if allStationsState.selectedStationIndex > 0 {
                allStationsState.selectedStationIndex -= 1
            }
            return true
        case 125: // Down
            if allStationsState.selectedStationIndex < allStationsState.filteredStations.count - 1 {
                allStationsState.selectedStationIndex += 1
            }
            return true
        case 123: // Left — previous genre or exit
            if allStationsState.selectedGenreIndex > 0 {
                withAnimation(portalCurve) {
                    allStationsState.setGenre(to: allStationsState.selectedGenreIndex - 1)
                }
            } else {
                exitAllStations()
            }
            return true
        case 124: // Right — next genre
            if allStationsState.selectedGenreIndex < allStationsState.genres.count - 1 {
                withAnimation(portalCurve) {
                    allStationsState.setGenre(to: allStationsState.selectedGenreIndex + 1)
                }
            }
            return true
        case 36: // Enter — play selected station
            let stations = allStationsState.filteredStations
            if allStationsState.selectedStationIndex < stations.count {
                audio.playStation(stations[allStationsState.selectedStationIndex])
            }
            return true
        case 1: // S key — toggle search
            withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                allStationsState.isSearching = true
            }
            return true
        case 3: // F key — toggle favorite
            allStationsState.toggleFavorite()
            return true
        case 49: // Space
            audio.togglePause()
            return true
        case 2: // D
            debugPanel.toggle(settings: settings, audio: audio)
            return true
        case 9: // V
            settings.cyclePreset()
            return true
        default:
            return false
        }
    }

    private func enterAllStations() {
        allStationsState.setGenre(to: allStationsState.selectedGenreIndex)
        withAnimation(portalCurve) {
            showAllStations = true
        }
    }

    private func exitAllStations() {
        withAnimation(portalCurve) {
            showAllStations = false
        }
        allStationsState.reset()
        selectedIndex = favorites.count
    }

    private func sweepStation(direction: Int) {
        guard !favorites.isEmpty else { return }

        var newIndex = selectedIndex + direction
        if newIndex < 0 { newIndex = favorites.count - 1 }
        if newIndex >= favorites.count { newIndex = 0 }

        selectedIndex = newIndex
        audio.playStation(favorites[newIndex])
    }

    // MARK: - Visualizer calculations

    private func safeScale(_ i: Int, _ h: CGFloat) -> CGFloat {
        let amp   = displayAmplitudes[i]
        let want  = 1.0 + sqrt(amp * settings.scaleMultiplier)
        let limit = (h * 0.8) / settings.baseSize
        return min(want, limit)
    }

    private func safeOffset(_ i: Int, _ h: CGFloat) -> CGFloat {
        let amp      = displayAmplitudes[i]
        let dir: CGFloat = (i % 2 == 0) ? -1 : 1
        let raw      = dir * (amp * settings.sensitivity * 10)
        let radius   = (settings.baseSize * safeScale(i, h)) / 2
        let winLimit = (h / 2) - radius - 10
        let finalLim = min(settings.yOffsetMax, winLimit)
        return max(min(raw, finalLim), -finalLim)
    }

    private func updateVisuals() {
        let raw = audio.amplitudes.map { CGFloat($0) }
        let avg = raw.reduce(0, +) / CGFloat(raw.count)
        for i in 0..<6 {
            let mixed = raw[i] * (1 - settings.uniformity) + avg * settings.uniformity
            displayAmplitudes[i] += (mixed - displayAmplitudes[i]) * (1 - settings.smoothness)
        }
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.level = .floating
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App Entry Point

@main
struct AV_TesterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
