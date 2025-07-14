#!/usr/bin/env bash
set -euo pipefail

test_dir="contrib/tests"

mapfile -d '' all_files < <(find "$test_dir" -mindepth 1 -maxdepth 1 -type d -print0)
echo "1..${#all_files[@]}"

success=true
i=1; for dir in "$test_dir"/*/ ; do
    [[ -d $dir ]] || continue

    subdir_name=$(basename "$dir")
    driver_script="./contrib/${subdir_name}.sh"

    mapfile -d '' test_files < <(find "$test_dir/$subdir_name" -mindepth 1 -maxdepth 1 -type f -print0)
    echo "    1..${#test_files[@]}"

    if [[ ! -x $driver_script ]]; then
        echo "ok $i - $dir # SKIP - $driver_script not found"
        continue
    fi

    j=1; for f in "${test_files[@]}"; do
        if "$driver_script" "$f" > /dev/null; then res="ok    "; else res="not ok"; success=false; fi
        echo "    $res $j - $driver_script $f"
        ((j++))
    done
    ((i++))
done

$success
