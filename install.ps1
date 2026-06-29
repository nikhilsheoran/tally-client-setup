$ErrorActionPreference = "Stop"

$RepoRawBase = "https://raw.githubusercontent.com/nikhilsheoran/tally-client-setup/main"
$ConfigUrl = "$RepoRawBase/client-config.json"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdminIfNeeded {
    if (Test-IsAdmin) {
        return
    }

    Write-Host "This setup needs administrator permission." -ForegroundColor Yellow
    Write-Host "A Windows permission prompt will open now."
    $command = "irm '$RepoRawBase/install.ps1' | iex"
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
    exit
}

function Get-SetupConfig {
    try {
        Write-Host "Fetching latest setup config..."
        return (Invoke-RestMethod -Uri $ConfigUrl -UseBasicParsing)
    }
    catch {
        Write-Host "Could not fetch online config. Using built-in defaults." -ForegroundColor Yellow
        return [pscustomobject]@{
            serverHost = "az-server.tailf5cd20.ts.net"
            excelShareName = "ExcelFolderD"
            driveLetter = "Z"
            rdpApps = @(
                [pscustomobject]@{
                    name = "TallyPrime"
                    remoteApplicationName = "TallyPrime"
                    remoteApplicationProgram = "||TallyPrime"
                    fileName = "TallyPrime.rdp"
                },
                [pscustomobject]@{
                    name = "TallyPrime1"
                    remoteApplicationName = "TallyPrime1"
                    remoteApplicationProgram = "||TallyPrime1"
                    fileName = "TallyPrime1.rdp"
                }
            )
        }
    }
}

function Find-TailscaleExe {
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Install-TailscaleIfMissing {
    $tailscale = Find-TailscaleExe
    if ($tailscale) {
        Write-Host "Tailscale is installed."
        return $tailscale
    }

    Write-Host "Tailscale is not installed. Installing it now..."
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        & winget install --id Tailscale.Tailscale --silent --accept-package-agreements --accept-source-agreements
    }
    else {
        $installer = Join-Path $env:TEMP "tailscale-setup-latest.exe"
        Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" -OutFile $installer -UseBasicParsing
        Start-Process -FilePath $installer -ArgumentList "/quiet" -Wait
    }

    Start-Sleep -Seconds 3
    $tailscale = Find-TailscaleExe
    if (-not $tailscale) {
        throw "Tailscale install did not finish correctly. Please install Tailscale manually and run setup again."
    }

    return $tailscale
}

function Ensure-TailscaleConnected {
    param(
        [string]$TailscaleExe,
        [string]$ServerHost
    )

    $service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        Start-Service -Name Tailscale
        Start-Sleep -Seconds 2
    }

    $isConnected = $false
    try {
        $statusRaw = & $TailscaleExe status --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $statusRaw) {
            $status = $statusRaw | ConvertFrom-Json
            $isConnected = ($status.BackendState -eq "Running")
        }
    }
    catch {
        $isConnected = $false
    }

    if (-not $isConnected) {
        Write-Host ""
        Write-Host "Please sign in to Tailscale in the window that opens." -ForegroundColor Yellow
        Start-Process $TailscaleExe -ArgumentList "up"
        Read-Host "After Tailscale says Connected, press Enter here"
    }

    try {
        Resolve-DnsName $ServerHost -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "Could not resolve $ServerHost yet." -ForegroundColor Yellow
        Read-Host "Confirm Tailscale is connected, then press Enter to continue"
    }
}

function Select-RdpApps {
    param([array]$Apps)

    Write-Host ""
    Write-Host "Which Tally shortcut do you need?"
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $Apps[$i].name)
    }
    Write-Host ("{0}. Both" -f ($Apps.Count + 1))
    Write-Host ("{0}. Skip Tally shortcuts" -f ($Apps.Count + 2))

    while ($true) {
        $answer = (Read-Host "Enter choice number").Trim()
        if ($answer -match "^\d+$") {
            $choice = [int]$answer
            if ($choice -ge 1 -and $choice -le $Apps.Count) {
                return @($Apps[$choice - 1])
            }
            if ($choice -eq ($Apps.Count + 1)) {
                return @($Apps)
            }
            if ($choice -eq ($Apps.Count + 2)) {
                return @()
            }
        }
        Write-Host "Please enter a valid choice." -ForegroundColor Yellow
    }
}

