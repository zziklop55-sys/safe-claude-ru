#!/usr/bin/env bash
# safe-claude-ru — настройка Ubuntu 24.04 для жизни в России.
# Запуск:  ./install.sh            — меню
#          ./install.sh base sway  — только нужные модули
# Модули: base zapret sway killswitch firefox dev osint wifi-ath9k
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZAPRET_VER="${ZAPRET_VER:-v1.0.6}"
PROXY_PORT="${PROXY_PORT:-10808}"

c_ok() { printf '\e[32m%s\e[0m\n' "$*"; }
c_info() { printf '\e[36m==> %s\e[0m\n' "$*"; }
c_warn() { printf '\e[33m%s\e[0m\n' "$*"; }
ask() { read -rp "$1 [y/N] " a; [[ "$a" =~ ^[YyДд] ]]; }

[[ $EUID -eq 0 ]] && { echo "Запускай от обычного пользователя, sudo скрипт спросит сам."; exit 1; }
grep -q 'VERSION_ID="24.04"' /etc/os-release || c_warn "Скрипт проверялся на Ubuntu 24.04, у тебя другая версия."

apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; }

# ---------------------------------------------------------------- base
mod_base() {
  c_info "Обновление системы и базовые пакеты"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y -qq full-upgrade
  apt_install curl wget git htop btop jq tree unzip ripgrep fd-find iw ufw zram-tools smartmontools net-tools

  c_info "zram: сжатая подкачка в памяти (заметно помогает на 4–8 ГБ)"
  printf 'ALGO=zstd\nPERCENT=50\nPRIORITY=100\n' | sudo tee /etc/default/zramswap >/dev/null
  printf 'vm.swappiness=150\nvm.page-cluster=0\n' | sudo tee /etc/sysctl.d/99-zram.conf >/dev/null
  sudo sysctl -q --system; sudo systemctl restart zramswap

  c_info "Файрвол: входящие запрещены, SSH — только из домашней сети"
  local net; net="$(ip -4 route | awk '/proto kernel/ && !/docker|virbr/ {print $1; exit}')"
  sudo ufw default deny incoming >/dev/null; sudo ufw default allow outgoing >/dev/null
  [[ -n "$net" ]] && sudo ufw allow from "$net" to any port 22 proto tcp >/dev/null
  sudo ufw --force enable >/dev/null

  c_info "Ускорение загрузки: отключить cloud-init и ожидание сети"
  sudo touch /etc/cloud/cloud-init.disabled
  sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
  c_ok "base готов"
}

# ---------------------------------------------------------------- zapret2
mod_zapret() {
  c_info "zapret2 $ZAPRET_VER (обход DPI для YouTube, Discord и т.д.)"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/z.tgz" "https://github.com/bol-van/zapret2/releases/download/$ZAPRET_VER/zapret2-$ZAPRET_VER.tar.gz"
  curl -fsSL -o "$tmp/sums" "https://github.com/bol-van/zapret2/releases/download/$ZAPRET_VER/sha256sum.txt"
  tar xzf "$tmp/z.tgz" -C "$tmp"
  (cd "$tmp" && grep "linux-x86_64" sums | sha256sum -c --quiet -) || { echo "Контрольные суммы не сошлись"; exit 1; }
  sudo rm -rf /opt/zapret2; sudo cp -a "$tmp/zapret2-$ZAPRET_VER" /opt/zapret2
  (cd /opt/zapret2 && sudo ./install_bin.sh >/dev/null)
  sudo cp /opt/zapret2/config.default /opt/zapret2/config
  sudo sed -i -e 's/^NFQWS2_ENABLE=0/NFQWS2_ENABLE=1/' -e 's/^MODE_FILTER=none/MODE_FILTER=autohostlist/' /opt/zapret2/config
  sudo cp "$HERE/system/zapret-hosts-user.txt" /opt/zapret2/ipset/zapret-hosts-user.txt
  sudo cp /opt/zapret2/ipset/zapret-hosts-user-exclude.txt.default /opt/zapret2/ipset/zapret-hosts-user-exclude.txt
  c_warn "ВАЖНО: если пользуешься VPN с маскировкой (VLESS Reality), впиши SNI и IP своего сервера в"
  c_warn "  /opt/zapret2/ipset/zapret-hosts-user-exclude.txt — иначе zapret сломает VPN (см. README)."
  sudo cp /opt/zapret2/init.d/systemd/zapret2.service /etc/systemd/system/
  sudo systemctl daemon-reload; sudo systemctl enable --now zapret2
  rm -rf "$tmp"
  c_ok "zapret2 запущен: systemctl status zapret2"
}

