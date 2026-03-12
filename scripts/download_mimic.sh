#!/usr/bin/env bash
#
# Download missing MIMIC-IV v3.1 files from PhysioNet.
#
# Usage:
#   ./scripts/download_mimic.sh <physionet_username>
#
# You will be prompted for your PhysioNet password.
# Requires: wget (brew install wget)

set -euo pipefail

# Load credentials from .env file (handles special chars in values)
SCRIPT_DIR_TMP="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR_TMP")/.env"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Strip leading/trailing whitespace from key
        key=$(echo "$key" | xargs)
        # Export the variable (value is taken as-is, no shell expansion)
        export "$key=$value"
    done < "$ENV_FILE"
fi

PHYSIONET_USER="${PHYSIONET_USER:-${1:-}}"
PHYSIONET_PASS="${PHYSIONET_PASS:-}"

if [[ -z "$PHYSIONET_USER" ]]; then
    echo "Usage: $0 <physionet_username>"
    echo "Or set PHYSIONET_USER and PHYSIONET_PASS in .env"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data/mimiciv/3.1"
BASE_URL="https://physionet.org/files/mimiciv/3.1"

# All files from SHA256SUMS.txt, organized by module
HOSP_FILES=(
    admissions.csv.gz
    d_hcpcs.csv.gz
    d_icd_diagnoses.csv.gz
    d_icd_procedures.csv.gz
    d_labitems.csv.gz
    diagnoses_icd.csv.gz
    drgcodes.csv.gz
    emar.csv.gz
    emar_detail.csv.gz
    hcpcsevents.csv.gz
    labevents.csv.gz
    microbiologyevents.csv.gz
    omr.csv.gz
    patients.csv.gz
    pharmacy.csv.gz
    poe.csv.gz
    poe_detail.csv.gz
    prescriptions.csv.gz
    procedures_icd.csv.gz
    provider.csv.gz
    services.csv.gz
    transfers.csv.gz
)

ICU_FILES=(
    caregiver.csv.gz
    chartevents.csv.gz
    d_items.csv.gz
    datetimeevents.csv.gz
    icustays.csv.gz
    ingredientevents.csv.gz
    inputevents.csv.gz
    outputevents.csv.gz
    procedureevents.csv.gz
)

mkdir -p "$DATA_DIR/hosp" "$DATA_DIR/icu"

download_if_missing() {
    local module="$1"
    local file="$2"
    local dest="$DATA_DIR/$module/$file"

    if [[ -f "$dest" ]]; then
        echo "[SKIP] $module/$file (already exists)"
        return
    fi

    echo "[DOWNLOAD] $module/$file ..."
    # Use a temp .wgetrc to safely pass credentials with special chars
    local tmp_wgetrc
    tmp_wgetrc=$(mktemp)
    echo "user=$PHYSIONET_USER" > "$tmp_wgetrc"
    echo "password=$PHYSIONET_PASS" >> "$tmp_wgetrc"
    WGETRC="$tmp_wgetrc" wget \
        --no-clobber --continue \
        -O "$dest" \
        "$BASE_URL/$module/$file"
    rm -f "$tmp_wgetrc"
}

echo "============================================"
echo "MIMIC-IV v3.1 Downloader"
echo "Target: $DATA_DIR"
echo "============================================"
echo ""

# Count missing files first
missing=0
for f in "${HOSP_FILES[@]}"; do
    [[ ! -f "$DATA_DIR/hosp/$f" ]] && ((missing++))
done
for f in "${ICU_FILES[@]}"; do
    [[ ! -f "$DATA_DIR/icu/$f" ]] && ((missing++))
done

total=$(( ${#HOSP_FILES[@]} + ${#ICU_FILES[@]} ))
existing=$(( total - missing ))
echo "Files: $existing/$total present, $missing to download"
echo ""

if [[ $missing -eq 0 ]]; then
    echo "All files already downloaded!"
else
    echo "Downloading $missing missing files..."
    echo ""

    for f in "${HOSP_FILES[@]}"; do
        download_if_missing "hosp" "$f"
    done

    for f in "${ICU_FILES[@]}"; do
        download_if_missing "icu" "$f"
    done
fi

# Verify checksums
echo ""
echo "============================================"
echo "Verifying SHA256 checksums..."
echo "============================================"
cd "$DATA_DIR"
if shasum -a 256 -c SHA256SUMS.txt; then
    echo ""
    echo "All checksums PASSED"
else
    echo ""
    echo "WARNING: Some checksums FAILED - re-download those files"
fi

echo ""
echo "============================================"
echo "Download summary"
echo "============================================"
echo ""
echo "hosp/ files:"
for f in "${HOSP_FILES[@]}"; do
    if [[ -f "$DATA_DIR/hosp/$f" ]]; then
        size=$(du -h "$DATA_DIR/hosp/$f" | cut -f1)
        echo "  [OK] $f ($size)"
    else
        echo "  [MISSING] $f"
    fi
done
echo ""
echo "icu/ files:"
for f in "${ICU_FILES[@]}"; do
    if [[ -f "$DATA_DIR/icu/$f" ]]; then
        size=$(du -h "$DATA_DIR/icu/$f" | cut -f1)
        echo "  [OK] $f ($size)"
    else
        echo "  [MISSING] $f"
    fi
done

echo ""
echo "Total size:"
du -sh "$DATA_DIR"
