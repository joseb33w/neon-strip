#!/usr/bin/env bash
# Fetch the directly-instanced library models (the drivable car + Kenney pedestrians/player).
# The bulk of the world (buildings, cars-as-scenery, palms, rocks) and the Meshy hero pieces are
# STREAMED at runtime from R2 by the chunk runtime and are NOT stored in the repo.
set -euo pipefail
BASE="https://preview.myapping.com/godot-assets"
mkdir -p models
declare -A MAP=(
  ["car.glb"]="props/kk_city/car_sedan.glb"
  ["player.glb"]="characters/character-a.glb"
  ["ped_a.glb"]="characters/character-b.glb"
  ["ped_b.glb"]="characters/character-c.glb"
  ["ped_c.glb"]="characters/character-d.glb"
  ["ped_d.glb"]="characters/character-e.glb"
)
for out in "${!MAP[@]}"; do
  curl -sfL "$BASE/${MAP[$out]}" -o "models/$out" && echo "fetched models/$out"
done
echo "Done. Now run:  python3 scripts/generate_audio.py   (regenerates the localized audio loops)"
