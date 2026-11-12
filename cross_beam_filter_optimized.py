import pandas as pd                       # for reading/writing candidate CSVs and beam position table
import numpy as np                        # for vectorized frequency/harmonic matching and coordinate math
import glob                                # to find every beam's final_pulsar_candidate.csv
import os                                  # path handling
import re                                  # to pull the beam index out of a "BM7" style folder name
import argparse                            # command-line interface
from sklearn.cluster import DBSCAN         # spatial clustering of beam pointings (RA/DEC)
from sklearn.neighbors import NearestNeighbors   # used only to auto-suggest a DBSCAN eps if none is given

ARCSEC_PER_RAD = 206264.806247   # conversion factor: radians -> arcseconds, used for human-readable eps reporting


# ---------------------------------------------------------------------------
# STEP 1: Load the beam layout (RA/DEC per beam index) and spatially cluster
# beams with DBSCAN, so we can later ask "are these two beams neighbors?"
# ---------------------------------------------------------------------------
def load_beam_groups(beam_pos_file, eps_arcsec, min_samples):
    """Read the RA/DEC/BM-Idx table and return {beam_idx: spatial_group_label}."""
    beams = pd.read_csv(beam_pos_file, sep=r"\s+")
    beams.columns = [c.strip() for c in beams.columns]   # strip stray whitespace from header names

    idx_col = [c for c in beams.columns if "bm" in c.lower()][0]
    beams = beams.rename(columns={idx_col: "beam"})
    beams["beam"] = beams["beam"].astype(int)

    dec_rad = beams["DEC"].to_numpy()
    ra_rad = beams["RA"].to_numpy()
    x_arcsec = ra_rad * np.cos(dec_rad) * ARCSEC_PER_RAD
    y_arcsec = dec_rad * ARCSEC_PER_RAD
    coords = np.column_stack([x_arcsec, y_arcsec])

    if eps_arcsec is None:
        if len(coords) < 2:
            raise ValueError("Need at least 2 beams in the position file to auto-estimate eps.")
        nn = NearestNeighbors(n_neighbors=2).fit(coords)
        dists, _ = nn.kneighbors(coords)
        nearest_neighbor_dist = dists[:, 1]
        median_spacing = np.median(nearest_neighbor_dist)
        eps_arcsec = 1.5 * median_spacing
        print(f"[beam-groups] Auto-estimated median beam spacing: {median_spacing:.2f} arcsec")
        print(f"[beam-groups] Auto-estimated eps (1.5x spacing): {eps_arcsec:.2f} arcsec "
              f"-- override with --eps_arcsec if this looks wrong for your layout.")

    db = DBSCAN(eps=eps_arcsec, min_samples=min_samples).fit(coords)
    beams["beam_group"] = db.labels_

    n_groups = len(set(db.labels_) - {-1})
    n_noise = int(np.sum(db.labels_ == -1))
    print(f"[beam-groups] Found {n_groups} neighbor group(s) among {len(beams)} beams "
          f"({n_noise} isolated beam(s) with no close neighbor).")

    return dict(zip(beams["beam"], beams["beam_group"]))


# ---------------------------------------------------------------------------
# STEP 2: Load every beam's final_pulsar_candidate.csv into one combined table,
# tagging each row with which beam it came from.
# ---------------------------------------------------------------------------
def load_all_candidates(data_dir, candidate_filename):
    pattern = os.path.join(data_dir, "BM*", "output", "dm_synchronized_results", candidate_filename)
    files = sorted(glob.glob(pattern))
    if not files:
        raise FileNotFoundError(f"No candidate files found matching: {pattern}")

    frames = []
    for f in files:
        m = re.search(r"BM(\d+)", f)
        if not m:
            print(f"[candidates] WARNING: couldn't parse a beam index out of {f}, skipping.")
            continue
        beam_idx = int(m.group(1))
        df = pd.read_csv(f)
        if df.empty:
            continue
        df["beam"] = beam_idx
        frames.append(df)

    if not frames:
        raise ValueError("All candidate files were empty -- nothing to cross-match.")

    combined = pd.concat(frames, ignore_index=True)
    print(f"[candidates] Loaded {len(combined)} total candidates from {len(frames)} beam(s).")
    return combined


