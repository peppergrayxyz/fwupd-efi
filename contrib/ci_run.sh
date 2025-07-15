#!/usr/bin/env sh
ci_run()
{
###
#
#   Copyright (c) 2025 Pepper Gray <hello@peppergray.xyz>
#   SPDX short identifier: Apache-2.0
#
#   ci_run.sh - run artifact on platform 
#
#   usage: ./contrib/ci_run.sh <work-dir> <artifact> <qemu-args...>
#
#   args:
#   work-dir    directory that contains <artifact> and is used to create the test drive, default: ./build
#   artifact    file name (prefix) to test, default: (prefix) artifact{UEFI_ARCH}.efi
#   qemu-args   are forwarded to qemu
#
#   steps:
#   1. Create a test drive
#       drive
#       ├── EFI
#       │   └── BOOT
#       |       └── boot{UEFI_ARCH}.efi (uefi-shell, optional)
#       ├── <artifact>{UEFI_ARCH}.efi
#       └── startup.nsh
#   2. run it using qemu-system-$arch and log to <work-dir>/<artifact>-log
#
#   CONF-VARS:
#
#   ARCH        architecture of qemu-system-* (e.g. x86_64, i386, aarch64), default: host architecture
#
#   QEMU:
#   PLATFORM    override platform passed to qemu
#   OUT_FILE    redirect qemu output to file (unset for stdout), default: /dev/null
#   MONSOCK     socket to connect to qemu monitor, default: <work-dir>/qemu-monitor-socket
#   DURQ        timeout to quit qemu, unset to deactivate, default: 60s
#   DURK        timeout to kill qemu, unset to deactivate, default: 70s
#
#   UEFI:
#   UEFI_ARCH   architecture of firmware and and artifact (e.g. x64, ia32, aa64), default: host architecture
#   EDK2_DIR    where to search for ovmf firmware, default: /usr/share/edk2
#   OVMF_CODE   name of firmware code file, default: code.fd
#   OVMF_VARS   name of firmware vars file, default: vars.fd
#   UEFI_SHELL  name of uefi-shell file,    default: shell.efi
#
#   DRIVE:
#   DRIVE_DIR   path to test drive, default: work-dir/drive
#   RMLOG       remove (previous) log,   default: true
#   RMDRIVE     remove (previous) drive, default: true
#   RUN_SCRIPT  script to start,         default: unset (script creates startup.nsh)
#   CP_ARTIFACT copy artifact to drive,  default: true
#   CP_SHELL    copy uefi shell to test drive (don't rely on shell being present in firmware), default: true
#
#   RUN:
#   USE_TAGS    use tags to enclose output (unset to disable tagging), default: true
#   TAGS_RUN    run     output, default: run    
#   TAGS_CMD    command output, default: cmd
#   TAGS_CRES   command retval, default: cmd-res
#   TAGS_LOG    qemu log data,  default: log
#   TAGS_LRES   qemu retval,    default: log-res
#   EOF_DELIM   heredoc deliminator for log output, defauilt: EOF
#
###

set -eu
{ [ -n "${DEBUG:-}" ] || [ -n "${DEBUG_CI_RUN:-}" ]; } && set -x

## functions

setduration()
{
    set -e; t_durk="$1"; t_durq="$2"; shift 2; 
    ( "$@" ) & t_cmd_pid=$!
    [ -n "$t_durq" ] && ( sleep "$t_durq" && kill -HUP $t_cmd_pid ) 2>/dev/null & t_watcher_quit=$!
    [ -n "$t_durk" ] && ( sleep "$t_durk" && kill -9   $t_cmd_pid ) 2>/dev/null & t_watcher_kill=$!
    wait $t_cmd_pid 2>/dev/null || return $?
    [ -n "$t_durq" ] && { pkill -HUP -P $t_watcher_quit || true; }
    [ -n "$t_durk" ] && { pkill -HUP -P $t_watcher_kill || true; }
    return 0
}
read_d() {
    set -e; r_d_var="$1"; eval "$r_d_var=";
    while IFS= read -r r_d_line || [ -n "$r_d_line" ]; do
        eval "$r_d_var=\${$r_d_var}\$r_d_line\$'\\n'"
    done; eval "$r_d_var=\${$r_d_var%$'\\n'}"
}
print_check_result() 
{
    set -e; dep_name="$1"; dep_path="$2"; dep_res="$3"
    printf " - %s: %s (%s)\n" "$dep_name" "$( [ "$dep_res" -eq 0 ] && echo "found" || echo "not found")" "$dep_path"
    return "$dep_res"
}
check_cmd() 
{
    set -e; dep_name="$1"; dep_cmd="$2"
    dep_path="$(command -v "$dep_cmd")"; dep_res=$?
    [ $dep_res -ne 0 ] && dep_path="$dep_cmd"
    print_check_result "$dep_name" "$dep_path" "$dep_res"
}
check_file()
{
    set -e; dep_name="$1"; dep_path="$2"
    [ -f "$dep_path" ] && dep_res=0 || dep_res=1
    print_check_result "$dep_name" "$dep_path" "$dep_res"
}

## args

if [ $# -lt 1 ]; then
    echo "usage: $0 <artifact(prefix)> <work-dir> <qemu-args...>" >&2
    return 2
fi

artifact="${1}"
work_dir="${2:-"./build"}"
shift || true
shift || true
qemu_args="$*"

## vars

# arch
arch="${ARCH:-"$(uname -m)"}"

# qemu
platform=""

case "$arch" in
    "x86_64")   uefi_arch="x64" ;;
    "i386"|\
    "i686")     uefi_arch="ia32"                             arch="i386" ;;
    "arm"*)     uefi_arch="arm";   platform="-machine virt"; arch="arm"  ;;
    "aarch64")  uefi_arch="aa64";  platform="-machine virt -cpu cortex-a57" ;; # qemu#3034
    *)          uefi_arch="$arch"; platform="-machine virt" ;;
