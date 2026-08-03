import Foundation

/// The two documents that had to be written rather than assembled.
///
/// Most privacy policies are a template with the product's name substituted in,
/// and they describe collection that is not happening. This one describes an app
/// with no server: the honest version is shorter than the template and says more.
enum LegalDrafts {

    // MARK: - Política de Privacidade

    static let privacy = """
    # Política de Privacidade

    Versão de 3 de agosto de 2026.

    ## O essencial, primeiro

    **Nada do que você faz no Cadenza chega até quem o desenvolveu.**

    Não existe servidor do Cadenza. Não existe cadastro, conta nem login neste \
    app. Não há telemetria, análise de uso, relatório de falhas nem qualquer \
    biblioteca de rastreamento. O autor do app não recebe seu nome, seu e-mail, \
    o que você ouve, quando ouve, nem que ele foi aberto.

    O app roda no seu Mac e fala com dois serviços — a Apple e o Google — porque \
    **você** tem conta neles e pediu que ele os usasse. O que trafega vai direto \
    do seu computador para eles, sem intermediário.

    ## O que fica guardado, e onde

    Tudo no seu próprio Mac:

    - **Credenciais da Apple Music** — em `~/Library/Application Support/Cadenza/`, \
    com permissão de leitura só para o seu usuário. São os mesmos tokens que o \
    site da Apple entrega ao navegador quando você entra.
    - **Token do Google** — na Chaveira do macOS, cifrada pelo sistema. Não fica \
    em arquivo de preferências.
    - **Catálogo das músicas locais** — títulos, intérpretes, compositores, \
    álbuns e o caminho dos arquivos, em `~/Library/Application Support/Cadenza/local-library.json`. \
    Os arquivos de áudio não são copiados: o app só aponta para onde eles já estão.
    - **Capas das músicas locais** — em `~/Library/Application Support/Cadenza/local-artwork/`.
    - **Partituras baixadas e resultados de leitura de gravuras** — em \
    `~/Library/Application Support/Cadenza/partituras/` e `.../omr/`.
    - **Preferências** — idioma, zoom da partitura, motor de áudio, em UserDefaults.
    - **Cookies e dados de site** do player da Apple, guardados pelo WebKit onde \
    o macOS guarda os de qualquer app.

    ### Como apagar tudo

    - Em **Ajustes ▸ Armazenamento**, use **Sair** para desconectar o Google — \
    isso apaga o token da Chaveira.
    - Apague a pasta `~/Library/Application Support/Cadenza/`.
    - Apague o app.
    - Se quiser, apague a pasta `Cadenza` no seu Google Drive e revogue o acesso \
    em [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

    Não é preciso pedir nada a ninguém: não existe cópia em outro lugar.

    ## Google Drive

    Conectar o Google é opcional. O app nunca faz isso sozinho — só quando você \
    clica em **Entrar com o Google**.

    O Cadenza pede um único escopo, `drive.file`. Ele significa, literalmente, que \
    **o app só enxerga arquivos que ele mesmo criou**. O resto do seu Drive — \
    documentos, fotos, planilhas — é invisível para ele, e isso é o Google quem \
    garante, não este texto.

    O que vai para lá são os arquivos de música que você mesmo importou e um \
    `biblioteca.json` com os títulos, álbuns, compositores e referências de capa \
    que você editou. Tudo dentro de uma pasta só, `Cadenza`, que você pode abrir, \
    inspecionar e apagar quando quiser. O envio e a busca são sempre iniciados por \
    você, num botão; nada sobe em segundo plano.

    O login acontece no seu navegador, na página do próprio Google. O app não vê \
    sua senha.

    ### Limited Use

    > Cadenza's use and transfer to any other app of information received from \
    Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), \
    including the Limited Use requirements.

    Em português: o uso que o Cadenza faz — e qualquer transferência para outro \
    app — das informações recebidas das APIs do Google segue a Política de Dados \
    do Usuário dos Serviços de API do Google, incluindo os requisitos de Uso \
    Limitado. Na prática: os dados do seu Drive servem só para a função que você \
    acionou, não são transferidos a ninguém, não alimentam publicidade, não são \
    lidos por pessoa alguma e não treinam modelo nenhum.

    ## Apple Music

    Você entra com o seu Apple ID, na página da Apple, dentro de uma janela do \
    app. A senha vai para a Apple; o Cadenza não a lê nem a guarda. O que ele \
    guarda são os tokens que a sessão devolve, e são eles que permitem mostrar a \
    sua biblioteca e tocar pela sua assinatura.

    O que você faz no app — tocar, favoritar, criar playlist — acontece na sua \
    conta da Apple e está sujeito à \
    [Política de Privacidade da Apple](https://www.apple.com/br/legal/privacy/).

    ## Outros serviços que o app contata

    - **github.com** — para baixar partituras de domínio público dos acervos \
    OpenScore e Humdrum. Vai só o pedido do arquivo.
    - **verovio.org** — para carregar o programa que desenha a partitura na tela.
    - **pypi.org** — apenas se você pedir a leitura de uma gravura escaneada, para \
    instalar o reconhecedor. A imagem em si nunca sai do seu Mac.

    Nenhum deles recebe quem você é. Como qualquer servidor da internet, eles \
    registram o endereço IP de quem faz o pedido.

    A tradução de letras usa o tradutor do próprio macOS e roda no seu \
    computador — o texto não é enviado para lugar nenhum.

    ## Crianças

    O Cadenza não é dirigido a crianças e não coleta dado nenhum de ninguém, de \
    qualquer idade.

    ## Seus direitos

    A pergunta que essas leis existem para responder — *o que essa empresa sabe \
    sobre mim, e como faço para apagar?* — aqui tem resposta curta: **nada**, e \
    você apaga sozinho, nos passos acima.

    Ainda assim, vale dizer onde cada direito se exerce:

    - **LGPD** (Brasil, Lei 13.709/2018) — acesso, correção, eliminação, \
    portabilidade. Como o autor do app não recebe nem trata dado pessoal seu, ele \
    não é controlador de nada que seja seu, e não há pedido a fazer a ele. Os \
    dados estão na sua máquina e nas suas contas da Apple e do Google.
    - **GDPR** (União Europeia) e **UK GDPR** — artigos 15 a 21. Mesma situação: \
    sem tratamento pelo desenvolvedor, não há a quem requerer. Para os dados nas \
    contas que você conectou, use [privacy.apple.com](https://privacy.apple.com) e \
    [takeout.google.com](https://takeout.google.com).
    - **CCPA/CPRA** (Califórnia) — o Cadenza não vende nem compartilha informação \
    pessoal. Não há o que recusar.
    - **APPI** (Japão) — o app não mantém base de dados pessoais.
    - **Revogar o Google** a qualquer momento, sem passar pelo app: \
    [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

    ## Mudanças

    Se esta política mudar, a versão nova sai junto com uma versão do app e a data \
    no topo muda. O histórico completo fica público no repositório.

    ## Contato

    Abra uma questão em \
    [github.com/NspxMiguel/Cadenza/issues](https://github.com/NspxMiguel/Cadenza/issues). \
    É o canal do projeto, e fica registrado.
    """

