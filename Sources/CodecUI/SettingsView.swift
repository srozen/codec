import SwiftUI
import AppKit
import CodecCore

struct SettingsView: View {
    let preferences: Preferences
    let sounds: any SoundPlaying

    var body: some View {
        TabView {
            AppearanceSettings(prefs: preferences)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShellSettings(prefs: preferences)
                .tabItem { Label("Shell", systemImage: "terminal") }
            NotificationSettings(prefs: preferences, sounds: sounds)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences

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
                Text(prefs.theme.summary)
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
                Toggle("Dim inactive split panes", isOn: $prefs.dimInactivePanes)
                Toggle("CRT scanlines", isOn: $prefs.scanlines)
            }

            Section("Status bar") {
                Toggle("Show CPU, memory and network meters", isOn: $prefs.showSystemStats)
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("~/code ").foregroundStyle(Color(nsColor: theme.ansi[4]))
                        Text("main").foregroundStyle(Color(nsColor: theme.ansi[5]))
                    }
                    Text("$ make test").foregroundStyle(theme.foregroundColor)
                    HStack(spacing: 3) {
                        ForEach(1..<7) { i in
                            Circle()
                                .fill(Color(nsColor: theme.ansi[i]))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(10)
            }
            .frame(height: 70)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? theme.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            }
            Text(theme.name)
                .font(.callout.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ShellSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                TextField("Shell", text: $prefs.shellPath, prompt: Text("Login shell (\(Preferences.loginShell))"))
                Toggle("Use Option as Meta key", isOn: $prefs.optionAsMeta)
            }
            Section {
                Toggle("Shell integration", isOn: $prefs.shellIntegration)
            } footer: {
                Text("Lets Codec track commands in zsh: exit status and duration in the status bar, ⌘↑ / ⌘↓ to jump between commands, and notifications when long commands finish. Your own startup files load unchanged. Applies to new panes.")
                    .foregroundStyle(.secondary)
            }
            Section("When the shell exits") {
                Picker("When the shell exits", selection: $prefs.exitBehavior) {
                    ForEach(ExitBehavior.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @ObservedObject var prefs: Preferences
    let sounds: any SoundPlaying

    var body: some View {
        Form {
            Section("Bell") {
                Picker("In the focused pane", selection: $prefs.bell) {
                    ForEach(BellBehavior.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Notify me from background panes", isOn: $prefs.notifyInBackground)
            } footer: {
                Text("A bell in a pane you’re not looking at, or a command that ran for more than \(Int(prefs.longCommandThreshold)) seconds finishing there, posts a notification and marks its tab.")
                    .foregroundStyle(.secondary)
            }
            Section("Codec sounds") {
                Toggle("Play codec sounds", isOn: $prefs.codecSounds)
                Toggle("Also when opening and closing panes", isOn: $prefs.paneSounds)
                    .disabled(!prefs.codecSounds)
                LabeledContent("Volume") {
                    Slider(value: $prefs.soundVolume, in: 0...1)
                }
                .disabled(!prefs.codecSounds)
                HStack {
                    Spacer()
                    Button("Call") { sounds.play(.call) }
                    Button("Lock-on") { sounds.play(.lock) }
                    Button("Close") { sounds.play(.exit) }
                }
                .disabled(!prefs.codecSounds)
            }
        }
        .formStyle(.grouped)
    }
}
