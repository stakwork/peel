import Foundation
import PeelCore
import WebKit

/// The one JavaScript-to-native handler Peel has (docs/app-wallet.md; it
/// reverses phases/05-parity.md's "No `sphinx` bridge in v1", for this
/// alone): strut's UI, the main frame of a page Peel opened, relays an app's
/// `strut/wallet/*` calls to `window.webkit.messageHandlers.strutWallet`
/// (strut's specs/WALLET.md §1.1), and Peel pushes each notification back
/// through strut's UI's `window.strutWallet.notify`. WebKit hands
/// `messageHandlers` to every frame, the app's sandboxed one included, so
/// only the main frame at the origin Peel loaded is answered; nothing else
/// learns more than that the call was not answered.
enum StrutWallet {
    static let handlerName = "strutWallet"
    /// How recent the person's own click or tap must be for a sheet:
    /// "the last few seconds" (WALLET.md §5.4).
    static let gestureWindow: Duration = .seconds(5)
    /// What a frame that is not answered is told, as a rejected promise.
    static let notAnswered = "not answered"

    /// Whether `frame` may be answered: the main frame, at `origin`'s
    /// scheme, host and port (a default port written or not).
    static func mayAnswer(_ frame: WKFrameInfo, origin: URL) -> Bool {
        guard frame.isMainFrame else { return false }
        let seen = frame.securityOrigin
        guard let scheme = origin.scheme?.lowercased(), let host = origin.host()?.lowercased() else { return false }
        return seen.protocol.lowercased() == scheme && seen.host.lowercased() == host
            && port(seen.port == 0 ? nil : seen.port, scheme: scheme) == port(origin.port, scheme: scheme)
    }

    private static func port(_ port: Int?, scheme: String) -> Int? {
        port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    /// What WebKit handed over as JSON: a message is an object of
    /// dictionaries, arrays, numbers, strings and null. Anything else (a
    /// date, NaN, which `JSONSerialization` would raise on) is nil.
    static func json(_ body: Any) -> JSONValue? {
        guard body is NSDictionary, JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The reply as WebKit takes it back to the page's promise.
    static func foundation(_ value: JSONValue) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Pushes a notification (`WalletPush.envelope`) into `webView`'s main
    /// frame while it still shows strut's UI at `origin`. The message goes
    /// as an argument to strut's own function, JSON text that it parses,
    /// never spliced into a script's text, so nothing in it can end a
    /// string or start code.
    @MainActor static func push(_ envelope: JSONValue, into webView: WKWebView, origin: URL) {
        guard let url = webView.url, url.scheme?.lowercased() == origin.scheme?.lowercased(),
              url.host()?.lowercased() == origin.host()?.lowercased(), url.port == origin.port,
              let data = try? JSONEncoder().encode(envelope) else { return }
        let message = String(decoding: data, as: UTF8.self)
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "if (window.strutWallet && typeof window.strutWallet.notify === 'function') window.strutWallet.notify(message);",
                arguments: ["message": message], in: nil, contentWorld: .page
            )
        }
    }
}
