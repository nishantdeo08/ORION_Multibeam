#!/usr/bin/env python3
import glob
import os
import pandas as pd
import numpy as np
import argparse

def process_harmonics():
    parser = argparse.ArgumentParser(description="Optimized Harmonic Synchronizer (SNR/Period Layout)")
    parser.add_argument("--input_dir", type=str, required=True, help="Directory containing individual split DM CSVs")
    parser.add_argument("--output_dir", type=str, required=True, help="Directory to save synchronized results")
    parser.add_argument("--f_tol_pct", type=float, default=0.1, help="Frequency tolerance percentage window")
    parser.add_argument("--harmonics", type=float, nargs='+',
                        default=[0.1, 0.111, 0.125, 0.142, 0.166, 0.2, 0.25, 0.333, 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    parser.add_argument("--harmonic_matching", action="store_true",
                        help="Treat frequency ratios such as f and 2f as harmonic matches. Off by default.")
    parser.add_argument("--z_value_matching", action="store_true",
                        help="Require exact z-bin matching for candidate pairs; when harmonic matching is enabled, "
                             "z-values are scaled by the same factor. Off by default.")

    # Defaults adjusted to match your new upstream format
    parser.add_argument("--sigma_col", type=str, default="sigma")
    parser.add_argument("--freq_col", type=str, default="frequency_hz")
    parser.add_argument("--harmonic_col", type=str, default="numharm")
    parser.add_argument("--dm_col", type=str, default="dm",
                        help="Name of the DM column in input CSVs (default: dm)")
    parser.add_argument("--dm_tol_abs", type=float, default=2.0,
                        help="Absolute DM tolerance required for a cross-DM harmonic match (default: 0.5)")
    # NEW: same debug flag as parallel_harmonic_filter_new.py, adapted to this script's
    # cross-DM grouping logic. Logs every match found during grouping -- which frequency
    # matched which, via which harmonic factor, and which DM file each came from -- so
    # you can trace how a signal propagated across DM trials into one synchronized group.
    parser.add_argument("--debug", action="store_true", help="Output execution text diagnostics")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    rel_tol = args.f_tol_pct / 100.0
    debug_log = []   # NEW: collects one line per match found, written out at the end if --debug is set

    # 1. Load data
    files = glob.glob(os.path.join(args.input_dir, "*.csv"))
    if not files:
        print("No CSV files found in the specified input directory.")
        return

    master_df = pd.concat([pd.read_csv(f).assign(source_file=os.path.basename(f)) for f in files], ignore_index=True)
    master_df['group_id'] = -1

    # Sort by SNR DESC (ensures the cluster leader is always the highest SNR candidate)
    master_df = master_df.sort_values(by=args.sigma_col, ascending=False).reset_index(drop=True)

    # --- TRANSLATION LAYER ---
    # Compute temporary frequencies to drive the optimized binary searching algorithm
    master_df['frequency_hz'] = 1.0 * master_df[args.freq_col]
    master_df['dm'] = 1.0 * master_df[args.dm_col]

    # Pre-calculate numpy arrays for lightning-fast vectorized access
    freqs = master_df['frequency_hz'].values
    dms = master_df['dm'].values
    group_ids = np.full(len(master_df), -1, dtype=int)
    source_files = master_df['source_file'].values   # NEW: only pulled out for debug logging below
    if 'z' in master_df.columns:
        z_vals = master_df['z'].to_numpy(dtype=float)
        has_z_column = True
    else:
        z_vals = np.full(len(master_df), np.nan, dtype=float)
        has_z_column = False

    # Create secondary index sorted by frequency for windowed binary searching
    f_sort_idx = np.argsort(freqs)
    sorted_freqs = freqs[f_sort_idx]

    # 2. Optimized Grouping logic
    group_counter = 0
    print(f"Grouping {len(master_df)} candidates across files...")

    for i in range(len(master_df)):
        if group_ids[i] != -1:
            continue

        group_ids[i] = group_counter
        base_f = freqs[i]

        if args.debug:   # NEW: record this group's leader before checking for matches
            debug_log.append(
                f"GROUP {group_counter} LEADER: {base_f:.6f}Hz (source_file={source_files[i]})"
            )

        harmonic_factors = args.harmonics if args.harmonic_matching else [1.0]

        # Check all harmonic multiples
        for n in harmonic_factors:
            target_f = base_f * n
            target_z = z_vals[i] * n if (has_z_column and args.z_value_matching) else None

            # Define frequency bounding box window
            f_min = target_f * (1 - rel_tol)
            f_max = target_f * (1 + rel_tol)

            # High-speed binary search to find nearby candidate indexes in the sorted array
            idx_start = np.searchsorted(sorted_freqs, f_min, side='left')
            idx_end = np.searchsorted(sorted_freqs, f_max, side='right')

            if idx_start < idx_end:
                # Resolve internal references back to master_df indexes
                candidate_indices = f_sort_idx[idx_start:idx_end]

                # Filter for candidates that haven't been assigned a group yet
                mask = group_ids[candidate_indices] == -1
                candidate_indices = candidate_indices[mask]

                if len(candidate_indices) > 0:
                    # Apply DM tolerance before grouping as a necessary physics condition
                    dm_mask = np.abs(dms[candidate_indices] - dms[i]) <= args.dm_tol_abs
                    candidate_candidates = candidate_indices[dm_mask]

                    if has_z_column and args.z_value_matching:
                        z_mask = np.isfinite(z_vals[candidate_candidates]) & (z_vals[candidate_candidates] == target_z)
                        potential_matches = candidate_candidates[z_mask]
                    else:
                        potential_matches = candidate_candidates

                    if len(potential_matches) > 0:
                        group_ids[potential_matches] = group_counter

                        if args.debug:   # NEW: one line per matched candidate, same style as parallel_harmonic_filter_new.py
                            for idx in potential_matches:
                                debug_log.append(
                                    f"MATCH: Main {base_f:.6f}Hz -> Harmonic {freqs[idx]:.6f}Hz via Factor {n} "
                                    f"(dm={dms[idx]:.3f}, source_file={source_files[idx]}, group {group_counter})"
                                )

        group_counter += 1

    master_df['group_id'] = group_ids

    # 3. Synchronize periodic properties across clustered signals
    # Set the matching group's active frequency to match the highest SNR lead profile
    leads_freq = master_df.groupby('group_id')[args.freq_col].transform('first')
    master_df[args.freq_col] = leads_freq

    # 4. Save results
    # Clean up transient calculation headers so the schema output matches your template constraints
    # cols_to_drop_final = ['source_file', 'group_id', 'frequency_hz']
    cols_to_drop_final = ['source_file', 'group_id']

    consolidated_path = os.path.join(args.output_dir, "final_pulsar_candidate.csv")

    # Save the master deduplicated summary file
    master_df.drop_duplicates('group_id').drop(columns=cols_to_drop_final, errors='ignore').to_csv(consolidated_path, index=False)

    for f_name, group in master_df.groupby('source_file'):
        out_path = os.path.join(args.output_dir, f_name)
        #cleaned_group = group.drop(columns=['source_file', 'group_id', 'frequency_hz'], errors='ignore')
        cleaned_group = group.drop(columns=['source_file', 'group_id'], errors='ignore')
        cleaned_group.to_csv(out_path, index=False, float_format='%.6f')

    # NEW: write the collected debug log, same convention as parallel_harmonic_filter_new.py
    # (a debug_harmonics/ subdirectory inside output_dir), just one combined file here since
    # this script processes all DM files together rather than one-at-a-time per process.
    if args.debug and debug_log:
        debug_dir = os.path.join(args.output_dir, "debug_harmonics")
        os.makedirs(debug_dir, exist_ok=True)
        debug_path = os.path.join(debug_dir, "process_harmonics.debug")
        with open(debug_path, 'w') as f:
            f.write("\n".join(debug_log))
        print(f"Debug log written to: {debug_path}")

    print(f"Deduplication complete. Outputs exported to: {args.output_dir}")

if __name__ == "__main__":
    process_harmonics()
