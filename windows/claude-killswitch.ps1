﻿# safe-claude-ru (Windows): Claude только через прокси, без утечки настоящего IP.
#
# Запуск: PowerShell от имени администратора, затем
#   powershell -ExecutionPolicy Bypass -File .\claude-killswitch.ps1
# Другой порт прокси:   ... -File .\claude-killswitch.ps1 -ProxyPort 2080
# Удалить правило:      ... -File .\claude-killswitch.ps1 -Remove
#
# VPN-клиент (Happ, v2rayN и т.п.) подключается к своему серверу, а не к адресам
# Claude, поэтому правило его не задевает и исключения для него не нужны.

param([int]$ProxyPort = 10808, [switch]$Remove)

$name = 'claude-killswitch'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Запусти PowerShell от имени администратора.' -ForegroundColor Red; exit 1 }

Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) { Write-Host 'Правило удалено.'; return }

# 1. Файрвол: прямой доступ к Claude запрещён всем программам
New-NetFirewallRule -Name $name `
    -DisplayName 'Claude: только через прокси (блок прямого доступа)' `
    -Description '160.79.104.0/21 и 2607:6bc0::/48 — Anthropic, 35.190.46.17 — downloads.claude.ai (обновления Claude Code).' `
    -Direction Outbound -Action Block -Profile Any `
    -RemoteAddress 160.79.104.0/21, 35.190.46.17, 2607:6bc0::/48 | Out-Null
Write-Host '[OK] Правило файрвола создано' -ForegroundColor Green

# 2. Claude Code: весь трафик и обновления через прокси
$proxy = "http://127.0.0.1:$ProxyPort"
$dir = Join-Path $env:USERPROFILE '.claude'
$file = Join-Path $dir 'settings.json'
New-Item -ItemType Directory -Force $dir | Out-Null
$cfg = if ((Test-Path $file) -and (Get-Item $file).Length -gt 0) { Get-Content $file -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $cfg.PSObject.Properties['env']) { $cfg | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
foreach ($kv in @{ HTTPS_PROXY = $proxy; HTTP_PROXY = $proxy; NO_PROXY = 'localhost,127.0.0.1,::1' }.GetEnumerator()) {
    $cfg.env | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
}
[IO.File]::WriteAllText($file, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
Write-Host "[OK] Прокси для Claude Code: $file" -ForegroundColor Green

# 3. Проверка
Write-Host 'Проверка:'
& curl.exe -s -o NUL -m 8 --noproxy '*' https://claude.ai/
Write-Host "  claude.ai напрямую: $(if ($LASTEXITCODE -ne 0) { 'заблокирован (так и надо)' } else { 'ОТКРЫЛСЯ — проверь адреса' })"
$ip = (& curl.exe -s -m 10 -x $proxy https://claude.ai/cdn-cgi/trace) | Select-String '^ip=' | ForEach-Object { $_.ToString().Substring(3) }
if ($ip) { Write-Host "  через прокси Claude видит IP: $ip" } else { Write-Host '  прокси не отвечает — включи VPN-клиент' -ForegroundColor Yellow }
