# Windows: запретить прямой доступ к Claude / Anthropic (только через VPN/прокси).
# Запуск: ПКМ по PowerShell -> «Запуск от имени администратора», затем:
#   powershell -ExecutionPolicy Bypass -File .\claude-killswitch.ps1
# Удалить правило:
#   powershell -ExecutionPolicy Bypass -File .\claude-killswitch.ps1 -Remove
#
# VPN-клиент (Happ, v2rayN и т.п.) подключается к своему серверу, а не к адресам
# ниже, поэтому правило его не задевает и исключения для него не нужны.

param([switch]$Remove)

$name = 'claude-killswitch'
Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) { Write-Host 'Правило удалено.'; return }

New-NetFirewallRule -Name $name `
    -DisplayName 'Claude: только через прокси (блок прямого доступа)' `
    -Description '160.79.104.0/21 и 2607:6bc0::/48 — Anthropic, 35.190.46.17 — downloads.claude.ai (обновления Claude Code).' `
    -Direction Outbound -Action Block -Profile Any `
    -RemoteAddress 160.79.104.0/21, 35.190.46.17, 2607:6bc0::/48 | Out-Null

Write-Host 'Готово. Проверка:'
$r = & curl.exe -s -o NUL -m 8 -w '%{http_code}' --noproxy '*' https://claude.ai/
Write-Host "  claude.ai напрямую: $(if ($LASTEXITCODE -ne 0) { 'заблокирован (так и надо)' } else { "ОТКРЫЛСЯ ($r) — что-то не так" })"
