#!/usr/bin/env sh
set -euo pipefail

build_dir="${1:-build}"
toolchain="${2:-}"

configure_env=""
case "$toolchain" in
    "LLVM") configure_env="CC='clang' CC_LD='lld' AR='llvm-ar' STRIP='llvm-strip' OBJCOPY='llvm-objcopy' " ;;
    "GNU")  configure_env="CC='gcc'   CC_LD='ld'  AR='ar'      STRIP='strip'      OBJCOPY='objcopy' "      ;;
esac

configure_cmd="${configure_env}meson setup $build_dir $*"
build_cmd="ninja -C $build_dir"

rm -rf "$build_dir"

echo "Configure project:"
echo "- toolchain: $toolchain"
echo "- build-dir: $build_dir"
echo "$configure_cmd"
eval "$configure_cmd" || exit 1

echo "Build project:"
echo "$build_cmd"
eval "$build_cmd" || exit 1
