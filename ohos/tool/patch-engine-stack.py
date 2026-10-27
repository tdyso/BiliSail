#!/usr/bin/env python3
"""Patch libflutter.so so the Dart UI isolate is not capped to a 128 KB stack.

KaihongOS x86 microLIBc reports the main thread stack as 131072 bytes from
``pthread_getattr_np`` (the value is captured while the initial stack mapping
is still small and never refreshed).  The OHOS Flutter engine runs the Dart
UI isolate on the platform (main) thread, and the VM derives its stack limit
from that report in ``third_party/dart/runtime/vm/os_thread.cc``:

    margin  = min(131072, f(stack_size))      # 0x20000 constant
    limit   = stack_lower + margin            # stack_lower from musl
    if (current_sp <= limit) -> StackOverflow

With stack_size == 131072 the usable stack is a few KB, so any non-trivial
widget tree overflows during its first build.  The kernel itself grows the
main stack on demand up to RLIMIT_STACK (8 MB), so only the VM's view of the
bounds is wrong.

The patch rewrites the bounds computation in the OSThread initializer to use
the live stack pointer:

    upper = rsp
    lower = rsp - 6 MB

which leaves ~6 MB of headroom while staying clear of the kernel's real stack
bottom.  This is an engine-level workaround: re-apply it after every
``flutter build hap`` and drop it once the platform fixes the musl report or
the engine moves the UI isolate to its own pthread.

Usage:
    python3 ohos/tool/patch-engine-stack.py                # patch + sign
    python3 ohos/tool/patch-engine-stack.py --no-sign      # patch only
"""

import argparse
import os
import subprocess
import sys
import zipfile

# The sequence itself identifies the site, so an engine update needs a new
# entry instead of new absolute addresses. Each entry is
# (description, original bytes, patched bytes):
#
# - Engine 57b612dc (22 MB libflutter.so): OSThread::stack_limit_ at 0x78,
#   stack size at 0x80.
# - Engine shipped from 2026-10-26 (21 MB libflutter.so): stack_base_ at 0x70,
#   stack_limit_ at 0x78, stack_headroom_ at 0x80.
#
# Originals, right after pthread_attr_getstack returns the (stale) bounds:
#   mov 8(%rsp),%rbx ; mov %rbx,<limit> ; mov (%rsp),%rax
#   lea (%rax,%rbx),%rcx ; mov %rcx,<base>
# The replacement keeps the stored fields consistent with a 6 MB window that
# ends at the live stack pointer, which the kernel grows on demand.
STACK_HEADROOM = 0x600000

PATCHES = [
    (
        "engine 57b612dc (limit at 0x78, base at 0x80)",
        bytes.fromhex("488b5c240849899f80000000488b0424488d0c1849894f78"),
        # mov %rsp,%rbx / mov %rbx,120(%r15) / sub $0x600000,%rbx /
        # mov %rbx,128(%r15) / nop nop nop
        bytes.fromhex(
            "4889e3"
            "49895f78"
            "4881eb00006000"
            "49899f80000000"
            "909090"
        ),
    ),
    (
        "engine 2026-10 (base at 0x70, limit at 0x78)",
        bytes.fromhex("488b5c240849895f78488b0424488d0c1849894f70"),
        # mov %rsp,%rbx / mov %rbx,112(%r15) / sub $0x600000,%rbx /
        # mov %rbx,120(%r15) / nop nop nop
        bytes.fromhex(
            "4889e3"
            "49895f70"
            "4881eb00006000"
            "49895f78"
            "909090"
        ),
    ),
]

ABI = "x86_64"


def apply_patch(data):
    for description, _, replacement in PATCHES:
        if data.find(replacement) >= 0:
            print("libflutter.so already patched (%s), reusing as-is" % description)
            return bytes(data)
    for description, original, replacement in PATCHES:
        offset = data.find(original)
        if offset < 0:
            continue
        if data.find(original, offset + 1) >= 0:
            raise SystemExit(
                "ambiguous engine build: %s appears more than once" % description
            )
        patched = bytearray(data)
        patched[offset:offset + len(original)] = replacement
        print(
            "patched stack bounds at file offset %#x (%s, headroom %d MB)"
            % (offset, description, STACK_HEADROOM >> 20)
        )
        return bytes(patched)
    raise SystemExit(
        "unexpected engine build: no known stack-bounds sequence found; "
        "add the new sequence to PATCHES"
    )


def patch_hap(hap_path, out_path):
    with zipfile.ZipFile(hap_path, "r") as source:
        target = "libs/%s/libflutter.so" % ABI
        names = source.namelist()
        if target not in names:
            raise SystemExit("%s not found in %s" % (target, hap_path))
        entries = []
        for item in source.infolist():
            payload = source.read(item.filename)
            if item.filename == target:
                payload = apply_patch(payload)
            entries.append((item, payload))
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as output:
        for item, payload in entries:
            output.writestr(item, payload)
    print("wrote %s" % out_path)


def sign(in_path, out_path, signing_dir, java, sign_tool, key_alias, passwords):
    command = [
        java, "-jar", sign_tool, "sign-app",
        "-keyAlias", key_alias,
        "-signAlg", "SHA256withECDSA",
        "-mode", "localSign",
        "-appCertFile", os.path.join(signing_dir, "app-debug-chain.cer"),
        "-profileFile", os.path.join(signing_dir, "app-debug-pemfinal.p7b"),
        "-inFile", in_path,
        "-outFile", out_path,
        "-keystoreFile", os.path.join(signing_dir, "OpenHarmony.p12"),
        "-keystorePwd", passwords[0],
        "-keyPwd", passwords[1],
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0 or "sign-app success" not in result.stdout:
        sys.stderr.write(result.stdout[-2000:] + result.stderr[-2000:])
        raise SystemExit("hap-sign-tool failed")
    print("signed %s" % out_path)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ohos_dir = os.path.dirname(here)
    project_dir = os.path.dirname(ohos_dir)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hap", default=os.path.join(
        project_dir, "build", "ohos", "hap", "entry-default-signed.hap"))
    parser.add_argument("--out", default=None)
    parser.add_argument("--java", default="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java")
    parser.add_argument("--sign-tool", default=(
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony"
        "/toolchains/lib/hap-sign-tool.jar"))
    parser.add_argument("--signing-dir", default=os.path.join(ohos_dir, "signing"))
    parser.add_argument("--key-alias", default="bilisail debug key")
    parser.add_argument("--store-password", default="123456")
    parser.add_argument("--key-password", default="123456")
    parser.add_argument("--no-sign", action="store_true")
    parser.add_argument("--unpacked-so", default=None,
                        help="patch this libflutter.so in place instead of a HAP")
    args = parser.parse_args()

    if args.unpacked_so:
        with open(args.unpacked_so, "rb") as handle:
            patched = apply_patch(handle.read())
        with open(args.unpacked_so, "wb") as handle:
            handle.write(patched)
        return

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.hap)),
                                   "entry-default-stackpatched.hap")
    unsigned = out + ".unsigned"
    patch_hap(args.hap, unsigned)
    if args.no_sign:
        os.replace(unsigned, out)
        print("skipped signing")
        return
    sign(unsigned, out, args.signing_dir, args.java, args.sign_tool,
         args.key_alias, (args.store_password, args.key_password))
    os.remove(unsigned)


if __name__ == "__main__":
    main()
