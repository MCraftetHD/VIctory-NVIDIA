#!/usr/bin/env bash
# Fetches, on Linux, what the Windows fetchers (`victory get-dlss`,
# `victory get-fsr`) would: they run Windows PowerShell, which Wine only
# stubs, so under Wine they cannot download anything. The files and versions
# are the ones scripts/get-nvidia-sdks.ps1 and scripts/get-amd-fsr.ps1 get on
# Windows, checked against the same checksums where AMD's are known.
#
#   scripts/fetch-under-linux.sh [folder of the game]
#
# The files land in <folder>/fidelityfx (AMD's two) and
# <folder>/nvidia-sdk/Streamline/bin/x64 (NVIDIA's) — the folders the start
# looks at beside victory.exe. With no argument, the current folder. Nothing
# here runs the title, and nothing here is needed to build it.

set -euo pipefail

to=${1:-.}
if [ ! -f "$to/victory.exe" ]; then
    echo "no victory.exe in '$to': give the folder the exe is in (or run this there)"
    exit 1
fi

fetch() { # url file
    if command -v curl >/dev/null 2>&1; then
        curl --location --fail --silent --show-error --output "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        echo "no curl or wget in PATH: 'sudo pacman -S --needed curl', then run this again" >&2
        exit 1
    fi
}

sha_of() { sha256sum "$1" | cut -d' ' -f1 | tr 'a-f' 'A-F'; }

# --- AMD's FidelityFX SDK v2.4.0: the two files FSR 3 frame generation loads.
# The same files and checksums scripts/get-amd-fsr.ps1 fetches on Windows.
fsr=$to/fidelityfx
mkdir -p "$fsr"
amd_base=https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/v2.4.0/Kits/FidelityFX
echo "AMD FSR 3 frame generation (FidelityFX SDK v2.4.0), from github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK:"
for name in amd_fidelityfx_loader_dx12.dll amd_fidelityfx_framegeneration_dx12.dll; do
    if [ -f "$fsr/$name" ]; then
        echo "  $name already there"
        continue
    fi
    echo "  $name"
    fetch "$amd_base/signedbin/$name" "$fsr/$name.part"
    case $name in
        amd_fidelityfx_loader_dx12.dll)
            want=E2191D3C0828BE45EB8AFFD4E3EC0378F2293ADC345B772A7170EDCF3B021ECB ;;
        amd_fidelityfx_framegeneration_dx12.dll)
            want=E6843252F58B0341A0D80F6A20BC0D840643EE95BC48C22CAC08745344577BB6 ;;
    esac
    got=$(sha_of "$fsr/$name.part")
    if [ "$got" != "$want" ]; then
        rm -f "$fsr/$name.part"
        echo "$name is not the file this build was tested with (SHA-256 $got); not kept" >&2
        exit 1
    fi
    mv "$fsr/$name.part" "$fsr/$name"
done
if [ ! -f "$fsr/amd-fidelityfx-license.md" ]; then
    fetch "$amd_base/docs/license.md" "$fsr/amd-fidelityfx-license.md" || echo "  (AMD's licence text could not be fetched)"
fi

# --- NVIDIA Streamline v2.14.16 with DLSS and frame generation, from
# github.com/NVIDIA-RTX/Streamline: the files the game runs through, the same
# ones scripts/get-nvidia-sdks.ps1 fetches on Windows. The archive is one
# 263 MB download; the eight files come out of it.
sl=$to/nvidia-sdk/Streamline
bin=$sl/bin/x64
tag=v2.14.16
url=https://github.com/NVIDIA-RTX/Streamline/releases/download/$tag/streamline-sdk-$tag.zip
dlls='sl.interposer.dll sl.common.dll sl.dlss.dll sl.dlss_g.dll sl.reflex.dll sl.pcl.dll nvngx_dlss.dll nvngx_dlssg.dll'
missing=
for name in $dlls; do
    [ -f "$bin/$name" ] || missing="$missing $name"
done
echo "NVIDIA Streamline $tag with DLSS and frame generation, from github.com/NVIDIA-RTX/Streamline (the archive is about 263 MB):"
if [ -z "$missing" ]; then
    echo "  all there already: $bin"
else
    if ! command -v unzip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        echo "no unzip or python3: 'sudo pacman -S --needed unzip', then run this again" >&2
        exit 1
    fi
    zip=$(mktemp -d)/streamline-sdk-$tag.zip
    fetch "$url" "$zip"
    mkdir -p "$bin"
    if command -v unzip >/dev/null 2>&1; then
        # The paths in the archive run <top>/bin/x64/<file>; the development
        # tree has a copy too, which is left there.
        list=$(unzip -Z1 "$zip")
        for name in $dlls; do
            member=$(echo "$list" | grep -E "(^|/)bin/x64/$name\$" | grep -v '/development/' | head -1)
            if [ -z "$member" ]; then
                echo "the archive has no bin/x64/$name" >&2
                exit 1
            fi
            unzip -p "$zip" "$member" > "$bin/$name"
            echo "  $name  $(du -h "$bin/$name" | cut -f1)"
        done
        echo "$list" | grep -E '(^|/)bin/x64/[^/]*license[^/]*\.txt$' | grep -v '/development/' | while read -r member; do
            unzip -p "$zip" "$member" > "$bin/$(basename "$member")"
        done
        top_licence=$(echo "$list" | grep -E '^license\.txt$' | head -1)
        if [ -n "$top_licence" ]; then
            unzip -p "$zip" "$top_licence" > "$sl/license.txt"
        fi
    else
        python3 - "$zip" "$bin" "$sl" $dlls <<'PY'
import re, sys, zipfile
zip_path, bin_dir, sl_dir = sys.argv[1], sys.argv[2], sys.argv[3]
names = sys.argv[4:]
with zipfile.ZipFile(zip_path) as z:
    for info in z.infolist():
        n = info.filename
        if "/development/" in n:
            continue
        m = re.search(r"(?:^|/)bin/x64/([^/]+)$", n)
        if m and (m.group(1) in names or re.search(r"license[^/]*\.txt$", m.group(1))):
            with open(f"{bin_dir}/{m.group(1)}", "wb") as f:
                f.write(z.read(info))
            if m.group(1) in names:
                print(f"  {m.group(1)}  {info.file_size / 1e6:.1f} MB")
        elif n == "license.txt":
            with open(f"{sl_dir}/license.txt", "wb") as f:
                f.write(z.read(info))
PY
    fi
    rm -rf "$(dirname "$zip")"
    for name in $dlls; do
        if [ ! -f "$bin/$name" ]; then
            echo "not there after all: $bin/$name (the archive's listing above says what came out)" >&2
            exit 1
        fi
    done
fi

echo
echo "Done. They are used from the next start:"
echo "  wine victory.exe play --series-s --framegen 2"
