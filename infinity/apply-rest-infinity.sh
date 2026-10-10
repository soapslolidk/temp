#!/usr/bin/env bash
# Apply EVERY RestlessOS patch (trebledroid, rom, personal, release-builds). Never stops; summary at end.
W=/work; SRC=$W/infinity; R=$W/treble_restlessos/patches; STATE=$W/.state-infinity
mkdir -p "$STATE" "$W/logs"; LOG=$W/logs/patches-all.log; SUM=$W/logs/patch-summary.txt; : > "$LOG"; : > "$SUM"
shopt -s nullglob
map() {
  local p; p="$(tr _ / <<<"$1" | sed -e 's;platform/;;g')"
  [ "$p" == build ] && p=build/make
  [ "$p" == system/fs/fs/mgr ] && p=system/fs/fs_mgr
  [ "$p" == testing ] && p=platform_testing
  [ "$p" == treble/app ] && p=treble_app
  [ "$p" == vendor/hardware/overlay ] && p=vendor/hardware_overlay
  [ "$p" == vendor/partner/gms ] && p=vendor/partner_gms
  echo "$p"
}
ok=0; skip=0; fail=0; miss=0
for tier in trebledroid personal release-builds; do
  for pd in "$R/$tier"/*/; do
    proj=$(basename "$pd"); rel=$(map "$proj"); dir=$SRC/$rel
    for f in "$pd"*.patch; do
      b=$(basename "$f"); key="$STATE/applied.$tier.$proj.$b"
      if [ -e "$key" ] || [ -e "$STATE/applied.$b" ]; then skip=$((skip+1)); continue; fi
      if [ ! -d "$dir" ]; then echo "MISSING-DIR $tier/$proj/$b -> $rel" >> "$SUM"; miss=$((miss+1)); continue; fi
      if [ -e "$dir/.git" ]; then
        if git -C "$dir" apply --check -R "$f" >/dev/null 2>&1; then touch "$key"; skip=$((skip+1)); continue; fi
        if git -C "$dir" am "$f" >>"$LOG" 2>&1 || { git -C "$dir" am --abort >/dev/null 2>&1; git -C "$dir" am --3way "$f" >>"$LOG" 2>&1; }; then
          touch "$key"; ok=$((ok+1)); echo "[ok]   $tier/$proj/$b"
        else
          git -C "$dir" am --abort >/dev/null 2>&1
          echo "FAIL $tier/$proj/$b" >> "$SUM"; fail=$((fail+1)); echo "[FAIL] $tier/$proj/$b"
        fi
      else
        if (cd "$dir" && GIT_CEILING_DIRECTORIES="$SRC" git apply --no-index -p1 "$f") >>"$LOG" 2>&1; then
          touch "$key"; ok=$((ok+1)); echo "[ok]   $tier/$proj/$b"
        else echo "FAIL $tier/$proj/$b" >> "$SUM"; fail=$((fail+1)); echo "[FAIL] $tier/$proj/$b"; fi
      fi
    done
  done
done
echo; echo "applied=$ok already=$skip failed=$fail missing_dir=$miss  (details: $SUM)"
