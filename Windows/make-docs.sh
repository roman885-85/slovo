#!/bin/bash
# =============================================================================
#  make-docs.sh — ЧИТАТЬ.md → сторінка HTML і PDF (власник: «доки в pdf»)
# =============================================================================
#  Розбір Markdown — markdown-it із проєкту сайту (node_modules/.pnpm), друк у
#  PDF — Chrome без вікна (лише з --disable-extensions, інакше висне).
#  Результат: ~/Documents/Слово/Слово для Windows — як користуватись.{md,html,pdf}
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
OUT="${SLOVO_WIN_OUT:-$HOME/Documents/Слово}"
NAME="Слово для Windows — як користуватись"
SITE="${SLOVO_SITE_REPO:-$HOME/Documents/cloude_work}"
cp ЧИТАТЬ.md "$OUT/$NAME.md"
node - "$SITE" ЧИТАТЬ.md "$OUT/$NAME.html" <<'JS'
import { createRequire } from 'module';
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'fs';
import path from 'path';
const [repo, source, target] = process.argv.slice(2);
const pnpm = path.join(repo, 'node_modules', '.pnpm');
const dir = existsSync(pnpm) ? readdirSync(pnpm).filter((d) => d.startsWith('markdown-it@')).sort().pop() : null;
if (!dir) { console.error('немає markdown-it у ' + pnpm); process.exit(1); }
const require = createRequire(path.join(pnpm, dir, 'node_modules', 'markdown-it', 'package.json'));
const md = require('markdown-it')({ html: false, linkify: true, typographer: false });
const body = md.render(readFileSync(source, 'utf8'));
const css = `
  body { font: 11pt/1.45 -apple-system, "Segoe UI", Roboto, Arial, sans-serif; color: #111; max-width: 900px; margin: 24px auto; padding: 0 24px; }
  h1 { font-size: 22pt; margin: 0 0 12px; } h2 { font-size: 15pt; margin: 22px 0 8px; border-bottom: 1px solid #ccc; padding-bottom: 3px; page-break-after: avoid; }
  h3 { font-size: 12pt; margin: 16px 0 6px; } p, li { orphans: 3; widows: 3; } code { font-family: Menlo, Consolas, monospace; font-size: 9.5pt; background: #f3f3f3; padding: 0 3px; }
  pre { background: #f3f3f3; padding: 8px 10px; font-size: 9.5pt; white-space: pre-wrap; word-break: break-word; }
  table { border-collapse: collapse; margin: 8px 0; font-size: 10pt; } th, td { border: 1px solid #ccc; padding: 4px 8px; vertical-align: top; text-align: left; }
  hr { border: 0; border-top: 1px solid #ccc; margin: 20px 0; } strong { font-weight: 600; }
  @page { size: A4; margin: 16mm 14mm; } @media print { body { margin: 0; max-width: none; } a { color: inherit; text-decoration: none; } }
`;
writeFileSync(target, `<!doctype html><html lang="uk"><head><meta charset="utf-8"><title>Слово для Windows</title><style>${css}</style></head><body>${body}</body></html>`);
console.log('HTML: ' + target);
JS
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  PROFILE="$(mktemp -d)"
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-default-apps \
    --disable-extensions --disable-background-networking --disable-component-update --user-data-dir="$PROFILE" \
    --no-pdf-header-footer --generate-pdf-document-outline --print-to-pdf="$OUT/$NAME.pdf" "file://$OUT/$NAME.html" >/dev/null 2>&1 &
  pid=$!; n=0
  while kill -0 "$pid" 2>/dev/null; do [ "$n" -ge 120 ] && { kill "$pid" 2>/dev/null; break; }; sleep 1; n=$((n+1)); done
  rm -rf "$PROFILE"
  xattr -c "$OUT/$NAME.pdf" 2>/dev/null || true
  [ -s "$OUT/$NAME.pdf" ] && echo "PDF: $OUT/$NAME.pdf ($(du -h "$OUT/$NAME.pdf" | cut -f1))" || echo "✗ PDF не вийшов"
else
  echo "Chrome не знайдено — лише HTML"
fi
