import Testing
import AppKit
import SwiftUI
import CodecCore
@testable import CodecUI

@Suite("Prompt editor", .serialized)
@MainActor
struct PromptEditorTests {
    private func configuration(enabled kinds: [PromptConfiguration.Kind]) -> PromptConfiguration {
        var configuration = PromptConfiguration.default
        configuration.style = .codec
        configuration.segments = configuration.segments.map { segment in
            var segment = segment
            segment.enabled = false
            return segment
        }
        kinds.forEach { configuration.place($0) }
        return configuration
    }

    /// The area's height when its container offers only `offered` points, as a sheet does while sizing itself.
    private func areaHeight(_ kinds: [PromptConfiguration.Kind], width: CGFloat, offered: CGFloat) -> CGFloat {
        _ = NSApplication.shared
        let area = PromptChipArea(configuration: .constant(configuration(enabled: kinds)), theme: .codec,
                                  sample: PromptConfiguration.Sample(), add: { _, _ in })
        return NSHostingController(rootView: area).sizeThatFits(in: CGSize(width: width, height: offered)).height
    }

    /// Regression: offered less height than it needs, the prompt area shrank to its minimum and the
    /// wrapped chips spilled out over the text below.
    @Test(arguments: [360.0, 592.0])
    func promptAreaNeverShrinksBelowItsChips(width: Double) {
        let natural = areaHeight(PromptConfiguration.Kind.allCases, width: width, offered: 10_000)
        let squeezed = areaHeight(PromptConfiguration.Kind.allCases, width: width, offered: 10)
        // Every chip enabled wraps onto at least two rows of 26 pt.
        #expect(natural >= 2 * 26 + 8 + 24)
        #expect(squeezed == natural)
    }

    @Test func promptAreaGrowsWithItsChips() {
        let one = areaHeight([.directory], width: 592, offered: 10)
        let all = areaHeight(PromptConfiguration.Kind.allCases, width: 592, offered: 10)
        #expect(one == 52)
        #expect(all > one + 20)
    }

    /// The sheet sizes itself to fit everything, including every chip.
    @Test func sheetFitsAllChips() {
        _ = NSApplication.shared
        func height(_ kinds: [PromptConfiguration.Kind]) -> CGFloat {
            NSHostingController(rootView: PromptEditorSheet(original: configuration(enabled: kinds), theme: .codec,
                                                            onFinish: { _ in })).view.fittingSize.height
        }
        #expect(height(PromptConfiguration.Kind.allCases) > height([.directory]))
    }
}
