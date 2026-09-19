<#
.SYNOPSIS
  Read-only structural inspection of a Xiaomi Redmi AC2100 (RM2100) stock NAND dump.

.DESCRIPTION
  Verifies dump file sizes against the stock /proc/mtd table, sniffs binary
  formats (uImage, UBI EC headers, UBIFS, squashfs), parses uImage headers,
  proves dump self-consistency by comparing every partition against the
  matching byte range of mtd0-ALL.bin, and identifies the bootloader.

  REDACTION BY DESIGN: never prints Factory/Bdata/Config/cfg_bak contents,
  MAC addresses, NVRAM values, or credentials. For data partitions only
  structural classifications (format, fill ratio) are reported.

  Read-only: this script writes nothing into the dump directory.

.PARAMETER DumpDir
  Path to the dump directory. Default: dump-20260919-163622 (relative to cwd).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\inspect-stock.ps1 -DumpDir dump-20260919-163622
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DumpDir = "dump-20260919-163622"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Expected stock layout (from dump proc-mtd.txt; erase block 0x20000) ----
$ExpectedLayout = [ordered]@{
    "mtd1-Bootloader.bin"  = 0x00080000
    "mtd2-Config.bin"      = 0x00040000
    "mtd3-Bdata.bin"       = 0x00040000
    "mtd4-Factory.bin"     = 0x00040000
    "mtd5-crash.bin"       = 0x00040000
    "mtd6-crash_syslog.bin"= 0x00040000
    "mtd7-cfg_bak.bin"     = 0x00040000
    "mtd8-kernel0.bin"     = 0x00400000
    "mtd9-kernel1.bin"     = 0x00400000
    "mtd10-rootfs0.bin"    = 0x01A00000
    "mtd11-rootfs1.bin"    = 0x01A00000
    "mtd12-overlay.bin"    = 0x02600000
    "mtd13-obr.bin"        = 0x01B80000
}
# Logical (gluebi/UBI) views - not part of mtd0 tiling.
$LogicalLayout = [ordered]@{
    "mtd14-ubi_rootfs.bin" = 0x00C1C000   # ubi0 volume "ubi_rootfs", 100 LEBs x 124 KiB
}
# Writable at router runtime; mtd0-ALL and the per-partition dumps were taken in
# separate passes, so these are EXPECTED to differ between the two.
$WritablePartitions = @("mtd7-cfg_bak.bin", "mtd12-overlay.bin")

function Read-Bytes([string]$Path, [long]$Offset, [int]$Count) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $Count
        $read = 0
        while ($read -lt $Count) {
            $n = $fs.Read($buf, $read, $Count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt $Count) { return $buf[0..($read - 1)] }
        return $buf
    }
    finally { $fs.Dispose() }
}

function Get-FillStats([string]$Path) {
    # Returns [pscustomobject] with erased (0xFF) and zero (0x00) ratios over the whole file.
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 1MB
        [long]$total = 0; [long]$ff = 0; [long]$zero = 0
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            for ($i = 0; $i -lt $n; $i++) {
                if ($buf[$i] -eq 0xFF) { $ff++ }
                elseif ($buf[$i] -eq 0x00) { $zero++ }
            }
            $total += $n
        }
        return [pscustomobject]@{
            Total       = $total
            ErasedRatio = if ($total) { [math]::Round($ff / $total, 4) } else { 0 }
            ZeroRatio   = if ($total) { [math]::Round($zero / $total, 4) } else { 0 }
        }
    }
    finally { $fs.Dispose() }
}

function Get-Ascii([byte[]]$Bytes) {
    return -join ($Bytes | ForEach-Object {
            if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' }
        })
}

$script:CrcTable = $null
function Get-Crc32([byte[]]$Bytes) {
    # CRC-32 (ISO 3309). All math in [long] to avoid PS 5.1 signed-bitwise pitfalls.
    if ($null -eq $script:CrcTable) {
        $script:CrcTable = New-Object long[] 256
        for ($i = 0; $i -lt 256; $i++) {
            [long]$c = $i
            for ($k = 0; $k -lt 8; $k++) {
                $c = if (($c -band 1) -ne 0) { (0xEDB88320L -bxor ($c -shr 1)) } else { ($c -shr 1) }
            }
            $script:CrcTable[$i] = $c
        }
    }
    [long]$crc = 0xFFFFFFFFL
    foreach ($b in $Bytes) { $crc = $script:CrcTable[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8) }
    return ($crc -bxor 0xFFFFFFFFL)
}

