"""Extract ExeFS and RomFS (base 1.0.0) from a Switch 2 .nup package."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys

import zstandard as zstd


NUP_MAGIC = b"NUP\x01"


def _read_name(toc: bytes, pool_off: int, off: int, length: int) -> str:
    return toc[pool_off + off : pool_off + off + length].decode("utf-8", errors="replace")


def extract_nup(nup_path: Path, exefs_out: Path, romfs_out: Path) -> None:
    if not nup_path.is_file():
        raise FileNotFoundError(f"NUP introuvable : {nup_path}")

    with nup_path.open("rb") as f:
        sb = f.read(0x80)
        if sb[:4] != NUP_MAGIC:
            raise ValueError("Fichier .nup invalide (en-tête NUP\\x01 absent).")
        toc_off, toc_size = struct.unpack_from("<QQ", sb, 8)
        f.seek(toc_off)
        toc = f.read(toc_size)

        pkg_cnt, dirs_cnt, files_cnt, pool_off = struct.unpack_from("<IQQQ", toc, 4)
        pos = 0x30
        packages = []
        for _ in range(pkg_cnt):
            tid, _u1, exefs_idx, romfs_idx, ver, kind, _u6 = struct.unpack_from("<QIIIIII", toc, pos)
            packages.append((tid, exefs_idx, romfs_idx, ver, kind))
            pos += 0x40

        # Prefer base game (kind == 0, version == 0) because Wonder recomp targets 1.0.0.
        base_pkgs = [p for p in packages if p[4] == 0 and p[1] != 0xFFFFFFFF]
        if not base_pkgs:
            base_pkgs = [p for p in packages if p[1] != 0xFFFFFFFF and p[4] in (0, 1)]
        if not base_pkgs:
            raise RuntimeError("Aucun package programme ExeFS trouvé dans le .nup.")

        tid, exefs_idx, romfs_idx, ver, kind = min(base_pkgs, key=lambda p: p[3])
        print(f"[extract_nup] Package selectionne: {tid:016X} v{ver} (kind={kind})", flush=True)

        dir_tab = pos
        file_tab = dir_tab + dirs_cnt * 0x18
        child_tab = file_tab + files_cnt * 0x50
        dctx = zstd.ZstdDecompressor()

        def extract_dir(dir_idx: int, dest: Path, count_only: list[int]) -> None:
            dest.mkdir(parents=True, exist_ok=True)
            _n_off, _n_len, first_child, child_count = struct.unpack_from(
                "<IIII", toc, dir_tab + dir_idx * 0x18
            )
            for idx in range(child_count):
                (child_id,) = struct.unpack_from("<I", toc, child_tab + 4 * (first_child + idx))
                if child_id < dirs_cnt:
                    dn_off, dn_len = struct.unpack_from("<II", toc, dir_tab + child_id * 0x18)
                    dname = _read_name(toc, pool_off, dn_off, dn_len)
                    extract_dir(child_id, dest / dname, count_only)
                else:
                    f_idx = child_id - dirs_cnt
                    fn_off, fn_len, uncomp_sz, data_off, comp_sz = struct.unpack_from(
                        "<IIQQQ", toc, file_tab + f_idx * 0x50
                    )
                    fname = _read_name(toc, pool_off, fn_off, fn_len)
                    out_file = dest / fname
                    f.seek(data_off)
                    if comp_sz < uncomp_sz:
                        blob = f.read(comp_sz)
                        data = dctx.decompress(blob, max_output_size=uncomp_sz)
                    else:
                        data = f.read(uncomp_sz)
                    out_file.write_bytes(data)
                    count_only[0] += 1

        exefs_count = [0]
        extract_dir(exefs_idx, exefs_out, exefs_count)
        print(f"[extract_nup] ExeFS extrait ({exefs_count[0]} fichiers) -> {exefs_out}", flush=True)

        if romfs_idx != 0xFFFFFFFF:
            romfs_count = [0]
            extract_dir(romfs_idx, romfs_out, romfs_count)
            print(f"[extract_nup] RomFS extrait ({romfs_count[0]} fichiers) -> {romfs_out}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--nup", required=True)
    ap.add_argument("--exefs", required=True)
    ap.add_argument("--romfs", required=True)
    args = ap.parse_args()
    extract_nup(Path(args.nup), Path(args.exefs), Path(args.romfs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

