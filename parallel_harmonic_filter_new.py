#!/usr/bin/env python3
import pandas as pd
import numpy as np
import glob
import os
import argparse
from multiprocessing import Pool

def process_single_dm(args_tuple):
    """Filter a single DM file using vectorized NumPy binary searches."""
    file_path, output_dir, rel_tol, factors, debug = args_tuple
    try:
        df = pd.read_csv(file_path)
        if df.empty:
            return None

        # 1. Sort by SNR descending natively
        df = df.sort_values(by='sigma', ascending=False).reset_index(drop=True)

        # 2. Extract raw NumPy arrays for pure C-speed processing
        freqs = df['frequency_hz'].to_numpy()

        num_candidates = len(df)
        keep_mask = np.ones(num_candidates, dtype=bool)
        debug_log = []

        # 3. Streamlined Vectorized Sifting
        for i in range(num_candidates):
            if not keep_mask[i]:
                continue

            current_freq = freqs[i]

            for factor in factors:
                target_freq = current_freq * factor

                # Define the tolerance window boundaries for this harmonic target
                lower_bound = target_freq * (1.0 - rel_tol)
                upper_bound = target_freq * (1.0 + rel_tol)

                # Vectorized search: find all elements falling inside our tolerance window
                # We only check elements past index 'i' (higher index = lower SNR)
                matched_indices = np.where(
                    keep_mask[i+1:] &
                    (freqs[i+1:] >= lower_bound) &
                    (freqs[i+1:] <= upper_bound)
                )[0] + (i + 1)

                if len(matched_indices) > 0:
                    keep_mask[matched_indices] = False
                    if debug:
                        for idx in matched_indices:
                            debug_log.append(
                                f"MATCH: Main {current_freq:.6f}Hz -> Harmonic {freqs[idx]:.6f}Hz via Factor {factor}"
                            )

        # 4. Finalizing DataFrames
        # Inject standard required tracking variables directly into the filtered DataFrame
        filtered_df = df.iloc[keep_mask].copy()

        out_name = os.path.join(output_dir, os.path.basename(file_path))
        filtered_df.to_csv(out_name, index=False, float_format='%.6f')

        # Generate optional diagnostic text dumps
        if debug and debug_log:
            debug_dir = os.path.join(output_dir, "debug_harmonics")
            os.makedirs(debug_dir, exist_ok=True)
            with open(os.path.join(debug_dir, os.path.basename(file_path) + ".debug"), 'w') as f:
                f.write("\n".join(debug_log))

        return f"Processed {os.path.basename(file_path)}: {num_candidates} -> {len(filtered_df)}"

    except Exception as e:
        return f"Error processing {os.path.basename(file_path)}: {e}"

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Parallel vectorized harmonic filtering (Freq + Zeroed Pdot Layout)")

    parser.add_argument("--input_dir", type=str, required=True, help="Directory containing the split DM CSVs")
    parser.add_argument("--output_dir", type=str, help="Directory to save filtered results")
    parser.add_argument("--f_tol_pct", type=float, default=0.1, help="Frequency tolerance percentage window")
    parser.add_argument("--harmonics", type=float, nargs='+',
                        default=[0.1, 0.111, 0.125, 0.142, 0.166, 0.2, 0.25, 0.333, 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    parser.add_argument("--threads", type=int, default=None, help="Number of multi-processing workers")
    parser.add_argument("--debug", action="store_true", help="Output execution text diagnostics")

    args = parser.parse_args()

    rel_tol = args.f_tol_pct / 100.0
    input_path = args.input_dir.rstrip("/")
    output_path = args.output_dir if args.output_dir else os.path.join(os.path.dirname(input_path), "dm_filtered_results")
    os.makedirs(output_path, exist_ok=True)

    file_list = glob.glob(os.path.join(input_path, "*.csv"))
    pool_args = [(f, output_path, rel_tol, args.harmonics, args.debug) for f in file_list]

    print("Starting parallel vectorized sifting (Optimized Engine)...")
    with Pool(processes=args.threads) as pool:
        results = pool.map(process_single_dm, pool_args)

    for res in results:
        if res:
            print(res)