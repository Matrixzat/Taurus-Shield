#!/usr/bin/env python3
"""Resolve and validate NMMP opcode mappings before any DEX is written.

This gate deliberately fails closed.  A mapping is usable only when the Java
solver finds one unique permutation that preserves every recovered method's
instruction layout and its original wrapper register frame.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def exact_source_assignments(mapping):
    """Return a validated generated-source permutation, or None.

    Native handler inference supplies candidate_opcodes and must go through the
    Java format solver.  A generated DexOpcodes.h permutation is different:
    it is already exact source evidence and has no candidate-domain section.
    Keep that path explicit so partial native mappings cannot bypass the gate.
    """
    if mapping.get("schema") != "nmmp-generated-handler-mapping/v1":
        return None
    known = mapping.get("known_assignments")
    if not isinstance(known, dict) or len(known) != 256:
        raise SystemExit(
            "generated source mapping must contain exactly 256 assignments"
        )
    assignments = {}
    for encoded, standard in known.items():
        encoded_value = number(encoded)
        standard_value = number(standard)
        if not 0 <= encoded_value < 256 or not 0 <= standard_value < 256:
            raise SystemExit("generated source mapping contains an out-of-range byte")
        assignments[encoded_value] = standard_value
    if len(assignments) != 256 or len(set(assignments.values())) != 256:
        raise SystemExit(
            "generated source mapping is not a one-to-one 256-byte permutation"
        )
    return assignments


def write_exact_source_mapping(mapping, assignments, output):
    result = dict(mapping)
    result["format_solver"] = {
        "status": "accepted_exact_source",
        "reason": (
            "The generated DexOpcodes.h permutation is complete and bijective; "
            "native candidate-domain solving is not applicable."
        ),
    }
    result["entries"] = [
        {
            **entry,
            "standard": f"0x{assignments[number(entry['encoded'])]:02x}",
            "confidence": "generated-source-exact",
        }
        if entry.get("encoded") is not None
        and number(entry["encoded"]) in assignments else entry
        for entry in mapping.get("entries", [])
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--solver", required=True, type=Path)
    parser.add_argument("--methods", required=True, type=Path)
    parser.add_argument("--mapping", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    recovered = json.loads(args.methods.read_text(encoding="utf-8"))
    mapping = json.loads(args.mapping.read_text(encoding="utf-8"))
    methods = []
    for index, item in enumerate(recovered.get("recovered", [])):
        if item.get("error"):
            raise SystemExit(f"method {index}: wrapper metadata is incomplete")
        register_count = item.get("register_count")
        if register_count is None:
            raise SystemExit(
                f"method {index}: original NMMP register count was not recovered; "
                "refusing to invent a DEX register frame"
            )
        ins_size = item.get("ins_size")
        if ins_size is None:
            raise SystemExit(
                f"method {index}: receiver-aware ins_size was not recovered; "
                "refusing to solve against an invented frame"
            )
        methods.append({
            "words": [number(word) for word in item.get("words", [])],
            "registerCount": number(register_count),
            "insSize": number(ins_size),
        })

    exact = exact_source_assignments(mapping)
    if exact is not None:
        write_exact_source_mapping(mapping, exact, args.out)
        return 0

    candidates = mapping.get("candidate_opcodes")
    if not isinstance(candidates, dict) or not candidates:
        raise SystemExit("opcode mapper did not provide candidate domains")
    known = mapping.get("known_assignments", {})
    problem = {"methods": methods, "candidates": candidates,
               "knownAssignments": known}
    process = subprocess.run(
        ["java", "-jar", str(args.solver)],
        input=json.dumps(problem), text=True, capture_output=True,
    )
    try:
        result = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"format solver returned invalid JSON: {exc}")
    if process.returncode or result.get("status") != "resolved":
        reason = result.get("reason", process.stderr.strip() or "unknown failure")
        raise SystemExit(f"opcode mapping is not uniquely verifier-safe: {reason}")

    values = result["mappingValues"]
    solved = {number(encoded): number(standard)
              for encoded, standard in values.items()}
    if len(solved) != len(candidates) or len(set(solved.values())) != len(solved):
        raise SystemExit("format solver did not return a one-to-one candidate mapping")

    output = dict(mapping)
    output["format_solver"] = result
    output["entries"] = [
        {
            **entry,
            "standard": f"0x{solved[number(entry['encoded'])]:02x}",
            "confidence": "format-solver-unique",
        }
        if entry.get("encoded") is not None
        and number(entry["encoded"]) in solved else entry
        for entry in mapping.get("entries", [])
    ]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())