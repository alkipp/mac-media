#!/usr/bin/env bash
#
# artifacts-prune.sh — alte Läufe unter .../mac-compute/artifacts aufräumen.
#
# Jeder Lauf legt ein Verzeichnis `<uuid>/` mit Video, Frames und Logs an. Ohne
# Aufräumen wächst der Ordner unbegrenzt; auf dem Mac lagen 130 Läufe mit
# 198 MB. Das Skript behält die neuesten N Verzeichnisse und löscht den Rest.
#
# Aufruf:
#   scripts/artifacts-prune.sh                  # Trockenlauf, behält 5
#   scripts/artifacts-prune.sh --keep 10        # Trockenlauf, behält 10
#   scripts/artifacts-prune.sh --apply          # wirklich löschen
#   scripts/artifacts-prune.sh --max-age-days 30 --apply
#
# Ohne `--apply` wird nur angezeigt, was gelöscht würde. `--max-age-days`
# löscht zusätzlich alles, was älter ist, auch wenn es innerhalb der letzten N
# liegt.
#
set -euo pipefail

ARTIFACTS="${MAC_COMPUTE_DIR:-$HOME/Library/Application Support/mac-compute}/artifacts"
KEEP=5
MAX_AGE_DAYS=0
APPLY=0

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep)
      KEEP="${2:-}"
      shift 2
      ;;
    --max-age-days)
      MAX_AGE_DAYS="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf '✖ unbekannte Option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$KEEP" in
  '' | *[!0-9]*)
    printf '✖ --keep erwartet eine Zahl, bekommen: %s\n' "$KEEP" >&2
    exit 2
    ;;
esac
[ "$KEEP" -ge 1 ] || {
  printf '✖ --keep muss mindestens 1 sein\n' >&2
  exit 2
}

case "$MAX_AGE_DAYS" in
  '' | *[!0-9]*)
    printf '✖ --max-age-days erwartet eine Zahl, bekommen: %s\n' "$MAX_AGE_DAYS" >&2
    exit 2
    ;;
esac

[ -d "$ARTIFACTS" ] || {
  printf '✖ Artefaktverzeichnis fehlt: %s\n' "$ARTIFACTS" >&2
  exit 1
}

now="$(date +%s)"
total=0
would_delete=0
deleted_bytes=0

printf 'Verzeichnis: %s\n' "$ARTIFACTS"
printf 'Behalten:   die neuesten %s\n' "$KEEP"
[ "$MAX_AGE_DAYS" -gt 0 ] && printf 'Zusätzlich löschen: älter als %s Tage\n' "$MAX_AGE_DAYS"
[ "$APPLY" = "1" ] && printf 'Modus:      löschen\n' || printf 'Modus:      Trockenlauf (--apply löscht)\n'
printf '\n'

# Neueste zuerst; der Rang entscheidet, was bleibt.
while IFS=' ' read -r mtime path; do
  [ -n "$path" ] || continue
  total=$((total + 1))
  size="$(du -sk "$path" | awk '{print $1}')"
  rank=$((total))
  age_days=$(( (now - mtime) / 86400 ))
  drop=0
  [ "$rank" -gt "$KEEP" ] && drop=1
  [ "$MAX_AGE_DAYS" -gt 0 ] && [ "$age_days" -gt "$MAX_AGE_DAYS" ] && drop=1
  if [ "$drop" = "1" ]; then
    would_delete=$((would_delete + 1))
    deleted_bytes=$((deleted_bytes + size))
    printf '  löschen  %s  (%s Tage, %s KB)\n' "$(basename "$path")" "$age_days" "$size"
    if [ "$APPLY" = "1" ]; then
      rm -rf "$path"
    fi
  fi
done < <(
  find "$ARTIFACTS" -mindepth 1 -maxdepth 1 -type d -print0 |
    xargs -0 stat -f '%m %N' |
    sort -rn
)

printf '\n%s Verzeichnisse gesamt, %s zum Löschen (%s MB)\n' \
  "$total" "$would_delete" "$((deleted_bytes / 1024))"
if [ "$APPLY" = "1" ]; then
  printf '✔ gelöscht\n'
else
  printf 'ℹ Trockenlauf – mit --apply ausführen\n'
fi