# ---------------------------------------------------------------------------
# Small disjoint-set (union-find) helper: lets us merge candidates into harmonic
# "clusters" incrementally, without needing to know cluster membership up front.
# ---------------------------------------------------------------------------
class UnionFind:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, i):
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, i, j):
        ri, rj = self.find(i), self.find(j)
        if ri != rj:
            self.parent[ri] = rj


# ---------------------------------------------------------------------------
# STEP 3: Cross-beam harmonic clustering.
# This mirrors the tolerance-window matching from parallel_harmonic_filter_new.py,
# but instead of immediately discarding lower-significance matches, it UNIONS
# matched candidates into the same cluster -- because here we need to know which
# beams a signal appeared in before deciding what to do with it.
# ---------------------------------------------------------------------------
def build_harmonic_clusters(
    df,
    f_tol_pct,
    harmonics,
    dm_tol_abs,
    use_harmonic_matching=False,
    use_z_matching=False,
    debug=False,
):
    rel_tol = f_tol_pct / 100.0
    order = df["sigma"].to_numpy().argsort()[::-1]
    freqs = df["frequency_hz"].to_numpy()
    dms = df["dm"].to_numpy()
    beams = df["beam"].to_numpy()
    n = len(df)

    if "z" in df.columns:
        z_vals = df["z"].to_numpy(dtype=float)
        has_z_column = True
    else:
        z_vals = np.full(n, np.nan, dtype=float)
        has_z_column = False

    uf = UnionFind(n)
    assigned = np.zeros(n, dtype=bool)
    debug_log = []
    factors = harmonics if use_harmonic_matching else [1.0]

    # Pre-sort frequencies to allow windowed binary search instead of O(N^2) scanning.
    sorted_idx = np.argsort(freqs)
    sorted_freqs = freqs[sorted_idx]

    for i in order:
        if assigned[i]:
            continue
        assigned[i] = True
        current_freq = freqs[i]
        current_z = z_vals[i] if has_z_column else np.nan

        for factor in factors:
            target_freq = current_freq * factor
            lower_bound = target_freq * (1.0 - rel_tol)
            upper_bound = target_freq * (1.0 + rel_tol)
            target_z = current_z * factor if (has_z_column and use_z_matching) else None

            lo = np.searchsorted(sorted_freqs, lower_bound, side="left")
            hi = np.searchsorted(sorted_freqs, upper_bound, side="right")

            if lo >= hi:
                continue

            candidate_indices = sorted_idx[lo:hi]
            candidate_indices = candidate_indices[candidate_indices != i]

            if candidate_indices.size == 0:
                continue

            dm_mask = np.abs(dms[candidate_indices] - dms[i]) <= dm_tol_abs
            candidate_indices = candidate_indices[dm_mask]

            if has_z_column and use_z_matching:
                z_mask = np.isfinite(z_vals[candidate_indices]) & (z_vals[candidate_indices] == target_z)
                candidate_indices = candidate_indices[z_mask]

            candidate_indices = candidate_indices[~assigned[candidate_indices]]
            for j in candidate_indices:
                uf.union(i, j)
                assigned[j] = True
                if debug:
                    debug_log.append(
                        f"MATCH: Main {current_freq:.6f}Hz (beam {beams[i]}) -> "
                        f"Candidate {freqs[j]:.6f}Hz (beam {beams[j]}) via Factor {factor} "
                        f"(dm diff={abs(dms[i]-dms[j]):.3f})"
                    )

    clusters = {}
    for idx in range(n):
        root = uf.find(idx)
        clusters.setdefault(root, []).append(idx)
    return list(clusters.values()), debug_log


