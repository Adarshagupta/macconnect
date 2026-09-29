#Requires -Version 5.1
param(
    [switch]$FirewallOnly,
    [string]$Exe
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-MacConnectFirewallRule {
    param([string]$Program)
    Get-NetFirewallRule -DisplayName 'MacConnect Viewer' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'MacConnect Viewer Beacon' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'MacConnect Viewer' -Direction Inbound -Action Allow -Program $Program -Protocol TCP -LocalPort 47900 -Profile Private, Domain | Out-Null
    New-NetFirewallRule -DisplayName 'MacConnect Viewer Beacon' -Direction Inbound -Action Allow -Program $Program -Protocol UDP -LocalPort 47901 -Profile Private, Domain | Out-Null
}

if ($FirewallOnly) {
    if (-not $Exe) {
        throw 'Firewall setup needs the viewer executable path.'
    }
    Add-MacConnectFirewallRule -Program $Exe
    Write-Host "Allowed MacConnect through the firewall."
    exit 0
}

$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
if (-not (Test-Path $dotnet)) {
    throw "The .NET 8 SDK is required. Install it from https://dotnet.microsoft.com/download/dotnet/8.0 and run this script again."
}

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'windows\MacConnectViewer\MacConnectViewer.csproj'
$publish = Join-Path $env:LOCALAPPDATA 'MacConnect\Viewer'

Write-Host "Publishing MacConnect Viewer to $publish"
& $dotnet publish $project -c Release -o $publish
if ($LASTEXITCODE -ne 0) {
    throw 'Publish failed.'
}

$exe = Join-Path $publish 'MacConnectViewer.exe'
if (-not (Test-Path $exe)) {
    throw "Could not find $exe"
}

$startup = [Environment]::GetFolderPath('Startup')
$shortcut = Join-Path $startup 'MacConnect Viewer.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $publish
$link.Description = 'Show a Mac desktop on this PC'
$link.Save()
Write-Host "The viewer will start when you sign in to Windows."

if (Test-Admin) {
    Add-MacConnectFirewallRule -Program $exe
    Write-Host 'Allowed MacConnect through the firewall.'
} else {
    Write-Host 'Windows will ask for administrator approval so the Mac can connect.'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FirewallOnly -Exe `"$exe`""
    $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    if ($elevated.ExitCode -ne 0) {
        Write-Warning 'The firewall rule was not added. Allow MacConnectViewer.exe if Windows asks, or run this script again as administrator.'
    }
}

$existing = Get-Process -Name 'MacConnectViewer' -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Process -Name 'MacConnectViewer' -Force
    Start-Sleep -Seconds 1
}
Start-Process -FilePath $exe
Write-Host 'MacConnect Viewer is running. Leave this PC on and signed in.'
