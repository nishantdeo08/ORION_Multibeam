#!/bin/bash
# Multibeam AA+PULSCAN orchestrator: distributes N .fil files across M GPU nodes,
# using G GPUs per node (each node's GPUs run one file each, concurrently),
# instead of one file at a time or one file per node.

# --- COLOR DEFINITIONS FOR PROFESSIONAL LOGGING ---
RED='\033[0;31m'      # ANSI red, used for errors
GREEN='\033[0;32m'    # ANSI green, used for success messages
YELLOW='\033[0;33m'   # ANSI yellow, used for warnings
BLUE='\033[0;34m'      # ANSI blue, used for info messages
NC='\033[0m'          # ANSI reset code ("No Color")

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }                # prints an info line
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }            # prints a success line
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }              # prints a warning line, does NOT exit
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }        # prints an error and kills the WHOLE script
                                                                   # (only safe to call from the main/foreground shell,
                                                                   #  never from inside a backgrounded job)

# --- DEFAULT CONFIGURATIONS ---
LOW_TH=5                 # default lower SNR threshold
HIGH_TH=""                # empty means "no upper bound"; kept as string, passed through as-is
SORT_COL=7                # default sort column (2 = Period)
ORDER_FLAG=1               # default order (1 = Descending)
DATA_PATH=""               # must be supplied via -d
COMPUTE_NODES_INPUT=""     # must be supplied via -n
GPUS_PER_NODE=2             # NEW: how many GPU cards per node to use concurrently (default 2, matches your hardware)
BEAM_POSITIONS=""           # NEW: path to the RA/DEC/BM-Idx beam layout file, manual override for -p (optional)
AUTO_BEAM_POSITIONS=""      # NEW: path to the file Step 6 auto-extracts from .ahdr headers, used if -p is not given
RESUME=1                    # NEW: 1 = skip steps whose output already exists (default ON), 0 = always re-run everything

# NEW: Step 8 (PRESTO) controls -- mirror presto_candidate_pipeline_fast.sh's own
# flag letters/defaults wherever they don't collide with flags already used above
# (only -c is taken, so PRESTO's CPU count uses -C instead).
PRESTO_NCPUS=8                  # -C : CPUs per PRESTO process (prepsubband/accelsearch/prepfold)
PRESTO_JOBS_PER_NODE=1          # -j : concurrent beam pipelines per compute node
PRESTO_SIGMA_THRESH=5.0         # -m : minimum accelsearch candidate sigma required to trigger prepfold
PRESTO_DM_STEP=0.10             # -s : prepsubband DM grid step for Step 8's own DM grid
PRESTO_LOW_DM=""                # -L : low DM for Step 8's prepsubband grid (requires -H)
PRESTO_HIGH_DM=""               # -H : high DM for Step 8's prepsubband grid (requires -L)
PRESTO_FOLD_INPUT_FLAG=0        # -y : prepfold input, 0 = .fil, 1 = dedispersed .dat
PRESTO_BEAMS=""                 # -b : optional beam filter, space/comma separated beam indices

# --- USAGE/HELP FUNCTION ---
usage() {
    cat << EOF
Usage: $(basename "$0") -d <data_path> -n "<node1> <node2> ..." [OPTIONS]

Required Arguments:
  -d PATH         Path to the base data directory containing FilData/
  -n "NODES"      Space or comma separated list of compute target nodes
                  (e.g., -n "rggpu40 rggpu41 rggpu42 rggpu43 rggpu44")

Optional Arguments:
  -l FLOAT        Lower SNR threshold limit (Default: 5)
  -u FLOAT        Upper SNR threshold limit (Optional)
  -c INT          Sorting column index (plain 1-based, matches sigma,logp,r,z,power,numharm,frequency_hz,dm) (Default: 2)
  -o INT          Ordering direction flag (0: Ascending, 1: Descending) (Default: 1)
  -g INT          Number of GPUs per node to use concurrently (Default: 2)
  -p PATH         Path to a RA/DEC/BM-Idx beam layout file, used for the final
                  cross-beam coincidence filtering step. OPTIONAL: if omitted,
                  the pipeline auto-extracts beam coordinates from each
                  observation's .ahdr headers (Step 6) and uses that instead.
                  Only needed if you want to override the auto-extracted file.
  -r 0|1          Resume mode (Default: 1/on). If a step's expected output already
                  exists, skip re-running it. Pass -r 0 to force everything to
                  re-run regardless of what's already on disk.

Step 8 (PRESTO candidate pipeline) Options:
  -C INT          CPUs per PRESTO process (prepsubband/accelsearch/prepfold) (Default: 8)
  -j INT          Concurrent beam pipelines allowed per compute node (Default: 1)
  -m FLOAT        Minimum accelsearch candidate sigma required to trigger prepfold (Default: 5.0)
  -s FLOAT        DM step for Step 8's own prepsubband DM grid (Default: 0.10)
  -L FLOAT        Low DM for Step 8's prepsubband grid (requires -H; auto-extracted per beam if omitted)
  -H FLOAT        High DM for Step 8's prepsubband grid (requires -L; auto-extracted per beam if omitted)
  -y 0|1          prepfold input: 0 = original .fil, 1 = dedispersed .dat (Default: 0)
  -b "BEAMS"      Restrict Step 8 to specific beam indices, e.g. "12 34 57" or "12,34,57"
                  (Default: all beams present in the final cross-beam candidate CSV)
  -h              Display this help text and exit

Example:
  $(basename "$0") -d /lustre_archive/spotlight/Nishant/DATA_DIR -n "rggpu40 rggpu41"
EOF
    exit 1
}

