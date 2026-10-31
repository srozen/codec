import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ChannelSettings()
                .tabItem { Label("Channel", systemImage: "antenna.radiowaves.left.and.right") }
            SignalSettings()
                .tabItem { Label("Signals", systemImage: "exclamationmark.bubble") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    private let monospacedFonts: [String] = NSFontManager.shared
        .availableFontFamilies
        .filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 12)], spacing: 12) {
                    ForEach(CodecTheme.all) { theme in
                        ThemeCard(theme: theme, selected: theme.id == prefs.themeID)
                            .onTapGesture { prefs.themeID = theme.id }
                    }
                }
                .padding(.vertical, 4)
                Text(prefs.theme.briefing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Picker("Font", selection: $prefs.fontName) {
                    Text("SF Mono").tag("")
                    Divider()
                    ForEach(monospacedFonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $prefs.fontSize, in: 9...24, step: 1)
                        Text("\(Int(prefs.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Window") {
                Toggle("Blur behind window", isOn: $prefs.blur)
                LabeledContent("Opacity") {
                    Slider(value: $prefs.opacity, in: 0.5...1)
                }
                .disabled(!prefs.blur)
                Toggle("CRT scanlines", isOn: $prefs.scanlines)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemeCard: View {
    let theme: CodecTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.backgroundColor)
                VStack(alignment: .leading, spacing: 6) {
                    SevenSegmentDisplay(text: "140.85", color: theme.accentColor, ghost: 0.12, glow: 0.3)
                        .frame(height: 12)
                    HStack(spacing: 3) {
                        ForEach(1..<7) { i in
                            Circle()
                                .fill(Color(nsColor: theme.ansi[i]))
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text("$ snake --sneak")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.foregroundColor)
                }
                .padding(10)
            }
            .frame(height: 70)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            }
            Text(theme.name)
                .font(.callout.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ChannelSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Shell") {
                TextField("Shell", text: $prefs.shellPath, prompt: Text(defaultShell))
                Toggle("Use Option as Meta key", isOn: $prefs.optionAsMeta)
            }
            Section("When the shell exits") {
                Picker("When the shell exits", selection: $prefs.exitBehavior) {
                    ForEach(ExitBehavior.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section("New channels") {
                Toggle("Play the tuning sequence", isOn: $prefs.tuningSequence)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return "Login shell (\(String(cString: shell)))"
        }
        return "Login shell"
    }
}

private struct SignalSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Bell") {
                Picker("Sound", selection: $prefs.bellSound) {
                    ForEach(BellSound.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show “!” over the cursor", isOn: $prefs.visualAlert)
                HStack {
                    Spacer()
                    Button("Test Alert") { CodecSound.shared.play(.alert) }
                    Button("Test Call") { CodecSound.shared.play(.call) }
                }
                .disabled(prefs.bellSound != .codec)
            }
            Section {
                Toggle("Incoming calls from background channels", isOn: $prefs.incomingCalls)
            } footer: {
                Text("When a channel you're not looking at rings its bell, its tab flashes CALL, the Dock icon is badged and a notification is posted.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
