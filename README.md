# Waypoints places

Map places merged from three open sources and baked into PMTiles, one archive
per region, published monthly as [releases](../../releases/latest).

| Source | License |
| --- | --- |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) | ODbL 1.0 |
| [All the Places](https://www.alltheplaces.xyz/) | CC0 |
| [Overture Maps places](https://docs.overturemaps.org/attribution/) | CDLA Permissive 2.0 |

A place found by more than one source keeps OpenStreetMap's position and takes
phone, website, opening hours and brand from whichever source has them.

## License

The baked data is a derivative of OpenStreetMap and is available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
© OpenStreetMap contributors. The scripts in this repository may be used under
the same terms.

## Baking a region

```bash
./bake.sh romania 20.2,43.6,29.8,48.3 https://download.geofabrik.de/europe/romania-latest.osm.pbf out
```

Needs `duckdb`, `osmium`, `pmtiles`, `tippecanoe` and `python3`. Add a region to
`regions.json` to have the workflow bake it.
