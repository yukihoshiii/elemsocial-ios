import SwiftUI
import WebKit

/// hCaptcha challenge rendered in a WKWebView (same sitekey as the web client).
/// The page posts the token back through `webkit.messageHandlers.captcha`.
struct HCaptchaView: UIViewRepresentable {
    let siteKey: String
    @Binding var token: String
    @Binding var isSolved: Bool

    static let elementSiteKey = "29c6b1c2-7e78-43ec-8bf8-5de49c58c54a"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "captcha")

        let resetScript = WKUserScript(source: """
        window.captchaReset = function() {
            if (window.hcaptcha) {
                try { hcaptcha.reset(); } catch (e) {}
            }
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(resetScript)

        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .clear

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.didLoadPage == false {
            context.coordinator.didLoadPage = true
            uiView.loadHTMLString(Self.pageHTML(siteKey: siteKey), baseURL: URL(string: "https://elemsocial.com"))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HCaptchaView
        weak var webView: WKWebView?
        var didLoadPage = false

        init(_ parent: HCaptchaView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "captcha" else { return }
            let body = message.body as? [String: Any] ?? [:]
            let event = body["event"] as? String

            switch event {
            case "verified":
                let token = body["token"] as? String ?? ""
                DispatchQueue.main.async {
                    self.parent.token = token
                    self.parent.isSolved = !token.isEmpty
                }
            case "expired":
                DispatchQueue.main.async {
                    self.parent.token = ""
                    self.parent.isSolved = false
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Captcha challenges open external links — let the system handle them.
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
                return
            }
            decisionHandler(.allow)
        }

        func reset() {
            parent.token = ""
            parent.isSolved = false
            webView?.evaluateJavaScript("window.captchaReset && window.captchaReset();", completionHandler: nil)
        }
    }

    static func pageHTML(siteKey: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
            html, body { margin: 0; padding: 0; background: transparent; display: flex; justify-content: center; }
            #challenge { transform-origin: top left; }
        </style>
        <script>
            function onCaptchaVerified(token) {
                webkit.messageHandlers.captcha.postMessage({ event: 'verified', token: token });
            }
            function onCaptchaExpired() {
                webkit.messageHandlers.captcha.postMessage({ event: 'expired' });
            }
        </script>
        <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
        </head>
        <body>
            <div id="challenge" class="h-captcha"
                 data-sitekey="\(siteKey)"
                 data-callback="onCaptchaVerified"
                 data-expired-callback="onCaptchaExpired"></div>
        </body>
        </html>
        """
    }
}
