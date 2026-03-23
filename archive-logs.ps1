# Archive-Logs.ps1
# Script for archiving rotated logs by date based on timestamp field in JSON.

<#
.SYNOPSIS
    Archives rotated logs by date.

.DESCRIPTION
    Processes all files matching *.log.* (with a digit at the end), extracts the date
    from the timestamp field of each JSON line, and distributes lines into archive files
    inside subfolders: logs_archive/{type}/{date}.log.
    After successful processing, source files are deleted.
    On parsing or write errors, files are moved to logs_archive/_corrupted with a timestamp suffix.

    Environment variables (read from .env file in project root):
    - LOG_PATH                 – directory for log files (default: 'logs')
    - LOG_SIZE                 – max size of archive_script.log in bytes (default: 5 * 1024 * 1024)
                                 Supports expressions with '*', e.g. '10 * 1024 * 1024' is 10 MB
    - LOG_FILES                – max number of rotated archive_script.log files to keep (default: 5)
    - LOG_ARCHIVE_VERBOSE      – enable verbose logging if 'true' or '1' (default: false)
    - LOG_ARCHIVE_LOCK_TIMEOUT – lock file timeout in minutes (default: 30)
                                 Supports expressions with '*', e.g. '60 * 24' is 24 hours

.EXAMPLE
    .\archive-logs.ps1          # Manual run from project root

.NOTES
    For automation, create a scheduled task in Windows Task Scheduler:
    1. Open Task Scheduler (taskschd.msc)
    2. Create task → Trigger (e.g., daily at 3:00)
    3. Action: Start program → powershell.exe
    4. Arguments: -ExecutionPolicy Bypass -File "C:\full\path\to\archive-logs.ps1"
    5. Working folder: C:\full\path\to\project
    6. Ensure the account has read/write permissions to log and archive folders.

    Manual run:
        Open PowerShell in project root and run:
        .\archive-logs.ps1
        (if necessary, allow script execution: Set-ExecutionPolicy RemoteSigned)
#>

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# 1. Determine project root and read .env
# ------------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    Write-Error "Cannot determine script directory. Run as .\archive-logs.ps1"
    exit 1
}

$envFile = Join-Path $scriptRoot ".env"
$logsPath = "logs"
$logSize = 5 * 1024 * 1024  # 5 MB default
$logFiles = 5                # number of backup files for archive_script.log
$verboseLogging = $false     # default
$lockTimeoutMinutes = 30     # default

# Function to parse expressions with '*' (removes whitespace)
function ParseSize($str) {
    $str = $str.Trim()
    if ($str -match '\*') {
        $parts = $str -split '\*' | ForEach-Object {
            $num = $_ -replace '\s+', ''
            if ($num -match '^\d+$') {
                [int]$num
            } else {
                Write-Warning "Non-numeric fragment '$num' in expression '$str'. Using 0."
                0
            }
        }
        $result = 1
        foreach ($part in $parts) { $result *= $part }
        return $result
    } else {
        $num = $str -replace '\s+', ''
        if ($num -match '^\d+$') {
            return [int]$num
        } else {
            Write-Warning "Non-numeric value '$str'. Using 0."
            return 0
        }
    }
}

