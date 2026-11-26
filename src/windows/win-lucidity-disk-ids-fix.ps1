<#
.SYNOPSIS
    Analyzes disk IDs and BCD configuration for Lucidity storage pool recovery.

.DESCRIPTION
    This script runs from a rescue VM where the original boot disk and the
    Lucidity storage pool disk are both attached. It performs the following steps:
    0. Downloads win-root-recovery-tools.zip from the Lucidity orchestrator and
       extracts it to C:\tools.
    1. Locates the Lucidity storage pool (name must match Lucidity*) and its backing disk.
    2. Identifies the smaller boot disk as the other Windows disk.
    3. Checks both disks for offline status; stops if any is offline due to a
       disk/partition signature collision. For MBR disks, runs
       Migrate_StorageSpace_MBR_sync.exe -d <bootDiskId> <lucidityDiskId> first.
    4. Brings any other offline disks online.
    5. Collects MBR signatures or GPT GUIDs (disk, Windows partition, EFI partition)
       for both disks and logs them.
    6. Locates the BCD store on the boot disk (EFI partition for GPT, active
       partition for MBR), reads it with bcdedit, and reports whether the boot
       entries point to the boot disk or the Lucidity disk.
    7. If BCD points to the Lucidity disk, runs
       Migrate_StorageSpace_MBR_sync.exe -d <lucidityDiskId> <bootDiskId> to fix
       the disk signature mapping.

.NOTES
    Name:    win-lucidity-disk-ids-fix.ps1
    Author:  vlafed@lucidity.cloud

.EXAMPLE
    az vm repair run -g <rg> -n <vm> --run-id win-lucidity-disk-ids-fix --run-on-repair

.VERIFICATION
    Check the log file for the full analysis output:
Get-ChildItem "C:\Users\Public\Desktop\win-lucidity-disk-ids-fix-run-*\win-lucidity-disk-ids-fix-*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content

.VERSION
    v1.1: [Aug 2026] - Added tools download, MBR sync at Step 3, and BCD-driven signature fix at Step 7
    v1.0: [Aug 2026] - Initial release
#>

# Initialization (path-validated - matching local file layout)
$initPath = Join-Path -Path $PSScriptRoot -ChildPath 'common\setup\init.ps1'
$diskPartitionsPath = Join-Path -Path $PSScriptRoot -ChildPath 'common\helpers\Get-Disk-Partitions-v2.ps1'

if (-not (Test-Path -Path $initPath -PathType Leaf)) {
    Write-Error "Missing required dependency: $initPath"
    return 1
}
. $initPath

if (-not (Test-Path -Path $diskPartitionsPath -PathType Leaf)) {
    Log-Error "Missing required dependency: $diskPartitionsPath"
    return $STATUS_ERROR
}
. $diskPartitionsPath

# Script-level logging: create a plain text desktop log that mirrors Log-* output.
$scriptName    = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$runTimestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runOutputDir  = Join-Path -Path $env:PUBLIC -ChildPath ("Desktop\\{0}-run-{1}" -f $scriptName, $runTimestamp)
$logFilePath   = Join-Path -Path $runOutputDir -ChildPath ("{0}-{1}.log" -f $scriptName, $runTimestamp)

if (-not (Test-Path -Path $runOutputDir -PathType Container)) {
    New-Item -Path $runOutputDir -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path -Path $logFilePath -PathType Leaf)) {
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}

$script:OriginalLogOutput  = (Get-Command Log-Output  -CommandType Function).ScriptBlock
$script:OriginalLogInfo    = (Get-Command Log-Info    -CommandType Function).ScriptBlock
$script:OriginalLogWarning = (Get-Command Log-Warning -CommandType Function).ScriptBlock
$script:OriginalLogError   = (Get-Command Log-Error   -CommandType Function).ScriptBlock
$script:OriginalLogDebug   = (Get-Command Log-Debug   -CommandType Function).ScriptBlock

function Write-DesktopLogLine {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][PSObject[]]$Message
    )
    try {
        $renderedMessage = ($Message | ForEach-Object { "$_" }) -join ' '
        $line = "[{0} {1}]{2}" -f $Level, (Get-Date), $renderedMessage
        Add-Content -Path $logFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        if ($script:OriginalLogWarning) {
            & $script:OriginalLogWarning -message "Failed to append to desktop log '$logFilePath': $($_.Exception.Message)"
        }
    }
}

