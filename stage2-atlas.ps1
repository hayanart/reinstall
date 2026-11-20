# stage2-atlas.ps1 — AtlasOS 0.5.0 stage-2 installer (proyek RDP Installer)
#
# Dijalankan TERPISAH (detached) sebagai administrator saat logon pertama,
# ditanam oleh windows-setup.bat lewat RunOnce (offline registry).
# Alur: unduh AME TrustedUninstaller CLI + playbook Atlas -> terapkan
# playbook lewat CLI -> tulis status agar bot bisa memantau lewat SSH.
#
# Yang dipakai di sini semuanya RILIS RESMI (bukan main/beta):
# - Atlas Playbook v0.5.0-hotfix (.apbx, 48.024.713 byte, SHA256 terverifikasi)
# - AME Beta v0.8.4 CLI-Standalone.zip (9.548.697 byte, SHA256 terverifikasi)
# - 7zr.exe (7-Zip console, untuk ekstrak .apbx yang berpassword "malte")
#
# Opsi playbook (dari playbook.conf Atlas 0.5.0, default yang disarankan):
#   defender-enable, mitigations-default, auto-updates-disable
#
# Versi: 1.0.0 (2026-11-21). Sintaks PowerShell belum dicek mesin (belum ada
# host Windows untuk pwsh) — pembuktian lewat live test di VM Windows.

$ErrorActionPreference = 'Stop'

$AtlasDir   = 'C:\Atlas'
$LogFile    = "$AtlasDir\stage2.log"
$StatusFile = "$AtlasDir\stage2.status"
$SevenZr    = "$AtlasDir\7zr.exe"
$CliZip     = "$AtlasDir\CLI-Standalone.zip"
$CliDir     = "$AtlasDir\cli"
$ApbxFile   = "$AtlasDir\AtlasPlaybook_v0.5.0-hotfix.apbx"
$PlaybookDir = "$AtlasDir\playbook"

$ApbxUrl  = 'https://github.com/Atlas-OS/Atlas/releases/download/0.5.0-hotfix/AtlasPlaybook_v0.5.0-hotfix.apbx'
$ApbxSha256 = '13c4d8e7fc0ed38c37c5942ebcabf7f636389972e6de391a192ae649967602d8'
$ApbxBytes  = 48024713
$CliUrl   = 'https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/releases/download/0.8.4/CLI-Standalone.zip'
$CliSha256 = '70e4946b52c9384ca88730c0dd25646defc63affdef7acadd69cb6317f21825a'
$CliBytes  = 9548697
$SevenZrUrl = 'https://www.7-zip.org/a/7zr.exe'

$PlaybookOptions = @('defender-enable', 'mitigations-default', 'auto-updates-disable')

if (-not (Test-Path $AtlasDir)) { New-Item -ItemType Directory -Path $AtlasDir -Force | Out-Null }

function Write-Stage2Status {
    param([string]$State, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$State|$Message|$ts" | Set-Content -Path $StatusFile -Encoding utf8 -Force
}

function Invoke-DownloadWithRetry {
    param(
        [string]$Url,
        [string]$Dest,
        [long]$ExpectedBytes = 0,
        [string]$ExpectedSha256 = ''
    )
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            if (Test-Path $Dest) { Remove-Item $Dest -Force }
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest -TimeoutSec 300
            $len = (Get-Item $Dest).Length
            if ($ExpectedBytes -gt 0 -and $len -ne $ExpectedBytes) {
                throw "ukuran $len byte, diharapkan $ExpectedBytes byte"
            }
            if ($ExpectedSha256 -ne '') {
                $hash = (Get-FileHash -Path $Dest -Algorithm SHA256).Hash.ToLower()
                if ($hash -ne $ExpectedSha256.ToLower()) {
                    throw "SHA256 $hash tidak cocok"
                }
            }
            Write-Output "OK unduh $Dest ($len byte)."
            return
        } catch {
            Write-Output "Unduh $Url gagal (percobaan $attempt/3): $($_.Exception.Message)"
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds (15 * $attempt)
        }
    }
}

