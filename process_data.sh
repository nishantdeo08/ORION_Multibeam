#!/bin/bash
# Usage: ./process_data.sh <input_file> <lower_threshold> <upper_threshold> <col_index> <order_flag> [OPTIONS]
#
# Input:  global_pulscan_candidates.csv
# Output: global_pulscan_candidates_new.csv  (same directory as input)
#
# Expected columns (1-based, matches the actual CSV header exactly):
#   1: sigma   2: logp   3: r   4: z   5: power   6: numharm   7: frequency_hz   8: dm
#
# Filtering is always done on column 1 (sigma), PLUS column 7 (frequency_hz) -- see
# the new -f/-F flags below. Sorting column is whatever you pass via <col_index>.
#
# NEW optional flags (come AFTER the 5 required positional arguments):
#   -f MIN_FREQ_HZ   Minimum frequency cutoff in Hz. Candidates below this are
#                    removed. Default: 1 Hz (~1 second period).
#   -F MAX_FREQ_HZ   Maximum frequency cutoff in Hz. Candidates above this are
#                    removed. Default: 1000 Hz (~1 millisecond period).
#   Both flags are optional -- if you don't pass them, the defaults above apply
#   automatically. This means existing callers that only pass the original 5
#   positional arguments get the frequency cutoff for free, with no other change
#   needed on their end.

# BUGFIX: argument-count check now runs FIRST, before anything touches $1..$5.
# Previously COL_INDEX=$(( $4 + 1 )) ran before this check, so calling the script
# with too few args crashed on a bash arithmetic error instead of showing usage.
# Changed from "-ne 5" to "-lt 5" since optional trailing flags can add more args now.
if [ "$#" -lt 5 ]; then
    echo "Usage: $0 <file_name> <lower_th> <upper_th> <col_index> <order_flag (0:asc, 1:desc)> [-f MIN_FREQ_HZ] [-F MAX_FREQ_HZ]"
    echo "  col_index is a plain 1-based index into: sigma,logp,r,z,power,numharm,frequency_hz,dm"
    echo "  -f: minimum frequency cutoff in Hz (default: 1)"
    echo "  -F: maximum frequency cutoff in Hz (default: 1000)"
    exit 1
fi
INPUT_FILE=$1     # path to global_pulscan_candidates.csv
LOWER_TH=$2       # lower sigma threshold
UPPER_TH=$3       # upper sigma threshold (may be empty -> "no upper bound")
COL_INDEX=$4      # BUGFIX: used as-is now, plain 1-based index -- no more "+1" conversion,
                  # since the old +1 assumed a 0-based input that doesn't match how your
                  # orchestrator (or you) actually specify columns.
ORDER_FLAG=$5     # 0 = ascending, 1 = descending
shift 5           # NEW: consume the 5 required positional args, leaving only the optional
                  # -f/-F flags (if any) in "$@" for getopts to process below.

# NEW: frequency cutoff defaults -- applied even if -f/-F are never passed.
MIN_FREQ_HZ=1        # 1 Hz ~ 1 second period; anything below this is removed
MAX_FREQ_HZ=1000     # 1000 Hz ~ 1 millisecond period; anything above this is removed

while getopts "f:F:h" opt; do
    case "$opt" in
        f) MIN_FREQ_HZ="$OPTARG" ;;
        F) MAX_FREQ_HZ="$OPTARG" ;;
        h)
            echo "Usage: $0 <file_name> <lower_th> <upper_th> <col_index> <order_flag> [-f MIN_FREQ_HZ] [-F MAX_FREQ_HZ]"
            exit 1
            ;;
        *)
            echo "ERROR: unrecognized option. Use -f MIN_FREQ_HZ and/or -F MAX_FREQ_HZ."
            exit 1
            ;;
    esac
done

