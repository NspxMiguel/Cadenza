# Security Policy — Cadenza

## Reportar
Problemas de segurança: contacto do maintainer (NSPX). Não abrir issue pública com detalhes exploráveis.

## Superfície
- Cliente macOS nativo (SwiftUI + WebKit/FairPlay)
- OAuth public client (PKCE) — sem client secret no repositório
- Tokens de sessão no Keychain / armazenamento local da app

## Dependências e CI
- Builds locais via `./build.sh` / `swift build`
- CI corre `swift build` em macOS runners quando disponível

## Secrets
Nunca commitar cookies, tokens Music, ou `.env` reais. Ver ADR de portfólio 0008.