# ---------------------------------------------------------------- sway
mod_sway() {
  c_info "Sway + Waybar + Wofi + Kitty + Mako"
  apt_install sway swaybg swayidle swaylock waybar wofi kitty mako-notifier grim slurp wl-clipboard \
    brightnessctl pavucontrol network-manager-gnome policykit-1-gnome xdg-desktop-portal-wlr fonts-noto-color-emoji

  c_info "Шрифт FantasqueSansM Nerd Font"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/f.zip" https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FantasqueSansMono.zip
  mkdir -p ~/.local/share/fonts/FantasqueNerd && unzip -oq "$tmp/f.zip" -d ~/.local/share/fonts/FantasqueNerd && fc-cache -f

  c_info "fastfetch (последний релиз с GitHub)"
  curl -fsSL -o "$tmp/ff.deb" https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.deb
  sudo apt-get install -y -qq "$tmp/ff.deb" >/dev/null; rm -rf "$tmp"

  c_info "Конфиги (старые сохраняются как *.bak-<время>)"
  local ts; ts="$(date +%s)"
  for d in sway waybar wofi mako kitty fastfetch; do
    [[ -e ~/.config/$d ]] && cp -a ~/.config/$d ~/.config/$d.bak-$ts
    mkdir -p ~/.config/$d; cp -r "$HERE/configs/$d/." ~/.config/$d/
  done
  mkdir -p "$(xdg-user-dir PICTURES 2>/dev/null || echo ~/Pictures)"
  c_ok "Готово. Выйди из системы, на экране входа нажми шестерёнку и выбери Sway."
}

# ---------------------------------------------------------------- killswitch
mod_killswitch() {
  c_info "Kill-switch: Claude/Anthropic только через прокси"
  sudo cp "$HERE/system/claude-killswitch.nft" /etc/claude-killswitch.nft
  sudo cp "$HERE/system/claude-killswitch.service" /etc/systemd/system/
  sudo systemctl daemon-reload; sudo systemctl enable --now claude-killswitch
  if curl -s -o /dev/null -m 6 https://claude.ai/; then c_warn "claude.ai напрямую открылся — проверь адреса в /etc/claude-killswitch.nft"
  else c_ok "claude.ai напрямую заблокирован"; fi

  c_info "Claude Code: весь его трафик (и обновления) через прокси 127.0.0.1:$PROXY_PORT"
  mkdir -p ~/.claude
  python3 - "$PROXY_PORT" <<'PY'
import json, os, sys
port = sys.argv[1]; p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
d.setdefault("env", {}).update({"HTTPS_PROXY": f"http://127.0.0.1:{port}",
                                "HTTP_PROXY": f"http://127.0.0.1:{port}",
                                "NO_PROXY": "localhost,127.0.0.1,::1"})
json.dump(d, open(p, "w"), indent=2)
PY
  c_ok "Прокси прописан в ~/.claude/settings.json (нужен смешанный SOCKS+HTTP порт, как у Happ)"
}

