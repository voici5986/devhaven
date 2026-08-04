import XCTest
@testable import DevHavenApp

final class WorkspaceMarkdownHTMLRendererTests: XCTestCase {
    private static let pixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO9Wn1cAAAAASUVORK5CYII="

    func testAbsoluteImageOutsideBaseDirectoryIsEmbedded() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhaven-markdown-absolute-\(UUID().uuidString)", isDirectory: true)
        let documentRoot = fixtureRoot.appendingPathComponent("docs", isDirectory: true)
        let imageURL = fixtureRoot.appendingPathComponent("shared.png")
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        try XCTUnwrap(Data(base64Encoded: Self.pixelPNGBase64)).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let markdown = WorkspaceMarkdownHTMLRenderer.preprocessMarkdownSource(
            "![shared](\(imageURL.path))",
            baseURL: documentRoot
        )

        XCTAssertTrue(markdown.contains("data:image/png;base64,\(Self.pixelPNGBase64)"))
    }

    func testParentRelativeImageWithinProjectIsEmbedded() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhaven-markdown-parent-\(UUID().uuidString)", isDirectory: true)
        let documentRoot = fixtureRoot.appendingPathComponent("docs", isDirectory: true)
        let assetsRoot = fixtureRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        try XCTUnwrap(Data(base64Encoded: Self.pixelPNGBase64))
            .write(to: assetsRoot.appendingPathComponent("pixel.png"))
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let markdown = WorkspaceMarkdownHTMLRenderer.preprocessMarkdownSource(
            "![pixel](../assets/pixel.png)",
            baseURL: documentRoot
        )

        XCTAssertTrue(markdown.contains("data:image/png;base64,\(Self.pixelPNGBase64)"))
    }

    func testScriptClosingSequenceIsEscapedWithoutChangingRenderedText() throws {
        let source = "before </script> after"
        let literal = WorkspaceMarkdownHTMLRenderer.javaScriptStringLiteral(source)

        XCTAssertFalse(literal.contains("</script>"))
        XCTAssertTrue(literal.contains("\\u003C"))
        XCTAssertTrue(literal.contains("\\u003E"))
        XCTAssertEqual(
            try JSONDecoder().decode(String.self, from: Data(literal.utf8)),
            source
        )
    }
}
