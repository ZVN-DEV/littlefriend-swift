#if canImport(UIKit) && !os(watchOS)
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import LittleFriendReplay

/// Privacy proof for the serializer: known secret text, input values, accessibility labels,
/// native identifiers and image content never appear in an encoded snapshot, for UIKit trees and
/// for SwiftUI through its hosting view.
@MainActor
final class SerializerTests: XCTestCase {
    private let secrets = [
        "MariaOkafor", "hunter2hunter", "typedsecrettext", "A11ySecretLabel",
        "native-id-secret", "BuyNowSecret", "SwiftUISecret", "4111111111111111",
        "chosenoptionsecret", "placeholder-secret",
    ]

    private func encoded(_ snapshot: ReplayCapturedSnapshot) throws -> String {
        try String(decoding: ReplayWire.encoded(snapshot.events), as: UTF8.self)
    }

    private func assertNoSecrets(_ json: String) {
        for secret in secrets {
            XCTAssertFalse(json.contains(secret), "snapshot leaked \(secret)")
        }
    }

    func testUIKitTreeMasksLabelsAndNeverReadsValuesOrIdentifiers() throws {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

        let heading = UILabel(frame: CGRect(x: 16, y: 16, width: 300, height: 24))
        heading.text = "MariaOkafor 4111111111111111"
        heading.accessibilityLabel = "A11ySecretLabel"
        heading.accessibilityIdentifier = "native-id-secret"
        root.addSubview(heading)

        let password = UITextField(frame: CGRect(x: 16, y: 56, width: 300, height: 44))
        password.isSecureTextEntry = true
        password.text = "hunter2hunter"
        password.placeholder = "placeholder-secret"
        root.addSubview(password)

        let note = UITextView(frame: CGRect(x: 16, y: 112, width: 300, height: 80))
        note.text = "typedsecrettext"
        root.addSubview(note)

        let image = UIImageView(frame: CGRect(x: 16, y: 204, width: 80, height: 80))
        image.accessibilityLabel = "A11ySecretLabel"
        root.addSubview(image)

        let toggle = UISwitch(frame: CGRect(x: 16, y: 296, width: 52, height: 32))
        toggle.isOn = true
        root.addSubview(toggle)

        let segments = UISegmentedControl(items: ["chosenoptionsecret", "other"])
        segments.frame = CGRect(x: 16, y: 340, width: 220, height: 32)
        segments.selectedSegmentIndex = 0
        root.addSubview(segments)

        let button = UIButton(frame: CGRect(x: 16, y: 384, width: 160, height: 44))
        button.setTitle("BuyNowSecret", for: .normal)
        root.addSubview(button)

        let snapshot = ReplaySerializer.snapshot(root: root, route: "/home", timestamp: testTimestamp)
        let json = try encoded(snapshot)
        assertNoSecrets(json)
        // The label's masked shape is present: layout survives, the words do not.
        XCTAssertTrue(json.contains("███████████"))
        XCTAssertEqual(snapshot.events.count, 2)
        guard case let .meta(_, meta) = snapshot.events[0] else {
            return XCTFail("first event is not Meta")
        }
        XCTAssertEqual(meta.href, "/home")
        XCTAssertEqual(meta.width, 390)
        XCTAssertEqual(meta.height, 844)
        XCTAssertTrue(snapshot.events[1].isFullSnapshot)
        // Every emitted element is a hit target inside the viewport.
        XCTAssertFalse(snapshot.hitTargets.isEmpty)
        XCTAssertTrue(snapshot.hitTargets.allSatisfy {
            $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 390 && $0.y + $0.height <= 844
        })
    }

    func testSwiftUIHostingViewNeverLeaksText() throws {
        let host = UIHostingController(rootView: VStack {
            Text("SwiftUISecret")
            Button("BuyNowSecret") {}
        })
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        root.addSubview(host.view)
        root.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let snapshot = ReplaySerializer.snapshot(root: root, route: "/swiftui", timestamp: testTimestamp)
        assertNoSecrets(try encoded(snapshot))
        XCTAssertEqual(snapshot.events.count, 2)
    }

    func testChunkZeroBuiltFromSerializerOutputHasNoSecrets() throws {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        label.text = "MariaOkafor"
        root.addSubview(label)
        let snapshot = ReplaySerializer.snapshot(root: root, route: "/home", timestamp: testTimestamp)
        let chunk = try ReplayChunkFactory.make(
            core: makeCore(), sessionID: "abcdefghijklmnopqrst", pageID: ReplayID.make(),
            sequence: 0, route: "/home", events: snapshot.events
        )
        assertNoSecrets(String(decoding: chunk.body, as: UTF8.self))
        XCTAssertTrue(chunk.hasSnapshot)
    }
}
#endif
