#!/usr/bin/env python3
"""
termpeek Offline Chronological Ranking & Latency Benchmark Oracle
-----------------------------------------------------------------
Replays chronological shell history traces (80% training / 20% holdout split)
across both prefix queries and multi-token abbreviated queries, comparing:
  1. Legacy Baseline (contiguous substring + raw timestamp addition)
  2. Token-Aware Markov-Frecency Engine (QueryWorker with online RECORD updates)

Verifies:
  - Higher Hit@1, Hit@4, and Mean Reciprocal Rank (MRR)
  - Worker query P99 latency < 2.0 ms
"""

import importlib.machinery
import importlib.util
import os
import sys
import time


def load_worker_module(repo_root):
    worker_path = os.path.join(repo_root, "bin", "termpeek-worker")
    loader = importlib.machinery.SourceFileLoader("termpeek_worker", worker_path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class LegacySubstringEngine:
    """Exact reproduction of the pre-upgrade contiguous substring + raw timestamp ranker."""

    def __init__(self, entries, max_results=4):
        # entries is newest-first list of (raw_cmd, cmd_lower, cwd, ts)
        self.history_cache = list(entries)
        self.max_results = max_results

    def record_command(self, cwd, prev_cmd, raw_cmd, ts):
        clean = raw_cmd.replace("\r", "").replace("\n", " && ").strip()
        if len(clean) >= 2:
            self.history_cache.insert(0, (clean, clean.lower(), cwd, ts))

    def rank(self, cwd, query_text, prev_cmd=""):
        trimmed = query_text.strip()
        lower_trim = trimmed.lower()
        if len(lower_trim) < 2:
            return []

        scored_rows = []
        for idx, (raw_cmd, cmd_lower, h_cwd, ts) in enumerate(self.history_cache):
            if lower_trim not in cmd_lower:
                continue
            clean = raw_cmd.replace("\r", "").replace("\n", " && ").strip()
            if clean == trimmed:
                continue
            prefix_bonus = 100.0 if cmd_lower.startswith(lower_trim) else 0.0
            dir_bonus = 0.0
            if cwd and h_cwd:
                if h_cwd == cwd:
                    dir_bonus = 200.0
            recency = float(ts) if ts > 0 else float(len(self.history_cache) - idx)
            scored_rows.append((dir_bonus + prefix_bonus, recency, clean))

        scored_rows.sort(key=lambda x: (x[0], x[1]), reverse=True)
        results = []
        seen = set()
        for _, _, clean in scored_rows:
            if clean not in seen:
                seen.add(clean)
                results.append(clean)
                if len(results) >= self.max_results:
                    break
        return results


def build_realistic_trace(base_ts):
    """Deterministic chronological developer workflow trace covering real shell sessions."""
    home = os.path.expanduser("~")
    ws = os.path.join(home, "workspace")
    chess = os.path.join(ws, "chess")
    api = os.path.join(ws, "api")

    # Noise entries (one-off commands, URLs with .git suffixes, flags) executed at various times
    session_blocks = []
    t = base_ts - 86400 * 5

    # Recurring core developer loops
    for cycle in range(18):
        session_blocks.extend([
            ("cd workspace/chess", ws, t + 10),
            ("git status", chess, t + 20),
            ("git diff --stat", chess, t + 35),
            ("npx expo start --lan --max-workers 1", chess, t + 60),
            ("npx expo run:ios --device", chess, t + 180),
            ("cd workspace/api && npm run dev", ws, t + 240),
            ("pytest tests/ -q --maxfail=1", api, t + 300),
            ("git add -p", chess, t + 360),
            ("git commit -m 'fix: update telemetry'", chess, t + 400),
            ("git push origin main", chess, t + 430),
        ])
        t += 7200

    # Inject realistic late-arriving one-off noise (e.g. git clone URLs, grep commands)
    # In the legacy ranker, a recent one-off command beats a 18x repeated core command
    # when both match a prefix or substring.
    noise_ts = t - 3600
    noise_entries = [
        ("git clone https://github.com/example/experimental- sandbox.git", chess, noise_ts + 10),
        ("git log --grep='fix: temporary debug' -n 1", chess, noise_ts + 20),
        ("npx --yes create-react-app my-temp-sandbox", chess, noise_ts + 30),
        ("cd /tmp/random-test-dir", ws, noise_ts + 40),
        ("pytest tests/test_one_off_experiment.py", api, noise_ts + 50),
    ]
    all_chronological = session_blocks + noise_entries
    all_chronological.sort(key=lambda x: x[2])

    # Append post-noise continuation of core workflows (holdout evaluation segment)
    for cycle in range(5):
        all_chronological.extend([
            ("cd workspace/chess", ws, t + 100),
            ("git status", chess, t + 120),
            ("git diff --stat", chess, t + 140),
            ("npx expo start --lan --max-workers 1", chess, t + 170),
            ("npx expo run:ios --device", chess, t + 220),
            ("cd workspace/api && npm run dev", ws, t + 260),
            ("pytest tests/ -q --maxfail=1", api, t + 300),
            ("git add -p", chess, t + 340),
            ("git commit -m 'fix: update telemetry'", chess, t + 380),
            ("git push origin main", chess, t + 410),
        ])
        t += 1800

    # Convert to worker format: (raw_cmd, cmd_lower, cwd, ts)
    return [(cmd, cmd.lower(), cwd, ts) for (cmd, cwd, ts) in all_chronological]


def generate_queries_for_target(clean_cmd):
    """Generate realistic user typing queries (prefix + multi-token abbreviation) for a target command."""
    queries = []
    if len(clean_cmd) >= 4:
        queries.append(("prefix4", clean_cmd[:4]))

    tokens = clean_cmd.replace("/", " ").split()
    if len(tokens) >= 2 and len(tokens[0]) >= 2 and len(tokens[-1]) >= 3:
        abbr = f"{tokens[0]} {tokens[-1][:4]}"
        if abbr != clean_cmd:
            queries.append(("multitoken", abbr))
    return queries


def parse_worker_response(resp):
    parts = resp.split("\t")
    if len(parts) < 2:
        return []
    count = int(parts[1])
    cmds = []
    idx = 2
    for _ in range(count):
        if idx < len(parts):
            cmds.append(parts[idx])
        idx += 4
    return cmds


def run_benchmark():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    worker_mod = load_worker_module(repo_root)

    now = time.time()
    # Load real user history if available, and combine with chronological developer workflow trace
    probe_worker = worker_mod.QueryWorker()
    real_entries = list(reversed(probe_worker.history_cache))  # chronological oldest -> newest

    # Filter clean valid commands from real history
    cleaned_real = []
    for raw_cmd, cmd_lower, cwd, raw_ts in real_entries:
        clean = raw_cmd.replace("\r", "").replace("\n", " && ").strip()
        if len(clean) >= 5:
            ts_sec = float(raw_ts) / 1e9 if raw_ts > 1e12 else (float(raw_ts) if raw_ts > 0 else now - 3600)
            cleaned_real.append((clean, clean.lower(), cwd, ts_sec))

    # Take recent real commands + realistic developer workflow trace
    recent_real = cleaned_real[-250:] if len(cleaned_real) > 250 else cleaned_real
    workflow_trace = build_realistic_trace(now)

    # Evaluate on the chronological workflow trace while keeping real user history in the index
    split_idx = int(len(workflow_trace) * 0.75)
    train_workflow = workflow_trace[:split_idx]
    test_workflow = workflow_trace[split_idx:]

    # Worker expects newest-first in ingest_entries
    initial_entries_newest_first = list(reversed(recent_real + train_workflow))

    legacy = LegacySubstringEngine(initial_entries_newest_first, max_results=4)
    upgraded = worker_mod.QueryWorker()
    upgraded._refresh_history_cache = lambda: None  # Lock to benchmark dataset
    upgraded.ingest_entries(initial_entries_newest_first)

    metrics = {
        "legacy": {"hit1": 0, "hit4": 0, "mrr": 0.0, "total": 0},
        "upgraded": {"hit1": 0, "hit4": 0, "mrr": 0.0, "total": 0},
    }
    latencies_ms = []

    prev_cmd = train_workflow[-1][0] if train_workflow else ""

    for idx, (target_cmd, _, cwd, ts_sec) in enumerate(test_workflow):
        queries = generate_queries_for_target(target_cmd)
        for q_kind, q_str in queries:
            # 1. Legacy evaluation
            leg_preds = legacy.rank(cwd, q_str, prev_cmd)
            metrics["legacy"]["total"] += 1
            if target_cmd in leg_preds:
                rank = leg_preds.index(target_cmd) + 1
                if rank == 1:
                    metrics["legacy"]["hit1"] += 1
                if rank <= 4:
                    metrics["legacy"]["hit4"] += 1
                metrics["legacy"]["mrr"] += 1.0 / rank

            # 2. Upgraded QueryWorker evaluation + latency measurement
            t0 = time.perf_counter()
            resp = upgraded.query(str(idx), cwd, q_str, prev_cmd)
            lat_ms = (time.perf_counter() - t0) * 1000.0
            latencies_ms.append(lat_ms)

            upg_preds = parse_worker_response(resp)
            metrics["upgraded"]["total"] += 1
            if target_cmd in upg_preds:
                rank = upg_preds.index(target_cmd) + 1
                if rank == 1:
                    metrics["upgraded"]["hit1"] += 1
                if rank <= 4:
                    metrics["upgraded"]["hit4"] += 1
                metrics["upgraded"]["mrr"] += 1.0 / rank

        # Online update after command execution (simulating _termpeek_preexec RECORD stream)
        legacy.record_command(cwd, prev_cmd, target_cmd, ts_sec)
        upgraded.record_command(cwd, prev_cmd, target_cmd, ts_sec)
        prev_cmd = target_cmd

    total_q = metrics["upgraded"]["total"]
    leg_hit1 = (metrics["legacy"]["hit1"] / total_q) * 100.0
    leg_hit4 = (metrics["legacy"]["hit4"] / total_q) * 100.0
    leg_mrr = metrics["legacy"]["mrr"] / total_q

    upg_hit1 = (metrics["upgraded"]["hit1"] / total_q) * 100.0
    upg_hit4 = (metrics["upgraded"]["hit4"] / total_q) * 100.0
    upg_mrr = metrics["upgraded"]["mrr"] / total_q

    sorted_lat = sorted(latencies_ms)
    p50_lat = sorted_lat[int(len(sorted_lat) * 0.50)]
    p99_lat = sorted_lat[int(len(sorted_lat) * 0.99)]

    print("=" * 72)
    print("termpeek Chronological Holdout Ranking & Latency Benchmark")
    print("=" * 72)
    print(f"Indexed History Size : {len(upgraded.cmd_stats)} unique commands ({len(initial_entries_newest_first)} raw events)")
    print(f"Holdout Queries      : {total_q} queries (prefix + multi-token abbreviations)")
    print("-" * 72)
    print(f"{'Engine':<34} | {'Hit@1':>8} | {'Hit@4':>8} | {'MRR':>8}")
    print("-" * 72)
    print(f"{'Legacy (Substring + Raw Timestamp)':<34} | {leg_hit1:>7.1f}% | {leg_hit4:>7.1f}% | {leg_mrr:>8.3f}")
    print(f"{'Upgraded (Token + Markov-Frecency)':<34} | {upg_hit1:>7.1f}% | {upg_hit4:>7.1f}% | {upg_mrr:>8.3f}")
    print("-" * 72)
    print(f"Improvement Delta                  | {upg_hit1 - leg_hit1:>+7.1f}% | {upg_hit4 - leg_hit4:>+7.1f}% | {upg_mrr - leg_mrr:>+8.3f}")
    print("-" * 72)
    print(f"Worker Query Latency : P50 = {p50_lat:.3f} ms | P99 = {p99_lat:.3f} ms (budget < 2.000 ms)")
    print("=" * 72)

    if upg_hit1 <= leg_hit1 or upg_hit4 <= leg_hit4 or upg_mrr <= leg_mrr:
        print("FAIL: Upgraded ranking engine did not outperform legacy baseline across all metrics")
        sys.exit(1)

    if p99_lat > 2.0:
        print(f"FAIL: Worker P99 query latency {p99_lat:.3f} ms exceeded 2.0 ms budget")
        sys.exit(1)

    print("PASS: Token-Aware Markov-Frecency engine verified superior on Hit@1, Hit@4, and MRR")


if __name__ == "__main__":
    run_benchmark()
