import XCTest
@testable import LittleFriendReplay

/// The capture window is chosen fail-closed: exactly one foreground-active scene, and inside it
/// one unambiguous window. Anything else captures nothing, so an allowed route can never
/// serialize another window's excluded screen.
final class WindowSelectionPolicyTests: XCTestCase {
    private func scene(_ active: Bool, _ windows: [ReplayWindowCandidate]) -> ReplaySceneCandidate {
        ReplaySceneCandidate(isForegroundActive: active, windows: windows)
    }
    private func win(key: Bool = true, hidden: Bool = false, root: Bool = true) -> ReplayWindowCandidate {
        ReplayWindowCandidate(isKey: key, isHidden: hidden, hasRootViewController: root)
    }

    func testSingleActiveSceneKeyWindowIsChosen() {
        XCTAssertEqual(
            ReplayWindowSelectionPolicy.select(scenes: [scene(true, [win(key: false), win()])]),
            ReplayWindowSelection(sceneIndex: 0, windowIndex: 1)
        )
    }

    func testTwoActiveScenesAreAmbiguousAndFailClosed() {
        XCTAssertNil(ReplayWindowSelectionPolicy.select(scenes: [
            scene(true, [win()]), scene(true, [win()]),
        ]))
    }

    func testInactiveScenesAreIgnored() {
        XCTAssertNil(ReplayWindowSelectionPolicy.select(scenes: [scene(false, [win()])]))
        XCTAssertEqual(
            ReplayWindowSelectionPolicy.select(scenes: [scene(false, [win()]), scene(true, [win()])]),
            ReplayWindowSelection(sceneIndex: 1, windowIndex: 0)
        )
    }

    func testNoKeyWindowNeedsExactlyOneEligibleWindow() {
        XCTAssertEqual(
            ReplayWindowSelectionPolicy.select(scenes: [scene(true, [win(key: false)])]),
            ReplayWindowSelection(sceneIndex: 0, windowIndex: 0)
        )
        XCTAssertNil(ReplayWindowSelectionPolicy.select(scenes: [
            scene(true, [win(key: false), win(key: false)]),
        ]))
        XCTAssertNil(ReplayWindowSelectionPolicy.select(scenes: [
            scene(true, [win(hidden: true), win(root: false)]),
        ]))
    }
}
