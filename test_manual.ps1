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

$TESTDIR  = Join-Path $env:TEMP "nightwatch_manual_$PID"
$TESTDIR2 = Join-Path $env:TEMP "nightwatch_manual2_$PID"
New-Item -ItemType Directory -Path $TESTDIR  | Out-Null
New-Item -ItemType Directory -Path $TESTDIR2 | Out-Null

Write-Host "--- watching $TESTDIR and $TESTDIR2 ---"
Write-Host "--- starting nightwatch (Ctrl-C to stop early) ---"
Write-Host ""

# Start nightwatch in background watching both dirs, events go to stdout
$proc = Start-Process -FilePath $NW -ArgumentList $TESTDIR, $TESTDIR2 -NoNewWindow -PassThru
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
Start-Sleep -Milliseconds 400

Write-Host "[op] mkdir dirA"
New-Item -ItemType Directory -Path "$TESTDIR\dirA" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] touch dirA\file3.txt"
New-Item -ItemType File -Path "$TESTDIR\dirA\file3.txt" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] rename dirA -> dirB"
Rename-Item -Path "$TESTDIR\dirA" -NewName "dirB"
Start-Sleep -Milliseconds 400

Write-Host "[op] rmdir dirB (and contents)"
Remove-Item -Recurse -Force -Path "$TESTDIR\dirB"
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host "# cross-root renames (both dirs watched)"
Write-Host ""

Write-Host "[op] mkdir subA in both roots"
New-Item -ItemType Directory -Path "$TESTDIR\subA"  | Out-Null
New-Item -ItemType Directory -Path "$TESTDIR2\subA" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] touch crossfile.txt in dir1"
New-Item -ItemType File -Path "$TESTDIR\crossfile.txt" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] rename crossfile.txt: dir1 -> dir2 (root to root)"
Move-Item -Path "$TESTDIR\crossfile.txt" -Destination "$TESTDIR2\crossfile.txt"
Start-Sleep -Milliseconds 400

Write-Host "[op] touch subA\crosssub.txt in dir1"
New-Item -ItemType File -Path "$TESTDIR\subA\crosssub.txt" | Out-Null
Start-Sleep -Milliseconds 400

Write-Host "[op] rename subA\crosssub.txt: dir1\subA -> dir2\subA (subdir to subdir)"
Move-Item -Path "$TESTDIR\subA\crosssub.txt" -Destination "$TESTDIR2\subA\crosssub.txt"
Start-Sleep -Milliseconds 400

Write-Host "[op] rename subA: dir1 -> dir2 (subdir across roots)"
Move-Item -Path "$TESTDIR\subA" -Destination "$TESTDIR2\subA2"
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host "--- done, stopping nightwatch ---"
Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
$proc.WaitForExit()
Remove-Item -Recurse -Force -Path $TESTDIR
Remove-Item -Recurse -Force -Path $TESTDIR2
