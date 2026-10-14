"""Compile and run all HW1 self-checking testbenches with Icarus Verilog."""
from pathlib import Path
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / 'results'
BUILD = RESULTS / 'build'


def locate(name, env):
    candidate = os.environ.get(env) or shutil.which(name)
    if candidate:
        return candidate
    fallback = Path('C:/iverilog/bin') / (name + '.exe')
    if fallback.is_file():
        return str(fallback)
    raise SystemExit(f'{name} was not found. Install Icarus Verilog or set {env}.')


def main():
    RESULTS.mkdir(exist_ok=True)
    BUILD.mkdir(exist_ok=True)
    compiler = locate('iverilog', 'IVERILOG')
    runtime = locate('vvp', 'VVP')
    version = subprocess.run([compiler, '-V'], capture_output=True, text=True).stdout.splitlines()[0]
    summaries = []
    for top in ('tb_uart_dma', 'tb_ahb', 'tb_axi'):
        start = time.perf_counter()
        target = BUILD / f'{top}.vvp'
        command = [compiler, '-g2012', '-Wall', '-s', top, '-o', os.path.relpath(target, RESULTS)]
        command += [os.path.relpath(p, RESULTS) for p in sorted((ROOT / 'rtl').glob('*.sv'))]
        command += [os.path.relpath(ROOT / 'sim' / f'{top}.sv', RESULTS)]
        compiled = subprocess.run(command, cwd=RESULTS, capture_output=True, text=True, timeout=90)
        compile_log = compiled.stdout + compiled.stderr
        (RESULTS / f'{top}_compile.log').write_text(compile_log, encoding='utf-8')
        if compiled.returncode:
            print(compile_log)
            raise SystemExit(f'Compilation failed: {top}')
        executed = subprocess.run([runtime, os.path.relpath(target, RESULTS)], cwd=RESULTS, capture_output=True, text=True, timeout=90)
        log = executed.stdout + executed.stderr
        (RESULTS / f'{top}.log').write_text(log, encoding='utf-8')
        passed = executed.returncode == 0 and 'PASS' in log and 'FAIL' not in log and 'FATAL' not in log
        summaries.append({'testbench': top, 'passed': passed, 'returncode': executed.returncode,
                          'elapsed_seconds': round(time.perf_counter() - start, 3),
                          'pass_lines': [line for line in log.splitlines() if 'PASS' in line]})
        print(f'{top}: {"PASS" if passed else "FAIL"}')
        print(log.strip())
    sources = [*sorted((ROOT / 'rtl').glob('*.sv')), *sorted((ROOT / 'sim').glob('*.sv')),
               Path(__file__).resolve()]
    source_hashes = {str(p.relative_to(ROOT)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sources}
    summary = {'simulator': version,
               'executed_at_utc_plus_8': datetime.now(timezone(timedelta(hours=8))).isoformat(),
               'tests': summaries, 'source_sha256': source_hashes,
               'all_passed': all(item['passed'] for item in summaries)}
    (RESULTS / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    return 0 if summary['all_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
