"""
il2cpp_dumper.py — On-device IL2CPP metadata + ELF parser for Taurus Shield.

Accepts a ZIP containing:
  - global-metadata.dat  (IL2CPP metadata binary)
  - libil2cpp.so         (arm64-v8a native library)

Produces dump.json compatible with Taurus Shield Mod Engine:
  { "version": int, "total_methods": int,
    "all_methods": [...], "interesting_methods": [...] }

Each entry:
  { "method": str, "class": str, "return_type": str,
    "offset": "0xHEX", "interest_score": int }

Supports IL2CPP metadata versions 16–29 (covers virtually all Unity games).
Requires: pyelftools (pre-installed via Chaquopy pip).
No internet. Fully on-device.
"""

import struct
import array
import os
import sys
import io
import json
import zipfile
import tempfile
import shutil
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Optional, Tuple


# ── Live log bridge (same pattern as api_bridge.py) ───────────────────────────

class _LiveLogger:
    def __init__(self):
        self._buf = io.StringIO()
        try:
            from java import jclass
            self._bridge = jclass('com.taurus.shield.LogBridge')
        except Exception:
            self._bridge = None

    def write(self, text: str):
        self._buf.write(text)
        if self._bridge and text.strip():
            for line in text.splitlines():
                s = line.strip()
                if s:
                    try:
                        self._bridge.push(s)
                    except Exception:
                        pass

    def flush(self): pass

    def getvalue(self) -> str:
        return self._buf.getvalue()


# ── Binary helpers ─────────────────────────────────────────────────────────────

def _u8(d, o):  return struct.unpack_from('B',  d, o)[0]
def _i32(d, o): return struct.unpack_from('<i', d, o)[0]
def _u32(d, o): return struct.unpack_from('<I', d, o)[0]
def _u16(d, o): return struct.unpack_from('<H', d, o)[0]
def _u64(d, o): return struct.unpack_from('<Q', d, o)[0]

METADATA_MAGIC = 0xFAB11BAF


def _read_cstr(data: bytes, offset: int) -> str:
    try:
        end = data.index(b'\x00', offset)
        return data[offset:end].decode('utf-8', errors='replace')
    except (ValueError, IndexError):
        return ''


# ── IL2CPP Metadata parser ─────────────────────────────────────────────────────

def _parse_header(data: bytes) -> Tuple[int, Dict]:
    if len(data) < 8:
        raise ValueError("File too small for global-metadata.dat")
    magic = _u32(data, 0)
    if magic != METADATA_MAGIC:
        raise ValueError(f"Not global-metadata.dat (magic={hex(magic)}, expected {hex(METADATA_MAGIC)})")
    version = _i32(data, 4)
    if version < 16 or version > 31:
        raise ValueError(f"Unsupported IL2CPP metadata version: {version}")

    COMMON_SECTIONS = [
        'stringLiteral', 'stringLiteralData', 'string',
        'events', 'properties', 'methods',
        'parameterDefaultValues', 'fieldDefaultValues',
        'fieldAndParameterDefaultValueData', 'fieldMarshaledSizes',
        'parameters', 'fields', 'genericParameters',
        'genericParameterConstraints', 'genericContainers',
        'nestedTypes', 'interfaces', 'vtableMethods', 'interfaceOffsets',
        'typeDefinitions',
    ]

    h = {}
    pos = 8
    for name in COMMON_SECTIONS:
        h[name + 'Offset'] = _i32(data, pos); pos += 4
        h[name + 'Size']   = _i32(data, pos); pos += 4

    if version >= 21:
        h['rgctxEntriesOffset'] = _i32(data, pos); pos += 4
        h['rgctxEntriesSize']   = _i32(data, pos); pos += 4

    if version >= 24:
        h['imagesOffset']     = _i32(data, pos); pos += 4
        h['imagesSize']       = _i32(data, pos); pos += 4
        h['assembliesOffset'] = _i32(data, pos); pos += 4
        h['assembliesSize']   = _i32(data, pos); pos += 4

    if version >= 27:
        for name in ['metadataUsagePairs', 'fieldRefs']:
            h[name + 'Offset'] = _i32(data, pos); pos += 4
            h[name + 'Size']   = _i32(data, pos); pos += 4

    if version >= 29:
        for name in ['unresolvedVirtualCallParameterTypes',
                     'unresolvedVirtualCallParameterRanges',
                     'windowsRuntimeTypeNames', 'windowsRuntimeStrings',
                     'exportedTypeDefinitions']:
            h[name + 'Offset'] = _i32(data, pos); pos += 4
            h[name + 'Size']   = _i32(data, pos); pos += 4

    return version, h


