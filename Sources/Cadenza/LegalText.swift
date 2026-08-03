import Foundation

/// The text of the documents. Kept apart from the machinery that displays them
/// so that editing a clause never means reading a view.
enum LegalText {

    // MARK: - Licenças e créditos

    static let licences = """
    # Licenças e créditos

    O Cadenza é um projeto independente. **Não tem vínculo, patrocínio nem \
    endosso da Apple Inc. ou da Google LLC.** Apple Music, Apple Music Classical \
    e as marcas relacionadas pertencem à Apple Inc.; Google Drive pertence à \
    Google LLC. Os nomes aparecem aqui apenas para dizer com o que o app conversa.

    ## O próprio Cadenza

    Licença MIT. Copyright © 2026 Miguel Moretti. O texto completo está no arquivo \
    `LICENSE` do repositório: [github.com/NspxMiguel/Cadenza](https://github.com/NspxMiguel/Cadenza).

    Em resumo: você pode usar, copiar, alterar e redistribuir, inclusive \
    comercialmente, desde que mantenha o aviso de copyright. O software vem sem \
    garantia.

    ## Partituras

    Nenhuma partitura é escrita por este app. Todas vêm de acervos públicos de \
    terceiros, baixadas na hora, e cada uma carrega os termos de quem a digitou.

    ### OpenScore — CC0 1.0

    *Lieder Corpus* e *String Quartets Corpus*, do projeto OpenScore.

    Dedicados ao domínio público sob [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). \
    Não exigem atribuição — mas alguém digitou cada nota, e isso merece o crédito \
    que o app dá no rodapé da partitura.

    ### Edições Humdrum de Craig Stuart Sapp

    Oito acervos de `**kern`, do repertório de teclado e quarteto de cordas. \
    Copyright © Craig Stuart Sapp / CCARH.

    Quatro deles declaram licença \
    [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) — \
    atribuição, uso **não comercial**, e compartilhamento sob a mesma licença:

    - Sonatas para piano de Mozart
    - Sonatas para piano de Haydn
    - Sonatas para teclado de Scarlatti
    - Obras de Scott Joplin

    Os outros quatro não declaram licença nenhuma:

    - Sonatas para piano de Beethoven
    - Mazurcas de Chopin
    - Prelúdios de Chopin
    - Quartetos de cordas de Beethoven

    Sem declaração, o padrão legal é "todos os direitos reservados". O Cadenza os \
    exibe como leitura pessoal, sempre creditando o editor, e nunca os \
    redistribui — o download vai direto do repositório de origem para a sua \
    máquina, sem passar por nenhum servidor deste projeto.

    A cláusula **não comercial** é vinculante enquanto o app trouxer esses \
    acervos: o Cadenza não pode ser vendido, nem monetizado, nem embutido em algo \
    que seja.

    ## Verovio — LGPL 3.0

    A gravação das partituras na tela é feita pelo [Verovio](https://www.verovio.org), \
    do RISM Digital Center, sob [LGPL 3.0](https://www.gnu.org/licenses/lgpl-3.0.html).

    O Verovio não é distribuído com o Cadenza: é carregado do site do próprio \
    projeto quando você abre uma partitura, e roda dentro de uma webview isolada.

    ## oemer — MIT

    O reconhecimento de partituras escaneadas usa o [oemer](https://github.com/BreezeWhite/oemer), \
    de BreezeWhite, sob licença MIT.

    Não vem junto com o app. É instalado sob demanda, num ambiente Python \
    separado, na primeira vez que você pede a leitura de uma gravura — e roda \
    inteiramente na sua máquina, sem enviar a imagem para lugar nenhum.

    ## Conteúdo da Apple e do Google

    Catálogo, capas, textos editoriais, letras e áudio do Apple Music Classical \
    pertencem à Apple Inc. e aos titulares dos direitos das gravações. O Cadenza \
    apenas os exibe e os reproduz pela sua assinatura; não os armazena, não os \
    decifra e não os redistribui.

    Os arquivos que você envia para o Google Drive continuam seus. O Cadenza usa o \
    escopo `drive.file`, que só dá acesso ao que o próprio app criou.

    ## Fontes tipográficas e ícones

    A interface usa fontes e símbolos do sistema (SF Pro e SF Symbols), fornecidos \
    pela Apple com o macOS e sujeitos aos termos dela.
    """

    // MARK: - Política de Privacidade

    static let privacy = LegalDrafts.privacy

    // MARK: - Termos de Uso

    static let terms = LegalDrafts.terms
}
