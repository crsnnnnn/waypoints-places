-- Merges OpenStreetMap, AllThePlaces and Overture places for one region
-- into places.geojsonseq, one feature per place, for tippecanoe.
-- bake.sh fills in the {WORK}, {RELEASE} and bounding box placeholders.

INSTALL spatial; LOAD spatial;
INSTALL httpfs; LOAD httpfs;
SET s3_region = 'us-west-2';

-- A name reduced to letters and digits, so "Lidl", "LIDL" and "Lidl "
-- match.
CREATE MACRO name_key(s) AS
  lower(regexp_replace(strip_accents(coalesce(s, '')), '[^A-Za-z0-9]+', '', 'g'));

CREATE MACRO meters(lat1, lon1, lat2, lon2) AS
  6371008.8 * 2 * asin(sqrt(
    pow(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    pow(sin(radians(lon2 - lon1) / 2), 2)));

CREATE MACRO tag(p, k) AS nullif(trim(json_extract_string(p, '$."' || k || '"')), '');

-- The first of OpenStreetMap's main feature keys a place carries, as
-- "key=value".
CREATE MACRO osm_kind(p) AS coalesce(
  'amenity=' || tag(p, 'amenity'), 'shop=' || tag(p, 'shop'),
  'tourism=' || tag(p, 'tourism'), 'leisure=' || tag(p, 'leisure'),
  'office=' || tag(p, 'office'), 'craft=' || tag(p, 'craft'),
  'healthcare=' || tag(p, 'healthcare'));

CREATE TABLE osm AS
SELECT
  1 AS source_rank,
  'osm' AS source,
  upper(substr(tag(properties, '@type'), 1, 1)) || ':' || tag(properties, '@id') AS osm_id,
  upper(substr(tag(properties, '@type'), 1, 1)) || tag(properties, '@id') AS source_id,
  tag(properties, 'name') AS name,
  tag(properties, 'brand') AS brand,
  osm_kind(properties) AS kind,
  coalesce(tag(properties, 'phone'), tag(properties, 'contact:phone')) AS phone,
  coalesce(tag(properties, 'website'), tag(properties, 'contact:website')) AS website,
  tag(properties, 'opening_hours') AS hours,
  ST_Y(ST_Centroid(ST_GeomFromGeoJSON(geometry))) AS lat,
  ST_X(ST_Centroid(ST_GeomFromGeoJSON(geometry))) AS lon,
  0.8 AS confidence
FROM read_json('{WORK}/osm.geojsonseq', format = 'newline_delimited',
  columns = {type: 'VARCHAR', properties: 'JSON', geometry: 'JSON'})
WHERE tag(properties, 'name') IS NOT NULL;

CREATE TABLE atp AS
SELECT
  2 AS source_rank,
  'atp' AS source,
  NULL::VARCHAR AS osm_id,
  coalesce(tag(properties, '@spider'), '') || '/' || coalesce(tag(properties, 'ref'), md5(geometry::VARCHAR)) AS source_id,
  coalesce(tag(properties, 'name'), tag(properties, 'brand')) AS name,
  tag(properties, 'brand') AS brand,
  osm_kind(properties) AS kind,
  coalesce(tag(properties, 'phone'), tag(properties, 'contact:phone')) AS phone,
  coalesce(tag(properties, 'website'), tag(properties, 'contact:website')) AS website,
  tag(properties, 'opening_hours') AS hours,
  ST_Y(ST_GeomFromGeoJSON(geometry)) AS lat,
  ST_X(ST_GeomFromGeoJSON(geometry)) AS lon,
  0.85 AS confidence
FROM read_json('{WORK}/atp.geojsonseq', format = 'newline_delimited',
  columns = {type: 'VARCHAR', properties: 'JSON', geometry: 'JSON'})
WHERE json_extract_string(geometry, '$.type') = 'Point'
  AND coalesce(tag(properties, 'name'), tag(properties, 'brand')) IS NOT NULL;

CREATE TABLE overture AS
SELECT
  3 AS source_rank,
  'overture' AS source,
  NULL::VARCHAR AS osm_id,
  id AS source_id,
  names.primary AS name,
  brand.names.primary AS brand,
  'overture=' || basic_category AS kind,
  phones[1] AS phone,
  websites[1] AS website,
  NULL::VARCHAR AS hours,
  ST_Y(geometry) AS lat,
  ST_X(geometry) AS lon,
  confidence
FROM read_parquet('s3://overturemaps-us-west-2/release/{RELEASE}/theme=places/type=place/*',
  hive_partitioning = 1)
WHERE bbox.xmin >= {WEST} AND bbox.xmax <= {EAST}
  AND bbox.ymin >= {SOUTH} AND bbox.ymax <= {NORTH}
  AND coalesce(operating_status, 'open') = 'open'
  AND names.primary IS NOT NULL;

CREATE TABLE places AS
SELECT row_number() OVER () AS pid, *, name_key(name) AS key,
  floor(lat * 1000)::INTEGER AS cell
FROM (
  SELECT * FROM osm
  UNION ALL BY NAME SELECT * FROM atp
  UNION ALL BY NAME SELECT * FROM overture
)
WHERE lat BETWEEN {SOUTH} AND {NORTH} AND lon BETWEEN {WEST} AND {EAST}
  AND name_key(name) <> '';

-- Records of the same name within 80 m are one place. So are records from
-- different sources within 50 m when one name starts with the other and the
-- shorter has at least five letters: "Saola Coffee" and "Saola Coffee
-- Shop", "Radisson Blu" and "Radisson Blu Hotel Bucharest", but not "ING"
-- and every ING branch.
CREATE TABLE pairs AS
SELECT a.pid AS a, b.pid AS b
FROM places a JOIN places b
  ON substr(a.key, 1, 5) = substr(b.key, 1, 5)
  AND b.cell BETWEEN a.cell - 1 AND a.cell + 1 AND a.pid <> b.pid
WHERE (a.key = b.key AND meters(a.lat, a.lon, b.lat, b.lon) < 80)
   OR (a.source <> b.source
       AND least(length(a.key), length(b.key)) >= 5
       AND (starts_with(a.key, b.key) OR starts_with(b.key, a.key))
       AND meters(a.lat, a.lon, b.lat, b.lon) < 50);

-- A record is kept unless a better one (OpenStreetMap first, then
-- AllThePlaces, then Overture) describes the same place.
CREATE TABLE kept AS
SELECT * FROM places
WHERE pid NOT IN (
  SELECT pairs.b FROM pairs
  JOIN places pa ON pa.pid = pairs.a
  JOIN places pb ON pb.pid = pairs.b
  WHERE pa.source_rank < pb.source_rank
     OR (pa.source_rank = pb.source_rank AND pa.pid < pb.pid)
);

CREATE TABLE merged AS
SELECT
  k.pid, k.source, k.source_id, k.name, k.lat, k.lon, k.confidence,
  coalesce(k.osm_id, arg_min(m.osm_id, m.source_rank) FILTER (WHERE m.osm_id IS NOT NULL)) AS osm_id,
  coalesce(k.brand, arg_min(m.brand, m.source_rank) FILTER (WHERE m.brand IS NOT NULL)) AS brand,
  coalesce(k.kind, arg_min(m.kind, m.source_rank) FILTER (WHERE m.kind IS NOT NULL)) AS kind,
  coalesce(k.phone, arg_min(m.phone, m.source_rank) FILTER (WHERE m.phone IS NOT NULL)) AS phone,
  coalesce(k.website, arg_min(m.website, m.source_rank) FILTER (WHERE m.website IS NOT NULL)) AS website,
  coalesce(k.hours, arg_min(m.hours, m.source_rank) FILTER (WHERE m.hours IS NOT NULL)) AS hours,
  1 + count(DISTINCT m.source) AS sources
FROM kept k
LEFT JOIN pairs pr ON pr.a = k.pid
LEFT JOIN places m ON m.pid = pr.b
GROUP BY k.pid, k.source, k.source_id, k.name, k.lat, k.lon, k.confidence,
  k.osm_id, k.brand, k.kind, k.phone, k.website, k.hours;

-- The app's place categories, from OpenStreetMap tags or Overture's basic
-- category.
CREATE MACRO app_category(kind) AS CASE
  WHEN kind IN ('amenity=cafe', 'overture=coffee_shop', 'overture=cafe') THEN 'coffee'
  WHEN kind IN ('amenity=fuel', 'amenity=charging_station', 'overture=gas_station',
                'overture=ev_charging_station') THEN 'fuel'
  WHEN kind IN ('amenity=parking', 'overture=parking') THEN 'parking'
  WHEN kind IN ('amenity=restaurant', 'amenity=fast_food', 'amenity=bar', 'amenity=pub',
                'amenity=food_court', 'amenity=ice_cream', 'amenity=biergarten',
                'shop=bakery')
       OR kind SIMILAR TO 'overture=.*(restaurant|eatery|bar|pub|bakery|food_court|dessert).*'
       THEN 'food'
  WHEN kind IN ('tourism=hotel', 'tourism=hostel', 'tourism=motel', 'tourism=guest_house',
                'tourism=apartment')
       OR kind SIMILAR TO 'overture=.*(hotel|hostel|motel|lodging|bed_and_breakfast).*'
       THEN 'lodging'
  WHEN kind IN ('tourism=attraction', 'tourism=museum', 'tourism=viewpoint',
                'tourism=gallery', 'tourism=artwork', 'tourism=zoo', 'tourism=theme_park')
       OR kind SIMILAR TO 'overture=.*(museum|historic|landmark|monument|art_gallery|attraction).*'
       THEN 'landmark'
  WHEN kind LIKE 'shop=%'
       OR kind SIMILAR TO 'overture=.*(store|shop|shopping|supermarket|market|pharmacy).*'
       THEN 'shopping'
  ELSE 'other'
END;

-- "amenity=fast_food" → "Fast food", "overture=coffee_shop" → "Coffee shop".
CREATE MACRO kind_label(kind) AS
  upper(substr(replace(split_part(kind, '=', 2), '_', ' '), 1, 1)) ||
  substr(replace(split_part(kind, '=', 2), '_', ' '), 2);

CREATE TABLE final AS
SELECT *,
  app_category(kind) AS category,
  (CASE WHEN brand IS NOT NULL THEN 2 ELSE 0 END) +
  (CASE WHEN website IS NOT NULL THEN 1 ELSE 0 END) +
  (CASE WHEN phone IS NOT NULL THEN 1 ELSE 0 END) +
  (CASE WHEN hours IS NOT NULL THEN 1 ELSE 0 END) +
  (sources - 1) AS prominence
FROM merged
-- Overture places no other source confirms need its confidence.
WHERE NOT (source = 'overture' AND sources = 1 AND confidence < 0.7);

COPY (
  SELECT
    'Feature' AS type,
    {
      'id': substr(md5(source || ':' || source_id), 1, 12),
      'name': name,
      'kind': kind_label(kind),
      'category': category,
      'brand': brand,
      'phone': phone,
      'website': website,
      'hours': hours,
      'osm': osm_id
    } AS properties,
    {'type': 'Point', 'coordinates': [round(lon, 6), round(lat, 6)]} AS geometry,
    -- Prominent places appear from further out.
    {'minzoom': CASE WHEN prominence >= 4 THEN 13 WHEN prominence >= 2 THEN 14 ELSE 15 END}
      AS tippecanoe
  FROM final
  ORDER BY prominence DESC
) TO '{WORK}/places.geojsonseq' (FORMAT JSON);

SELECT source, count(*) AS places, sum(CASE WHEN sources > 1 THEN 1 ELSE 0 END) AS confirmed
FROM final GROUP BY source ORDER BY source;
