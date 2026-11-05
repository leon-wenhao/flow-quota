#!/usr/bin/env python3
"""Opt-in macOS integration check: real sampler CPU, output, and SIGTERM cleanup.

Run against a freshly built FlowQuotaAgent, outside the application sandbox.
A temporary database avoids changing the installed application's usage or rules.
CPU percentages use cumulative process CPU time over the observation window;
100% represents one CPU core. Only status metadata is printed.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def processes(parent):
    output = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,time=,comm="], text=True)
    result = []
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4 and fields[1] == str(parent) and fields[3] == "/usr/bin/nettop":
            minutes, seconds = fields[2].split(":")
            result.append((int(fields[0]), int(minutes) * 60 + float(seconds)))
    return result


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def check(binary):
    with tempfile.TemporaryDirectory(prefix="flowquota-cpu-") as directory:
        child = subprocess.Popen(
            [str(binary), "--snapshot", "--sample-seconds", "10", "--database",
             str(Path(directory) / "quota.sqlite")],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        samplers = []
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                samplers = processes(child.pid)
                if samplers:
                    break
                if child.poll() is not None:
                    raise RuntimeError("Agent exited before starting the sampler")
                time.sleep(0.1)
            assert len(samplers) == 1, "Expected exactly one sampler"
            pid, cpu_start = samplers[0]
            start = time.monotonic()
            time.sleep(5)
            current = processes(child.pid)
            assert len(current) == 1 and current[0][0] == pid, "Sampler unexpectedly restarted"
            elapsed = time.monotonic() - start
            cpu = 100 * (current[0][1] - cpu_start) / elapsed
            assert cpu < 10, f"Sampler used {cpu:.2f}% CPU; expected <10% on an idle test host"
            stdout, stderr = child.communicate(timeout=10)
            assert child.returncode == 0, stderr
            snapshot = json.loads(stdout)["snapshot"]["_0"]
            assert snapshot.get("monitoring") == "collecting", "Sampling did not produce valid frames"
            assert snapshot.get("sampledAt") is not None, "Missing sample timestamp"
            assert not alive(pid), "Normal diagnostic shutdown left its sampler running"
            print(json.dumps({"check": "sampling", "cpu_percent": round(cpu, 2),
                              "observation_seconds": round(elapsed, 2),
                              "collecting": True, "child_reaped": True}), flush=True)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=10)
            for pid, _ in samplers:
                if alive(pid):
                    os.kill(pid, signal.SIGTERM)

        # Start long enough to interrupt it while its stream is active.
        child = subprocess.Popen(
            [str(binary), "--snapshot", "--sample-seconds", "60", "--database",
             str(Path(directory) / "quota.sqlite")],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        samplers = []
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                samplers = processes(child.pid)
                if samplers:
                    break
                time.sleep(0.1)
            assert len(samplers) == 1, "Expected one sampler before termination"
            child.terminate()
            child.wait(timeout=10)
            assert not alive(samplers[0][0]), "SIGTERM left an orphan sampler"
            assert child.returncode == 0, "Agent did not finish graceful shutdown"
            print(json.dumps({"check": "SIGTERM", "child_reaped": True}), flush=True)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=10)
            for pid, _ in samplers:
                if alive(pid):
                    os.kill(pid, signal.SIGTERM)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent", type=Path)
    check(parser.parse_args().agent.resolve(strict=True))
