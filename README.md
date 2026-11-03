# safe-claude-ru

**Claude и Claude Code из России без утечки настоящего IP.** Linux и Windows.

![Linux](https://img.shields.io/badge/Linux-nftables-FCC624) ![Windows](https://img.shields.io/badge/Windows-Firewall-0078D6) ![License](https://img.shields.io/badge/license-MIT-blue)

## Зачем

Ты ходишь в Claude через VPN или прокси. Но достаточно один раз забыть его включить, или программа пойдёт в обход прокси — и Anthropic увидит твой российский IP. А это прямой путь к бану аккаунта.

Этот репозиторий делает так, что **напрямую до Claude достучаться физически нельзя**:

```
Claude Code, браузер с прокси ──► 127.0.0.1:10808 (VPN-клиент) ──► VPN-сервер ──► Claude ✔
Всё остальное к Claude напрямую ─────────────────────────────────────────────────► ✖ блок
```

| Что | Как |
|---|---|
| **Kill-switch** | правило файрвола (Linux — nftables, Windows — Windows Firewall) запрещает любые прямые подключения к серверам Claude/Anthropic |
| **Claude Code** | весь его трафик — запросы, **обновления**, телеметрия — идёт через прокси (`~/.claude/settings.json`) |
| **Браузер** (Linux, по желанию) | отдельный профиль Firefox, который без прокси не открывает вообще ничего |

VPN-клиенту исключения не нужны: он подключается к **своему** серверу, а не к адресам Claude, поэтому правило его не задевает.

## Что нужно

VPN-клиент с **локальным прокси** — например, [Happ](https://github.com/Happ-proxy/happ-desktop), v2rayN, Nekoray. В Happ порт `10808` по умолчанию и он **смешанный** (SOCKS5 + HTTP) — это важно, см. «Грабли».

Режим VPN-клиента: **«только прокси»** — TUN и «системный прокси» выключены. Тогда через VPN идут только те программы, которым ты его прописал, а всё остальное работает как обычно.

## Установка

### Linux (Ubuntu / Debian / любой с nftables и systemd)

```bash
git clone https://github.com/zziklop55-sys/safe-claude-ru.git
cd safe-claude-ru/linux
./install.sh                 # kill-switch + прокси для Claude Code (поставит его, если нет)
./install.sh firefox         # по желанию: Firefox «только через прокси» для claude.ai
```

Другой порт прокси: `PROXY_PORT=2080 ./install.sh`. Удалить kill-switch: `./install.sh remove`.

### Windows

PowerShell **от имени администратора**:

```powershell
git clone https://github.com/zziklop55-sys/safe-claude-ru.git
cd safe-claude-ru\windows
powershell -ExecutionPolicy Bypass -File .\claude-killswitch.ps1
```

Другой порт: `-ProxyPort 2080`. Удалить: `-Remove`.

## Проверка

```bash
# Linux
curl -s -m 6 https://claude.ai >/dev/null || echo "напрямую заблокирован ✔"
curl -s -x http://127.0.0.1:10808 https://claude.ai/cdn-cgi/trace | grep ip=   # какой IP видит Claude
```

```powershell
# Windows
curl.exe -s -m 6 --noproxy * https://claude.ai ; if ($LASTEXITCODE) { "напрямую заблокирован ✔" }
curl.exe -s -x http://127.0.0.1:10808 https://claude.ai/cdn-cgi/trace | Select-String ip=
```

Во второй строке должен быть IP твоего VPN-сервера, а не домашний.

## ⚠️ Грабли, на которые мы наступили

1. **Claude Code обновляется не с серверов Anthropic.** Обновления идут с `downloads.claude.ai` — это Google Cloud (`35.190.46.17`), а не сеть Anthropic. Если блокировать только `160.79.104.0/21`, обновление пойдёт напрямую и засветит IP. Здесь заблокированы оба.
2. **Установщик Claude Code не понимает `socks5h://`.** С `HTTPS_PROXY=socks5h://…` он скачивает файл и зависает на шаге `install`, а если его прервать — удаляет скачанное. Нужен **HTTP-прокси**: `HTTPS_PROXY=http://127.0.0.1:10808`. У Happ порт смешанный, так что подходит тот же 10808.
3. **zapret ломает VPN с маскировкой (VLESS Reality).** Если одновременно работает zapret/zapret2 в режиме autohostlist — он может принять твой VPN-сервер (маскирующийся под `dl.google.com` и т.п.) за заблокированный сайт и начать его «пробивать». VPN перестаёт работать. Решение: добавь SNI и IP своего VPN-сервера в исключения zapret.
4. **ZapretGUI (Windows) и «XBOX DNS».** В ZapretGUI есть разблокировка через файл `hosts`: Claude, ChatGPT, Gemini и десятки сервисов отправляются на сторонние серверы. Хозяин этих серверов видит, куда и с какого IP ты ходишь. Если пользуешься прокси — выключи это во вкладке hosts ZapretGUI.
5. **TUN-режим VPN-клиента обходит kill-switch.** При включённом TUN весь трафик и так уходит в VPN, и правило файрвола его не видит — утечки нет. Но тогда через VPN ходит весь компьютер; режим «только прокси» удобнее.

## Если Anthropic сменит адреса

Kill-switch проверен на адресах ноября 2026. Проверить актуальные:

```bash
getent ahostsv4 claude.ai api.anthropic.com downloads.claude.ai
```

Если появились новые — обнови `linux/claude-killswitch.nft` и `windows/claude-killswitch.ps1` (или открой issue).

## Лицензия

MIT
