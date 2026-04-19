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

struct RadioStation: Identifiable, Codable {
    let id: String
    let name: String
    let url: String
    /// Resolved direct stream URL from Radio Browser API (follows redirects).
    /// Prefer this over `url` which may point to a playlist or redirect page.
    let urlResolved: String
    let favicon: String
    let tags: String
    let country: String
    let codec: String
    let bitrate: Int
    let votes: Int

    enum CodingKeys: String, CodingKey {
        case id = "stationuuid"
        case name, url, favicon, tags, country, codec, bitrate, votes
        case urlResolved = "url_resolved"
    }

    /// Manual init for hardcoded favorites
    init(id: String, name: String, url: String, urlResolved: String = "", favicon: String = "", tags: String = "", country: String = "", codec: String = "MP3", bitrate: Int = 128, votes: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.urlResolved = urlResolved
        self.favicon = favicon
        self.tags = tags
        self.country = country
        self.codec = codec
        self.bitrate = bitrate
        self.votes = votes
    }

    /// Best stream URL to use for playback.
    /// Prefers `url_resolved` (direct stream) over `url` (may be playlist/redirect).
    var streamURL: String {
        let resolved = urlResolved.trimmingCharacters(in: .whitespaces)
        return resolved.isEmpty ? url : resolved
    }
}

// MARK: - Station Metadata Helpers

extension RadioStation {
    /// Extracts FM frequency from station name, e.g. "KEXP 90.3 FM Seattle" → "90.3 FM"
    var fmFrequency: String? {
        let pattern = #"(\d{2,3}(?:\.\d{1,2})?)\s*[Ff][Mm]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let freqRange = Range(match.range(at: 1), in: name) else { return nil }
        return "\(name[freqRange]) FM"
    }

    /// Compact grey metadata string using "/" as divider; omits blank fields.
    /// Example: "90.3 FM / US / ambient / chill / MP3 / 128k"
    var metadataDisplayString: String {
        var parts: [String] = []
        if let freq = fmFrequency         { parts.append(freq) }
        if !country.isEmpty               { parts.append(country.uppercased()) }
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .forEach { parts.append($0) }
        if !codec.isEmpty                 { parts.append(codec.uppercased()) }
        if bitrate > 0                    { parts.append("\(bitrate)k") }
        return parts.joined(separator: " / ")
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

// MARK: - Radio Browser Query (intelligent multi-param search)

/// Structured query assembled by `RadioQueryParser` from a free-form input string.
/// Maps directly to the Radio Browser `/stations/search` endpoint parameters:
/// https://de1.api.radio-browser.info/
struct RadioBrowserQuery {
    var name: String = ""
    var countryCode: String = ""   // ISO-3166-1 alpha-2 (preferred over `country`)
    var country: String = ""       // Full country name — used only if ISO code is unknown
    var state: String = ""
    var tags: [String] = []

    var isEmpty: Bool {
        name.isEmpty && countryCode.isEmpty && country.isEmpty && state.isEmpty && tags.isEmpty
    }

    func urlQueryItems(limit: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit",       value: String(limit)),
            URLQueryItem(name: "hidebroken",  value: "true"),
            URLQueryItem(name: "order",       value: "votes"),
            URLQueryItem(name: "reverse",     value: "true"),
        ]
        if !name.isEmpty           { items.append(URLQueryItem(name: "name",        value: name)) }
        if !countryCode.isEmpty    { items.append(URLQueryItem(name: "countrycode", value: countryCode)) }
        else if !country.isEmpty   { items.append(URLQueryItem(name: "country",     value: country)) }
        if !state.isEmpty          { items.append(URLQueryItem(name: "state",       value: state)) }
        if tags.count == 1         { items.append(URLQueryItem(name: "tag",         value: tags[0])) }
        else if tags.count > 1     { items.append(URLQueryItem(name: "tagList",     value: tags.joined(separator: ","))) }
        return items
    }
}

/// Parses a free-form input ("Jazz Israel", "United States NPR", "KAN GIMEL") into a
/// `RadioBrowserQuery`. Recognizes:
///   • A curated country phrase list → ISO country code
///   • A curated tag/genre vocabulary → `tag`/`tagList`
///   • Everything left over → `name` (station title match)
///
/// The parser is deliberately conservative: unknown tokens always fall through to
/// `name` so unusual station titles ("KAN GIMEL") still resolve cleanly.
enum RadioQueryParser {
    /// Country phrase → ISO-3166-1 alpha-2. Keys must be lowercase.
    /// Ordered longest-first at match time, so "united kingdom" wins over "united".
    private static let countryPhrases: [String: String] = [
        // The Americas
        "united states": "US", "united states of america": "US", "usa": "US", "us": "US", "america": "US",
        "canada": "CA", "mexico": "MX", "brazil": "BR", "argentina": "AR", "chile": "CL",
        "colombia": "CO", "peru": "PE", "venezuela": "VE", "cuba": "CU",
        // Europe
        "united kingdom": "GB", "uk": "GB", "great britain": "GB", "britain": "GB",
        "england": "GB", "scotland": "GB", "wales": "GB",
        "ireland": "IE", "france": "FR", "germany": "DE", "spain": "ES", "italy": "IT",
        "portugal": "PT", "netherlands": "NL", "holland": "NL", "belgium": "BE",
        "switzerland": "CH", "austria": "AT", "sweden": "SE", "norway": "NO",
        "denmark": "DK", "finland": "FI", "poland": "PL", "czech republic": "CZ",
        "czechia": "CZ", "hungary": "HU", "greece": "GR", "romania": "RO",
        "ukraine": "UA", "russia": "RU", "iceland": "IS",
        // Middle East & Africa
        "israel": "IL", "palestine": "PS", "turkey": "TR", "egypt": "EG",
        "saudi arabia": "SA", "united arab emirates": "AE", "uae": "AE",
        "south africa": "ZA", "morocco": "MA", "nigeria": "NG", "kenya": "KE",
        // Asia & Pacific
        "japan": "JP", "china": "CN", "south korea": "KR", "korea": "KR",
        "india": "IN", "pakistan": "PK", "indonesia": "ID", "philippines": "PH",
        "thailand": "TH", "vietnam": "VN", "malaysia": "MY", "singapore": "SG",
        "hong kong": "HK", "taiwan": "TW",
        "australia": "AU", "new zealand": "NZ",
    ]

    /// Genre/format keywords recognized as explicit tags. Lowercase, no punctuation.
    private static let knownTags: Set<String> = [
        "jazz", "rock", "pop", "classical", "classic", "news", "talk", "sports",
        "hiphop", "rap", "electronic", "edm", "house", "techno", "trance",
        "ambient", "chill", "lounge", "country", "folk", "blues", "reggae",
        "latin", "salsa", "dance", "indie", "alternative", "metal", "punk",
        "soul", "funk", "oldies", "christian", "gospel", "religious", "kids",
        "comedy", "culture", "public", "college", "community", "tech",
        "business", "weather", "dnb", "dubstep", "disco", "bollywood", "kpop",
        "anime", "workout", "80s", "90s", "70s", "60s", "2000s",
    ]

    /// Tokenizer: lowercases and splits on whitespace. Unicode scalars (CJK, emoji,
    /// accents) pass through unchanged so unusual names route to `name=` intact.
    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    static func parse(_ input: String) -> RadioBrowserQuery {
        var tokens = tokenize(input)
        var query = RadioBrowserQuery()

        // 1) Country phrase match — try longest phrases first (up to 3 tokens).
        let maxLen = min(3, tokens.count)
        if maxLen >= 1 {
            phraseLoop: for length in stride(from: maxLen, through: 1, by: -1) {
                var i = 0
                while i <= tokens.count - length {
                    let phrase = tokens[i..<(i + length)].joined(separator: " ")
                    if let code = countryPhrases[phrase] {
                        query.countryCode = code
                        tokens.removeSubrange(i..<(i + length))
                        continue phraseLoop
                    }
                    i += 1
                }
            }
        }

        // 2) Tag match — extract known genre keywords.
        var remaining: [String] = []
        for t in tokens {
            if knownTags.contains(t) {
                if !query.tags.contains(t) { query.tags.append(t) }
            } else {
                remaining.append(t)
            }
        }

        // 3) Leftovers → name. Preserve original casing for readability; the API
        //    matches case-insensitively either way.
        if !remaining.isEmpty {
            let originalTokens = input.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            let remainingSet = Set(remaining)
            let kept = originalTokens.filter { remainingSet.contains($0.lowercased()) }
            query.name = kept.joined(separator: " ")
        }

        return query
    }
}

// MARK: - All Stations State

@MainActor
class AllStationsState: ObservableObject {
    /// Genre tabs shown in the All Stations browser. "All Stations" is always index 0;
    /// the rest come from `AppSettings.enabledGenres` and update live when Settings changes.
    @Published var genres: [String] = ["All Stations", "News", "Jazz", "Rock"]
    /// Countries biased when fetching the "All Stations" and per-genre lists.
    /// Mirrored from `AppSettings.countryBias`.
    @Published var countries: [String] = ["US", "GB", "IL"]

    @Published var selectedGenreIndex = 0
    @Published var previousGenreIndex = 0
    @Published var selectedStationIndex = 0
    @Published var isSearching = false
    @Published var searchText = ""
    @Published var favoriteStations: [RadioStation] = []
    @Published var recentStations: [RadioStation] = []
    @Published var isLoading = false
    @Published var currentStations: [RadioStation] = []

    /// Results from the most recent Radio Browser API search. Empty while no query is
    /// active; overrides `currentStations` in `filteredStations` whenever `searchText`
    /// is non-empty.
    @Published var searchResults: [RadioStation] = []
    /// True while a debounced API search is in flight — drives the pulsing border on
    /// the search palette.
    @Published var isSearchLoading = false
    /// Non-nil when the last search surfaced no results (or the network failed).
    /// Shown in the empty state of the palette.
    @Published var searchNotice: String?

    var localFavorites: Set<String> {
        Set(favoriteStations.map { $0.id })
    }

    private var genreCache: [Int: [RadioStation]] = [:]
    private let baseURL = "https://de1.api.radio-browser.info/json"
    private let favoritesKey = "savedFavoriteStations"
    private let recentsKey = "savedRecentStations"
    private let lastGenreKey = "lastSelectedGenreIndex"

    /// Debounce + cancellation plumbing for the global search palette.
    /// A 300ms delay after the final keystroke keeps us well under the API rate
    /// limits; each new keystroke cancels any in-flight fetch so stale results
    /// never flash in the UI.
    private var searchCancellables: Set<AnyCancellable> = []
    private var searchTask: Task<Void, Never>?
    private static let searchResultLimit = 100

    init() {
        if let data = UserDefaults.standard.data(forKey: "savedFavoriteStations"),
           let stations = try? JSONDecoder().decode([RadioStation].self, from: data) {
            favoriteStations = stations
        } else {
            favoriteStations = FavoriteStations.all
        }
        if let data = UserDefaults.standard.data(forKey: "savedRecentStations"),
           let stations = try? JSONDecoder().decode([RadioStation].self, from: data) {
            recentStations = stations
        }

        // Seed the selected tab from UserDefaults first so that any prefetch kicked
        // off by the upcoming `syncWithSettings` call hits the user's actual tab.
        let savedGenre = UserDefaults.standard.integer(forKey: lastGenreKey)
        if savedGenre >= 0 && savedGenre < genres.count {
            selectedGenreIndex = savedGenre
            previousGenreIndex = savedGenre
        }

        // Pull the current user preferences for genres + country bias. This clamps
        // the selected index if the saved tab no longer exists.
        syncWithSettings(AppSettings.shared)

        // Debounced pipeline: every keystroke bumps `searchText`, we wait 300ms of
        // silence, then fire an async API search. `removeDuplicates` prevents a
        // duplicate fetch when the state is cleared + reset to the same value.
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.performSearch(text)
            }
            .store(in: &searchCancellables)

