#!/usr/bin/env sh
set -eu

if command -v git >/dev/null 2>&1; then
    # disable the safe directory feature
    git config --global safe.directory "*"
fi

set_env() {
    for env_assignment do
        case $env_assignment in
            *=*)
                env_var=${env_assignment%%=*}
                env_val=${env_assignment#*=}
                ;;
            *)
                printf 'Invalid environment assignment: %s\n' "$env_assignment" >&2
                return 2
                ;;
        esac

        case $env_var in
            '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*)
                printf 'Invalid environment variable name: %s\n' "$env_var" >&2
                return 2
                ;;
        esac

        eval "env_current=\${$env_var-}"

        if [ -n "$env_current" ]; then
            printf '%s=%s (overwrites default "%s")\n' "$env_var" "$env_current" "$env_val"
        elif [ -n "$env_val" ]; then
            export "$env_var=$env_val"
            printf '%s=%s\n' "$env_var" "$env_val"
        fi
    done
}

case "${TARGET:-}" in
    gnu*)
        set_env CC=gcc
        set_env OBJCOPY=objcopy
        set_env AR=ar
        set_env STRIP=strip
    ;;
    llvm*)
        set_env CC=clang
        set_env CC_LD=lld
        set_env OBJCOPY=llvm-objcopy
        set_env AR=llvm-ar
        set_env STRIP=llvm-strip
        set_env MESON_ARGS="-Dc_link_args=--rtlib=compiler-rt"
    ;;
    none)
        unset CC
        unset CC_LD
        unset OBJCOPY
        unset AR
        unset STRIP
    ;;
    *)
    ;;
esac

echo "Running on: $(uname -m)"

rm -rf build/

# shellcheck disable=SC2086
meson setup build ${MESON_ARGS:-} || {
    status=$?
    logfile="./build/meson-logs/meson-log.txt"
    [ -f "$logfile" ] && cat "$logfile"
    exit "$status"
}
ninja -C build
