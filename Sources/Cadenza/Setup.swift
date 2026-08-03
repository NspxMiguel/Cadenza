import SwiftUI

/// First run.
///
/// Until now the only thing the app asked for on launch was an Apple ID, and
/// everything else it can do — the music already on the Mac, the copy of it on
/// Drive — sat in a preferences tab nobody opens. Two of the three things this
/// app is for were therefore invisible to anyone who did not already know they
/// were there.
///
/// Every step after the first is skippable and says so. A setup that cannot be
/// escaped is a worse first impression than no setup at all.
@MainActor
@Observable
final class SetupState {
    static let shared = SetupState()

    enum Step: Int, CaseIterable {
        case appleMusic, local, drive, done

        var title: String {
            switch self {
            case .appleMusic: "Apple Music"
            case .local: "Suas músicas"
            case .drive: "Google Drive"
            case .done: "Pronto"
            }
        }
    }

    private static let key = "cadenza.setup.completed"

    var isPresented = false
    var step: Step = .appleMusic

    /// Where the flow started, so the progress dots do not show steps that were
    /// never going to be offered.
    private(set) var entry: Step = .appleMusic

    var hasCompleted: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    func begin(at step: Step) {
        entry = step
        self.step = step
        isPresented = true
    }

    var steps: [Step] { Step.allCases.filter { $0.rawValue >= entry.rawValue } }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.key)
        isPresented = false
    }
}

// MARK: - The sheet

struct SetupSheet: View {
    /// Called the moment Apple's tokens appear, so the library can start
    /// loading behind the sheet rather than after it.
    var onAuthenticated: () -> Void = {}

    @State private var state = SetupState.shared

    var body: some View {
        VStack(spacing: 0) {
            switch state.step {
            case .appleMusic: AppleMusicStep(onAuthenticated: onAuthenticated)
            case .local: LocalMusicStep()
            case .drive: DriveStep()
            case .done: DoneStep()
            }
        }
        .frame(width: state.step == .appleMusic ? 980 : 620,
               height: state.step == .appleMusic ? 700 : 470)
        .animation(.snappy(duration: 0.2), value: state.step)
    }
}

