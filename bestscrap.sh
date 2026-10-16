#!/usr/bin/env bash
# BestScrap: poll Best Buy Canada for in-store pickup stock.
# Needs curl and the usual POSIX tools (sed, awk, grep, sort). Nothing else.

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG="$DIR/config.yml"
DATA="$DIR/data"
STORES="$DATA/stores.tsv"
BASE="https://www.bestbuy.ca"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
TAB=$(printf '\t')

usage() {
  cat <<EOF
usage: bestscrap.sh [command]

  watch    poll forever, report changes, play a sound when stock appears (default)
  once     check once; exit 0 if anything is in stock, 1 if not, 2 on error
  sync     rebuild the store list for the provinces in config.yml
  stores   print the cached store list
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
log() { printf '[%s] %s\n' "$(LC_ALL=C date '+%-d %b. %H:%M:%S')" "$*"; }

# ---- config -----------------------------------------------------------------

has_key() { [ -f "$CONFIG" ] && grep -q "^$1:" "$CONFIG"; }

cfg() {
  [ -f "$CONFIG" ] || return 0
  tr -d '\r' < "$CONFIG" | sed -n "s/^$1:[[:space:]]*//p" | head -1 |
    sed -e 's/^#.*//' -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' \
        -e "s/^[\"']//" -e "s/[\"']\$//"
}

