#!/bin/sh
# This file was generated with the help of Claude Code.
#
# Summarizes the nextpnr-ecp5 logs for `make timing`: for the whole design,
# the maximum clock frequency, the minimum clock period, where the critical
# path starts and ends, and how much of the chip it uses; then the maximum
# clock frequency of each module on its own.
#
#   timing/report.sh build/timing <module>...
#
# Reads <dir>/market_maker/pnr.log and <dir>/<module>/pnr.log.
set -eu

dir=$1
shift

# nextpnr names each cell after its net, plus suffixes for the primitive it
# became; keep just the design's name for it (e.g. "pricing.in_item").
cell_name() {
    sed -E 's/\.[A-Z0-9]+$//; s/\$[0-9]+\.//g; s/(_TRELLIS|_MULT18|_LUT4|_CCU2C|_DP16KD|_PFUMX|_L6MUX|\$).*//; s/^dut\.//'
}

fmax() {
    grep "Max frequency for clock 'clk'" "$1" | tail -1 | sed -E 's/.*: ([0-9.]+) MHz.*/\1/'
}

period() {
    awk -v f="$1" 'BEGIN { printf "%.2f", 1000 / f }'
}

utilization() {
    grep -E "^Info:[[:space:]]+$2:" "$1" | tail -1 | sed -E 's/.*: *([0-9]+)\/ *([0-9]+) +([0-9]+%).*/\1 of \2 (\3)/'
}

# ---- The whole design ----

log=$dir/market_maker/pnr.log
design_fmax=$(fmax "$log")
split=$(grep -E "ns logic, [0-9.]+ ns routing" "$log" | tail -1 | sed -E 's/^Info: //')

# The critical path report: the first Source and the last Sink.
path=$(sed -n "/Critical path report for clock 'clk'/,/ns logic,/p" "$log")
from=$(printf '%s\n' "$path" | grep -m1 " Source " | sed -E 's/.* Source //' | cell_name)
to=$(printf '%s\n' "$path" | grep " Sink " | tail -1 | sed -E 's/.* Sink //' | cell_name)

echo "Timing: ECP5 LFE5U-85F, speed grade 6"
echo
echo "The whole design:"
printf '  max clock frequency  %s MHz\n' "$design_fmax"
printf '  min clock period     %s ns  (%s)\n' "$(period "$design_fmax")" "$split"
printf '  critical path        from %s\n' "$from"
printf '                       to   %s\n' "$to"
printf '  logic cells (LUTs)   %s\n' "$(utilization "$log" TRELLIS_COMB)"
printf '  flip-flops           %s\n' "$(utilization "$log" TRELLIS_FF)"
printf '  block RAMs           %s\n' "$(utilization "$log" DP16KD)"
printf '  multipliers          %s\n' "$(utilization "$log" MULT18X18D)"

# ---- Each module on its own ----

slowest=
slowest_fmax=
for module in "$@"; do
    f=$(fmax "$dir/$module/pnr.log")
    if [ -z "$slowest" ] || awk -v a="$f" -v b="$slowest_fmax" 'BEGIN { exit !(a < b) }'; then
        slowest=$module
        slowest_fmax=$f
    fi
done

echo
echo "Each module on its own (the design can run no faster than its slowest):"
printf '  %-20s %10s %12s %8s\n' "module" "max MHz" "min period" "LUTs"
for module in "$@"; do
    log=$dir/$module/pnr.log
    f=$(fmax "$log")
    luts=$(utilization "$log" TRELLIS_COMB | cut -d' ' -f1)
    marker=
    [ "$module" = "$slowest" ] && marker="  <- slowest"
    printf '  %-20s %10s %9s ns %8s%s\n' "$module" "$f" "$(period "$f")" "$luts" "$marker"
done
