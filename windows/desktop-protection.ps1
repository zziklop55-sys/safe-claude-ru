# Общие правила Claude Desktop для установки и ручного обновления.
$desktopPolicy = 'HKCU:\Software\Policies\Claude'
$desktopState = 'HKCU:\Software\SafeClaudeRu'

function Get-ClaudeDesktopPackage {
    $package = Get-AppxPackage -Name Claude | Where-Object PackageFamilyName -eq 'Claude_pzs8sxrjxfjjc' | Select-Object -First 1
    if (-not $package -or -not $package.InstallLocation) {
        throw 'Установленный пакет Claude Desktop MSIX для текущего пользователя не найден.'
    }
    $package
}

function Set-ClaudeDesktopRules($Package) {
    Assert-FirewallProfiles
    $root = $Package.InstallLocation
    $cache = Join-Path $env:LOCALAPPDATA "Packages\$($Package.PackageFamilyName)"
    $main = Get-ExecutablePath (Join-Path $root 'app\Claude.exe')
    $paths = @(
        $main
        foreach ($directory in $root, $cache) {
            if (Test-Path -LiteralPath $directory) {
                Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.exe' | ForEach-Object FullName
            }
        }
    )
    $paths = @($paths | Sort-Object -Unique)

    if (-not ('SafeClaudeDesktop.PackageSid' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SafeClaudeDesktop {
    public static class PackageSid {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
        public static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
        [DllImport("advapi32.dll")]
        public static extern IntPtr FreeSid(IntPtr sid);
    }
}
'@
    }
    $pointer = [IntPtr]::Zero
    $result = [SafeClaudeDesktop.PackageSid]::DeriveAppContainerSidFromAppContainerName($Package.PackageFamilyName, [ref]$pointer)
    if ($result -ne 0) { throw "Не удалось получить SID Claude Desktop ($result)." }
    try { $sid = [Security.Principal.SecurityIdentifier]::new($pointer).Value }
    finally { [void][SafeClaudeDesktop.PackageSid]::FreeSid($pointer) }

    # Правило по SID дополняет правила по путям. В тесте дочерний Win32-процесс
    # с идентичностью пакета всё равно подключился напрямую без своего правила.
    # Новые .exe встроенного Code требуют повторного запуска защиты.
    $rule = @{
        Name = 'safe-claude-desktop-package'
        PolicyStore = 'PersistentStore'
        Package = $sid
        Direction = 'Outbound'
        Action = 'Block'
        Enabled = 'True'
        Profile = 'Any'
        Protocol = 'Any'
        RemoteAddress = $nonLoopback
    }
    if (@(Get-NetFirewallRule -PolicyStore PersistentStore).Name -contains $rule.Name) {
        Set-NetFirewallRule @rule
    } else {
        New-NetFirewallRule @rule -Group $proxyOnlyGroup -DisplayName 'Safe Claude RU: пакет Claude Desktop' | Out-Null
    }
    $active = Get-NetFirewallRule -Name $rule.Name -PolicyStore ActiveStore
    $application = $active | Get-NetFirewallApplicationFilter
    $addresses = ($active | Get-NetFirewallAddressFilter).RemoteAddress
    if ($active.Enabled -ne 'True' -or $active.Action -ne 'Block' -or $active.Direction -ne 'Outbound' -or
        $active.Profile -ne 'Any' -or $application.Package -ne $sid -or
        (Compare-Object ($nonLoopback | Sort-Object) ($addresses | Sort-Object))) {
        throw 'Правило пакета Claude Desktop отсутствует или изменено.'
    }
    Set-ProxyOnlyProgramRules $paths
    Write-Host "[OK] Активно правило SID пакета и правила для $($paths.Count) обнаруженных .exe Claude Desktop."
}

function Set-ClaudeDesktopProxy([int]$Port) {
    $wanted = @{ egressProxyUrl = "http://127.0.0.1:$Port"; disableAutoUpdates = 1 }
    $machine = Get-ItemProperty -LiteralPath 'HKLM:\Software\Policies\Claude' -ErrorAction SilentlyContinue
    $user = Get-ItemProperty -LiteralPath $desktopPolicy -ErrorAction SilentlyContinue
    if ($machine.egressProxyPacUrl -or $user.egressProxyPacUrl) {
        throw 'Политика egressProxyPacUrl имеет приоритет над локальным прокси Claude Desktop.'
    }
    foreach ($name in $wanted.Keys) {
        foreach ($policy in $machine, $user) {
            if ($policy -and $policy.PSObject.Properties[$name] -and $policy.$name -ne $wanted[$name]) {
                throw "Политика Claude Desktop $name конфликтует с этой настройкой."
            }
        }
    }
    $state = Get-ItemProperty -LiteralPath $desktopState -Name DesktopPolicyNames -ErrorAction SilentlyContinue
    $owned = @($state.DesktopPolicyNames | Where-Object { $_ -in $wanted.Keys })
    $new = @($wanted.Keys | Where-Object { -not $user -or -not $user.PSObject.Properties[$_] })
    if ($new.Count) {
        if (-not (Test-Path -LiteralPath $desktopState)) { New-Item -Path $desktopState -Force | Out-Null }
        $names = [string[]]@($owned + $new | Sort-Object -Unique)
        New-ItemProperty -LiteralPath $desktopState -Name DesktopPolicyNames -PropertyType MultiString -Value $names -Force | Out-Null
        New-ItemProperty -LiteralPath $desktopState -Name DesktopProxyPort -PropertyType DWord -Value $Port -Force | Out-Null
        if (-not (Test-Path -LiteralPath $desktopPolicy)) { New-Item -Path $desktopPolicy -Force | Out-Null }
        foreach ($name in $new) {
            $kind = if ($name -eq 'disableAutoUpdates') { 'DWord' } else { 'String' }
            New-ItemProperty -LiteralPath $desktopPolicy -Name $name -PropertyType $kind -Value $wanted[$name] | Out-Null
        }
    }
}

function Remove-ClaudeDesktopProxy {
    $state = Get-ItemProperty -LiteralPath $desktopState -ErrorAction SilentlyContinue
    if (-not $state.DesktopPolicyNames) { return }
    $wanted = @{ egressProxyUrl = "http://127.0.0.1:$($state.DesktopProxyPort)"; disableAutoUpdates = 1 }
    $policy = Get-ItemProperty -LiteralPath $desktopPolicy -ErrorAction SilentlyContinue
    foreach ($name in $state.DesktopPolicyNames) {
        if ($name -in $wanted.Keys -and $policy -and $policy.PSObject.Properties[$name] -and $policy.$name -eq $wanted[$name]) {
            Remove-ItemProperty -LiteralPath $desktopPolicy -Name $name
        }
    }
    Remove-ItemProperty -LiteralPath $desktopState -Name DesktopPolicyNames, DesktopProxyPort
}
