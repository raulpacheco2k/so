#!/usr/bin/env bash
# Fecha o walker quando ele perde o foco ou recebe um clique fora da janela.
# No X11/i3 o click_to_close do walker nao captura cliques no wallpaper.
set -u

WALKER_CLASS="walker"
WALKER="${WALKER_BIN:-$HOME/.local/bin/walker}"
LOCK="/tmp/walker-close-on-blur.lock"
CLOSE_LOCK="/tmp/walker-close-on-blur.close.lock"
CLOSE_STAMP="/tmp/walker-close-on-blur.close.stamp"

# Mantem um lock de processo para impedir acumulacao quando o i3 faz reload.
exec 9>"$LOCK"
flock -n 9 || exit 0

walker_window() {
  local c w h
  for c in $(xdotool search --onlyvisible --class "$WALKER_CLASS" 2>/dev/null); do
    read -r w h <<< "$(xdotool getwindowgeometry "$c" 2>/dev/null | awk -F'x' '/Geometry:/ {gsub(/[^0-9]/,"",$1); gsub(/[^0-9]/,"",$2); print $1, $2}')"
    if [ -n "${w:-}" ] && [ "$w" -gt 100 ] 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

close_walker() {
  local now last wid

  wid=$(walker_window) || return 0

  (
    flock -n 9 || exit 0

    now=$(date +%s%3N)
    last=$(cat "$CLOSE_STAMP" 2>/dev/null || printf '0')
    if [ "$((now - last))" -lt 300 ] 2>/dev/null; then
      exit 0
    fi

    printf '%s\n' "$now" > "$CLOSE_STAMP"
    "$WALKER" >/dev/null 2>&1
  ) 9>"$CLOSE_LOCK"
}

# xinput observa botoes do mouse, touchpad e eventos XTEST. Isso cobre o
# clique no wallpaper, que nao muda o foco no i3.
monitor_pointer() {
  local device="$1"

  xinput test "$device" 2>/dev/null | while IFS= read -r event; do
    case "$event" in
      button\ press*)
        wid=$(walker_window) || continue
        pointer_window=$(xdotool getmouselocation --shell 2>/dev/null | awk -F= '$1 == "WINDOW" {print $2}')
        [ "$pointer_window" = "$wid" ] && continue
        close_walker
        ;;
    esac
  done
}

# Inclui o dispositivo XTEST para cliques sinteticos e os dispositivos reais
# de ponteiro presentes nesta sessao.
for device in $(xinput list --short 2>/dev/null | awk '/slave +pointer/ {match($0, /id=[0-9]+/); if (RSTART) print substr($0, RSTART + 3, RLENGTH - 3)}'); do
  monitor_pointer "$device" &
done

i3-msg -t subscribe -m '["window"]' 2>/dev/null | while IFS= read -r event; do
  change=$(printf '%s' "$event" | jq -r '.change // empty')
  [ "$change" != "focus" ] && continue

  wid=$(walker_window) || continue
  focused=$(xdotool getactivewindow 2>/dev/null) || continue

  if [ -n "$focused" ] && [ "$focused" != "$wid" ]; then
    close_walker
  fi
done
