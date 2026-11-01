import SwiftUI
import CodecCore

/// Explaining one failed command, for its output viewer: whether it can be, and how far it got.
@MainActor
final class FailureExplanationModel: ObservableObject {
    enum State: Equatable {
        case idle
        /// Being written: what there is of it so far.
        case working(FailureExplanation?)
        case done(FailureExplanation)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    let report: FailureReport?
    private let explainer: (any FailureExplaining)?
    private var task: Task<Void, Never>?

    /// No explainer, or a command that didn't fail with an exit status, and there's nothing to offer.
    init(entry: TimelineEntry, output: String?, explainer: (any FailureExplaining)?) {
        self.explainer = explainer
        report = explainer == nil ? nil : FailureReport(entry: entry, output: output)
    }

    var isOffered: Bool { report != nil }

    var availability: ExplainerAvailability { explainer?.availability ?? .unavailable("") }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    func explain() {
        guard let explainer, let report, !isWorking, availability == .available else { return }
        state = .working(nil)
        task = Task { [weak self] in
            var latest: FailureExplanation?
            do {
                for try await explanation in explainer.explain(report) {
                    latest = explanation
                    self?.state = .working(explanation)
                }
                guard let latest, !latest.cause.isEmpty else {
                    self?.state = .failed("No explanation came back.")
                    return
                }
                self?.state = .done(latest)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(OnDeviceExplainer.message(for: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The explanation under the output viewer's buttons: what went wrong, what to do, and a command
/// to put on the command line.
struct FailureExplanationView: View {
    @ObservedObject var model: FailureExplanationModel
    let theme: CodecTheme
    let codeFont: NSFont
    let canInsert: Bool
    var insert: (String) -> Void

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .working(nil):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the output…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(background)
        case .working(let explanation?), .done(let explanation):
            answer(explanation)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(background)
        }
    }

    private func answer(_ explanation: FailureExplanation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(explanation.cause).fontWeight(.medium)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(theme.accentColor)
            }
            if !explanation.fix.isEmpty {
                Text(explanation.fix).padding(.leading, 22)
            }
            if let command = explanation.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(Font(NSFont(descriptor: codeFont.fontDescriptor, size: 12) ?? codeFont))
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Insert", systemImage: "text.insert") { insert(command) }
                        .disabled(!canInsert || model.isWorking)
                        .help("Put this command on the command line, to check before running it")
                        .controlSize(.small)
                        .buttonStyle(.glass)
                }
                .padding(.leading, 22)
            }
            Text("Written on this Mac by Apple Intelligence, which can be wrong.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 22)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(background)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8).fill(theme.accentColor.opacity(0.08))
    }
}
