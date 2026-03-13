$minimumVersion = [version]'5.0.0'
$available = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

if (-not $available -or $available.Version -lt $minimumVersion) {
    Write-Error 'Pester 5.0.0 or newer is required for this repository. Install it with: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}

Import-Module Pester -MinimumVersion 5.0.0 -Force
Invoke-Pester -Path (Join-Path -Path $PSScriptRoot -ChildPath '.') -Output Detailed
