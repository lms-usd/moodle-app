#!/usr/bin/env python3
import asyncio
import statistics
import subprocess
import threading
import time
import aiohttp
import matplotlib.pyplot as plt
import numpy as np

# Configuration
TOTAL_REQUESTS = 500
CONCURRENCY = 25

TARGETS = {
    "FrankenPHP\n(Single Container)": {
        "url": "http://localhost:8081/install.php",
        "containers": ["bench-frankenphp"],
        "color": "#00ADD8",  # Go / Caddy Cyan
    },
    "FastCGI\n(Nginx + PHP-FPM)": {
        "url": "http://localhost:8082/install.php",
        "containers": ["bench-fpm", "bench-nginx"],
        "color": "#777BB4",  # PHP Purple
    },
    "LOMP\n(OpenLiteSpeed + LSAPI)": {
        "url": "http://localhost:8083/install.php",
        "containers": ["bench-lomp"],
        "color": "#38A169",  # LiteSpeed Green
    },
}


def parse_mem_to_mib(mem_str: str) -> float:
    """Convert docker stats memory string (e.g. '45.2MiB' or '1.1GiB') to MiB."""
    usage = mem_str.split("/")[0].strip()
    if "GiB" in usage:
        return float(usage.replace("GiB", "")) * 1024.0
    if "MiB" in usage:
        return float(usage.replace("MiB", ""))
    if "KiB" in usage:
        return float(usage.replace("KiB", "")) / 1024.0
    return 0.0


def get_total_memory_mib(containers: list[str]) -> float:
    """Query docker stats for the combined memory usage of a pod's containers."""
    cmd = ["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}"] + containers
    out = subprocess.check_output(cmd, text=True).strip().splitlines()
    return sum(parse_mem_to_mib(line) for line in out if line)


async def run_http_phase(
    url: str, total_requests: int, concurrency: int, keep_alive: bool
):
    """Run concurrent HTTP benchmark and return throughput (req/s) and latency list (ms)."""
    connector = aiohttp.TCPConnector(limit=concurrency, force_close=not keep_alive)
    headers = {} if keep_alive else {"Connection": "close"}
    timeout = aiohttp.ClientTimeout(total=8, connect=3, sock_read=5)
    latencies_ms = []
    sem = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession(
        connector=connector,
        headers=headers,
        timeout=timeout,
        cookie_jar=aiohttp.DummyCookieJar(),
    ) as session:
        # Warm-up only on Keep-Alive phase to prime OPcache and spawn workers
        if keep_alive:
            async with session.get(url) as resp:
                await resp.read()
                if resp.status != 200:
                    raise RuntimeError(
                        f"Target {url} returned HTTP {resp.status} instead of 200!"
                    )

            async def fetch_warmup():
                async with sem:
                    try:
                        async with session.get(url) as resp:
                            await resp.read()
                    except (asyncio.TimeoutError, aiohttp.ClientError):
                        pass

            await asyncio.gather(*(fetch_warmup() for _ in range(10)))

        # Actual timed benchmark
        async def fetch():
            async with sem:
                t0 = time.perf_counter()
                try:
                    async with session.get(url) as resp:
                        await resp.read()
                    latencies_ms.append((time.perf_counter() - t0) * 1000.0)
                except (asyncio.TimeoutError, aiohttp.ClientError):
                    # Ignore single dropped socket so 1 stalled packet doesn't abort 500 reqs
                    pass

        start_time = time.perf_counter()
        await asyncio.gather(*(fetch() for _ in range(total_requests)))
        elapsed = time.perf_counter() - start_time

    completed = len(latencies_ms)
    throughput = completed / elapsed if elapsed > 0 else 0.0
    return throughput, latencies_ms


