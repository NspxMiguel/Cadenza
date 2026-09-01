# ADR 0001 — API v10 documentada em docs/

- Status: aceite (evidência: `docs/api-v10.md`)
- Data: 2026-08-31

## Contexto

O repositório mantém documentação específica da API em `docs/api-v10.md` (e afins: library-writes, lossless, scores).

## Decisão

Tratar `docs/api-v10.md` como fonte de verdade da superfície de API do cliente; alterações de protocolo devem atualizar esse ficheiro na mesma mudança.

## Consequências

README deve apontar para esses docs; evitar duplicar contratos noutros sítios.