load_config() {
  [ -f "$CONFIG" ] || die "no config.yml; copy example.config.yml to config.yml first"
  SKU=$(cfg sku)
  [ -n "$SKU" ] || die "sku is not set in config.yml"
  PROVS=$(cfg provinces | tr 'a-z,[]' 'A-Z   ' | tr -s ' ' | sed 's/^ //; s/ $//')
  [ -n "$PROVS" ] || die "provinces is not set in config.yml (e.g. QC, or ALL)"
  PROV_KEY=",$(printf '%s' "$PROVS" | tr ' ' ','),"
  INTERVAL=$(cfg interval)
  INTERVAL=${INTERVAL:-45}
  case $INTERVAL in ''|*[!0-9]*) die "interval must be a number of seconds" ;; esac
  [ "$INTERVAL" -ge 10 ] || die "interval must be at least 10 seconds"
  if has_key sound; then SOUND=$(cfg sound); else SOUND="sounds/alert.wav"; fi
  case $SOUND in ''|/*) ;; *) SOUND="$DIR/$SOUND" ;; esac
  EXTRA=$(cfg extra_seeds)
}

# ---- store discovery --------------------------------------------------------

fetch_locations() { # $1 = city or postal code
  if printf '%s' "$1" | grep -Eq '^[A-Za-z][0-9][A-Za-z] ?[0-9][A-Za-z][0-9]$'; then k=postalCode; else k=city; fi
  curl -sf -m 90 --retry 2 --retry-delay 2 -G -A "$UA" --data-urlencode "$k=$1" \
    "$BASE/api/v2/json/locations?lang=en&showOnlyStores=true"
}

# JSON on stdin -> id, name, city, postal code, province, address, phone (tab separated).
# Relies on each location listing address1 first and region last.
parse_locations() {
  grep -oE '"(address1|phone1|city|locationId|name|postalCode|region)":("([^"\\]|\\.)*"|null)' |
  awk '
    {
      i = index($0, "\":"); key = substr($0, 2, i - 2); v = substr($0, i + 2)
      if (v == "null") v = ""; else v = substr(v, 2, length(v) - 2)
      if (key == "address1") { addr = v; id = name = city = zip = phone = "" }
      else if (key == "phone1") phone = v
      else if (key == "city") city = v
      else if (key == "locationId") id = v
      else if (key == "name") name = v
      else if (key == "postalCode") zip = v
      else if (key == "region") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, name, city, zip, v, addr, phone
    }'
}

sync_stores() {
  mkdir -p "$DATA"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/bestscrap.XXXXXX") || die "mktemp failed"
  awk -v provs="$PROV_KEY" '
    /^[ \t]*#/ || NF == 0 { next }
    { p = $1; sub(/^[^ \t]+[ \t]+/, ""); if (provs == ",ALL," || index(provs, "," p ",")) print }
  ' "$DIR/seeds.txt" > "$tmp/seeds"
  if [ -n "$EXTRA" ]; then
    printf '%s' "$EXTRA" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . >> "$tmp/seeds"
  fi
  [ -s "$tmp/seeds" ] || { rm -rf "$tmp"; die "no seeds for provinces: $PROVS"; }

  total=$(wc -l < "$tmp/seeds" | tr -d ' ')
  log "Finding stores in $PROVS ($total lookups, this takes a minute)"
  i=0
  while IFS= read -r seed; do
    i=$((i + 1))
    ( fetch_locations "$seed" > "$tmp/$i.json" 2>/dev/null || : ) &
    [ $((i % 8)) -eq 0 ] && wait
  done < "$tmp/seeds"
  wait

  cat "$tmp"/*.json 2>/dev/null | parse_locations |
    awk -F'\t' -v provs="$PROV_KEY" 'provs == ",ALL," || index(provs, "," $5 ",")' |
    sort -t "$TAB" -k1,1 -u > "$tmp/stores.tsv"
  if [ ! -s "$tmp/stores.tsv" ]; then rm -rf "$tmp"; die "no stores found (network down or rate limited?)"; fi
  mv "$tmp/stores.tsv" "$STORES"
  printf '%s|%s\n' "$PROV_KEY" "$EXTRA" > "$DATA/stores.key"
  rm -rf "$tmp"
  log "Found $(wc -l < "$STORES" | tr -d ' ') stores"
}

ensure_stores() {
  if [ ! -s "$STORES" ] || [ "$(cat "$DATA/stores.key" 2>/dev/null)" != "$PROV_KEY|$EXTRA" ]; then
    sync_stores
  fi
}

# ---- availability -----------------------------------------------------------

product_info() {
  body=$(curl -sf -m 30 -A "$UA" "$BASE/api/v2/json/product/$SKU") || return 1
  PNAME=$(printf '%s' "$body" | grep -o '"name":"[^"]*"' | head -1 | sed 's/^"name":"//; s/"$//')
  PPRICE=$(printf '%s' "$body" | grep -o '"salePrice":[0-9.]*' | head -1 | sed 's/.*://')
  [ -n "$PNAME" ]
}

# Writes id, quantity, reservable for every store with stock to $1. Returns 1 on any failure.
check() {
  : > "$1"
  POSTAL=$(head -1 "$STORES" | cut -f4 | tr -d ' ')
  cut -f1 "$STORES" | xargs -n 25 | tr ' ' '|' | while IFS= read -r locs; do
    resp=$(curl -sf -m 30 -G -A "$UA" \
      --data-urlencode "accept=application/vnd.bestbuy.standardproduct.v1+json" \
      --data-urlencode "accept-language=en-CA" \
      --data-urlencode "locations=$locs" \
      --data-urlencode "postalCode=$POSTAL" \
      --data-urlencode "skus=$SKU" \
      "$BASE/ecomm-api/availability/products") || exit 1
    case $resp in *'"availabilities"'*) ;; *) exit 1 ;; esac
    printf '%s' "$resp" | tr '{}' '\n\n' | awk '
      function val(s, k,  m) {
        if (match(s, "\"" k "\":(\"[^\"]*\"|[^,}]*)")) {
          m = substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3); gsub(/"/, "", m); return m
        }
        return ""
      }
      /"locationKey"/ {
        q = val($0, "quantityOnHand") + 0; r = val($0, "isReservable"); h = val($0, "hasInventory")
        if (q > 0 || r == "true" || h == "true") print val($0, "locationKey") "\t" q "\t" r
      }' >> "$1"
  done
}

# Compares previous and current stock; prints one line per change.
diff_stock() { # $1 prev, $2 cur, $3 first (1/0)
  awk -F'\t' -v first="$3" '
    function label(id) { return name[id] " (" city[id] " " zip[id] ")" }
    FILENAME == ARGV[1] { name[$1] = $2; city[$1] = $3; zip[$1] = $4; addr[$1] = $6; ph[$1] = $7; next }
    FILENAME == ARGV[2] { pq[$1] = $2; next }
    { cq[$1] = $2; cr[$1] = $3 }
    END {
      for (id in cq) if (!(id in pq))
        printf "%s: %s %s %s - qty %s%s\n", (first ? "IN STOCK" : "NEW STOCK"), label(id), addr[id], ph[id], cq[id], (cr[id] == "true" ? ", reservable" : "")
      for (id in pq) if (!(id in cq)) printf "GONE: %s no longer available\n", label(id)
      for (id in cq) if ((id in pq) && pq[id] != cq[id]) printf "QTY CHANGE: %s %s -> %s\n", label(id), pq[id], cq[id]
    }' "$STORES" "$1" "$2"
}

# ---- sound ------------------------------------------------------------------

play_sound() {
  if [ -z "$SOUND" ] || [ ! -f "$SOUND" ]; then printf '\a'; return; fi
  # WSL / Git Bash: play through Windows. WSL often leaves Windows dirs off PATH.
  ps=$(command -v powershell.exe 2>/dev/null)
  [ -n "$ps" ] || { [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ] &&
    ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; }
  if [ -n "$ps" ]; then
    w=""
    if command -v wslpath >/dev/null 2>&1; then w=$(wslpath -w "$SOUND")
    elif command -v cygpath >/dev/null 2>&1; then w=$(cygpath -w "$SOUND"); fi
    if [ -n "$w" ]; then
      "$ps" -NoProfile -Command "(New-Object Media.SoundPlayer '$w').PlaySync()" >/dev/null 2>&1 &
      return
    fi
  fi
  if command -v afplay >/dev/null 2>&1; then afplay "$SOUND" >/dev/null 2>&1 &
  elif command -v paplay >/dev/null 2>&1; then paplay "$SOUND" >/dev/null 2>&1 &
  elif command -v aplay >/dev/null 2>&1; then aplay -q "$SOUND" >/dev/null 2>&1 &
  elif command -v play >/dev/null 2>&1; then play -q "$SOUND" >/dev/null 2>&1 &
  elif command -v ffplay >/dev/null 2>&1; then ffplay -nodisp -autoexit -loglevel quiet "$SOUND" >/dev/null 2>&1 &
  elif command -v mpv >/dev/null 2>&1; then mpv --no-video --really-quiet "$SOUND" >/dev/null 2>&1 &
  else printf '\a'; fi
}

# ---- main -------------------------------------------------------------------

run() { # $1 = watch | once
  load_config
  ensure_stores
  if product_info; then
    log "Watching: $PNAME (SKU $SKU, \$$PPRICE) in $(wc -l < "$STORES" | tr -d ' ') stores, every ${INTERVAL}s"
  else
    die "could not load SKU $SKU (wrong SKU, or Best Buy unreachable)"
  fi
  mkdir -p "$DATA"
  prev="$DATA/prev.tsv"; cur="$DATA/cur.tsv"; events="$DATA/events.txt"
  : > "$prev"
  first=1
  while :; do
    if check "$cur.new"; then
      mv "$cur.new" "$cur"
      diff_stock "$prev" "$cur" "$first" > "$events"
      if [ -s "$events" ]; then
        alert=0
        while IFS= read -r line; do
          log "$line"
          case $line in "IN STOCK"*|"NEW STOCK"*) alert=1 ;; esac
        done < "$events"
        if [ "$alert" = 1 ]; then
          printf '    reserve: %s/en-ca/reserve-and-pickup/%s\n' "$BASE" "$SKU"
          play_sound
        fi
      elif [ "$first" = 1 ]; then
        log "Nothing in stock right now"
      fi
      mv "$cur" "$prev"
      first=0
    else
      log "check failed, will retry"
      [ "$1" = once ] && exit 2
    fi
    if [ "$1" = once ]; then [ -s "$prev" ] && exit 0 || exit 1; fi
    sleep "$INTERVAL"
  done
}

case "${1:-watch}" in
  watch) run watch ;;
  once)  run once ;;
  sync)  load_config; sync_stores ;;
  stores)
    [ -s "$STORES" ] || die "no store list yet; run: $0 sync"
    awk -F'\t' '{ printf "%-5s %-2s %-8s %-28s %s\n", $1, $5, $4, $2, $3 }' "$STORES" | sort -k2,2 -k5
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
