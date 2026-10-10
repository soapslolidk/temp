#!/usr/bin/env bash
# LineageOS 24.0 (Android 17) GSI build. Run inside the build container with /work mounted.
# Resumable: finished phases are skipped via /work/.state-lineage/<phase>.
set -uo pipefail

W=/work
SRC=$W/lineage
RESTLESS=$W/treble_restlessos
LOS_BRANCH=lineage-24.0
TARGET="${TARGET:-treble_arm64_bvN-userdebug}"
JOBS=${JOBS:-$(nproc)}

STATE=$W/.state-lineage; mkdir -p "$STATE" "$W/logs"
phase() { [ -e "$STATE/$1" ] && { echo "[skip] $1"; return 1; }; echo "[run ] $1"; return 0; }
done_() { touch "$STATE/$1"; }
die()   { echo "FATAL: $*" >&2; exit 1; }

CORE=(
  trebledroid/platform_packages_modules_Connectivity/000[1-9]
  trebledroid/platform_system_bpf/000[1-2]
  trebledroid/platform_system_netd/000[3-4]
  trebledroid/platform_frameworks_native/0012
  trebledroid/platform_system_core/0001
  trebledroid/platform_system_core/0003
  trebledroid/platform_system_core/0012
  trebledroid/platform_system_core/0016
  personal/platform_system_apex/0001
)
OPT=(
  trebledroid/platform_system_core/0002
  trebledroid/platform_system_core/0004
  trebledroid/platform_system_core/0005
  trebledroid/platform_system_core/0013
  trebledroid/platform_system_core/0015
  trebledroid/platform_system_core/0017
  trebledroid/platform_system_netd/000[1-2]
)

apply_one() {  # $1 = tier/project/NNNN glob ; $2 = core|opt
  local spec=$1 kind=$2 f proj rel dir subj
  for f in $RESTLESS/patches/$spec*.patch; do
    [ -e "$f" ] || { echo "  no match: $spec"; [ "$kind" = core ] && die "missing patch $spec"; return; }
    proj=$(basename "$(dirname "$f")")
    rel=$(tr _ / <<<"$proj" | sed 's;^platform/;;')
    dir=$SRC/$rel
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || die "no git repo at $dir"
    subj=$(git mailinfo /dev/null /dev/null <"$f" 2>/dev/null | sed -n 's/^Subject: //p')
    if [ -e "$STATE/applied.$(basename "$f")" ] || git -C "$dir" log --format=%s -n 300 | grep -qxF "$subj" || git -C "$dir" apply --check -R "$f" >/dev/null 2>&1; then
      echo "  [already] $(basename "$f")"; continue
    fi
    if git -C "$dir" am "$f" >>"$W/logs/patches.log" 2>&1 || { git -C "$dir" am --abort >/dev/null 2>&1; git -C "$dir" am --3way "$f" >>"$W/logs/patches.log" 2>&1; }; then
      touch "$STATE/applied.$(basename "$f")"; echo "  [ok]      $rel/$(basename "$f")"
    else
      git -C "$dir" am --abort >/dev/null 2>&1
      echo "  [FAIL]    $rel/$(basename "$f")  (see logs/patches.log)"
      [ "$kind" = core ] && die "core patch failed: $f"
    fi
  done
}

if phase clone_patches; then
  [ -d "$RESTLESS/.git" ] || git clone --depth 1 https://github.com/cawilliamson/treble_restlessos "$RESTLESS" || die clone
  done_ clone_patches
fi

if phase repo_init; then
  mkdir -p "$SRC" && cd "$SRC" || die cd
  echo y | repo init -u https://github.com/LineageOS/android.git -b "$LOS_BRANCH" --git-lfs --depth=1 || die repo_init
  done_ repo_init
fi

if phase repo_sync; then
  cd "$SRC" || die cd
  until repo sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags; do
    echo "sync failed, retry in 30s"; sleep 30
  done
  done_ repo_sync
fi

if phase treble_tree; then
  cd "$SRC" || die cd
  U=$RESTLESS/overlays
  for pair in trebledroid/device_phh_treble:device/phh/treble trebledroid/treble_app:treble_app \
              trebledroid/vendor_hardware_overlay:vendor/hardware_overlay trebledroid/vendor_interfaces:vendor/interfaces \
              phhusson/lptools:vendor/lptools phhusson/vndk-tests:vendor/vndk-tests; do
    rm -rf "${pair#*:}"; mkdir -p "$(dirname "${pair#*:}")"; cp -aT "$U/${pair%%:*}" "${pair#*:}" || die "$pair"
  done
  done_ treble_tree
fi

if phase patches; then
  cd "$SRC" || die cd
  : > "$W/logs/patches.log"
  echo "== CORE (apexd / BPF / boot) =="; for s in "${CORE[@]}"; do apply_one "$s" core; done
  echo "== OPTIONAL ==";                  for s in "${OPT[@]}";  do apply_one "$s" opt;  done
  done_ patches
fi

cd "$SRC" || die cd
if phase patches_all; then /work/apply-rest-lineage.sh; done_ patches_all; fi
mkdir -p vendor/keys && cp -f /work/.keys/*.pk8 /work/.keys/*.x509.pem vendor/keys/
set +u; source build/envsetup.sh
lunch "$TARGET" || die "lunch $TARGET failed"; [ "${TARGET_PRODUCT:-}" = "treble_arm64_bvN" ] || die "lunch did not select treble_arm64_bvN (got ${TARGET_PRODUCT:-none})"
m -j"$JOBS" systemimage || die "systemimage failed"
echo "image: $OUT/system.img"
