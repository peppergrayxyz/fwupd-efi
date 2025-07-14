#!/usr/bin/env sh
set -eu

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

work_dir="${1:-$(pwd)/build}"
ekd2_dir="${2:-/usr/share/edk2}"
arch="${ARCH:-"$(uname -m)"}"

qemu_cmd="qemu-system-$arch"
platform=""
case "$arch" in
    "x86_64")   uefi_arch="x64"   ;;
    "i386"|\
    "i686")     uefi_arch="ia32"   qemu_cmd="qemu-system-i386" ;;
    "arm"*)     uefi_arch="arm";   platform="-machine virt"; qemu_cmd="qemu-system-arm"  ;;
    "aarch64")  uefi_arch="aa64";  platform="-machine virt -cpu neoverse-n1" ;;
    *)          uefi_arch="$arch"; platform="-machine virt" ;;
esac

ovmf_code="$ekd2_dir/$uefi_arch/code.fd"
ovmf_vars="$ekd2_dir/$uefi_arch/vars.fd"
uefi_shell="$ekd2_dir/$uefi_arch/shell.efi"

fwupd_efi="fwupd$uefi_arch.efi"
fwupd_path="$work_dir/efi/$fwupd_efi"
fwupd_log="$work_dir/$fwupd_efi.log"

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
#cp "$uefi_shell" "$boot_dir/boot$uefi_arch.efi"
cp "$fwupd_path" "$drive_dir"

cat >"$drive_dir/startup.nsh" << EOF
@echo -off
echo "<test>"

fs0:\\$fwupd_efi

if %lasterror% ne 0 then
    echo "[Result] %lasterror% (Error)"
else
    echo "[Result] 0x0 (Success)"
endif
@echo "</test>"

# shutdown
reset -s                         
EOF

tree "$drive_dir"

## Run Qemu
qemu_timeout="60s"
qemu_kill="70s"
qemu_monitor_socket="$work_dir/qemu-monitor-socket"

qemu_cmd_str="$(cat << EOF
$qemu_cmd $platform
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

# shellcheck disable=SC2086 
(timeout -k $qemu_kill $qemu_timeout $qemu_cmd_str > /dev/null ) & qemu_pid=$!

if wait $qemu_pid 2>/dev/null; then 
    qemu_res=$?
    echo "Test run finished!"
else
    qemu_res=$?

    echo "Test run interrupted!"
    case "$qemu_res" in
        124) echo "- exited qemu after timeout ($qemu_timeout)" >&2 ;;
        137) echo "- killed qemu after timeout ($qemu_kill)" >&2    ;;
        *)   echo "- failed to start $qemu_cmd" >&2                 ;;
    esac

    exit $qemu_res
fi

