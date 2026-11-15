import Foundation

/// A failed attempt, classified so the caller knows whether to try again.
struct AttemptFailure: Error {
    let error: GoogleDriveError
    let retryable: Bool
}

enum HTTP {
    /// Sends a request; maps transport errors. Task cancellation surfaces as `CancellationError`.
    static func send(_ request: URLRequest, on session: URLSession, followRedirects: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: followRedirects ? nil : NoRedirects.shared)
        } catch {
            throw transportFailure(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AttemptFailure(error: .unexpectedResponse(status: nil, reason: "not an HTTP response"), retryable: false)
        }
        return (data, http)
    }

    /// `CancellationError` when the task is cancelled; otherwise an `AttemptFailure` that is
    /// retryable for connection problems.
    static func transportFailure(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let failure = error as? AttemptFailure { return failure }
        guard let urlError = error as? URLError else {
            return AttemptFailure(error: .unexpectedResponse(status: nil, reason: String(describing: error)), retryable: false)
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .resourceUnavailable,
             .secureConnectionFailed, .cannotLoadFromNetwork, .backgroundSessionWasDisconnected:
            return AttemptFailure(error: .noNetwork, retryable: true)
        default:
            return AttemptFailure(error: .unexpectedResponse(status: nil, reason: "URLError \(urlError.code.rawValue)"), retryable: false)
        }
    }

    /// Drive's error body: `{"error": {"code", "message", "errors": [{"domain", "reason", "message"}]}}`.
    private struct DriveErrorBody: Decodable {
        struct Inner: Decodable {
            struct Item: Decodable { let reason: String? }
            let errors: [Item]?
            let status: String?
        }
        let error: Inner
    }

    static func driveReason(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(DriveErrorBody.self, from: data) else { return nil }
        return body.error.errors?.first(where: { $0.reason != nil })?.reason ?? body.error.status
    }

    /// Maps a non-success Drive response. 429, 5xx and 403 rate-limit reasons are retryable
    /// (Drive's guidance: exponential backoff); everything else is final.
    static func driveFailure(status: Int, data: Data) -> AttemptFailure {
        let reason = driveReason(in: data)
        switch (status, reason) {
        case (403, "storageQuotaExceeded"):
            return AttemptFailure(error: .storageFull, retryable: false)
        case (403, "rateLimitExceeded"), (403, "userRateLimitExceeded"), (429, _):
            return AttemptFailure(error: .rateLimited, retryable: true)
        case (403, "dailyLimitExceeded"):
            return AttemptFailure(error: .rateLimited, retryable: false)
        case (401, _):
            return AttemptFailure(error: .needsSignInAgain, retryable: false)
        case (404, _):
            return AttemptFailure(error: .notFound, retryable: false)
        case (500...599, _):
            return AttemptFailure(error: .unexpectedResponse(status: status, reason: reason), retryable: true)
        default:
            return AttemptFailure(error: .unexpectedResponse(status: status, reason: reason), retryable: false)
        }
    }

    static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}

/// Returns a redirect response to the caller instead of following it. A resumable upload's
/// "308 Resume Incomplete" shares its status code with HTTP's Permanent Redirect.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension URLRequest {
    init(method: String, url: URL, accessToken: String? = nil) {
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        httpMethod = method
        if let accessToken { setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
    }
}
