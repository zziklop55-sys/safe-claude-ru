# Windows PowerShell 5.1, от имени администратора той же учётной записи.
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort = 10808,
    [ValidateNotNullOrEmpty()][string[]]$Program,
    [string]$ClaudePath,
    [string]$BrowserPath,
    [string]$MainBrowserPath,
    [switch]$ProtectDesktop,
    [switch]$ProxyOnly,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'proxyonly-common.ps1')
. (Join-Path $PSScriptRoot 'browser-policies.ps1')
. (Join-Path $PSScriptRoot 'desktop-protection.ps1')
$name = 'claude-killswitch'
$store = 'PersistentStore'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Запусти Windows PowerShell от имени администратора.'
}

$dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$file = [IO.Path]::GetFullPath((Join-Path $dir 'settings.json'))
if ($Remove) {
    if (-not $Program -and -not $ProxyOnly) {
        Remove-BrowserPolicies $file
        Remove-ClaudeDesktopProxy
    }
    $selected = if ($Program) { @($Program | ForEach-Object { "claude-proxyonly-$(Get-ProxyOnlyId (Get-ExecutablePath $_))" }) }
    Get-NetFirewallRule -PolicyStore $store | Where-Object {
        if ($selected) {
            $_.Name -in $selected -and $_.Group -eq $proxyOnlyGroup
        } else {
            $_.Group -eq $proxyOnlyGroup -or (-not $ProxyOnly -and $_.Name -eq $name)
        }
    } | Remove-NetFirewallRule
    Write-Host 'Выбранные правила удалены.'
    return
}

if ($ProxyOnly -and (-not $Program -or $BrowserPath -or $ClaudePath -or $MainBrowserPath -or $ProtectDesktop)) {
    throw 'Для -ProxyOnly укажи только список .exe через -Program.'
}
if (($ClaudePath -or $MainBrowserPath) -and -not $BrowserPath) {
    throw 'Укажи браузер с прокси через -BrowserPath.'
}

$configureCli = -not $ProxyOnly -and ($ClaudePath -or (-not $BrowserPath -and -not $ProtectDesktop))
if ($configureCli) {
    $cfg = Read-ClaudeSettings $file
    if (-not $cfg.PSObject.Properties['env']) {
        $cfg | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
    }
    if ($cfg.env -isnot [pscustomobject]) { throw "Ожидался JSON-объект env в $file." }
}

$programs = @($Program | Where-Object { $_ })
if ($BrowserPath) {
    $browser = Get-ExecutablePath $BrowserPath
    $programs += $browser
    if ($ClaudePath) {
        $claude = Get-ExecutablePath $ClaudePath
        $product = (Get-Item -LiteralPath $claude).VersionInfo.ProductName
        if ([IO.Path]::GetFileName($claude) -ne 'claude.exe' -or $product -ne 'Claude Code') {
            throw 'Параметр -ClaudePath принимает отдельный Claude Code CLI. Для Claude Desktop достаточно -BrowserPath.'
        }
        $programs += $claude
    }
    $mainBrowser = if ($MainBrowserPath) { Get-ExecutablePath $MainBrowserPath } else { Get-DefaultBrowserPath }
    $config = if ($configureCli) { $file }
    $browserPlan = New-BrowserPolicyPlan $mainBrowser $browser $ProxyPort $config $cfg
}
$paths = @($programs | ForEach-Object { Get-ExecutablePath $_ } | Sort-Object -Unique)
if ($ProtectDesktop) { $desktop = Get-ClaudeDesktopPackage }
Assert-FirewallProfiles
if ($paths) {
    Set-ProxyOnlyProgramRules $paths
    Write-Host "[OK] Правила proxyonly для $($paths.Count) программ."
}
$installed = @(Get-NetFirewallRule -PolicyStore $store)

if ($ProxyOnly) { return }
if ($desktop) {
    Set-ClaudeDesktopRules $desktop
    Set-ClaudeDesktopProxy $ProxyPort
    Write-Host '[OK] Прокси Claude Desktop настроен. Для обновлений используй update-claude-desktop.ps1.'
}

# Системный список известных адресов. Защита выбранных .exe выше не зависит от этого списка.
$basicRule = @{
    Name = $name
    DisplayName = 'Claude: блок известных адресов'
    Description = 'Известные IPv4 и IPv6 Anthropic и downloads.claude.ai.'
    PolicyStore = $store
    Enabled = 'True'
    Direction = 'Outbound'
    Action = 'Block'
    Profile = 'Any'
    RemoteAddress = @('160.79.104.0/21', '2607:6bc0::/48', '35.190.46.17', '2600:1901:0:b25e::')
}
if ($name -in $installed.Name) {
    $basicRule.NewDisplayName = $basicRule.DisplayName
    $basicRule.Remove('DisplayName')
    Set-NetFirewallRule @basicRule
} else {
    New-NetFirewallRule @basicRule | Out-Null
}
Get-NetFirewallRule -Name $name -PolicyStore ActiveStore | Out-Null
Write-Host '[OK] Системное правило для известных адресов Claude активно.'

if ($browserPlan) {
    Install-BrowserPolicies $browserPlan
    Write-Host "[OK] Сайты Claude закрыты в $mainBrowser. Прокси настроен для $browser."
}
if (-not $configureCli) { return }

$proxy = "http://127.0.0.1:$ProxyPort"
foreach ($entry in @{ HTTPS_PROXY = $proxy; HTTP_PROXY = $proxy; NO_PROXY = $loopbackHosts }.GetEnumerator()) {
    $cfg.env | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}

if ($browserPlan) {
    $cfg.env | Add-Member -NotePropertyName BROWSER -NotePropertyValue $browser -Force
}
Save-ClaudeSettings $file $cfg
Write-Host "[OK] Прокси Claude Code: $file"