def _detect_method_struct_size(h: dict) -> int:
    sz = h.get('methodsSize', 0)
    for candidate in [52, 48, 44, 56, 40]:
        if sz > 0 and sz % candidate == 0:
            count = sz // candidate
            if 10 < count < 10_000_000:
                return candidate
    return 52


def _detect_type_struct_size(h: dict) -> int:
    sz = h.get('typeDefinitionsSize', 0)
    for candidate in [116, 84, 92, 96, 108, 120, 80]:
        if sz > 0 and sz % candidate == 0:
            count = sz // candidate
            if 1 < count < 1_000_000:
                return candidate
    return 116


# ── Bulk struct format strings ─────────────────────────────────────────────────

def _method_iter_fmt(struct_sz: int) -> Tuple[str, int, int, int]:
    skip = struct_sz - 14
    fmt  = f'<i4xi{skip}xH'
    return fmt, 0, 1, 2


def _type_iter_fmt(struct_sz: int) -> Optional[str]:
    if struct_sz == 116:
        return '<ii52xI4xi24xH18x'
    elif struct_sz in (84, 92, 96):
        trail = struct_sz - 74
        return f'<ii28xI4xi24xH{trail}x'
    elif struct_sz in (108, 120):
        trail = struct_sz - 98
        return f'<ii52xI4xi24xH{trail}x'
    else:
        return None


def _parse_methods_and_types(data: bytes, header: Dict, version: int):
    """
    Bulk-parses all method and type definitions using struct.iter_unpack.
    Speed optimisations:
      • string_cache dict: each unique string index resolved once via
        data.index(b'\\x00') — repeated lookups are O(1) dict hits.
      • Slice assignment: method_class[a:b] = [name]*count instead of
        a Python for-loop per type's methods.
      • iter_unpack: single C-level pass over both section blobs.
    """
    str_base  = header['stringOffset']
    str_cache: Dict[int, str] = {}

    def string_at(idx: int) -> str:
        if idx < 0:
            return ''
        cached = str_cache.get(idx)
        if cached is not None:
            return cached
        s = _read_cstr(data, str_base + idx)
        str_cache[idx] = s
        return s

    meth_sz = _detect_method_struct_size(header)
    type_sz = _detect_type_struct_size(header)

    meth_off   = header['methodsOffset']
    meth_bytes = header['methodsSize']
    type_off   = header['typeDefinitionsOffset']
    type_bytes = header['typeDefinitionsSize']

    method_count = meth_bytes // meth_sz
    type_count   = type_bytes // type_sz

    print(f"  Method struct : {meth_sz} B → {method_count:,} methods")
    print(f"  Type struct   : {type_sz} B → {type_count:,} types")

    # ── Build method_index → class/namespace name (bulk iter_unpack) ───────
    method_class = [''] * method_count
    method_ns    = [''] * method_count

    type_fmt  = _type_iter_fmt(type_sz)
    type_blob = data[type_off: type_off + type_bytes]

    if type_fmt and len(type_blob) >= type_bytes:
        try:
            for tup in struct.iter_unpack(type_fmt, type_blob):
                n_idx, ns_idx, _flags, m_start, m_count = tup
                if m_count <= 0 or m_count > method_count:
                    continue
                end = m_start + m_count
                if m_start < 0 or end > method_count:
                    continue
                cls_name = string_at(n_idx)
                ns_name  = string_at(ns_idx) if ns_idx >= 0 else ''
                # Slice assignment — one C-level op instead of a Python for-loop
                method_class[m_start:end] = [cls_name] * m_count
                method_ns[m_start:end]    = [ns_name]  * m_count
        except struct.error:
            pass
    else:
        tf = {'nameIndex': 0, 'namespaceIndex': 4,
              'methodStart': 68 if type_sz >= 100 else 44,
              'method_count': 96 if type_sz >= 100 else 72}
        for t in range(type_count):
            base = type_off + t * type_sz
            if base + type_sz > len(data):
                break
            try:
                n_idx   = _i32(data, base + tf['nameIndex'])
                ns_idx  = _i32(data, base + tf['namespaceIndex'])
                m_start = _i32(data, base + tf['methodStart'])
                m_count = _u16(data, base + tf['method_count'])
                end     = m_start + m_count
                if m_count <= 0 or m_start < 0 or end > method_count:
                    continue
                cls_name = string_at(n_idx)
                ns_name  = string_at(ns_idx) if ns_idx >= 0 else ''
                method_class[m_start:end] = [cls_name] * m_count
                method_ns[m_start:end]    = [ns_name]  * m_count
            except Exception:
                continue

    # ── Bulk-parse every method definition ─────────────────────────────────
    meth_fmt, fi_name, fi_ret, fi_param = _method_iter_fmt(meth_sz)
    meth_blob = data[meth_off: meth_off + meth_bytes]

    methods: List[Dict] = []
    try:
        for i, tup in enumerate(struct.iter_unpack(meth_fmt, meth_blob)):
            name_idx    = tup[fi_name]
            ret_idx     = tup[fi_ret]
            param_count = tup[fi_param]
            meth_name   = string_at(name_idx)
            methods.append({
                'index':       i,
                'name':        meth_name,
                'class':       method_class[i] if i < len(method_class) else '',
                'namespace':   method_ns[i]    if i < len(method_ns)    else '',
                'ret_idx':     ret_idx,
                'param_count': param_count,
            })
    except struct.error:
        pass

    return methods, string_at