/// The frame every step after the web view shares: a symbol, a claim, an
/// explanation, whatever the step actually does, and a way out.
private struct StepFrame<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @State private var state = SetupState.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)

                Text(title)
                    .font(.cadenzaTitle(23))
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 54)

                content
                    .padding(.top, 6)
            }
            // Centred rather than pinned to the top. These steps are short, and
            // top-aligned they left half the sheet as blank space, which reads
            // as something that failed to load.
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            Divider()

            HStack(spacing: 10) {
                dots
                Spacer()
                actions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(state.steps, id: \.rawValue) { step in
                Circle()
                    .fill(step == state.step ? AnyShapeStyle(.tint)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: Step 1 — Apple Music

private struct AppleMusicStep: View {
    let onAuthenticated: () -> Void

    @State private var probe = DRMProbe()
    @State private var state = SetupState.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entre com seu Apple ID").font(.headline)
                    Text("O Cadenza toca pela sua própria assinatura. A senha vai para a "
                         + "Apple, na página dela — o app não a vê.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Agora não") { state.advance() }
            }
            .padding(12)

            Divider()
            ClassicalWebView(probe: probe)
        }
        .task {
            // The harvester runs inside the page; poll until it has both tokens.
            while !Task.isCancelled {
                if TokenStore.shared.credentials != nil {
                    onAuthenticated()
                    state.advance()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: Step 2 — Local files

private struct LocalMusicStep: View {
    @State private var state = SetupState.shared
    @State private var library = LocalLibrary.shared

    var body: some View {
        StepFrame(
            symbol: "folder.badge.plus",
            title: "As músicas que já são suas",
            detail: "Rips dos seus discos, gravações ao vivo, transferências de LP — "
                + "aquilo que nenhuma assinatura tem. Toca em lossless, porque nada "
                + "aqui recodifica o arquivo."
        ) {
            VStack(spacing: 10) {
                Button {
                    library.promptForFiles()
                } label: {
                    Text("Escolher arquivos ou uma pasta…").frame(width: 240)
                }
                .controlSize(.large)

                if library.importing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Lendo as etiquetas…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if !library.tracks.isEmpty {
                    Label("\(library.tracks.count) faixa\(library.tracks.count == 1 ? "" : "s") "
                          + "na biblioteca", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                }

                Text("MP3, AAC, ALAC, FLAC, WAV, AIFF, Opus e mais 20 formatos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button(library.tracks.isEmpty ? "Pular" : "Continuar") { state.advance() }
                .buttonStyle(library.tracks.isEmpty ? AnyPrimitiveButtonStyle(.bordered)
                             : AnyPrimitiveButtonStyle(.borderedProminent))
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Step 3 — Google Drive

private struct DriveStep: View {
    @State private var state = SetupState.shared
    @State private var auth = GoogleAuth.shared
    @State private var drive = DriveSync.shared
    @State private var library = LocalLibrary.shared

    var body: some View {
        StepFrame(
            symbol: auth.isSignedIn ? "checkmark.icloud" : "icloud.and.arrow.up",
            title: "As mesmas músicas em qualquer Mac",
            detail: "O Cadenza guarda seus arquivos locais numa pasta do seu Drive e traz "
                + "de volta no outro computador, com título, álbum e capa junto. "
                + "Ele só enxerga o que ele mesmo criou lá — o resto do seu Drive "
                + "continua fora do alcance dele."
        ) {
            VStack(spacing: 10) {
                if auth.isSignedIn {
                    Label(auth.email ?? "Conectado", systemImage: "person.crop.circle.fill")
                        .font(.callout)

                    if library.tracks.isEmpty {
                        Text("Nada para enviar ainda. Assim que você importar algo, "
                             + "use Ajustes ▸ Armazenamento.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 50)
                    } else {
                        Button("Enviar \(library.tracks.count) faixa"
                               + "\(library.tracks.count == 1 ? "" : "s") agora") {
                            Task { await drive.push() }
                        }
                        .controlSize(.large)
                        .disabled(isWorking)
                    }

                    switch drive.state {
                    case .working(let step):
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(step).font(.callout).foregroundStyle(.secondary)
                        }
                    case .done(let message):
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message).font(.callout).foregroundStyle(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    case .idle:
                        EmptyView()
                    }
                } else {
                    Button {
                        Task { await auth.signIn() }
                    } label: {
                        HStack(spacing: 7) {
                            if auth.busy { ProgressView().controlSize(.small) }
                            Text("Entrar com o Google").frame(minWidth: 150)
                        }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(auth.busy)

                    if auth.busy {
                        Text("Termine no navegador e volte para cá.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = auth.lastError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                }
            }
        } actions: {
            Button(auth.isSignedIn ? "Continuar" : "Pular") { state.advance() }
                .buttonStyle(auth.isSignedIn ? AnyPrimitiveButtonStyle(.borderedProminent)
                             : AnyPrimitiveButtonStyle(.bordered))
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
        }
    }

    private var isWorking: Bool {
        if case .working = drive.state { return true }
        return false
    }
}

// MARK: Step 4 — Done

private struct DoneStep: View {
    @State private var state = SetupState.shared

    var body: some View {
        StepFrame(
            symbol: "music.quarternote.3",
            title: "Tudo pronto",
            detail: "Procure por obra, compositor ou gravação. A partitura e a letra ficam "
                + "no mesmo botão, embaixo do player. Dá para mudar tudo isto depois "
                + "em Ajustes."
        ) {
            EmptyView()
        } actions: {
            Button("Começar a ouvir") { state.finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Choosing a button style at runtime, which SwiftUI's own styles cannot do
/// because each is a distinct type.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
