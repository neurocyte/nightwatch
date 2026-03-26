#!/bin/sh
# Manual test for nightwatch CLI.
# Usage: ./test_manual.sh [path-to-nightwatch-binary]
#
# Run this in one terminal. It starts nightwatch watching a temp dir,
# performs a sequence of filesystem operations, then exits.
# You should see one event per line on stdout as they happen.

NW="${1:-./zig-out/bin/nightwatch}"

if [ ! -x "$NW" ]; then
    echo "error: binary not found: $NW"
    exit 1
fi

TESTDIR=$(mktemp -d)
echo "--- watching $TESTDIR ---"
echo "--- starting nightwatch (Ctrl-C to stop early) ---"
echo ""

# Start nightwatch in background, events go to stdout
"$NW" "$TESTDIR" &
NW_PID=$!
sleep 0.5

echo "[op] touch file1.txt"
touch "$TESTDIR/file1.txt"
sleep 0.4

echo "[op] write to file1.txt"
echo "hello nightwatch" > "$TESTDIR/file1.txt"
sleep 0.4

echo "[op] mkdir subdir"
mkdir "$TESTDIR/subdir"
sleep 0.4

echo "[op] touch subdir/file2.txt"
touch "$TESTDIR/subdir/file2.txt"
sleep 0.4

echo "[op] rename file1.txt -> renamed.txt"
mv "$TESTDIR/file1.txt" "$TESTDIR/renamed.txt"
sleep 0.4

echo "[op] delete renamed.txt"
rm "$TESTDIR/renamed.txt"
sleep 0.4

echo "[op] delete subdir/file2.txt"
rm "$TESTDIR/subdir/file2.txt"
sleep 0.4

echo "[op] rmdir subdir"
rmdir "$TESTDIR/subdir"
sleep 0.4

echo "[op] mkdir dirA"
mkdir "$TESTDIR/dirA"
sleep 0.4

echo "[op] touch dirA/file3.txt"
touch "$TESTDIR/dirA/file3.txt"
sleep 0.4

echo "[op] rename dirA -> dirB"
mv "$TESTDIR/dirA" "$TESTDIR/dirB"
sleep 0.4

echo "[op] rmdir dirB (and contents)"
rm -rf "$TESTDIR/dirB"
sleep 0.5

echo ""
echo "--- done, stopping nightwatch ---"
kill $NW_PID 2>/dev/null
wait $NW_PID 2>/dev/null
rm -rf "$TESTDIR"
