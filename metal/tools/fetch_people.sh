#!/bin/bash
# Downloads the people from Microsoft's Rocketbox avatar library (MIT licence, © 2020 Microsoft) and converts
# them for the game: meshes and motion-capture clips to glTF with assimp, textures to 1024 px JPEG with sips.
# Needs `brew install assimp`. Output goes to data/people; files already there are kept.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="https://raw.githubusercontent.com/microsoft/Microsoft-Rocketbox/master/Assets"
OUT="data/people"
TMP="$(mktemp -d)"
mkdir -p "$OUT/anim"

AVATARS="Adults/Male_Adult_04 Adults/Male_Adult_12 Adults/Male_Adult_18 Professions/Business_Male_05
Professions/Construction_Male_03 Professions/Sports_Male_03 Adults/Male_Adult_08 Adults/Male_Adult_01
Adults/Male_Adult_11 Professions/Business_Male_07 Professions/Wood_Male_01 Adults/Male_Adult_15
Professions/Business_Female_01 Adults/Female_Party_02 Adults/Female_Adult_02 Adults/Female_Adult_15
Adults/Female_Adult_17 Adults/Female_Adult_11 Adults/Female_Adult_01 Adults/Female_Adult_06
Adults/Female_Adult_10 Adults/Female_Adult_03 Professions/Sports_Male_01 Adults/Male_Adult_02
Adults/Female_Adult_14 Adults/Male_Adult_17"
CLIPS="xy/m_walk_neutral_01 xy/f_walk_neutral_01 xy/m_walk_stroll_01 xy/f_walk_stroll_01
static/m_idle_neutral_01 static/f_idle_neutral_01 static/m_idle_neutral_02 static/f_idle_neutral_02
static/m_gestic_talk_neutral_01 static/f_gestic_talk_neutral_01"

for a in $AVATARS; do
    name="$(basename "$a")"
    if [ ! -f "$OUT/$name.gltf" ]; then
        echo "$name"
        curl -sfL -o "$TMP/$name.fbx" "$BASE/Avatars/$a/Export/$name.fbx"
        assimp export "$TMP/$name.fbx" "$OUT/$name.gltf" >/dev/null
    fi
    # Texture names (m007_body_color.tga and so on) come from the materials in the converted file.
    # Hair cards and eyelashes, a hard hat or a tool belt: extra materials some of the people have. PNG keeps the alpha.
    for part in opacity helmet tools; do
        tex="$(grep -o "[a-zA-Z0-9_]*_${part}_color\.tga" "$OUT/$name.gltf" | head -1 || true)"
        if [ -z "$tex" ] || [ -f "$OUT/${name}_${part}_color.png" ]; then continue; fi
        curl -sfL -o "$TMP/$tex" "$BASE/Avatars/$a/Textures/$tex"
        sips -s format png -Z 1024 "$TMP/$tex" --out "$OUT/${name}_${part}_color.png" >/dev/null
        rm -f "$TMP/$tex"
    done
    for part in body head; do
        for kind in color normal; do
            [ -f "$OUT/${name}_${part}_${kind}.jpg" ] && continue
            tex="$(grep -o "[a-zA-Z0-9_]*_${part}_${kind}\.tga" "$OUT/$name.gltf" | head -1)"
            curl -sfL -o "$TMP/$tex" "$BASE/Avatars/$a/Textures/$tex"
            size=1024; [ "$kind" = normal ] && size=512
            sips -s format jpeg -s formatOptions 88 -Z $size "$TMP/$tex" --out "$OUT/${name}_${part}_${kind}.jpg" >/dev/null
            rm -f "$TMP/$tex"
        done
    done
done
for c in $CLIPS; do
    name="$(basename "$c")"
    [ -f "$OUT/anim/$name.gltf" ] && continue
    echo "$name"
    curl -sfL -o "$TMP/$name.fbx" "$BASE/Animations/all_animations_max_motextr_$c.max.fbx"
    assimp export "$TMP/$name.fbx" "$OUT/anim/$name.gltf" >/dev/null
done
[ -f "$OUT/LICENSE-Rocketbox.md" ] || curl -sfL -o "$OUT/LICENSE-Rocketbox.md" "https://raw.githubusercontent.com/microsoft/Microsoft-Rocketbox/master/LICENSE.md"
rm -rf "$TMP"
du -sh "$OUT"