function Log-Output  { Param([PSObject[]]$message) & $script:OriginalLogOutput  -message $message; Write-DesktopLogLine -Level 'Output'  -Message $message }
function Log-Info    { Param([PSObject[]]$message) & $script:OriginalLogInfo    -message $message; Write-DesktopLogLine -Level 'Info'    -Message $message }
function Log-Warning { Param([PSObject[]]$message) & $script:OriginalLogWarning -message $message; Write-DesktopLogLine -Level 'Warning' -Message $message }
function Log-Error   { Param([PSObject[]]$message) & $script:OriginalLogError   -message $message; Write-DesktopLogLine -Level 'Error'   -Message $message }
function Log-Debug   { Param([PSObject[]]$message) & $script:OriginalLogDebug   -message $message; Write-DesktopLogLine -Level 'Debug'   -Message $message }

Log-Info "Starting Lucidity Disk IDs Analysis Script. Desktop log: $logFilePath"

$script_final_status = $STATUS_ERROR
$changesApplied = $false
$rescueDrive = $env:SystemDrive -replace ':', ''

# Returns the first unused drive letter from D..Z.
function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
    [char[]](68..90) | Where-Object { $used -notcontains "$_" } | Select-Object -First 1
}

# Maps OfflineReason to a human-readable string.
# Get-Disk returns OfflineReason as an integer on some Windows versions and as a
# string on others; handle both so the cast never fails.
function Get-OfflineReasonText {
    param($Reason)
    if ($Reason -is [string]) { return $Reason }
    switch ([int]$Reason) {
        0 { 'Policy' }
        1 { 'Redundant Path' }
        2 { 'Snapshot' }
        3 { 'Disk/Partition Signature Collision' }
        4 { 'Resource Exhaustion' }
        5 { 'Critical Write Failures' }
        6 { 'Data Integrity Scan Required' }
        default { "Unknown ($Reason)" }
    }
}

# Returns true when a drive letter char is non-null and printable.
function Test-ValidDriveLetter {
    param($Letter)
    -not [string]::IsNullOrWhiteSpace($Letter) -and "$Letter" -ne "`0"
}

$toolsDir = 'C:\tools'
$toolsExe = 'C:\tools\win-root-recovery-tools\recovery\disk_signature_fix\Migrate_StorageSpace_MBR_sync.exe'

# Invokes Migrate_StorageSpace_MBR_sync.exe with -d <DiskX> <DiskY> and logs the output.
# DiskX and DiskY are disk numbers as shown in diskpart.
# Returns $true if the tool ran and exited with code 0, $false otherwise.
function Invoke-MbrSync {
    param([int]$DiskX, [int]$DiskY, [string]$Context)
    if (-not (Test-Path -Path $toolsExe -PathType Leaf)) {
        Log-Warning "[$Context] Skipping MBR sync - tool not available at $toolsExe"
        return $false
    }
    Log-Output "[$Context] Running: $toolsExe -d $DiskX $DiskY"
    $output = & $toolsExe -d $DiskX $DiskY 2>&1
    $exitCode = $LASTEXITCODE
    Log-Output "[$Context] Exit code: $exitCode"
    if ($output) {
        foreach ($line in $output) { Log-Output "[$Context] $line" }
    }
    else {
        Log-Output "[$Context] (no output captured from tool)"
    }
    return ($exitCode -eq 0)
}

