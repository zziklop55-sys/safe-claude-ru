# safe-claude-ru

Claude и ИИ-инструменты из России **без утечки настоящего IP** + настройка **Ubuntu 24.04** «под ключ»: YouTube и Discord без VPN, лёгкий красивый рабочий стол для старого ноутбука. Kill-switch для Linux и Windows.

Проверено на HP ProBook 4540s (Core i5 3-го поколения, 8 ГБ, Intel HD 4000) — на таком железе всё летает.

![Sway](https://img.shields.io/badge/WM-Sway-5F18B1) ![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420) ![License](https://img.shields.io/badge/license-MIT-blue)

## Что внутри

| Модуль | Что делает |
|---|---|
| `base` | обновления, утилиты (`btop`, `ripgrep`, `jq`…), **zram** (сжатая подкачка), **файрвол** (SSH только из домашней сети), отключение лишнего при загрузке |
| `zapret` | [zapret2](https://github.com/bol-van/zapret2) — обход замедления YouTube, Discord и др. **без VPN**, режим autohostlist (сам находит заблокированные сайты) |
| `sway` | [Sway](https://swaywm.org) — тайловый рабочий стол в духе Hyprland, но лёгкий. Waybar, Wofi, Kitty, Mako, тёмно-фиолетовая тема, шрифт FantasqueSansM Nerd Font |
| `killswitch` | **Claude только через прокси**: прямые подключения к Claude/Anthropic блокируются на уровне системы (nftables), Claude Code и его обновления идут через прокси |
| `firefox` | отдельный профиль Firefox, который ходит **только через прокси** (без прокси — нет интернета, WebRTC выключен) |
| `dev` | Python, Node.js 22, VS Code |
| `osint` | `nmap`, `whois`, `dig`, `exiftool`, `sherlock`, `maigret`, `holehe` |
| `wifi-ath9k` | фикс постоянных обрывов Wi-Fi на старых картах Atheros |

Плюс:
- [`windows/claude-killswitch.ps1`](windows/claude-killswitch.ps1) — тот же kill-switch для Windows;
- [`docs/linux-cheatsheet.md`](docs/linux-cheatsheet.md) — шпаргалка «Linux для тех, кто привык к Windows»: папки, команды, права, горячие клавиши.

## Установка

```bash
sudo apt install -y git
git clone https://github.com/zziklop55-sys/safe-claude-ru.git
cd safe-claude-ru
./install.sh
```

Скрипт спросит про каждый модуль. Можно ставить выборочно:

```bash
./install.sh base zapret sway
```

После модуля `sway`: выйди из системы → на экране входа нажми ⚙️ внизу справа → выбери **Sway**. GNOME остаётся, можно переключаться обратно.

## Горячие клавиши Sway

| Клавиши | Действие |
|---|---|
| `Win+Enter` | терминал |
| `Win+Backspace` | плавающий терминал с fastfetch |
| `Win+D` | меню программ |
| `Win+Q` | закрыть окно |
| `Win+1…9` | рабочие столы |
| `Win+Shift+1…9` | перенести окно на рабочий стол |
| `Alt+Tab` | следующее окно |
| `Win+F` | на весь экран |
| `Win+Space` | плавающее окно ↔ сетка |
| `Win+Shift+S` | скриншот области (в буфер) |
| `Alt+Shift` | раскладка EN/RU |
| `Win+L` | блокировка |
| `Win+Shift+C` | перечитать конфиг |

Полный список — в [шпаргалке](docs/linux-cheatsheet.md) (раздел 11) и в `~/.config/sway/config`.

**Обои:** положи картинку в `~/.config/sway/wallpaper.jpg` и раскомментируй строку `output * bg …` в конфиге.

## Схема «VPN только там, где нужен»

```
Обычный браузер, YouTube, Discord ──► zapret2 ──► напрямую (твой IP, но без блокировок)
Firefox «прокси», Telegram, Claude ──► 127.0.0.1:10808 (VPN-клиент) ──► VPN-сервер за границей
Claude напрямую ─────────────────────► ✖ заблокировано kill-switch'ем
```

VPN-клиент (например, [Happ](https://github.com/Happ-proxy/happ-desktop)) нужно включить в режиме **«только прокси»**: TUN и «системный прокси» **выключены**, локальный порт `10808`. Тогда VPN используют только те программы, которым ты его прописал.

- **Telegram**: Настройки → Продвинутые → Тип соединения → SOCKS5, `127.0.0.1`, порт `10808`.
- **Claude Code**: модуль `killswitch` сам пропишет прокси в `~/.claude/settings.json`.
- **Firefox через прокси**: модуль `firefox`, запуск командой `ffp`. Поставь в двух профилях разные темы — не перепутаешь.

## ⚠️ Грабли, на которые мы наступили

1. **zapret2 ломает VPN с маскировкой (VLESS Reality).** Режим autohostlist видит, что «сайт» (на самом деле VPN-сервер, маскирующийся под `dl.google.com` и т.п.) плохо отвечает, и начинает его «пробивать» — VPN перестаёт работать. Решение: впиши **SNI и IP своего VPN-сервера** в `/opt/zapret2/ipset/zapret-hosts-user-exclude.txt`, удали их из `zapret-hosts-auto.txt` и перезапусти: `sudo systemctl restart zapret2`.
2. **Claude Code обновляется не с серверов Anthropic.** Обновления идут с `downloads.claude.ai` → это Google Cloud (`35.190.46.17`). Если блокировать только сеть Anthropic, обновление пойдёт напрямую и засветит IP. Kill-switch здесь блокирует и этот адрес.
3. **Нативный установщик Claude Code не понимает `socks5h://`** и зависает на шаге `install`. Используй HTTP-прокси: `HTTPS_PROXY=http://127.0.0.1:10808` (у Happ порт смешанный — SOCKS и HTTP одновременно).
4. **ZapretGUI на Windows** умеет «разблокировать» сервисы через файл `hosts`, отправляя Claude/Gemini/ChatGPT и др. на сторонние серверы («XBOX DNS»). Хозяин этих серверов видит, куда ты ходишь. Если не нужно — выключи в его вкладке hosts.
5. **Старые Wi-Fi Atheros (AR9565 и др.)** под Linux постоянно теряют роутер (`BEACON-LOSS`). Модуль `wifi-ath9k` + в роутере **ширина канала 20 МГц** и канал 1/6/11. Лучше всего — заменить карту на Intel AC 7260 (~500 ₽).
6. **Большие файлы по SSH через слабый Wi-Fi** рвутся. Режь на куски: `split -b 1M файл part_` → `scp` с повторами → `cat part_* > файл`. Или флешка.

## Проверка

```bash
systemctl status zapret2 claude-killswitch         # обе службы active
curl -s -m 6 https://claude.ai >/dev/null || echo "Claude напрямую заблокирован ✔"
curl -s -x http://127.0.0.1:10808 https://ipinfo.io/ip  # IP VPN-сервера
curl -s https://ipinfo.io/ip                          # твой обычный IP
```

## Удаление

```bash
sudo systemctl disable --now zapret2 claude-killswitch
sudo rm -rf /opt/zapret2 /etc/claude-killswitch.nft /etc/systemd/system/{zapret2,claude-killswitch}.service
# конфиги Sway: старые лежат рядом как ~/.config/<имя>.bak-<время>
```

## Дисклеймер

Проект — для личного использования и обучения. zapret2 и VPN используй в рамках законодательства своей страны. OSINT-инструменты — только для своих аккаунтов, открытых данных и учебных задач. Kill-switch проверен на адресах ноября 2026 — если Anthropic сменит IP, обнови `system/claude-killswitch.nft` (`getent ahostsv4 claude.ai downloads.claude.ai`).

## Благодарности

- [bol-van/zapret2](https://github.com/bol-van/zapret2)
- [JaKooLit/Hyprland-Dots](https://github.com/JaKooLit/Hyprland-Dots) — вдохновение для оформления
- [ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts), [fastfetch](https://github.com/fastfetch-cli/fastfetch)
