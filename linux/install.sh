#!/usr/bin/env bash
# safe-claude-ru (Linux): Claude только через прокси, без утечки настоящего IP.
#
#   ./install.sh                — всё: kill-switch + Claude Code через прокси
#   ./install.sh killswitch     — только блокировка прямого доступа
#   ./install.sh claude-code    — только прокси для Claude Code (+ установка, если его нет)
#   ./install.sh firefox        — отдельный профиль Firefox «только через прокси»
#   ./install.sh remove         — убрать kill-switch
#
# Порт прокси по умолчанию 10808 (Happ). Другой: PROXY_PORT=2080 ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROXY_PORT="${PROXY_PORT:-10808}"
PROXY="http://127.0.0.1:$PROXY_PORT"

ok()   { printf '\e[32m✔ %s\e[0m\n' "$*"; }
info() { printf '\e[36m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[33m! %s\e[0m\n' "$*"; }
die()  { printf '\e[31m✖ %s\e[0m\n' "$*"; exit 1; }

[[ $EUID -eq 0 ]] && die "Запускай от обычного пользователя, sudo скрипт спросит сам."
command -v nft >/dev/null || die "Нужен nftables: sudo apt install nftables"

check_proxy() {
  local ip
  ip="$(curl -s -m 10 -x "$PROXY" https://ipinfo.io/ip || true)"
  [[ -n "$ip" ]] || die "Прокси $PROXY не отвечает. Включи VPN-клиент (режим «только прокси») и повтори."
  ok "Прокси работает, выход через $ip"
}

mod_killswitch() {
  info "Kill-switch: прямые подключения к Claude/Anthropic запрещены"
  sudo install -m 644 "$HERE/claude-killswitch.nft" /etc/claude-killswitch.nft
  sudo install -m 644 "$HERE/claude-killswitch.service" /etc/systemd/system/claude-killswitch.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now claude-killswitch >/dev/null 2>&1
  sudo systemctl restart claude-killswitch
  if curl -s -o /dev/null -m 6 https://claude.ai/; then
    warn "claude.ai напрямую ОТКРЫЛСЯ. Проверь адреса: getent ahostsv4 claude.ai downloads.claude.ai"
    warn "и сравни с /etc/claude-killswitch.nft. Если включён TUN в VPN-клиенте — это нормально."
  else
    ok "claude.ai напрямую заблокирован"
  fi
}

mod_claude-code() {
  check_proxy
  info "Claude Code: весь трафик, включая обновления, через $PROXY"
  mkdir -p ~/.claude
  python3 - "$PROXY" <<'PY'
import json, os, sys
proxy = sys.argv[1]; p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
d.setdefault("env", {}).update({"HTTPS_PROXY": proxy, "HTTP_PROXY": proxy,
                                "NO_PROXY": "localhost,127.0.0.1,::1"})
json.dump(d, open(p, "w"), indent=2)
PY
  ok "Прокси прописан в ~/.claude/settings.json"

  if ! command -v claude >/dev/null && [[ ! -x ~/.local/bin/claude ]]; then
    info "Claude Code не найден — ставлю через прокси"
    # socks5h:// установщик не понимает и зависает — только HTTP-прокси
    HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  fi
  if [[ -x ~/.local/bin/claude ]]; then ok "$(~/.local/bin/claude --version)"; fi
}

mod_firefox() {
  local base=~/snap/firefox/common/.mozilla/firefox
  [[ -d $base ]] || base=~/.mozilla/firefox
  [[ -d $base ]] || die "Firefox не найден. Запусти его один раз и повтори."
  mkdir -p "$base/claude-proxy.profile"
  sed "s/10808/$PROXY_PORT/" "$HERE/firefox-proxy-user.js" > "$base/claude-proxy.profile/user.js"
  ok "Профиль создан: $base/claude-proxy.profile"
  echo "  Запуск: firefox --new-instance --profile $base/claude-proxy.profile"
  echo "  Без прокси этот Firefox не откроет ни одного сайта — так и задумано."
}

mod_remove() {
  sudo systemctl disable --now claude-killswitch 2>/dev/null || true
  sudo rm -f /etc/claude-killswitch.nft /etc/systemd/system/claude-killswitch.service
  sudo systemctl daemon-reload
  ok "Kill-switch удалён. Прокси в ~/.claude/settings.json оставлен — убери блок env вручную, если нужно."
}

if [[ $# -eq 0 ]]; then set -- killswitch claude-code; fi
for m in "$@"; do
  declare -F "mod_$m" >/dev/null || die "Нет такой команды: $m (есть: killswitch, claude-code, firefox, remove)"
  "mod_$m"
done
