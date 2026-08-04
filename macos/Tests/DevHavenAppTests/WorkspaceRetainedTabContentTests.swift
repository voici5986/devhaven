import XCTest
@testable import DevHavenApp
@testable import DevHavenCore

final class WorkspaceRetainedTabContentTests: XCTestCase {
    func testInitialRetentionMountsOnlyRequiredTabs() {
        let items = [
            makeItem(id: "terminal-1", selection: .terminal("terminal-1")),
            makeItem(id: "editor-1", selection: .editor("editor-1")),
            makeItem(id: "editor-2", selection: .editor("editor-2")),
            makeItem(id: "diff-1", selection: .diff("diff-1")),
        ]
        let input = WorkspaceRetainedTabContentInput(
            items: items,
            selection: .editor("editor-1"),
            splitEditorTabIDs: []
        )
        let cache = WorkspaceRetainedTabContentCache()

        let retainedContent = cache.contentIDs(including: input)

        XCTAssertEqual(retainedContent.editorTabIDs, ["editor-1"])
        XCTAssertTrue(retainedContent.diffTabIDs.isEmpty)
    }

    func testSwitchingTabsRetainsPreviouslyMountedContent() {
        let items = [
            makeItem(id: "editor-1", selection: .editor("editor-1")),
            makeItem(id: "diff-1", selection: .diff("diff-1")),
        ]
        var cache = WorkspaceRetainedTabContentCache()
        cache.sync(WorkspaceRetainedTabContentInput(
            items: items,
            selection: .editor("editor-1"),
            splitEditorTabIDs: []
        ))
        let switchedInput = WorkspaceRetainedTabContentInput(
            items: items,
            selection: .diff("diff-1"),
            splitEditorTabIDs: []
        )
        cache.sync(switchedInput)

        let retainedContent = cache.contentIDs(including: switchedInput)

        XCTAssertEqual(retainedContent.editorTabIDs, ["editor-1"])
        XCTAssertEqual(retainedContent.diffTabIDs, ["diff-1"])
    }

    func testClosingTabImmediatelyDropsRetainedContent() {
        let initialItems = [
            makeItem(id: "editor-1", selection: .editor("editor-1")),
            makeItem(id: "diff-1", selection: .diff("diff-1")),
        ]
        var cache = WorkspaceRetainedTabContentCache()
        cache.sync(WorkspaceRetainedTabContentInput(
            items: initialItems,
            selection: .editor("editor-1"),
            splitEditorTabIDs: []
        ))
        cache.sync(WorkspaceRetainedTabContentInput(
            items: initialItems,
            selection: .diff("diff-1"),
            splitEditorTabIDs: []
        ))

        let closedInput = WorkspaceRetainedTabContentInput(
            items: initialItems.filter { $0.id != "editor-1" },
            selection: .diff("diff-1"),
            splitEditorTabIDs: []
        )
        cache.sync(closedInput)

        let retainedContent = cache.contentIDs(including: closedInput)
        XCTAssertTrue(retainedContent.editorTabIDs.isEmpty)
        XCTAssertEqual(retainedContent.diffTabIDs, ["diff-1"])
    }

    func testRetentionEvictsLeastRecentlyUsedHiddenContentAtCapacity() {
        let items = [
            makeItem(id: "editor-1", selection: .editor("editor-1")),
            makeItem(id: "editor-2", selection: .editor("editor-2")),
            makeItem(id: "diff-1", selection: .diff("diff-1")),
        ]
        var cache = WorkspaceRetainedTabContentCache(capacity: 2)
        [
            WorkspacePresentedTabSelection.editor("editor-1"),
            .editor("editor-2"),
            .diff("diff-1"),
        ].forEach { selection in
            cache.sync(WorkspaceRetainedTabContentInput(
                items: items,
                selection: selection,
                splitEditorTabIDs: []
            ))
        }

        let retainedContent = cache.contentIDs(including: WorkspaceRetainedTabContentInput(
            items: items,
            selection: .diff("diff-1"),
            splitEditorTabIDs: []
        ))
        XCTAssertEqual(retainedContent.editorTabIDs, ["editor-2"])
        XCTAssertEqual(retainedContent.diffTabIDs, ["diff-1"])
    }

    func testSplitRequiresBothVisibleEditorTabs() {
        let items = [
            makeItem(id: "editor-1", selection: .editor("editor-1")),
            makeItem(id: "editor-2", selection: .editor("editor-2")),
        ]
        let input = WorkspaceRetainedTabContentInput(
            items: items,
            selection: .editor("editor-1"),
            splitEditorTabIDs: ["editor-1", "editor-2"]
        )

        let retainedContent = WorkspaceRetainedTabContentCache(capacity: 1).contentIDs(including: input)

        XCTAssertEqual(retainedContent.editorTabIDs, ["editor-2", "editor-1"])
    }

    private func makeItem(
        id: String,
        selection: WorkspacePresentedTabSelection
    ) -> WorkspacePresentedTabItem {
        WorkspacePresentedTabItem(
            id: id,
            title: id,
            selection: selection,
            isSelected: false
        )
    }
}