def main():
    results = {}

    for name, cfg in TARGETS.items():
        clean_name = name.replace("\n", " ")
        print(f"\n==========================================")
        print(f"Benchmarking: {clean_name}")
        print(f"==========================================")

        # 1. Measure Idle Memory
        idle_mem = get_total_memory_mib(cfg["containers"])
        print(f"📊 Idle Memory: {idle_mem:.2f} MiB")

        # Background thread to sample peak memory during load
        peak_mem_samples = [idle_mem]
        stop_sampling = False

        def sample_mem():
            while not stop_sampling:
                try:
                    peak_mem_samples.append(get_total_memory_mib(cfg["containers"]))
                except Exception:
                    pass
                time.sleep(0.2)

        sampler = threading.Thread(target=sample_mem, daemon=True)
        sampler.start()

        # 2. Phase A: RPS & Latency (Keep-Alive = True)
        print(
            f"Running RPS & Latency test ({TOTAL_REQUESTS} reqs, concurrency={CONCURRENCY})..."
        )
        rps, latencies = asyncio.run(
            run_http_phase(cfg["url"], TOTAL_REQUESTS, CONCURRENCY, keep_alive=True)
        )
        mean_lat = statistics.mean(latencies)
        p95_lat = float(np.percentile(latencies, 95))
        print(f"Phase A done: {rps:.2f} RPS (Mean: {mean_lat:.2f} ms, P95: {p95_lat:.2f} ms)")

        # Brief 1s cooldown so ephemeral TCP sockets settle before CPS test
        time.sleep(1.0)

        # 3. Phase B: CPS - Connections Per Second (Keep-Alive = False / New TCP conn per request)
        print(
            f"Running CPS test ({TOTAL_REQUESTS} new connections, concurrency={CONCURRENCY})..."
        )
        cps, _ = asyncio.run(
            run_http_phase(cfg["url"], TOTAL_REQUESTS, CONCURRENCY, keep_alive=False)
        )

        stop_sampling = True
        sampler.join(timeout=1.0)

        mean_lat = statistics.mean(latencies)
        p95_lat = float(np.percentile(latencies, 95))
        peak_mem = max(peak_mem_samples)

        results[name] = {
            "rps": rps,
            "cps": cps,
            "mean_lat": mean_lat,
            "p95_lat": p95_lat,
            "idle_mem": idle_mem,
            "peak_mem": peak_mem,
            "color": cfg["color"],
        }

        print(f"Results for {clean_name}:")
        print(f"   • RPS (Keep-Alive):     {rps:.2f} req/s")
        print(f"   • CPS (New TCP Conns):  {cps:.2f} conn/s")
        print(f"   • Mean Latency:         {mean_lat:.2f} ms")
        print(f"   • P95 Latency:          {p95_lat:.2f} ms")
        print(f"   • Peak Memory Used:     {peak_mem:.2f} MiB")

    # ==========================================
    # Plotting 2x2 Comparison Chart
    # ==========================================
    labels = list(results.keys())
    colors = [results[k]["color"] for k in labels]
    x = np.arange(len(labels))
    width = 0.35

    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    fig.suptitle(
        "Moodle 5.3 Architecture Benchmark: FrankenPHP vs. FastCGI vs. LOMP (OpenLiteSpeed)",
        fontsize=14,
        fontweight="bold",
    )

    # Subplot 1: RPS & CPS (Higher is Better)
    ax1 = axes[0, 0]
    rps_vals = [results[k]["rps"] for k in labels]
    cps_vals = [results[k]["cps"] for k in labels]
    b1 = ax1.bar(
        x - width / 2, rps_vals, width, label="RPS (Keep-Alive)", color="#00ADD8"
    )
    b2 = ax1.bar(
        x + width / 2, cps_vals, width, label="CPS (New Conns/s)", color="#2B6CB0"
    )
    ax1.set_title("Throughput: RPS & CPS (Higher is Better ↑)", fontweight="bold")
    ax1.set_ylabel("Per Second")
    ax1.set_xticks(x, labels)
    ax1.legend()
    ax1.bar_label(b1, fmt="%.1f", padding=3)
    ax1.bar_label(b2, fmt="%.1f", padding=3)
    ax1.grid(axis="y", linestyle="--", alpha=0.4)

    # Subplot 2: Latency Mean & P95 (Lower is Better)
    ax2 = axes[0, 1]
    mean_vals = [results[k]["mean_lat"] for k in labels]
    p95_vals = [results[k]["p95_lat"] for k in labels]
    b3 = ax2.bar(
        x - width / 2, mean_vals, width, label="Mean Latency (ms)", color="#48BB78"
    )
    b4 = ax2.bar(
        x + width / 2, p95_vals, width, label="P95 Latency (ms)", color="#F56565"
    )
    ax2.set_title("Response Latency in ms (Lower is Better ↓)", fontweight="bold")
    ax2.set_ylabel("Milliseconds (ms)")
    ax2.set_xticks(x, labels)
    ax2.legend()
    ax2.bar_label(b3, fmt="%.1f ms", padding=3)
    ax2.bar_label(b4, fmt="%.1f ms", padding=3)
    ax2.grid(axis="y", linestyle="--", alpha=0.4)

    # Subplot 3: Memory Usage Idle vs Peak (Lower is Better)
    ax3 = axes[1, 0]
    idle_vals = [results[k]["idle_mem"] for k in labels]
    peak_vals = [results[k]["peak_mem"] for k in labels]
    b5 = ax3.bar(
        x - width / 2, idle_vals, width, label="Idle RAM (MiB)", color="#A0AEC0"
    )
    b6 = ax3.bar(
        x + width / 2, peak_vals, width, label="Peak Load RAM (MiB)", color="#ED8936"
    )
    ax3.set_title("Pod Memory Footprint in MiB (Lower is Better ↓)", fontweight="bold")
    ax3.set_ylabel("Memory (MiB)")
    ax3.set_xticks(x, labels)
    ax3.legend()
    ax3.bar_label(b5, fmt="%.1f MiB", padding=3)
    ax3.bar_label(b6, fmt="%.1f MiB", padding=3)
    ax3.grid(axis="y", linestyle="--", alpha=0.4)

    # Subplot 4: Efficiency Ratio (RPS per 100 MiB of Peak RAM)
    ax4 = axes[1, 1]
    eff_vals = [(results[k]["rps"] / results[k]["peak_mem"]) * 100.0 for k in labels]
    b7 = ax4.bar(x, eff_vals, width=0.45, color=colors)
    ax4.set_title(
        "Memory Efficiency: RPS per 100 MiB RAM (Higher is Better ↑)", fontweight="bold"
    )
    ax4.set_ylabel("RPS / 100 MiB")
    ax4.set_xticks(x, labels)
    ax4.bar_label(b7, fmt="%.1f", padding=3)
    ax4.grid(axis="y", linestyle="--", alpha=0.4)

    for ax in axes.flat:
     ax.margins(y=0.22)

    plt.tight_layout(rect=[0, 0.02, 1, 0.95])
    output_file = "benchmark/moodle_arch_comparison.png"
    plt.savefig(output_file, dpi=150)
    print(f"\nChart saved to: {output_file}")


if __name__ == "__main__":
    main()
