#!/usr/bin/env sh
set -eu

work_dir="${1:-$(pwd)/build}"
arch="${2:-"$(uname -m)"}"
ekd2_dir="${3:-/usr/share/edk2}"

machine=""
case "$arch" in
    "x86_64")   uefi_arch="x64"   ;;
    "i386")     uefi_arch="ia32"  ;;
    "aarch64")  uefi_arch="aa64"; machine="-machine virt" ;;
    *)          uefi_arch="$arch" ;;
esac

fwupd_efi="fwupd$uefi_arch.efi"
fwupd_path="$work_dir/efi/$fwupd_efi"
fwupd_log="$work_dir/$fwupd_efi.log"
qemu_cmd="qemu-system-$arch"

ovmf_code="$ekd2_dir/$uefi_arch/OVMF_CODE.fd"
ovmf_vars="$ekd2_dir/$uefi_arch/OVMF_VARS.fd"
uefi_shell="$ekd2_dir/$uefi_arch/shell.efi"

check_print() 
{
    dep_name="$1"; dep_path="$2"; dep_res="$3"
    printf " - %s: %s (%s)\n" "$dep_name" "$( [ "$dep_res" -eq 0 ] && echo "found" || echo "not found")" "$dep_path"
    return "$dep_res"
}
check_cmd() 
{
    dep_name="$1"; dep_cmd="$2"
    dep_path="$(command -v "$dep_cmd")"; dep_res=$?
    [ $dep_res -ne 0 ] && dep_path="$dep_cmd"
    check_print "$dep_name" "$dep_path" "$dep_res"
}
check_dep()
{
    dep_name="$1"; dep_path="$2"
    [ -f "$dep_path" ] && dep_res=0 || dep_res=1
    check_print "$dep_name" "$dep_path" "$dep_res"
}

echo "Testing on $arch in $work_dir:"

check_cmd "qemu      " "$qemu_cmd"   || exit 1
check_dep "ovmf_code " "$ovmf_code"  || exit 1
check_dep "ovmf_code " "$ovmf_vars"  || exit 1
check_dep "uefi_shell" "$uefi_shell" || exit 1
check_dep "fwupd_efi " "$fwupd_path" || exit 1

## Create test env

echo "Creating drive:"
drive_dir="$work_dir/drive"
rm -rf "$drive_dir"
boot_dir="$drive_dir/EFI/BOOT"
mkdir -p "$boot_dir"
cp "$uefi_shell" "$boot_dir/boot$uefi_arch.efi"
cp "$fwupd_path" "$drive_dir"

cat >"$drive_dir/startup.nsh" << EOF
@echo -off
echo <test>

fs0:\\$fwupd_efi

if %lasterror% ne 0 then
    echo [Error] LastError = %lasterror%
else
    echo [OK] Status = 0 [Success]
endif
@echo </test>

# shutdown
reset -s                         
EOF

tree "$drive_dir"

## Run
qemu_timeout="30s"
qemu_kill="1m"
qemu_monitor_socket="$work_dir/qemu-monitor-socket"

qemu_cmd_str="$(cat << EOF
$qemu_cmd $machine
 -drive if=pflash,format=raw,unit=0,file=$ovmf_code,readonly=on
 -drive if=pflash,format=raw,unit=1,file=$ovmf_vars,snapshot=on
 -drive file=fat:rw:$drive_dir,format=raw,media=disk,if=virtio
 -chardev stdio,id=char0,logfile=$fwupd_log,signal=off
 -serial chardev:char0 -display none
 -monitor unix:$qemu_monitor_socket,server,nowait
 -nodefaults -nographic 
EOF
)"

echo "Starting test (timeout: $qemu_timeout, kill after $qemu_kill):"
rm -f "$fwupd_log"
echo "Command: $qemu_cmd_str"
echo "Log    : 'tail -f $fwupd_log'"
echo "Monitor: 'socat -,echo=0,icanon=0 unix-connect:$qemu_monitor_socket'"

(timeout -k $qemu_kill $qemu_timeout $qemu_cmd_str > /dev/null) & qemu_pid=$!

if wait $qemu_pid 2>/dev/null; then 
    echo "Test run finished:"
else
    qemu_res=$?

    echo "Test Log:"
    printf "%s\n" "$(cat "$fwupd_log" 2> /dev/null)"

    echo "Test run interrupted:"
    case "$qemu_res" in
        124) echo "$0: exited qemu after timeout ($qemu_timeout)" >&2 ;;
        137) echo "$0: killed qemu after timeout ($qemu_kill)" >&2    ;;
        *)   echo "$0: failed to start $qemu_cmd" >&2                 ;;
    esac
fi

## Eval Result

if ! [ -f "$fwupd_log" ]; then
  echo "test failed (failed to boot test drive)"
  return 1
fi

fwupd_version=$(meson introspect meson.build --projectinfo --indent)
fwupd_version=${fwupd_version#*\"version\"}
fwupd_version=${fwupd_version#*\"}
fwupd_version=${fwupd_version%%\"*}

fwupd_ref="fwupd-efi version $fwupd_version WARNING: No updates to process, exiting in 10 seconds. [Error] LastError = 0x2"
fwupd_re0=$(tr '\n' ' ' < "$fwupd_log" |  tr -d '\0-\31' | tr -d '\255-\377')
fwupd_re1="${fwupd_re0##*<test> }"
fwupd_res="${fwupd_re1%% </test>*}"

if [ -z "$fwupd_re0" ] || [ "$fwupd_re1" = "$fwupd_re0" ] ; then
  echo "test failed (failed to start)"
  return 1
fi

if [ "$fwupd_res" = "$fwupd_re1" ] ; then
  echo "test failed (failed to complete)"
  return 1
fi

if [ "$fwupd_res" != "$fwupd_ref" ]; then
    echo "expected: $fwupd_ref"
    echo "saw     : $fwupd_res"
    echo "test failed"
    return 1
fi

echo "test passed"
return 0
