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

# The Mac connects to this PC on TCP 47900. The rule covers every network type (Windows often labels a
# home network "Public") but only accepts traffic from the local network, never from the internet.
function Add-MacConnectFirewallRule {
    param([string]$Program)
    foreach ($name in 'MacConnect Viewer', 'MacConnect Viewer Beacon') {
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }
    New-NetFirewallRule -DisplayName 'MacConnect Viewer' -Direction Inbound -Action Allow `
        -Program $Program -Protocol TCP -LocalPort 47900 -Profile Any -RemoteAddress LocalSubnet | Out-Null
}

if ($FirewallOnly) {
    if (-not $Exe) {
        throw 'Firewall setup needs the viewer executable path.'
    }
    Add-MacConnectFirewallRule -Program $Exe
    Write-Host 'Allowed MacConnect through the firewall.'
    exit 0
}

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
if (-not (Test-Path $dotnet)) {
    throw 'The .NET 8 SDK is required. Install it from https://dotnet.microsoft.com/download/dotnet/8.0 and run this script again.'
}

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'windows\MacConnectViewer\MacConnectViewer.csproj'
$publish = Join-Path $env:LOCALAPPDATA 'MacConnect\Viewer'

# A running copy locks its own files, so it has to stop before it can be replaced.
$running = Get-Process -Name 'MacConnectViewer' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host 'Stopping the running viewer...'
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}

Write-Host "Publishing MacConnect Viewer to $publish"
& $dotnet publish $project -c Release -o $publish
if ($LASTEXITCODE -ne 0) {
    throw 'Publish failed. The previous version was left in place if it had been installed.'
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
Write-Host 'The viewer will start when you sign in to Windows.'

if (Test-Admin) {
    Add-MacConnectFirewallRule -Program $exe
    Write-Host 'Allowed MacConnect through the firewall.'
} else {
    Write-Host 'Windows will ask for administrator approval so the Mac can connect.'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FirewallOnly -Exe `"$exe`""
    $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    if ($elevated.ExitCode -ne 0) {
        Write-Warning 'The firewall rule was not added, so the Mac may not be able to connect. Run this script again and approve the administrator prompt.'
    }
}

Start-Process -FilePath $exe
Write-Host 'MacConnect Viewer is running. Leave this PC on and signed in.'
Write-Host "This PC's address on your network (useful as a backup, see README):"
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
    ForEach-Object { Write-Host "  $($_.IPAddress)" }