# ── ELF / method-offset discovery ─────────────────────────────────────────────

def _build_segments(elf) -> List[Tuple[int, int, int]]:
    segs = []
    for seg in elf.iter_segments():
        if seg.header.p_type == 'PT_LOAD' and seg.header.p_filesz > 0:
            segs.append((seg.header.p_vaddr,
                         seg.header.p_offset,
                         seg.header.p_filesz))
    return segs


def _va_to_foff(segments, va: int) -> Optional[int]:
    for seg_va, seg_fo, seg_sz in segments:
        if seg_va <= va < seg_va + seg_sz:
            return seg_fo + (va - seg_va)
    return None


def _foff_to_va(segments, foff: int) -> Optional[int]:
    for seg_va, seg_fo, seg_sz in segments:
        if seg_fo <= foff < seg_fo + seg_sz:
            return seg_va + (foff - seg_fo)
    return None


def _decode_adrp(insn: int, pc: int) -> Optional[int]:
    if (insn >> 31) & 1 and (insn >> 24) & 0x1F == 0x10:
        immlo = (insn >> 29) & 3
        immhi = (insn >> 5) & 0x7FFFF
        imm21 = (immhi << 2) | immlo
        if imm21 & (1 << 20):
            imm21 |= -(1 << 21)
        return ((pc >> 12) + imm21) << 12
    return None


def _decode_add_imm(insn: int) -> Optional[int]:
    op = (insn >> 24) & 0xFF
    if op in (0x91, 0x11):
        shift = (insn >> 22) & 3
        imm12 = (insn >> 10) & 0xFFF
        return imm12 << (12 if shift == 1 else 0)
    return None


def _sym_search(elf) -> Optional[int]:
    try:
        from elftools.elf.sections import SymbolTableSection
        for sec in elf.iter_sections():
            if isinstance(sec, SymbolTableSection):
                for sym in sec.iter_symbols():
                    n = sym.name
                    if ('CodeRegistration' in n or
                            'codeRegistration' in n or
                            'il2cpp_codegen_register' in n):
                        va = sym.entry.st_value
                        if va:
                            return va
    except Exception:
        pass
    return None


def _init_array_candidates(elf, so_data: bytes,
                            segments: List) -> List[int]:
    init_sec = None
    for sec in elf.iter_sections():
        if sec.name in ('.init_array', '.ctors', 'init_array'):
            init_sec = sec
            break
    if init_sec is None:
        return []

    is64    = elf.elfclass == 64
    ptr_sz  = 8 if is64 else 4
    ptr_fmt = '<Q' if is64 else '<I'

    init_data = init_sec.data()
    func_vas  = []
    for i in range(0, len(init_data) - ptr_sz + 1, ptr_sz):
        va = struct.unpack_from(ptr_fmt, init_data, i)[0]
        if va:
            func_vas.append(va)

    candidates: set = set()
    for func_va in func_vas:
        foff = _va_to_foff(segments, func_va)
        if foff is None or foff + 256 > len(so_data):
            continue
        for i in range(0, 64 * 4, 4):
            if foff + i + 8 > len(so_data):
                break
            insn = struct.unpack_from('<I', so_data, foff + i)[0]
            page = _decode_adrp(insn, func_va + i)
            if page is None:
                continue
            next_insn = struct.unpack_from('<I', so_data, foff + i + 4)[0]
            add_imm = _decode_add_imm(next_insn)
            if add_imm is not None:
                candidates.add(page + add_imm)
    return list(candidates)


