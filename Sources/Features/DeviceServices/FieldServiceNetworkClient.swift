import CoreLocation
import Foundation

struct FieldWeatherResult: Equatable {
    let temperatureCelsius: Double
    let apparentCelsius: Double
    let windKPH: Double
    let weatherCode: Int
    let observedAt: String
}

struct FieldPlaceResult: Equatable {
    let locality: String
    let region: String
    let country: String
}

struct FieldReleaseResult: Equatable {
    let tag: String
    let name: String
    let publishedAt: String
}

protocol FieldServiceNetworkProviding: AnyObject {
    func weather(at location: CLLocation) async throws -> FieldWeatherResult
    func place(at location: CLLocation) async throws -> FieldPlaceResult
    func latestRelease() async throws -> FieldReleaseResult
    func deliver(_ entry: FieldJournalEntry, to webhook: FieldWebhookConfiguration) async throws
}

enum WebhookURLPolicy {
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.absoluteString.utf8.count <= 512,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !isLocalHost(host) else {
            throw DeviceServiceError.invalidURL
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") ||
            host.hasSuffix(".internal") || host == "::1" || host.hasPrefix("fe80:") ||
            host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }
}

final class FieldServiceNetworkClient: FieldServiceNetworkProviding {
    private let maximumDownloadBytes = 32 * 1024

    func weather(at location: CLLocation) async throws -> FieldWeatherResult {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: Self.coordinateText(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: Self.coordinateText(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components.url else { throw DeviceServiceError.invalidURL }
        var request = baseRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request)
        let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return FieldWeatherResult(
            temperatureCelsius: response.current.temperature,
            apparentCelsius: response.current.apparent,
            windKPH: response.current.wind,
            weatherCode: response.current.code,
            observedAt: response.current.time
        )
    }

    func place(at location: CLLocation) async throws -> FieldPlaceResult {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bigdatacloud.net"
        components.path = "/data/reverse-geocode-client"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: Self.coordinateText(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: Self.coordinateText(location.coordinate.longitude)),
            URLQueryItem(name: "localityLanguage", value: "en"),
        ]
        guard let url = components.url else { throw DeviceServiceError.invalidURL }
        let data = try await fetch(baseRequest(url: url))
        let response = try JSONDecoder().decode(BigDataCloudResponse.self, from: data)
        let locality = response.locality ?? response.city ?? "Unknown"
        let safeLocality = Self.safeResponseText(locality, maximum: 40)
        return FieldPlaceResult(
            locality: safeLocality.isEmpty ? "Unknown" : safeLocality,
            region: Self.safeResponseText(response.region ?? "", maximum: 40),
            country: Self.safeResponseText(response.country ?? response.countryCode ?? "", maximum: 40)
        )
    }

    func latestRelease() async throws -> FieldReleaseResult {
        guard let url = URL(string: "https://api.github.com/repos/squazaryu/tumoflip/releases/latest") else {
            throw DeviceServiceError.invalidURL
        }
        var request = baseRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(SafeHTTPSRequest.githubAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        let data = try await fetch(request)
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        return FieldReleaseResult(
            tag: Self.safeResponseText(response.tag, maximum: 32),
            name: Self.safeResponseText(response.name ?? response.tag, maximum: 48),
            publishedAt: Self.safeResponseText(response.publishedAt ?? "", maximum: 32)
        )
    }

    func deliver(_ entry: FieldJournalEntry, to webhook: FieldWebhookConfiguration) async throws {
        try WebhookURLPolicy.validate(webhook.url)
        var request = baseRequest(url: webhook.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = webhook.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(entry)
        guard let body = request.httpBody, body.count <= 4 * 1024 else {
            throw DeviceServiceError.responseTooLarge
        }
        _ = try await fetch(request, responseLimit: 4 * 1024)
    }

    private func baseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("TumoCompanion", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func fetch(_ request: URLRequest, responseLimit: Int? = nil) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let redirect = FieldServiceRejectRedirectDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DeviceServiceError.network
        }
        let limit = responseLimit ?? maximumDownloadBytes
        var data = Data()
        data.reserveCapacity(min(limit, 8 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw DeviceServiceError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func safeResponseText(_ input: String, maximum: Int) -> String {
        let scalars = input.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7F,
               scalar != ";", scalar != "=" {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(maximum))
    }

    private static func coordinateText(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature: Double
        let apparent: Double
        let code: Int
        let wind: Double

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case apparent = "apparent_temperature"
            case code = "weather_code"
            case wind = "wind_speed_10m"
        }
    }
    let current: Current
}

private struct BigDataCloudResponse: Decodable {
    let locality: String?
    let city: String?
    let region: String?
    let country: String?
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case locality
        case city
        case region = "principalSubdivision"
        case country = "countryName"
        case countryCode
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tag: String
    let name: String?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case name
        case publishedAt = "published_at"
    }
}

private final class FieldServiceRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
