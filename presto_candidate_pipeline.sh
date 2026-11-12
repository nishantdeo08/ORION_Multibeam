#!/bin/bash

# --- ENVIRONMENT INITIALIZATION FOR NON-INTERACTIVE / SSH SESSIONS ---
[ -f /etc/profile ] && source /etc/profile 2>/dev/null
[ -f ~/.bash_profile ] && source ~/.bash_profile 2>/dev/null

if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then
    source /lustre_archive/apps/tdsoft/env.sh
fi

export PATH="/lustre_archive/apps/tdsoft/pulsarx/bin:$PATH"
export LD_LIBRARY_PATH="/lustre_archive/apps/tdsoft/pulsarx/lib:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
export BASH_ENV="/lustre_archive/apps/tdsoft/env.sh"

# ==============================================================================
# PRESTO Candidate Processing Pipeline (Two-Phase Search then Fold)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

DATA_PATH=""
COMPUTE_NODES_INPUT=""
NCPUS=16
JOBS_PER_NODE=1              
JOBS_PER_NODE_EXPLICIT=0       
DM_STEP=0.1                   
LOW_DM_OVERRIDE=""             
HIGH_DM_OVERRIDE=""            
ACCEL_PCT_LIST="10 20 30" 
ZMAX=200
FOLD_INPUT_FLAG=0              # 0 = fold on .fil, 1 = fold on .dat, 2 = fold on both (PRESTO engine only; PulsarX always folds on .fil)
RESUME=1                       
SIGMA_THRESH=5.0               
BEAM_FILTER=""                  
FOLDER_ENGINE="presto"          
PULSARX_TEMPLATE="/lustre_archive/spotlight/Nishant/templates" 
HARMONIC_TOL=0.01              # relative tolerance for inter/intra-DM harmonic ratio matching (0.01 = 1%)
INTER_DM_ELIM="on"             # on = dedup pools candidates across ALL DM trials in a beam; off = intra-DM only (per-DM-trial)

usage() {
    cat <<'USAGE'
Usage:
  ./presto_candidate_pipeline.sh -d <DATA_PATH> -n "<node1> <node2> ..." [OPTIONS]
USAGE
    exit 1
}

while getopts "d:n:c:j:m:s:L:H:w:x:y:r:b:F:t:i:h" opt; do
    case "$opt" in
        d) DATA_PATH="$OPTARG" ;;
        n) COMPUTE_NODES_INPUT="$OPTARG" ;;
        c) NCPUS="$OPTARG" ;;
        j) JOBS_PER_NODE="$OPTARG"; JOBS_PER_NODE_EXPLICIT=1 ;;
        m) SIGMA_THRESH="$OPTARG" ;;
        s) DM_STEP="$OPTARG" ;;
        L) LOW_DM_OVERRIDE="$OPTARG" ;;
        H) HIGH_DM_OVERRIDE="$OPTARG" ;;
        w) ACCEL_PCT_LIST="$OPTARG" ;;
        x) ZMAX="$OPTARG" ;;
        y) FOLD_INPUT_FLAG="$OPTARG" ;;
        r) RESUME="$OPTARG" ;;
        b) BEAM_FILTER="$OPTARG" ;;
        F) FOLDER_ENGINE="$OPTARG" ;;
        t) HARMONIC_TOL="$OPTARG" ;;
        i) INTER_DM_ELIM="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$DATA_PATH" ]; then log_error "Missing required argument: -d <DATA_PATH> is mandatory."; fi
if [ -z "$COMPUTE_NODES_INPUT" ]; then log_error "Missing required argument: -n \"<compute_nodes>\" is mandatory."; fi
if ! [[ "$NCPUS" =~ ^[1-9][0-9]*$ ]]; then log_error "-c NCPUS must be a positive integer."; fi

if [ "$JOBS_PER_NODE_EXPLICIT" -eq 0 ]; then
    JOBS_PER_NODE="$NCPUS"
fi

