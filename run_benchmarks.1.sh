#!/bin/bash

# ===== CONFIG =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR/benchmarks"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RUN_DIR="$BASE_DIR/$TIMESTAMP"

NV_CMD="./nvbandwidth"
MEMTEST_CMD="./memtest_vulkan"
GLMARK_CMD="./glmark2"

COOLDOWN=15
ORIGINAL_DIR="$BASE_DIR/original"
# ===================

mkdir -p "$RUN_DIR"

echo "========================================="
echo "Starting benchmark run"
echo "Directory: $RUN_DIR"
echo "========================================="
echo

# Enable persistence mode (optional)
sudo nvidia-smi -pm 1 > /dev/null 2>&1

run_test () {
    NAME=$1
    CMD=$2
    LOGFILE="$RUN_DIR/$NAME.log"

    echo "-----------------------------------------"
    echo "Running $NAME"
    echo "-----------------------------------------"

    {
        echo "===== $NAME ====="
        echo "Timestamp: $(date)"
        echo
        echo "GPU status BEFORE:"
        nvidia-smi
        echo
        echo "----- Benchmark output -----"
    } > "$LOGFILE"

    $CMD >> "$LOGFILE" 2>&1

    {
        echo
        echo "GPU status AFTER:"
        nvidia-smi
    } >> "$LOGFILE"

    echo "Cooling down ${COOLDOWN}s..."
    sleep $COOLDOWN
}

# Run benchmarks sequentially
run_test "nvbandwidth" "$NV_CMD"
run_test "memtest_vulkan" "$MEMTEST_CMD"
run_test "glmark2" "$GLMARK_CMD"

# Update "latest" symlink
ln -sfn "$RUN_DIR" "$BASE_DIR/latest"

echo
echo "Benchmarks completed."
echo "Logs saved in: $RUN_DIR"

# ============== COMPARISON WITH ORIGINAL ==============
if [ -d "$ORIGINAL_DIR" ]; then
    echo
    echo "========================================="
    echo "Comparing with original benchmarks in $ORIGINAL_DIR"
    echo "========================================="

    # Detect colordiff
    if command -v colordiff >/dev/null 2>&1; then
        DIFF_CMD="colordiff -u"
    else
        DIFF_CMD="diff -u"
    fi

    for file in nvbandwidth.log memtest_vulkan.log glmark2.log
    do
        if [ -f "$ORIGINAL_DIR/$file" ]; then
            echo
            echo "########## Diff: $file ##########"
            $DIFF_CMD "$ORIGINAL_DIR/$file" "$RUN_DIR/$file" || true
        else
            echo "File not found in original: $file"
        fi
    done
else
    echo "Original benchmarks not found at $ORIGINAL_DIR. Skipping comparison."
fi

