import SwiftUI
import WebKit
import DevHavenCore

extension EnvironmentValues {
    @Entry var workspaceRetainedTabIsVisible = true
}

struct WorkspaceMonacoEditorHighlightPayload: Codable, Equatable {
    var kind: String
    var startLine: Int
    var lineCount: Int
}

struct WorkspaceMonacoEditorInlineHighlightPayload: Codable, Equatable {
    var kind: String
    var lineIndex: Int
    var startColumn: Int
    var length: Int
}

struct WorkspaceMonacoEditorDisplayOptionsPayload: Codable, Equatable {
    var showsLineNumbers: Bool
    var highlightsCurrentLine: Bool
    var usesSoftWraps: Bool
    var showsWhitespaceCharacters: Bool
    var showsRightMargin: Bool
    var rightMarginColumn: Int
}

struct WorkspaceMonacoEditorPayload: Codable, Equatable {
    var text: String
    var language: String
    var theme: String
    var isEditable: Bool
    var displayOptions: WorkspaceMonacoEditorDisplayOptionsPayload
    var highlights: [WorkspaceMonacoEditorHighlightPayload]
    var inlineHighlights: [WorkspaceMonacoEditorInlineHighlightPayload]

    init(
        text: String,
        language: String,
        theme: String,
        isEditable: Bool,
        displayOptions: WorkspaceMonacoEditorDisplayOptionsPayload,
        highlights: [WorkspaceMonacoEditorHighlightPayload] = [],
        inlineHighlights: [WorkspaceMonacoEditorInlineHighlightPayload] = []
    ) {
        self.text = text
        self.language = language
        self.theme = theme
        self.isEditable = isEditable
        self.displayOptions = displayOptions
        self.highlights = highlights
        self.inlineHighlights = inlineHighlights
    }
}

@MainActor
private final class WorkspaceMonacoEditorScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: WorkspaceMonacoEditorBridge?

    init(bridge: WorkspaceMonacoEditorBridge) {
        self.bridge = bridge
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bridge?.handleScriptMessage(message)
    }
}

@MainActor
protocol WorkspaceMonacoWebViewLifecycle: AnyObject {
    var webView: WKWebView { get }

    func activate()
    func tearDown()
}

extension WorkspaceMonacoWebViewLifecycle {
    func setHostVisibility(_ isVisible: Bool) {
        let window = webView.window
        let firstResponderView = window?.firstResponder as? NSView
        let ownsFirstResponder = firstResponderView.map { responderView in
            responderView === webView || responderView.isDescendant(of: webView)
        } ?? false

        webView.isHidden = !isVisible
        if !isVisible, ownsFirstResponder {
            _ = window?.makeFirstResponder(nil)
        }
    }
}

@MainActor
final class WorkspaceMonacoEditorBridge: NSObject, ObservableObject, WorkspaceMonacoWebViewLifecycle {
    private enum Constants {
        static let messageHandlerName = "devhavenMonacoEditor"
    }

    let webView: WKWebView

    private var isActive = false
    private var isReady = false
    private var pendingPayload: WorkspaceMonacoEditorPayload?
    private var renderedPayload: WorkspaceMonacoEditorPayload?
    private var pendingScripts: [String] = []
    private var onContentChanged: ((String) -> Void)?
    private var onSaveRequested: (() -> Void)?

    override init() {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        super.init()
    }

    func activate() {
        guard !isActive else {
            return
        }
        isActive = true
        isReady = false
        renderedPayload = nil

        let messageHandler = WorkspaceMonacoEditorScriptMessageHandler(bridge: self)
        webView.configuration.userContentController.add(
            messageHandler,
            name: Constants.messageHandlerName
        )
        loadShellIfNeeded()
    }

    func tearDown() {
        guard isActive else {
            return
        }
        isActive = false
        isReady = false
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Constants.messageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        pendingPayload = nil
        renderedPayload = nil
        pendingScripts.removeAll(keepingCapacity: false)
        onContentChanged = nil
        onSaveRequested = nil
    }

    func update(
        payload: WorkspaceMonacoEditorPayload,
        onContentChanged: @escaping (String) -> Void,
        onSaveRequested: @escaping () -> Void
    ) {
        activate()
        self.onContentChanged = onContentChanged
        self.onSaveRequested = onSaveRequested
        pendingPayload = payload
        applyPendingPayloadIfNeeded()
    }