# ---------------------------------------------------------------- firefox
mod_firefox() {
  c_info "Отдельный профиль Firefox «только через прокси» (команда: ffp)"
  local base=~/snap/firefox/common/.mozilla/firefox
  [[ -d $base ]] || base=~/.mozilla/firefox
  mkdir -p "$base/proxy.profile"
  sed "s/10808/$PROXY_PORT/" "$HERE/firefox/user.js" > "$base/proxy.profile/user.js"
  echo
  c_ok "Профиль: $base/proxy.profile"
  echo "Добавь себе команду (один раз):"
  echo "  echo \"alias ffp='setsid firefox --new-instance --profile $base/proxy.profile >/dev/null 2>&1 &'\" >> ~/.bashrc && source ~/.bashrc"
}

# ---------------------------------------------------------------- dev
mod_dev() {
  c_info "Для разработки: компиляторы, Python, Node.js 22, VS Code"
  apt_install build-essential python3-venv python3-pip pipx
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null && apt_install nodejs
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/code.deb" "https://update.code.visualstudio.com/latest/linux-deb-x64/stable" && sudo apt-get install -y -qq "$tmp/code.deb"
  rm -rf "$tmp"
  c_ok "node $(node -v), $(code --version 2>/dev/null | head -1 | sed 's/^/VS Code /')"
  c_warn "Claude Code ставь через прокси: HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT curl -fsSL https://claude.ai/install.sh | bash"
}

# ---------------------------------------------------------------- osint
mod_osint() {
  c_info "OSINT: nmap, whois, dig, exiftool + sherlock, maigret, holehe"
  apt_install nmap whois dnsutils libimage-exiftool-perl pipx
  pipx ensurepath >/dev/null
  for p in sherlock-project maigret holehe; do pipx install -q "$p" || true; done
  c_warn "Используй только в законных целях: свои аккаунты, открытые данные, учебные задания."
}

# ---------------------------------------------------------------- wifi-ath9k
mod_wifi-ath9k() {
  if ! lsmod | grep -q '^ath9k '; then c_warn "Драйвер ath9k не найден — модуль не нужен."; return; fi
  c_info "Фикс обрывов Wi-Fi для Atheros AR9xxx (ath9k)"
  echo "options ath9k btcoex_enable=1 ps_enable=0 nohwcrypt=1" | sudo tee /etc/modprobe.d/ath9k-fix.conf >/dev/null
  printf '[connection]\nwifi.powersave = 2\n' | sudo tee /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf >/dev/null
  c_ok "Применится после перезагрузки. Ещё помогает: канал 20 МГц и канал 1/6/11 в роутере."
}

# ---------------------------------------------------------------- main
SEL=()
ALL=(base zapret sway killswitch firefox dev osint wifi-ath9k)
declare -A DESC=(
  [base]="обновления, утилиты, zram, файрвол, быстрая загрузка"
  [zapret]="zapret2 — обход блокировок YouTube/Discord без VPN"
  [sway]="лёгкий тайловый рабочий стол (Sway) с готовым оформлением"
  [killswitch]="Claude только через прокси, прямой доступ заблокирован"
  [firefox]="отдельный Firefox, работающий только через прокси"
  [dev]="Python, Node.js 22, VS Code"
  [osint]="nmap, sherlock, maigret, holehe и др."
  [wifi-ath9k]="фикс обрывов Wi-Fi на старых Atheros"
)

if [[ $# -gt 0 ]]; then
  for m in "$@"; do declare -F "mod_$m" >/dev/null || { echo "Нет модуля: $m"; exit 1; }; "mod_$m"; done
  exit 0
fi

echo "safe-claude-ru — выбери, что ставить:"
for m in "${ALL[@]}"; do
  if ask "  $m — ${DESC[$m]}?"; then SEL+=("$m"); fi
done
[[ ${#SEL[@]} -eq 0 ]] && { echo "Ничего не выбрано."; exit 0; }
for m in "${SEL[@]}"; do "mod_$m"; done
c_ok "Всё. Шпаргалка по Linux: docs/linux-cheatsheet.md"