        // Live-reload genre tabs + country bias when the Settings panel edits them.
        // We collapse back to "All Stations" and dump the cache so the next genre
        // fetch reflects the new country set.
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Defer one tick so AppSettings' published properties are committed
                // before we read them.
                DispatchQueue.main.async { self?.syncWithSettings(AppSettings.shared) }
            }
            .store(in: &searchCancellables)
    }

    /// Copy the user-facing genre + country bias lists from `AppSettings` into this
    /// state, and wipe cached station lists if either has changed — cached lists are
    /// country-scoped and would otherwise be stale.
    func syncWithSettings(_ settings: AppSettings) {
        let newGenres = ["All Stations"] + settings.enabledGenres.map { $0.displayName }
        let newCountries = settings.countryBias.isEmpty ? ["US"] : settings.countryBias

        let genresChanged    = newGenres != genres
        let countriesChanged = newCountries != countries

        guard genresChanged || countriesChanged else { return }

        genres    = newGenres
        countries = newCountries

        // Clamp selection into the new tab range.
        if selectedGenreIndex >= genres.count {
            selectedGenreIndex = 0
            previousGenreIndex = 0
            UserDefaults.standard.set(0, forKey: lastGenreKey)
        }

        // Country or genre membership changed — invalidate cache and refetch the
        // currently-selected tab so the UI reflects the new bias immediately.
        genreCache = [:]
        currentStations = []
        isLoading = true
        let targetIndex = selectedGenreIndex
        Task { await fetchGenre(for: targetIndex) }
    }

    var filteredStations: [RadioStation] {
        // With a live query the palette renders remote API results; otherwise the
        // selected genre's cached list wins. `searchText` (not `isSearching`) is the
        // source of truth so filtering persists after ↓ transfers focus to the list.
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return currentStations }
        return searchResults
    }

    /// Debounced entry point — cancels the previous fetch and kicks off a new one
    /// matching the parsed query. Empty/whitespace input clears the results.
    private func performSearch(_ rawText: String) {
        searchTask?.cancel()

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchResults = []
            isSearchLoading = false
            searchNotice = nil
            return
        }

        let query = RadioQueryParser.parse(text)
        guard !query.isEmpty else {
            // Shouldn't happen — parser routes unknown tokens to `name` — but defend anyway.
            searchResults = []
            isSearchLoading = false
            searchNotice = nil
            return
        }

        isSearchLoading = true
        searchNotice = nil
        let limit = Self.searchResultLimit
        let baseURL = self.baseURL

        searchTask = Task { [weak self] in
            let outcome = await Self.fetchSearch(query: query, baseURL: baseURL, limit: limit)
            if Task.isCancelled { return }
            guard let self = self else { return }
            switch outcome {
            case .success(let stations):
                self.searchResults = stations
                self.searchNotice = stations.isEmpty ? "No stations found" : nil
            case .failure:
                self.searchResults = []
                self.searchNotice = "Search unavailable"
            }
            self.isSearchLoading = false
            self.selectedStationIndex = 0
        }
    }

    /// Off-main-actor network call. Using `URLComponents` lets us compose multiple
    /// query parameters without hand-rolling percent-encoding for every field.
    nonisolated private static func fetchSearch(
        query: RadioBrowserQuery,
        baseURL: String,
        limit: Int
    ) async -> Result<[RadioStation], Error> {
        guard var comps = URLComponents(string: "\(baseURL)/stations/search") else {
            return .success([])
        }
        comps.queryItems = query.urlQueryItems(limit: limit)
        guard let url = comps.url else { return .success([]) }
        var req = URLRequest(url: url)
        req.setValue("RadioVisualizerApp/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .success([])
            }
            let stations = try JSONDecoder().decode([RadioStation].self, from: data)
            return .success(stations)
        } catch is CancellationError {
            return .success([])   // cancelled — discard result, caller already bailed
        } catch {
            return .failure(error)
        }
    }

    func setGenre(to index: Int) {
        if index >= 0 && index < genres.count {
            previousGenreIndex = selectedGenreIndex
            selectedGenreIndex = index
            UserDefaults.standard.set(index, forKey: lastGenreKey)
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
            // Translate the display name back to the Radio Browser API tag. Falls
            // back to a lowercased slug so hand-added genres still fetch something
            // reasonable.
            let display = genres[index]
            let tag = GenreOption.allOptions
                .first(where: { $0.displayName == display })?.tag
                ?? display.lowercased()
            stations = await fetchGenreFromCountries(genre: tag, limitPerCountry: 10)
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
        let codec = codecFilter()
        let minBitrate = AppSettings.shared.minBitrate
        var all: [RadioStation] = []
        await withTaskGroup(of: [RadioStation].self) { group in
            for country in countries {
                group.addTask { await self.fetchStations(country: country, tag: nil, limit: limitPerCountry, codec: codec, minBitrate: minBitrate) }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return deduplicate(all, limit: 50)
    }

    private func fetchGenreFromCountries(genre: String, limitPerCountry: Int) async -> [RadioStation] {
        let codec = codecFilter()
        let minBitrate = AppSettings.shared.minBitrate
        var all: [RadioStation] = []
        await withTaskGroup(of: [RadioStation].self) { group in
            for country in countries {
                group.addTask { await self.fetchStations(country: country, tag: genre, limit: limitPerCountry, codec: codec, minBitrate: minBitrate) }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return deduplicate(all, limit: 30)
    }

    /// Map the Settings codec preference to a Radio Browser API query value.
    /// Returns `nil` when the user picked "Any" so we don't constrain the filter.
    private func codecFilter() -> String? {
        let choice = AppSettings.shared.preferredCodec
        return (choice == "Any") ? nil : choice
    }

    nonisolated private func fetchStations(country: String, tag: String?, limit: Int, codec: String?, minBitrate: Int) async -> [RadioStation] {
        var urlStr = "\(baseURL)/stations/search?limit=\(limit)&hidebroken=true&order=votes&reverse=true&bitrateMin=\(minBitrate)&countrycode=\(country)"
        if let codec = codec, !codec.isEmpty {
            urlStr += "&codec=\(codec)"
        }
        if let tag = tag {
            let enc = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
            urlStr += "&tag=\(enc)"
        }
        guard let url = URL(string: urlStr) else {
            print("[API] Invalid URL: \(urlStr)")
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("RadioVisualizerApp/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[API] HTTP \(http.statusCode) for \(urlStr)")
                return []
            }
            let stations = try JSONDecoder().decode([RadioStation].self, from: data)
            print("[API] Fetched \(stations.count) stations (country=\(country) tag=\(tag ?? "none"))")
            return stations
        } catch {
            print("[API] Fetch failed (country=\(country) tag=\(tag ?? "none")): \(error.localizedDescription)")
            return []
        }
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
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        isSearchLoading = false
        searchNotice = nil
    }

    func toggleFavorite() {
        let stations = filteredStations
        guard selectedStationIndex < stations.count else { return }
        let station = stations[selectedStationIndex]
        if localFavorites.contains(station.id) {
            favoriteStations.removeAll { $0.id == station.id }
        } else {
            favoriteStations.append(station)
        }
        saveFavorites()
    }

    func addFavorite(_ station: RadioStation) {
        guard !localFavorites.contains(station.id) else { return }
        favoriteStations.append(station)
        saveFavorites()
    }

    func removeFavorite(_ station: RadioStation) {
        favoriteStations.removeAll { $0.id == station.id }
        saveFavorites()
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoriteStations) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    func addRecent(_ station: RadioStation) {
        recentStations.removeAll { $0.id == station.id }
        recentStations.insert(station, at: 0)
        let cap = max(1, AppSettings.shared.maxRecents)
        if recentStations.count > cap {
            recentStations = Array(recentStations.prefix(cap))
        }
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentStations) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
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
    /// Called on the main thread when a stream error occurs (not on deliberate stop/cancel).
    var onError: ((String) -> Void)?

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

    /// Debug logging flag — FFT/decode diagnostics. Disabled in Release builds.
    #if DEBUG
    var debugLogging = true
    #else
    var debugLogging = false
    #endif
    private var fftCallCount = 0
    private var fftLastLogTime = Date()
    private var decodeCallCount = 0
    private var decodeLastLogTime = Date()
    /// Tracks whether we've received the first data chunk from the current stream
    private var firstDataReceived = false

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
        print("[STREAM] play() → \(url.absoluteString)")
        stopStream()  // increments generation, cancels session, drains queue
        prebufferDone = false
        bytesBuffered = 0
        firstDataReceived = false

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
            print("[STREAM] ERROR: AudioFileStreamOpen failed with OSStatus \(st)")
            return
        }
        print("[STREAM] AudioFileStreamOpen OK (gen=\(generation))")

        var cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task    = session?.dataTask(with: url)
        task?.resume()
        print("[STREAM] URLSession task started")
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
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            print("[STREAM] Non-HTTP response — allowing data through")
            completionHandler(.allow)
            return
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        print("[STREAM] HTTP \(http.statusCode) | Content-Type: \(contentType) | URL: \(http.url?.absoluteString ?? "?")")

        if http.statusCode >= 400 {
            let msg = "Station unreachable (HTTP \(http.statusCode))"
            print("[STREAM] ERROR: \(msg)")
            completionHandler(.cancel)
            DispatchQueue.main.async { self.onError?(msg) }
            return
        }

        // Warn if the server is returning a playlist instead of raw audio
        let lct = contentType.lowercased()
        if lct.contains("mpegurl") || lct.contains("x-scpls") || lct.contains("x-pls") || lct.contains("playlist") {
            print("[STREAM] WARNING: Content-Type '\(contentType)' looks like a playlist file, not a raw audio stream. The station URL likely needs to be the direct stream URL.")
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if !firstDataReceived {
            firstDataReceived = true
            print("[STREAM] First data chunk received (\(data.count) bytes)")
        }
        guard let stream = fileStream else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            AudioFileStreamParseBytes(stream, UInt32(data.count), base, [])
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let dest = request.url?.absoluteString ?? "?"
        print("[STREAM] Redirect → \(dest)")
        // Reject redirects to localhost — the stream is offline or geo-blocked
        if let host = request.url?.host, host == "127.0.0.1" || host == "localhost" {
            print("[STREAM] ERROR: Redirect to localhost blocked — stream is offline or geo-restricted")
            completionHandler(nil)
            DispatchQueue.main.async {
                self.onError?("Stream unavailable — the station may be offline or geo-restricted.")
            }
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let e = error as NSError? {
            if e.code == NSURLErrorCancelled {
                print("[STREAM] Stream cancelled (expected on stop/switch)")
            } else {
                let url = task.originalRequest?.url?.absoluteString ?? "unknown URL"
                print("[STREAM] ERROR: Stream failed for \(url)")
                print("[STREAM]   → \(e.localizedDescription)")
                print("[STREAM]   → domain=\(e.domain) code=\(e.code)")
                let msg: String
                if e.domain == NSURLErrorDomain && e.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                    print("[STREAM]   → ATS BLOCKED: This is an HTTP (non-HTTPS) stream. Add NSAllowsArbitraryLoads to Info.plist to allow plain HTTP streams.")
                    msg = e.localizedDescription
                } else if e.domain == NSURLErrorDomain && e.code == NSURLErrorCannotConnectToHost {
                    print("[STREAM]   → Connection refused — stream is offline or geo-restricted")
                    msg = "Stream unavailable — the station may be offline or geo-restricted."
                } else {
                    msg = e.localizedDescription
                }
                DispatchQueue.main.async { self.onError?(msg) }
            }
        } else {
            print("[STREAM] Stream ended (server closed connection — normal for some stations)")
        }
    }

    private func onProperty(stream: AudioFileStreamID, id: AudioFileStreamPropertyID) {
        guard generation == activeGeneration else { return }
        switch id {
        case kAudioFileStreamProperty_DataFormat:
            var sz   = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var asbd = AudioStreamBasicDescription()
            guard AudioFileStreamGetProperty(stream, id, &sz, &asbd) == noErr else {
                print("[STREAM] ERROR: Failed to read DataFormat property")
                return
            }
            var mAsbd = asbd
            sourceFormat = AVAudioFormat(streamDescription: &mAsbd)
            if let src = sourceFormat {
                converter = AVAudioConverter(from: src, to: destFormat)
                let sr = src.sampleRate
                let ch = src.channelCount
                let fmt = src.streamDescription.pointee
                print("[STREAM] Audio format detected: \(Int(sr)) Hz, \(ch) ch, formatID=\(String(format: "%c%c%c%c", (fmt.mFormatID >> 24) & 0xFF, (fmt.mFormatID >> 16) & 0xFF, (fmt.mFormatID >> 8) & 0xFF, fmt.mFormatID & 0xFF))")
                if converter == nil {
                    print("[STREAM] ERROR: AVAudioConverter creation failed — format may be unsupported")
                } else {
                    print("[STREAM] AVAudioConverter ready")
                }
            } else {
                print("[STREAM] ERROR: Could not create AVAudioFormat from stream descriptor")
            }

        case kAudioFileStreamProperty_PacketSizeUpperBound,
             kAudioFileStreamProperty_MaximumPacketSize:
            var sz  = UInt32(MemoryLayout<UInt32>.size)
            var val = UInt32(0)
            AudioFileStreamGetProperty(stream, id, &sz, &val)
            if val > 0 {
                maxPktSize = Int(val)
                print("[STREAM] Max packet size: \(val) bytes")
            }

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
            print("[STREAM] Prebuffer satisfied (\(total) bytes) — starting decode/playback")
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
        if result == .error || out.frameLength == 0 {
            if let e = error {
                print("[STREAM] Decode error: \(e.localizedDescription) (domain=\(e.domain) code=\(e.code))")
            } else if out.frameLength == 0 {
                print("[STREAM] Decode produced 0 frames (no audio output for this batch)")
            }
        } else {
            playerNode.scheduleBuffer(out)

            // Debug: log decode cadence
            if debugLogging {
                decodeCallCount += 1
                let now = Date()
                let dt = now.timeIntervalSince(decodeLastLogTime)
                if dt >= 1.0 {
                    print("[DECODE] \(decodeCallCount) calls/s, batch=\(batch.count) pkts, frames=\(out.frameLength)")
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
                print("[FFT] \(String(format: "%.0f", rate)) Hz  bands: [\(bandStr)]")
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
    /// Non-nil when the current stream hit a connection/playback error.
    @Published var streamError: String?

    private let streamEngine = StreamAudioEngine()
    private var triedFallbackURL = false
    /// Scheduled auto-dismiss for the current streamError banner — replaced when a
    /// new error arrives so the timer always reflects the latest message.
    private var errorDismissWork: DispatchWorkItem?
    /// How long a transient error banner is shown before self-dismissing.
    /// HIG: non-intrusive "toast" behavior rather than modal alert.
    private let errorAutoDismissSeconds: TimeInterval = 5.0

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
        streamEngine.onError = { [weak self] message in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // If url_resolved failed and the raw url differs, try it once as a fallback
                if let station = self.currentStation,
                   !self.triedFallbackURL,
                   station.urlResolved != station.url,
                   !station.url.isEmpty,
                   let fallbackURL = URL(string: station.url) {
                    self.triedFallbackURL = true
                    print("[PLAY] url_resolved failed — retrying with raw url: \(station.url)")
                    self.streamEngine.play(url: fallbackURL)
                } else {
                    self.presentStreamError(message)
                }
            }
        }
    }

    /// Show a non-intrusive error toast and schedule its auto-dismissal.
    /// Always replaces any existing banner so the latest message wins.
    private func presentStreamError(_ message: String) {
        streamError = message
        errorDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Only clear if the user hasn't already resolved it (still the same message).
            guard let self = self, self.streamError == message else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.streamError = nil
            }
        }
        errorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + errorAutoDismissSeconds, execute: work)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: Radio stream

    func playStation(_ station: RadioStation) {
        stopFilePlayback()
        triedFallbackURL = false
        let urlString = station.streamURL
        guard let url = URL(string: urlString) else {
            print("[PLAY] Invalid URL for '\(station.name)': \(urlString)")
            DispatchQueue.main.async { self.fileName = "Invalid URL" }
            return
        }
        print("[PLAY] '\(station.name)' | codec=\(station.codec) bitrate=\(station.bitrate)k")
        print("[PLAY] stream URL: \(urlString)")
        if station.url != urlString {
            print("[PLAY] (raw url was: \(station.url))")
        }
        streamEngine.play(url: url)
        errorDismissWork?.cancel()
        DispatchQueue.main.async {
            self.isPlaying      = true
            self.isPaused       = false
            self.streamError    = nil   // clear previous error
            self.currentStation = station
            self.fileName       = station.name
        }
    }

    func togglePause() {
        guard isPlaying else { return }
        if isPaused {
            // Resume — replay current station (reset error + fallback flag)
            if let station = currentStation, let url = URL(string: station.streamURL) {
                triedFallbackURL = false
                streamEngine.play(url: url)
            }
            DispatchQueue.main.async {
                self.isPaused    = false
                self.streamError = nil
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
    /// Called on scroll wheel / trackpad scroll.  Return true to consume.
    /// Receives the vertical scrolling delta in points (positive = content
    /// scrolling up = user wants to move DOWN in the list).
    var onScrollEvent: ((NSEvent) -> Bool)?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    func install() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.onKeyEvent?(event) == true {
                return nil // consumed
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            if self?.onScrollEvent?(event) == true {
                return nil // consumed
            }
            return event
        }
    }

    func uninstall() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    deinit {
        uninstall()
    }
}

// MARK: - Responder Zone (central keyboard routing coordinator)

/// Tracks which UI "zone" currently owns keyboard responder priority.
/// Computed from existing state in ContentView — no separate @State needed.
enum ResponderZone: Equatable {
    case home           // Favorites / Recents panel (main widget)
    case browse         // All Stations list (no search bar open)
    case search         // All Stations search bar is receiving input
    case contextMenu    // Station context popup is open
    case confirmDelete  // Destructive-action confirmation sheet is open
    case onboarding     // First-run / on-demand keyboard shortcut overlay
}

// MARK: - Thin Divider (matches Figma)

struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(height: 1)
    }
}

// MARK: - Shake Effect (for invalid-action feedback)

/// Horizontal shake driven by an animatable counter.  Increment the counter to
/// trigger a damped-sinusoid oscillation, mimicking macOS password-field rejection
/// feedback.  Pairs with NSHapticFeedbackManager for a tactile "thunk."
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 6
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

extension View {
    /// Apply a one-shot shake animation, re-triggered every time `trigger` increments.
    /// Wrap the caller's mutation in `withAnimation(.linear(duration: ~0.35))` for the
    /// classic macOS rejection wobble.
    func shake(trigger: Int) -> some View {
        modifier(ShakeEffect(animatableData: CGFloat(trigger)))
    }
}

/// Fires a short error haptic on the system feedback manager (trackpad "bump").
@inline(__always) func fireInvalidActionHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
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
        // Hidden text anchors the height to a single line; GeometryReader overlay
        // fills that same height for width measurement without expanding vertically.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
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
            }
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
    var isFavorite: Bool = false
    let terminalFont: Font
    var onPlay: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var isHovered: Bool = false

    private var isSelected: Bool { index == selectedIndex }
    private var isPlaying: Bool {
        audio.currentStation?.id == station.id && audio.isPlaying && !audio.isPaused
    }

    private let pushSpring = Animation.interpolatingSpring(stiffness: 280, damping: 28)
    private let squishSpring = Animation.interpolatingSpring(stiffness: 600, damping: 40)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Chevron — slides in and pushes the text right
            Text(">")
                .font(terminalFont)
                .foregroundColor(.white)
                .opacity(isSelected ? 1 : 0)
                .frame(width: isSelected ? 10 : 0, alignment: .leading)
                .clipped()
                .animation(pushSpring, value: isSelected)

            // Icons + station name (fixed) — metadata scrolls to the right
            HStack(spacing: 4) {
                if isFavorite {
                    FavoriteStarShape()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                }
                if isPlaying {
                    PlayTriangle()
                        .fill(Color(red: 0.98, green: 0.25, blue: 0.65))
                        .frame(width: 7, height: 8)
                }

                Text(station.name)
                    .font(terminalFont)
                    .foregroundColor(isPlaying ? Color(red: 0.98, green: 0.25, blue: 0.65) : .white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(0)
            .animation(pushSpring, value: isSelected)
            .animation(.easeOut(duration: 0.15), value: isPlaying)

            let metaStr = station.metadataDisplayString
            if !metaStr.isEmpty {
                Spacer(minLength: 8)
                MarqueeText(
                    text: metaStr,
                    font: terminalFont,
                    color: Color.white.opacity(0.4),
                    isActive: isSelected,
                    speed: 30,
                    startDelay: 1.0,
                    cycleDelay: 1.0
                )
                .frame(minWidth: 60, alignment: .leading)
                .layoutPriority(1)
                .animation(pushSpring, value: isSelected)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            scale = 0.97
            selectedIndex = index
            audio.playStation(station)
            onPlay?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(squishSpring) { scale = 1.0 }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(rowTint))
                .animation(.easeOut(duration: 0.12), value: isSelected)
                .animation(.easeOut(duration: 0.08), value: isHovered)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.name + (isFavorite ? ", favorite" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isPlaying ? "Now playing" : "Press Enter to play")
    }

    /// Selection wins over hover; hover is a subtle hint.
    private var rowTint: Double {
        if isSelected { return 0.18 }
        if isHovered  { return 0.08 }
        return 0
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
    /// Extra transparent padding added below the list so maxOffset is slot-aligned.
    /// Observed by the view to size a Color.clear spacer.
    @Published private(set) var bottomAlignmentPadding: CGFloat = 0

    /// Spring parameters — critically damped (ζ ≥ 1.0, no jiggle per Bible Law #2)
    private let stiffness: CGFloat = 300
    private let damping: CGFloat = 32

    /// Rubber-band parameters (§2A: 15% max stretch, logarithmic resistance)
    private let rubberBandMaxFraction: CGFloat = 0.15

    private var targetOffset: CGFloat = 0
    private var springVelocity: CGFloat = 0
    private var isAnimating = false
    private let linkID = UUID()

    /// Raw measured height of the item VStack (not including the alignment spacer)
    private var rawContentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0
    private var itemCount: Int = 0

    /// Estimated row height (updated dynamically from first measurement)
    var estimatedRowHeight: CGFloat = 32
    /// Spacing between rows
    var rowSpacing: CGFloat = 5

    /// Slot height = rowHeight + spacing, derived from the raw item content only.
    /// slotHeight = (rawContentHeight + 4) / itemCount  because:
    ///   rawContentHeight = itemCount * rowHeight + (itemCount - 1) * 4
    ///                    = itemCount * slotHeight - 4
    private var slotHeight: CGFloat {
        guard itemCount > 0, rawContentHeight > 0 else { return estimatedRowHeight + 4 }
        return (rawContentHeight + 4) / CGFloat(itemCount)
    }

    /// Total content height presented to the physics engine (rows + alignment pad)
    var contentHeight: CGFloat { rawContentHeight + bottomAlignmentPadding }

    /// maxOffset is now always a multiple of slotHeight so every scroll target
    /// lands on an exact row boundary — no top-item pixel clipping ever.
    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    func updateGeometry(contentHeight: CGFloat, viewportHeight: CGFloat, itemCount: Int = 0) {
        self.rawContentHeight = contentHeight
        self.viewportHeight = viewportHeight
        if itemCount > 0 { self.itemCount = itemCount }
        recomputePadding()
    }

    /// Call when item count changes independently (e.g. genre/search switch)
    func updateItemCount(_ count: Int) {
        itemCount = count
        recomputePadding()
    }

    /// Recalculates bottomAlignmentPadding so that maxOffset = ceil(rawMax/slotHeight)*slotHeight.
    /// With this invariant, every retarget() call lands on an exact row boundary.
    private func recomputePadding() {
        let sh = slotHeight
        let rawMax = max(0, rawContentHeight - viewportHeight)
        guard sh > 0, rawMax > 0 else {
            bottomAlignmentPadding = 0
            return
        }
        let rem = rawMax.truncatingRemainder(dividingBy: sh)
        bottomAlignmentPadding = rem > 0 ? sh - rem : 0
    }

    /// Scroll so the selected item is centered in the viewport, snapping to exact
    /// item boundaries.  The offset is always a multiple of slotHeight so no item
    /// is ever pixel-clipped at the top.
    func scrollToIndex(_ index: Int, totalItems: Int) {
        guard totalItems > 0 else { return }

        if itemCount != totalItems {
            itemCount = totalItems
            recomputePadding()
        }

        let sh = slotHeight
        let visibleCount = max(1, Int((viewportHeight + 4) / sh))

        // Center the focused item; push toward the start/end when near boundaries
        let idealFirst = index - visibleCount / 2
        let maxFirstVisible = max(0, Int((maxOffset / sh).rounded()))
        let newFirstVisible = max(0, min(idealFirst, maxFirstVisible))

        let newOffset = min(CGFloat(newFirstVisible) * sh, maxOffset)
        retarget(newOffset)
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
    let index: Int
    @Binding var selectedIndex: Int
    @ObservedObject var audio: AudioManager
    var isFavorite: Bool
    let terminalFont: Font
    var onPlay: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var isHovered: Bool = false

    private var isSelected: Bool { index == selectedIndex }
    private var isPlaying: Bool {
        audio.currentStation?.id == station.id && audio.isPlaying && !audio.isPaused
    }

    private let textColor = Color(red: 0.157, green: 0.157, blue: 0.157) // Dark text for light background
    private let metaColor = Color(red: 0.55, green: 0.55, blue: 0.55) // Grey text
    private let pushSpring = Animation.interpolatingSpring(stiffness: 280, damping: 28)
    private let squishSpring = Animation.interpolatingSpring(stiffness: 600, damping: 40)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Chevron — slides in and pushes the text right
            Text(">")
                .font(terminalFont)
                .foregroundColor(textColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: isSelected ? 10 : 0, alignment: .leading)
                .clipped()
                .animation(pushSpring, value: isSelected)

            // Station name and icons — fixed (no scroll); metadata scrolls to the right
            HStack(spacing: 4) {
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

                Text(station.name)
                    .font(terminalFont)
                    .foregroundColor(isPlaying ? Color(red: 0.98, green: 0.25, blue: 0.65) : textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(0)
            .animation(pushSpring, value: isSelected)

            let metaStr = station.metadataDisplayString
            if !metaStr.isEmpty {
                Spacer(minLength: 8)
                MarqueeText(
                    text: metaStr,
                    font: terminalFont,
                    color: metaColor,
                    isActive: isSelected,
                    speed: 30,
                    startDelay: 1.0,
                    cycleDelay: 1.0
                )
                .frame(minWidth: 60, alignment: .leading)
                .layoutPriority(1)
                .animation(pushSpring, value: isSelected)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            scale = 0.97
            selectedIndex = index
            audio.playStation(station)
            onPlay?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(squishSpring) { scale = 1.0 }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(rowTint))
                .animation(.easeOut(duration: 0.12), value: isSelected)
                .animation(.easeOut(duration: 0.08), value: isHovered)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.name + (isFavorite ? ", favorite" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isPlaying ? "Now playing" : "Press Enter to play")
    }

    private var rowTint: Double {
        if isSelected { return 0.18 }
        if isHovered  { return 0.08 }
        return 0
    }
}

// MARK: - All Stations View

struct AllStationsView: View {
    @ObservedObject var state: AllStationsState
    @ObservedObject var audio: AudioManager
    let terminalFont: Font

    private let bgColor = Color(red: 0.961, green: 0.961, blue: 0.961) // #f5f5f5
    private let textColor = Color(red: 0.157, green: 0.157, blue: 0.157) // #282828
    // Spatial Shift: 300ms Out-Quart
    private let searchSpring = Animation.timingCurve(0.15, 0, 0, 1, duration: 0.3)
    
    @State private var cursorVisible = true
    /// Pulses between high/low opacity while a search is in flight — ties the
    /// network state to the existing motion language rather than adding a
    /// separate spinner chrome.
    @State private var loadingPulse: Bool = false

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
        // Show the spinner for either kind of load (genre prefetch *or* remote
        // search). The search pulse handles the search-specific feedback inside
        // the palette; this surface remains visibly busy until results arrive.
        if state.isLoading || state.isSearchLoading {
            loadingView
        } else if state.filteredStations.isEmpty {
            emptyView
        } else {
            stationList
        }
    }

    private var searchBar: some View {
        HStack(spacing: 2) {
            if !state.searchText.isEmpty {
                Text(state.searchText)
                    .font(terminalFont)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(0)
            }

            // Blinking Line Cursor (Figma 1294:2686 & UX Audit 5B)
            Rectangle()
                .fill(textColor)
                .frame(width: 1, height: 10)
                .opacity(cursorVisible ? 1 : 0)
                .layoutPriority(1)
                .onAppear {
                    cursorVisible = true
                    withAnimation(Animation.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                        cursorVisible = false
                    }
                }
                .onDisappear {
                    withAnimation(.linear(duration: 0)) {
                        cursorVisible = true
                    }
                }

            if state.searchText.isEmpty {
                Text("Name, country, genre…")
                    .font(terminalFont)
                    .foregroundColor(textColor.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        // Pulsing underline = network activity. Stays invisible when idle, fades
        // back to transparent on completion so it shares the established 0.3s
        // Spatial-Shift cadence.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(textColor)
                .frame(height: 1)
                .opacity(state.isSearchLoading ? (loadingPulse ? 0.55 : 0.12) : 0.0)
                .offset(y: 6)
        }
        .onChange(of: state.isSearchLoading) { loading in
            if loading {
                loadingPulse = false
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    loadingPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    loadingPulse = false
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isSearchField)
        .accessibilityLabel("Search stations")
        .accessibilityValue(state.searchText)
        .accessibilityHint("Type name, country, or genre. Down arrow moves to results. Escape clears.")
    }

    private var genreBar: some View {
        HStack(spacing: 12) {
            ForEach(Array(state.genres.enumerated()), id: \.offset) { idx, genre in
                Text(genre)
                    .font(terminalFont)
                    .foregroundColor(textColor)
                    .opacity(idx == state.selectedGenreIndex ? 1.0 : 0.5)
                    .animation(.easeOut(duration: 0.1), value: state.selectedGenreIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard idx != state.selectedGenreIndex else { return }
                        withAnimation(searchSpring) {
                            state.setGenre(to: idx)
                        }
                    }
                    .accessibilityLabel(genre)
                    .accessibilityAddTraits(idx == state.selectedGenreIndex ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            // Native indeterminate progress — respects Dark Mode and Reduce Motion automatically.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(textColor)
            Text("Loading stations…")
                .font(terminalFont)
                .foregroundColor(textColor.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading stations")
    }

    /// Helpful empty state with a clear CTA. Copy adapts depending on whether the
    /// empty list is due to a search filter or a genuinely empty catalog.
    private var emptyView: some View {
        let hasQuery = !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let headline: String = {
            if hasQuery { return state.searchNotice ?? "No stations found" }
            return "No stations available"
        }()
        let subline: String = {
            if hasQuery { return "Press Esc to refine your query" }
            return "Try a different genre with ← →"
        }()
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: hasQuery ? "magnifyingglass" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(textColor.opacity(0.5))
            Text(headline)
                .font(terminalFont)
                .foregroundColor(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
            Text(subline)
                .font(terminalFont)
                .foregroundColor(textColor.opacity(0.5))
                .lineLimit(1)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasQuery ? "\(headline). Press Escape to clear." : "No stations available. Try a different genre.")
    }

    @StateObject private var liquidScroll = LiquidScrollState()

    private var stationList: some View {
        GeometryReader { outerGeo in
            let viewportH = outerGeo.size.height

            // Custom spring-driven scroll — no ScrollView, the VStack moves via offset.
            // Outer VStack: inner item rows + a transparent alignment spacer.
            // The spacer is NOT included in the contentHeight measurement; it only
            // extends the physics content so maxOffset is a multiple of slotHeight,
            // which guarantees the first visible row is never pixel-clipped at the top.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(state.filteredStations.enumerated()), id: \.element.id) { idx, station in
                        AllStationsStationRow(
                            station: station,
                            index: idx,
                            selectedIndex: $state.selectedStationIndex,
                            audio: audio,
                            isFavorite: state.localFavorites.contains(station.id),
                            terminalFont: terminalFont,
                            onPlay: { state.addRecent(station) }
                        )
                    }
                }
                .background(
                    GeometryReader { contentGeo in
                        Color.clear
                            .onAppear {
                                liquidScroll.updateGeometry(
                                    contentHeight: contentGeo.size.height,
                                    viewportHeight: viewportH,
                                    itemCount: state.filteredStations.count
                                )
                            }
                            .onChange(of: contentGeo.size.height) { h in
                                liquidScroll.updateGeometry(
                                    contentHeight: h,
                                    viewportHeight: viewportH,
                                    itemCount: state.filteredStations.count
                                )
                            }
                    }
                )

                // Slot-alignment spacer: makes maxOffset a multiple of slotHeight
                Color.clear.frame(height: liquidScroll.bottomAlignmentPadding)
            }
            .offset(y: -liquidScroll.offset)  // Spring-driven scroll offset
            .frame(width: outerGeo.size.width, height: viewportH, alignment: .topLeading)
            .clipped()  // Clip content outside viewport
            .onChange(of: state.selectedStationIndex) { newIdx in
                liquidScroll.scrollToIndex(
                    newIdx,
                    totalItems: state.filteredStations.count
                )
            }
            .onChange(of: state.filteredStations.count) { count in
                // When stations change (genre switch, search), update count then jump to top
                liquidScroll.updateItemCount(count)
                liquidScroll.jumpToTop()
            }
        }
    }
}

// MARK: - Transport Buttons (press feedback)

struct TransportButton: View {
    let label: String
    let font: Font
    let action: () -> Void
    var a11yLabel: String = ""

    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(font)
            .foregroundColor(.white)
            .opacity(pressed ? 0.5 : 1.0)
            .scaleEffect(pressed ? 0.88 : 1.0, anchor: .center)
            .contentShape(Rectangle())
            .onTapGesture {
                pressed = true
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.interpolatingSpring(stiffness: 600, damping: 30)) {
                        pressed = false
                    }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(a11yLabel.isEmpty ? label : a11yLabel)
    }
}

struct PlayPauseButton: View {
    let isPaused: Bool
    let isPlaying: Bool
    let action: () -> Void

    @State private var pressed = false

    /// When paused (or stopped), show a filled triangle (▶). When actively playing, show a hollow square (■).
    private var showPlayGlyph: Bool { !isPlaying || isPaused }

    var body: some View {
        ZStack {
            if showPlayGlyph {
                PlayTriangle()
                    .fill(Color.white)
                    .frame(width: 9, height: 11)
            } else {
                Rectangle()
                    .stroke(Color.white, lineWidth: 0.5)
                    .frame(width: 11, height: 11)
            }
        }
        .frame(width: 11, height: 11)
        .opacity(pressed ? 0.5 : 1.0)
        .scaleEffect(pressed ? 0.85 : 1.0, anchor: .center)
        .padding(2)
        .contentShape(Rectangle())
        .onTapGesture {
            pressed = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.interpolatingSpring(stiffness: 600, damping: 30)) {
                    pressed = false
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(showPlayGlyph ? "Play" : "Pause")
    }
}

// MARK: - Main Content View (Terminal-Style Figma Design)

struct ContentView: View {
    @StateObject private var audio    = AudioManager()
    @StateObject private var settings = VisualizerSettings()
    @StateObject private var radio    = RadioBrowserService()
    @StateObject private var keyboard = KeyboardEventHandler()
    @StateObject private var allStationsState = AllStationsState()
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var displayAmplitudes: [CGFloat] = Array(repeating: 0, count: 6)
    @State private var selectedIndex: Int = 0
    @State private var showAllStations: Bool = false
    @AppStorage("showRecentsPanel") private var showRecents: Bool = false
    @StateObject private var recentsScroll = LiquidScrollState()
    @StateObject private var favoritesScroll = LiquidScrollState()

    // Context menu overlay state
    @State private var contextMenuStation: RadioStation? = nil
    @State private var contextMenuFocusIndex: Int = 0
    // Destructive-action confirmation state
    @State private var confirmDeleteStation: RadioStation? = nil
    @State private var confirmDeleteFocusIndex: Int = 0  // 0 = Cancel (default), 1 = Remove
    // Shake feedback on invalid actions (HIG: password-field rejection)
    @State private var invalidActionShake: Int = 0

    // Onboarding: shown once on first launch and on-demand via `?`.
    // Bumped storage key whenever the sheet's content changes meaningfully so
    // returning users see the updated shortcut set.
    @AppStorage("hasSeenOnboardingV1") private var hasSeenOnboarding: Bool = false
    @State private var showOnboarding: Bool = false

    /// Computed responder zone — derived from existing state, no extra @State needed.
    private var currentZone: ResponderZone {
        if contextMenuStation != nil { return .contextMenu }
        if confirmDeleteStation != nil { return .confirmDelete }
        if showOnboarding { return .onboarding }
        if showAllStations { return allStationsState.isSearching ? .search : .browse }
        return .home
    }

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
        // ─── Single-widget layout: Now Playing header always on top,
        //     content area cross-fades between visualizer+favorites and All Stations ───
        VStack(spacing: 4) {
            // Now Playing header — always visible at top; fixedSize prevents the
            // GeometryReader inside MarqueeText from inflating the header's height.
            nowPlayingHeader
                .fixedSize(horizontal: false, vertical: true)

            // Content area — in-place cross-fade (Liquid Glass §3 Portals)
            ZStack {
                // ─── Default: Visualizer + Favorites ───
                // When the user disables the visualizer (Settings → Behavior),
                // the Favorites/Recents section absorbs the freed vertical space
                // so the panel stays visually balanced rather than leaving a gap.
                if !showAllStations {
                    VStack(spacing: 4) {
                        if appSettings.showVisualizer {
                            visualizerSection
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            favoritesSection
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            favoritesSection
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .animation(portalCurve, value: appSettings.showVisualizer)
                    .transition(.opacity)
                }

                // ─── All Stations: replaces visualizer + favorites ───
                if showAllStations {
                    AllStationsView(state: allStationsState, audio: audio, terminalFont: terminalFont)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(4)
        .frame(width: Self.widgetWidth, height: Self.widgetHeight)
        .background(outerBG)
        .clipShape(RoundedRectangle(cornerRadius: Self.widgetCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
        .shake(trigger: invalidActionShake)
        .animation(portalCurve, value: showAllStations)
        .fixedSize()
        .overlay(alignment: .bottom) { contextMenuOverlay }
        .overlay { confirmDeleteOverlay }
        .overlay { onboardingOverlay }
        .onReceive(frameTimer) { _ in
            updateVisuals()
        }
        .background(WindowAccessor())
        .onAppear {
            installKeyboard()
            // Expose these to the menu-bar controller, which lives outside the SwiftUI
            // scene and needs a handle to dispatch Play/Pause / Next / Previous.
            AppEnvironment.shared.audio = audio
            AppEnvironment.shared.stations = allStationsState

            // Auto-resume the most-recent station on launch when the user opted in.
            // First recent wins; if absent, fall back to the top favorite.
            if AppSettings.shared.autoResumeOnLaunch, audio.currentStation == nil {
                if let station = allStationsState.recentStations.first
                    ?? allStationsState.favoriteStations.first {
                    audio.playStation(station)
                }
            }

            // First-launch shortcut cheatsheet. `?` re-summons it any time.
            if !hasSeenOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(portalCurve) { showOnboarding = true }
                }
            }
        }
        .onDisappear {
            keyboard.uninstall()
        }
    }

    // MARK: - Now Playing Header (always visible at top — matches Figma 1294:2362 / 1294:2429 TOP)

    private var nowPlayingHeader: some View {
        VStack(spacing: 0) {
            // "Now Playing" label
            HStack {
                Text("Now Playing")
                    .font(terminalFont)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.bottom, 4)

            ThinDivider()

            // Station name + << ■ >> transport controls on a single row
            // (Figma: 1294:2372 / 1294:2427 — stop square 11×11 stroked white)
            HStack(spacing: 8) {
                TransportButton(label: "<<", font: terminalFont, action: { sweepStation(direction: -1) }, a11yLabel: "Previous station")

                let isActive = audio.isPlaying && !audio.isPaused
                let nameText: String = {
                    if let err = audio.streamError { return "⚠ \(err)" }
                    if let station = audio.currentStation { return station.name }
                    if audio.isPlaying && audio.fileName != "No file selected" { return audio.fileName }
                    return "Not Playing"
                }()
                let nameColor: Color = audio.streamError != nil ? Color(red: 1.0, green: 0.45, blue: 0.35) : .white
                MarqueeText(
                    text: nameText,
                    font: terminalFont,
                    color: nameColor,
                    isActive: isActive || audio.streamError != nil,
                    speed: 30,
                    startDelay: 1.5,
                    cycleDelay: 2.0
                )

                PlayPauseButton(isPaused: audio.isPaused, isPlaying: audio.isPlaying, action: { audio.togglePause() })

                TransportButton(label: ">>", font: terminalFont, action: { sweepStation(direction: 1) }, a11yLabel: "Next station")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Visualizer Section (fades out when switching to All Stations)

    private var visualizerSection: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
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
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Favorites / Recents Section

    private var favoritesSection: some View {
        let pushSpring = Animation.interpolatingSpring(stiffness: 280, damping: 28)
        return VStack(spacing: 8) {
            // Header — left/right arrows indicate toggling is available
            HStack(alignment: .firstTextBaseline) {
                Text("<")
                    .font(terminalFont)
                    .foregroundColor(.white.opacity(showRecents ? 1.0 : 0.25))
                    .contentShape(Rectangle())
                    .onTapGesture { if showRecents { toggleFavoritesRecents() } }
                Spacer()
                Text(showRecents ? "Recents" : "Favorites")
                    .font(terminalFont)
                    .foregroundColor(.white)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleFavoritesRecents() }
                Spacer()
                Text(">")
                    .font(terminalFont)
                    .foregroundColor(.white.opacity(showRecents ? 0.25 : 1.0))
                    .contentShape(Rectangle())
                    .onTapGesture { if !showRecents { toggleFavoritesRecents() } }
            }
            .animation(pushSpring, value: showRecents)

            ThinDivider()

            if showRecents {
                recentsContent
            } else {
                favoritesContent()
            }

            ThinDivider()

            allStationsLink(pushSpring: pushSpring)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func favoritesContent() -> some View {
        if allStationsState.favoriteStations.isEmpty {
            VStack {
                Spacer()
                Text("No favorite stations")
                    .font(terminalFont)
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
            .frame(minHeight: 96, maxHeight: appSettings.showVisualizer ? 96 : .infinity)
        } else {
            GeometryReader { outerGeo in
                let viewportH = outerGeo.size.height
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(allStationsState.favoriteStations.enumerated()), id: \.element.id) { idx, station in
                            TerminalStationRow(
                                station: station,
                                index: idx,
                                selectedIndex: $selectedIndex,
                                audio: audio,
                                isFavorite: true,
                                terminalFont: terminalFont,
                                onPlay: { allStationsState.addRecent(station) }
                            )
                        }
                    }
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .onAppear {
                                    favoritesScroll.updateGeometry(
                                        contentHeight: contentGeo.size.height,
                                        viewportHeight: viewportH,
                                        itemCount: allStationsState.favoriteStations.count
                                    )
                                }
                                .onChange(of: contentGeo.size.height) { h in
                                    favoritesScroll.updateGeometry(
                                        contentHeight: h,
                                        viewportHeight: viewportH,
                                        itemCount: allStationsState.favoriteStations.count
                                    )
                                }
                        }
                    )

                    // Slot-alignment spacer: makes maxOffset a multiple of slotHeight
                    Color.clear.frame(height: favoritesScroll.bottomAlignmentPadding)
                }
                .offset(y: -favoritesScroll.offset)
                .frame(width: outerGeo.size.width, height: viewportH, alignment: .topLeading)
                .clipped()
                .onChange(of: selectedIndex) { newIdx in
                    // Skip the virtual "All Stations" link index (rendered outside this scroll region).
                    let count = allStationsState.favoriteStations.count
                    guard count > 0, newIdx < count else { return }
                    favoritesScroll.scrollToIndex(newIdx, totalItems: count)
                }
                .onChange(of: allStationsState.favoriteStations.count) { count in
                    favoritesScroll.updateItemCount(count)
                    favoritesScroll.jumpToTop()
                }
            }
            .frame(minHeight: 96, maxHeight: appSettings.showVisualizer ? 96 : .infinity)
        }
    }

    private func allStationsLink(pushSpring: Animation) -> some View {
        let listCount = showRecents ? allStationsState.recentStations.count : allStationsState.favoriteStations.count
        let isSelected = selectedIndex == listCount

        return HStack(spacing: 0) {
            Text(">")
                .font(terminalFont)
                .foregroundColor(.white)
                .opacity(isSelected ? 1 : 0)
                .frame(width: isSelected ? 10 : 0, alignment: .leading)
                .clipped()
                .animation(pushSpring, value: isSelected)
            Text("All Stations")
                .font(terminalFont)
                .foregroundColor(.white)
                .animation(pushSpring, value: isSelected)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            enterAllStations()
        }
        .accessibilityLabel("All Stations")
        .accessibilityHint("Browse all available stations")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var recentsContent: some View {
        if allStationsState.recentStations.isEmpty {
            VStack {
                Spacer()
                Text("No recent stations")
                    .font(terminalFont)
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
            .frame(minHeight: 96, maxHeight: appSettings.showVisualizer ? 96 : .infinity)
        } else {
            GeometryReader { outerGeo in
                let viewportH = outerGeo.size.height
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(allStationsState.recentStations.enumerated()), id: \.element.id) { idx, station in
                            TerminalStationRow(
                                station: station,
                                index: idx,
                                selectedIndex: $selectedIndex,
                                audio: audio,
                                isFavorite: allStationsState.localFavorites.contains(station.id),
                                terminalFont: terminalFont,
                                onPlay: { allStationsState.addRecent(station) }
                            )
                        }
                    }
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .onAppear {
                                    recentsScroll.updateGeometry(
                                        contentHeight: contentGeo.size.height,
                                        viewportHeight: viewportH,
                                        itemCount: allStationsState.recentStations.count
                                    )
                                }
                                .onChange(of: contentGeo.size.height) { h in
                                    recentsScroll.updateGeometry(
                                        contentHeight: h,
                                        viewportHeight: viewportH,
                                        itemCount: allStationsState.recentStations.count
                                    )
                                }
                        }
                    )

                    // Slot-alignment spacer: makes maxOffset a multiple of slotHeight
                    Color.clear.frame(height: recentsScroll.bottomAlignmentPadding)
                }
                .offset(y: -recentsScroll.offset)
                .frame(width: outerGeo.size.width, height: viewportH, alignment: .topLeading)
                .clipped()
                .onChange(of: selectedIndex) { newIdx in
                    // Skip when focus is on the virtual "All Stations" link.
                    let count = allStationsState.recentStations.count
                    guard count > 0, newIdx < count else { return }
                    recentsScroll.scrollToIndex(newIdx, totalItems: count)
                }
                .onChange(of: allStationsState.recentStations.count) { count in
                    recentsScroll.updateItemCount(count)
                    recentsScroll.jumpToTop()
                }
            }
            .frame(minHeight: 96, maxHeight: appSettings.showVisualizer ? 96 : .infinity)
        }
    }

    // MARK: - Station Row (terminal-style with animated chevron push)
    // Replaced by TerminalStationRow struct below

    // MARK: - Invalid Action Feedback

    /// Trigger a one-shot shake + haptic to indicate an invalid action
    /// (e.g. pressing ↓ at the last row, ← at the leftmost genre).
    private func signalInvalidAction() {
        fireInvalidActionHaptic()
        withAnimation(.linear(duration: 0.35)) {
            invalidActionShake += 1
        }
    }

    // MARK: - Keyboard Handling (Zone-Based Routing)

    private func installKeyboard() {
        keyboard.onKeyEvent = { event in
            // Overlay zones trap all input; derived from state, no extra @State needed.
            switch currentZone {
            case .contextMenu:    return handleContextMenuKey(event)
            case .confirmDelete:  return handleConfirmDeleteKey(event)
            case .onboarding:     return handleOnboardingKey(event)
            case .search:         return handleSearchKey(event)
            case .browse:         return handleAllStationsNavKey(event)
            case .home:           return handleHomeKey(event)
            }
        }
        keyboard.onScrollEvent = { event in
            handleScrollEvent(event)
        }
        keyboard.install()
    }

    // MARK: - Scroll Wheel / Trackpad (zone-routed like keyboard)

    /// Accumulated scroll delta between row steps.  Persisted across events so a slow
    /// two-finger trackpad drag still advances one row at the right moment.
    @State private var scrollAccumulator: CGFloat = 0
    /// Minimum vertical points per row step.  Tuned so a single trackpad "tick" of
    /// inertia scrolling advances ~1 row.
    private static let scrollRowThreshold: CGFloat = 14

    private func handleScrollEvent(_ event: NSEvent) -> Bool {
        // Only route scroll to zones where a list is visible.
        // Modal overlays swallow it; search bar also swallows (consistent with
        // keyboard, which ignores arrow keys while searching).
        switch currentZone {
        case .contextMenu, .confirmDelete, .search:
            return true  // consume so background doesn't scroll behind modal
        case .home, .browse:
            break
        }

        // Natural-direction convention (matches Music.app): finger swipes up on
        // trackpad (positive scrollingDeltaY) → list content scrolls up → focused
        // row moves DOWN (index +1).
        scrollAccumulator -= event.scrollingDeltaY

        var steps = 0
        while scrollAccumulator >= Self.scrollRowThreshold {
            scrollAccumulator -= Self.scrollRowThreshold
            steps += 1
        }
        while scrollAccumulator <= -Self.scrollRowThreshold {
            scrollAccumulator += Self.scrollRowThreshold
            steps -= 1
        }
        // Reset residual at the end of a gesture so we don't drift.
        if event.phase == .ended || event.momentumPhase == .ended {
            scrollAccumulator = 0
        }

        guard steps != 0 else { return true }

        switch currentZone {
        case .browse:
            let last = allStationsState.filteredStations.count - 1
            guard last >= 0 else { return true }
            let next = max(0, min(last, allStationsState.selectedStationIndex + steps))
            allStationsState.selectedStationIndex = next
        case .home:
            let listCount = showRecents ? allStationsState.recentStations.count : allStationsState.favoriteStations.count
            let last = listCount  // Virtual "All Stations" link lives at [listCount]
            guard listCount > 0 else { return true }
            let next = max(0, min(last, selectedIndex + steps))
            selectedIndex = next
        default:
            break
        }
        return true
    }

    // MARK: - Home Panel (Favorites / Recents)

    private func handleHomeKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd   = flags.contains(.command)
        let shift = flags.contains(.shift)

        let list    = showRecents ? allStationsState.recentStations : allStationsState.favoriteStations
        let lastIdx = list.count  // "All Stations" link lives at this virtual index

        switch event.keyCode {
        // ── Core navigation ──────────────────────────────────────────
        case 126:             // ↑ Arrow
            if selectedIndex > 0 { selectedIndex -= 1 } else { signalInvalidAction() }
            return true
        case 125:             // ↓ Arrow
            if selectedIndex < lastIdx { selectedIndex += 1 } else { signalInvalidAction() }
            return true
        case 40 where !cmd:   // k — Vim up
            if selectedIndex > 0 { selectedIndex -= 1 } else { signalInvalidAction() }
            return true
        case 38 where !cmd:   // j — Vim down
            if selectedIndex < lastIdx { selectedIndex += 1 } else { signalInvalidAction() }
            return true
        case 115:             // Home → first item
            selectedIndex = 0
            return true
        case 119:             // End → All Stations link
            selectedIndex = lastIdx
            return true
        case 116:             // Page Up
            selectedIndex = max(0, selectedIndex - 5)
            return true
        case 121:             // Page Down
            selectedIndex = min(lastIdx, selectedIndex + 5)
            return true

        // ── Primary actions ───────────────────────────────────────────
        case 36:              // Enter — play selected or enter All Stations
            if selectedIndex == lastIdx { enterAllStations(); return true }
            if selectedIndex < list.count {
                let s = list[selectedIndex]
                audio.playStation(s)
                allStationsState.addRecent(s)
            }
            return true
        case 49:              // Space — toggle pause/resume (media player convention)
            audio.togglePause()
            return true

        // ── Panel & sweep navigation ──────────────────────────────────
        case 123:             // ← Arrow
            if shift { sweepStation(direction: -1); return true }
            toggleFavoritesRecents()
            return true
        case 124:             // → Arrow
            if shift { sweepStation(direction: 1); return true }
            toggleFavoritesRecents()
            return true

        // ── Hierarchy navigation (Cmd+[ / Cmd+]) ─────────────────────
        case 33 where cmd:    // Cmd+[ — no-op at root; consume to avoid beep
            signalInvalidAction()
            return true
        case 30 where cmd:    // Cmd+] — forward → All Stations
            enterAllStations()
            return true

        // ── Search activation (Cmd+K / Cmd+F / /) ────────────────────
        case 40 where cmd:    // Cmd+K — global command palette
            enterAllStations(); openSearch()
            return true
        case 3 where cmd:     // Cmd+F
            enterAllStations(); openSearch()
            return true
        case 44 where shift:  // ? (Shift+/) — open shortcut cheatsheet
            openOnboarding()
            return true
        case 44 where !cmd:   // /
            enterAllStations(); openSearch()
            return true

        // ── Context menu (M or Shift+F10) ────────────────────────────
        case 46:              // M
            openContextMenu()
            return true
        case 109 where shift: // Shift+F10
            openContextMenu()
            return true

        // ── Destructive action (Cmd+Delete) ──────────────────────────
        case 51 where cmd:    // Cmd+⌫ — remove from Favorites (not Recents)
            guard !showRecents, selectedIndex < allStationsState.favoriteStations.count else {
                signalInvalidAction()
                return true
            }
            confirmDeleteStation = allStationsState.favoriteStations[selectedIndex]
            confirmDeleteFocusIndex = 0  // Default focus: Cancel
            return true

        // ── Utility ───────────────────────────────────────────────────
        case 2: debugPanel.toggle(settings: settings, audio: audio); return true  // D
        case 9: settings.cyclePreset(); return true                               // V
        default: return false
        }
    }

    // MARK: - All Stations Search Bar

    private func handleSearchKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd   = flags.contains(.command)

        switch event.keyCode {
        case 53:              // Escape — clear search and close bar
            withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                allStationsState.isSearching = false
                allStationsState.searchText  = ""
                allStationsState.selectedStationIndex = 0
            }
            return true

        case 125:             // ↓ Arrow — transfer focus to the first result
            withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                allStationsState.isSearching = false  // Hide bar; filter persists via searchText
            }
            allStationsState.selectedStationIndex = 0
            return true

        case 126:             // ↑ Arrow — no-op while typing
            return true

        case 36:              // Enter — play selected, close bar
            let stations = allStationsState.filteredStations
            if allStationsState.selectedStationIndex < stations.count {
                let s = stations[allStationsState.selectedStationIndex]
                audio.playStation(s)
                allStationsState.addRecent(s)
            }
            withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                allStationsState.isSearching = false
            }
            return true

        case 51:              // Backspace
            if !allStationsState.searchText.isEmpty {
                allStationsState.searchText.removeLast()
                allStationsState.selectedStationIndex = 0
            } else {
                withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
                    allStationsState.isSearching = false
                }
            }
            return true

        case 3 where cmd:     // Cmd+F — already searching; no-op
            return true
        case 40 where cmd:    // Cmd+K — already searching; no-op
            return true

        default:
            // Reject modifier combos; accept any printable character (Unicode, emoji, accents).
            // Filtering to printable means: exclude control characters (U+0000–U+001F, U+007F)
            // but allow everything else including CJK, emoji, diacritics.
            guard !cmd else { return false }
            if let raw = event.characters, !raw.isEmpty {
                let chars = raw.filter { ch in
                    ch.unicodeScalars.allSatisfy { scalar in
                        let v = scalar.value
                        return v >= 32 && v != 0x7F
                    }
                }
                if !chars.isEmpty, allStationsState.searchText.count < 256 {
                    let remaining = 256 - allStationsState.searchText.count
                    allStationsState.searchText += String(chars.prefix(remaining))
                    allStationsState.selectedStationIndex = 0
                }
            }
            return true
        }
    }

    // MARK: - All Stations Browse

    private func handleAllStationsNavKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd   = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch event.keyCode {
        // ── Escape: clear filter first, then exit ─────────────────────
        case 53:
            if !allStationsState.searchText.isEmpty {
                allStationsState.searchText = ""
            } else {
                exitAllStations()
            }
            return true

        // ── Core navigation ──────────────────────────────────────────
        case 126:             // ↑ Arrow
            if allStationsState.selectedStationIndex > 0 {
                allStationsState.selectedStationIndex -= 1
            } else {
                signalInvalidAction()
            }
            return true
        case 125:             // ↓ Arrow
            let last = allStationsState.filteredStations.count - 1
            if allStationsState.selectedStationIndex < last {
                allStationsState.selectedStationIndex += 1
            } else {
                signalInvalidAction()
            }
            return true
        case 40 where !cmd:   // k — Vim up
            if allStationsState.selectedStationIndex > 0 {
                allStationsState.selectedStationIndex -= 1
            } else {
                signalInvalidAction()
            }
            return true
        case 38 where !cmd:   // j — Vim down
            let last = allStationsState.filteredStations.count - 1
            if allStationsState.selectedStationIndex < last {
                allStationsState.selectedStationIndex += 1
            } else {
                signalInvalidAction()
            }
            return true
        case 115:             // Home
            allStationsState.selectedStationIndex = 0
            return true
        case 119:             // End
            allStationsState.selectedStationIndex = max(0, allStationsState.filteredStations.count - 1)
            return true
        case 116:             // Page Up
            allStationsState.selectedStationIndex = max(0, allStationsState.selectedStationIndex - 5)
            return true
        case 121:             // Page Down
            let last = max(0, allStationsState.filteredStations.count - 1)
            allStationsState.selectedStationIndex = min(last, allStationsState.selectedStationIndex + 5)
            return true

        // ── Genre navigation ──────────────────────────────────────────
        case 123:             // ← — previous genre or exit
            if allStationsState.selectedGenreIndex > 0 {
                withAnimation(portalCurve) {
                    allStationsState.setGenre(to: allStationsState.selectedGenreIndex - 1)
                }
            } else {
                exitAllStations()
            }
            return true
        case 124:             // → — next genre
            if allStationsState.selectedGenreIndex < allStationsState.genres.count - 1 {
                withAnimation(portalCurve) {
                    allStationsState.setGenre(to: allStationsState.selectedGenreIndex + 1)
                }
            } else {
                signalInvalidAction()
            }
            return true

        // ── Primary actions ───────────────────────────────────────────
        case 36:              // Enter — play selected
            let stations = allStationsState.filteredStations
            if allStationsState.selectedStationIndex < stations.count {
                let s = stations[allStationsState.selectedStationIndex]
                audio.playStation(s)
                allStationsState.addRecent(s)
            }
            return true
        case 49:              // Space — toggle pause/resume
            audio.togglePause()
            return true

        // ── Search activation ─────────────────────────────────────────
        case 1:               // S
            openSearch()
            return true
        case 40 where cmd:    // Cmd+K — global command palette
            openSearch()
            return true
        case 3 where cmd:     // Cmd+F
            openSearch()
            return true
        case 44 where shift:  // ? (Shift+/) — open shortcut cheatsheet
            openOnboarding()
            return true
        case 44 where !cmd:   // /
            openSearch()
            return true

        // ── Hierarchy navigation ──────────────────────────────────────
        case 33 where cmd:    // Cmd+[ — back to home
            exitAllStations()
            return true
        case 30 where cmd:    // Cmd+] — no forward level; consume
            signalInvalidAction()
            return true

        // ── Favorites & context ───────────────────────────────────────
        case 3:               // F — toggle favorite (no Cmd modifier)
            allStationsState.toggleFavorite()
            return true
        case 46:              // M — context menu
            openContextMenu()
            return true
        case 109 where shift: // Shift+F10 — context menu
            openContextMenu()
            return true

        // ── Utility ───────────────────────────────────────────────────
        case 2: debugPanel.toggle(settings: settings, audio: audio); return true  // D
        case 9: settings.cyclePreset(); return true                               // V
        default: return false
        }
    }

    // MARK: - Search / Context / Confirm Helpers

    private func openSearch() {
        withAnimation(.timingCurve(0.15, 0, 0, 1, duration: 0.3)) {
            allStationsState.isSearching = true
        }
        allStationsState.selectedStationIndex = 0
    }

    private func openContextMenu() {
        let station: RadioStation?
        if showAllStations {
            let idx = allStationsState.selectedStationIndex
            let stations = allStationsState.filteredStations
            station = idx < stations.count ? stations[idx] : nil
        } else {
            let list = showRecents ? allStationsState.recentStations : allStationsState.favoriteStations
            station = selectedIndex < list.count ? list[selectedIndex] : nil
        }
        guard let s = station else { return }
        contextMenuStation   = s
        contextMenuFocusIndex = 0
    }

    // MARK: - Context Menu Key Handler (focus trapped inside overlay)

    private func handleContextMenuKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:          // Escape — dismiss
            contextMenuStation = nil
            return true
        case 48:          // Tab — cycle forward through items
            contextMenuFocusIndex = (contextMenuFocusIndex + 1) % 3
            return true
        case 126:         // ↑ — move up
            if contextMenuFocusIndex > 0 { contextMenuFocusIndex -= 1 }
            return true
        case 125:         // ↓ — move down
            if contextMenuFocusIndex < 2 { contextMenuFocusIndex += 1 }
            return true
        case 36, 49:      // Enter / Space — execute
            executeContextMenuAction()
            return true
        default:
            return true   // Trap all other keys (no leakage to background)
        }
    }

    private func executeContextMenuAction() {
        guard let station = contextMenuStation else { return }
        switch contextMenuFocusIndex {
        case 0:  // Play
            audio.playStation(station)
            allStationsState.addRecent(station)
        case 1:  // Toggle Favorite
            if allStationsState.localFavorites.contains(station.id) {
                allStationsState.removeFavorite(station)
            } else {
                allStationsState.addFavorite(station)
            }
        default: break
        }
        contextMenuStation = nil
    }

    // MARK: - Onboarding Key Handler (any key dismisses)

    private func openOnboarding() {
        withAnimation(portalCurve) { showOnboarding = true }
    }

    private func dismissOnboarding() {
        withAnimation(portalCurve) { showOnboarding = false }
        hasSeenOnboarding = true
    }

    private func handleOnboardingKey(_ event: NSEvent) -> Bool {
        // Modifier-only presses (e.g. holding Shift) shouldn't dismiss — only real
        // characters or navigation keys should. keyCodes 54..63 are the modifier keys.
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(event.keyCode) { return true }
        dismissOnboarding()
        return true
    }

    // MARK: - Confirm Delete Key Handler (focus trapped inside dialog)

    private func handleConfirmDeleteKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:          // Escape — cancel (same as "Cancel" button)
            confirmDeleteStation = nil
            return true
        case 48:          // Tab — toggle between Cancel / Remove
            confirmDeleteFocusIndex = confirmDeleteFocusIndex == 0 ? 1 : 0
            return true
        case 126:         // ↑ — focus Cancel
            confirmDeleteFocusIndex = 0
            return true
        case 125:         // ↓ — focus Remove
            confirmDeleteFocusIndex = 1
            return true
        case 36, 49:      // Enter / Space — execute focused button
            if confirmDeleteFocusIndex == 1, let station = confirmDeleteStation {
                allStationsState.removeFavorite(station)
                if selectedIndex >= allStationsState.favoriteStations.count {
                    selectedIndex = max(0, allStationsState.favoriteStations.count - 1)
                }
            }
            confirmDeleteStation = nil
            return true
        default:
            return true   // Trap all keys — modal is fully isolated
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
        // UX Audit 5C: Delay reset so the panel animates out with content intact
        let favCount = allStationsState.favoriteStations.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            allStationsState.reset()
        }
        selectedIndex = favCount
    }

    private func sweepStation(direction: Int) {
        let list = showRecents ? allStationsState.recentStations : allStationsState.favoriteStations
        guard !list.isEmpty else { return }

        // Anchor on whichever index is currently playing (if present in the visible list),
        // otherwise on the currently selected row.
        let startIndex: Int = {
            if let cur = audio.currentStation?.id, let i = list.firstIndex(where: { $0.id == cur }) {
                return i
            }
            return min(max(0, selectedIndex), list.count - 1)
        }()

        var newIndex = startIndex + direction
        if newIndex < 0 { newIndex = list.count - 1 }
        if newIndex >= list.count { newIndex = 0 }

        selectedIndex = newIndex
        audio.playStation(list[newIndex])
        allStationsState.addRecent(list[newIndex])
    }

    /// Toggle between Favorites and Recents panels. Preserves focus on the
    /// "All Stations" link if the user was already parked on it.
    private func toggleFavoritesRecents() {
        let oldCount  = showRecents ? allStationsState.recentStations.count : allStationsState.favoriteStations.count
        let wasOnLink = selectedIndex == oldCount

        withAnimation(portalCurve) { showRecents.toggle() }

        let newCount = showRecents ? allStationsState.recentStations.count : allStationsState.favoriteStations.count
        selectedIndex = wasOnLink ? newCount : 0
        if showRecents { recentsScroll.jumpToTop() } else { favoritesScroll.jumpToTop() }
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

    // MARK: - Context Menu Overlay

    @ViewBuilder
    private var contextMenuOverlay: some View {
        if let station = contextMenuStation {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(station.name)
                        .font(terminalFont)
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    ThinDivider()
                    contextMenuItemView(label: "Play", index: 0)
                    contextMenuItemView(
                        label: allStationsState.localFavorites.contains(station.id)
                            ? "Remove Favorite" : "Add Favorite",
                        index: 1
                    )
                    contextMenuItemView(label: "Close", index: 2)
                }
                .background(Color(red: 0.10, green: 0.10, blue: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: -6)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context menu for \(station.name)")
        }
    }

    private func contextMenuItemView(label: String, index: Int) -> some View {
        HStack {
            Text(label)
                .font(terminalFont)
                .foregroundColor(.white)
            Spacer()
            if index == contextMenuFocusIndex {
                Text(">")
                    .font(terminalFont)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(index == contextMenuFocusIndex ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            contextMenuFocusIndex = index
            if index == 2 { contextMenuStation = nil } else { executeContextMenuAction() }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(index == contextMenuFocusIndex ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Onboarding Overlay (first-launch + `?` cheatsheet)

    @ViewBuilder
    private var onboardingOverlay: some View {
        if showOnboarding {
            ZStack {
                Color.black.opacity(0.7)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissOnboarding() }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Shortcuts")
                            .font(terminalFont)
                            .foregroundColor(.white)
                        Spacer()
                        Text("esc")
                            .font(terminalFont)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    ThinDivider()

                    onboardingGroup("Playback", rows: [
                        ("Space",   "Play / Pause"),
                        ("← →",     "Panel / Genre"),
                        ("⇧ ← →",   "Prev / Next station"),
                    ])
                    onboardingGroup("Navigate", rows: [
                        ("↑ ↓",     "Move selection"),
                        ("↵",       "Play"),
                        ("⌘ [  ⌘ ]", "Home / All Stations"),
                    ])
                    onboardingGroup("Discover", rows: [
                        ("⌘ K  /",  "Search anywhere"),
                        ("F",       "Toggle favorite"),
                        ("M",       "Context menu"),
                    ])
                    onboardingGroup("App", rows: [
                        ("V",       "Visualizer preset"),
                        ("D",       "Tweak panel"),
                        ("?",       "Show this help"),
                    ])

                    ThinDivider()
                    Text("Press any key to dismiss")
                        .font(terminalFont)
                        .foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(panelBG)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 0)
                .padding(.horizontal, 10)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keyboard shortcuts")
        }
    }

    private func onboardingGroup(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(terminalFont)
                .foregroundColor(Color.cyan.opacity(0.75))
            ForEach(rows, id: \.0) { key, desc in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(key)
                        .font(terminalFont)
                        .foregroundColor(.white)
                        .frame(width: 82, alignment: .leading)
                    Text(desc)
                        .font(terminalFont)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Confirm Delete Overlay

    @ViewBuilder
    private var confirmDeleteOverlay: some View {
        if let station = confirmDeleteStation {
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 14) {
                    Text("Remove Station?")
                        .font(terminalFont)
                        .foregroundColor(.white)
                    Text(station.name)
                        .font(terminalFont)
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    HStack(spacing: 20) {
                        deleteConfirmButton("Cancel", isFocused: confirmDeleteFocusIndex == 0) {
                            confirmDeleteStation = nil
                        }
                        deleteConfirmButton("Remove", isFocused: confirmDeleteFocusIndex == 1) {
                            allStationsState.removeFavorite(station)
                            if selectedIndex >= allStationsState.favoriteStations.count {
                                selectedIndex = max(0, allStationsState.favoriteStations.count - 1)
                            }
                            confirmDeleteStation = nil
                        }
                    }
                }
                .padding(20)
                .background(panelBG)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 0)
                .frame(maxWidth: 250)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Confirm remove \(station.name) from favorites")
        }
    }

    private func deleteConfirmButton(_ label: String, isFocused: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(terminalFont)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isFocused ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .accessibilityLabel(label)
            .accessibilityAddTraits(isFocused ? [.isSelected, .isButton] : .isButton)
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

// MARK: - Genre & Country Catalogs

/// A single genre option the user can pin to the tab bar.
/// `displayName` is what shows in the All Stations header; `tag` is the Radio Browser
/// API tag we hit (often lowercase, hyphen-stripped).
struct GenreOption: Identifiable, Hashable, Codable {
    var id: String { tag }
    let tag: String
    let displayName: String

    static let allOptions: [GenreOption] = [
        GenreOption(tag: "news",        displayName: "News"),
        GenreOption(tag: "talk",        displayName: "Talk"),
        GenreOption(tag: "sports",      displayName: "Sports"),
        GenreOption(tag: "jazz",        displayName: "Jazz"),
        GenreOption(tag: "rock",        displayName: "Rock"),
        GenreOption(tag: "pop",         displayName: "Pop"),
        GenreOption(tag: "classical",   displayName: "Classical"),
        GenreOption(tag: "electronic",  displayName: "Electronic"),
        GenreOption(tag: "hiphop",      displayName: "Hip-Hop"),
        GenreOption(tag: "country",     displayName: "Country"),
        GenreOption(tag: "metal",       displayName: "Metal"),
        GenreOption(tag: "reggae",      displayName: "Reggae"),
        GenreOption(tag: "latin",       displayName: "Latin"),
        GenreOption(tag: "blues",       displayName: "Blues"),
        GenreOption(tag: "ambient",     displayName: "Ambient"),
        GenreOption(tag: "folk",        displayName: "Folk"),
        GenreOption(tag: "indie",       displayName: "Indie"),
    ]

    static let defaults: [GenreOption] = [
        allOptions.first { $0.tag == "news" }!,
        allOptions.first { $0.tag == "jazz" }!,
        allOptions.first { $0.tag == "rock" }!,
    ]
}

/// Curated country catalog — ISO-3166-1 alpha-2 codes paired with display names.
/// Used by the Settings panel's country-bias picker. Keeping this narrow avoids a
/// paralyzing 250-entry list; advanced users can still search any country via the
/// global Cmd+K palette.
struct CountryOption: Identifiable, Hashable {
    var id: String { code }
    let code: String
    let name: String

    static let catalog: [CountryOption] = [
        CountryOption(code: "US", name: "United States"),
        CountryOption(code: "GB", name: "United Kingdom"),
        CountryOption(code: "IL", name: "Israel"),
        CountryOption(code: "CA", name: "Canada"),
        CountryOption(code: "FR", name: "France"),
        CountryOption(code: "DE", name: "Germany"),
        CountryOption(code: "IT", name: "Italy"),
        CountryOption(code: "ES", name: "Spain"),
        CountryOption(code: "NL", name: "Netherlands"),
        CountryOption(code: "SE", name: "Sweden"),
        CountryOption(code: "NO", name: "Norway"),
        CountryOption(code: "DK", name: "Denmark"),
        CountryOption(code: "IE", name: "Ireland"),
        CountryOption(code: "PT", name: "Portugal"),
        CountryOption(code: "PL", name: "Poland"),
        CountryOption(code: "GR", name: "Greece"),
        CountryOption(code: "JP", name: "Japan"),
        CountryOption(code: "KR", name: "South Korea"),
        CountryOption(code: "AU", name: "Australia"),
        CountryOption(code: "NZ", name: "New Zealand"),
        CountryOption(code: "BR", name: "Brazil"),
        CountryOption(code: "MX", name: "Mexico"),
        CountryOption(code: "AR", name: "Argentina"),
        CountryOption(code: "IN", name: "India"),
        CountryOption(code: "ZA", name: "South Africa"),
    ]

    static func name(for code: String) -> String {
        catalog.first { $0.code == code }?.name ?? code
    }
}

// MARK: - App Settings

/// User preferences surfaced in the menu-bar Settings panel. Persists via
/// `UserDefaults` as JSON; `@Published` updates fan out to `AllStationsState`,
/// the menu-bar controller, and the Settings UI itself.
final class AppSettings: ObservableObject {
    /// Global shared instance — the menu-bar lives outside the SwiftUI scene and
    /// needs a stable handle. `AllStationsState` also reads this directly to keep
    /// genre tabs + country bias in sync.
    static let shared = AppSettings()

    /// Genre tabs the user has pinned (beyond the always-present "All Stations").
    @Published var enabledGenres: [GenreOption] = GenreOption.defaults {
        didSet { persist() }
    }
    /// ISO country codes used to bias All Stations + per-genre fetches.
    @Published var countryBias: [String] = ["US", "GB", "IL"] {
        didSet { persist() }
    }
    /// Minimum bitrate used when fetching lists. Radio Browser's `bitrateMin`.
    @Published var minBitrate: Int = 96 { didSet { persist() } }
    /// Codec preference: "MP3", "AAC", or "Any".
    @Published var preferredCodec: String = "MP3" { didSet { persist() } }
    /// Cap on the Recents list.
    @Published var maxRecents: Int = 20 { didSet { persist() } }
    /// Whether the menu-bar status item is visible.
    @Published var showMenuBarIcon: Bool = true { didSet { persist() } }
    /// Whether the Dock icon is visible. Toggling this flips the app's activation
    /// policy at runtime (regular ↔ accessory).
    @Published var showDockIcon: Bool = true { didSet { persist() } }
    /// Auto-play the most-recent station on next launch.
    @Published var autoResumeOnLaunch: Bool = false { didSet { persist() } }
    /// Whether the frequency-spectrum visualizer is shown in the main panel.
    /// When off, the Favorites/Recents list expands into the freed space.
    @Published var showVisualizer: Bool = true { didSet { persist() } }

    private struct Payload: Codable {
        var enabledGenres: [GenreOption]
        var countryBias: [String]
        var minBitrate: Int
        var preferredCodec: String
        var maxRecents: Int
        var showMenuBarIcon: Bool
        var showDockIcon: Bool
        var autoResumeOnLaunch: Bool
        var showVisualizer: Bool?
    }

    private static let storageKey = "SwiftRadio.AppSettings.v1"
    private var isLoading = false

    private init() {
        load()
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        isLoading = true
        enabledGenres      = payload.enabledGenres
        countryBias        = payload.countryBias
        minBitrate         = payload.minBitrate
        preferredCodec     = payload.preferredCodec
        maxRecents         = payload.maxRecents
        showMenuBarIcon    = payload.showMenuBarIcon
        showDockIcon       = payload.showDockIcon
        autoResumeOnLaunch = payload.autoResumeOnLaunch
        showVisualizer     = payload.showVisualizer ?? true
        isLoading = false
    }

    private func persist() {
        guard !isLoading else { return }
        let payload = Payload(
            enabledGenres: enabledGenres,
            countryBias: countryBias,
            minBitrate: minBitrate,
            preferredCodec: preferredCodec,
            maxRecents: maxRecents,
            showMenuBarIcon: showMenuBarIcon,
            showDockIcon: showDockIcon,
            autoResumeOnLaunch: autoResumeOnLaunch,
            showVisualizer: showVisualizer
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Toggle membership of a genre in `enabledGenres`, preserving existing order.
    func toggleGenre(_ option: GenreOption) {
        if let idx = enabledGenres.firstIndex(of: option) {
            enabledGenres.remove(at: idx)
        } else {
            enabledGenres.append(option)
        }
    }

    /// Toggle membership of a country in `countryBias`.
    func toggleCountry(_ code: String) {
        if let idx = countryBias.firstIndex(of: code) {
            countryBias.remove(at: idx)
        } else {
            countryBias.append(code)
        }
    }
}

// MARK: - App Environment

/// Weak registry so components living outside the SwiftUI view tree — the menu-bar
/// controller in particular — can reach the active AudioManager / AllStationsState.
/// ContentView registers these on `onAppear`. Accessed only from the main thread.
final class AppEnvironment {
    static let shared = AppEnvironment()
    private init() {}

    weak var audio: AudioManager?
    weak var stations: AllStationsState?
}

// MARK: - Menu-Bar Controller

/// Owns the `NSStatusItem` + its dropdown menu. Actions route through the shared
/// `AppEnvironment` so we don't duplicate state. The menu rebuilds on every open so
/// "Now Playing" reflects the current station title.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var settings: AppSettings?
    private var showWindowAction: (() -> Void)?
    private var openSettingsAction: (() -> Void)?

    func install(settings: AppSettings, showWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.showWindowAction = showWindow
        self.openSettingsAction = openSettings
        refreshVisibility()
    }

    /// Show or hide the status item to match the current `showMenuBarIcon` pref.
    func refreshVisibility() {
        guard let settings = settings else { return }
        if settings.showMenuBarIcon {
            if statusItem == nil { createStatusItem() }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Swift Radio")
            button.image?.isTemplate = true
            button.toolTip = "Swift Radio"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    // NSMenuDelegate — rebuild on open so Now Playing and pause-state are live.
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let env = AppEnvironment.shared
        let nowPlayingTitle: String = {
            if let name = env.audio?.currentStation?.name { return "♪ \(name)" }
            return "Not Playing"
        }()
        let header = NSMenuItem(title: nowPlayingTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let isPlaying = (env.audio?.isPlaying ?? false) && !(env.audio?.isPaused ?? true)
        let playPause = NSMenuItem(
            title: isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause),
            keyEquivalent: " "
        )
        playPause.keyEquivalentModifierMask = []
        playPause.target = self
        playPause.isEnabled = (env.audio?.currentStation != nil) || !(env.audio?.isPlaying ?? false)
        menu.addItem(playPause)

        let prev = NSMenuItem(title: "Previous Station", action: #selector(previousStation), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        prev.target = self
        menu.addItem(prev)

        let next = NSMenuItem(title: "Next Station", action: #selector(nextStation), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        menu.addItem(next)

        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Swift Radio", action: #selector(showMainWindow), keyEquivalent: "0")
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        menu.addItem(show)

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Swift Radio", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func togglePlayPause() {
        guard let audio = AppEnvironment.shared.audio else { return }
        if audio.isPlaying {
            audio.togglePause()
            return
        }
        // Nothing playing yet — kick off the most-recent station if we have one.
        if let station = AppEnvironment.shared.stations?.recentStations.first
            ?? AppEnvironment.shared.stations?.favoriteStations.first {
            audio.playStation(station)
        }
    }

    @objc private func previousStation() { sweep(-1) }
    @objc private func nextStation()     { sweep(1) }

    private func sweep(_ direction: Int) {
        guard let stations = AppEnvironment.shared.stations,
              let audio = AppEnvironment.shared.audio else { return }
        let list = stations.favoriteStations
        guard !list.isEmpty else { return }
        let startIndex: Int = {
            if let cur = audio.currentStation?.id,
               let i = list.firstIndex(where: { $0.id == cur }) { return i }
            return 0
        }()
        var newIndex = startIndex + direction
        if newIndex < 0 { newIndex = list.count - 1 }
        if newIndex >= list.count { newIndex = 0 }
        audio.playStation(list[newIndex])
        stations.addRecent(list[newIndex])
    }

    @objc private func showMainWindow() {
        showWindowAction?()
    }

    @objc private func openSettings() {
        openSettingsAction?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Settings Window Controller

/// Floating settings panel — mirrors `DebugPanelController` so both panels feel
/// consistent. Reuses `AppSettings.shared` as the source of truth.
final class SettingsWindowController {
    private var panel: NSPanel?

    func open() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(settings: AppSettings.shared)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 560)

        let p = NSPanel(
            contentRect: NSRect(x: 240, y: 240, width: 380, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Swift Radio — Settings"
        p.contentView = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header("Genre Tabs")
                Text("Pick the genres shown in the All Stations browser. \"All Stations\" is always the first tab.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                genreGrid

                Divider()

                header("Country Bias")
                Text("The All Stations and genre lists are pooled from these countries, sorted by community votes.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                countryGrid

                Divider()

                header("Playback")
                playbackSection

                Divider()

                header("Behavior")
                behaviorSection
            }
            .padding(18)
        }
        .frame(minWidth: 360, minHeight: 520)
    }

    // MARK: Sections

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }

    private var genreGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(GenreOption.allOptions) { option in
                let on = settings.enabledGenres.contains(option)
                Button(action: { settings.toggleGenre(option) }) {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(on ? .accentColor : .secondary)
                        Text(option.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(on ? 0.18 : 0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var countryGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(CountryOption.catalog) { country in
                let on = settings.countryBias.contains(country.code)
                Button(action: { settings.toggleCountry(country.code) }) {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(on ? .accentColor : .secondary)
                        Text(country.name)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(country.code)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(on ? 0.18 : 0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Minimum bitrate")
                    .font(.system(size: 12))
                Spacer()
                Text("\(settings.minBitrate) kbps")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.minBitrate) },
                    set: { settings.minBitrate = Int($0.rounded()) }
                ),
                in: 64...320, step: 16
            )

            HStack {
                Text("Preferred codec")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: $settings.preferredCodec) {
                    Text("MP3").tag("MP3")
                    Text("AAC").tag("AAC")
                    Text("Any").tag("Any")
                }
                .labelsHidden()
                .frame(width: 100)
            }

            HStack {
                Text("Max Recents")
                    .font(.system(size: 12))
                Spacer()
                Stepper(value: $settings.maxRecents, in: 5...50, step: 5) {
                    Text("\(settings.maxRecents)")
                        .font(.system(size: 12, design: .monospaced))
                }
                .frame(width: 140)
            }
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show visualizer", isOn: $settings.showVisualizer)
                .font(.system(size: 12))
            Toggle("Show menu-bar icon", isOn: $settings.showMenuBarIcon)
                .font(.system(size: 12))
            Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                .font(.system(size: 12))
            Toggle("Auto-resume last station on launch", isOn: $settings.autoResumeOnLaunch)
                .font(.system(size: 12))
        }
    }
}

// MARK: - App Delegate

/// Coordinates the menu-bar status item, Settings panel, and activation-policy
/// changes. Owned via `@NSApplicationDelegateAdaptor` on `AV_TesterApp`.
final class RadioAppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let settingsWindow = SettingsWindowController()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared
        applyActivationPolicy(showDockIcon: settings.showDockIcon)

        menuBar.install(
            settings: settings,
            showWindow: { [weak self] in self?.showMainWindow() },
            openSettings: { [weak self] in self?.settingsWindow.open() }
        )

        // Keep menu-bar visibility + dock icon in sync with Settings toggles.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.menuBar.refreshVisibility()
                    self?.applyActivationPolicy(showDockIcon: settings.showDockIcon)
                }
            }
            .store(in: &cancellables)

        // Listen for Cmd+, / "Settings…" from the main window.
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow.open() }
        }
    }

    /// Hide/show the Dock icon at runtime. `.accessory` keeps the app running
    /// without a Dock tile (menu-bar-only feel); `.regular` restores normal.
    private func applyActivationPolicy(showDockIcon: Bool) {
        let desired: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer a non-panel, non-settings window — our main ContentView scene.
        for window in NSApp.windows {
            if !(window is NSPanel) && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        // Fallback: just front whatever we have.
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App Entry Point

/// Notification fired when the user invokes the standard macOS Settings shortcut (Cmd+,)
/// or chooses the Settings menu item. The AppDelegate listens for this and opens the
/// Settings panel.
extension Notification.Name {
    static let openSettingsRequested = Notification.Name("SwiftRadio.openSettingsRequested")
}

@main
struct AV_TesterApp: App {
    @NSApplicationDelegateAdaptor(RadioAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // HIG: Cmd+, is the universal macOS Settings shortcut. Opens the Settings
            // panel (menu-bar preferences); the in-place Tweak panel is on 'D'.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
