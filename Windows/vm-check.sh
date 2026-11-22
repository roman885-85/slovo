#!/bin/bash
# =============================================================================
#  vm-check.sh — перевірка «Слова» для Windows у справжній Windows (ВМ Parallels)
# =============================================================================
#  Проганяє сценарії vm/1…5 у ВМ «Мой Boot Camp» через
#  cloude_work/tools/nas-migrator-win/vm/exec.sh (той додає BOM і виконує
#  PowerShell від імені користувача Windows). Спершу збирається Слово.exe
#  (build.sh) — сценарії беруть його з ~/Documents/Слово.
#
#  ВМ має бути ЗАПУЩЕНА заздалегідь: `prlctl start "Мой Boot Camp"` і зачекати
#  хвилину. Приспаний стан не переживає зміни версії Parallels (22.11.2026:
#  resume → «Operation canceled»); скидати його (`prlctl stop --drop-state`) —
#  лише за словом власника. Після перевірки — `prlctl stop` (штатне вимкнення),
#  а не suspend: це ще й розділ Boot Camp.
#
#  Результат: Службові/vm/ — знімки екрана й вікон, selftest.txt, journal.txt.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
EXEC="${SLOVO_VM_EXEC:-$HOME/Documents/cloude_work/tools/nas-migrator-win/vm/exec.sh}"
VM="${MIGRATOR_VM:-Мой Boot Camp}"
[ "$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}')" = "running" ] || { echo "ВМ «$VM» не запущена: prlctl start \"$VM\" і зачекайте хвилину"; exit 1; }
mkdir -p Службові/vm
for step in 1-setup 2-drive 3-windows 4-cleanup 5-selftest; do
  echo "▶ $step"
  [ "$step" = "2-drive" ] && sleep 15
  "$EXEC" < "vm/$step.ps1" 2>&1 | tail -45
done
echo "✓ знімки й журнали: $PWD/Службові/vm"