function Test-RebootPending {
    # Gabungan flag reboot pending yang umum (CBS + Windows Update).
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

try {
    Start-Transcript -Path $LogFile -Append -Force | Out-Null
} catch {
    # Transcript gagal (mis. file terkunci) — lanjut tanpa transcript,
    # Write-Output tetap tercatat bila dijalankan dari console.
}

try {
    Write-Stage2Status -State 'running' -Message 'stage2 Atlas dimulai'
    Write-Output '=== stage2-atlas.ps1 v1.0.0 — mulai ==='

    # 1. Tunggu jaringan (maks ~10 menit). Driver NIC sudah dipasang tool,
    # tapi DNS / DHCP kadang butuh beberapa detik setelah boot pertama.
    $netOk = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            if (Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $netOk = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds 15
    }
    if (-not $netOk) { throw 'tidak ada jaringan setelah ~10 menit menunggu' }
    Write-Output 'Jaringan OK.'

    # 2. Nyalakan OpenSSH Server DULU supaya bot bisa memantau progres
    # (observability). Kegagalan di sini tidak menggagalkan Atlas.
    try {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
        Start-Service -Name sshd -ErrorAction Stop
        Set-Service -Name sshd -StartupType Automatic
        if (-not (Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'sshd' -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }
        # Login remote sebagai administrator harus dapat token penuh
        # (tanpa ini sesi SSH hanya dapat token terfilter UAC).
        $pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        New-ItemProperty -Path $pol -Name 'LocalAccountTokenFilterPolicy' `
            -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Output 'OpenSSH Server aktif (port 22).'
    } catch {
        Write-Output "PERINGATAN: OpenSSH gagal dinyalakan: $($_.Exception.Message) — lanjut tanpa SSH."
    }

    # 3. Bila Windows minta reboot (update tertunda), jadwalkan ulang
    # script ini sebagai tugas terjadwal SYSTEM lalu reboot. Tanpa ini,
    # playbook akan ditolak syarat NoPendingUpdates-nya.
    if (Test-RebootPending) {
        Write-Stage2Status -State 'waiting-reboot' -Message 'reboot pending, dijadwalkan ulang setelah reboot'
        Write-Output 'Reboot pending terdeteksi — menjadwalkan ulang stage2 lalu reboot.'
        schtasks /create /tn 'AtlasStage2' `
            /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Atlas\stage2-atlas.ps1" `
            /sc onstart /ru SYSTEM /rl highest /f | Out-Null
        shutdown /r /t 10 /c 'Atlas stage2: reboot untuk update tertunda' | Out-Null
        Write-Output 'Reboot dijadwalkan (10 detik).'
        try { Stop-Transcript | Out-Null } catch { }
        exit 0
    }

    # 4. Unduh 7zr + CLI + playbook (dengan verifikasi ukuran + SHA256).
    Write-Output 'Mengunduh 7zr.exe ...'
    Invoke-DownloadWithRetry -Url $SevenZrUrl -Dest $SevenZr
    $zrLen = (Get-Item $SevenZr).Length
    if ($zrLen -lt 100000) { throw "7zr.exe terlalu kecil ($zrLen byte), kemungkinan bukan file yang benar" }
    Write-Output 'Mengunduh CLI-Standalone.zip ...'
    Invoke-DownloadWithRetry -Url $CliUrl -Dest $CliZip -ExpectedBytes $CliBytes -ExpectedSha256 $CliSha256
    Write-Output 'Mengunduh AtlasPlaybook_v0.5.0-hotfix.apbx ...'
    Invoke-DownloadWithRetry -Url $ApbxUrl -Dest $ApbxFile -ExpectedBytes $ApbxBytes -ExpectedSha256 $ApbxSha256

    # 5. Ekstrak CLI (zip biasa) + playbook (.apbx = zip berpassword "malte").
    Write-Output 'Mengekstrak CLI ...'
    if (Test-Path $CliDir) { Remove-Item $CliDir -Recurse -Force }
    Expand-Archive -Path $CliZip -DestinationPath $CliDir -Force
    $CliExe = Get-ChildItem -Path $CliDir -Recurse -Filter 'TrustedUninstaller.CLI.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $CliExe) { throw 'TrustedUninstaller.CLI.exe tidak ditemukan di CLI-Standalone.zip' }
    Write-Output "CLI ditemukan: $CliExe"
    Write-Output 'Mengekstrak playbook Atlas ...'
    if (Test-Path $PlaybookDir) { Remove-Item $PlaybookDir -Recurse -Force }
    New-Item -ItemType Directory -Path $PlaybookDir -Force | Out-Null
    & $SevenZr x "-pmalte" "-o$PlaybookDir" -y $ApbxFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7zr gagal mengekstrak .apbx (exit $LASTEXITCODE)" }
    if (-not (Test-Path "$PlaybookDir\playbook.conf")) { throw 'playbook.conf tidak ditemukan setelah ekstrak — .apbx rusak?' }
    Write-Output 'Playbook terekstrak.'

    # 6. Terapkan playbook lewat CLI (sebagai administrator; CLI sendiri
    # yang menaikkan ke TrustedInstaller lewat broker-nya).
    Write-Stage2Status -State 'running' -Message 'TrustedUninstaller CLI sedang menerapkan playbook Atlas'
    Write-Output "Menjalankan CLI: $CliExe `"$PlaybookDir`" $($PlaybookOptions -join ' ')"
    $cliArgs = @($PlaybookDir) + $PlaybookOptions
    $proc = Start-Process -FilePath $CliExe -ArgumentList $cliArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$AtlasDir\cli-out.log" -RedirectStandardError "$AtlasDir\cli-err.log"
    $cliRc = $proc.ExitCode
    Write-Output "CLI selesai, exit code $cliRc."
    if (Test-Path "$AtlasDir\cli-out.log") { Get-Content "$AtlasDir\cli-out.log" -Tail 30 | Write-Output }
    if (Test-Path "$AtlasDir\cli-err.log") { Get-Content "$AtlasDir\cli-err.log" -Tail 30 | Write-Output }

    # 7. CLI kadang melepas proses anak lalu keluar duluan — tunggu sampai
    # tidak ada lagi proses TrustedUninstaller yang jalan (maks 30 menit).
    for ($i = 0; $i -lt 30; $i++) {
        $still = Get-Process -Name 'TrustedUninstaller*' -ErrorAction SilentlyContinue
        if (-not $still) { break }
        Write-Output 'Menunggu proses TrustedUninstaller selesai ...'
        Start-Sleep -Seconds 60
    }

    # 8. Verifikasi marker Atlas.
    $markers = @()
    $markerPaths = @(
        "$env:PUBLIC\Desktop\AtlasDesktop",
        'C:\Users\Administrator\Desktop\AtlasDesktop',
        'C:\Windows\AtlasModules',
        'C:\AtlasModules'
    )
    foreach ($mp in $markerPaths) {
        if (Test-Path $mp) { $markers += $mp }
    }
    Write-Output "Marker Atlas ditemukan: $($markers -join '; ')"
    if ($cliRc -eq 0 -and $markers.Count -gt 0) {
        Write-Stage2Status -State 'done' -Message "Atlas 0.5.0 terpasang (CLI exit 0; marker: $($markers -join '; '))"
        Write-Output '=== stage2 Atlas SELESAI (terverifikasi) ==='
    } elseif ($cliRc -eq 0) {
        Write-Stage2Status -State 'done-unverified' -Message 'CLI exit 0 tapi marker Atlas tidak ditemukan — verifikasi manual via RDP'
        Write-Output '=== stage2 Atlas selesai tapi TANPA marker — cek manual via RDP ==='
    } else {
        throw "TrustedUninstaller CLI gagal (exit $cliRc). Lihat cli-out.log / cli-err.log."
    }
} catch {
    $msg = $_.Exception.Message
    Write-Output "ERROR stage2: $msg"
    Write-Stage2Status -State 'failed' -Message $msg
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

try { Stop-Transcript | Out-Null } catch { }
exit 0