try {
    # -------------------------------------------------------------------------
    # Step 0 - Download and extract recovery tools
    # -------------------------------------------------------------------------
    $toolsZipUrl  = 'https://orchestrator.prod.lucidity.dev/agentinstall/win-root-recovery-tools.zip'
    $toolsZipPath = Join-Path -Path $toolsDir -ChildPath 'win-root-recovery-tools.zip'

    Log-Info "Step 0: Downloading recovery tools from $toolsZipUrl..."
    try {
        if (-not (Test-Path -Path $toolsDir -PathType Container)) {
            New-Item -Path $toolsDir -ItemType Directory -Force | Out-Null
        }
        Invoke-WebRequest -Uri $toolsZipUrl -OutFile $toolsZipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $toolsZipPath -DestinationPath $toolsDir -Force -ErrorAction Stop
        Log-Info "Recovery tools extracted to $toolsDir"
    }
    catch {
        Log-Error "Failed to download or extract recovery tools from $toolsZipUrl : $($_.Exception.Message)"
        Log-Error "Repair steps that depend on $toolsExe will be skipped."
    }

    # -------------------------------------------------------------------------
    # Step 1 - Locate the Lucidity storage pool
    # -------------------------------------------------------------------------
    Log-Info "Step 1: Searching for Lucidity storage pool..."

    $lucidityPool = Get-StoragePool -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like 'Lucidity*' -and $_.IsPrimordial -eq $false } |
        Select-Object -First 1

    if (-not $lucidityPool) {
        throw "Lucidity storage pool not found. Please attach all Lucidity data disks to the recovery VM."
    }

    Log-Info "Found storage pool: '$($lucidityPool.FriendlyName)' [Health: $($lucidityPool.HealthStatus), Status: $($lucidityPool.OperationalStatus)]"

    $lucidityVirtualDisk = $lucidityPool | Get-VirtualDisk -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lucidityVirtualDisk) {
        throw "No virtual disk found in Lucidity storage pool. Please attach all Lucidity data disks to the recovery VM."
    }

    Log-Info "Virtual disk: '$($lucidityVirtualDisk.FriendlyName)' [Health: $($lucidityVirtualDisk.HealthStatus), OperationalStatus: $($lucidityVirtualDisk.OperationalStatus)]"

    $lucidityDisk = $lucidityVirtualDisk | Get-Disk -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lucidityDisk) {
        throw "Cannot map the Lucidity virtual disk to a Windows disk object. Please attach all Lucidity data disks to the recovery VM."
    }

    Log-Info "Lucidity disk: Disk $($lucidityDisk.Number), $([math]::Round($lucidityDisk.Size / 1GB, 1)) GB, PartitionStyle=$($lucidityDisk.PartitionStyle)"

    # -------------------------------------------------------------------------
    # Step 2 - Identify the boot disk (smallest non-rescue, non-Lucidity disk
    #          that contains a Windows partition)
    #
    #   The boot disk is often not usable as-is on a repair VM:
    #     * it can be OFFLINE (it is only brought online in Step 4), and
    #     * its partitions often have NO drive letter.
    #   So before looking for \Windows\System32\config\SYSTEM we bring candidate
    #   disks online (never touching signature-collision disks) and, where a
    #   partition has no drive letter, mount it temporarily just for the probe.
    # -------------------------------------------------------------------------
    Log-Info "Step 2: Identifying boot disk..."

    $bootDisk         = $null
    $bootWindowsDrive = $null

    # The repair VM's own OS disk must never be treated as the boot disk.
    $rescueDiskNumber = $null
    $rescuePart = Get-Partition -DriveLetter $rescueDrive -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rescuePart) { $rescueDiskNumber = $rescuePart.DiskNumber }

    function Write-DiskInventory {
        foreach ($d in (Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
            $offlineText = if ($d.IsOffline) { "OFFLINE ($(Get-OfflineReasonText -Reason $d.OfflineReason))" } else { 'online' }
            Log-Info ("  Disk {0}: {1} GB, {2}, {3}, ReadOnly={4}, Name='{5}'" -f $d.Number, [math]::Round($d.Size / 1GB, 1), $d.PartitionStyle, $offlineText, $d.IsReadOnly, $d.FriendlyName)
            foreach ($pt in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
                $letter = if (Test-ValidDriveLetter $pt.DriveLetter) { "$($pt.DriveLetter):" } else { '(no letter)' }
                Log-Info ("      Part {0}: {1} MB, Type={2}, {3}" -f $pt.PartitionNumber, [math]::Round($pt.Size / 1MB), $pt.Type, $letter)
            }
        }
    }

    $candidateDisks = Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { $_.Number -ne $lucidityDisk.Number -and $_.Number -ne $rescueDiskNumber } |
        Sort-Object Size

    # 2a - bring offline candidates online. Signature-collision disks are left
    #      alone: changing them here could further alter the signatures.
    $collisionDisks = @()
    foreach ($candidate in $candidateDisks) {
        if (-not $candidate.IsOffline) { continue }
        $reasonText  = Get-OfflineReasonText -Reason $candidate.OfflineReason
        $isCollision = ($candidate.OfflineReason -eq 3) -or ("$($candidate.OfflineReason)" -match 'Collision')
        if ($isCollision) {
            Log-Warning "Disk $($candidate.Number) is OFFLINE due to '$reasonText' - not bringing it online automatically."
            $collisionDisks += $candidate.Number
            continue
        }
        try {
            Set-Disk -Number $candidate.Number -IsOffline $false -ErrorAction Stop
            Set-Disk -Number $candidate.Number -IsReadOnly $false -ErrorAction SilentlyContinue
            Log-Info "Disk $($candidate.Number) was offline ($reasonText) - brought online for boot disk detection."
        }
        catch {
            Log-Warning "Failed to bring Disk $($candidate.Number) online: $($_.Exception.Message)"
        }
    }

    # 2b - probe each online candidate for a Windows installation.
    foreach ($candidate in $candidateDisks) {
        if ($collisionDisks -contains $candidate.Number) { continue }

        foreach ($part in (Get-Partition -DiskNumber $candidate.Number -ErrorAction SilentlyContinue)) {
            if ($part.Type -eq 'Reserved') { continue }

            $dl         = $part.DriveLetter
            $tempLetter = $null

            if (Test-ValidDriveLetter $dl) {
                if ("$dl" -eq $rescueDrive) { continue }
            }
            else {
                # No drive letter (typical for a freshly attached disk): mount temporarily.
                $tempLetter = Get-FreeDriveLetter
                if (-not $tempLetter) { continue }
                try {
                    Add-PartitionAccessPath -DiskNumber $candidate.Number -PartitionNumber $part.PartitionNumber -AccessPath "${tempLetter}:\" -ErrorAction Stop
                    $dl = "$tempLetter"
                }
                catch {
                    Log-Debug "Disk $($candidate.Number) Part $($part.PartitionNumber): could not mount for probing - $($_.Exception.Message)"
                    continue
                }
            }

            $found = Test-Path -Path "${dl}:\Windows\System32\config\SYSTEM"

            if ($tempLetter) {
                # Always drop the probe letter so disk state is left as we found it.
                Remove-PartitionAccessPath -DiskNumber $candidate.Number -PartitionNumber $part.PartitionNumber -AccessPath "${tempLetter}:\" -ErrorAction SilentlyContinue
            }

            if ($found) {
                $bootDisk         = $candidate
                $bootWindowsDrive = if ($tempLetter) { "(Part $($part.PartitionNumber), no drive letter)" } else { "$dl" }
                break
            }
        }
        if ($bootDisk) { break }
    }

    if (-not $bootDisk) {
        Log-Error "Disk inventory at time of failure:"
        Write-DiskInventory
        if ($collisionDisks.Count -gt 0) {
            throw "Could not identify a boot disk with a Windows partition. Disk(s) $($collisionDisks -join ', ') are OFFLINE due to a disk signature collision and were not touched - resolve the collision (e.g. detach the colliding Lucidity disks / run the MBR sync tool) and re-run."
        }
        throw "Could not identify a boot disk with a Windows partition. Ensure both the boot disk and all Lucidity data disks are attached."
    }

    # Refresh: the online state may have changed in 2a.
    $bootDisk = Get-Disk -Number $bootDisk.Number

    Log-Info "Boot disk: Disk $($bootDisk.Number), $([math]::Round($bootDisk.Size / 1GB, 1)) GB, PartitionStyle=$($bootDisk.PartitionStyle), Windows on ${bootWindowsDrive}"

    # -------------------------------------------------------------------------
    # Step 3 - Check for disk/partition signature collision on either disk
    # -------------------------------------------------------------------------
    Log-Info "Step 3: Checking disk online status and collision..."

    foreach ($disk in @($bootDisk, $lucidityDisk)) {
        $label = if ($disk.Number -eq $bootDisk.Number) { 'Boot disk' } else { 'Lucidity disk' }
        if ($disk.IsOffline) {
            $reasonText  = Get-OfflineReasonText -Reason $disk.OfflineReason
            $isCollision = ($disk.OfflineReason -eq 3) -or ("$($disk.OfflineReason)" -match 'Collision')
            if ($isCollision) {
                throw "$label (Disk $($disk.Number)) is OFFLINE due to '$reasonText'. Resolve the collision before running this script."
            }
            Log-Warning "$label (Disk $($disk.Number)) is offline - reason: $reasonText. Will attempt to bring online."
        }
        else {
            Log-Info "$label (Disk $($disk.Number)) is online."
        }
    }

    # For MBR disks, run the signature sync tool proactively before proceeding.
    if ($bootDisk.PartitionStyle -eq 'MBR') {
        Log-Info "Step 3 (MBR): Running MBR sync with boot disk as source..."
        if (Invoke-MbrSync -DiskX $bootDisk.Number -DiskY $lucidityDisk.Number -Context 'Step3-MBR') {
            $changesApplied = $true
        }
    }

    # -------------------------------------------------------------------------
    # Step 4 - Bring offline disks online (collision disks never reach here)
    # -------------------------------------------------------------------------
    Log-Info "Step 4: Bringing offline disks online if needed..."

    foreach ($disk in @($bootDisk, $lucidityDisk)) {
        if ($disk.IsOffline) {
            try {
                Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
                Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
                Log-Info "Disk $($disk.Number) brought online."
            }
            catch {
                Log-Warning "Failed to bring Disk $($disk.Number) online: $($_.Exception.Message)"
            }
        }
    }

    # Refresh disk objects after any online state change
    $bootDisk     = Get-Disk -Number $bootDisk.Number
    $lucidityDisk = Get-Disk -Number $lucidityDisk.Number

    # -------------------------------------------------------------------------
    # Step 5 - Collect disk and partition IDs
    # -------------------------------------------------------------------------
    Log-Info "Step 5: Collecting disk and partition IDs..."

    function Get-DiskIdLines {
        param($Disk, [string]$Label)

        $lines = @()
        $lines += "[$Label] Disk $($Disk.Number) - PartitionStyle: $($Disk.PartitionStyle), Size: $([math]::Round($Disk.Size / 1GB, 1)) GB"
        $partitions = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue

        if ($Disk.PartitionStyle -eq 'GPT') {
            $lines += "  Disk GUID            : $($Disk.Guid)"
            $efi = $partitions | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
            $win = $partitions | Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' } | Select-Object -First 1
            if ($efi) {
                $lines += "  EFI Partition GUID   : $($efi.Guid)  (#$($efi.PartitionNumber))"
            }
            else {
                $lines += "  EFI Partition GUID   : not found"
            }
            if ($win) {
                $lines += "  Windows Part. GUID   : $($win.Guid)  (#$($win.PartitionNumber))"
            }
            else {
                $lines += "  Windows Part. GUID   : not found"
            }
        }
        elseif ($Disk.PartitionStyle -eq 'MBR') {
            $lines += "  Disk Signature       : 0x{0:X8}" -f $Disk.Signature
            $active = $partitions | Where-Object { $_.IsActive -eq $true }      | Select-Object -First 1
            $win    = $partitions | Where-Object { $_.MbrType  -eq 7 }          | Select-Object -First 1
            if ($active) {
                $lines += "  Active Partition     : #$($active.PartitionNumber), Offset $($active.Offset) B, $([math]::Round($active.Size / 1MB)) MB"
            }
            if ($win) {
                $lines += "  NTFS Partition       : #$($win.PartitionNumber), Offset $($win.Offset) B, $([math]::Round($win.Size / 1MB)) MB"
            }
        }
        else {
            $lines += "  (unsupported partition style: $($Disk.PartitionStyle))"
        }

        return $lines
    }

    Log-Info "--- Disk ID Report ---"
    foreach ($line in (Get-DiskIdLines -Disk $bootDisk     -Label 'BOOT DISK'))     { Log-Info $line }
    foreach ($line in (Get-DiskIdLines -Disk $lucidityDisk -Label 'LUCIDITY DISK')) { Log-Info $line }

    # -------------------------------------------------------------------------
    # Step 6 - BCD analysis
    #   GPT: BCD is at \EFI\Microsoft\Boot\BCD on the EFI System Partition
    #   MBR: BCD is at \Boot\BCD on the Active partition
    # -------------------------------------------------------------------------
    Log-Info "Step 6: BCD analysis..."

    # Track whether we temporarily assigned a drive letter so we can remove it.
    $bcdTempDiskNum          = $null
    $bcdTempPartNum          = $null
    $bcdTempDrive            = $null
    $skipTempDriveCleanup    = $false

    try {
        $bcdStorePath    = $null
        $bcdDriveLetter  = $null

        if ($bootDisk.PartitionStyle -eq 'GPT') {
            $esp = Get-Partition -DiskNumber $bootDisk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
                Select-Object -First 1

            if (-not $esp) { throw "No EFI System Partition found on boot disk (Disk $($bootDisk.Number))." }

            if (Test-ValidDriveLetter $esp.DriveLetter) {
                $bcdDriveLetter = "$($esp.DriveLetter)"
            }
            else {
                $bcdTempDrive   = Get-FreeDriveLetter
                $bcdTempDiskNum = $bootDisk.Number
                $bcdTempPartNum = $esp.PartitionNumber
                Add-PartitionAccessPath -DiskNumber $bcdTempDiskNum -PartitionNumber $bcdTempPartNum -AccessPath "${bcdTempDrive}:\" -ErrorAction Stop
                $bcdDriveLetter = $bcdTempDrive
                Log-Info "Temporarily mounted EFI partition (Disk $bcdTempDiskNum, Part $bcdTempPartNum) as ${bcdTempDrive}:"
            }

            $bcdStorePath = "${bcdDriveLetter}:\EFI\Microsoft\Boot\BCD"
        }
        elseif ($bootDisk.PartitionStyle -eq 'MBR') {
            $activePart = Get-Partition -DiskNumber $bootDisk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.IsActive -eq $true } |
                Select-Object -First 1

            if (-not $activePart) { throw "No active partition found on boot disk (Disk $($bootDisk.Number))." }

            if (Test-ValidDriveLetter $activePart.DriveLetter) {
                $bcdDriveLetter = "$($activePart.DriveLetter)"
            }
            else {
                $bcdTempDrive   = Get-FreeDriveLetter
                $bcdTempDiskNum = $bootDisk.Number
                $bcdTempPartNum = $activePart.PartitionNumber
                Add-PartitionAccessPath -DiskNumber $bcdTempDiskNum -PartitionNumber $bcdTempPartNum -AccessPath "${bcdTempDrive}:\" -ErrorAction Stop
                $bcdDriveLetter = $bcdTempDrive
                Log-Info "Temporarily mounted active partition (Disk $bcdTempDiskNum, Part $bcdTempPartNum) as ${bcdTempDrive}:"
            }

            $bcdStorePath = "${bcdDriveLetter}:\Boot\BCD"
        }
        else {
            throw "Boot disk has unsupported partition style: $($bootDisk.PartitionStyle)"
        }

        if (-not (Test-Path -Path $bcdStorePath)) {
            throw "BCD store not found at expected path: $bcdStorePath"
        }

        Log-Info "BCD store: $bcdStorePath"
        $bcdRaw = & bcdedit.exe /store $bcdStorePath /enum all 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "bcdedit exited with code $LASTEXITCODE : $($bcdRaw -join ' | ')"
        }

        # Parse only the {default} boot loader entry and resolve its device field.
        # bcdedit fields start at column 0, so regexes use ^\s* not ^\s+.
        # Pre-load all partitions once to avoid repeated calls inside the loop.
        $allPartitions  = Get-Partition -ErrorAction SilentlyContinue
        $bcdFindings    = @()
        $currentEntry   = ''
        $inDefaultEntry = $false

        foreach ($line in $bcdRaw) {
            if ($line -match '^-{5,}') {
                $currentEntry   = ''
                $inDefaultEntry = $false
            }
            elseif ($line -match '^\s*identifier\s+(.+)') {
                $currentEntry   = $matches[1].Trim()
                $inDefaultEntry = ($currentEntry -eq '{default}')
            }
            elseif ($inDefaultEntry -and $line -match '^\s*(device|osdevice)\s+partition=([A-Za-z]):') {
                $field = $matches[1]
                $dl    = $matches[2].ToUpper()
                $part  = $allPartitions | Where-Object { "$($_.DriveLetter)" -eq $dl } | Select-Object -First 1
                if ($part) {
                    $target = if     ($part.DiskNumber -eq $bootDisk.Number)     { 'BOOT DISK' }
                              elseif ($part.DiskNumber -eq $lucidityDisk.Number) { 'LUCIDITY DISK' }
                              else                                                { "Disk $($part.DiskNumber) [UNKNOWN]" }
                    $bcdFindings += "  entry=$currentEntry  $field -> ${dl}: (Disk $($part.DiskNumber)) => $target"
                }
                else {
                    $bcdFindings += "  entry=$currentEntry  $field -> ${dl}: (drive not mapped to any partition)"
                }
            }
            elseif ($inDefaultEntry -and $line -match '^\s*(device|osdevice)\s+(.+)') {
                $bcdFindings += "  entry=$currentEntry  $($matches[1]) -> $($matches[2].Trim()) [non-letter reference]"
            }
        }

        Log-Info "--- BCD Device References ---"
        if ($bcdFindings.Count -gt 0) {
            foreach ($f in $bcdFindings) { Log-Info $f }
        }
        else {
            Log-Warning "No device/osdevice references found in BCD output. Raw bcdedit output:"
            foreach ($line in $bcdRaw) { Log-Info "  [bcdedit] $line" }
        }

        # Summary verdict
        $pointsToBoot     = $bcdFindings | Where-Object { $_ -match 'BOOT DISK' }
        $pointsToLucidity = $bcdFindings | Where-Object { $_ -match 'LUCIDITY DISK' }

        if ($pointsToBoot -and $pointsToLucidity) {
            Log-Output "BCD FINDING: BCD references BOTH the boot disk and the Lucidity disk - mixed configuration detected."
        }
        elseif ($pointsToBoot) {
            Log-Output "BCD FINDING: BCD points exclusively to the BOOT DISK."
        }
        elseif ($pointsToLucidity) {
            Log-Output "BCD FINDING: BCD points exclusively to the LUCIDITY DISK - boot configuration references the storage pool disk."
        }
        else {
            Log-Output "BCD FINDING: Could not resolve BCD device references to either known disk. Review entries above."
        }

        # -------------------------------------------------------------------------
        # Step 7 - Fix disk signature mapping when BCD points to the Lucidity disk
        # -------------------------------------------------------------------------
        if ($pointsToLucidity -and -not $pointsToBoot) {
            Log-Info "Step 7: BCD points to Lucidity disk - running MBR sync with Lucidity disk as source..."
            if (Invoke-MbrSync -DiskX $lucidityDisk.Number -DiskY $bootDisk.Number -Context 'Step7-BCD') {
                $changesApplied       = $true
                $skipTempDriveCleanup = $true
            }
        }
        elseif ($pointsToBoot -and -not $pointsToLucidity) {
            Log-Info "Step 7: BCD points to boot disk - running MBR sync with boot disk as source..."
            if (Invoke-MbrSync -DiskX $bootDisk.Number -DiskY $lucidityDisk.Number -Context 'Step7-BCD') {
                $changesApplied       = $true
                $skipTempDriveCleanup = $true
            }
        }

        $script_final_status = $STATUS_SUCCESS
        $changesText = if ($changesApplied) { 'TRUE' } else { 'FALSE' }
        Log-Output "SCRIPT FINISHED PROPERLY, CHANGES_APPLIED=$changesText"
    }
    finally {
        # Remove the temporary drive letter if we assigned one, unless the sync tool
        # already put the disk offline (making the access path invalid).
        if ($null -ne $bcdTempDiskNum -and $null -ne $bcdTempPartNum -and $null -ne $bcdTempDrive) {
            if ($skipTempDriveCleanup) {
                Log-Info "Skipping temp drive letter cleanup - disks were put offline by the sync tool."
            }
            else {
                try {
                    Remove-PartitionAccessPath -DiskNumber $bcdTempDiskNum -PartitionNumber $bcdTempPartNum -AccessPath "${bcdTempDrive}:\" -ErrorAction Stop
                    Log-Info "Removed temporary drive letter ${bcdTempDrive}:"
                }
                catch {
                    Log-Warning "Failed to remove temporary drive letter ${bcdTempDrive}: - $($_.Exception.Message)"
                }
            }
        }
    }
}
catch {
    Log-Error "An unexpected error occurred: $($_.Exception.Message)"
    $script_final_status = $STATUS_ERROR
}
finally {
    Log-Info "Script ended at $(Get-Date)"
}

return $script_final_status
