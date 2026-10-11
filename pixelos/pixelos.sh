#!/usr/bin/env bash
set -uo pipefail

WORK=${WORK:-/work}
SRC=${SRC:-$WORK/pixelos}
RLOS=${RLOS:-$WORK/treble_restlessos}
BRANCH=${BRANCH:-seventeen}
JOBS=${JOBS:-16}
SYNC_JOBS=${SYNC_JOBS:-8}
EXCLUDE=${EXCLUDE:-$WORK/patch-exclude.txt}
STATE=$WORK/.state-pixelos
CRITICAL='packages_modules_Connectivity|system_bpf|system_apex|system_core|system_netd|system_sepolicy|platform_bionic|system_linkerconfig|modules_vndk|system_vold'

mkdir -p "$STATE"
export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-pixelos-gsi}
export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-pixelos-gsi@localhost}
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

say() { printf '\n=== %s\n' "$*"; }

done_step() { [ -f "$STATE/$1" ]; }
mark_step() { : > "$STATE/$1"; }

step_deps() {
  done_step deps && return 0
  say deps
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git git-lfs curl python3 repo build-essential bc bison flex gperf zip unzip zlib1g-dev libncurses-dev libssl-dev lib32z1-dev libxml2-utils xsltproc rsync lz4 xz-utils fontconfig openjdk-21-jdk ccache patch
  fi
  git lfs install
  mark_step deps
}

write_local_manifest() {
  mkdir -p "$SRC/.repo/local_manifests"
  cat > "$SRC/.repo/local_manifests/treble.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="device/amlogic/yukawa" />
  <remove-project name="device/amlogic/yukawa-kernel" />
  <remove-project name="device/generic/art" />
  <remove-project name="device/generic/x86" />
  <remove-project name="device/generic/x86_64" />
  <remove-project name="device/google_car" />
  <remove-project name="device/linaro/dragonboard" />
  <remove-project name="device/linaro/dragonboard-kernel" />
  <remove-project name="device/linaro/hikey" />
  <remove-project name="device/linaro/hikey-kernel" />
  <remove-project name="device/google/cuttlefish_vmm" />
  <remove-project name="platform/hardware/invensense" />
  <remove-project name="platform/hardware/samsung/nfc" />
  <remove-project name="platform/hardware/st/secure_element" />
  <remove-project name="platform/hardware/st/secure_element2" />
  <remove-project name="platform/hardware/ti/am57x" />
  <remove-project name="kernel/tests" />
  <remove-project name="platform/test/catbox" />
  <remove-project name="platform/test/cts-root" />
  <remove-project name="platform/test/dittosuite" />
  <remove-project name="platform/test/vts-testcase/nbu" />
  <remove-project name="platform/test/vts-testcase/performance" />
  <remove-project name="platform/test/vts-testcase/security" />
  <remove-project name="platform/tools/test/connectivity" />
  <remove-project name="platform/tools/test/mobly_snippets" />
  <remove-project name="platform/tools/test/openhst" />
  <remove-project name="platform/packages/modules/Virtualization" />
</manifest>
XML
}

step_sync() {
  done_step sync && return 0
  say sync
  mkdir -p "$SRC"
  cd "$SRC" || exit 1
  [ -d .repo ] || repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b "$BRANCH" --depth=1 --git-lfs || exit 1
  write_local_manifest
  until repo sync -c -j"$SYNC_JOBS" --force-sync --no-clone-bundle --no-tags --optimized-fetch --retry-fetches=3; do
    echo "sync failed, retrying in 30s"
    sleep 30
  done
  mark_step sync
}

step_clone_restless() {
  [ -d "$RLOS/.git" ] || git clone --depth 1 https://github.com/cawilliamson/treble_restlessos "$RLOS"
}