# Read .env if present
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile -Raw
    # LOG_PATH
    if ($envContent -match '(?m)^LOG_PATH\s*=\s*(.+)$') {
        $value = $matches[1].Trim()
        if ($value -match '^["''](.*)["'']$') { $value = $matches[1] }
        if ($value -match '^(.*?)\s*#') { $value = $matches[1].TrimEnd() }
        if ($value) { $logsPath = $value }
    }
    # LOG_SIZE
    if ($envContent -match '(?m)^LOG_SIZE\s*=\s*(.+)$') {
        $sizeVal = $matches[1].Trim()
        if ($sizeVal -match '^["''](.*)["'']$') { $sizeVal = $matches[1] }
        if ($sizeVal -match '^(.*?)\s*#') { $sizeVal = $matches[1].TrimEnd() }
        if ($sizeVal) {
            $parsed = ParseSize $sizeVal
            if ($parsed -gt 0) { $logSize = $parsed }
        }
    }
    # LOG_FILES
    if ($envContent -match '(?m)^LOG_FILES\s*=\s*(.+)$') {
        $filesVal = $matches[1].Trim()
        if ($filesVal -match '^["''](.*)["'']$') { $filesVal = $matches[1] }
        if ($filesVal -match '^(.*?)\s*#') { $filesVal = $matches[1].TrimEnd() }
        if ($filesVal -match '^\d+$') { $logFiles = [int]$filesVal }
    }
    # LOG_ARCHIVE_VERBOSE
    if ($envContent -match '(?m)^LOG_ARCHIVE_VERBOSE\s*=\s*(.+)$') {
        $verboseVal = $matches[1].Trim()
        if ($verboseVal -match '^["''](.*)["'']$') { $verboseVal = $matches[1] }
        if ($verboseVal -match '^(.*?)\s*#') { $verboseVal = $matches[1].TrimEnd() }
        if ($verboseVal -eq 'true' -or $verboseVal -eq '1') {
            $verboseLogging = $true
        }
    }
    # LOG_ARCHIVE_LOCK_TIMEOUT
    if ($envContent -match '(?m)^LOG_ARCHIVE_LOCK_TIMEOUT\s*=\s*(.+)$') {
        $timeoutVal = $matches[1].Trim()
        if ($timeoutVal -match '^["''](.*)["'']$') { $timeoutVal = $matches[1] }
        if ($timeoutVal -match '^(.*?)\s*#') { $timeoutVal = $matches[1].TrimEnd() }
        if ($timeoutVal) {
            $parsed = ParseSize $timeoutVal
            if ($parsed -gt 0) { $lockTimeoutMinutes = $parsed }
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Check log path (security)
# ------------------------------------------------------------------------------
$projectRoot = $scriptRoot
$resolvedLogsDir = Join-Path $projectRoot $logsPath
$resolvedLogsDir = [System.IO.Path]::GetFullPath($resolvedLogsDir)
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($projectRoot)

if (-not $resolvedProjectRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $resolvedProjectRoot += [System.IO.Path]::DirectorySeparatorChar
}
$isSubDirectory = $resolvedLogsDir.StartsWith($resolvedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)
if (-not $isSubDirectory) {
    Write-Error "Path traversal: $logsPath attempts to escape project root"
    exit 1
}

$sourceDir = $resolvedLogsDir
if (-not (Test-Path $sourceDir)) {
    Write-Host "Log directory not found: $sourceDir"
    exit 0
}

$parentDir = Split-Path $sourceDir -Parent
$archiveDir = Join-Path $parentDir ($(Split-Path $sourceDir -Leaf) + "_archive")
if (-not (Test-Path $archiveDir)) {
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
}

# ------------------------------------------------------------------------------
# 3. Script logging (with rotation)
# ------------------------------------------------------------------------------
$scriptLogFile = Join-Path $archiveDir "archive_script.log"

function Rotate-LogFile {
    param([string]$FilePath, [int]$MaxFiles)
    if (-not (Test-Path $FilePath)) { return }
    if ($MaxFiles -le 0) { return }
    # Remove max index file if exists
    $maxIndexFile = "${FilePath}.$MaxFiles"
    if (Test-Path $maxIndexFile) {
        Remove-Item $maxIndexFile -Force
    }
    # Shift from MaxFiles-1 down to 1
    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
        $old = "${FilePath}.$i"
        $new = "${FilePath}.$($i+1)"
        if (Test-Path $old) {
            Move-Item $old $new -Force
        }
    }
    # Rename current file to .1
    Move-Item $FilePath "${FilePath}.1" -Force
}

function Write-Log {
    param([string]$Message, [switch]$VerboseOnly)
    if ($VerboseOnly -and -not $verboseLogging) { return }

    # Rotate script log if size exceeds limit
    if (Test-Path $scriptLogFile) {
        $file = Get-Item $scriptLogFile
        if ($file.Length -gt $logSize) {
            Rotate-LogFile -FilePath $scriptLogFile -MaxFiles $logFiles
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Out-File -FilePath $scriptLogFile -Append
}

# ------------------------------------------------------------------------------
# 4. Lock file with timeout (LOG_ARCHIVE_LOCK_TIMEOUT)
# ------------------------------------------------------------------------------
$lockFile = Join-Path $archiveDir "archive.lock"

if (Test-Path $lockFile) {
    $lockInfo = Get-Item $lockFile
    $lockAge = (Get-Date) - $lockInfo.LastWriteTime
    if ($lockAge.TotalMinutes -gt $lockTimeoutMinutes) {
        Write-Log "Found stale lock file (age $([math]::Round($lockAge.TotalMinutes,1)) min). Deleting."
        Remove-Item $lockFile -Force
    } else {
        Write-Log "Script already running (lock file exists). Exiting."
        Write-Host "Script already running, exiting."
        exit 0
    }
}
try {
    New-Item -Path $lockFile -ItemType File -Force | Out-Null
} catch {
    Write-Log "Failed to create lock file: $_"
    Write-Host "Failed to create lock file. Exiting."
    exit 1
}

# ------------------------------------------------------------------------------
# 5. Helper function to get relative path (compatible with PowerShell 5.1)
# ------------------------------------------------------------------------------
function Get-RelativePath {
    param([string]$BasePath, [string]$FullPath)
    $base = [System.IO.Path]::GetFullPath($BasePath)
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }
    $rel = $full.Substring($base.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
    if ($rel -eq '') { return '.' }
    return $rel
}

# ------------------------------------------------------------------------------
# 6. Main processing
# ------------------------------------------------------------------------------
$writers = @{}
$files = $null

try {
    # Prepare log messages (relative paths)
    $rootForLog = $resolvedProjectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $sourceRelative = Get-RelativePath -BasePath $rootForLog -FullPath $sourceDir
    $archiveRelative = Get-RelativePath -BasePath $rootForLog -FullPath $archiveDir

    Write-Log "=== Archive started ==="
    Write-Log "Project root: $rootForLog"
    Write-Log "Source: $sourceRelative"
    Write-Log "Archive: $archiveRelative"

    $files = Get-ChildItem -Path $sourceDir | Where-Object { $_.Name -match '\.log\.\d+$' }
    if ($files.Count -eq 0) {
        Write-Log "No files to process in $sourceRelative"
        return
    }

    Write-Log "Found files: $($files.Count)"

    $filesWithErrors = @{}  # files that should be moved to corrupted

    foreach ($file in $files) {
        $logType = $file.Name -replace '\.log\.\d+$', ''
        Write-Log "Processing $($file.FullName) (type: $logType)" -VerboseOnly

        # Read all lines of the file into an array
        $allLines = @()
        try {
            $allLines = Get-Content -Path $file.FullName -Encoding UTF8
        } catch {
            Write-Log "ERROR: Could not read file $($file.FullName): $_"
            $filesWithErrors[$file.FullName] = $true
            continue
        }

        # Temporary buffer for valid lines grouped by key
        $validLines = @{}
        $hasParseError = $false

        foreach ($line in $allLines) {
            $line = $line.Trim()
            if (-not $line) { continue }

            try {
                $obj = $line | ConvertFrom-Json
                $timestamp = $obj.timestamp
                if (-not $timestamp) {
                    Write-Log "WARNING: No timestamp in line: $line"
                    $hasParseError = $true
                    continue
                }
                if ($timestamp -match '^(\d{4}-\d{2}-\d{2})') {
                    $date = $matches[1]
                } else {
                    Write-Log "WARNING: Cannot parse date from timestamp: $timestamp"
                    $hasParseError = $true
                    continue
                }

                $key = "${logType}_${date}"
                if (-not $validLines.ContainsKey($key)) {
                    $validLines[$key] = @()
                }
                $validLines[$key] += $line
            }
            catch {
                Write-Log "ERROR: Failed to parse line: $line. $_"
                $hasParseError = $true
            }
        }

        # If any parsing error, mark file as erroneous and skip writing
        if ($hasParseError) {
            Write-Log "File $($file.FullName) contains invalid lines. Will be moved to corrupted."
            $filesWithErrors[$file.FullName] = $true
            continue
        }

        # No errors, write collected lines to archive files
        $writeError = $false
        foreach ($key in $validLines.Keys) {
            if (-not $writers.ContainsKey($key)) {
                $parts = $key -split '_'
                $type = $parts[0]
                $date = $parts[1]
                $typeDir = Join-Path $archiveDir $type
                if (-not (Test-Path $typeDir)) {
                    New-Item -ItemType Directory -Path $typeDir -Force | Out-Null
                }
                $archiveFilePath = Join-Path $typeDir "${date}.log"
                $writers[$key] = [System.IO.StreamWriter]::new($archiveFilePath, $true, [System.Text.Encoding]::UTF8)
            }
            $writer = $writers[$key]
            foreach ($line in $validLines[$key]) {
                try {
                    $writer.WriteLine($line)
                } catch {
                    Write-Log "ERROR: Failed to write line to $($writer.BaseStream.Name): $_"
                    $writeError = $true
                    $writer.Close()
                    $writers.Remove($key)
                    break
                }
            }
            if ($writeError) { break }
        }

        if ($writeError) {
            Write-Log "File $($file.FullName) will not be deleted due to write error. Moving to corrupted."
            $filesWithErrors[$file.FullName] = $true
        } else {
            Write-Log "File $($file.FullName) processed successfully, will be deleted." -VerboseOnly
        }
    }

    # Delete or move source files
    foreach ($file in $files) {
        if ($filesWithErrors.ContainsKey($file.FullName)) {
            $corruptedDir = Join-Path $archiveDir "_corrupted"
            if (-not (Test-Path $corruptedDir)) {
                New-Item -ItemType Directory -Path $corruptedDir -Force | Out-Null
            }
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $newName = $file.BaseName + "_$timestamp" + $file.Extension
            $destFile = Join-Path $corruptedDir $newName
            try {
                Move-Item -Path $file.FullName -Destination $destFile -Force
                Write-Log "Moved (error) $($file.FullName) to $destFile" -VerboseOnly
            } catch {
                Write-Log "FAILED to move $($file.FullName): $_"
            }
        } else {
            try {
                Remove-Item -Path $file.FullName -Force
                Write-Log "Deleted $($file.FullName)" -VerboseOnly
            } catch {
                Write-Log "FAILED to delete $($file.FullName): $_"
            }
        }
    }

    Write-Log "Archiving completed successfully."
}
finally {
    # Close all writers
    if ($writers) {
        foreach ($writer in $writers.Values) {
            try { $writer.Close() } catch { Write-Log "Error closing writer: $_" }
        }
        $writers.Clear()
    }

    # Remove lock file
    try {
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Failed to remove lock file: $_"
    }
}