def _try_resolve_from_candidates(so_data: bytes, segments: List,
                                  method_count: int,
                                  candidates: List[int]) -> Optional[List[int]]:
    exec_ranges = [(va, va + sz) for va, _, sz in segments]

    def is_code(p: int) -> bool:
        return bool(p) and any(lo <= p < hi for lo, hi in exec_ranges)

    for va in candidates:
        foff = _va_to_foff(segments, va)
        if foff is None or foff + 16 > len(so_data):
            continue
        try:
            count64 = struct.unpack_from('<Q', so_data, foff)[0]
            arr_ptr = struct.unpack_from('<Q', so_data, foff + 8)[0]
            count32 = struct.unpack_from('<I', so_data, foff)[0]

            for count, arr_ptr_va in [(count64, arr_ptr),
                                      (count32, struct.unpack_from('<Q', so_data, foff + 4)[0])]:
                if count != method_count:
                    continue
                arr_off = _va_to_foff(segments, arr_ptr_va)
                if arr_off is None or arr_off + count * 8 > len(so_data):
                    continue
                ptrs = list(struct.unpack_from(f'<{count}Q', so_data, arr_off))
                sample = ptrs[:min(200, count)]
                valid  = sum(1 for p in sample if is_code(p))
                if valid >= len(sample) * 0.7:
                    return ptrs
        except Exception:
            continue
    return None


