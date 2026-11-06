# safe-claude-ru

**Локальный прокси и блокировка прямых подключений для Claude и Claude Code.** Linux и Windows.

![Linux](https://img.shields.io/badge/Linux-nftables-FCC624) ![Windows](https://img.shields.io/badge/Windows-Firewall-0078D6) ![License](https://img.shields.io/badge/license-MIT-blue)

## Зачем

При выключенном прокси или обходе его настроек приложение может открыть прямое соединение. Схема сочетает блокировку адресов и правила для приложений:

```
Claude Code, браузер с прокси ──► 127.0.0.1:10808 (VPN-клиент) ──► VPN-сервер ──► Claude ✔
Прямые подключения к известным адресам Claude ──────────────────────────────────► ✖ блок
Прямые подключения выбранных программ в режиме proxyonly ──────────────────────► ✖ блок
```

| Что | Как |
|---|---|
| **Kill-switch** | nftables или Windows Firewall блокирует прямой выход на известные адреса Claude/Anthropic |
| **Claude Code** | стандартные переменные HTTP-прокси в `~/.claude/settings.json` |
| **Браузер** | отдельный браузер для Claude и OAuth. В Windows установщик настраивает для него прокси и блокирует домены Claude в обычном браузере |
| **Proxyonly** | Linux фильтрует cgroup, Windows — явно указанные `.exe`. В обоих случаях приложение использует локальный прокси для внешних соединений |

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

Другой порт прокси: `PROXY_PORT=2080 ./install.sh`. Удалить всё: `./install.sh remove`.

### Жёсткий режим `proxyonly` (Linux)

Kill-switch защищает только адреса Claude. А если ты хочешь, чтобы **программа целиком** — Codex, VS Code, IDE на Electron — физически не могла выйти в интернет мимо прокси:

```bash
./install.sh proxyonly          # команда proxyonly
./install.sh codex              # Codex CLI всегда запускается через proxyonly

proxyonly code                  # любая программа: только через прокси
proxyonly firefox
```

Как устроено:

```
proxyonly <программа>
  └─ systemd scope в proxyonly.slice  (своя cgroup)
       └─ nftables: для этой cgroup разрешён только 127.0.0.1 (локальный прокси),
                    всё остальное — reject
       └─ отфильтрованный D-Bus (xdg-dbus-proxy): без доступа к systemd,
          чтобы Chromium/Electron не смогли «выпрыгнуть» из cgroup
       └─ HTTPS_PROXY / ALL_PROXY / BROWSER уже прописаны
```

Проверка: `proxyonly curl --noproxy '*' https://ipinfo.io` — должно упасть; `proxyonly curl https://ipinfo.io` — IP VPN-сервера.

### Windows

**Какой браузер оставить по умолчанию, решать тебе.** Claude Desktop открывает ссылку входа в системном браузере. Чтобы снизить риск случайного прямого подключения, проще оставить браузер с прокси по умолчанию. Если удобнее пользоваться привычным браузером, переключись на браузер с прокси перед входом и верни обычный после авторизации. В обоих случаях перед входом включи Happ.

1. Выбери два разных браузера для обычного интернета и для Claude. Установщик поддерживает Edge, Chrome, Firefox и Comet. Например, можно использовать Comet для обычных сайтов и настроить Edge для работы через прокси.
2. Открой Windows PowerShell **от имени администратора той же учётной записи**. Из корня скачанного репозитория укажи фактические пути к обоим браузерам:

```powershell
$browser = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$main = 'C:\Program Files\Perplexity\Comet\Application\comet.exe'
.\windows\claude-killswitch.ps1 -BrowserPath $browser -MainBrowserPath $main -ProtectDesktop
```

Если Windows блокирует запуск скачанных скриптов, открой нужную сессию командой `powershell.exe -NoProfile -ExecutionPolicy Bypass`. Перед запуском проверь скачанный код.

После установки перезапусти браузеры, чтобы они перечитали политики. Для входа в Claude Desktop назначай браузер с прокси по умолчанию для обоих протоколов, HTTP и HTTPS.

Для Claude Desktop отдельный CLI не нужен. Параметр `-ProtectDesktop` настраивает локальный прокси для пакета Claude Desktop MSIX и блокирует прямой выход для обнаруженных исполняемых файлов, включая встроенный Code и помощники. Перезапусти Claude Desktop после установки. Запуск с `-BrowserPath` без `-ProtectDesktop` настраивает только браузеры и системный блок известных IP.

В обычном браузере, выбранном при установке, отдельная политика закрывает `claude.ai`, `claude.com`, `anthropic.com` и `claudeusercontent.com` вместе с их поддоменами. Для браузера с прокси Firewall блокирует прямые IPv4 и IPv6 вне loopback во всех профилях. Если Happ выключен, прямые соединения этого браузера остаются заблокированы.

Если используешь отдельный Claude Code CLI, добавь к команде `-ClaudePath "$env:USERPROFILE\.local\bin\claude.exe"` с фактическим путём. Установщик добавит правило Firewall для CLI и пропишет выбранный браузер в `settings.json`. При запуске `claude` из терминала вход открывается в этом браузере. Локальный callback на `localhost`, `127.0.0.1` или `::1` идёт внутри ПК.

Если обычный браузер уже выбран в Windows для HTTP и HTTPS, параметр `-MainBrowserPath` можно опустить. Для другого локального порта укажи `-ProxyPort 2080`. Установщик проверяет совместимость уже заданной политики прокси с этим портом.

Чтобы сменить пару браузеров, сначала запусти установщик с `-Remove`, затем с новыми путями. Полное удаление снимает правила проекта, убирает добавленные им политики браузеров и возвращает прежнее значение `BROWSER`. Переменные прокси в Claude Code можно убрать вручную из `settings.json`.

Для отдельного управления правилами приложений есть `-ProxyOnly -Program ...`. Для запуска произвольного защищённого приложения с переменными прокси используй `proxyonly.ps1 -Program ...`. Запуск установщика без путей устанавливает базовое правило по IP и конфиг прокси Claude Code.

#### Обновление Claude Desktop

`-ProtectDesktop` отключает встроенное автообновление Desktop. Обновлятор проекта скачивает MSIX через явный HTTP-прокси, проверяет подпись и устанавливает правила для путей новой версии.

```powershell
# Проверка наличия обновления
.\windows\update-claude-desktop.ps1 -CheckOnly

# Установка. Закрой Claude Desktop и запусти Windows PowerShell от администратора
.\windows\update-claude-desktop.ps1
```

Для нестандартного порта передай тот же `-ProxyPort`, что использовал при настройке. Запускай Desktop после сообщения об активных правилах новой версии. Правило по SID пакета дополняет правила по путям. В тесте оно пропустило прямое подключение дочернего Win32-процесса, для которого не было отдельного правила. Если встроенный Code обновился отдельно, закрой Desktop и повтори `.\windows\claude-killswitch.ps1 -ProtectDesktop` с тем же портом перед следующим запуском, чтобы добавить правила для новых `.exe`.

**Границы защиты.** Windows фильтрует сокеты указанных исполняемых файлов. Дочерние программы, обновляторы с другими путями, MCP-инструменты, DNS через общесистемные службы и другие приложения требуют отдельного контроля. Loopback остаётся доступным для прокси и OAuth. Настрой в Happ маршрутизацию через доверенный узел для нужных сайтов. После смены пути к `.exe` переустанови для него правило. На управляемом ПК учитывай политики Firewall и браузера.

## Проверка

```bash
# Linux
curl -s -m 6 https://claude.ai >/dev/null || echo "напрямую заблокирован ✔"
curl -s -x http://127.0.0.1:10808 https://claude.ai/cdn-cgi/trace | grep ip=   # какой IP видит Claude
```

```powershell
# Windows PowerShell от администратора
Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,AllowLocalFirewallRules
Get-NetFirewallRule -Group 'safe-claude-ru proxyonly' -PolicyStore ActiveStore |
    Get-NetFirewallAddressFilter | Select-Object RemoteAddress
```

```powershell
# Проверка прокси на нейтральном сайте в обычном Windows PowerShell
curl.exe -q --proxy http://127.0.0.1:10808 --noproxy localhost -sS -o NUL -w "CONNECT=%{http_connect} HTTP=%{http_code}" https://example.com/
```

Для Windows ожидается `CONNECT=200 HTTP=200`. В выделенном браузере при отключённом прокси внешний сайт должен перестать открываться. Чтобы проверить само правило Firewall сетевым тестом, сравни прямое подключение к одному доступному адресу из обычной и защищённой копий программы. Одиночная ошибка curl может означать таймаут, отсутствие маршрута или сбой DNS.

## Подтверждение личности

Anthropic может запросить проверку через Persona, в том числе фото действующего документа и селфи с камеры. Открывай проверку из официального интерфейса Claude и следуй подсказкам Persona. Если она предлагает продолжить на телефоне и нужен тот же сетевой маршрут, заранее включи на телефоне тот же доверенный VPN или настрой прокси с тем же выходным узлом. Сеть эмулятора тоже настраивается отдельно. Используй эмулятор только если конкретный сценарий его поддерживает, а для проверки с камерой держи под рукой реальный телефон. Прокси управляет маршрутом трафика, а доступность сервиса и решение по проверке определяет Anthropic. [Проверка личности](https://support.claude.com/en/articles/14328960-identity-verification-on-claude) · [Поддерживаемые страны](https://support.claude.com/en/articles/8461763-where-can-i-access-claude)

## ⚠️ Грабли, на которые мы наступили

1. **Загрузки Claude Code используют отдельный хост.** `downloads.claude.ai` может отдавать адреса вне подсетей Anthropic. В базовом списке Windows есть известные IPv4 и IPv6 этого хоста. Для выбранных `.exe` правило proxyonly действует независимо от адреса.
2. **Установщик Claude Code не понимает `socks5h://`.** С `HTTPS_PROXY=socks5h://…` он скачивает файл и зависает на шаге `install`, а если его прервать — удаляет скачанное. Нужен **HTTP-прокси**: `HTTPS_PROXY=http://127.0.0.1:10808`. У Happ порт смешанный, так что подходит тот же 10808.
3. **zapret ломает VPN с маскировкой (VLESS Reality).** Если одновременно работает zapret/zapret2 в режиме autohostlist — он может принять твой VPN-сервер (маскирующийся под `dl.google.com` и т.п.) за заблокированный сайт и начать его «пробивать». VPN перестаёт работать. Решение: добавь SNI и IP своего VPN-сервера в исключения zapret.
4. **ZapretGUI (Windows) и «XBOX DNS».** В ZapretGUI есть разблокировка через файл `hosts`: Claude, ChatGPT, Gemini и десятки сервисов отправляются на сторонние серверы. Хозяин этих серверов видит, куда и с какого IP ты ходишь. Если пользуешься прокси — выключи это во вкладке hosts ZapretGUI.
5. **Для OAuth используется браузер.** В Windows назначь браузер с прокси браузером по умолчанию для входа из Claude Desktop. В Linux `./install.sh claude-code` указывает `BROWSER` на `ffp-open`. Если клиент показывает ссылку, вставь её в браузер с прокси.
6. **Firefox «только через прокси» ломает OAuth-вход.** После входа Google/Anthropic возвращают тебя на `http://localhost:ПОРТ/callback`. Если прокси перехватывает и localhost (`allow_hijacking_localhost=true`), прокси ищет этот «localhost» на VPN-сервере → `NS_ERROR_NET_EMPTY_RESPONSE`. localhost должен идти напрямую — это не утечка, это сам компьютер.
7. **Chromium/Electron сбегают из песочницы.** Программа на Chromium (VS Code, Cursor, IDE на Electron) при старте сама переносит главный процесс в свою cgroup `app-org.chromium.Chromium-*.scope` через D-Bus-вызов `StartTransientUnit` к systemd. Правило файрвола для твоей cgroup её больше не касается. Переименование scope в `app-*` не помогает. Помогает только отрезать программе systemd на D-Bus (`xdg-dbus-proxy --filter`), оставив связку ключей, порталы и уведомления.
8. **Внутри песочницы не открываются ссылки.** `xdg-open` в Sway/без DE пишет `no method available`, а snap-Firefox вообще не стартует без доступа к systemd. Решение: подменённый `xdg-open`, который запускает прокси-Firefox **вне** песочницы — у него и так нет прямого выхода.
9. **TUN меняет маршрутизацию.** Этот набор настроек рассчитан на режим локального HTTP-прокси. У TUN свои маршруты и правила на случай обрыва.

## Если Anthropic сменит адреса

Базовый kill-switch использует список известных адресов. Проверь записи обоих семейств:

```bash
for host in claude.ai api.anthropic.com downloads.claude.ai; do
    dig +short "$host" A
    dig +short "$host" AAAA
done
```

```powershell
'claude.ai','api.anthropic.com','downloads.claude.ai' | ForEach-Object {
    Resolve-DnsName -Name $_ -Type A
    Resolve-DnsName -Name $_ -Type AAAA
}
```

Если появились новые — обнови `linux/claude-killswitch.nft` и `windows/claude-killswitch.ps1` (или открой issue).

## Лицензия

MIT
