#!/bin/bash
# Exercises the decoder against a real API payload.
#
# The models decode permissively so that an unrecognised type degrades into a
# gap instead of a crash — but that same permissiveness can silently yield an
# empty screen. This asserts the payload actually produced content.
#
#   tools/decode-test.sh path/to/screen.json
set -euo pipefail
cd "$(dirname "$0")/.."

PAYLOAD="${1:-}"
if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
    echo "uso: tools/decode-test.sh <screen.json>" >&2
    echo "dica: capture um com curl usando as credenciais de capture/tokens.json" >&2
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let screen: Screen
do {
    screen = try JSONDecoder().decode(Screen.self, from: data)
} catch {
    print("FALHOU: \(error)")
    exit(1)
}

let components = screen.sections.reduce(0) { $0 + $1.components.count }
let items = screen.allItems
print("screenType: \(screen.screenType ?? "nil")")
print("seções: \(screen.sections.count)  componentes: \(components)  itens: \(items.count)")
print("com action: \(items.filter { $0.action?.url != nil }.count)")
print("com imagem: \(items.filter { $0.image?.url != nil }.count)")

if screen.sections.isEmpty || items.isEmpty {
    print("VAZIO — decodificação permissiva engoliu um erro.")
    exit(1)
}
print("OK")
SWIFT

swiftc -O Sources/Cadenza/Models.swift "$WORK/main.swift" -o "$WORK/run"
"$WORK/run" "$PAYLOAD"
