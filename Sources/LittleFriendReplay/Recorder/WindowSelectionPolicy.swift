import Foundation

struct ReplayWindowCandidate: Sendable, Equatable {
    let isKey: Bool
    let isHidden: Bool
    let hasRootViewController: Bool
}

struct ReplaySceneCandidate: Sendable, Equatable {
    let isForegroundActive: Bool
    let windows: [ReplayWindowCandidate]
}

struct ReplayWindowSelection: Sendable, Equatable {
    let sceneIndex: Int
    let windowIndex: Int
}

/// Which window a capture may serialize. The bridge screen event carries no scene identity, so
/// capture is fail-closed whenever the window could be another scene's: exactly one
/// foreground-active scene, and inside it one unambiguous window. Inactive scenes never capture.
enum ReplayWindowSelectionPolicy {
    static func select(scenes: [ReplaySceneCandidate]) -> ReplayWindowSelection? {
        let active = scenes.enumerated().filter { $0.element.isForegroundActive }
        guard active.count == 1, let scene = active.first else { return nil }
        let eligible = scene.element.windows.enumerated()
            .filter { !$0.element.isHidden && $0.element.hasRootViewController }
        let key = eligible.filter { $0.element.isKey }
        if key.count == 1, let only = key.first {
            return ReplayWindowSelection(sceneIndex: scene.offset, windowIndex: only.offset)
        }
        guard key.isEmpty, eligible.count == 1, let only = eligible.first else { return nil }
        return ReplayWindowSelection(sceneIndex: scene.offset, windowIndex: only.offset)
    }
}