if ! [[ "$JOBS_PER_NODE" =~ ^[1-9][0-9]*$ ]]; then log_error "-j JOBS_PER_NODE must be a positive integer."; fi
if ! [[ "$SIGMA_THRESH" =~ ^[0-9]*\.?[0-9]+$ ]]; then log_error "-m SIGMA_THRESH must be a valid number."; fi
if ! [[ "$FOLD_INPUT_FLAG" =~ ^[0-2]$ ]]; then log_error "-y FOLD_INPUT_FLAG must be 0 (.fil), 1 (.dat), or 2 (both)."; fi
if ! [[ "$HARMONIC_TOL" =~ ^[0-9]*\.?[0-9]+$ ]]; then log_error "-t HARMONIC_TOL must be a valid number (e.g. 0.01 for 1%)."; fi
if [[ "$INTER_DM_ELIM" != "on" && "$INTER_DM_ELIM" != "off" ]]; then log_error "-i INTER_DM_ELIM must be 'on' or 'off'."; fi

if [[ "$FOLDER_ENGINE" != "presto" && "$FOLDER_ENGINE" != "pulsarx" ]]; then
    log_error "-F must be either 'presto' or 'pulsarx'.";
fi

# Clean beam filter input to convert commas to spaces
BEAM_FILTER=$(echo "$BEAM_FILTER" | tr ',' ' ')

read -r -a ACCEL_PCT_ARR <<< "$ACCEL_PCT_LIST"
if [ "${#ACCEL_PCT_ARR[@]}" -eq 0 ]; then log_error "-w must contain at least one percentage value."; fi

