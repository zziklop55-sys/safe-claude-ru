# Политики браузеров и их откат для текущей учётной записи Windows.
$browserPolicyState = 'HKCU:\Software\SafeClaudeRu'
$claudeDomains = 'claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com'

function Get-DefaultBrowserPath {
    $message = 'Не удалось определить один основной браузер для HTTP и HTTPS. Укажи его .exe через -MainBrowserPath.'
    $paths = foreach ($scheme in 'https', 'http') {
        $choice = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$scheme\UserChoice" -ErrorAction SilentlyContinue
        if (-not $choice.ProgId) { throw $message }
        $command = Get-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\$($choice.ProgId)\shell\open\command" -ErrorAction SilentlyContinue
        if (-not $command -or $command.GetValue('') -notmatch '^\s*(?:"([^"]+\.exe)"|(\S+\.exe))(?:\s|$)') {
            throw $message
        }
        Get-ExecutablePath ([Environment]::ExpandEnvironmentVariables($Matches[1] + $Matches[2]))
    }
    $handlers = @($paths | Sort-Object -Unique)
    if ($handlers.Count -ne 1) { throw $message }
    $handlers[0]
}

function Read-ClaudeSettings([string]$File) {
    if (Test-Path -LiteralPath $File) {
        $raw = Get-Content -LiteralPath $File -Raw -Encoding utf8
        if ($raw) {
            if ($raw.TrimStart() -notmatch '^\{') { throw "Ожидался JSON-объект в $File." }
            try { return ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
            catch { throw "Не удалось прочитать JSON в $File." }
        }
    }
    [pscustomobject]@{}
}

function Save-ClaudeSettings([string]$File, $Settings) {
    $dir = Split-Path -Parent $File
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $temporary = Join-Path $dir ('.safe-claude-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, ($Settings | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $File) {
            [IO.File]::Replace($temporary, $File, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $File)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Get-BrowserPolicyState {
    $state = Get-ItemProperty -LiteralPath $browserPolicyState -Name BrowserPolicyState -ErrorAction SilentlyContinue
    if ($state.BrowserPolicyState) { ConvertFrom-Json -InputObject $state.BrowserPolicyState }
}

function Assert-BrowserPolicyState($State, [string]$Config) {
    $vendors = 'Microsoft\Edge', 'Google\Chrome', 'Perplexity\Comet', 'Mozilla\Firefox'
    if ($State.MainVendor -notin $vendors -or $State.ProxyVendor -notin $vendors -or
        ($State.Config -and $Config -and $State.Config -ne $Config)) {
        throw 'Для отката используй ту же учётную запись и тот же CLAUDE_CONFIG_DIR, что при установке.'
    }
    $main = "HKCU:\Software\Policies\$($State.MainVendor)"
    $proxy = "HKCU:\Software\Policies\$($State.ProxyVendor)"
    $block = if ($State.MainVendor -eq 'Mozilla\Firefox') { "$main\WebsiteFilter\Block" } else { "$main\URLBlocklist" }
    foreach ($entry in $State.Changes) {
        $valid = ($entry.Key -eq $block -and $entry.Name -match '^[1-9][0-9]{0,3}$' -and $entry.Type -eq 'String') -or
            ($entry.Key -eq $proxy -and $entry.Name -eq 'ProxySettings' -and $entry.Type -eq 'String') -or
            ($State.ProxyVendor -eq 'Mozilla\Firefox' -and $entry.Key -eq "$proxy\Proxy" -and
                $entry.Name -in 'Mode', 'HTTPProxy', 'SSLProxy', 'Passthrough', 'Locked' -and $entry.Type -in 'String', 'DWord')
        if (-not $valid) { throw 'Сохранённый список политик браузера повреждён.' }
    }
    $changedKeys = @($State.Changes | ForEach-Object Key)
    foreach ($key in $State.CreatedKeys) {
        if ($key -notin $changedKeys) { throw 'Сохранённый список ключей политик повреждён.' }
    }
}

function New-BrowserPolicyPlan([string]$MainBrowser, [string]$Browser, [int]$Port, [string]$Config, $Settings) {
    $mainVendor = Get-BrowserPolicyVendor $MainBrowser
    $proxyVendor = Get-BrowserPolicyVendor $Browser
    if (-not $mainVendor -or -not $proxyVendor) {
        throw 'Для постоянной настройки выбери два разных браузера из Edge, Chrome, Firefox и Comet.'
    }
    if ($mainVendor -eq $proxyVendor) {
        throw 'Основной и проксированный браузеры должны быть разными продуктами: политика применяется ко всем профилям браузера.'
    }
    $state = Get-BrowserPolicyState
    if ($state) { Assert-BrowserPolicyState $state $Config }
    if ($state -and ($state.MainVendor -ne $mainVendor -or $state.ProxyVendor -ne $proxyVendor -or
        $state.Browser -ne $Browser -or $state.Port -ne $Port)) {
        throw 'Сначала сними прежнюю настройку командой с -Remove, затем установи её для новой пары браузеров или порта.'
    }
    if (-not $state) {
        $state = [pscustomobject]@{
            MainVendor = $mainVendor
            ProxyVendor = $proxyVendor
            Browser = $Browser
            Port = $Port
            Config = $null
            PreviousBrowser = $null
            Changes = @()
            CreatedKeys = @()
        }
    }
    if ($Config -and -not $state.Config) {
        $state.Config = $Config
        $previous = $Settings.env.PSObject.Properties['BROWSER']
        if ($previous) { $state.PreviousBrowser = [pscustomobject]@{ Value = $previous.Value } }
    }

    $mainFirefox = $mainVendor -eq 'Mozilla\Firefox'
    $blockList = if ($mainFirefox) { 'WebsiteFilter\Block' } else { 'URLBlocklist' }
    $allowList = if ($mainFirefox) { 'WebsiteFilter\Exceptions' } else { 'URLAllowlist' }
    $root = "Software\Policies\$mainVendor"
    foreach ($keyPath in "HKLM:\$root\$blockList", "HKLM:\$root\$allowList", "HKCU:\$root\$allowList") {
        $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
        if ($key -and $key.ValueCount) { throw "Существующая политика $keyPath может переопределить блокировку. Проверь её перед установкой." }
    }

    $blockPath = "HKCU:\$root\$blockList"
    $key = Get-Item -LiteralPath $blockPath -ErrorAction SilentlyContinue
    $names = @($state.Changes | Where-Object Key -eq $blockPath | ForEach-Object Name)
    if ($key) { $names += $key.GetValueNames() }
    $patterns = foreach ($domain in $claudeDomains) {
        if ($mainFirefox) { "*://*.$domain/*" } else { $domain }
    }
    foreach ($pattern in $patterns) {
        if (($key -and @($key.GetValueNames() | ForEach-Object { $key.GetValue($_) }) -contains $pattern) -or
            @($state.Changes | Where-Object Key -eq $blockPath | ForEach-Object Value) -contains $pattern) { continue }
        $name = 1..1000 | Where-Object { [string]$_ -notin $names } | Select-Object -First 1
        if (-not $name) { throw "В $blockPath нет свободных записей." }
        $names += [string]$name
        $state.Changes += [pscustomobject]@{ Key = $blockPath; Name = [string]$name; Value = $pattern; Type = 'String' }
    }

    $root = "Software\Policies\$proxyVendor"
    $proxy = "127.0.0.1:$Port"
    $hasPolicy = $false
    if ($proxyVendor -eq 'Mozilla\Firefox') {
        $values = @{ Mode = 'manual'; HTTPProxy = $proxy; SSLProxy = $proxy; Passthrough = $loopbackHosts; Locked = 1 }
        foreach ($hive in 'HKLM:', 'HKCU:') {
            $path = "$hive\$root\Proxy"
            $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if (-not $key -or -not $key.ValueCount) { continue }
            $policy = Get-ItemProperty -LiteralPath $path
            if ($policy.Mode -ne 'manual' -or $policy.HTTPProxy -ne $proxy -or
                ($policy.SSLProxy -ne $proxy -and $policy.UseHTTPProxyForAllProtocols -ne 1) -or
                @($policy.Passthrough -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notin 'localhost', '127.0.0.1', '::1', '[::1]' }).Count) {
                throw "Политика прокси Firefox в $hive\$root несовместима с локальным прокси $proxy."
            }
            $hasPolicy = $true
        }
        if (-not $hasPolicy -and -not @($state.Changes | Where-Object Key -eq "HKCU:\$root\Proxy").Count) {
            foreach ($entry in $values.GetEnumerator()) {
                $type = if ($entry.Value -is [int]) { 'DWord' } else { 'String' }
                $state.Changes += [pscustomobject]@{ Key = "HKCU:\$root\Proxy"; Name = $entry.Key; Value = $entry.Value; Type = $type }
            }
        }
    } else {
        Assert-ChromiumProxyPolicy $Browser $Port
        foreach ($hive in 'HKLM:', 'HKCU:') {
            $policy = Get-ItemProperty -LiteralPath "$hive\$root" -ErrorAction SilentlyContinue
            if ($policy.ProxySettings -or $policy.ProxyMode) { $hasPolicy = $true }
        }
        if (-not $hasPolicy -and -not @($state.Changes | Where-Object { $_.Key -eq "HKCU:\$root" -and $_.Name -eq 'ProxySettings' }).Count) {
            $value = @{ ProxyMode = 'fixed_servers'; ProxyServer = "http://$proxy" } | ConvertTo-Json -Compress
            $state.Changes += [pscustomobject]@{ Key = "HKCU:\$root"; Name = 'ProxySettings'; Value = $value; Type = 'String' }
        }
    }
    $state.CreatedKeys = @(@($state.CreatedKeys) + @($state.Changes | ForEach-Object Key |
        Where-Object { -not (Test-Path -LiteralPath $_) }) | Where-Object { $_ } | Sort-Object -Unique)
    $state
}

function Install-BrowserPolicies($State) {
    foreach ($entry in $State.Changes) {
        $key = Get-Item -LiteralPath $entry.Key -ErrorAction SilentlyContinue
        if ($key -and $entry.Name -in $key.GetValueNames() -and $key.GetValue($entry.Name) -cne $entry.Value) {
            throw "Запись политики $($entry.Key)\$($entry.Name) уже изменена."
        }
    }
    if (-not (Test-Path -LiteralPath $browserPolicyState)) { New-Item -Path $browserPolicyState -Force | Out-Null }
    New-ItemProperty -LiteralPath $browserPolicyState -Name BrowserPolicyState -Value ($State | ConvertTo-Json -Depth 8 -Compress) -Force | Out-Null
    foreach ($entry in $State.Changes) {
        if (-not (Test-Path -LiteralPath $entry.Key)) { New-Item -Path $entry.Key -Force | Out-Null }
        New-ItemProperty -LiteralPath $entry.Key -Name $entry.Name -Value $entry.Value -PropertyType $entry.Type -Force | Out-Null
    }
}

function Remove-BrowserPolicies([string]$Config) {
    $state = Get-BrowserPolicyState
    if (-not $state) { return }
    Assert-BrowserPolicyState $state $Config
    if ($state.Config -and (Test-Path -LiteralPath $state.Config)) {
        $settings = Read-ClaudeSettings $state.Config
        if ($settings.env.BROWSER -eq $state.Browser) {
            if ($state.PreviousBrowser) { $settings.env.BROWSER = $state.PreviousBrowser.Value }
            else { $settings.env.PSObject.Properties.Remove('BROWSER') }
            Save-ClaudeSettings $state.Config $settings
        }
    }
    foreach ($entry in $state.Changes) {
        $key = Get-Item -LiteralPath $entry.Key -ErrorAction SilentlyContinue
        if ($key -and $key.GetValue($entry.Name) -ceq $entry.Value) {
            Remove-ItemProperty -LiteralPath $entry.Key -Name $entry.Name
        }
    }
    foreach ($path in $state.CreatedKeys) {
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($key -and -not $key.ValueCount -and -not $key.SubKeyCount) {
            Remove-Item -LiteralPath $path
        }
    }
    Remove-ItemProperty -LiteralPath $browserPolicyState -Name BrowserPolicyState
}
