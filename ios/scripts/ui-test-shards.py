#!/usr/bin/env python3
import argparse
import pathlib
import re
import statistics
import sys


def scan(directory):
    tests = []
    for path in sorted(directory.rglob("*.swift")):
        name = None
        for line in path.read_text().splitlines():
            declaration = re.search(r"\bclass\s+(\w+)\s*:\s*XCTestCase", line)
            if declaration:
                name = declaration[1]
            method = re.match(r"\s*(?:@\w+\s+)*func\s+(test\w*)\s*\(", line)
            if name and method:
                tests.append(f"LinksUITests/{name}/{method[1]}")
    return sorted(set(tests))


def assign(tests, weights, count):
    fallback = statistics.median(weights.values()) if weights else 30.0
    loads = [0.0] * count
    assignments = {}
    for test in sorted(tests, key=lambda name: (-weights.get(name, fallback), name)):
        shard = min(range(count), key=lambda index: (loads[index], index))
        assignments[test] = shard + 1
        loads[shard] += weights.get(test, fallback)
    return assignments, loads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "LinksUITests")
    parser.add_argument("--durations", type=pathlib.Path, default=pathlib.Path(__file__).with_name("ui-test-durations.tsv"))
    parser.add_argument("--shard", default="1/1")
    args = parser.parse_args()
    match = re.fullmatch(r"([1-9]\d*)/([1-9]\d*)", args.shard)
    if not match or int(match[1]) > int(match[2]):
        parser.error("shard must be K/N with 1 <= K <= N")
    shard, count = map(int, match.groups())
    weights = {}
    for line in args.durations.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, seconds = line.split("\t")
        weights[name] = float(seconds)
        if not 0 < weights[name] < float("inf"):
            parser.error(f"invalid duration for {name}")
    assignments, loads = assign(scan(args.tests), weights, count)
    for index, load in enumerate(loads, 1):
        print(f"UI test slice {index}/{count}: planned {load:.1f}s", file=sys.stderr)
    if shard not in assignments.values():
        parser.error(f"UI test slice {args.shard} has no tests")
    for test, index in sorted(assignments.items()):
        print(f"{index}\t{test}")


if __name__ == "__main__":
    main()
