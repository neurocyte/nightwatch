# Manual test for nightwatch CLI.
# Usage: .\test_manual.ps1 [path-to-nightwatch-binary]
#
# Run this in one terminal. It starts nightwatch watching a temp dir,
# performs a sequence of filesystem operations, then exits.
# You should see one event per line on stdout as they happen.

param(
    [string]$NW = ".\zig-out\bin\nightwatch.exe"
)

if (-not (Test-Path $NW)) {
    Write-Error "error: binary not found: $NW"
    exit 1
}

$TESTDIR = Join-Path $env:TEMP "nightwatch_manual_$PID"
New-Item -ItemType Directory -Path $TESTDIR | Out-Null

Write-Host "--- watching $TESTDIR ---"
Write-Host "--- starting nightwatch (Ctrl-C to stop early) ---"
Write-Host ""

# Start nightwatch in background, events go to stdout
$proc = Start-Process -FilePath $NW -ArgumentList $TESTDIR -NoNewWindow -PassThru
Start-Sleep -Milliseconds 500

Write-Host "[op] touch file1.txt"
New-Item -ItemType File -Path "$TESTDIR\file1.txt" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] write to file1.txt"
Set-Content -Path "$TESTDIR\file1.txt" -Value "hello nightwatch"
Start-Sleep -Milliseconds 400

Write-Host "[op] mkdir subdir"
New-Item -ItemType Directory -Path "$TESTDIR\subdir" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] touch subdir\file2.txt"
New-Item -ItemType File -Path "$TESTDIR\subdir\file2.txt" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] rename file1.txt -> renamed.txt"
Rename-Item -Path "$TESTDIR\file1.txt" -NewName "renamed.txt"
Start-Sleep -Milliseconds 400

Write-Host "[op] delete renamed.txt"
Remove-Item -Path "$TESTDIR\renamed.txt"
Start-Sleep -Milliseconds 400

Write-Host "[op] delete subdir\file2.txt"
Remove-Item -Path "$TESTDIR\subdir\file2.txt"
Start-Sleep -Milliseconds 400

Write-Host "[op] rmdir subdir"
Remove-Item -Path "$TESTDIR\subdir"
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host "--- done, stopping nightwatch ---"
Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
$proc.WaitForExit()
Remove-Item -Recurse -Force -Path $TESTDIR