    // MARK: - Termos de Uso

    static let terms = """
    # Termos de Uso

    Versão de 3 de agosto de 2026.

    ## O que é isto

    O Cadenza é um app de código aberto para macOS que serve de cliente para o \
    Apple Music Classical — que a Apple nunca lançou para Mac. É gratuito e feito \
    por uma pessoa física.

    **Não tem vínculo, patrocínio, endosso nem aprovação da Apple Inc. ou da \
    Google LLC.** Apple, Apple Music, Apple Music Classical e as marcas \
    relacionadas pertencem à Apple Inc. Google e Google Drive pertencem à Google \
    LLC. Se você procurava o app oficial, este não é ele.

    Usar o Cadenza é aceitar estes termos. Se não aceitar, não use.

    ## O que você precisa ter

    Uma assinatura ativa do Apple Music, sua. O Cadenza não fornece música: ele \
    reproduz o que a **sua** assinatura já permite. A reprodução acontece dentro \
    do player da própria Apple, embutido no app.

    O Cadenza **não** decifra, não extrai, não baixa e não redistribui áudio \
    protegido. A proteção FairPlay permanece intacta e o áudio nunca é gravado em \
    disco. Se você procura uma ferramenta para baixar música do Apple Music, não é \
    esta — e não peça para que passe a ser.

    ## Riscos que você precisa conhecer antes de instalar

    Isto não é letra miúda. É a parte mais importante do documento.

    O Cadenza conversa com endpoints da Apple que **não são públicos nem \
    documentados**. Isso tem três consequências reais:

    - **Pode parar de funcionar a qualquer momento**, sem aviso, quando a Apple \
    mudar alguma coisa do lado dela. Não há compromisso de conserto nem prazo.
    - **Os Termos de Serviços de Mídia da Apple dizem que você deve acessar os \
    serviços usando software da Apple.** O Cadenza não é software da Apple. Usar \
    este app está fora do que a Apple autoriza, e isso não tem solução técnica: \
    qualquer cliente independente está na mesma situação.
    - **A Apple pode agir sobre a sua conta**, incluindo suspensão ou encerramento, \
    e isso alcançaria seu Apple ID inteiro, não só a música. Não se conhece caso de \
    a Apple ter feito isso contra usuário de cliente alternativo — mas ela reserva \
    esse direito, e o risco é seu, não do autor do app.

    Diante disso, **guarde cópia do que importa para você**, e não use este app \
    numa conta cuja perda seria grave.

    ## O que você se compromete a não fazer

    - Usar conta que não seja sua.
    - Usar o app para contornar proteção técnica, limite de assinatura ou \
    restrição geográfica.
    - Redistribuir conteúdo da Apple obtido através dele.
    - Vender o Cadenza, cobrar por ele ou embuti-lo em produto pago. Além de o \
    projeto não querer isso, parte dos acervos de partitura que ele traz é \
    licenciada para uso **não comercial**, e isso vincula quem redistribuir o app.

    ## Licença do código

    Licença MIT. Você pode usar, estudar, alterar e redistribuir o código, \
    mantendo o aviso de copyright. O texto completo está em `LICENSE`, no \
    repositório.

    Componentes de terceiros — Verovio, os acervos OpenScore e Humdrum, o oemer — \
    têm licenças próprias, listadas em **Licenças e créditos**. A cláusula não \
    comercial de parte das partituras merece atenção especial de quem for \
    redistribuir.

    ## Garantia e responsabilidade

    O software é fornecido **como está**, sem garantia de funcionamento, de \
    adequação a um propósito ou de disponibilidade. É um projeto pessoal, gratuito, \
    mantido no tempo livre de uma pessoa.

    Na medida em que a lei permitir, o autor não responde por danos decorrentes do \
    uso — inclusive perda de acesso a serviços de terceiros, perda de dados ou \
    interrupção.

    Dito isso, sem fingir o contrário: o **Código de Defesa do Consumidor** \
    brasileiro e a legislação de consumo da União Europeia **não admitem exclusão \
    total de responsabilidade**, e nada aqui afasta o que essas leis garantem, nem \
    responsabilidade por dolo ou culpa grave. Uma cláusula dizendo o contrário \
    seria inválida, e escrevê-la só serviria para enganar quem lê.

    ## Lei aplicável

    Estes termos seguem a lei brasileira. Fica eleito o foro da comarca de \
    domicílio do autor — com a ressalva honesta de que, sendo você consumidor, o \
    CDC lhe garante demandar no seu próprio domicílio, e essa garantia prevalece \
    sobre esta cláusula.

    ## Mudanças

    Estes termos mudam junto com o app, e a data no topo acompanha. O histórico \
    fica público no repositório. Continuar usando depois de uma mudança é aceitá-la; \
    quem não aceitar, desinstala.

    ## Contato

    [github.com/NspxMiguel/Cadenza/issues](https://github.com/NspxMiguel/Cadenza/issues).
    """
}
