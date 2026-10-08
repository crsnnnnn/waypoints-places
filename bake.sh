#!/usr/bin/env bash
# Bakes one region's places into a PMTiles archive the app streams.
#
#   bake.sh <name> <west,south,east,north> <osm.pbf path or URL> [out dir]
#
# Sources, merged into one place per name and spot:
#   - OpenStreetMap (ODbL): shops, amenities, tourism, leisure, offices,
#     crafts and healthcare with a name, from a Geofabrik extract.
#   - AllThePlaces (CC0): brand locations scraped from store finders, from
#     the latest run's PMTiles, cut to the region at zoom 15.
#   - Overture Maps places (CDLA Permissive 2.0), read straight from its
#     public S3 bucket.
#
# A place found by more than one source keeps OpenStreetMap's position and
# takes phone, website, hours and brand from whichever source has them.
# Overture places no other source confirms need confidence 0.7 or more.
# Because the output contains OpenStreetMap data it is shared under ODbL.
#
# Needs duckdb, osmium, pmtiles, tippecanoe and python3 on PATH.
# OVERTURE_RELEASE and ATP_PMTILES override the latest Overture release and
# AllThePlaces run; KEEP_WORK=<dir> keeps the intermediate files.
set -euo pipefail

name=${1:?region name}
bbox=${2:?west,south,east,north}
osm=${3:?osm.pbf path or URL}
out=${4:-out}
IFS=, read -r west south east north <<<"$bbox"

here=$(cd "$(dirname "$0")" && pwd)
work=${KEEP_WORK:-$(mktemp -d)}
mkdir -p "$work"
# KEEP_WORK=<dir> keeps the intermediate files and database for a look.
[[ -n ${KEEP_WORK:-} ]] || trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

echo "[$name] OpenStreetMap"
if [[ $osm == http* ]]; then
  curl -sfL --retry 3 -o "$work/source.osm.pbf" "$osm"
else
  ln -s "$(cd "$(dirname "$osm")" && pwd)/$(basename "$osm")" "$work/source.osm.pbf"
fi
osmium extract --overwrite -b "$bbox" "$work/source.osm.pbf" -o "$work/box.osm.pbf"
osmium tags-filter --overwrite "$work/box.osm.pbf" \
  nwr/amenity nwr/shop nwr/tourism nwr/leisure nwr/office nwr/craft \
  nwr/healthcare -o "$work/poi.osm.pbf"
osmium export --overwrite "$work/poi.osm.pbf" -f geojsonseq \
  -x print_record_separator=false --geometry-types=point,polygon \
  -a type,id -o "$work/osm.geojsonseq"

echo "[$name] AllThePlaces"
atp=${ATP_PMTILES:-$(curl -sf https://alltheplaces-data.openaddresses.io/runs/latest.json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["pmtiles_url"])')}
pmtiles extract "$atp" "$work/atp.pmtiles" --bbox="$bbox" --minzoom=15 --maxzoom=15
tippecanoe-decode -c -f "$work/atp.pmtiles" >"$work/atp.geojsonseq" 2>/dev/null || true

echo "[$name] Overture"
release=${OVERTURE_RELEASE:-$(duckdb -noheader -list -c "
  INSTALL httpfs; LOAD httpfs; SET s3_region='us-west-2';
  SELECT max(regexp_extract(file, 'release/([^/]+)/', 1))
  FROM glob('s3://overturemaps-us-west-2/release/*/theme=places/type=place/*');" | tail -1)}
echo "  release $release"

echo "[$name] merging"
sed -e "s|{WORK}|$work|g" -e "s|{RELEASE}|$release|g" \
  -e "s|{WEST}|$west|g" -e "s|{SOUTH}|$south|g" \
  -e "s|{EAST}|$east|g" -e "s|{NORTH}|$north|g" \
  "$here/merge.sql" >"$work/merge.sql"
(cd "$work" && duckdb -bail places.duckdb <merge.sql)
count=$(wc -l <"$work/places.geojsonseq" | tr -d ' ')
echo "  $count places"

echo "[$name] tiling"
tippecanoe --force --quiet -o "$out/$name.pmtiles" -l places \
  -Z12 -z16 --drop-densest-as-needed --extend-zooms-if-still-dropping \
  --attribution='<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>, <a href="https://www.alltheplaces.xyz/">All the Places</a>, <a href="https://overturemaps.org">Overture Maps</a>' \
  -P "$work/places.geojsonseq"
ls -l "$out/$name.pmtiles"
