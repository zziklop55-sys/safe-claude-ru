# Общие параметры правила и проверка перед запуском.
$proxyOnlyGroup = 'safe-claude-ru proxyonly'
$nonLoopback = @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255', '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
$loopbackHosts = 'localhost,127.0.0.1,::1'

function Get-ExecutablePath([string]$Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file -isnot [IO.FileInfo] -or $file.Extension -ne '.exe' -or $file.FullName -notmatch '^[A-Z]:\\') {
        throw 'Укажи путь к локальному .exe.'
    }
    $file.FullName
}

function Get-ProxyOnlyId([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant()))
        [BitConverter]::ToString($hash).Replace('-', '').Substring(0, 24)
    } finally {
        $sha.Dispose()
    }
}

function Get-BrowserPolicyVendor([string]$Path) {
    switch ([IO.Path]::GetFileName($Path)) {
        'msedge.exe' { 'Microsoft\Edge' }
        'chrome.exe' { 'Google\Chrome' }
        'comet.exe' { 'Perplexity\Comet' }
        'firefox.exe' { 'Mozilla\Firefox' }
    }
}

function Assert-ChromiumProxyPolicy([string]$Path, [int]$Port) {
    $vendor = Get-BrowserPolicyVendor $Path
    if (-not $vendor -or $vendor -eq 'Mozilla\Firefox') { return }
    $required = "127.0.0.1:$Port"
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $key = "$hive\Software\Policies\$vendor"
        $policy = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($policy.ProxySettings) {
            try { $policy = ConvertFrom-Json -InputObject $policy.ProxySettings -ErrorAction Stop }
            catch { throw "Не удалось прочитать политику ProxySettings в $key." }
        }
        if (-not ($policy.ProxyMode -or $policy.ProxyServer -or $policy.ProxyPacUrl -or $policy.ProxyBypassList)) { continue }

        $bypass = @($policy.ProxyBypassList -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $loopbackOnly = @($bypass | Where-Object { $_ -notin 'localhost', '127.0.0.1', '[::1]', '::1', '<-loopback>' }).Count -eq 0
        $loopbackAllowed = '<-loopback>' -notin $bypass -or
            ($bypass[0] -eq '<-loopback>' -and 'localhost' -in $bypass -and '127.0.0.1' -in $bypass -and '[::1]' -in $bypass)
        if ($policy.ProxyMode -ne 'fixed_servers' -or $policy.ProxyServer -notin $required, "http://$required" -or
            -not $loopbackOnly -or -not $loopbackAllowed) {
            throw "Политика прокси браузера в $key должна использовать HTTP-прокси $required и оставлять loopback для OAuth."
        }
    }
}

function Assert-ProxyOnlyRule([string]$Path) {
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    if (@(Get-Service BFE,MpsSvc | Where-Object Status -ne Running).Count -or
        $policy.LocalPolicyModifyState -ne 0 -or
        -not ($policy.FirewallEnabled(1) -and $policy.FirewallEnabled(2) -and $policy.FirewallEnabled(4))) {
        throw 'Проверь, что Windows Firewall включён во всех профилях и локальные правила действуют.'
    }

    $displayName = "$proxyOnlyGroup $(Get-ProxyOnlyId $Path)"
    $rules = @($policy.Rules | Where-Object { $_.Name -eq $displayName -and $_.Grouping -eq $proxyOnlyGroup })
    if ($rules.Count -ne 1) { throw "Установи правило proxyonly для $Path." }

    $rule = $rules[0]
    if (-not $rule.Enabled -or $rule.Profiles -ne 2147483647 -or $rule.Direction -ne 2 -or $rule.Action -ne 0 -or
        $rule.Protocol -ne 256 -or $rule.ApplicationName -ne $Path -or $rule.ServiceName -or
        $rule.LocalAddresses -ne '*' -or $rule.InterfaceTypes -ne 'All' -or $rule.Interfaces -or
        (Compare-Object ($nonLoopback | Sort-Object) ($rule.RemoteAddresses -split ',' | Sort-Object))) {
        throw "Правило proxyonly для $Path изменено. Переустанови его перед запуском."
    }
}

function Assert-FirewallProfiles {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($profiles.Count -ne 3 -or @($profiles | Where-Object { $_.Enabled -ne 'True' -or $_.AllowLocalFirewallRules -eq 'False' }).Count) {
        throw 'Windows Firewall должен быть включён и принимать локальные правила во всех трёх профилях.'
    }
}

function Set-ProxyOnlyProgramRules([string[]]$Paths) {
    $store = 'PersistentStore'
    $installed = @(Get-NetFirewallRule -PolicyStore $store).Name
    foreach ($path in $Paths) {
        $id = Get-ProxyOnlyId $path
        $rule = @{
            Name = "claude-proxyonly-$id"
            DisplayName = "$proxyOnlyGroup $id"
            PolicyStore = $store
            Enabled = 'True'
            Direction = 'Outbound'
            Action = 'Block'
            Profile = 'Any'
            Protocol = 'Any'
            Program = $path
            RemoteAddress = $nonLoopback
        }
        if ($rule.Name -in $installed) {
            $rule.NewDisplayName = $rule.DisplayName
            $rule.Remove('DisplayName')
            Set-NetFirewallRule @rule -LocalAddress Any -InterfaceType Any
        } else {
            New-NetFirewallRule @rule -Group $proxyOnlyGroup | Out-Null
        }
        Get-NetFirewallRule -Name $rule.Name -PolicyStore ActiveStore | Out-Null
        Assert-ProxyOnlyRule $path
    }
}
