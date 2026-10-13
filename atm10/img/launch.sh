#!/bin/bash
# All the Mods 10 server launcher.
# Installs/updates the official ATM10 server files into /data, applies settings
# from environment variables, then starts the server.
set -Eeuo pipefail

# --- Pack version ------------------------------------------------------------------
# Read from the VERSION file baked into the image (contains e.g. "8.2").
# A MODPACK_VERSION env var at runtime overrides it, to update without rebuilding.
MODPACK_VERSION="${MODPACK_VERSION:-$(tr -d '[:space:]' 2>/dev/null < /VERSION || true)}"
MODPACK_FILE_ID="${MODPACK_FILE_ID:-8945094}"   # CurseForge file id of ServerFiles-<version>.zip
[[ -n "$MODPACK_VERSION" ]] || { echo "[atm10] ERROR: no modpack version (/VERSION missing or empty)" >&2; exit 1; }

DATA=/data
MARKER="$DATA/.installed-version"             # written only after a complete install
PACK_JVM_ARGS="$DATA/.user_jvm_args.pack"     # pristine copy of the pack's JVM args

log() { echo "[atm10] $*"; }
die() { echo "[atm10] ERROR: $*" >&2; exit 1; }

cd "$DATA"

# --- EULA ----------------------------------------------------------------------
if [[ "${EULA:-}" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
    echo "eula=true" > eula.txt
else
    die "You must accept the Minecraft EULA (https://aka.ms/MinecraftEULA): set EULA=true"
fi

# --- Install / update the server files -----------------------------------------
install_pack() {
    local tmp="$DATA/.install" src neoforge
    local url="https://mediafilez.forgecdn.net/files/${MODPACK_FILE_ID:0:4}/$((10#${MODPACK_FILE_ID:4}))/ServerFiles-${MODPACK_VERSION}.zip"

    log "Installing ATM10 server files $MODPACK_VERSION"
    rm -rf "$tmp" && mkdir -p "$tmp/unpacked"

    log "Downloading $url"
    curl -fL --retry 3 --retry-delay 5 -o "$tmp/pack.zip" "$url" \
        || die "Download failed. Check MODPACK_VERSION and MODPACK_FILE_ID."

    log "Unpacking"
    unzip -q "$tmp/pack.zip" -d "$tmp/unpacked"

    # The zip may or may not have a top-level folder; find the one with startserver.sh
    src="$(dirname "$(find "$tmp/unpacked" -maxdepth 3 -name startserver.sh -print -quit)")"
    [[ -f "$src/startserver.sh" ]] || die "startserver.sh not found in the server files"

    # NeoForge version the pack expects (NEOFORGE_VERSION env var overrides)
    neoforge="${NEOFORGE_VERSION:-$(grep -oP '^\s*NEOFORGE_VERSION=\K[0-9.]+' "$src/startserver.sh" | head -n 1 || true)}"
    [[ -n "$neoforge" ]] || die "Could not find NEOFORGE_VERSION in startserver.sh; set it as env var"

    # Remove the old pack files. World, whitelist, ops and server.properties stay.
    rm -rf config defaultconfigs kubejs mods packmenu libraries \
           neoforge-*-installer.jar* run.sh run.bat user_jvm_args.txt "$MARKER"

    # Copy the new files in (including dotfiles); keep our server.properties if we have one
    if [[ -f server.properties ]]; then rm -f "$src/server.properties"; fi
    cp -a "$src"/. "$DATA"/
    cp user_jvm_args.txt "$PACK_JVM_ARGS" 2>/dev/null || : > "$PACK_JVM_ARGS"

    log "Installing NeoForge $neoforge"
    curl -fL --retry 3 -o "$tmp/neoforge-installer.jar" \
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/$neoforge/neoforge-$neoforge-installer.jar" \
        || die "NeoForge installer download failed"
    java -jar "$tmp/neoforge-installer.jar" --installServer "$DATA" > "$tmp/neoforge-install.log" 2>&1 \
        || { tail -n 30 "$tmp/neoforge-install.log"; die "NeoForge install failed"; }

    rm -rf "$tmp"
    printf '%s %s\n' "$MODPACK_VERSION" "$neoforge" > "$MARKER"   # only now counts as installed
    log "ATM10 $MODPACK_VERSION with NeoForge $neoforge installed"
}

read -r installed_version NEOFORGE <<< "$(cat "$MARKER" 2>/dev/null || true)"
if [[ "${installed_version:-}" != "$MODPACK_VERSION" ]]; then
    install_pack
    read -r installed_version NEOFORGE < "$MARKER"
else
    log "ATM10 $MODPACK_VERSION already installed"
fi

# --- JVM args: rebuilt from the pack's file on every start (no duplicates) -------
{
    grep -v -E '^\s*-Xm[sx]' "$PACK_JVM_ARGS" 2>/dev/null || true
    for opt in ${JVM_OPTS:-}; do echo "$opt"; done
} > user_jvm_args.txt

# --- server.properties -----------------------------------------------------------
touch server.properties
set_prop() {   # set_prop key value: replaces the line, or appends it if missing
    local tmp_file
    tmp_file="$(mktemp -p "$DATA")"
    K="$1" V="$2" awk -F= '
        $1 == ENVIRON["K"] { print ENVIRON["K"] "=" ENVIRON["V"]; found = 1; next }
        { print }
        END { if (!found) print ENVIRON["K"] "=" ENVIRON["V"] }
    ' server.properties > "$tmp_file"
    mv "$tmp_file" server.properties
}

[[ -n "${MOTD:-}" ]]             && set_prop motd "$MOTD"
[[ -n "${MAX_PLAYERS:-}" ]]      && set_prop max-players "$MAX_PLAYERS"
[[ -n "${ALLOW_FLIGHT:-}" ]]     && set_prop allow-flight "$ALLOW_FLIGHT"
[[ -n "${ONLINE_MODE:-}" ]]      && set_prop online-mode "$ONLINE_MODE"
[[ -n "${DIFFICULTY:-}" ]]       && set_prop difficulty "$DIFFICULTY"
[[ -n "${VIEW_DISTANCE:-}" ]]    && set_prop view-distance "$VIEW_DISTANCE"
if [[ -n "${ENABLE_WHITELIST:-}" ]]; then
    set_prop white-list "$ENABLE_WHITELIST"
    set_prop enforce-whitelist "$ENABLE_WHITELIST"
fi
set_prop server-port 25565

# --- Whitelist / ops (add-only: removing a name here does not remove the player) --
add_players() {   # add_players <json file> <comma-separated names> <label> [extra jq fields]
    local file="$1" names="$2" label="$3" extra="${4:-}" raw username uuid
    [[ -n "$extra" ]] || extra='{}'
    [[ -s "$file" ]] || echo "[]" > "$file"

    IFS=',' read -ra list <<< "$names"
    for raw in "${list[@]}"; do
        username="$(echo "$raw" | xargs)"
        if ! [[ "$username" =~ ^[a-zA-Z0-9_]{3,16}$ ]]; then
            [[ -n "$username" ]] && log "$label: invalid username '$username', skipping"
            continue
        fi

        uuid="$(curl -fsS --max-time 10 "https://playerdb.co/api/player/minecraft/$username" \
                | jq -r '.data.player.id // empty' 2>/dev/null || true)"
        if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{32,36}$ ]]; then
            log "$label: could not look up UUID for $username, skipping"
            continue
        fi

        if jq -e --arg u "$uuid" 'any(.[]; .uuid == $u)' "$file" > /dev/null; then
            log "$label: $username already listed"
        else
            log "$label: adding $username ($uuid)"
            jq --arg u "$uuid" --arg n "$username" --argjson extra "$extra" \
                '. += [{uuid: $u, name: $n} + $extra]' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        fi
    done
}

[[ -n "${WHITELIST_USERS:-}" ]] && add_players whitelist.json "$WHITELIST_USERS" Whitelist
[[ -n "${OP_USERS:-}" ]]        && add_players ops.json "$OP_USERS" Ops '{"level":4,"bypassesPlayerLimit":false}'

# --- Start -------------------------------------------------------------------------
args_file="libraries/net/neoforged/neoforge/$NEOFORGE/unix_args.txt"
[[ -f "$args_file" ]] || die "$args_file missing; delete $MARKER to force a reinstall"

log "Starting server"
# exec: Java replaces this script, so it receives SIGTERM from Kubernetes/Docker and saves the world
exec java @user_jvm_args.txt "@$args_file" nogui