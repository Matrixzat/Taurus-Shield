#!/usr/bin/env python3
"""Report ARMv7 R_ARM_RELATIVE dispatch-table evidence.

This is a diagnostic reader only.  It records complete 256-entry relocation
windows and normalizes their native target structure, but it never assigns a
DEX opcode.  ARMv7 and ARM64 handler identities are separate evidence paths
until an ARMv7 reference VM or another independent semantic proof establishes
their equivalence.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


SECTION_RE = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+"
    r"([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)"
)
RELATIVE_RE = re.compile(
    r"^\s*([0-9a-fA-F]+)\s+\S+\s+R_ARM_RELATIVE"
)
MAPPING_PROMOTION = {
    "allowed": False,
    "reason": (
        "ARMv7 target evidence must not be merged into the ARM64 "
        "encoded-byte mapping without independent proof."
    ),
}


def readelf(path: Path, *args: str) -> str:
    return subprocess.check_output(
        ["readelf", *args, str(path)],
        text=True,
        stderr=subprocess.STDOUT,
    )


def elf_identity(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in readelf(path, "-h").splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[key.strip()] = value.strip()
    return {
        "class": values.get("Class", ""),
        "data": values.get("Data", ""),
        "machine": values.get("Machine", ""),
    }


def read_sections(path: Path) -> list[dict[str, int | str]]:
    sections = []
    for line in readelf(path, "-S", "--wide").splitlines():
        match = SECTION_RE.match(line)
        if not match:
            continue
        name, address, offset, size = match.groups()
        sections.append({
            "name": name,
            "address": int(address, 16),
            "offset": int(offset, 16),
            "size": int(size, 16),
        })
    return sections


def word_at(
    data: bytes, sections: list[dict[str, int | str]], address: int
) -> int:
    for section in sections:
        start = int(section["address"])
        size = int(section["size"])
        if start <= address and address + 4 <= start + size:
            offset = int(section["offset"]) + address - start
            if offset + 4 <= len(data):
                return int.from_bytes(data[offset:offset + 4], "little")
    raise ValueError(f"relocation address {address:#x} is not file-backed")


def read_relative_relocations(
    path: Path, sections: list[dict[str, int | str]]
) -> dict[int, int]:
    data = path.read_bytes()
    relocations: dict[int, int] = {}
    for line in readelf(path, "-r", "--wide").splitlines():
        match = RELATIVE_RE.match(line)
        if match:
            location = int(match.group(1), 16)
            # ARM32 uses REL relocations: unlike AArch64 RELA records, the
            # addend is stored in the relocated word, not printed by readelf.
            relocations[location] = word_at(data, sections, location)
    return relocations


def complete_tables(
    relocations: dict[int, int], entry_count: int = 256, stride: int = 4
) -> list[int]:
    tables = []
    for base in sorted(relocations):
        window = [base + stride * index for index in range(entry_count)]
        if all(location in relocations for location in window):
            tables.append(base)
    return tables


def containing_section(
    sections: list[dict[str, int | str]], address: int
) -> dict[str, int | str] | None:
    for section in sections:
        start = int(section["address"])
        if start <= address < start + int(section["size"]):
            return section
    return None


def normalized_target(
    sections: list[dict[str, int | str]], target: int
) -> tuple[str, bool, str | None]:
    section = containing_section(sections, target)
    if section is None:
        return f"absolute+0x{target:x}", False, None
    name = str(section["name"])
    offset = target - int(section["address"])
    return f"{name}+0x{offset:x}", name == ".text", name


def table_report(
    table: int,
    relocations: dict[int, int],
    sections: list[dict[str, int | str]],
) -> dict:
    entries = []
    sequence = []
    groups: dict[str, list[int]] = {}
    executable_count = 0
    for encoded in range(256):
        target = relocations[table + encoded * 4]
        normalized, executable, section = normalized_target(sections, target)
        sequence.append(normalized)
        groups.setdefault(normalized, []).append(encoded)
        executable_count += executable
        entries.append({
            "encoded_byte": encoded,
            "native_target_addend": f"0x{target:x}",
            "normalized_target": normalized,
            "target_section": section,
            "executable_text_target": executable,
        })

    repeated = [
        {"normalized_target": target, "encoded_bytes": encoded}
        for target, encoded in sorted(groups.items())
        if len(encoded) > 1
    ]
    return {
        "virtual_address": f"0x{table:x}",
        "entry_stride": 4,
        "entry_count": 256,
        "executable_text_target_count": executable_count,
        "unique_normalized_target_count": len(groups),
        "normalized_target_sequence": sequence,
        "normalized_target_groups": repeated,
        "entries": entries,
        "interpretation": (
            "The normalized sequence describes ARMv7 native target "
            "structure only; it is not an encoded-byte to DEX-opcode mapping."
        ),
    }


def analyze(path: Path) -> dict:
    identity = elf_identity(path)
    if identity != {
        "class": "ELF32",
        "data": "2's complement, little endian",
        "machine": "ARM",
    }:
        return {
            "status": "skipped",
            "identity": identity,
            "reason": "not a little-endian ELF32 ARM object",
        }

    sections = read_sections(path)
    relocations = read_relative_relocations(path, sections)
    tables = complete_tables(relocations)
    reports = [table_report(table, relocations, sections) for table in tables]
    preferred = None
    if reports:
        preferred = max(
            reports,
            key=lambda report: (
                report["executable_text_target_count"],
                -int(report["virtual_address"], 16),
            ),
        )["virtual_address"]
    text = next(
        (section for section in sections if section["name"] == ".text"),
        None,
    )
    return {
        "status": "ok" if reports else "no_complete_dispatch_table",
        "identity": identity,
        "relative_relocation_type": "R_ARM_RELATIVE",
        "relative_relocation_count": len(relocations),
        "text_section": text,
        "complete_256_entry_tables": reports,
        "preferred_table": preferred,
        "selection_rule": (
            "Preferred table is the complete window with the most executable "
            "targets; this selects evidence and does not prove opcode identity."
        ),
        "mapping_promotion": {
            "allowed": False,
            "reason": (
                "No ARMv7 reference VM or independently proven cross-ABI "
                "semantic equivalence was supplied."
            ),
        },
    }


def input_paths(root: Path | None, paths: list[Path]) -> tuple[list[Path], Path | None]:
    if root is not None:
        return sorted(root.rglob("*.so")), root
    expanded = []
    for path in paths:
        if path.is_dir():
            expanded.extend(sorted(path.rglob("*.so")))
        else:
            expanded.append(path)
    return expanded, None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.root is None and not args.paths:
        parser.error("provide paths or --root")

    files, root = input_paths(args.root, args.paths)
    result = {
        "schema": "nmmp-armv7-dispatch-evidence/v1",
        "architecture": "ARMv7",
        "files_scanned": len(files),
        "armv7_files": {},
        "non_armv7_files": {},
        "mapping_promotion": MAPPING_PROMOTION,
    }
    for path in files:
        key = str(path.relative_to(root)) if root else str(path)
        try:
            report = analyze(path)
        except (OSError, subprocess.CalledProcessError, ValueError) as exc:
            report = {"status": "error", "error": str(exc)}
        if report.get("identity", {}).get("machine") == "ARM" and (
            report.get("identity", {}).get("class") == "ELF32"
        ):
            result["armv7_files"][key] = report
        else:
            result["non_armv7_files"][key] = report
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()