# --- PARSE COMMAND LINE FLAGS ---
while getopts "d:n:l:u:c:o:g:p:r:C:j:m:s:L:H:y:b:h" opt; do   # loop over each recognized flag
    case "${opt}" in
        d) DATA_PATH="${OPTARG}" ;;             # capture data path
        n) COMPUTE_NODES_INPUT="${OPTARG}" ;;   # capture raw node list string
        l) LOW_TH="${OPTARG}" ;;                # capture lower threshold
        u) HIGH_TH="${OPTARG}" ;;               # capture upper threshold
        c) SORT_COL="${OPTARG}" ;;              # capture sort column
        o) ORDER_FLAG="${OPTARG}" ;;            # capture order flag
        g) GPUS_PER_NODE="${OPTARG}" ;;         # capture GPUs-per-node override
        p) BEAM_POSITIONS="${OPTARG}" ;;        # NEW: capture beam RA/DEC layout file path
        r) RESUME="${OPTARG}" ;;                # NEW: capture resume mode override
        C) PRESTO_NCPUS="${OPTARG}" ;;          # NEW: Step 8 CPUs per PRESTO process
        j) PRESTO_JOBS_PER_NODE="${OPTARG}" ;;  # NEW: Step 8 concurrent beam pipelines per node
        m) PRESTO_SIGMA_THRESH="${OPTARG}" ;;   # NEW: Step 8 minimum fold sigma
        s) PRESTO_DM_STEP="${OPTARG}" ;;        # NEW: Step 8 prepsubband DM step
        L) PRESTO_LOW_DM="${OPTARG}" ;;         # NEW: Step 8 prepsubband grid low DM
        H) PRESTO_HIGH_DM="${OPTARG}" ;;        # NEW: Step 8 prepsubband grid high DM
        y) PRESTO_FOLD_INPUT_FLAG="${OPTARG}" ;; # NEW: Step 8 prepfold input (.fil vs .dat)
        b) PRESTO_BEAMS="${OPTARG}" ;;          # NEW: Step 8 beam filter
        h) usage ;;                             # -h shows help and exits
        *) usage ;;                             # any unrecognized flag also shows help
    esac
done

# Validate required inputs
if [ -z "$DATA_PATH" ]; then
    log_error "Missing required argument: -d <data_path> is mandatory."   # abort if -d missing
fi
if [ -z "$COMPUTE_NODES_INPUT" ]; then
    log_error "Missing required argument: -n \"<compute_nodes>\" is mandatory."  # abort if -n missing
fi
if [ ! -d "$DATA_PATH/FilData" ]; then
    log_error "The expected FilData directory does not exist inside: $DATA_PATH"  # abort if data layout wrong
fi