step_overlays() {
  done_step overlays && return 0
  say overlays
  step_clone_restless
  local pairs=(
    andycgyan/QcRilAm:packages/apps/QcRilAm
    phhusson/lptools:vendor/lptools
    phhusson/magisk:vendor/magisk
    phhusson/vndk-tests:vendor/vndk-tests
    trebledroid/device_phh_treble:device/phh/treble
    trebledroid/treble_app:treble_app
    trebledroid/vendor_hardware_overlay:vendor/hardware_overlay
    trebledroid/vendor_interfaces:vendor/interfaces
  )
  local pair d t
  for pair in "${pairs[@]}"; do
    d=${pair%%:*}
    t=$SRC/${pair#*:}
    rm -rf "$t"
    mkdir -p "$(dirname "$t")"
    cp -aT "$RLOS/overlays/$d" "$t"
    git -C "$t" init -q
    git -C "$t" add -A
    git -C "$t" commit -q -m "overlay base"
    echo "$d -> ${pair#*:}"
  done
  mark_step overlays
}

project_path() {
  local p
  p=$(tr _ / <<<"$1" | sed -e 's;platform/;;g')
  case "$p" in
    build) p=build/make ;;
    test/vts-testcase/hal/treble/vintf) p=test/vts-testcase/hal ;;
    system/fs/fs/mgr) p=system/fs/fs_mgr ;;
    treble/app) p=treble_app ;;
    vendor/hardware/overlay) p=vendor/hardware_overlay ;;
    vendor/partner/gms) p=vendor/partner_gms ;;
  esac
  echo "$p"
}

is_excluded() {
  local rel=$1 pat
  [ -f "$EXCLUDE" ] || return 1
  while IFS= read -r pat; do
    case "$pat" in '' | '#'*) continue ;; esac
    case "$rel" in "$pat"*) return 0 ;; esac
  done < "$EXCLUDE"
  return 1
}

apply_one() {
  local d=$1 patch=$2 subj
  if git -C "$d" am --3way --quiet "$patch" >/dev/null 2>&1; then
    echo OK
    return 0
  fi
  git -C "$d" am --abort >/dev/null 2>&1
  if patch -p1 -F3 --dry-run --no-backup-if-mismatch -d "$d" < "$patch" >/dev/null 2>&1; then
    patch -p1 -F3 --no-backup-if-mismatch -d "$d" < "$patch" >/dev/null 2>&1
    subj=$(sed -n 's/^Subject: *\(\[PATCH[^]]*\] *\)\{0,1\}//p' "$patch" | head -1)
    git -C "$d" add -A
    git -C "$d" commit -q -m "${subj:-fuzz-applied patch}" >/dev/null 2>&1
    echo FUZZ
    return 0
  fi
  echo FAIL
  return 1
}