COMPUTE_NODES=($(echo "$COMPUTE_NODES_INPUT" | tr ',' ' '))
NUM_NODES=${#COMPUTE_NODES[@]}

SUMMARY_DIR="$DATA_PATH/ORION_output"
FINAL_CSV="$SUMMARY_DIR/final_multibeam_candidates.csv"
CAND_SCRATCH_DIR="$SUMMARY_DIR/presto_candidate_lists"

if [ ! -f "$FINAL_CSV" ]; then log_error "Not found: $FINAL_CSV -- did cross-beam filtering complete?"; fi

mkdir -p "$CAND_SCRATCH_DIR"

# Initialize Single Central Log File in the Filterbank directory
# SINGLE_LOG_FILE="$DATA_PATH/FilData/accel_search_summary.log"
SINGLE_LOG_FILE="$DATA_PATH/FilData/accel_search_summary.log"
if [ ! -f "$SINGLE_LOG_FILE" ]; then
    {
        echo "===================================================================================================="
        echo " ACCELSEARCH PIPELINE CONSOLIDATED AUDIT LOG"
        echo " Initialized: $(date)"
        echo "===================================================================================================="
        printf "%-20s | %-8s | %-11s | %-18s | %-8s | %s\n" "TIMESTAMP" "BEAM" "STATUS" "DM / FREQ (Hz)" "PERCENT" "DETAILS / REASON"
        echo "----------------------------------------------------------------------------------------------------"
    } >> "$SINGLE_LOG_FILE"
fi

BEAM_LIST=$(python3 -c "
import pandas as pd
import os
import sys

df = pd.read_csv('$FINAL_CSV')
outdir = '$CAND_SCRATCH_DIR'
os.makedirs(outdir, exist_ok=True)

df.columns = [c.strip().lower() for c in df.columns]
beam_col = 'beam' if 'beam' in df.columns else df.columns[0]
dm_col = 'dm' if 'dm' in df.columns else [c for c in df.columns if 'dm' in c][0]
freq_col = 'frequency_hz' if 'frequency_hz' in df.columns else [c for c in df.columns if 'freq' in c][0]

beam_filter_raw = '$BEAM_FILTER'.replace(',', ' ').split()
beam_filter = set(int(b) for b in beam_filter_raw) if beam_filter_raw else None

total_cands = 0
beams = sorted(df[beam_col].unique())

if beam_filter is not None:
    missing = beam_filter - set(int(b) for b in beams)
    for m in sorted(missing):
        print(f'[prep] WARNING: requested beam {m} (-b) has no candidates in final CSV -- skipping.', file=sys.stderr)
    beams = [b for b in beams if int(b) in beam_filter]

for b in beams:
    sub = df[df[beam_col] == b].copy()
    total_cands += len(sub)

    cand_file = os.path.join(outdir, f'BM{int(b)}_candidates.txt')
    with open(cand_file, 'w') as f:
        for _, row in sub.iterrows():
            try:
                d_val = float(row[dm_col])
                f_val = float(row[freq_col])
                if f_val > 0:
                    f.write(f\"{d_val:.4f} {f_val:.6f}\n\")
            except (ValueError, TypeError):
                continue
    print(int(b))

print(f'[prep] Extracted {total_cands} candidate(s) across {len(beams)} beam(s).', file=sys.stderr)
")

if [ -z "$BEAM_LIST" ]; then
    log_warn "No candidates found in $FINAL_CSV -- nothing to do."
    exit 0
fi

NUM_BEAMS=$(echo "$BEAM_LIST" | wc -l)
NUM_CANDIDATES=$(wc -l < "$FINAL_CSV")
NUM_CANDIDATES=$((NUM_CANDIDATES - 1))

log_info "============================================================"
log_info "PRESTO CANDIDATE PIPELINE (chained per-beam edition)"
log_info "============================================================"
log_info "Beams with candidates: $NUM_BEAMS"
log_info "Total candidates: $NUM_CANDIDATES"
log_info "Folding Engine: ${FOLDER_ENGINE^^}"
log_info "Compute nodes: $NUM_NODES (${COMPUTE_NODES[*]})"
log_info "CPUs per process: $NCPUS"
log_info "Harmonic dedup tolerance: $HARMONIC_TOL"
log_info "Inter-DM harmonic elimination: ${INTER_DM_ELIM^^}"
log_info "Central Log File: $SINGLE_LOG_FILE"
log_info "PulsarX Template Path: $PULSARX_TEMPLATE"

resolve_fil_file() {
    local BEAM="$1"
    local CANDIDATE=""

    CANDIDATE=$(find "$DATA_PATH/FilData" -maxdepth 2 -type f \( -iname "*.fil" -o -iname "*.FIL" \) 2>/dev/null | \
        grep -E "/BM${BEAM}(\_.*)?\.[fF][iI][lL]$" | head -n 1)

    if [ -n "$CANDIDATE" ]; then
        printf '%s\n' "$CANDIDATE"
        return 0
    fi

    local BEAM_DIR
    BEAM_DIR=$(find "$DATA_PATH/FilData" -maxdepth 1 -type d 2>/dev/null | \
        grep -E "/BM${BEAM}(\_.*)?$" | head -n 1)

    if [ -n "$BEAM_DIR" ]; then
        CANDIDATE=$(find "$BEAM_DIR" -maxdepth 1 -type f \( -iname "*.fil" -o -iname "*.FIL" \) 2>/dev/null | head -n 1)
        if [ -n "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    fi

    return 1
}

process_one_beam() {
    local BEAM="$1"
    local NODE="$2"
    local CAND_FILE="$CAND_SCRATCH_DIR/BM${BEAM}_candidates.txt"

    local FIL_FILE_PATH=""
    if ! FIL_FILE_PATH=$(resolve_fil_file "$BEAM"); then
        log_warn "[BM${BEAM}] Could not find a matching beam file -- skipping this beam entirely."
        return 1
    fi

    local FIL_DIR
    FIL_DIR=$(dirname "$FIL_FILE_PATH")
    local FULL_FILENAME
    FULL_FILENAME=$(basename "$FIL_FILE_PATH")
    local BASENAME="${FULL_FILENAME%.*}"
    local NUM_BEAM_CANDS
    NUM_BEAM_CANDS=$(wc -l < "$CAND_FILE")

    RAW_LOW=$(awk 'NR==1{min=$1} {if($1<min) min=$1} END{printf "%.4f", min}' "$CAND_FILE")
    RAW_HIGH=$(awk 'NR==1{max=$1} {if($1>max) max=$1} END{printf "%.4f", max}' "$CAND_FILE")

    LOW_DM=$(awk -v lo="$RAW_LOW" -v s="$DM_STEP" 'BEGIN{ v=lo; if(v<0) v=0; printf "%.2f", int(v/s)*s }')
    HIGH_DM=$(awk -v hi="$RAW_HIGH" 'BEGIN{printf "%.2f", hi}')
    NUMDM=$(awk -v lo="$LOW_DM" -v hi="$HIGH_DM" -v s="$DM_STEP" 'BEGIN{ n=(hi-lo)/s; printf "%d", (n==int(n)?n:int(n)+1)+1 }')

    log_info "[BM${BEAM}] $NUM_BEAM_CANDS candidate(s). File: $FULL_FILENAME -> $NODE"

    ssh "$NODE" bash -s -- \
        "$(printf '%q' "$FIL_FILE_PATH")" \
        "$(printf '%q' "$FIL_DIR")" \
        "$(printf '%q' "$BASENAME")" \
        "$(printf '%q' "$LOW_DM")" \
        "$(printf '%q' "$NUMDM")" \
        "$(printf '%q' "$DM_STEP")" \
        "$(printf '%q' "$NCPUS")" \
        "$(printf '%q' "$RESUME")" \
        "$(printf '%q' "$ZMAX")" \
        "$(printf '%q' "$FOLD_INPUT_FLAG")" \
        "$(printf '%q' "$CAND_FILE")" \
        "$(printf '%q' "${ACCEL_PCT_ARR[*]}")" \
        "$(printf '%q' "$SIGMA_THRESH")" \
        "$(printf '%q' "$FOLDER_ENGINE")" \
        "$(printf '%q' "$PULSARX_TEMPLATE")" \
        "$(printf '%q' "$SCRIPT_DIR")" \
        "$(printf '%q' "$BEAM")" \
        "$(printf '%q' "$SINGLE_LOG_FILE")" \
        "$(printf '%q' "$HARMONIC_TOL")" \
        "$(printf '%q' "$INTER_DM_ELIM")" <<'EOF'
        REMOTE_FIL_FILE_PATH="$1"
        REMOTE_FIL_DIR="$2"
        REMOTE_BASENAME="$3"
        REMOTE_LOW_DM="$4"
        REMOTE_NUMDM="$5"
        REMOTE_DM_STEP="$6"
        REMOTE_NCPUS="$7"
        REMOTE_RESUME="$8"
        REMOTE_ZMAX="$9"
        REMOTE_FOLD_INPUT_FLAG="${10}"
        REMOTE_CAND_FILE="${11}"
        REMOTE_PCT_LIST="${12}"
        REMOTE_SIGMA_THRESH="${13}"
        REMOTE_FOLDER_ENGINE="${14}"
        REMOTE_PULSARX_TEMPLATE="${15}"
        REMOTE_SCRIPT_DIR="${16}"
        REMOTE_BEAM="${17}"
        REMOTE_LOG_FILE="${18}"
        REMOTE_HARMONIC_TOL="${19}"
        REMOTE_INTER_DM_ELIM="${20}"

        cd "$REMOTE_FIL_DIR" || exit 2

        if [ -f /lustre_archive/apps/tdsoft/env.sh ]; then
            source /lustre_archive/apps/tdsoft/env.sh
        fi

        export PGPLOT_DEV="/ps"
        export PGPLOT_TYPE="PS"

        # 1. PREPSUBBAND
        EXISTING_COUNT=$(find . -maxdepth 1 -type f -name "${REMOTE_BASENAME}_DM*.dat" -size +0c 2>/dev/null | wc -l)
        if [ "$REMOTE_RESUME" -eq 1 ] && [ "$EXISTING_COUNT" -ge "$REMOTE_NUMDM" ]; then
            echo "[REMOTE INFO] Found $EXISTING_COUNT existing DM .dat file(s) -- skipping prepsubband."
        else
            prepsubband -nobary -ncpus "$REMOTE_NCPUS" -lodm "$REMOTE_LOW_DM" -numdms "$REMOTE_NUMDM" -dmstep "$REMOTE_DM_STEP" "$REMOTE_FIL_FILE_PATH" -o "$REMOTE_BASENAME"
            [ $? -ne 0 ] && exit 3
        fi

        # ----------------------------------------------------------------------
        # PHASE 1: ACCELERATION SEARCH FOR ALL CANDIDATES (ALL DM TRIALS)
        # ----------------------------------------------------------------------
        BEAM_CAND_FAILED=0
        declare -a FOLD_QUEUE=()

        while IFS=' ' read -r DM FREQ || [ -n "$DM" ]; do
            DM=$(echo "$DM" | tr -d '\r' | xargs)
            FREQ=$(echo "$FREQ" | tr -d '\r' | xargs)
            [ -z "$DM" ] || [ -z "$FREQ" ] && continue

            MATCHED_DAT=$(find . -maxdepth 1 -type f -name "${REMOTE_BASENAME}_DM*.dat" -size +0c 2>/dev/null | awk -v want="$DM" '
                {
                    fname = $0
                    n = split(fname, a, "_DM")
                    dmpart = a[n]
                    sub(/\.dat$/, "", dmpart)
                    diff = dmpart - want
                    if (diff < 0) diff = -diff
                    if (!found || diff < bestdiff) { bestdiff = diff; best = fname; found = 1 }
                }
                END { if (found) print best }
            ')

            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

            if [ -z "$MATCHED_DAT" ]; then
                BEAM_CAND_FAILED=$((BEAM_CAND_FAILED + 1))
                printf "%-20s | BM%-6s | %-11s | DM:%-6s / %-7s | %-8s | %s\n" \
                    "$TIMESTAMP" "$REMOTE_BEAM" "NOT_CREATED" "$DM" "$FREQ" "N/A" \
                    "Reason: No matching .dat file found for requested DM" >> "$REMOTE_LOG_FILE"
                continue
            fi

            MATCHED_BASENAME=$(basename "$MATCHED_DAT" .dat)
            REMOTE_DAT_FILE="${MATCHED_BASENAME}.dat"
            REMOTE_ACCEL_TXT="${MATCHED_BASENAME}_ACCEL_${REMOTE_ZMAX}"

            FOUND=0
            SUCCESS_PCT=""
            ATTEMPT_REASONS=""

            for PCT in $REMOTE_PCT_LIST; do
                FLO=$(awk -v f="$FREQ" -v t="$PCT" 'BEGIN{v=f*(1-t/100); printf "%.6f", (v<0?0:v)}')
                FHI=$(awk -v f="$FREQ" -v t="$PCT" 'BEGIN{printf "%.6f", f*(1+t/100)}')

                if accelsearch -ncpus "$REMOTE_NCPUS" -flo "$FLO" -fhi "$FHI" -zmax "$REMOTE_ZMAX" "$REMOTE_DAT_FILE"; then
                    if [ -s "${REMOTE_ACCEL_TXT}.cand" ]; then
                        FOUND=1
                        SUCCESS_PCT="${PCT}%"
                        break
                    else
                        ATTEMPT_REASONS="${ATTEMPT_REASONS}[${PCT}%: empty .cand file] "
                    fi
                else
                    ATTEMPT_REASONS="${ATTEMPT_REASONS}[${PCT}%: accelsearch non-zero exit] "
                fi
            done

            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

            if [ "$FOUND" -eq 1 ]; then
                printf "%-20s | BM%-6s | %-11s | DM:%-6s / %-7s | %-8s | %s\n" \
                    "$TIMESTAMP" "$REMOTE_BEAM" "CREATED" "$DM" "$FREQ" "$SUCCESS_PCT" \
                    "File: ${REMOTE_ACCEL_TXT}.cand" >> "$REMOTE_LOG_FILE"

                # PREVENT OVERWRITE: Make a frequency-unique archive copy of search results
                UNIQUE_ACCEL_BASE="${REMOTE_FIL_DIR}/${MATCHED_BASENAME}_Freq_${FREQ}_ACCEL_${REMOTE_ZMAX}"
                [ -f "${REMOTE_ACCEL_TXT}" ] && cp "${REMOTE_ACCEL_TXT}" "${UNIQUE_ACCEL_BASE}"
                [ -f "${REMOTE_ACCEL_TXT}.cand" ] && cp "${REMOTE_ACCEL_TXT}.cand" "${UNIQUE_ACCEL_BASE}.cand"

                if [ "$REMOTE_FOLD_INPUT_FLAG" -eq 1 ]; then
                    REMOTE_FOLD_INPUT="$REMOTE_FIL_DIR/$REMOTE_DAT_FILE"
                else
                    REMOTE_FOLD_INPUT="$REMOTE_FIL_FILE_PATH"
                fi

                FOLD_PREFIX="${REMOTE_BASENAME}_Freq_${FREQ}_DM_${DM}_"

                # Queue this DM trial's surviving candidates for the beam-wide reduction stage.
                # Nothing is folded yet -- folding only happens after every DM trial in this
                # beam has been searched and the candidates have been reduced across all DMs.
                FOLD_QUEUE+=("${DM}|${FREQ}|${UNIQUE_ACCEL_BASE}|${FOLD_PREFIX}|${REMOTE_FOLD_INPUT}|${REMOTE_FIL_DIR}/${REMOTE_DAT_FILE}|fil")
            else
                BEAM_CAND_FAILED=$((BEAM_CAND_FAILED + 1))
                printf "%-20s | BM%-6s | %-11s | DM:%-6s / %-7s | %-8s | %s\n" \
                    "$TIMESTAMP" "$REMOTE_BEAM" "NOT_CREATED" "$DM" "$FREQ" "ALL_FAILED" \
                    "File: ${REMOTE_ACCEL_TXT}.cand | Reason: ${ATTEMPT_REASONS}" >> "$REMOTE_LOG_FILE"
            fi
        done < "$REMOTE_CAND_FILE"

        # ----------------------------------------------------------------------
        # PHASE 2: BEAM-WIDE CANDIDATE REDUCTION (INTRA + INTER-DM HARMONICS)
        #          THEN FOLDING OF ONLY THE SURVIVING CANDIDATES
        # ----------------------------------------------------------------------
        NUM_QUEUED=${#FOLD_QUEUE[@]}
        echo "[REMOTE INFO] Search phase completed for all DM trials. ${NUM_QUEUED} candidate(s) queued for reduction."


        if [ "$NUM_QUEUED" -gt 0 ]; then
            REMOTE_MANIFEST="${REMOTE_FIL_DIR}/BM${REMOTE_BEAM}_fold_manifest.txt"
            : > "$REMOTE_MANIFEST"
            for ITEM in "${FOLD_QUEUE[@]}"; do
                echo "$ITEM" >> "$REMOTE_MANIFEST"
            done

            # A single call handles ALL DM trials for this beam together, so harmonically
            # related candidates found at different DMs collapse to one (highest-sigma)
            # candidate before folding -- shrinking the folding parameter space accordingly.
            # This also writes BM<beam>_candidate_decisions.log recording exactly which
            # candidates were kept and which were eliminated (and matched against what),
            # so an expected pulsar's fate can be looked up and the reduction parameters
            # (--tol / --harmonic-ratios) tuned if it was wrongly collapsed.
            python3 "${REMOTE_SCRIPT_DIR}/accelcand_harmonic_elimination.py" \
                --manifest "$REMOTE_MANIFEST" \
                --sigma "$REMOTE_SIGMA_THRESH" \
                --folder "$REMOTE_FOLDER_ENGINE" \
                --fil "$REMOTE_FIL_FILE_PATH" \
                --cores "$REMOTE_NCPUS" \
                --outdir "$REMOTE_FIL_DIR" \
                --templates "$REMOTE_PULSARX_TEMPLATE" \
                --log-file "$REMOTE_LOG_FILE" \
                --beam "$REMOTE_BEAM" \
                --tol "$REMOTE_HARMONIC_TOL" \
                --inter-dm-elim "$REMOTE_INTER_DM_ELIM"
        fi

        [ "$BEAM_CAND_FAILED" -gt 0 ] && exit 4
        exit 0
EOF
    return $?
}

log_info "============================================================"
log_info "DISPATCHING BEAM PIPELINES"
log_info "============================================================"

declare -A NODE_ACTIVE_PIDS=()
for NODE in "${COMPUTE_NODES[@]}"; do NODE_ACTIVE_PIDS["$NODE"]=""; done

BEAM_IDX=0
while read -r BEAM; do
    [ -z "$BEAM" ] && continue
    selected_node=""
    while [ -z "$selected_node" ]; do
        for NODE in "${COMPUTE_NODES[@]}"; do
            active_pids=""
            active_count=0
            for pid in ${NODE_ACTIVE_PIDS["$NODE"]}; do
                if kill -0 "$pid" 2>/dev/null; then
                    active_pids+="$pid "
                    active_count=$((active_count + 1))
                fi
            done
            NODE_ACTIVE_PIDS["$NODE"]="$active_pids"
            if [ "$active_count" -lt "$JOBS_PER_NODE" ]; then
                selected_node="$NODE"
                break
            fi
        done
        [ -z "$selected_node" ] && sleep 1
    done

    ((BEAM_IDX++))
    log_info "Dispatching beam $BEAM_IDX/$NUM_BEAMS: BM${BEAM} -> $selected_node"
    process_one_beam "$BEAM" "$selected_node" &
    pid=$!
    NODE_ACTIVE_PIDS["$selected_node"]+="$pid "
done <<< "$BEAM_LIST"

log_info "Waiting for all beam pipelines to finish..."
wait

log_info "============================================================"
log_info "ORGANIZING OUTPUT FILES"
log_info "============================================================"

DEDISP_DIR="$SUMMARY_DIR/dedispersed_files"
SEARCH_DIR="$SUMMARY_DIR/presto_search"
FOLD_PLOTS_DIR="$SUMMARY_DIR/folded_plots"
REDUCTION_LOG_DIR="$SUMMARY_DIR/reduction_logs"

mkdir -p "$DEDISP_DIR" "$SEARCH_DIR" "$FOLD_PLOTS_DIR" "$REDUCTION_LOG_DIR"

log_info "Moving dedispersed files..."
find "$DATA_PATH/FilData" -type f -iname "*_DM*.dat" -exec mv {} "$DEDISP_DIR/" \;
find "$DATA_PATH/FilData" -type f -iname "*_DM*.inf" -exec mv {} "$DEDISP_DIR/" \;

log_info "Moving folded plots (PRESTO & PulsarX)..."
find "$DATA_PATH/FilData" -type f \( \
    -iname "*.pfd" -o -iname "*.pfd.ps" -o -iname "*.pfd.bestprof" -o -iname "*.pfd.polycos" \
    -o -iname "*.ar" -o -iname "*.ar.png" -o -iname "*.cands" -o -iname "*.ar.pdf" -o -iname "*.png" -o -iname "*.pdf" \
\) -exec mv {} "$FOLD_PLOTS_DIR/" \;

log_info "Moving ACCEL search outputs..."
find "$DATA_PATH/FilData" -type f -iname "*_ACCEL_*" -exec mv {} "$SEARCH_DIR/" \;

log_info "Moving candidate reduction manifests and KEPT/ELIMINATED decision logs..."
find "$DATA_PATH/FilData" -type f -iname "*_fold_manifest.txt" -exec mv {} "$REDUCTION_LOG_DIR/" \;
find "$DATA_PATH/FilData" -type f -iname "*_candidate_decisions.log" -exec mv {} "$REDUCTION_LOG_DIR/" \;

log_success "============================================================"
log_success "PIPELINE COMPLETE"
log_success "Log saved to: $SINGLE_LOG_FILE"
log_success "Per-beam KEPT/ELIMINATED decision logs: $REDUCTION_LOG_DIR"
log_success "============================================================"