function Read-UImage([string]$Path) {
    # Parses a legacy U-Boot uImage header (64 bytes, big-endian fields).
    $h = Read-Bytes $Path 0 64
    if ($h.Length -lt 64) { return $null }
    $be32 = { param($o) [long]( ([long]$h[$o] * 0x1000000) + ([long]$h[$o + 1] * 0x10000) + ([long]$h[$o + 2] * 0x100) + [long]$h[$o + 3] ) }
    $magic = & $be32 0
    if ($magic -ne 0x27051956) { return $null }
    $hcrc = & $be32 4
    $hZeroed = [byte[]]$h.Clone()
    for ($i = 4; $i -lt 8; $i++) { $hZeroed[$i] = 0 }
    $crcOk = (Get-Crc32 $hZeroed) -eq $hcrc
    $nameBytes = $h[32..63]
    $name = (-join ($nameBytes | ForEach-Object { if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } })).TrimEnd("`0", ' ')
    $archMap = @{ 2 = "arm"; 3 = "i386"; 5 = "mips"; 7 = "ppc"; 8 = "mips64" }
    $osMap = @{ 5 = "Linux" }
    $typeMap = @{ 2 = "kernel"; 3 = "ramdisk"; 4 = "multi"; 5 = "firmware"; 6 = "script"; 7 = "filesystem" }
    $compMap = @{ 0 = "none"; 1 = "gzip"; 2 = "bzip2"; 3 = "lzma"; 4 = "lzo"; 5 = "lz4"; 6 = "zstd" }
    return [pscustomobject]@{
        Name      = $name
        Timestamp = [DateTimeOffset]::FromUnixTimeSeconds([long](& $be32 8)).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss'Z'")
        DataSize  = & $be32 12
        LoadAddr  = "0x{0:X8}" -f (& $be32 16)
        EntryAddr = "0x{0:X8}" -f (& $be32 20)
        OS        = $osMap[[int]$h[24]]; Arch = $archMap[[int]$h[25]]
        Type      = $typeMap[[int]$h[26]]; Comp = $compMap[[int]$h[27]]
        HdrCrcOk  = $crcOk
    }
}

function Test-Ubi([string]$Path, [long]$FileSize) {
    # Counts PEBs (128 KiB) whose first 4 bytes are the UBI EC magic "UBI#" (sampled: all PEBs).
    $peb = 0x20000
    [long]$n = [math]::Floor($FileSize / $peb)
    [int]$ok = 0
    for ($i = 0; $i -lt $n; $i++) {
        $b = Read-Bytes $Path ($i * $peb) 4
        if ($b.Length -eq 4 -and $b[0] -eq 0x55 -and $b[1] -eq 0x42 -and $b[2] -eq 0x49 -and $b[3] -eq 0x23) { $ok++ }
    }
    return [pscustomobject]@{ Pebs = $n; EcOk = $ok }
}

function Get-PrintableKvClass([string]$Path) {
    # Classifies a (potentially sensitive) data partition WITHOUT emitting content.
    $b = Read-Bytes $Path 0 4096
    if ($b.Length -eq 0) { return "empty" }
    [int]$printable = 0; [int]$ff = 0; [int]$eq = 0
    foreach ($x in $b) {
        if ($x -eq 0xFF) { $ff++ }
        if ($x -ge 0x20 -and $x -le 0x7E) { $printable++ }
        if ($x -eq 0x3D) { $eq++ }
    }
    $pr = [math]::Round($printable / $b.Length, 3)
    if ($ff -gt ($b.Length * 0.95)) { return "mostly erased (0xFF)" }
    if ($pr -gt 0.85 -and $eq -gt 3) { return "text key=value store (contents redacted)" }
    if ($pr -gt 0.85) { return "mostly ASCII text (contents redacted)" }
    return "binary/structured (contents redacted)"
}

