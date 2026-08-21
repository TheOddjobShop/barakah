import SwiftUI
import UniformTypeIdentifiers

/// What Barakah shows the first time it runs.
///
/// It exists for one reason. Barakah ships no adhan recording — every recording
/// of the adhan is under copyright even though the words are not — so out of the
/// box the athan is a synthesised chime. Somebody who installs a prayer app and
/// hears a bell reasonably concludes it is broken or cheap. This makes choosing
/// a real recording the first thing that happens, in one drag, instead of
/// something to discover three settings tabs deep.
struct WelcomeView: View {
    @Bindable var app: AppState
    var onFinish: () -> Void

    @State private var isPickingFile = false
    @State private var isTargeted = false
    @State private var importError: String?
    @State private var importedName: String?

    private var installed: [String] { AthanLibrary.available() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            body_
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 460)
        .background(.ultraThinMaterial)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        ) { result in
            guard case .success(let url) = result else { return }
            performImport(url)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent(for: .maghrib))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 3) {
                Text("Barakah")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Prayer times, iqama reminders, and media that stops.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.headerGradient(for: .maghrib))
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your athan")
                .font(.system(size: 14, weight: .semibold))

            Text("Barakah doesn't include an adhan recording — every recording of the adhan is copyrighted, even though the words themselves are not. Use one you have, and Barakah will match its volume to everything else.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            dropTarget

            if let importedName {
                Label("Using “\(importedName)”", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !installed.isEmpty {
                // Anything already sitting in the Athan folder is offered
                // straight away rather than making the user re-pick it.
                Picker("Already installed", selection: Binding(
                    get: { currentBundledName ?? "" },
                    set: { use(bundled: $0) }
                )) {
                    if currentBundledName == nil {
                        Text("Chime (built in)").tag("")
                    }
                    ForEach(installed, id: \.self) { Text(AthanSound.bundledDisplayName(for: $0)).tag($0) }
                }
                .font(.system(size: 12))
            }
        }
        .padding(16)
    }

    private var dropTarget: some View {
        VStack(spacing: 7) {
            Image(systemName: isTargeted ? "square.and.arrow.down.fill" : "waveform")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(isTargeted ? Theme.accent(for: .maghrib) : .secondary)

            Text(isTargeted ? "Drop it here" : "Drag an audio file here")
                .font(.system(size: 12, weight: .medium))

            Button("Choose a file…") { isPickingFile = true }
                .controlSize(.small)

            Text("MP3, M4A, WAV, AIFF or CAF")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(isTargeted ? Theme.accent(for: .maghrib).opacity(0.10) : Color.secondary.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Theme.accent(for: .maghrib).opacity(0.55) : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [5, 4])
                        )
                }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in performImport(url) }
            }
            return true
        }
    }

    private var footer: some View {
        HStack {
            Text("You can change this later in Settings → Athan.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            // The label has to match what the button actually does. Offering
            // "use the chime" while a recording is already selected both lies
            // about the outcome and dismisses without honouring it.
            if hasRecordingSelected {
                Button("Done") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Use the built-in chime") {
                    app.updateSettings { $0.athanSound = .chime }
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var currentBundledName: String? {
        if case .bundled(let name) = app.settings.athanSound { return name }
        return nil
    }

    /// True once an actual recording is in play — either just imported, or
    /// already installed and chosen in the picker.
    private var hasRecordingSelected: Bool {
        importedName != nil || currentBundledName != nil
    }

    private func performImport(_ url: URL) {
        do {
            let name = try AthanImporter.import(url)
            use(bundled: name)
            importedName = AthanSound.bundledDisplayName(for: name)
            importError = nil
        } catch {
            importError = error.localizedDescription
            importedName = nil
        }
    }

    private func use(bundled name: String) {
        app.updateSettings { $0.athanSound = .bundled(name) }
        importedName = AthanSound.bundledDisplayName(for: name)
    }
}