# ---------------------------------------------------------------------------
# STEP 4: Apply the 3 acceptance rules per cluster.
# ---------------------------------------------------------------------------
def apply_beam_rules(df, clusters, beam_groups, keep_random_groups=False):
    keep_rows = []
    rejected_rows = []
    decisions = []

    for cluster_idx, row_indices in enumerate(clusters):
        cluster_df = df.iloc[row_indices]
        beams_involved = sorted(cluster_df["beam"].unique())

        if len(beams_involved) == 1:
            keep_rows.extend(row_indices)
            decisions.append(f"cluster {cluster_idx}: single beam {beams_involved} -> KEPT ALL ({len(row_indices)} rows)")
            continue

        group_labels = set()
        missing_beam = False
        for b in beams_involved:
            if b not in beam_groups:
                missing_beam = True
                break
            group_labels.add(beam_groups[b])

        all_same_real_group = (
            not missing_beam and
            len(group_labels) == 1 and
            -1 not in group_labels
        )

        if all_same_real_group:
            best_row = cluster_df["sigma"].idxmax()
            keep_rows.append(best_row)
            rejected_rows.extend([r for r in row_indices if r != best_row])
            decisions.append(f"cluster {cluster_idx}: beams {beams_involved} (same neighbor group) "
                              f"-> KEPT BEST ONLY (row {best_row}, dropped {len(row_indices)-1})")
        else:
            if keep_random_groups:
                keep_count = 2 if len(row_indices) > 10 else 1
                best_rows = cluster_df.sort_values("sigma", ascending=False).head(keep_count).index.tolist()
                keep_rows.extend(best_rows)
                rejected_rows.extend([r for r in row_indices if r not in best_rows])
                decisions.append(
                    f"cluster {cluster_idx}: beams {beams_involved} (random group) "
                    f"-> KEPT TOP {keep_count} BY SIGMA ({len(best_rows)} rows), dropped {len(row_indices) - len(best_rows)}"
                )
            else:
                rejected_rows.extend(row_indices)
                reason = "beam(s) missing from position file" if missing_beam else "beams not spatially adjacent"
                decisions.append(f"cluster {cluster_idx}: beams {beams_involved} ({reason}) -> REJECTED ALL ({len(row_indices)} rows)")

    return keep_rows, rejected_rows, decisions


