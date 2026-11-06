# Обновление установленного Claude Desktop MSIX через локальный HTTP-прокси.
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort = 10808,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'proxyonly-common.ps1')
. (Join-Path $PSScriptRoot 'desktop-protection.ps1')
$package = Get-ClaudeDesktopPackage
$architecture = $package.Architecture.ToString().ToLowerInvariant()
if ($architecture -notin 'x64', 'arm64') { throw "Неподдерживаемая архитектура пакета: $architecture." }

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$curlOptions = @(
    '-q', '--proxy', "http://127.0.0.1:$ProxyPort", '--noproxy', 'safe-claude-no-bypass.invalid',
    '--proto', '=https', '--connect-timeout', '10', '--fail', '--silent', '--show-error'
)
$endpoint = "https://claude.ai/api/desktop/win32/$architecture/msix/latest/redirect"
$redirect = & $curl @curlOptions --max-time 25 --output NUL --write-out '%{redirect_url}' $endpoint
if ($LASTEXITCODE) { throw "Проверка обновлений через прокси 127.0.0.1:$ProxyPort не удалась." }
$url = $null
if (-not [uri]::TryCreate(([string]$redirect).Trim(), [UriKind]::Absolute, [ref]$url) -or
    $url.Scheme -ne 'https' -or $url.Host -ne 'downloads.claude.ai' -or -not $url.IsDefaultPort -or $url.UserInfo -or
    $url.AbsolutePath -notmatch "^/releases/win32/$architecture/(\d+\.\d+\.\d+)/[^/]+\.msix$") {
    throw 'Сервер Claude вернул неожиданный адрес пакета.'
}
$version = [version]($Matches[1] + '.0')
Write-Host "Установлена версия $($package.Version). Доступна версия $version."
if ($CheckOnly) { return }

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Для установки обновления запусти Windows PowerShell от имени администратора.'
}
Set-ClaudeDesktopRules $package
Set-ClaudeDesktopProxy $ProxyPort
if ($version -le $package.Version) { return }

if (Get-Process -Name Claude -ErrorAction SilentlyContinue) {
    throw 'Перед обновлением полностью закрой Claude Desktop и его значок в области уведомлений.'
}
$path = Join-Path ([IO.Path]::GetTempPath()) ("safe-claude-" + [guid]::NewGuid().ToString('N') + '.msix')
try {
    & $curl @curlOptions --max-time 900 --output $path $url.AbsoluteUri
    if ($LASTEXITCODE) { throw 'Загрузка подписанного MSIX через прокси не удалась.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid') { throw 'Подпись MSIX не прошла проверку Windows.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw 'В MSIX отсутствует манифест.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $identity = $manifest.Package.Identity
    if ($identity.Name -ne $package.Name -or $identity.Publisher -ne $package.Publisher -or
        $identity.ProcessorArchitecture -ne $architecture -or [version]$identity.Version -ne $version) {
        throw 'Идентификатор, издатель, архитектура или версия MSIX не совпадают.'
    }
    if (Get-Process -Name Claude -ErrorAction SilentlyContinue) { throw 'Claude запущен. Закрой его перед обновлением.' }
    Add-AppxPackage -Path $path
    $updated = Get-ClaudeDesktopPackage
    if ($updated.Version -ne $version) { throw 'Windows не подтвердила установку нужной версии.' }
    Set-ClaudeDesktopRules $updated
    Write-Host "[OK] Claude Desktop обновлён до $version. Правила для новой версии проверены."
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