# Convert compute nodes to Bash Array
COMPUTE_NODES=($(echo "$COMPUTE_NODES_INPUT" | tr ',' ' '))   # normalize commas to spaces, then word-split into array
NUM_NODES=${#COMPUTE_NODES[@]}                                 # count how many nodes we actually got

# BUGFIX: guard against a divide-by-zero crash later (FILE_IDX % NUM_NODES)
if [ "$NUM_NODES" -eq 0 ]; then
    log_error "No valid compute nodes were parsed from -n. Check the -n argument."   # abort early, clear message
fi

# NEW: validate GPUS_PER_NODE is a sane positive integer before we use it below
if ! [[ "$GPUS_PER_NODE" =~ ^[0-9]+$ ]] || [ "$GPUS_PER_NODE" -lt 1 ]; then
    log_error "-g must be a positive integer (got: $GPUS_PER_NODE)."
fi

# NEW: validate Step 8 (PRESTO) options up front, same convention as
# presto_candidate_pipeline_fast.sh's own validation, so a typo here fails
# immediately instead of surfacing deep inside a remote SSH session at Step 8.
if ! [[ "$PRESTO_NCPUS" =~ ^[1-9][0-9]*$ ]]; then log_error "-C PRESTO_NCPUS must be a positive integer."; fi
if ! [[ "$PRESTO_JOBS_PER_NODE" =~ ^[1-9][0-9]*$ ]]; then log_error "-j PRESTO_JOBS_PER_NODE must be a positive integer."; fi
if ! [[ "$PRESTO_SIGMA_THRESH" =~ ^[0-9]*\.?[0-9]+$ ]]; then log_error "-m PRESTO_SIGMA_THRESH must be a valid number."; fi
if ! [[ "$PRESTO_DM_STEP" =~ ^[0-9]*\.?[0-9]+$ ]] || [ "$(awk -v v="$PRESTO_DM_STEP" 'BEGIN{print (v<=0)}')" -eq 1 ]; then
    log_error "-s PRESTO_DM_STEP must be a positive number.";
fi
if [ -n "$PRESTO_LOW_DM" ] || [ -n "$PRESTO_HIGH_DM" ]; then
    if [ -z "$PRESTO_LOW_DM" ] || [ -z "$PRESTO_HIGH_DM" ]; then
        log_error "-L and -H must be given together.";
    fi
    if ! [[ "$PRESTO_LOW_DM" =~ ^-?[0-9]*\.?[0-9]+$ ]] || ! [[ "$PRESTO_HIGH_DM" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
        log_error "-L and -H must be numbers.";
    fi
    if [ "$(awk -v lo="$PRESTO_LOW_DM" -v hi="$PRESTO_HIGH_DM" 'BEGIN{print (lo>=hi)}')" -eq 1 ]; then
        log_error "-L LOW_DM must be less than -H HIGH_DM.";
    fi
fi
if [[ "$PRESTO_FOLD_INPUT_FLAG" != "0" && "$PRESTO_FOLD_INPUT_FLAG" != "1" ]]; then
    log_error "-y must be either 0 (.fil) or 1 (.dat).";
fi

# NEW: build one "slot" per (node, GPU card) pair, e.g. for -n "rggpu38 rggpu39" -g 2:
#   rggpu38:0  rggpu38:1  rggpu39:0  rggpu39:1
# Each slot can run exactly one file at a time. This is what actually gives us
# GPUS_PER_NODE-way concurrency PER NODE, instead of only one file per node.
SLOTS=()                                            # will hold "node:card_id" strings
for NODE in "${COMPUTE_NODES[@]}"; do               # for every node given via -n
    for (( CARD=0; CARD<GPUS_PER_NODE; CARD++ )); do   # for every GPU card index on that node
        SLOTS+=("${NODE}:${CARD}")                  # record this node+card combination as one slot
    done
done
NUM_SLOTS=${#SLOTS[@]}                               # total concurrent job capacity = nodes * GPUs per node

log_info "Loaded $NUM_NODES node(s) x $GPUS_PER_NODE GPU(s) = $NUM_SLOTS concurrent slot(s): ${SLOTS[*]}"   # confirm slot list to user

FIRST_NODE="${COMPUTE_NODES[0]}"   # NEW: the first node from -n, used to run Step 6 (beam coordinate extraction) per your request

if [ "$RESUME" -eq 1 ]; then
    log_info "Resume mode ON: steps whose expected output already exists will be skipped. Pass -r 0 to force a full re-run."
else
    log_info "Resume mode OFF (-r 0): every step will re-run regardless of existing output."
fi

# --- TOTAL RUN TIMING SETUP ---
# This tracks wall-clock time for the ENTIRE run (all observations, all beams),
# separate from the existing per-beam TIMING_LOG inside process_one_file().
PIPELINE_START_EPOCH=$(date +%s)                          # Unix timestamp at start, used to compute total elapsed time
PIPELINE_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')          # human-readable start time, for the summary file
GRAND_TOTAL_FILES=0                                         # running count of .fil files processed across ALL observations
GRAND_TOTAL_OBS=0                                           # running count of observations actually processed (non-skipped)
SUMMARY_DIR="$DATA_PATH/ORION_output"                       # this is the directory that directly contains all BM0, BM1, ... dirs
mkdir -p "$SUMMARY_DIR"                                     # ensure it exists even before any beam has been dispatched
TOTAL_TIMING_LOG="$SUMMARY_DIR/total_run_timing.log"        # the file the overall summary will be written to

# --- 2. PIPELINE FIXED PARAMETERS ---
H_TOLERANCE=0.1     # harmonic tolerance for AA/pulscan
H_THREADS=32        # CPU threads for harmonic search step
H_LIST="0.1 0.1111111111111111 0.125 0.14285714285714285 0.16666666666666666 0.2 0.25 0.3333333333333333 0.5 1 2 3 4 5 6 7 8 9 10"  # harmonic ratio list
FREQ_TOL=0.5        # frequency tolerance for coincidence matching

AA_PULSCAN_PATH="/lustre_archive/apps/tdsoft/pulsar_search_aa_versions/astro-accelerate_ORION_final"  # AA+PULSCAN install path
ORION_PATH="/lustre_archive/spotlight/Nishant/ORION/ver1"                                        # your ORION scripts path
TEMPLATE_FILE="$AA_PULSCAN_PATH/input_files/aa_pulscan_master.txt"                                 # master template (never modified)
# NOTE: WORKING_FILE is now built PER FILE further down (see BUGFIX below), not as one shared global path.

if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then
    source /lustre_archive/apps/tdsoft/env.sh   # load shared environment if present, on the login node
fi

# --- STEP 6 HELPER: extract RA/DEC/BM-Idx from .ahdr headers ---
# Ported from your standalone extract_beam_coordinates.sh, with three changes:
# 1. `exit 1` -> `return 1` / remote exit codes, since `exit` inside a function
#    called from the main script body would kill the ENTIRE pipeline over one
#    bad directory -- this lets the caller log a warning and move on instead.
# 2. Uses the script's existing log_info/log_warn/log_success helpers instead
#    of plain echo, so its output matches the rest of the pipeline's logging.
# 3. NEW: the actual find/awk work now runs over `ssh -n` on a caller-specified
#    node (TARGET_NODE), per your request that all Step 6 actions happen on
#    the first GPU node from -n, rather than on the login node. Since the
#    input/output paths sit on shared Lustre storage, we can still inspect the
#    OUTPUT_FILE locally afterward -- only the extraction work itself is remote.
extract_beam_coordinates() {
    local INPUT_DIR="$1"      # directory containing the .ahdr files
    local OUTPUT_FILE="$2"    # where to write the extracted RA/DEC/BM-Idx table (shared Lustre path)
    local TARGET_NODE="$3"    # NEW: which node to actually run the extraction on

    log_info "  Running extraction on $TARGET_NODE ..."

    # Everything inside this ssh string executes on TARGET_NODE, not locally.
    # INPUT_DIR/OUTPUT_FILE are unescaped ($) because they're plain shared-path
    # constants already known locally (same convention used in process_one_file's
    # ssh block); \$FILE and the awk field variables (\$1, \$2, \$3) are escaped
    # so they survive to be interpreted on the REMOTE shell/awk, not expanded here.
    ssh -n "$TARGET_NODE" "
        if [ ! -d \"$INPUT_DIR\" ]; then exit 2; fi
        if ! compgen -G \"$INPUT_DIR/*.ahdr\" > /dev/null; then exit 3; fi

        printf '%-16s %-16s %s\n' 'RA' 'DEC' 'BM-Idx' > \"$OUTPUT_FILE\"

        while IFS= read -r FILE; do
            echo \"  Extracting beam coordinates from: \$(basename \"\$FILE\")\"
            awk '
            /BM-Idx[[:space:]]+BM-SubIdx/ {
                capture=1
                next
            }
            capture && NF == 4 && \$1 ~ /^[-+0-9.]+\$/ {
                print \$1, \$2, \$3
            }
            ' \"\$FILE\" >> \"$OUTPUT_FILE\"
        done < <(find \"$INPUT_DIR\" -maxdepth 1 -type f -name \"*.ahdr\" | sort -V)
    "
    local ssh_status=$?   # 2 = missing dir, 3 = no .ahdr files, 0 = success, anything else = unexpected remote failure

    if [ $ssh_status -eq 2 ]; then
        log_warn "Beam coordinate extraction: input directory does not exist: $INPUT_DIR (checked on $TARGET_NODE) -- skipping."
        return 1
    elif [ $ssh_status -eq 3 ]; then
        log_warn "Beam coordinate extraction: no .ahdr files found in $INPUT_DIR (checked on $TARGET_NODE) -- skipping."
        return 1
    elif [ $ssh_status -ne 0 ]; then
        log_warn "Beam coordinate extraction: remote command failed on $TARGET_NODE (exit $ssh_status) -- skipping."
        return 1
    fi

    # OUTPUT_FILE was written remotely, but it lives on shared Lustre storage,
    # so we can inspect it right here on the login node now that ssh has returned.
    local NUM_BEAMS
    NUM_BEAMS=$(($(wc -l < "$OUTPUT_FILE") - 1))   # total lines minus the header row
    if [ "$NUM_BEAMS" -le 0 ]; then
        log_warn "Beam coordinate extraction: 0 beams parsed from $INPUT_DIR -- output file is header-only."
        return 1
    fi

    log_success "Beam coordinate extraction complete: $NUM_BEAMS beam(s) -> $OUTPUT_FILE (ran on $TARGET_NODE)"
    return 0
}

# --- 3. MULTI-OBSERVATION MULTI-FILE LOOP ---

# Step A: Find all distinct observation subdirectories inside FilData
OBS_DIRS=$(find "$DATA_PATH/FilData" -maxdepth 1 -mindepth 1 -type d | sort)   # one dir per observation

if [ -z "$OBS_DIRS" ]; then
    log_error "No observation subdirectories found inside $DATA_PATH/FilData/"   # nothing to do, abort
fi

# --- PER-FILE WORKER FUNCTION ---
# This function does the work that used to be inline in the loop. Running it means
# it can be safely launched in the BACKGROUND (with `&`), which is what gives us
# real multi-GPU-node parallelism instead of one-file-at-a-time processing.
process_one_file() {
    local FIL_FILE_PATH="$1"    # full path to this beam's .fil file
    local CURRENT_NODE="$2"     # which rggpuXX node this file is assigned to
    local OBS_NAME="$3"         # observation name, only used for log messages
    local CARD_ID="$4"          # NEW: which GPU card index (0, 1, ...) on CURRENT_NODE to use

    local FIL_BASE_NAME
    FIL_BASE_NAME=$(basename "$FIL_FILE_PATH")     # e.g. BM07.fil
    local FIL_STRIPPED_NAME="${FIL_BASE_NAME%.*}"   # e.g. BM07 (no extension)

    log_info "[$OBS_NAME] Dispatching $FIL_BASE_NAME -> $CURRENT_NODE (GPU card $CARD_ID)"   # announce dispatch, now includes card

    # --- 4. DYNAMIC PATH SETTINGS (SANDBOXED BY FILE BASENAME) ---
    local BASE_DIR="$DATA_PATH/ORION_output/$FIL_STRIPPED_NAME"   # unique output root per beam/file
    local OUTPUT_DIR="$BASE_DIR/output/aa_pulscan_${FIL_STRIPPED_NAME}"   # BUGFIX: AA+PULSCAN names this dir per-beam
                                                                            # (e.g. aa_pulscan_BM07), not a fixed "aa_pulscan_orion"
                                                                            # shared by every beam -- must match per file.
    local DM_SPLIT_OUT="$BASE_DIR/output/dm_split_results"          # NEW: where Step 3 (split_by_dm.sh) writes its per-DM files,
                                                                     # and where Step 4 (harmonic filter) reads its input from
    local TIMING_LOG="$BASE_DIR/output/pipeline_timing.log"        # per-file timing log

    mkdir -p "$BASE_DIR/output"                       # create sandbox dir tree (safe if it already exists)

    # BUGFIX (resumability): don't blow away an existing timing log if we're about
    # to skip some/all steps for this beam -- only start a fresh one if it doesn't
    # exist yet, so a resumed run's log still has the earlier attempt's history.
    if [ ! -f "$TIMING_LOG" ]; then
        echo "Step,Duration_Seconds,Status" > "$TIMING_LOG"
    fi

    # BUGFIX (critical for parallelism / requirement #3):
    # WORKING_FILE must be UNIQUE PER FILE. Previously it was one shared path reused
    # by every file/node, which is a race condition the instant more than one file
    # is processed at the same time -- two concurrent jobs would stomp on each
    # other's input file mid-read.
    local WORKING_FILE="$AA_PULSCAN_PATH/input_files/aa_pulscan_${FIL_STRIPPED_NAME}.txt"   # unique per beam

    rm -f "$WORKING_FILE"                              # clear any stale file with this name
    head -n -1 "$TEMPLATE_FILE" > "$WORKING_FILE"       # copy template minus its last line (GNU head syntax)

    # NEW: point this file's job at the correct GPU card on its assigned node.
    # The template's "selected_card_id 0" line is a fixed value; we overwrite it
    # per-file so file A can run on card 0 while file B runs on card 1 of the
    # same node at the same time, instead of both fighting over card 0.
    sed -i "s/^selected_card_id .*/selected_card_id ${CARD_ID}/" "$WORKING_FILE"   # rewrite that one line in place

    local FINAL_FIL_PATH
    FINAL_FIL_PATH=$(realpath "$FIL_FILE_PATH")         # resolve to an absolute path (Lustre is shared, so this is valid on the remote node too)
    printf "file %s\n" "$FINAL_FIL_PATH" >> "$WORKING_FILE"   # append this beam's file line

    # --- 5. REMOTE EXECUTION BOUNDARY ---
    # BUGFIX (likely cause of the terminal crash): dropped `-t` (pseudo-terminal
    # allocation) in favor of `-n` (stdin from /dev/null). We don't need an
    # interactive TTY for a non-interactive batch command, and `-t` is what causes
    # local terminal corruption when sessions are run concurrently/in the background
    # or drop unexpectedly.
    ssh -n "$CURRENT_NODE" "
        export OUTPUT_DIR=\"$OUTPUT_DIR\"          # pass output dir into remote shell
        export LOW_TH=\"$LOW_TH\"                  # pass lower threshold
        export HIGH_TH=\"$HIGH_TH\"                # pass upper threshold (may be empty)
        export SORT_COL=\"$SORT_COL\"              # pass sort column
        export ORDER_FLAG=\"$ORDER_FLAG\"          # pass order flag
        export TIMING_LOG=\"$TIMING_LOG\"          # pass this file's own timing log path
        export CARD_ID=\"$CARD_ID\"                # NEW: pass GPU card id through, for remote-side logging only
                                                    #  (the actual card selection lives in WORKING_FILE's selected_card_id line)
        export RESUME=\"$RESUME\"                  # NEW: pass resume mode through to the remote shell

        if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then source /lustre_archive/apps/tdsoft/env.sh; fi   # load shared env on remote node
        if [ -f \"$AA_PULSCAN_PATH/scripts/environment.sh\" ]; then source \"$AA_PULSCAN_PATH/scripts/environment.sh\"; fi   # load AA env on remote node

        log_remote_info() { echo -e \"\033[0;34m[REMOTE INFO]\033[0m \$1\"; }   # minimal logger for remote-side messages
        log_remote_skip() { echo -e \"\033[0;33m[REMOTE SKIP]\033[0m \$1\"; }   # NEW: distinguishes a resumed/skipped step from a fresh run

        # NEW: resumability helper. If RESUME=1 and the given path already exists
        # (and, for files, is non-empty), print a SKIP message, log a
        # Skipped/duration-0 line to the timing CSV, and return success (0) so the
        # caller's \"if ...; then skip; else run; fi\" pattern works uniformly for
        # every step below.
        step_already_done() {
            local CHECK_PATH=\"\$1\"
            local STEP_LABEL=\"\$2\"
            if [ \"\$RESUME\" -eq 1 ] && [ -e \"\$CHECK_PATH\" ] && [ -s \"\$CHECK_PATH\" ]; then
                log_remote_skip \"\$STEP_LABEL already done (found: \$CHECK_PATH) -- skipping.\"
                echo \"\${STEP_LABEL},0,skipped\" >> \"\$TIMING_LOG\"
                return 0
            fi
            return 1
        }

        log_remote_info \"Step 1: Running Astro-Accelerate Core Binary on GPU card \$CARD_ID...\"    # announce step 1, now shows which card
        if ! step_already_done \"\$OUTPUT_DIR/global_pulscan_candidates.csv\" \"Step_1_AA\"; then
            START_TIME=\$SECONDS                                                    # start remote timer
            \"$AA_PULSCAN_PATH/scripts/astro-accelerate.sh\" \"$WORKING_FILE\" \"$BASE_DIR\"   # run AA on THIS file's unique working file
            status_s1=\$?                                                           # capture AA exit status
            echo \"Step_1_AA,\$((SECONDS - START_TIME)),\$status_s1\" >> \"\$TIMING_LOG\"   # log timing/status
            if [ \$status_s1 -ne 0 ]; then exit 1; fi                              # bail out of remote script on failure
        fi

        log_remote_info \"Step 2: Candidate Sifting (Thresholds: \$LOW_TH to \$HIGH_TH)...\"   # announce step 2
        if ! step_already_done \"\$OUTPUT_DIR/global_pulscan_candidates_new.csv\" \"Step_2_Sifting\"; then
            START_TIME=\$SECONDS                                                    # restart timer
            \"$ORION_PATH/script/process_data.sh\" \"\$OUTPUT_DIR/global_pulscan_candidates.csv\" \"\$LOW_TH\" \"\$HIGH_TH\" \"\$SORT_COL\" \"\$ORDER_FLAG\"   # sift candidates
            status_s2=\$?                                                           # capture sifting exit status
            echo \"Step_2_Sifting,\$((SECONDS - START_TIME)),\$status_s2\" >> \"\$TIMING_LOG\"   # log timing/status
            if [ \$status_s2 -ne 0 ]; then exit 1; fi                              # bail out on failure
        fi

        log_remote_info \"Step 3: Splitting by DM...\"                         # announce step 3
        if ! step_already_done \"$DM_SPLIT_OUT\" \"Step_3_DM_Split\"; then
            START_TIME=\$SECONDS                                                    # restart timer
            \"$ORION_PATH/script/split_by_dm.sh\" \"\$OUTPUT_DIR/global_pulscan_candidates_new.csv\"   # split by DM
            status_s3=\$?                                                           # capture split exit status
            echo \"Step_3_DM_Split,\$((SECONDS - START_TIME)),\$status_s3\" >> \"\$TIMING_LOG\"   # log timing/status
            if [ \$status_s3 -ne 0 ]; then exit 1; fi                              # bail out on failure
        fi

        log_remote_info \"Step 4: Running Parallel Harmonic Filtering (Intra-DM)...\"   # announce step 4
        if ! step_already_done \"$BASE_DIR/output/dm_filtered_results\" \"Step_4_IntraDM_Harmonic\"; then
            START_TIME=\$SECONDS                                                    # restart timer
            python3 \"$ORION_PATH/script/parallel_harmonic_filter_new.py\" \
                --input_dir \"$DM_SPLIT_OUT\" \
                --f_tol_pct \"$FREQ_TOL\" \
                --harmonics $H_LIST \
                --threads \"$H_THREADS\" \
                --debug                                                            # intra-DM harmonic filtering, reads Step 3's output
            status_s4=\$?                                                           # capture filter exit status
            echo \"Step_4_IntraDM_Harmonic,\$((SECONDS - START_TIME)),\$status_s4\" >> \"\$TIMING_LOG\"   # log timing/status
            if [ \$status_s4 -ne 0 ]; then exit 1; fi                              # bail out on failure
        fi

        log_remote_info \"Step 5: Executing Cross-DM Harmonic Synchronization...\"   # announce step 5
        if ! step_already_done \"$BASE_DIR/output/dm_synchronized_results/final_pulsar_candidate.csv\" \"Step_5_CrossDM_Harmonic\"; then
            START_TIME=\$SECONDS                                                    # restart timer
            python3 \"$ORION_PATH/script/process_harmonics_new.py\" \
                --input_dir \"$BASE_DIR/output/dm_filtered_results/\" \
                --output_dir \"$BASE_DIR/output/dm_synchronized_results\" \
                --f_tol_pct \"$FREQ_TOL\" \
                --harmonics $H_LIST \
                --harmonic_matching \
                --debug
            status_s5=\$?                                                           # capture sync exit status
            echo \"Step_5_CrossDM_Harmonic,\$((SECONDS - START_TIME)),\$status_s5\" >> \"\$TIMING_LOG\"   # log timing/status
            if [ \$status_s5 -ne 0 ]; then exit 1; fi                              # bail out on failure
        fi
    "
    local ssh_status=$?   # capture ssh's own exit status (reflects the remote script's exit code)

    if [ $ssh_status -ne 0 ]; then
        log_warn "[$OBS_NAME] Compute node tasks failed on $CURRENT_NODE for $FIL_BASE_NAME."   # warn only, don't kill the whole run
        return 1   # BUGFIX: `return`, not `exit` -- this function may be running as a background job,
                   #  and `exit` here would silently kill that job without a clear top-level message anyway.
                   #  `return` lets the caller decide what to do (and doesn't risk `set -e` weirdness).
    fi

    log_success "[$OBS_NAME] Completed $FIL_BASE_NAME on $CURRENT_NODE (GPU card $CARD_ID)."   # per-file success message
    return 0
}

# Loop over each observation sequentially (observations themselves are still processed one at a time,
# but ALL files within an observation are now fanned out across your nodes in parallel).
for OBS_DIR in $OBS_DIRS; do
    OBS_NAME=$(basename "$OBS_DIR")   # human-readable observation name for logs

    echo "##########################################################################"
    log_info "STARTING PROCESSING FOR OBSERVATION: $OBS_NAME"   # banner per observation
    echo "##########################################################################"

    # Step B: Find only the .fil files belonging STRICTLY to this observation folder
    FIL_FILES=$(find "$OBS_DIR" -maxdepth 1 -type f -name "*.fil" | sort)   # e.g. 160 BMXX.fil files

    if [ -z "$FIL_FILES" ]; then
        log_warn "No valid .fil files found inside observation directory: $OBS_DIR. Skipping."   # skip empty obs
        continue
    fi

    TOTAL_FILES=$(echo "$FIL_FILES" | wc -l)   # count files for progress logging
    log_info "Found $TOTAL_FILES .fil file(s) inside $OBS_NAME to distribute across $NUM_SLOTS GPU slot(s)."

    GRAND_TOTAL_FILES=$(( GRAND_TOTAL_FILES + TOTAL_FILES ))   # add this observation's file count to the running grand total
    GRAND_TOTAL_OBS=$(( GRAND_TOTAL_OBS + 1 ))                 # count this as one more observation actually processed

    FILE_IDX=0   # running index used to round-robin across GPU slots (node+card pairs)

    # Step C: Distribute the N files of this single observation across the GPU slots, IN PARALLEL.
    # BUGFIX (requirement #2, extended for multi-GPU nodes): round-robins over SLOTS
    # (node:card pairs) instead of just nodes, so each of a node's GPUs gets its own
    # file running concurrently, instead of only one file per node regardless of
    # how many GPUs it has.
    for FIL_FILE_PATH in $FIL_FILES; do
        SLOT_IDX=$(( FILE_IDX % NUM_SLOTS ))                # round-robin index into the slot array
        CURRENT_SLOT="${SLOTS[$SLOT_IDX]}"                   # e.g. "rggpu38:1"
        CURRENT_NODE="${CURRENT_SLOT%%:*}"                   # everything before the ":" -> node name
        CURRENT_CARD="${CURRENT_SLOT##*:}"                   # everything after the ":" -> GPU card id
        ((FILE_IDX++))                                       # advance for the next file

        process_one_file "$FIL_FILE_PATH" "$CURRENT_NODE" "$OBS_NAME" "$CURRENT_CARD" &   # launch this file's pipeline in the background

        # Throttle: once we have NUM_SLOTS jobs in flight (one per GPU across all nodes),
        # wait for a slot to free up before launching the next.
        # BUGFIX: `wait -n` needs Bash 4.3+; the cluster's /bin/bash is older than
        # that, so `wait -n` fails with "invalid option". Polling every second
        # instead works on any bash version and costs nothing given these jobs
        # run for minutes, not seconds.
        while [ "$(jobs -rp | wc -l)" -ge "$NUM_SLOTS" ]; do
            sleep 1   # re-check job count once a second until a slot frees up
        done
    done

    wait   # after dispatching all files for this observation, wait for the final in-flight jobs to finish
    log_success "Finished all files for observation: $OBS_NAME"   # observation-level completion message
done

log_success "-------------------------------------------------------------"
log_success "All observations and their respective files processed completely!"
log_success "-------------------------------------------------------------"

# --- STEP 6: extract beam RA/DEC/BM-Idx from .ahdr headers ---
# BUGFIX: this used to run once PER OBSERVATION pointed at "$OBS_DIR/BeamData", which
# doesn't exist -- your script's own usage example shows BeamData living at the TOP
# LEVEL, alongside FilData/ (i.e. "$DATA_PATH/BeamData"), not nested inside each scan.
# Since it's one shared directory rather than per-scan, this now runs ONCE, after all
# observations finish, instead of being needlessly re-run (with identical results)
# once per observation. Runs on FIRST_NODE per your request that Step 6 stay on the
# first GPU node given via -n, rather than the login node.
BEAM_HDR_INPUT_DIR="$DATA_PATH/BeamData"                 # top-level, sibling of FilData/
BEAM_HDR_OUTPUT_FILE="$SUMMARY_DIR/beam_positions.txt"    # single file, no per-observation suffix
STEP6_SECONDS=0                                            # NEW: timing capture for the main log
if [ "$RESUME" -eq 1 ] && [ -s "$BEAM_HDR_OUTPUT_FILE" ]; then
    log_info "Step 6: $BEAM_HDR_OUTPUT_FILE already exists -- skipping extraction (resume mode)."
    AUTO_BEAM_POSITIONS="$BEAM_HDR_OUTPUT_FILE"
else
    log_info "Step 6: Extracting beam coordinates on $FIRST_NODE..."
    STEP6_START=$SECONDS
    if extract_beam_coordinates "$BEAM_HDR_INPUT_DIR" "$BEAM_HDR_OUTPUT_FILE" "$FIRST_NODE"; then
        AUTO_BEAM_POSITIONS="$BEAM_HDR_OUTPUT_FILE"   # used as the default for Step 7 below if -p wasn't given explicitly
    fi
    STEP6_SECONDS=$((SECONDS - STEP6_START))
fi

# --- STEP 7: CROSS-BEAM COINCIDENCE FILTERING (runs once, after every beam is done) ---
# NEW: this is the final pipeline stage -- it needs EVERY beam's final_pulsar_candidate.csv
# to already exist, so it can only run after the loops above have fully finished, not
# per-file or per-observation like Steps 1-5.
CROSS_BEAM_STATUS=0                              # tracks whether this step ran/succeeded, for the timing log below
CROSS_BEAM_SECONDS=0                              # NEW: default to 0, set below if the step actually runs

# Decide which beam-positions file to use: an explicit -p always wins (manual override);
# otherwise fall back to whatever Step 6 auto-extracted from .ahdr headers.
EFFECTIVE_BEAM_POSITIONS="$BEAM_POSITIONS"
if [ -z "$EFFECTIVE_BEAM_POSITIONS" ] && [ -n "$AUTO_BEAM_POSITIONS" ]; then
    EFFECTIVE_BEAM_POSITIONS="$AUTO_BEAM_POSITIONS"
    log_info "No -p given; using Step 6's auto-extracted beam positions: $EFFECTIVE_BEAM_POSITIONS"
fi

FINAL_MULTIBEAM_CSV="$SUMMARY_DIR/final_multibeam_candidates.csv"   # NEW: named once, reused for the resume check and Step 8 below

if [ -n "$EFFECTIVE_BEAM_POSITIONS" ]; then                # only run if we ended up with a beam-positions file one way or another
    if [ ! -f "$EFFECTIVE_BEAM_POSITIONS" ]; then
        log_warn "Beam position file not found: $EFFECTIVE_BEAM_POSITIONS -- skipping cross-beam filtering."   # don't abort the whole run over this
        CROSS_BEAM_STATUS=1
    elif [ "$RESUME" -eq 1 ] && [ -s "$FINAL_MULTIBEAM_CSV" ]; then
        log_info "Step 7: $FINAL_MULTIBEAM_CSV already exists -- skipping cross-beam filtering (resume mode)."
        CROSS_BEAM_STATUS=0
    else
        log_info "Step 7: Running cross-beam coincidence filtering on $FIRST_NODE..."   # announce final step
        CROSS_BEAM_START=$SECONDS
        ssh -n "$FIRST_NODE" bash -lc "
            if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then source /lustre_archive/apps/tdsoft/env.sh; fi
            python3 '$ORION_PATH/script/cross_beam_filter_optimized.py' \
                --data_dir '$SUMMARY_DIR' \
                --beam_positions '$EFFECTIVE_BEAM_POSITIONS' \
                --f_tol_pct '$FREQ_TOL' \
                --harmonics $H_LIST \
                --output_file '$FINAL_MULTIBEAM_CSV' \
                --rejected_file '$SUMMARY_DIR/rejected_multibeam_candidates.csv' \
                --keep_random_groups
        "
        CROSS_BEAM_STATUS=$?
        CROSS_BEAM_SECONDS=$((SECONDS - CROSS_BEAM_START))

        if [ $CROSS_BEAM_STATUS -eq 0 ]; then
            log_success "Step 7 complete (${CROSS_BEAM_SECONDS}s) -- final candidates: $FINAL_MULTIBEAM_CSV"
        else
            log_warn "Step 7 (cross-beam filtering) failed with exit code $CROSS_BEAM_STATUS -- per-beam results are still intact."
        fi
    fi
else
    log_warn "No beam positions available (neither -p nor a successful Step 6 extraction) -- skipping cross-beam filtering."
fi

# --- STEP 8: PRESTO DEDISPERSION + SEARCH + FOLDING ---
#
# Runs the complete PRESTO pipeline for each CROSS-BEAM-FILTERED candidate:
#
#     Candidate N:
#         prepdata -> accelsearch -> prepfold
#
# If any stage fails for an individual candidate, only that candidate is skipped.
# The remaining candidates continue processing.
#
# Parallelization:
#
#   PRESTO_NCPUS:
#       Number of CPU cores used internally by each PRESTO command
#       (prepdata, accelsearch, prepfold).
#
#   PRESTO_JOBS_PER_NODE:
#       Number of complete candidate pipelines allowed to run concurrently
#       per compute node.
#
# Example:
#   3 compute nodes and PRESTO_JOBS_PER_NODE=2
#   -> maximum 6 candidate pipelines running concurrently.
#
# Each individual candidate always runs sequentially:
#
#     prepdata
#         ↓
#     accelsearch
#         ↓
#     prepfold
#
# Outputs are moved to ORION_output only after all candidate pipelines finish.


PRESTO_SCRIPTS_PATH="$ORION_PATH/script"

# accelsearch escalating frequency-window percentages (kept as a fixed pipeline
# parameter, same treatment as H_LIST/H_TOLERANCE above -- override by editing
# this script if a run genuinely needs something other than the default ladder).
PRESTO_ACCEL_PCT_LIST="10 20 30 40 50"

# accelsearch maximum Fourier-bin drift.
PRESTO_ZMAX=200

# NEW: harmonic/duplicate-DM dedup applied within each beam before folding
# (reuses this pipeline's existing FREQ_TOL for consistency with Steps 5/7,
# plus the same DM tolerance convention as process_harmonics_new.py /
# cross_beam_filter_optimized.py's --dm_tol_abs default).
PRESTO_DM_TOL_ABS=2.0

STEP8_SECONDS=0   # NEW: timing capture for the main log

if [ "$CROSS_BEAM_STATUS" -eq 0 ] && \
   [ -f "$FINAL_MULTIBEAM_CSV" ]; then

    # NEW (resumability): Step 8 already skips individual candidates whose ACCEL/.cand
    # or fold output already exists (handled inside presto_candidate_pipeline_fast.sh itself).
    # At the ORCHESTRATOR level, the simplest useful signal that "Step 8 already ran" is
    # the presence of the final folded-plots directory with at least one file in it --
    # if you want candidate-level resume within Step 8, that already happens downstream.
    STEP8_ALREADY_DONE=0
    if [ "$RESUME" -eq 1 ] && [ -d "$SUMMARY_DIR/presto_folded_plots" ] && \
       [ "$(find "$SUMMARY_DIR/presto_folded_plots" -type f | head -n 1)" != "" ]; then
        STEP8_ALREADY_DONE=1
    fi

    if [ "$STEP8_ALREADY_DONE" -eq 1 ]; then
        log_info "Step 8: $SUMMARY_DIR/presto_folded_plots already has output -- skipping (resume mode). Delete it (or pass -r 0) to force a re-run."
        PRESTO_PIPELINE_STATUS=0
    else
        log_info "Step 8: Running PRESTO candidate processing pipeline on $FIRST_NODE..."
        log_info "Pipeline per beam: prepsubband -> accelsearch -> (harmonic dedup) -> prepfold"
        log_info "PRESTO CPUs per process: $PRESTO_NCPUS"
        log_info "Concurrent beam pipelines per node: $PRESTO_JOBS_PER_NODE"
        log_info "Fold sigma threshold: >= $PRESTO_SIGMA_THRESH"
        if [ -n "$PRESTO_BEAMS" ]; then
            log_info "Beam filter (-b) active: only processing beam(s): $PRESTO_BEAMS"
        fi

        # NEW: build the optional flags as plain local strings first (each value
        # single-quoted individually) rather than passing arrays/command-subst
        # through the ssh string -- this is a remote-command STRING, evaluated
        # locally once before it's handed to ssh, same convention as every other
        # flag on this call, so it has to already be complete, literal text.
        PRESTO_DM_RANGE_FLAGS=""
        if [ -n "$PRESTO_LOW_DM" ] && [ -n "$PRESTO_HIGH_DM" ]; then
            PRESTO_DM_RANGE_FLAGS="-L '$PRESTO_LOW_DM' -H '$PRESTO_HIGH_DM'"
        fi
        PRESTO_BEAM_FLAG=""
        if [ -n "$PRESTO_BEAMS" ]; then
            PRESTO_BEAM_FLAG="-b '$PRESTO_BEAMS'"
        fi

        STEP8_START=$SECONDS
        ssh -n "$FIRST_NODE" bash -lc "set -euo pipefail; \
            if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then source /lustre_archive/apps/tdsoft/env.sh; fi; \
            bash '$PRESTO_SCRIPTS_PATH/presto_candidate_pipeline.sh' \
                -d '$DATA_PATH' \
                -n '$COMPUTE_NODES_INPUT' \
                -c '$PRESTO_NCPUS' \
                -j '$PRESTO_JOBS_PER_NODE' \
                -m '$PRESTO_SIGMA_THRESH' \
                -s '$PRESTO_DM_STEP' \
                $PRESTO_DM_RANGE_FLAGS \
                -w '$PRESTO_ACCEL_PCT_LIST' \
                -x '$PRESTO_ZMAX' \
                -y '$PRESTO_FOLD_INPUT_FLAG' \
                -r '$RESUME' \
                -t '$FREQ_TOL' \
                -T '$PRESTO_DM_TOL_ABS' \
                $PRESTO_BEAM_FLAG
        "
        PRESTO_PIPELINE_STATUS=$?
        STEP8_SECONDS=$((SECONDS - STEP8_START))

        if [ $PRESTO_PIPELINE_STATUS -eq 0 ]; then
            log_success "Step 8 complete (${STEP8_SECONDS}s): PRESTO candidate processing pipeline finished."
        else
            log_warn "Step 8 encountered an error. Check the PRESTO pipeline output for details."
        fi
    fi

else

    log_warn "Step 8: skipping PRESTO pipeline -- no cross-beam-filtered candidates available (Step 7 did not succeed)."

fi

# --- TOTAL RUN TIMING: write the overall summary ---
PIPELINE_END_EPOCH=$(date +%s)                              # Unix timestamp at the very end of the run
PIPELINE_END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')              # human-readable end time
TOTAL_SECONDS=$(( PIPELINE_END_EPOCH - PIPELINE_START_EPOCH ))   # total wall-clock seconds for the whole run
TOTAL_HMS=$(printf '%02d:%02d:%02d' $((TOTAL_SECONDS/3600)) $(((TOTAL_SECONDS%3600)/60)) $((TOTAL_SECONDS%60)))   # HH:MM:SS format

# NEW: aggregate Steps 1-5's per-beam timing CSVs into step-level totals for the main
# log. Each beam already writes its own "Step_N_Name,duration,status" rows into its
# own pipeline_timing.log (unaffected by this) -- this just sums those same numbers
# across every beam so you get one "how long did Step 4 take in total" figure here,
# instead of having to open 160 separate per-beam files to piece it together.
STEP_TIMING_SUMMARY=$(
    find "$SUMMARY_DIR" -name "pipeline_timing.log" -exec cat {} \; 2>/dev/null \
    | awk -F, 'NR==1 || $1=="Step" {next} {sum[$1]+=$2; cnt[$1]+=1} END {for (s in sum) printf "%-28s total=%8ds  across %d beam-step(s)\n", s, sum[s], cnt[s]}' \
    | sort
)

{
    echo "===== TOTAL PIPELINE RUN SUMMARY ====="
    echo "Start time:              $PIPELINE_START_HUMAN"
    echo "End time:                $PIPELINE_END_HUMAN"
    echo "Total duration (H:M:S):  $TOTAL_HMS"
    echo "Total duration (seconds):$TOTAL_SECONDS"
    echo "Observations processed:  $GRAND_TOTAL_OBS"
    echo "Total .fil files processed: $GRAND_TOTAL_FILES"
    echo "Compute nodes used:      ${COMPUTE_NODES[*]}"
    echo "GPUs per node:           $GPUS_PER_NODE"
    echo "Total concurrent slots:  $NUM_SLOTS"
    echo ""
    echo "----- Per-step timing (Steps 1-5, summed across all beams) -----"
    if [ -n "$STEP_TIMING_SUMMARY" ]; then
        echo "$STEP_TIMING_SUMMARY"
    else
        echo "(no per-beam timing logs found)"
    fi
    echo ""
    echo "----- Per-step timing (Steps 6-8, single run each) -----"
    echo "Step 6 (beam coordinate extraction): ${STEP6_SECONDS}s"
    echo "Step 7 (cross-beam filtering):        ${CROSS_BEAM_SECONDS}s"
    echo "Step 8 (PRESTO pipeline):             ${STEP8_SECONDS}s"
    echo ""
    if [ -n "$EFFECTIVE_BEAM_POSITIONS" ]; then
        echo "Beam positions used:     $EFFECTIVE_BEAM_POSITIONS"
        echo "Cross-beam filtering:    $( [ $CROSS_BEAM_STATUS -eq 0 ] && echo "OK" || echo "FAILED/SKIPPED (exit $CROSS_BEAM_STATUS)" )"
    else
        echo "Cross-beam filtering:    NOT RUN (no -p given and Step 6 auto-extraction found nothing)"
    fi
} > "$TOTAL_TIMING_LOG"   # overwrite (not append) -- one summary per run, matching the -d data path given this time

log_success "Total run time: $TOTAL_HMS -- summary written to $TOTAL_TIMING_LOG"   # confirm to the user on-screen too