function Write-RdpShortcut {
    param(
        [pscustomobject]$App,
        [string]$ServerHost,
        [string]$Desktop
    )

    $path = Join-Path $Desktop $App.fileName
    $content = @(
        "alternate full address:s:$ServerHost",
        "alternate shell:s:rdpinit.exe",
        "full address:s:$ServerHost",
        "remoteapplicationmode:i:1",
        "remoteapplicationname:s:$($App.remoteApplicationName)",
        "remoteapplicationprogram:s:$($App.remoteApplicationProgram)",
        "disableremoteappcapscheck:i:1",
        "drivestoredirect:s:*",
        "redirectcomports:i:1",
        "span monitors:i:1",
        "use multimon:i:1",
        "prompt for credentials:i:1"
    )

    Set-Content -Path $path -Value $content -Encoding ASCII
    Write-Host "Created/updated $path"
}

function Save-WindowsCredential {
    param([string]$ServerHost)

    Write-Host ""
    Write-Host "Enter your az-server Windows login for drive access."
    Write-Host "Example username format: az-server\aman"
    $username = Read-Host "Username"
    $securePassword = Read-Host "Password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        & cmdkey.exe "/add:$ServerHost" "/user:$username" "/pass:$plainPassword" | Out-Null
        & cmdkey.exe "/add:TERMSRV/$ServerHost" "/user:$username" "/pass:$plainPassword" | Out-Null
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Ensure-NetworkDrive {
    param(
        [string]$DriveLetter,
        [string]$SharePath
    )

    $driveName = $DriveLetter.TrimEnd(":")
    $existing = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.DisplayRoot -eq $SharePath -or $existing.Root -eq $SharePath) {
            Write-Host "$DriveLetter`: already points to $SharePath"
            return
        }

        Write-Host "$DriveLetter`: is already in use for $($existing.Root)." -ForegroundColor Yellow
        $confirm = Read-Host "Replace it with $SharePath? Type YES to continue"
        if ($confirm -ne "YES") {
            throw "Drive mapping was cancelled."
        }

        net use "$DriveLetter`:" /delete /y | Out-Null
    }

    net use "$DriveLetter`:" $SharePath /persistent:yes | Out-Null
    Write-Host "Mapped $DriveLetter`: to $SharePath"
}

function Write-DesktopShortcut {
    param(
        [string]$Desktop,
        [string]$Name,
        [string]$Target
    )

    $shortcutPath = Join-Path $Desktop "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $Target
    $shortcut.Save()
    Write-Host "Created/updated $shortcutPath"
}

Restart-AsAdminIfNeeded

Write-Host ""
Write-Host "Tally client setup" -ForegroundColor Cyan
Write-Host "This will set up Tailscale, Tally RDP shortcuts, and the ExcelFolderD drive."

$config = Get-SetupConfig
$desktop = [Environment]::GetFolderPath("Desktop")
$serverHost = $config.serverHost
$driveLetter = $config.driveLetter
$sharePath = "\\$serverHost\$($config.excelShareName)"

$tailscale = Install-TailscaleIfMissing
Ensure-TailscaleConnected -TailscaleExe $tailscale -ServerHost $serverHost

$selectedApps = Select-RdpApps -Apps @($config.rdpApps)
if ($selectedApps.Count -eq 0) {
    Write-Host "Skipping Tally shortcut setup."
}
else {
    foreach ($app in $selectedApps) {
        Write-RdpShortcut -App $app -ServerHost $serverHost -Desktop $desktop
    }
}

Save-WindowsCredential -ServerHost $serverHost
Ensure-NetworkDrive -DriveLetter $driveLetter -SharePath $sharePath
Write-DesktopShortcut -Desktop $desktop -Name $config.excelShareName -Target "$driveLetter`:\"

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "You can now open the Tally shortcut from Desktop and use $driveLetter`: for $($config.excelShareName)."
Read-Host "Press Enter to close"