# BUGFIX: sanity-check col_index against the known 8-column layout, so a typo
# (e.g. -c 9) fails clearly here instead of producing a silently empty sort key.
if ! [[ "$COL_INDEX" =~ ^[0-9]+$ ]] || [ "$COL_INDEX" -lt 1 ] || [ "$COL_INDEX" -gt 8 ]; then
    echo "ERROR: col_index must be a plain 1-based number from 1 to 8 (sigma=1 ... dm=8). Got: $COL_INDEX"
    exit 1
fi

# NEW: sanity-check the frequency cutoffs are actually numeric and in the right order,
# so a typo here fails clearly instead of silently filtering everything out.
if ! [[ "$MIN_FREQ_HZ" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: -f MIN_FREQ_HZ must be a non-negative number. Got: $MIN_FREQ_HZ"
    exit 1
fi
if ! [[ "$MAX_FREQ_HZ" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: -F MAX_FREQ_HZ must be a non-negative number. Got: $MAX_FREQ_HZ"
    exit 1
fi
if awk -v lo="$MIN_FREQ_HZ" -v hi="$MAX_FREQ_HZ" 'BEGIN{exit !(lo > hi)}'; then
    echo "ERROR: -f MIN_FREQ_HZ ($MIN_FREQ_HZ) cannot be greater than -F MAX_FREQ_HZ ($MAX_FREQ_HZ)."
    exit 1
fi

# 1. Detect delimiter
# BUGFIX: previous version used `[[ ... ]] || grep ... && DELIM=...` which, due to
# bash's left-to-right && / || precedence, ALWAYS set DELIM to tab for any file
# ending in .csv -- regardless of its real content. Rewritten as an explicit if/else:
# assume comma for .csv files (matches your actual header), only sniff for a real
# tab when the extension doesn't already tell us.
DELIM=","
if [[ "$INPUT_FILE" != *.csv ]] && grep -q $'\t' "$INPUT_FILE"; then
    DELIM=$'\t'
fi

# 2. Derive output filename
#    Strip the extension, append _new, put the extension back.
#    global_pulscan_candidates.csv -> global_pulscan_candidates_new.csv
BASE="${INPUT_FILE%.*}"
EXT="${INPUT_FILE##*.}"
OUTPUT_FILE="${BASE}_new.${EXT}"

# 3. Filter by sigma range + frequency range, and sort
HEADER=$(head -n 1 "$INPUT_FILE")

# BUGFIX: an empty UPPER_TH used to silently coerce to 0 inside awk, dropping every
# real candidate (sigma > 0 always fails "<= 0"). Build the awk filter condition
# dynamically instead: only include the upper-bound check when UPPER_TH is actually set.
# NEW: frequency cutoff ($7 = frequency_hz) is ALWAYS applied, using MIN_FREQ_HZ/MAX_FREQ_HZ
# (which always have a value -- either the defaults above, or whatever -f/-F overrode them to).
if [ -z "$UPPER_TH" ]; then
    AWK_FILTER='$1 >= low && $7 >= minf && $7 <= maxf {print $0}'
else
    AWK_FILTER='$1 >= low && $1 <= high && $7 >= minf && $7 <= maxf {print $0}'
fi

(
  echo "$HEADER"
  tail -n +2 "$INPUT_FILE" | \
  awk -F"$DELIM" -v low="$LOWER_TH" -v high="$UPPER_TH" -v minf="$MIN_FREQ_HZ" -v maxf="$MAX_FREQ_HZ" "$AWK_FILTER" | \
  sort -t"$DELIM" -k"${COL_INDEX},${COL_INDEX}" -n \
      $( [[ "$ORDER_FLAG" == "1" ]] && echo "-r" )
) > "$OUTPUT_FILE"

if [ -z "$UPPER_TH" ]; then
    echo "Filtered (sigma >= $LOWER_TH, no upper bound; freq ${MIN_FREQ_HZ}-${MAX_FREQ_HZ}Hz) -> $(basename "$OUTPUT_FILE")"
else
    echo "Filtered (sigma $LOWER_TH-$UPPER_TH; freq ${MIN_FREQ_HZ}-${MAX_FREQ_HZ}Hz) -> $(basename "$OUTPUT_FILE")"
fi
