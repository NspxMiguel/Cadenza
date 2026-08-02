# Escrevendo na biblioteca

Tudo aqui foi verificado contra a API real, com as credenciais da conta, não
lido em documentação. A API pública documentada e a que o cliente web usa não
são a mesma superfície, e onde divergem a documentada está errada.

Base: `https://amp-api.music.apple.com/v1`.
Cabeçalhos: `Authorization: Bearer <developerToken>`, `Music-User-Token`,
`Origin: https://music.apple.com`.

## Playlists

| Ação | Requisição | Resposta |
|---|---|---|
| Criar | `POST /me/library/playlists` com `{"attributes":{"name":…},"relationships":{"tracks":{"data":[{"id","type":"songs"}]}}}` | `201` com a playlist criada |
| Renomear | `PATCH /me/library/playlists/{id}` com `{"attributes":{"name":…}}` | `204` |
| Apagar | `DELETE /me/library/playlists/{id}` | `204` |
| Adicionar faixas | `POST /me/library/playlists/{id}/tracks` com `{"data":[{"id","type":"songs"}]}` | `204` |
| Remover faixa | `DELETE /me/library/playlists/{id}/tracks?ids[library-songs]={i.…}&mode=all` | `204` |

`PUT` também é aceito onde `PATCH` é, mas não há motivo para usar.

Três detalhes que custam tempo se descobertos por tentativa:

- **`mode` é obrigatório na remoção.** Sem ele a resposta é
  `400 Missing Parameter` apontando `mode` — que se parece com endpoint errado
  até você ler o `source.parameter`.
- **Remove-se pelo identificador de biblioteca (`i.…`), não pelo do catálogo.**
  A mesma gravação adicionada duas vezes tem dois deles, e só o de biblioteca
  distingue as duas.
- **Os colchetes precisam vir percent-encoded.** Literais, a resposta é
  `Bad Request`.

## Capa de playlist: não existe

Não há rota. `GET …/artwork` responde que a relação não existe e todo verbo de
escrita responde `405`. `PATCH` com `attributes.artwork` responde `204` e não
muda nada. A capa em mosaico que aparece é gerada pela Apple a partir das
faixas.

Trocar a capa é possível nos apps Música da Apple, não por esta API. É a única
coisa desta lista que o app não pode fazer.

## Biblioteca

| Ação | Requisição | Resposta |
|---|---|---|
| Adicionar | `POST /me/library?ids[songs]={catalogId}` (também `albums`) | `202` |
| Remover | `DELETE /me/library/{songs\|albums}/{i.…}` | `204` |
| Resolver id de biblioteca | `GET /me/library/songs?limit=100&sort=-dateAdded` e comparar `playParams.catalogId` | — |

`202 Accepted` não é `200`: a linha aparece segundos depois. Qualquer leitura
imediata vê a biblioteca inalterada — o que parece falha e não é. O app relê
depois de esperar, em vez de confiar na escrita.

## Favoritos

| Tipo | Requisição | Resposta |
|---|---|---|
| Faixas | `POST\|DELETE /me/favorites?ids[songs]={catalogId}` | `202` |
| Playlists | `…?ids[playlists]={pl.…}` | `202` |
| Artistas | `…?ids[library-artists]={r.…}` | `202` |
| Álbuns e artistas por id de catálogo | — | `404` "does not exist in user's Library" |

Não há rota de leitura: `GET /me/favorites` responde `404`. Os favoritos de
faixas são lidos da playlist que a Apple mantém e não deixa editar — a mesma que
reporta `canEdit: false` e não tem `playParams.globalId`.

O `inFavorites` do catálogo clássico **nunca** vira verdadeiro, nem depois da
escrita ser aceita. Foi o que fez a estrela parecer mentir: ela mostrava o
favorito da Apple Classical, não o do usuário.

## Playlist vazia responde 404

`GET /me/library/playlists/{id}/tracks` de uma playlist sem faixas responde
`404 "No related resources"`, não uma lista vazia. Tratado como falha, isso
fazia toda playlist criada no app sumir da barra lateral no instante em que era
criada, e abrir como "não foi possível carregar".

## A listagem atrasa

`GET /me/library/playlists` não contém uma playlist criada segundos antes.
Recarregar depois de criar devolve a lista de antes. Por isso o app insere a
playlist nova localmente em vez de reler.

O mesmo vale para o índice clássico: uma faixa adicionada à biblioteca aparece
em `/me/library/songs` quase na hora, mas a tela `favorites/tracks` da API
clássica continua vazia por bem mais tempo. Isso é reindexação da Apple, não do
app.