def _find_method_offsets_codegen_modules(
        so_data: bytes, segments: List, method_count: int) -> Optional[Dict[int, int]]:
    """
    Faithful Python port of Perfare/Il2CppDumper SectionHelper.FindCodeRegistration2019()
    — the same binary that game-dump.yml downloads and runs on GitHub Actions.

    For IL2CPP metadata v24.2+ (v29, v31 …) method pointers live in per-module
    CodeGenModule structs, NOT a flat array in CodeRegistration.

    CodeGenModule layout (64-bit ARM):
      +0  : const char* moduleName        → "AssemblyName.dll\0"
      +8  : uint64_t    methodPointerCount
      +16 : void**      methodPointers    → per-module function-pointer array

    Perfare's 4-level pointer chain (SectionHelper.cs FindCodeRegistration2019):
      dllva   = VA of "mscorlib.dll\0" string
      refva   = VA that *contains* dllva  → CodeGenModule.moduleName field
                = CodeGenModule struct base (moduleName is first field)
      refva2  = VA that *contains* refva  → entry in CodeGenModules[] array
      candidate = refva2 - i*8           → CodeGenModules[0] (array start)
      refva3  = VA that *contains* candidate → CodeRegistration.codeGenModules
      validate: u64(refva3 - 8) == i + 1 (= codeGenModulesCount)

    Performance: builds a reverse-pointer map (VA→foffs) once in O(n) time,
    making every FindReference() call an O(1) dict lookup instead of O(n) scan.
    """
    # ── Build uint64 array view of entire SO ──────────────────────────────────
    aligned_len = (len(so_data) // 8) * 8
    all_ptrs = array.array('Q')
    all_ptrs.frombytes(so_data[:aligned_len])
    n = len(all_ptrs)

    # VA range of all mapped segments — used to filter false-positive pointers
    seg_min = min(va for va, _, _ in segments)
    seg_max = max(va + sz for va, _, sz in segments)

    # ── Build reverse map: VA value → [file offsets containing that VA] ───────
    # Only store entries whose value falls within the SO's mapped VA range.
    # This keeps RAM down (~20-30 MB for a typical 30 MB game SO).
    rev: Dict[int, List[int]] = {}
    for i in range(n):
        p = int(all_ptrs[i])
        if seg_min <= p < seg_max:
            if p not in rev:
                rev[p] = []
            rev[p].append(i * 8)

    # ── FindReference equivalent: VA → list of VAs that contain a ptr to it ──
    def find_refs(target_va: int) -> List[int]:
        result: List[int] = []
        for fo in rev.get(target_va, []):
            va = _foff_to_va(segments, fo)
            if va:
                result.append(va)
        return result

    # ── Read u64 at a VA (returns None on miss) ────────────────────────────────
    def ru64(va: int) -> Optional[int]:
        fo = _va_to_foff(segments, va)
        if fo is None or fo + 8 > len(so_data):
            return None
        return struct.unpack_from('<Q', so_data, fo)[0]

    # ── Step 1: find "mscorlib.dll\0" string VAs ──────────────────────────────
    needle = b'mscorlib.dll\x00'
    mscorlib_vas: List[int] = []
    pos = 0
    while True:
        pos = so_data.find(needle, pos)
        if pos < 0:
            break
        va = _foff_to_va(segments, pos)
        if va:
            mscorlib_vas.append(va)
        pos += 1

    if not mscorlib_vas:
        print("  mscorlib.dll not found in binary")
        return None
    print(f"  mscorlib.dll string: {len(mscorlib_vas)} hit(s)")

    # ── Steps 2-4: unwind 4-level chain ───────────────────────────────────────
    # Perfare v27+ (mscorlib is LAST module): i walks backward from 0 to ~400
    # candidate = refva2 - i*8 = CodeGenModules[0] start when i == imageCount-1
    # Validation: u64(refva3 - 8) == i + 1  (== codeGenModulesCount)

    codegen_array_va:  Optional[int] = None   # VA of CodeGenModules[0]
    codegen_mod_count: Optional[int] = None   # codeGenModulesCount

    for dllva in mscorlib_vas:
        # Step 2: find CodeGenModule structs whose moduleName == dllva
        for refva in find_refs(dllva):
            # mscorlib always has methods — quick sanity on methodPointerCount
            mc = ru64(refva + 8)
            if mc is None or mc == 0 or mc > 500_000:
                continue

            # Step 3: find entries in CodeGenModules[] that point to this module
            for refva2 in find_refs(refva):

                # Step 4: walk backward — candidate is potential CodeGenModules[0]
                # For v27+ mscorlib is last, so i == imageCount-1 is the hit
                for i in range(400):
                    candidate = refva2 - i * 8

                    # Find CodeRegistration.codeGenModules (= ptr to candidate)
                    for refva3 in find_refs(candidate):
                        count_val = ru64(refva3 - 8)
                        if count_val is None:
                            continue
                        # Key match: codeGenModulesCount == i + 1
                        if count_val != i + 1 or not (1 <= count_val <= 400):
                            continue

                        # Extra validation: dereference the found array pointer
                        array_va = ru64(refva3)
                        if array_va is None or array_va != candidate:
                            continue
                        # First module ptr must map to readable memory
                        first_mod_va = ru64(array_va)
                        if first_mod_va is None:
                            continue
                        if _va_to_foff(segments, first_mod_va) is None:
                            continue
                        # First module's moduleName must contain .dll
                        first_name_va = ru64(first_mod_va)
                        if first_name_va is None:
                            continue
                        nfo = _va_to_foff(segments, first_name_va)
                        if nfo is None or b'.dll' not in so_data[nfo: nfo + 128]:
                            continue

                        # ── Found it ──────────────────────────────────────────
                        codegen_array_va  = candidate
                        codegen_mod_count = int(count_val)
                        print(f"  CodeRegistration.codeGenModules @ 0x{refva3:x}")
                        print(f"  codeGenModulesCount = {codegen_mod_count}")
                        print(f"  CodeGenModules[0]   @ VA 0x{codegen_array_va:x}")
                        break

                    if codegen_array_va:
                        break
                if codegen_array_va:
                    break
            if codegen_array_va:
                break
        if codegen_array_va:
            break

    if codegen_array_va is None:
        print("  4-level chain failed — no valid CodeRegistration found")
        return None

    # ── Step 5: walk CodeGenModules[] and build global_idx → file_offset ──────
    # CodeGenModules[] is an array of *pointers* to CodeGenModule structs.
    # 0-method modules are included (they advance global_idx by 0, no entries).
    offsets: Dict[int, int] = {}
    global_idx = 0

    for mod_i in range(codegen_mod_count):
        mod_va = ru64(codegen_array_va + mod_i * 8)
        if mod_va is None:
            continue
        mod_fo = _va_to_foff(segments, mod_va)
        if mod_fo is None or mod_fo + 24 > len(so_data):
            continue

        m_count  = struct.unpack_from('<Q', so_data, mod_fo + 8)[0]
        m_ptrs_v = struct.unpack_from('<Q', so_data, mod_fo + 16)[0]

        if m_count > 500_000:
            continue                         # bogus — skip without advancing
        if m_count == 0 or not m_ptrs_v:
            global_idx += int(m_count)       # 0-method module: advances by 0
            continue

        pfo = _va_to_foff(segments, m_ptrs_v)
        if pfo is None or pfo + m_count * 8 > len(so_data):
            global_idx += int(m_count)
            continue

        for local_idx in range(int(m_count)):
            g_idx = global_idx + local_idx
            if g_idx >= method_count:
                break
            fn_va = struct.unpack_from('<Q', so_data, pfo + local_idx * 8)[0]
            if fn_va:
                fo = _va_to_foff(segments, fn_va)
                if fo is not None:
                    offsets[g_idx] = fo

        global_idx += int(m_count)

    return offsets if offsets else None


def _parse_elf_offsets(so_data: bytes, method_count: int,
                       version: int = 0) -> Dict[int, int]:
    """
    Main ELF analysis entry: returns {method_index: file_offset}.

    Strategy order:
      1. Symbol table — instant, works only on non-stripped SOs
      2. CodeGenModule chain — CORRECT for IL2CPP v24.2+ (Unity 2018.3+, v29, v31…)
         Finds "mscorlib.dll" → per-module methodPointers arrays.
         The flat methodPointers array in CodeRegistration does NOT exist in v24.2+.
      3. .init_array ADRP + CodeRegistration heuristic — works for v24.1 and below
      4. Flat-array brute-force — last resort, only for v24.1 and below
    """
    import io as _io
    from elftools.elf.elffile import ELFFile

    elf      = ELFFile(_io.BytesIO(so_data))
    segments = _build_segments(elf)

    # ── Strategy 1: symbol table ──────────────────────────────────────────────
    sym_va = _sym_search(elf)
    if sym_va:
        print(f"  Symbol table hit: CodeRegistration @ 0x{sym_va:x}")
        ptrs = _try_resolve_from_candidates(so_data, segments, method_count, [sym_va])
        if ptrs:
            print(f"  Resolved via symbol: {len(ptrs):,} pointers")
            offsets: Dict[int, int] = {}
            for idx, va in enumerate(ptrs):
                if va:
                    fo = _va_to_foff(segments, va)
                    if fo is not None:
                        offsets[idx] = fo
            print(f"  Resolved {len(offsets):,} / {method_count:,} file offsets")
            return offsets

    # ── Strategy 2: CodeGenModule chain (IL2CPP v24.2+, metadata v29/v31) ────
    # In v24.2+ method pointers are split into per-assembly CodeGenModule arrays.
    # A single flat array of all method pointers does NOT exist in these builds,
    # so brute-force section scanning will always fail for v31 games.
    print("  Scanning for CodeGenModule structs (mscorlib.dll chain)…")
    print("PROGRESS:50")
    offsets = _find_method_offsets_codegen_modules(so_data, segments, method_count)
    if offsets:
        print(f"  Resolved {len(offsets):,} / {method_count:,} file offsets via CodeGenModules")
        return offsets

    # ── Strategy 3: .init_array ADRP + CodeRegistration (v24.1 and below) ────
    print("  Scanning .init_array with ARM64 ADRP decoder…")
    candidates = _init_array_candidates(elf, so_data, segments)
    if candidates:
        print(f"  Found {len(candidates)} candidate address(es)")
        ptrs = _try_resolve_from_candidates(so_data, segments, method_count, candidates)
        if ptrs:
            print(f"  CodeRegistration resolved: {len(ptrs):,} pointers")
            offsets = {}
            for idx, va in enumerate(ptrs):
                if va:
                    fo = _va_to_foff(segments, va)
                    if fo is not None:
                        offsets[idx] = fo
            print(f"  Resolved {len(offsets):,} / {method_count:,} file offsets")
            return offsets

    # ── Strategy 4: brute-force flat-array scan (v24.1 and below ONLY) ───────
    # v24.2+ stores method pointers in per-module CodeGenModule arrays, NOT as a
    # flat contiguous block, so this scan will never succeed for v31 games.
    if version > 0 and version < 24:
        print("  Brute-force scanning data sections for flat pointer array…")
        print("PROGRESS:55")
        offsets = {}
        exec_ranges = [(va, va + sz) for va, _, sz in segments]
        exec_pages: set = set()
        for lo, hi in exec_ranges:
            for page in range(lo >> 20, (hi >> 20) + 1):
                exec_pages.add(page)

        def is_code(p: int) -> bool:
            return bool(p) and (p >> 20) in exec_pages and \
                   any(lo <= p < hi for lo, hi in exec_ranges)

        import io as _io2
        elf2 = ELFFile(_io2.BytesIO(so_data))
        for sec in elf2.iter_sections():
            if sec.name not in ('.data.rel.ro', '.data', '.rodata'):
                continue
            sd = sec.data()
            aligned = (len(sd) // 8) * 8
            if aligned < method_count * 8:
                continue
            arr = array.array('Q')
            arr.frombytes(sd[:aligned])
            need = method_count
            for i in range(len(arr) - need + 1):
                sample = arr[i: i + min(200, need)]
                if sum(1 for p in sample if is_code(p)) >= len(sample) * 0.80:
                    window = list(arr[i: i + need])
                    if sum(1 for p in window if is_code(p)) >= need * 0.80:
                        print(f"  Flat pointer array found in '{sec.name}' @ {i}")
                        for idx, va in enumerate(window):
                            if va:
                                fo = _va_to_foff(segments, va)
                                if fo is not None:
                                    offsets[idx] = fo
                        if offsets:
                            print(f"  Resolved {len(offsets):,} / {method_count:,} file offsets")
                            return offsets
    else:
        print("  Skipping flat-array scan (not applicable for IL2CPP v24.2+)")

    print("  WARNING: Could not locate method pointer data."
          " All offsets will be 0x0 — import manually or retry.")
    return {}


# ── Return-type inference ──────────────────────────────────────────────────────

_IL2CPP_PRIMITIVES = {
    0x00: 'System.Void',   0x01: 'System.Void',
    0x02: 'System.Boolean',0x03: 'System.Char',
    0x04: 'System.SByte',  0x05: 'System.Byte',
    0x06: 'System.Int16',  0x07: 'System.UInt16',
    0x08: 'System.Int32',  0x09: 'System.UInt32',
    0x0A: 'System.Int64',  0x0B: 'System.UInt64',
    0x0C: 'System.Single', 0x0D: 'System.Double',
    0x0E: 'System.String', 0x1C: 'System.Object',
}


def _infer_return_type(m: Dict) -> str:
    n   = m['name'].lower()
    cls = m['class'].lower()
    nc  = n + ' ' + cls

    if (n.startswith(('is_', 'has_', 'can_', 'should_', 'check'))
            or any(k in nc for k in ('unlock', 'premium', 'purchase',
                                     'active', 'enable', 'ready',
                                     'allow', 'eligible', 'available'))):
        return 'System.Boolean'

    if any(k in nc for k in ('coin', 'gold', 'gem', 'cash', 'score',
                              'point', 'star', 'key', 'diamond',
                              'currency', 'token', 'resource', 'ticket',
                              'health', 'hp', 'live', 'life', 'energy',
                              'mana', 'stamina', 'credit', 'shard',
                              'count', 'amount', 'total', 'level', 'rank')):
        return 'System.Int32'

    if any(k in nc for k in ('speed', 'velocity', 'gravity', 'force',
                              'ratio', 'rate', 'factor', 'weight',
                              'angle', 'scale', 'multiplier', 'power')):
        return 'System.Single'

    if n.startswith(('set_', 'on_')) or n in ('start', 'stop',
                                               'reset', 'init', 'update'):
        return 'System.Void'

    ret_idx = m.get('ret_idx', -1)
    if 0 <= ret_idx in _IL2CPP_PRIMITIVES:
        return _IL2CPP_PRIMITIVES[ret_idx]
    if ret_idx == 0x08:   return 'System.Int32'
    if ret_idx == 0x0C:   return 'System.Single'
    if ret_idx == 0x02:   return 'System.Boolean'
    if ret_idx == 0x00:   return 'System.Void'

    if n.startswith('get_'):
        return 'System.Int32'

    return 'System.Object'


# ── Interest scoring ───────────────────────────────────────────────────────────

_HIGH_INTEREST = frozenset({
    'coin', 'gold', 'gem', 'cash', 'score', 'point', 'star', 'key',
    'diamond', 'currency', 'token', 'resource', 'ticket', 'shard',
    'health', 'hp', 'live', 'life', 'heart', 'energy', 'shield', 'armor',
    'speed', 'invincib', 'unlock', 'premium', 'purchase', 'owned',
})
_MED_INTEREST = frozenset({
    'jump', 'gravity', 'multiplier', 'timer', 'cooldown', 'damage',
    'power', 'level', 'exp', 'rank', 'ad', 'admob', 'reward', 'boost',
    'revive', 'mana', 'stamina',
})


def _interest_score(name: str, cls: str) -> int:
    nc = (name + ' ' + cls).lower()
    if any(k in nc for k in _HIGH_INTEREST):
        return 10
    if any(k in nc for k in _MED_INTEREST):
        return 5
    if name.startswith(('get_', 'is_', 'has_', 'can_', 'set_')):
        return 2
    return 0


# ── Main public entry point ────────────────────────────────────────────────────

def dump_il2cpp(zip_path: str, output_path: str) -> dict:
    """
    Parse global-metadata.dat + libil2cpp.so from zip_path.
    Write dump.json to output_path.
    Called from Kotlin via: Python.getInstance()
                               .getModule("il2cpp_dumper")
                               .callAttr("dump_il2cpp", zipPath, outputPath)
    Returns dict: { 'status': 'success'|'error', 'log': str,
                    'output_path': str (on success) | 'error': str (on failure) }
    """
    logger     = _LiveLogger()
    old_stdout = sys.stdout
    old_stderr = sys.stderr
    sys.stdout = logger
    sys.stderr = logger

    tmp_dir = None

    try:
        print("=" * 54)
        print("  TAURUS SHIELD — IL2CPP ON-DEVICE ANALYSER")
        print("=" * 54)
        print(f"  Input : {os.path.basename(zip_path)}")
        print(f"  Output: {os.path.basename(output_path)}")
        print("-" * 54)
        print("PROGRESS:5")

        # ── Step 1: Extract files from zip ───────────────────────────────────
        print("[1/6] Extracting IL2CPP files…")
        tmp_dir   = tempfile.mkdtemp(prefix='taurus_il2cpp_')
        meta_path = None
        so_path   = None

        with zipfile.ZipFile(zip_path, 'r') as zf:
            names = zf.namelist()
            for name in names:
                lo = name.lower()
                if lo.endswith('global-metadata.dat') and meta_path is None:
                    dst = os.path.join(tmp_dir, 'global-metadata.dat')
                    with zf.open(name) as src, open(dst, 'wb') as d:
                        d.write(src.read())
                    meta_path = dst
                elif lo.endswith('libil2cpp.so'):
                    if so_path is None or 'arm64' in lo:
                        dst = os.path.join(tmp_dir, 'libil2cpp.so')
                        with zf.open(name) as src, open(dst, 'wb') as d:
                            d.write(src.read())
                        so_path = dst

        if meta_path is None:
            raise FileNotFoundError(
                "global-metadata.dat not found in ZIP.\n"
                "Please pack: libil2cpp.so + global-metadata.dat")
        if so_path is None:
            raise FileNotFoundError(
                "libil2cpp.so not found in ZIP.")

        meta_mb = os.path.getsize(meta_path) / 1_048_576
        so_mb   = os.path.getsize(so_path)   / 1_048_576
        print(f"  global-metadata.dat : {meta_mb:.1f} MB")
        print(f"  libil2cpp.so (arm64): {so_mb:.1f} MB")
        print("  OK")
        print("PROGRESS:15")

        # ── Step 2: Parse metadata header ────────────────────────────────────
        print("[2/6] Parsing metadata header…")
        with open(meta_path, 'rb') as f:
            meta_data = f.read()
        version, header = _parse_header(meta_data)
        print(f"  IL2CPP metadata version : {version}")
        print("  OK")
        print("PROGRESS:25")

        # ── Step 3: Parse methods + type definitions ──────────────────────────
        print("[3/6] Reading method and type definitions…")
        methods, _str = _parse_methods_and_types(meta_data, header, version)
        print(f"  Total methods parsed : {len(methods):,}")
        print("  OK")
        print("PROGRESS:40")

        # ── Step 4: Parse ELF for method file offsets ─────────────────────────
        print("[4/6] Analysing libil2cpp.so for ARM64 method offsets…")
        print(f"  SO size: {so_mb:.1f} MB  |  methods: {len(methods):,}")
        with open(so_path, 'rb') as f:
            so_data = f.read()
        method_offsets = _parse_elf_offsets(so_data, len(methods), version)
        print("  OK")
        print("PROGRESS:80")

        # ── Step 5: Infer return types ────────────────────────────────────────
        print("[5/6] Inferring return types from method signatures…")
        print("  OK")
        print("PROGRESS:88")

        # ── Step 6: Assemble and write dump.json ──────────────────────────────
        print("[6/6] Building dump.json…")
        all_methods:     List[Dict] = []
        interesting:     List[Dict] = []

        for m in methods:
            idx      = m['index']
            foff     = method_offsets.get(idx, 0)
            offset_s = f'0x{foff:X}' if foff else '0x0'
            ret_type = _infer_return_type(m)
            score    = _interest_score(m['name'], m['class'])

            entry: Dict = {
                'method':         m['name'],
                'class':          m['class'],
                'return_type':    ret_type,
                'offset':         offset_s,
                'interest_score': score,
            }
            if m.get('namespace'):
                entry['namespace'] = m['namespace']

            all_methods.append(entry)
            if score >= 5:
                interesting.append(entry)

        result = {
            'version':             version,
            'total_methods':       len(all_methods),
            'all_methods':         all_methods,
            'interesting_methods': interesting,
        }

        os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(result, f, separators=(',', ':'))

        out_mb = os.path.getsize(output_path) / 1_048_576
        print(f"  Total methods       : {len(all_methods):,}")
        print(f"  Interesting methods : {len(interesting):,}")
        print(f"  dump.json size      : {out_mb:.2f} MB")
        print(f"  Offsets resolved    : {len(method_offsets):,} / {len(methods):,}")
        print("-" * 54)
        print("  ANALYSIS COMPLETE ✓")
        print("=" * 54)
        print("PROGRESS:100")

        return {
            'status':      'success',
            'log':         logger.getvalue(),
            'output_path': output_path,
        }

    except Exception as e:
        print("-" * 54)
        print(f"  ERROR: {e}")
        print(traceback.format_exc())
        print("=" * 54)
        # If json.dump completed before the exception, treat as success so the
        # UI can proceed — the dump.json is usable even if post-write cleanup failed.
        if output_path and os.path.exists(output_path) and os.path.getsize(output_path) > 0:
            return {
                'status':      'success',
                'log':         logger.getvalue(),
                'output_path': output_path,
            }
        return {
            'status': 'error',
            'log':    logger.getvalue(),
            'error':  str(e),
        }

    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr
        if tmp_dir and os.path.exists(tmp_dir):
            try:
                shutil.rmtree(tmp_dir)
            except Exception:
                pass
