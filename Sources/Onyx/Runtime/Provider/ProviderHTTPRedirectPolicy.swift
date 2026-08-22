import Foundation

/// Keeps an otherwise-safe provider request from being silently redirected to
/// a weaker endpoint. URLSession follows redirects by default, so endpoint
/// validation at connection-save time is insufficient on its own.
enum ProviderHTTPRedirectPolicy {
    /// Validates a redirect target before URLSession is allowed to follow it.
    ///
    /// HTTPS is never allowed to downgrade to HTTP, even when the user has
    /// explicitly acknowledged a local HTTP connection. Every provider request
    /// stays on its original origin: an unauthenticated chat body contains the
    /// same private conversation history as an authenticated one and must not
    /// be forwarded to a host the user did not configure.
    static func allowsRedirect(
        from source: URL,
        to destination: URL,
        transportSecurity: ProviderConnectionTransportSecurity,
        hasBearerCredential _: Bool
    ) -> Bool {
        guard let sourceScheme = source.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              ["http", "https"].contains(sourceScheme),
              ["http", "https"].contains(destinationScheme)
        else {
            return false
        }

        // An acknowledgement to use a literal local HTTP endpoint is not an
        // acknowledgement to downgrade a connection that began with TLS.
        guard !(sourceScheme == "https" && destinationScheme == "http") else {
            return false
        }

        // Reuse the durable endpoint policy for every redirect target: no
        // userinfo/query/fragment surprises, and HTTP still has the literal-IP
        // plus acknowledgement restrictions.
        guard (try? ProviderBaseURLNormalizer.normalize(
            destination,
            transportSecurity: transportSecurity
        )) != nil else {
            return false
        }

        guard sameOrigin(source, destination) else {
            return false
        }
        return true
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              lhsScheme == rhsScheme,
              lhsHost == rhsHost
        else {
            return false
        }
        return effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Owns both the URLSession and its redirect delegate. The delegate must stay
/// alive for the entire request; keeping it in this small container makes that
/// lifetime explicit for transport and discovery callers alike.
final class ProviderRedirectProtectedSession: @unchecked Sendable {
    let session: URLSession
    private let redirectDelegate: ProviderHTTPRedirectDelegate

    init(
        wrapping sourceSession: URLSession,
        transportSecurity: ProviderConnectionTransportSecurity,
        hasBearerCredential: Bool
    ) {
        redirectDelegate = ProviderHTTPRedirectDelegate(
            transportSecurity: transportSecurity,
            hasBearerCredential: hasBearerCredential
        )
        session = URLSession(
            configuration: sourceSession.configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }
}

private final class ProviderHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let transportSecurity: ProviderConnectionTransportSecurity
    private let hasBearerCredential: Bool

    init(
        transportSecurity: ProviderConnectionTransportSecurity,
        hasBearerCredential: Bool
    ) {
        self.transportSecurity = transportSecurity
        self.hasBearerCredential = hasBearerCredential
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let source = response.url,
              let destination = request.url,
              ProviderHTTPRedirectPolicy.allowsRedirect(
                  from: source,
                  to: destination,
                  transportSecurity: transportSecurity,
                  hasBearerCredential: hasBearerCredential
              )
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