esac
qemu_cmd="qemu-system-$arch"

platform="${PLATFORM:-$platform}"
[ -z ${OUT_FILE+x} ] && out_file="/dev/null" || out_file="$OUT_FILE"
qemu_monitor_socket="${MONSOCK:-"$work_dir/qemu-monitor-socket"}"

qemu_durq="${DURQ:-60s}"
qemu_durk="${DURK:-70s}"

# uefi
uefi_arch="${UEFI_ARCH:-"$uefi_arch"}"
ekd2_dir="${EDK2_DIR:-/usr/share/edk2}"

ovmf_code="$ekd2_dir/$uefi_arch/${OVMF_CODE:-code.fd}"
ovmf_vars="$ekd2_dir/$uefi_arch/${OVMF_VARS:-vars.fd}"
uefi_shell="$ekd2_dir/$uefi_arch/${UEFI_SHELL:-shell.efi}"

# drive
drive_dir="${DRIVE_DIR:-"$work_dir/drive"}"
rm_log="${RMLOG:-false}"
rm_drive="${RMDRIVE:-true}"
run_script="${RUN_SCRIPT:-}"
cp_artifact="${CP_ARTIFACT:-true}"
cp_shell="${CP_SHELL:-true}"

# run
use_tags="${USE_TAGS:-true}"
tags_run="${TAGS_RUN:-"run"}"
tags_cmd="${TAGS_CMD:-"cmd"}"
tags_cres="${TAGS_CRES:-"cmd-res"}"
tags_log="${TAGS_LOG:-"log"}"
tags_lres="${TAGS_LRES:-"log-res"}"
eof_delim="${EOF_DELIM:-"EOF"}"

# artifact
[ -f "$artifact" ] || artifact="$artifact$uefi_arch.efi" # (prefix)
run_artifact="$work_dir/efi/$artifact"
run_log="$work_dir/$artifact.log"

## check dependencies
echo "Run Artifact on Platform"
echo " - artifact    : $artifact"
echo " - work-dir    : $work_dir"
echo " - arch        : $arch"
[ -n "$qemu_args" ] && {
echo " - qemu args   : $qemu_args"
}

echo "Check dependencies:"
check_cmd  "qemu        " "$qemu_cmd"     || return 1
check_file "code        " "$ovmf_code"    || return 1
check_file "vars        " "$ovmf_vars"    || return 1
$cp_shell && {
check_file "shell       " "$uefi_shell"   || return 1; }
check_file "artifact    " "$run_artifact" || return 1
[ -n "$run_script" ] && {
check_file "run_script  " "$run_script"   || return 1; }

## create env
echo "Create Environment:"

# delete previos log
$rm_log && rm -rf "$run_log"

# setup drive
echo " - drive-dir   : $drive_dir"
echo " - run script  : ${run_script:-"(create)"}"
! $cp_shell && {
echo " - copy shell  : $cp_shell"; }
! $cp_artifact && {
echo " - cp artifact : $cp_artifact"; }

