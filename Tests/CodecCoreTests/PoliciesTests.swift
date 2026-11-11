import Testing
import Foundation
import Synchronization
@testable import CodecCore

@Suite("ExitBehavior")
struct ExitBehaviorTests {
    @Test(arguments: [(Int32?.some(0), true), (1, true), (127, true), (128, false), (137, false), (nil, false)])
    func closeIfCleanClosesOnlyForNormalExits(code: Int32?, closes: Bool) {
        #expect(ExitBehavior.closeIfClean.closesPane(exitCode: code) == closes)
    }

    @Test(arguments: [Int32?.some(0), 1, 137, nil])
    func alwaysAndNeverIgnoreTheStatus(code: Int32?) {
        #expect(ExitBehavior.alwaysClose.closesPane(exitCode: code))
        #expect(!ExitBehavior.keepOpen.closesPane(exitCode: code))
    }
}

@Suite("AttentionPolicy")
struct AttentionPolicyTests {
    typealias Reaction = AttentionPolicy.Reaction

    @Test(arguments: [
        (BellBehavior.visual, Reaction(indicator: true)),
        (.codecLock, Reaction(indicator: true, sound: .lock)),
        (.system, Reaction(indicator: true, sound: .system)),
        (.silent, Reaction.none),
    ])
    func bellInFront(bell: BellBehavior, expected: Reaction) {
        let policy = AttentionPolicy(bell: bell, notifyInBackground: true)
        #expect(policy.reactionToBell(paneInFront: true) == expected)
    }

    @Test func bellInBackgroundCallsForAttention() {
        let policy = AttentionPolicy(bell: .visual, notifyInBackground: true)
        #expect(policy.reactionToBell(paneInFront: false) == Reaction(markForAttention: true, notify: true, sound: .call))
    }

    @Test func bellInBackgroundOnlyMarksWhenNotificationsAreOff() {
        let policy = AttentionPolicy(bell: .visual, notifyInBackground: false)
        #expect(policy.reactionToBell(paneInFront: false) == Reaction(markForAttention: true))
    }

    @Test func silentBellIsIgnoredEverywhere() {
        let policy = AttentionPolicy(bell: .silent, notifyInBackground: true)
        #expect(policy.reactionToBell(paneInFront: false) == .none)
    }

    @Test func onlyLongCommandsInTheBackgroundNotify() {
        let policy = AttentionPolicy(bell: .visual, notifyInBackground: true, longCommandThreshold: 10)
        #expect(policy.reactionToFinishedCommand(duration: 9.9, paneInFront: false) == .none)
        #expect(policy.reactionToFinishedCommand(duration: 30, paneInFront: true) == .none)
        #expect(policy.reactionToFinishedCommand(duration: 10, paneInFront: false)
                == Reaction(markForAttention: true, notify: true, sound: .call))
    }
}

@Suite("Preferences", .serialized)
@MainActor
struct PreferencesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "codec.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func startsWithFactoryDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.themeID == "codec")
        #expect(preferences.fontSize == 13)
        #expect(preferences.bell == .visual)
        #expect(preferences.exitBehavior == .closeIfClean)
        #expect(preferences.shellIntegration)
        #expect(preferences.showSystemStats)
        #expect(!preferences.scanlines)
        #expect(preferences.commandSeparators)
        #expect(preferences.shadeAlternateCommands)
    }

    @Test func persistsChangesAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Preferences(defaults: defaults)
        first.themeID = "amber"
        first.fontSize = 15
        first.bell = .codecLock
        first.exitBehavior = .keepOpen
        first.shellPath = "/bin/bash"
        let second = Preferences(defaults: defaults)
        #expect(second.themeID == "amber")
        #expect(second.fontSize == 15)
        #expect(second.bell == .codecLock)
        #expect(second.exitBehavior == .keepOpen)
        #expect(second.shellPath == "/bin/bash")
    }

    @Test func repairsInvalidStoredValues() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(500.0, forKey: "fontSize")
        defaults.set("loud", forKey: "bell")
        defaults.set(-2.0, forKey: "opacity")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.fontSize == 13)
        #expect(preferences.bell == .visual)
        #expect(preferences.opacity == 0.9)
    }

    @Test func postsAChangeNotification() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let posted = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: preferences, queue: nil) { _ in
            posted.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        preferences.blur = false
        #expect(posted.withLock { $0 } == 1)
    }

    @Test func resolvesTheShell() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.resolvedShell() == Preferences.loginShell)
        preferences.shellPath = "/bin/sh"
        #expect(preferences.resolvedShell() == "/bin/sh")
        preferences.shellPath = "/no/such/shell"
        #expect(preferences.resolvedShell() == Preferences.loginShell)
    }

    @Test func persistsThePrompt() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Preferences(defaults: defaults)
        #expect(first.prompt == .default)
        first.prompt.style = .shell
        first.prompt.symbol = "λ"
        first.prompt.segments.swapAt(0, 1)
        let second = Preferences(defaults: defaults)
        #expect(second.prompt == first.prompt)
    }

    @Test func buildsTheAttentionPolicy() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.bell = .system
        preferences.notifyInBackground = false
        #expect(preferences.attentionPolicy == AttentionPolicy(bell: .system, notifyInBackground: false, longCommandThreshold: 10))
    }
}