function Find-BootloaderStrings([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sb = New-Object System.Text.StringBuilder
    $runs = New-Object System.Collections.Generic.List[string]
    foreach ($x in $bytes) {
        if ($x -ge 0x20 -and $x -le 0x7E) { [void]$sb.Append([char]$x) }
        else {
            if ($sb.Length -ge 8) { $runs.Add($sb.ToString()) }
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -ge 8) { $runs.Add($sb.ToString()) }
    $keywords = @("U-Boot", "CFE", "Breed", "BREED", "MT7621", "MTK", "Xiaomi", "RM2100",
        "flag_boot", "boot_wait", "tftp", "nand", "Press any key", "autoboot", "bootm")
    foreach ($kw in $keywords) {
        $hits = @($runs | Where-Object { $_.Contains($kw) } | Select-Object -First 2)
        if ($hits.Count -gt 0) {
            $samples = ($hits | ForEach-Object { if ($_.Length -gt 72) { $_.Substring(0, 72) + "..." } else { $_ } }) -join " | "
            Write-Output ("    [{0}] {1} sample(s): {2}" -f $kw, $hits.Count, $samples)
        }
    }
    Write-Output ("    total ASCII runs (>=8 chars): {0}" -f $runs.Count)
}

function Get-RangeSha256([string]$Path, [long]$Offset, [long]$Length) {
    # Streams exactly $Length bytes from $Offset and returns the lowercase hex SHA-256.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] 1MB
        [long]$remain = $Length
        while ($remain -gt 0) {
            $want = [int][math]::Min($buf.Length, $remain)
            $n = $fs.Read($buf, 0, $want)
            if ($n -le 0) { break }
            if ($n -eq $remain) { [void]$sha.TransformFinalBlock($buf, 0, $n) }
            else { [void]$sha.TransformBlock($buf, 0, $n, $buf, 0) }
            $remain -= $n
        }
        if ($remain -gt 0) { [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) }
        return ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ""
    }
    finally { $fs.Dispose(); $sha.Dispose() }
}

# ---------------------------------------------------------------- main ------
if (-not (Test-Path -LiteralPath $DumpDir -PathType Container)) {
    throw "Dump directory not found: $DumpDir"
}
$DumpDir = (Resolve-Path -LiteralPath $DumpDir).Path
Write-Output "== inspect-stock: $DumpDir =="

$allOk = $true
Write-Output "`n-- Size verification vs stock /proc/mtd --"
foreach ($name in ($ExpectedLayout.Keys + $LogicalLayout.Keys)) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "  MISSING  $name"; $allOk = $false; continue }
    $size = (Get-Item -LiteralPath $p).Length
    $exp = if ($ExpectedLayout.Contains($name)) { $ExpectedLayout[$name] } else { $LogicalLayout[$name] }
    $ok = ($size -eq $exp)
    if (-not $ok) { $allOk = $false }
    Write-Output ("  {0}  {1,-26} size=0x{2:X8} expected=0x{3:X8}" -f ($(if ($ok) { "OK     " } else { "BADSIZE" })), $name, $size, $exp)
}

Write-Output "`n-- Format detection --"
foreach ($name in $ExpectedLayout.Keys) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $head = Read-Bytes $p 0 16
    $magic = ""
    if ($head.Length -ge 4) {
        if ($head[0] -eq 0x27 -and $head[1] -eq 0x05 -and $head[2] -eq 0x19 -and $head[3] -eq 0x56) { $magic = "uImage" }
        elseif ($head[0] -eq 0x55 -and $head[1] -eq 0x42 -and $head[2] -eq 0x49 -and $head[3] -eq 0x23) { $magic = "UBI (EC header)" }
        elseif ($head[0] -eq 0x68 -and $head[1] -eq 0x73 -and $head[2] -eq 0x71 -and $head[3] -eq 0x73) { $magic = "squashfs" }
        elseif ($head[0] -eq 0x31 -and $head[1] -eq 0x18 -and $head[2] -eq 0x10 -and $head[3] -eq 0x06) { $magic = "UBIFS node" }
        elseif ($head[0] -eq 0x1F -and $head[1] -eq 0x8B) { $magic = "gzip" }
    }
    if (-not $magic) { $magic = "unrecognized (" + (Get-Ascii $head[0..7]) + ")" }
    Write-Output ("  {0,-26} {1}" -f $name, $magic)
}