def main():
    parser = argparse.ArgumentParser(description="Cross-beam coincidence filtering for PULSCAN candidates")
    parser.add_argument("--data_dir", required=True,
                         help="ORION_output directory containing BM0, BM1, ... subfolders")
    parser.add_argument("--beam_positions", required=True,
                         help="Path to the RA/DEC/BM-Idx beam layout file")
    parser.add_argument("--candidate_filename", default="final_pulsar_candidate.csv",
                         help="Filename to look for inside each BMx/output/dm_synchronized_results/")
    parser.add_argument("--f_tol_pct", type=float, default=0.1,
                         help="Frequency tolerance percentage window for harmonic matching (default: 0.1)")
    parser.add_argument("--harmonics", type=float, nargs="+",
                         default=[0.1, 0.111, 0.125, 0.142, 0.166, 0.2, 0.25, 0.333, 0.5,
                                  1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                         help="Harmonic factors to test when matching candidates across beams")
    parser.add_argument("--harmonic_matching", action="store_true",
                         help="Enable harmonic frequency matching (treat f and 2f, 3f, etc. as matches).")
    parser.add_argument("--z_matching", action="store_true",
                         help="Enable exact z-value matching for candidate pairs; scaled by the harmonic factor when enabled.")
    parser.add_argument("--dm_tol_abs", type=float, default=2.0,
                         help="Absolute DM tolerance (pc/cm^3) required for a cross-beam match to be "
                              "considered the same source. Set very large (e.g. 1e6) to disable this check.")
    parser.add_argument("--eps_arcsec", type=float, default=None,
                         help="DBSCAN eps for beam spatial clustering, in arcsec. "
                              "If omitted, auto-estimated from the beam layout (1.5x median spacing).")
    parser.add_argument("--min_samples", type=int, default=1,
                         help="DBSCAN min_samples for beam spatial clustering (default: 1, so an isolated "
                              "beam still forms its own singleton group rather than being called noise).")
    parser.add_argument("--output_file", required=True,
                         help="Path to write the final cross-beam-filtered candidate CSV")
    parser.add_argument("--rejected_file", default=None,
                         help="Optional: also write rejected candidates here, for diagnostics")
    parser.add_argument("--keep_random_groups", action="store_true",
                         help="If set, retain top candidates from random-beam clusters instead of rejecting them all. "
                              "Keeps the best 2 candidates when the cluster size exceeds 10, otherwise keeps the best 1.")
    debug_group = parser.add_mutually_exclusive_group()
    debug_group.add_argument("--debug", dest="debug", action="store_true",
                             help="Enable detailed harmonic-match and per-cluster decision logs.")
    debug_group.add_argument("--no-debug", dest="debug", action="store_false",
                             help="Disable detailed harmonic-match and per-cluster decision logs.")
    parser.set_defaults(debug=True)
    args = parser.parse_args()

    beam_groups = load_beam_groups(args.beam_positions, args.eps_arcsec, args.min_samples)
    combined = load_all_candidates(args.data_dir, args.candidate_filename)

    if args.harmonic_matching:
        print("[clustering] Harmonic matching enabled for frequency ratios such as f and 2f.")
    else:
        print("[clustering] Harmonic matching disabled; only exact-frequency matches will be used.")

    if args.z_matching:
        print("[clustering] z matching enabled with exact equality (scaled by the harmonic factor when applicable).")
    else:
        print("[clustering] z matching disabled.")

    clusters, harmonic_debug_log = build_harmonic_clusters(
        combined, args.f_tol_pct, args.harmonics, args.dm_tol_abs,
        use_harmonic_matching=args.harmonic_matching,
        use_z_matching=args.z_matching,
        debug=args.debug
    )
    print(f"[clustering] Formed {len(clusters)} harmonic cluster(s) across all beams.")

    keep_rows, rejected_rows, decisions = apply_beam_rules(
        combined, clusters, beam_groups,
        keep_random_groups=args.keep_random_groups
    )

    final_df = combined.loc[sorted(keep_rows)].sort_values("sigma", ascending=False)
    os.makedirs(os.path.dirname(os.path.abspath(args.output_file)), exist_ok=True)
    final_df.to_csv(args.output_file, index=False, float_format="%.6f")
    print(f"[output] Kept {len(final_df)} / {len(combined)} candidates -> {args.output_file}")

    if args.rejected_file:
        rejected_df = combined.loc[sorted(rejected_rows)].sort_values("sigma", ascending=False)
        os.makedirs(os.path.dirname(os.path.abspath(args.rejected_file)), exist_ok=True)
        rejected_df.to_csv(args.rejected_file, index=False, float_format="%.6f")
        print(f"[output] Wrote {len(rejected_df)} rejected candidates -> {args.rejected_file}")

    print("\n[decision log]")
    for line in decisions:
        print("  " + line)

    if args.debug:
        cluster_debug_lines = []
        for cluster_idx, row_indices in enumerate(clusters):
            cluster_df = combined.iloc[row_indices].copy()
            cluster_df = cluster_df.sort_values("sigma", ascending=False)
            selected_rows = [idx for idx in cluster_df.index if idx in keep_rows]

            if selected_rows:
                selected_candidates = []
                for idx in selected_rows:
                    row = cluster_df.loc[idx]
                    selected_candidates.append(
                        f"beam {row.beam}, freq {row.frequency_hz:.6f} Hz, sigma {row.sigma:.2f}"
                    )
                cluster_debug_lines.append(f"=== CLUSTER {cluster_idx} ===")
                cluster_debug_lines.append(
                    "Selected candidate(s) added to final candidates file: " + "; ".join(selected_candidates)
                )
            else:
                cluster_debug_lines.append(f"=== CLUSTER {cluster_idx} ===")
                cluster_debug_lines.append("Selected candidate(s) added to final candidates file: NONE")

            cluster_debug_lines.append("Candidates:")
            for row_idx in cluster_df.index:
                row = cluster_df.loc[row_idx]
                status = "KEEP" if row_idx in keep_rows else "DROP"
                cluster_debug_lines.append(
                    f"  [{status}] beam {row.beam} | freq {row.frequency_hz:.6f} Hz | dm {row.dm:.3f} | sigma {row.sigma:.2f}"
                )
            cluster_debug_lines.append("")

        debug_dir = os.path.join(os.path.dirname(os.path.abspath(args.output_file)), "debug_harmonics")
        os.makedirs(debug_dir, exist_ok=True)
        debug_path = os.path.join(debug_dir, "cross_beam.debug")
        with open(debug_path, "w") as f:
            f.write("=== HARMONIC MATCHES (cross-beam) ===\n")
            f.write("\n".join(harmonic_debug_log))
            f.write("\n\n=== PER-CLUSTER DECISIONS ===\n")
            f.write("\n".join(decisions))
            f.write("\n\n=== PER-CLUSTER CANDIDATE SUMMARY ===\n")
            f.write("\n".join(cluster_debug_lines))
        print(f"[debug] Wrote debug log -> {debug_path}")


if __name__ == "__main__":
    main()
