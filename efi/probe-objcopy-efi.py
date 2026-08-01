#!/usr/bin/env python3

import subprocess
import sys
import argparse
import tempfile
import pathlib
import pefile


def _probe_objcopy(args) -> int:

    with tempfile.TemporaryDirectory(prefix="objcopy-efi-probe-") as tmp:
        tmpdir = pathlib.Path(tmp)

        obj_file = tmpdir / "probe.o"
        elf_file = tmpdir / "probe.so"
        efi_file = tmpdir / "probe.efi"

        efi_src = b"""
            typedef __UINTPTR_TYPE__ EFI_STATUS;
            EFI_STATUS _relocate(void *base, void *dyn, void *image, void *systab) { return 0; }
            EFI_STATUS efi_main(void *image, void *systab) { return 0; }
            """

        cc_cmd = args.cc.split() + [
            "-x",
            "c",
            "-c",
            "-fno-stack-protector",
            "-fPIC",
            "-o",
            str(obj_file),
            "-",
        ]
        try:
            subprocess.run(cc_cmd, input=efi_src, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"probe compile failed: {error}", file=sys.stderr)
            return 2

        ld_cmd = args.cc.split() + [
            "-nostdlib",
            "-shared",
            "-Wl,-Bsymbolic",
            "-Wl,-znocombreloc",
            "-Wl,-e,_start",
            f"-Wl,-T,{args.lds}",
            str(args.crt0),
            str(obj_file),
            "-o",
            str(elf_file),
        ]
        try:
            subprocess.run(ld_cmd, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"probe compile failed: {error}", file=sys.stderr)
            return 2

        objcopy_cmd = args.objcopy.split() + [
            "-O",
            args.target,
            str(elf_file),
            str(efi_file),
        ]

        result = subprocess.run(objcopy_cmd, check=False)
        if result.returncode != 0:
            return result.returncode

        try:
            pefile.PE(str(efi_file))
        except pefile.PEFormatError as error:
            print(f"invalid EFI PE image: {error}", file=sys.stderr)
            return 1

        return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cc", default="gcc", help="Compiler to use ")
    parser.add_argument("--objcopy", default="objcopy", help="Objcopy binary to use")
    parser.add_argument("--target", default="efi-app-x86_64", help="EFI output target")
    parser.add_argument("--lds", default="efi.lds", help="EFI linker script")
    parser.add_argument("--crt0", default="crt0.o", help="EFI C runtime initialization")

    _args = parser.parse_args()
    res = _probe_objcopy(_args)

    sys.exit(res)