step_patches() {
  say patches
  step_clone_restless
  local tier pdir project dest patch rel res crit
  local ok=0 fuzz=0 fail=0 skip=0
  local failed=()
  : >> "$STATE/applied"
  for tier in trebledroid rom personal; do
    for pdir in "$RLOS/patches/$tier"/*/; do
      [ -d "$pdir" ] || continue
      project=$(basename "$pdir")
      dest=$(project_path "$project")
      for patch in "$pdir"*.patch; do
        [ -f "$patch" ] || continue
        rel=$tier/$project/$(basename "$patch")
        if is_excluded "$rel"; then
          skip=$((skip + 1))
          continue
        fi
        grep -qxF "$rel" "$STATE/applied" && continue
        if [ ! -d "$SRC/$dest/.git" ]; then
          echo "SKIP-NODIR $rel ($dest)"
          skip=$((skip + 1))
          continue
        fi
        res=$(apply_one "$SRC/$dest" "$patch")
        echo "$res $rel"
        case "$res" in
          OK) ok=$((ok + 1)); echo "$rel" >> "$STATE/applied" ;;
          FUZZ) fuzz=$((fuzz + 1)); echo "$rel" >> "$STATE/applied" ;;
          *) fail=$((fail + 1)); failed+=("$rel") ;;
        esac
      done
    done
  done
  say "patches: ok=$ok fuzz=$fuzz fail=$fail skipped=$skip"
  if [ "$fail" -gt 0 ]; then
    echo "failed patches:"
    printf '%s\n' "${failed[@]}"
    crit=$(printf '%s\n' "${failed[@]}" | grep -E "$CRITICAL")
    if [ -n "$crit" ]; then
      echo
      echo "CRITICAL (bpf/boot/apex) failures:"
      echo "$crit"
      return 2
    fi
  fi
  return 0
}

step_plan() {
  step_clone_restless
  local tier pdir project patch rel inc=0 exc=0
  for tier in trebledroid rom personal release-builds debug-builds; do
    for pdir in "$RLOS/patches/$tier"/*/; do
      [ -d "$pdir" ] || continue
      project=$(basename "$pdir")
      for patch in "$pdir"*.patch; do
        [ -f "$patch" ] || continue
        rel=$tier/$project/$(basename "$patch")
        if is_excluded "$rel"; then
          echo "EXCLUDE $rel"
          exc=$((exc + 1))
        else
          inc=$((inc + 1))
        fi
      done
    done
  done
  echo "apply=$inc exclude=$exc"
}

step_rommk() {
  cd "$SRC/device/phh/treble" || exit 1
  cat > pixelos.mk <<'MK'
TARGET_DISABLE_EPPE := true
CUSTOM_BUILD := treble
TARGET_SCREEN_WIDTH := 1080
PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey
$(call inherit-product, vendor/custom/config/common_full_phone.mk)
-include vendor/lineage/build/core/config.mk
-include vendor/lineage/build/core/apicheck.mk
MK
  sed -i "/PRODUCT_EXTRA_VNDK_VERSIONS/d" base.mk
  sed -i "/gms_mainline/d" "$SRC/build/make/target/product/generic_system.mk" "$SRC/build/make/target/product/go_defaults.mk"
  SRC="$SRC" python3 /work/strip-vndk.py
  bash generate.sh pixelos
}

detect_tag() {
  local t
  t=$(grep -m1 'target:' "$SRC/build/release/release_config_map.textproto" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')
  echo "${t:-cp2a}"
}

step_treble_app() {
  [ -f "$SRC/treble_app/build.sh" ] || return 0
  cp /work/.keys/platform.pk8 /work/.keys/platform.x509.pem "$SRC/treble_app/keys/"
  (cd "$SRC/treble_app" && bash build.sh release) || echo "treble_app build failed, continuing"
}

step_build() {
  say build
  cd "$SRC" || exit 1
  (step_rommk) || exit 1
  local tag=${TARGET:-treble_arm64_bgN-$(detect_tag)-userdebug}
  export WITH_ADB_INSECURE=true
  set +u
  source build/envsetup.sh
  lunch "$tag" || exit 1
  make systemimage -j"$JOBS"
}

step_reset() {
  cd "$SRC" || exit 1
  repo sync -l -d --force-sync -j"$SYNC_JOBS"
  rm -f "$STATE/overlays" "$STATE/applied"
}

case "${1:-all}" in
  plan) step_plan ;;
  deps) step_deps ;;
  sync) step_sync ;;
  overlays) step_overlays ;;
  patches) step_patches ;;
  build) step_build ;;
  reset) step_reset ;;
  all)
    step_deps
    step_sync
    step_overlays
    step_patches
    rc=$?
    if [ "$rc" -ne 0 ] && [ "${FORCE_BUILD:-0}" != 1 ]; then
      echo "stopping before build; fix critical patches or rerun with FORCE_BUILD=1 ./pixelos.sh build"
      exit "$rc"
    fi
    step_treble_app
    step_build
    ;;
  *) echo "usage: $0 [all|plan|deps|sync|overlays|patches|build|reset]"; exit 1 ;;
esac
