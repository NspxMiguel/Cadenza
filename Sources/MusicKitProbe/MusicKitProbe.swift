import Foundation
import MusicKit

/// Settles one question: does native MusicKit playback work from an app signed
/// with a free account and no MusicKit capability?
///
/// Apple documents the MusicKit capability in the context of MusicKit JS, where
/// it gates issuing developer tokens. Native MusicKit authenticates through the
/// signed-in user's own Apple Music subscription instead, so it may need nothing
/// but a usage description. If that holds, lossless and Spatial Audio are
/// reachable without a paid membership.
@main
struct MusicKitProbe {
    // A track from the classical catalog — classical tracks are ordinary
    // Apple Music catalog items, which is the whole premise.
    static let trackID = "1546810784"

    static func main() async {
        print("— MusicKit probe —\n")
        print("bundle: \(Bundle.main.bundleIdentifier ?? "nenhum (não empacotado)")")

        let status = await MusicAuthorization.request()
        print("autorização: \(status)")
        guard status == .authorized else {
            print("\n❌ negado. Sem autorização não dá pra concluir nada.")
            return
        }

        do {
            let sub = try await MusicSubscription.current
            print("assinatura: ativa=\(sub.canPlayCatalogContent) "
                + "pode assinar=\(sub.canBecomeSubscriber)")
            guard sub.canPlayCatalogContent else {
                print("\n❌ sem direito a catálogo.")
                return
            }
        } catch {
            print("assinatura: falhou — \(error)")
        }

        do {
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id, equalTo: MusicItemID(trackID))
            request.properties = [.albums]
            let response = try await request.response()

            guard let song = response.items.first else {
                print("\n❌ faixa \(trackID) não encontrada no catálogo.")
                return
            }
            print("\nfaixa: \(song.title) — \(song.artistName)")

            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await player.prepareToPlay()
            try await player.play()

            try? await Task.sleep(for: .seconds(4))
            let state = player.state
            print("estado: \(state.playbackStatus)  taxa=\(state.playbackRate)")
            print("posição: \(String(format: "%.1f", player.playbackTime))s")

            if state.playbackStatus == .playing && player.playbackTime > 0 {
                print("\n✅ MusicKit nativo TOCA sem capability paga.")
                print("   Caminho livre pra lossless/Atmos.")
            } else {
                print("\n⚠️  não avançou — ver estado acima.")
            }
            player.stop()
        } catch {
            print("\n❌ falhou: \(error)")
            print("   tipo: \(type(of: error))")
        }
    }
}