echo "Creating drive:"
$rm_drive && rm -v -rf "$drive_dir"
boot_dir="$drive_dir/EFI/BOOT"
mkdir -v -p "$boot_dir"

# create startup script
if [ -z "$run_script" ]; then
    startup_nsh=""
    read_d "startup_nsh" << EOF
@echo -off

$( $use_tags && echo "echo \"<$tags_cmd>\"")
fs0:\\$artifact
$( $use_tags && echo "echo \"</$tags_cmd><$tags_cres>%lasterror%</$tags_cres>\"" )

reset -s
EOF
    echo "$startup_nsh" > "$drive_dir/startup.nsh"
fi

# copy files
[ -n "$run_script" ] && cp -v "$run_script"   "$drive_dir/startup.nsh";
$cp_artifact         && cp -v "$run_artifact" "$drive_dir"
$cp_shell            && cp -v  "$uefi_shell"   "$boot_dir/boot$uefi_arch.efi";

echo "Drive Content:"
tree "$drive_dir"

## run qemu
read_d "qemu_cmd_str" << EOF
$qemu_cmd $platform \\
 -drive if=pflash,format=raw,unit=0,file=$ovmf_code,readonly=on \\
 -drive if=pflash,format=raw,unit=1,file=$ovmf_vars,snapshot=on \\
 -drive file=fat:rw:$drive_dir,format=raw,media=disk,if=virtio \\
 -chardev stdio,id=char0,logfile=$run_log,signal=off \\
 -serial chardev:char0 -display none \\
 -monitor unix:$qemu_monitor_socket,server,nowait \\
 -nodefaults -nographic
EOF
[ -n "$qemu_args" ] && qemu_cmd_str="$qemu_cmd_str $(echo " \\"; echo " $qemu_args")"
[ -n "$out_file"  ] && qemu_cmd_str="$qemu_cmd_str $(echo " \\"; echo " > $out_file")"

echo "Run Command:"
echo "'$qemu_cmd_str'"

echo "Starting qemu:"
[ -n "$out_file" ] && 
echo " - output      : $out_file"
echo " - timeout     : quit: $qemu_durq, kill: $qemu_durk"
echo " - log         : 'tail -f $run_log'"
echo " - monitor     : 'socat -,echo=0,icanon=0 unix-connect:$qemu_monitor_socket'"

if setduration "$qemu_durk" "$qemu_durq" eval "eval \$(echo \"$qemu_cmd_str\")"; then
    qemu_res=$?
    echo "Run completed:"
else
    qemu_res=$?
    echo "Run interrupted:"
    case "$qemu_res" in
        124) echo "- exited qemu after timeout ($qemu_res)" >&2 ;;
        137) echo "- killed qemu after timeout ($qemu_res)" >&2 ;;
        *)   echo "- failed to start $qemu_cmd ($qemu_res)" >&2 ;;
    esac
fi

res=0
logfile_txt=" - log         :"
## process log
if ! $use_tags; then
    echo "$logfile_txt not processed"
else
    log_raw=""; log_new=""; has_run_log=false
    [ -f "$run_log" ] && has_run_log=true
    $has_run_log && read_d "log_raw" < "$run_log"

    # add tags
    read_d "log_new" << EOF
<$tags_run>
<$tags_log>$( $has_run_log && [ -n "$log_raw" ] && echo ""; $has_run_log && echo "$log_raw"; echo "</$tags_log>"; )
<$tags_lres>$qemu_res</$tags_lres>
</$tags_run>
EOF
    # write new log
    echo "$log_new" > "$run_log"

    # evaluate tags

    f="$logfile_txt failed to"
                                           ! $has_run_log             && { echo "$f start qemu";     return 1; }
                                          [ -z "$log_raw" ]           && { echo "$f boot";           return 1; }
    logcmd1="${log_raw#*"<$tags_cmd>"}";  [ "$logcmd1" = "$log_raw" ] && { echo "$f start script";   return 1; }
    log_cmd="${logcmd1%"</$tags_cmd>"*}"; [ "$log_cmd" = "$logcmd1" ] && { echo "$f finish script";  res=1;    }

    [ $res -eq 0 ] && echo "$logfile_txt found"
    echo "Artifact Output:"
    echo "<<$eof_delim$log_cmd$eof_delim"
fi

return $res

###
}; [ -n "${SOURCED:-}" ] || ci_run "$@"
