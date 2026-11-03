#!/usr/bin/env bash
# safe-claude-ru (Linux): Claude только через прокси, без утечки настоящего IP.
#
#   ./install.sh                — kill-switch + Claude Code через прокси
#   ./install.sh killswitch     — только блокировка прямого доступа к Claude
#   ./install.sh claude-code    — прокси для Claude Code (+ установка, если его нет)
#   ./install.sh firefox        — отдельный профиль Firefox «только через прокси»
#   ./install.sh proxyonly      — «жёсткий режим»: команда proxyonly <программа>
#   ./install.sh codex          — Codex CLI всегда в жёстком режиме (нужен proxyonly)
#   ./install.sh remove         — убрать kill-switch и жёсткий режим
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
  mkdir -p ~/.claude ~/.local/bin
  install -m 755 "$HERE/ffp-open" ~/.local/bin/ffp-open
  python3 - "$PROXY" "$HOME/.local/bin/ffp-open" <<'PY'
import json, os, sys
proxy, opener = sys.argv[1], sys.argv[2]; p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
d.setdefault("env", {}).update({"HTTPS_PROXY": proxy, "HTTP_PROXY": proxy,
                                "NO_PROXY": "localhost,127.0.0.1,::1",
                                # вход в аккаунт откроется в Firefox «через прокси», а не в обычном браузере
                                "BROWSER": opener})
json.dump(d, open(p, "w"), indent=2)
PY
  ok "Прокси и браузер для входа прописаны в ~/.claude/settings.json"

  if ! command -v claude >/dev/null && [[ ! -x ~/.local/bin/claude ]]; then
    info "Claude Code не найден — ставлю через прокси"
    # socks5h:// установщик не понимает и зависает — только HTTP-прокси
    HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  fi
  if [[ -x ~/.local/bin/claude ]]; then ok "$(~/.local/bin/claude --version)"; fi
  [[ -n "$(ls -d ~/snap/firefox/common/.mozilla/firefox/claude-proxy.profile ~/.mozilla/firefox/claude-proxy.profile 2>/dev/null)" ]] \
    || warn "Для входа через браузер создай профиль: ./install.sh firefox"
}

mod_firefox() {
  local base=~/snap/firefox/common/.mozilla/firefox
  [[ -d $base ]] || base=~/.mozilla/firefox
  [[ -d $base ]] || die "Firefox не найден. Запусти его один раз и повтори."
  mkdir -p "$base/claude-proxy.profile" ~/.local/bin
  sed "s/10808/$PROXY_PORT/" "$HERE/firefox-proxy-user.js" > "$base/claude-proxy.profile/user.js"
  install -m 755 "$HERE/ffp-open" ~/.local/bin/ffp-open
  ok "Профиль создан: $base/claude-proxy.profile"
  echo "  Запуск: ffp-open   (или firefox --new-instance --profile $base/claude-proxy.profile)"
  echo "  Без прокси этот Firefox не откроет ни одного сайта — так и задумано."
}