Write-Output "`n-- uImage headers --"
foreach ($name in @("mtd1-Bootloader.bin", "mtd8-kernel0.bin", "mtd9-kernel1.bin", "mtd13-obr.bin")) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $u = Read-UImage $p
    if ($null -eq $u) {
        Write-Output "  $name : not a uImage"
        continue
    }
    Write-Output ("  {0}: '{1}' {2} {3}/{4} {5} size={6} load={7} ep={8} built={9} hdrCRC={10}" -f `
            $name, $u.Name, $u.OS, $u.Arch, $u.Type, $u.Comp, $u.DataSize, $u.LoadAddr, $u.EntryAddr, $u.Timestamp, $(if ($u.HdrCrcOk) { "ok" } else { "BAD" }))
}

Write-Output "`n-- UBI structure (PEB EC scan, 128 KiB PEBs) --"
foreach ($name in @("mtd10-rootfs0.bin", "mtd11-rootfs1.bin", "mtd12-overlay.bin", "mtd13-obr.bin")) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $sz = (Get-Item -LiteralPath $p).Length
    $r = Test-Ubi $p $sz
    Write-Output ("  {0,-26} PEBs={1} with-EC={2} ({3})" -f $name, $r.Pebs, $r.EcOk, `
            $(if ($r.EcOk -eq $r.Pebs) { "fully UBI-formatted" } elseif ($r.EcOk -eq 0) { "no UBI" } else { "partial" }))
}
$mtd14 = Join-Path $DumpDir "mtd14-ubi_rootfs.bin"
if (Test-Path -LiteralPath $mtd14) {
    $b = Read-Bytes $mtd14 0 4
    $isUbifs = ($b[0] -eq 0x31 -and $b[1] -eq 0x18 -and $b[2] -eq 0x10 -and $b[3] -eq 0x06)
    $isSquash = ($b[0] -eq 0x68 -and $b[1] -eq 0x73 -and $b[2] -eq 0x71 -and $b[3] -eq 0x73)
    $kind = if ($isSquash) { "squashfs (raw squashfs stored inside the UBI volume - matches /dev/mtdblock14 squashfs mount)" } `
        elseif ($isUbifs) { "UBIFS" } else { "unrecognized" }
    Write-Output ("  mtd14-ubi_rootfs.bin       UBI volume content: {0}" -f $kind)
}

Write-Output "`n-- Factory (radio calibration) - redacted structural check --"
$fact = Join-Path $DumpDir "mtd4-Factory.bin"
if (Test-Path -LiteralPath $fact) {
    $id0 = Read-Bytes $fact 0 2
    $id1 = Read-Bytes $fact 0x8000 2
    $chip0 = "0x{0:X2}{1:X2}" -f $id0[1], $id0[0]
    $chip1 = "0x{0:X2}{1:X2}" -f $id1[1], $id1[0]
    $st = Get-FillStats $fact
    Write-Output ("  word@0x0000 = {0} ({1})" -f $chip0, $(if ($chip0 -eq "0x7603") { "MT7603 EEPROM signature" } else { "unexpected" }))
    Write-Output ("  word@0x8000 = {0} ({1})" -f $chip1, $(if ($chip1 -eq "0x7615") { "MT7615 EEPROM signature" } else { "unexpected" }))
    Write-Output ("  erased(0xFF) ratio = {0}; MAC/calibration contents: REDACTED (never read into output)" -f $st.ErasedRatio)
}

Write-Output "`n-- Sensitive data partitions - redacted classification --"
foreach ($name in @("mtd2-Config.bin", "mtd3-Bdata.bin", "mtd7-cfg_bak.bin")) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    Write-Output ("  {0,-26} {1}" -f $name, (Get-PrintableKvClass $p))
}

Write-Output "`n-- Crash partitions - fill check --"
foreach ($name in @("mtd5-crash.bin", "mtd6-crash_syslog.bin")) {
    $p = Join-Path $DumpDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $st = Get-FillStats $p
    Write-Output ("  {0,-26} erased(0xFF)={1} zero={2} -> {3}" -f $name, $st.ErasedRatio, $st.ZeroRatio, `
            $(if ($st.ErasedRatio -gt 0.99) { "empty (no crash data)" } else { "contains data" }))
}

Write-Output "`n-- Bootloader identity (keyword strings) --"
$bl = Join-Path $DumpDir "mtd1-Bootloader.bin"
if (Test-Path -LiteralPath $bl) { Find-BootloaderStrings $bl }

Write-Output "`n-- mtd0 self-consistency (partition slices vs standalone files) --"
$mtd0 = Join-Path $DumpDir "mtd0-ALL.bin"
if (Test-Path -LiteralPath $mtd0) {
    [long]$off = 0
    foreach ($name in $ExpectedLayout.Keys) {
        $p = Join-Path $DumpDir $name
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $len = [long]$ExpectedLayout[$name]
        $fileHash = Get-RangeSha256 $p 0 $len
        $sliceHash = Get-RangeSha256 $mtd0 $off $len
        $match = ($fileHash -eq $sliceHash)
        $writable = $WritablePartitions.Contains($name)
        if (-not $match -and -not $writable) { $allOk = $false }
        $verdict = if ($match) { "MATCH  " } elseif ($writable) { "CHANGED (writable runtime partition - expected to drift; dump README)" } else { "MISMATCH" }
        Write-Output ("  {0}  {1,-26} @mtd0+0x{2:X8} len=0x{3:X8}" -f $verdict, $name, $off, $len)
        $off += $len
    }
    Write-Output ("  covered: 0x{0:X8} of mtd0 size 0x{1:X8} (tail 0x{2:X} bytes outside any partition)" -f $off, (Get-Item -LiteralPath $mtd0).Length, ((Get-Item -LiteralPath $mtd0).Length - $off))
}

Write-Output ("`n== inspect-stock done: {0} ==" -f $(if ($allOk) { "ALL CHECKS PASSED" } else { "DISCREPANCIES FOUND (see above)" }))
