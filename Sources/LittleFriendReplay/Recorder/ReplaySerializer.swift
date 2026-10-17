#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// A static masked wireframe of one view tree: generic absolutely positioned boxes in window
/// points, masked label text, and nothing else. Input values, checked and selected state, image
/// content, accessibility labels and native identifiers are never read. Views whose internals can
/// hold a value or a selection are emitted as empty boxes and never entered.
@MainActor
enum ReplaySerializer {
    static let maxNodes = 1500
    static let maxDepth = 64

    /// Meta plus a full snapshot of `root`, with the hit target of every emitted element.
    static func snapshot(root: UIView, route: String, timestamp: Int64) -> ReplayCapturedSnapshot {
        var walk = Walk(root: root)
        let children = walk.children(of: root, depth: 0)
        let width = Double(root.bounds.width)
        let height = Double(root.bounds.height)
        let meta = ReplayEvent.meta(
            timestamp: timestamp,
            data: ReplayMetaData(href: route, width: width, height: height)
        )
        let full = ReplayEvent.fullSnapshot(
            timestamp: timestamp,
            data: ReplayFullSnapshotData(
                node: ReplayWire.document(children: children, viewportHeight: height),
                initialOffset: ReplayOffset(left: 0, top: 0)
            )
        )
        return ReplayCapturedSnapshot(events: [meta, full], hitTargets: walk.hitTargets)
    }

    private struct Walk {
        let root: UIView
        var nextID = ReplayWire.firstNativeNodeID
        var emitted = 0
        var hitTargets: [ReplayHitTarget] = []

        mutating func children(of view: UIView, depth: Int) -> [ReplayNode] {
            view.subviews.compactMap { node(for: $0, depth: depth) }
        }

        mutating func node(for view: UIView, depth: Int) -> ReplayNode? {
            guard !view.isHidden, view.alpha > 0, emitted < ReplaySerializer.maxNodes else { return nil }
            let frame = view.convert(view.bounds, to: root)
            guard frame.width > 0, frame.height > 0, frame.intersects(root.bounds) else { return nil }
            emitted += 1
            let id = nextID
            nextID += 1
            hitTargets.append(ReplayHitTarget(
                nodeID: id, x: Double(frame.minX), y: Double(frame.minY),
                width: Double(frame.width), height: Double(frame.height)
            ))
            let style = "left:\(ReplayWireNumber.string(Double(frame.minX)))px;"
                + "top:\(ReplayWireNumber.string(Double(frame.minY)))px;"
                + "width:\(ReplayWireNumber.string(Double(frame.width)))px;"
                + "height:\(ReplayWireNumber.string(Double(frame.height)))px"

            var childNodes: [ReplayNode] = []
            var className = "lf-n"
            if let label = view as? UILabel {
                className += " lf-t"
                let text = label.text ?? label.attributedText?.string ?? ""
                if !text.isEmpty {
                    emitted += 1
                    let textID = nextID
                    nextID += 1
                    childNodes.append(ReplayNode(type: 3, id: textID, textContent: ReplayPolicy.mask(text)))
                }
            } else if Self.isBoxOnly(view) {
                className += view is UIImageView ? " lf-i" : " lf-b"
            } else if depth < ReplaySerializer.maxDepth {
                if view is UIControl { className += " lf-b" }
                childNodes = children(of: view, depth: depth + 1)
            }
            return ReplayNode(
                type: 2, id: id, tagName: "div",
                attributes: ["class": className, "style": style],
                childNodes: childNodes
            )
        }

        /// Never entered: their subviews can hold an input value, a checked or selected state, a
        /// chosen option, image content or a web page. Each is drawn as an empty box of its size.
        static func isBoxOnly(_ view: UIView) -> Bool {
            switch view {
            case is UITextField, is UITextView, is UISearchBar,
                 is UISwitch, is UISlider, is UISegmentedControl, is UIStepper,
                 is UIPickerView, is UIDatePicker, is UIPageControl,
                 is UIImageView, is UIActivityIndicatorView, is UIProgressView:
                return true
            default:
                return String(describing: type(of: view)) == "WKWebView"
            }
        }
    }
}
#endif
