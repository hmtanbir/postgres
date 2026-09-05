#!/bin/bash
set -euo pipefail

if [ -n "${1:-}" ]; then
    NEW_VERSION="$1"
else
    read -rp "Enter new version: " NEW_VERSION
fi

if [ -z "$NEW_VERSION" ]; then
    echo "No version provided. Exiting."
    exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid version format: $NEW_VERSION (expected X.Y or X.Y.Z)"
    exit 1
fi

NEW_VERSION_UNDERSCORE="${NEW_VERSION//./_}"
NEW_VERSION_MAJOR_MINOR="${NEW_VERSION%.*}"

# Update Dockerfile ARGs in place.
#   PG_VERSION     -> underscore form (e.g. 18_4) used for the REL tag URL
#   LABEL_VERSION  -> dot form (e.g. 18.4) used for the image label
apply_arg() {
    local file="$1" name="$2" value="$3" oldvalue="$4"
    if ! grep -q "^ARG $name=" "$file"; then
        echo "ERROR: ARG $name not found in $file"
        return 1
    fi
    sed -i.bak -E "s/^(ARG $name=).*$/\1$value/" "$file"
    rm -f "$file.bak"
    echo "Updated $file: $name = $oldvalue -> $value"
}

# Update every quoted version literal in deploy.yml (default and PG_VERSION_FULL).
# The current version is detected from the file, so re-running is also safe.
apply_yml() {
    local file="$1" newvalue="$2"
    local oldvalue
    oldvalue=$(grep -oE "'[0-9]+\.[0-9]+(\.[0-9]+)?'" "$file" | head -n1 | tr -d "'")
    if [ -z "$oldvalue" ]; then
        echo "ERROR: no quoted version found in $file"
        return 1
    fi
    if [ "$oldvalue" = "$newvalue" ]; then
        echo "Skipped $file: already at '$newvalue'"
        return 0
    fi
    sed -i.bak "s/'$oldvalue'/'$newvalue'/g" "$file"
    rm -f "$file.bak"
    echo "Updated $file: '$oldvalue' -> '$newvalue'"
}

exit_code=0

apply_arg "Dockerfile" "PG_VERSION" "$NEW_VERSION_UNDERSCORE" "$NEW_VERSION" || exit_code=1
apply_arg "Dockerfile" "LABEL_VERSION" "$NEW_VERSION" "$NEW_VERSION" || exit_code=1
apply_yml ".github/workflows/deploy.yml" "$NEW_VERSION" || exit_code=1

[ "$exit_code" -eq 0 ] && echo "Done." || echo "Finished with errors."
exit "$exit_code"
