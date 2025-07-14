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
arch="${2:-"$(uname -m)"}"
ekd2_dir="${3:-/usr/share/edk2}"

qemu_cmd="qemu-system-$arch"
machine=""
case "$arch" in
    "x86_64")   uefi_arch="x64"   ;;
    "i386"|\
    "i686")     uefi_arch="ia32"                            qemu_cmd="qemu-system-i386" ;;
    "arm"*)     uefi_arch="arm";   machine="-machine virt"; qemu_cmd="qemu-system-arm"  ;;
    "aarch64")  uefi_arch="aa64";  machine="-machine virt" ;;
    *)          uefi_arch="$arch"; machine="-machine virt" ;;
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

# shellcheck disable=SC2086
(timeout -k $qemu_kill $qemu_timeout $qemu_cmd_str > /dev/null) & qemu_pid=$!

if wait $qemu_pid 2>/dev/null; then 
    echo "Test run finished:"
else
    qemu_res=$?

    echo "Test Log:"
    echo "$(cat "$fwupd_log" 2> /dev/null) "

    echo "Test run interrupted:"
    case "$qemu_res" in
        124) echo "$0: exited qemu after timeout ($qemu_timeout)" >&2 ;;
        137) echo "$0: killed qemu after timeout ($qemu_kill)" >&2    ;;
        *)   echo "$0: failed to start $qemu_cmd" >&2                 ;;
    esac
fi

## Eval Result

echo "[Validate Test]"

if ! [ -f "$fwupd_log" ]; then
    echo "test failed (failed to boot test drive)"
    exit 1
fi

##
nl='
'
##
grep_n()
{
    number="$1" haystack="$2"; needle="$3"
    if [ "${haystack#*"$needle"}" != "$haystack" ] || 
    [ "${haystack%"$needle"*}" != "$haystack" ]; then
    echo "$number: $haystack"; return 0;
    else return 1; fi        
}

test_str_1st="<test>"
test_reference=$(cat <<'EOF'
fwupd-efi version
WARNING: No updates to process, exiting in 10 seconds.
EOF
)
test_str_ret="[Result]"
test_str_end="</test>"
test_reference_full="$test_str_1st$nl$test_reference$nl$test_str_ret$nl$test_str_end$nl"

curr_ref_line=""
next_ref_line="$test_reference"
test_result=""
test_passed=true

n=0; started=false; executing=false; completed=false; returned=false; finished=false; 
while IFS= read -r line; do 
    n=$((n+1))
    grep_n "$n" "$line" "$test_str_1st" && { started=true; }
    { $executing || { $started && ! $finished; }; } && test_result="$test_result$line$nl"
    grep_n "$n" "$line" "$test_str_ret" && { returned=true; executing=false; }
    grep_n "$n" "$line" "$test_str_end" && { finished=true; executing=false; }

    if $started || $executing; then 
        if ! $executing; then executing=true; else
            if ! grep_n "$n" "$line" "$curr_ref_line"; then
                test_passed=false
                echo "$n expected: $curr_ref_line"
                echo "$n found   : $line"
            fi
            if [ "$curr_ref_line" = "$next_ref_line" ]; then
                executing=false; completed=true;
            fi
        fi
        curr_ref_line="${next_ref_line%%"$nl"*}"
        next_ref_line="${next_ref_line#"$curr_ref_line$nl"}"
    fi
done < "$fwupd_log"

echo "[Result]"

if ! $test_passed; then                    echo "failed (see above)";
elif ! $started;   then test_passed=false; echo "failed to start"; 
elif ! $finished;  then test_passed=false; echo "failed to complete"; 
elif ! $returned;  then test_passed=false; echo "failed to return with expected status"; 
elif ! $completed; then test_passed=false; echo "failed to match all tests";
else                                       echo "passed"; fi

if ! $test_passed; then
    echo "[Ref]"; echo "$test_reference_full"
    echo "[Log]"; if [ -n "$test_result" ]; then echo "$test_result"; else cat "$fwupd_log"; fi
fi

$test_passed || exit 1
true