mod_proxyonly() {
  command -v systemd-run >/dev/null || die "Нужен systemd."
  [[ -d /sys/fs/cgroup/user.slice ]] || die "Нужна cgroup v2 (есть во всех свежих дистрибутивах)."
  info "Жёсткий режим: программа видит интернет ТОЛЬКО через прокси"
  sudo apt-get install -y -qq xdg-dbus-proxy >/dev/null 2>&1 || command -v xdg-dbus-proxy >/dev/null \
    || warn "Нет xdg-dbus-proxy — Electron/Chromium-программы смогут выйти из песочницы (см. README)."
  local uid; uid="$(id -u)"
  sudo install -m 755 "$HERE/proxyonly-apply" /usr/local/sbin/proxyonly-apply
  echo "$(id -un) ALL=(root) NOPASSWD: /usr/local/sbin/proxyonly-apply $uid" | sudo tee /etc/sudoers.d/91-proxyonly >/dev/null
  sudo chmod 440 /etc/sudoers.d/91-proxyonly
  sudo visudo -cf /etc/sudoers.d/91-proxyonly >/dev/null || { sudo rm -f /etc/sudoers.d/91-proxyonly; die "sudoers не прошёл проверку"; }
  mkdir -p ~/.local/bin ~/.local/share/proxyonly/bin ~/.config/systemd/user
  install -m 755 "$HERE/proxyonly" ~/.local/bin/proxyonly
  install -m 755 "$HERE/proxyonly-xdg-open" ~/.local/share/proxyonly/bin/xdg-open
  install -m 755 "$HERE/ffp-open" ~/.local/bin/ffp-open
  install -m 644 "$HERE/proxyonly-anchor.service" ~/.config/systemd/user/proxyonly-anchor.service
  systemctl --user daemon-reload
  systemctl --user enable --now proxyonly-anchor.service >/dev/null 2>&1
  systemctl --user restart proxyonly-anchor.service
  check_proxy
  if ~/.local/bin/proxyonly curl -s -m 8 -o /dev/null --noproxy '*' https://ipinfo.io/ip; then
    warn "Из proxyonly прямой выход ОТКРЫТ — что-то не так, проверь: sudo nft list table inet proxyonly"
  else
    ok "Из proxyonly напрямую — заблокировано"
  fi
  ok "Через прокси из proxyonly: $(~/.local/bin/proxyonly curl -s -m 10 https://ipinfo.io/ip)"
  echo "  Использование: proxyonly <программа>   например: proxyonly code, proxyonly firefox"
}

mod_codex() {
  [[ -x ~/.local/bin/proxyonly ]] || die "Сначала: ./install.sh proxyonly"
  local real; real="$(command -v codex 2>/dev/null || true)"
  [[ "$real" == "$HOME/.local/bin/codex" ]] && real="$(PATH="${PATH//$HOME\/.local\/bin:/}" command -v codex || true)"
  if [[ -z "$real" ]]; then
    info "Codex не найден — ставлю через npm"
    command -v npm >/dev/null || die "Нужен Node.js/npm."
    sudo npm install -g @openai/codex >/dev/null
    real="$(PATH="${PATH//$HOME\/.local\/bin:/}" command -v codex)"
  fi
  printf '#!/bin/sh\n# Codex всегда в жёстком режиме: в интернет только через прокси.\nexec "$HOME/.local/bin/proxyonly" %s "$@"\n' "$real" > ~/.local/bin/codex
  chmod +x ~/.local/bin/codex
  ok "codex → proxyonly $real ($("$real" --version 2>/dev/null))"
  warn "~/.local/bin должен стоять в PATH раньше /usr/bin (в Ubuntu так по умолчанию после перелогина)."
}

mod_remove() {
  sudo systemctl disable --now claude-killswitch 2>/dev/null || true
  sudo rm -f /etc/claude-killswitch.nft /etc/systemd/system/claude-killswitch.service
  sudo systemctl daemon-reload
  systemctl --user disable --now proxyonly-anchor.service 2>/dev/null || true
  rm -f ~/.config/systemd/user/proxyonly-anchor.service ~/.local/bin/proxyonly ~/.local/share/proxyonly/bin/xdg-open
  sudo nft delete table inet proxyonly 2>/dev/null || true
  sudo rm -f /usr/local/sbin/proxyonly-apply /etc/sudoers.d/91-proxyonly
  ok "Kill-switch и жёсткий режим удалены. Прокси в ~/.claude/settings.json оставлен — убери блок env вручную, если нужно."
}

if [[ $# -eq 0 ]]; then set -- killswitch claude-code; fi
for m in "$@"; do
  declare -F "mod_$m" >/dev/null || die "Нет такой команды: $m (есть: killswitch, claude-code, firefox, proxyonly, codex, remove)"
  "mod_$m"
done
