import Testing
import AppKit
import SwiftUI
import CodecCore
@testable import CodecUI

@Suite("Status bar", .serialized)
@MainActor
struct StatusBarTests {
    private func width(of reading: SystemReading) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SystemMeterReadout(reading: reading, theme: .codec))
        return host.fittingSize.width
    }

    private func reading(cpu: Double, memory: Double, down: Double, up: Double) -> SystemReading {
        SystemReading(cpu: cpu, memory: memory, memoryUsed: 1, memoryTotal: 2, downloadRate: down, uploadRate: up)
    }

    /// Regression: changing network rates resized the meters, shifting CPU and MEM sideways.
    @Test func metersKeepTheirWidthWhateverTheValues() {
        let readings = [
            reading(cpu: 0, memory: 0, down: 0, up: 0),
            reading(cpu: 0.07, memory: 0.5, down: 512, up: 3),
            reading(cpu: 1, memory: 1, down: 1_200, up: 999_700),
            reading(cpu: 0.42, memory: 0.99, down: 45_000_000, up: 2_000_000_000),
            reading(cpu: 0.5, memory: 0.31, down: 999.7, up: 9_960),
        ]
        let widths = readings.map(width(of:))
        #expect(widths.allSatisfy { $0 > 0 })
        #expect(Set(widths).count == 1, "widths: \(widths)")
    }
}

@Suite("Prompt sync", .serialized)
@MainActor
struct PromptSyncTests {
    @Test func writesThePromptFileWhenSettingsChange() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let file = try #require(env.environment.shellIntegration?.promptFile)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("your own prompt is in use"))
        env.preferences.prompt.style = .codec
        env.preferences.prompt.symbol = "λ"
        let script = try String(contentsOf: file, encoding: .utf8)
        #expect(script.contains("_codec_prompt_render"))
        #expect(script.contains("λ"))
    }

    @Test func panesPointZshAtThePromptFile() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let file = try #require(env.environment.shellIntegration?.promptFile)
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["CODEC_PROMPT_FILE"] == file.path)
    }
}
