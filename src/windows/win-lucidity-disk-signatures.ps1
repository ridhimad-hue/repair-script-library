# win-lucidity-disk-signatures.ps1
# Fetches disk signatures and metadata for all disks attached to the VM
# Useful for identifying ramdisk, OS disk, and data disks in Lucidity environments

function Log-Output($msg) { Write-Output "[Output $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }
function Log-Info($msg)   { Write-Output "[Info $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }
function Log-Error($msg)  { Write-Output "[Error $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }

Log-Info "Starting disk signature collection..."

# ============================================================
# METHOD 1: Get-Disk - disk level info
# ============================================================
Log-Info "Method 1 - Get-Disk..."
try {
    $disks = Get-Disk
    foreach ($disk in $disks) {
        Log-Output "--------------------------------------------"
        Log-Output "Disk Number     : $($disk.Number)"
        Log-Output "Friendly Name   : $($disk.FriendlyName)"
        Log-Output "Serial Number   : $($disk.SerialNumber)"
        Log-Output "Signature       : $($disk.Signature)"
        Log-Output "UniqueId        : $($disk.UniqueId)"
        Log-Output "GUID            : $($disk.Guid)"
        Log-Output "Size GB         : $([math]::Round($disk.Size / 1GB, 2))"
        Log-Output "Partition Style : $($disk.PartitionStyle)"
        Log-Output "Boot Disk       : $($disk.IsBoot)"
        Log-Output "System Disk     : $($disk.IsSystem)"
        Log-Output "Operational     : $($disk.OperationalStatus)"
        Log-Output "Health Status   : $($disk.HealthStatus)"
    }
} catch {
    Log-Error "Get-Disk failed: $_"
}

# ============================================================
# METHOD 2: Get-Partition - partition level info
# ============================================================
Log-Info "Method 2 - Get-Partition..."
try {
    $partitions = Get-Partition
    foreach ($p in $partitions) {
        Log-Output "--------------------------------------------"
        Log-Output "Disk Number     : $($p.DiskNumber)"
        Log-Output "Partition Number: $($p.PartitionNumber)"
        Log-Output "Drive Letter    : $($p.DriveLetter)"
        Log-Output "Size GB         : $([math]::Round($p.Size / 1GB, 2))"
        Log-Output "Type            : $($p.Type)"
        Log-Output "Is Boot         : $($p.IsBoot)"
        Log-Output "Is System       : $($p.IsSystem)"
        Log-Output "Is Active       : $($p.IsActive)"
        Log-Output "Is Hidden       : $($p.IsHidden)"
    }
} catch {
    Log-Error "Get-Partition failed: $_"
}

# ============================================================
# METHOD 3: MountedDevices registry
# ============================================================
Log-Info "Method 3 - MountedDevices registry..."
try {
    $mountedDevices = Get-ItemProperty -Path "HKLM:\SYSTEM\MountedDevices" -ErrorAction SilentlyContinue
    if ($mountedDevices) {
        $mountedDevices.PSObject.Properties | Where-Object { $_.Name -like "\DosDevices\*" } | ForEach-Object {
            Log-Output "Drive $($_.Name) - Raw bytes: $($_.Value -join ',')"
        }
    } else {
        Log-Error "MountedDevices registry key not found"
    }
} catch {
    Log-Error "MountedDevices failed: $_"
}

# ============================================================
# METHOD 4: Lucidity Ramdisk signature
# ============================================================
Log-Info "Method 4 - Lucidity Ramdisk registry..."
try {
    $ramdiskKey = "HKLM:\SYSTEM\CurrentControlSet\Services\LucidityRamdisk"
    if (Test-Path $ramdiskKey) {
        $ramdiskProps = Get-ItemProperty -Path $ramdiskKey -ErrorAction SilentlyContinue
        Log-Output "LucidityRamdisk Start     : $($ramdiskProps.Start)"
        Log-Output "LucidityRamdisk ImagePath : $($ramdiskProps.ImagePath)"
        Log-Output "LucidityRamdisk Type      : $($ramdiskProps.Type)"
        $sigKey = "$ramdiskKey\Parameters"
        if (Test-Path $sigKey) {
            $sigProps = Get-ItemProperty -Path $sigKey -ErrorAction SilentlyContinue
            Log-Output "LucidityRamdisk Parameters: $($sigProps | Out-String)"
        } else {
            Log-Output "LucidityRamdisk Parameters key NOT FOUND"
        }
    } else {
        Log-Output "LucidityRamdisk service NOT FOUND - Lucidity not onboarded"
    }
} catch {
    Log-Error "LucidityRamdisk check failed: $_"
}

# ============================================================
# METHOD 5: Storage Pool state
# ============================================================
Log-Info "Method 5 - Storage Pool state..."
try {
    $pools = Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { $_.IsPrimordial -eq $false }
    if ($pools) {
        foreach ($pool in $pools) {
            Log-Output "--------------------------------------------"
            Log-Output "Pool Name         : $($pool.FriendlyName)"
            Log-Output "Pool Health       : $($pool.HealthStatus)"
            Log-Output "Pool Operational  : $($pool.OperationalStatus)"
            Log-Output "Pool Size GB      : $([math]::Round($pool.Size / 1GB, 2))"
        }
    } else {
        Log-Output "No storage pools found"
    }
} catch {
    Log-Error "StoragePool check failed: $_"
}

# ============================================================
# METHOD 6: Virtual Disk (mirror) state
# ============================================================
Log-Info "Method 6 - Virtual Disk state..."
try {
    $vdisks = Get-VirtualDisk -ErrorAction SilentlyContinue
    if ($vdisks) {
        foreach ($vd in $vdisks) {
            Log-Output "--------------------------------------------"
            Log-Output "VDisk Name        : $($vd.FriendlyName)"
            Log-Output "VDisk Health      : $($vd.HealthStatus)"
            Log-Output "VDisk Operational : $($vd.OperationalStatus)"
            Log-Output "VDisk Size GB     : $([math]::Round($vd.Size / 1GB, 2))"
            Log-Output "VDisk ResyncPct   : $($vd.ResyncPercentComplete)"
        }
    } else {
        Log-Output "No virtual disks found"
    }
} catch {
    Log-Error "VirtualDisk check failed: $_"
}

# ============================================================
# METHOD 7: Physical sector size (relevant to EBS-11796)
# ============================================================
Log-Info "Method 7 - Sector size registry..."
try {
    $diskParams = Get-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\disk\Parameters" `
        -ErrorAction SilentlyContinue
    if ($diskParams) {
        Log-Output "BytesPerPhysicalSector : $($diskParams.BytesPerPhysicalSector)"
        Log-Output "BytesPerLogicalSector  : $($diskParams.BytesPerLogicalSector)"
    } else {
        Log-Output "disk\Parameters key NOT FOUND"
    }
} catch {
    Log-Error "Sector size check failed: $_"
}

Log-Output "============================================"
Log-Output "SCRIPT COMPLETED"
exit 0