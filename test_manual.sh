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
TESTDIR2=$(mktemp -d)
UNWATCHED=$(mktemp -d)
echo "--- watching $TESTDIR and $TESTDIR2 (unwatched: $UNWATCHED) ---"
echo "--- starting nightwatch (Ctrl-C to stop early) ---"
echo ""

# Start nightwatch in background watching both dirs, events go to stdout
"$NW" "$TESTDIR" "$TESTDIR2" &
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
echo "# cross-root renames (both dirs watched)"
echo ""

echo "[op] mkdir subA in both roots"
mkdir "$TESTDIR/subA"
mkdir "$TESTDIR2/subA"
sleep 0.4

echo "[op] touch crossfile.txt in dir1"
touch "$TESTDIR/crossfile.txt"
sleep 0.4

echo "[op] rename crossfile.txt: dir1 -> dir2 (root to root)"
mv "$TESTDIR/crossfile.txt" "$TESTDIR2/crossfile.txt"
sleep 0.4

echo "[op] touch subA/crosssub.txt in dir1"
touch "$TESTDIR/subA/crosssub.txt"
sleep 0.4

echo "[op] rename subA/crosssub.txt: dir1/subA -> dir2/subA (subdir to subdir)"
mv "$TESTDIR/subA/crosssub.txt" "$TESTDIR2/subA/crosssub.txt"
sleep 0.4

echo "[op] rename subA: dir1 -> dir2 (subdir across roots)"
mv "$TESTDIR/subA" "$TESTDIR2/subA2"
sleep 0.5

echo ""
echo "# move in/out (one side unwatched)"
echo ""

echo "[op] touch outfile.txt in dir1"
touch "$TESTDIR/outfile.txt"
sleep 0.4

echo "[op] move outfile.txt: dir1 -> unwatched (move out)"
mv "$TESTDIR/outfile.txt" "$UNWATCHED/outfile.txt"
sleep 0.4

echo "[op] move outfile.txt: unwatched -> dir1 (move in)"
mv "$UNWATCHED/outfile.txt" "$TESTDIR/outfile.txt"
sleep 0.4

echo "[op] delete outfile.txt"
rm "$TESTDIR/outfile.txt"
sleep 0.4

echo "[op] mkdir unwatched/subdir with a file"
mkdir "$UNWATCHED/subdir"
touch "$UNWATCHED/subdir/inside.txt"
sleep 0.4

echo "[op] move unwatched/subdir -> dir1/subdir (move subdir in)"
mv "$UNWATCHED/subdir" "$TESTDIR/subdir"
sleep 0.4

echo "[op] delete dir1/subdir/inside.txt"
rm "$TESTDIR/subdir/inside.txt"
sleep 0.4

echo "[op] rmdir dir1/subdir"
rmdir "$TESTDIR/subdir"
sleep 0.5

echo ""
echo "--- done, stopping nightwatch ---"
kill $NW_PID 2>/dev/null
wait $NW_PID 2>/dev/null
rm -rf "$TESTDIR" "$TESTDIR2" "$UNWATCHED"