    func focusEditor() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.focusEditor?.();")
    }

    func startSearch() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.startSearch?.();")
    }

    func showReplace() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.showReplace?.();")
    }

    func findNext() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.findNext?.();")
    }

    func findPrevious() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.findPrevious?.();")
    }

    func useSelectionForFind() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.useSelectionForFind?.();")
    }

    func closeSearch() {
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.closeSearch?.();")
    }

    func goToLine(_ lineNumber: Int) {
        guard lineNumber > 0 else {
            return
        }
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.goToLine?.(\(lineNumber));")
    }

    func revealLine(_ lineNumber: Int) {
        guard lineNumber > 0 else {
            return
        }
        evaluateWhenReady(script: "window.__devHavenMonacoEditor?.revealLine?.(\(lineNumber));")
    }

    private func loadShellIfNeeded() {
        guard let htmlURL = DevHavenAppResourceLocator.resolveResourceURL(
            subdirectory: "MonacoEditorResources",
            resource: "index",
            withExtension: "html"
        ) else {
            return
        }
        webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent().deletingLastPathComponent()
        )
    }

    private func applyPendingPayloadIfNeeded() {
        guard isReady, let pendingPayload else {
            return
        }
        guard renderedPayload != pendingPayload else {
            return
        }
        renderedPayload = pendingPayload
        guard let payloadJSON = jsonString(pendingPayload) else {
            return
        }
        evaluate(script: "window.__devHavenMonacoEditor?.applyPayload?.(\(payloadJSON));")
    }

    private func evaluate(script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func evaluateWhenReady(script: String) {
        activate()
        guard isReady else {
            pendingScripts.append(script)
            return
        }
        evaluate(script: script)
    }

    private func flushPendingScripts() {
        guard isReady, !pendingScripts.isEmpty else {
            return
        }
        let scripts = pendingScripts
        pendingScripts.removeAll(keepingCapacity: true)
        scripts.forEach { evaluate(script: $0) }
    }

    private func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard isActive else {
            return
        }
        guard message.name == Constants.messageHandlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else {
            return
        }

        switch type {
        case "ready":
            isReady = true
            applyPendingPayloadIfNeeded()
            flushPendingScripts()
        case "contentChanged":
            guard let text = body["text"] as? String else {
                return
            }
            onContentChanged?(text)
        case "saveRequested":
            onSaveRequested?()
        default:
            break
        }
    }
}

struct WorkspaceMonacoWebViewHost<Bridge: WorkspaceMonacoWebViewLifecycle>: NSViewRepresentable {
    let bridge: Bridge

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(context: Context) -> WorkspaceEmbeddedWebViewContainer.ContainerView {
        let containerView = WorkspaceEmbeddedWebViewContainer.ContainerView()
        context.coordinator.host(
            bridge,
            in: containerView,
            isVisible: context.environment.workspaceRetainedTabIsVisible
        )
        return containerView
    }

    func updateNSView(
        _ nsView: WorkspaceEmbeddedWebViewContainer.ContainerView,
        context: Context
    ) {
        context.coordinator.host(
            bridge,
            in: nsView,
            isVisible: context.environment.workspaceRetainedTabIsVisible
        )
    }

    static func dismantleNSView(
        _ nsView: WorkspaceEmbeddedWebViewContainer.ContainerView,
        coordinator: Coordinator
    ) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private var bridge: Bridge

        init(bridge: Bridge) {
            self.bridge = bridge
        }

        func host(
            _ nextBridge: Bridge,
            in containerView: WorkspaceEmbeddedWebViewContainer.ContainerView,
            isVisible: Bool
        ) {
            if bridge !== nextBridge {
                tearDown()
                bridge = nextBridge
            }
            bridge.activate()
            containerView.host(bridge.webView)
            bridge.setHostVisibility(isVisible)
        }

        func tearDown() {
            bridge.webView.removeFromSuperview()
            bridge.tearDown()
        }
    }
}

struct WorkspaceMonacoEditorView: View {
    let filePath: String
    @Binding var text: String
    let isEditable: Bool
    let shouldRequestFocus: Bool
    let displayOptions: WorkspaceEditorDisplayOptions
    var highlights: [WorkspaceDiffEditorHighlight] = []
    var inlineHighlights: [WorkspaceDiffEditorInlineHighlight] = []
    let bridge: WorkspaceMonacoEditorBridge
    let onSaveRequested: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WorkspaceMonacoWebViewHost(bridge: bridge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NativeTheme.window)
            .onAppear {
                syncBridge()
                syncFocus()
            }
            .onChange(of: payload) { _, _ in
                syncBridge()
            }
            .onChange(of: shouldRequestFocus) { _, _ in
                syncFocus()
            }
    }

    private var payload: WorkspaceMonacoEditorPayload {
        WorkspaceMonacoEditorPayload(
            text: text,
            language: workspaceMonacoLanguageID(forFilePath: filePath),
            theme: workspaceMonacoThemeName(for: colorScheme),
            isEditable: isEditable,
            displayOptions: WorkspaceMonacoEditorDisplayOptionsPayload(
                showsLineNumbers: displayOptions.showsLineNumbers,
                highlightsCurrentLine: displayOptions.highlightsCurrentLine,
                usesSoftWraps: displayOptions.usesSoftWraps,
                showsWhitespaceCharacters: displayOptions.showsWhitespaceCharacters,
                showsRightMargin: displayOptions.showsRightMargin,
                rightMarginColumn: displayOptions.rightMarginColumn
            ),
            highlights: highlights.map { highlight in
                WorkspaceMonacoEditorHighlightPayload(
                    kind: highlight.kind.rawValue,
                    startLine: highlight.lineRange.startLine,
                    lineCount: highlight.lineRange.lineCount
                )
            },
            inlineHighlights: inlineHighlights.map { highlight in
                WorkspaceMonacoEditorInlineHighlightPayload(
                    kind: highlight.kind.rawValue,
                    lineIndex: highlight.lineIndex,
                    startColumn: highlight.range.startColumn,
                    length: highlight.range.length
                )
            }
        )
    }

    private func syncBridge() {
        bridge.update(
            payload: payload,
            onContentChanged: { nextText in
                text = nextText
            },
            onSaveRequested: onSaveRequested
        )
    }

    private func syncFocus() {
        guard shouldRequestFocus else {
            return
        }
        bridge.focusEditor()
    }
}
