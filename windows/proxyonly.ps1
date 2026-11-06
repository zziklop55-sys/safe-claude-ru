# Запускает выбранный .exe после проверки его правила Windows Firewall.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Program,
    [ValidateRange(1, 65535)][int]$ProxyPort = 10808,
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'proxyonly-common.ps1')
$path = Get-ExecutablePath $Program
Assert-ProxyOnlyRule $path

$proxy = "http://127.0.0.1:$ProxyPort"
$proxyEnv = @{ HTTP_PROXY = $proxy; HTTPS_PROXY = $proxy; ALL_PROXY = $proxy; NO_PROXY = $loopbackHosts }
$previous = @{}
try {
    foreach ($key in $proxyEnv.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $proxyEnv[$key], 'Process')
    }
    & $path @Arguments
    $code = $LASTEXITCODE
} finally {
    foreach ($key in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
    }
}
exit $code
