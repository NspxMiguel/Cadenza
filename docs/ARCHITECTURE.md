# Arquitetura — Cadenza

## Overview

<div align="center">

<img src="docs/img/cadenza-icon.png" alt="Cadenza" width="148">

# Cadenza

**Apple Music Classical, native to macOS.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](#install)
[![Swift](https://img.shields.io/badge/built_with-SwiftUI%20%2B%20WebKit-F05138?logo=swift&logoColor=white)](#how-it-works)
[![Audio](https://img.shields.io/badge/audio-local%20files%20%2B%20Apple%20Music-7a1f2b)](#audio-quality)
[![License](https://img.shields.io/github/license/NspxMiguel/Cadenza?color=lightgrey)](LICENSE)

</div>

---

Cadenza is the Mac client Apple never shipped for Apple Music Classical. It pairs a native SwiftUI library with Apple's WebKit player, so browsing feels like a Mac app while playback stays inside Apple's supported DRM path.

Built in the spirit of [Cider](https://cider.sh): the web layer is used only as a
playback engine,

## Stack

- Package: `(sem name)` 
- Gestor: **npm**
- Workspaces: não
- Dependências (amostra): 

## Árvore

```
├── capture/
│   ├── endpoints.txt
│   ├── streams.txt
│   └── tokens.json
├── docs/
│   ├── img/
│   ├── api-v10.md
│   ├── library-writes.md
│   ├── lossless.md
│   └── scores.md
├── Formula/
│   └── cadenza.rb
├── Resources/
│   └── Cadenza.icns
├── Sources/
│   ├── Cadenza/
│   └── MusicKitProbe/
├── tools/
│   ├── build-probe.sh
│   ├── decode-test.sh
│   ├── discover.py
│   ├── emit-site.py
│   ├── id3-fixture.py
│   ├── make-icon.swift
│   └── qa-biblioteca.py
├── build.sh
├── LICENSE
├── Package.swift
└── README.md
```

```mermaid
flowchart LR
  src[Código] --> build[Build]
  build --> out[Artefacto]
```

## Scripts disponíveis

| Script | Comando |
|--------|---------|

