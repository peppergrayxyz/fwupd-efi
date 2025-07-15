#!/usr/bin/env sh
set -eu 

if [ $# -lt 1 ]; then
    echo "usage $0 <log-file>" >&2
    exit 1
fi

fwupd_log="$1"
echo "[Validate Test]"
echo "- log: $fwupd_log"

## Constants
##
nl='
'
##

## Functions
grep_n()
{
    number="$1" haystack="$2"; needle="$3"
    if [ "${haystack#*"$needle"}" != "$haystack" ] || 
    [ "${haystack%"$needle"*}" != "$haystack" ]; then
    echo "$number: $haystack"; return 0;
    else return 1; fi        
}

## Ref Data
test_str_1st="<cmd>"
test_reference=$(cat <<'EOF'
fwupd-efi version
WARNING: No updates to process, exiting in 10 seconds.
EOF
)
test_str_ret="<cmd-res>"
test_str_end="</cmd>"
test_reference_full="$test_str_1st$nl$test_reference$nl$test_str_ret$nl$test_str_end$nl"

## Variables
curr_ref_line=""
next_ref_line="$test_reference"
test_result=""
test_passed=true
n=0; started=false; testing=false; executing=false; completed=false; returned=false; finished=false; 

## Parse test data
while IFS= read -r line; do 
    n=$((n+1))
    grep_n "$n" "$line" "$test_str_1st" && { started=true; }
    { $executing || { $started && ! $finished; }; } && test_result="$test_result$line$nl"
    grep_n "$n" "$line" "$test_str_ret" && { returned=true; executing=false; }
    grep_n "$n" "$line" "$test_str_end" && { finished=true; executing=false; }

    if $started || $executing; then 
        if { $started && ! $testing; } || $executing; then
            curr_ref_line="${next_ref_line%%"$nl"*}"
            next_ref_line="${next_ref_line#"$curr_ref_line$nl"}"
        fi
        if ! $testing; then testing=true; else
            if grep_n "$n" "$line" "$curr_ref_line"; then
                executing=true
            elif $executing; then
                test_passed=false
                echo "$n expected: $curr_ref_line"
                echo "$n found   : $line"
            fi
            if [ "$curr_ref_line" = "$next_ref_line" ]; then
                executing=false; completed=true;
            fi
        fi
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