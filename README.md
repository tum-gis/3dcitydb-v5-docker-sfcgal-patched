# 3DCityDB with Patched SFCGAL for CityGML Geometric Calculations

A custom Docker image based on [3DCityDB](https://github.com/3dcitydb/3dcitydb) with a patched SFCGAL library that fixes geometry validation errors commonly encountered with LOD2 CityGML building data.

## 🎯 Problem Statement

When calculating 3D volumes (`CG_Volume`), 3D surface areas (`CG_3DArea`), or distances (`CG_Distance`/`CG_3DDistance`) on CityGML building geometries in 3DCityDB v5, validation errors frequently occur:

### Error 1: Planarity Error
```
points don't lie in the same plane
```

### Error 2: Self-Intersection Error
```
PolyhedralSurface is invalid : self intersects : POLYHEDRALSURFACE Z((...))
Solid is invalid : PolyhedralSurface (shell) 0 is invalid: self intersects
```

### Why Do These Errors Occur?

These errors are common in LOD2 CityGML data due to:
- **Minor geometric imperfections** in the data
- **Building part connections** that create tiny self-intersections
- **Automated roof reconstruction** from LiDAR/aerial imagery that isn't perfectly clean
- **Numerical precision limitations** in the source data

The standard SFCGAL library uses extremely strict validation tolerances (`1e-9`) and rejects geometries with even microscopic imperfections — imperfections that have no meaningful practical impact on volume or area calculations, but make CGAL's exact-arithmetic algorithms refuse to proceed.

## ✅ Solution

This Docker image contains a patched version of SFCGAL that:

1. **Relaxes planarity tolerance** from `1e-9` to `1e-2`
2. **Disables self-intersection checks** at the function-definition level (`selfIntersectsImpl<2>`/`<3>` forced to `false` in `intersects.cpp`), so the fix applies consistently regardless of which validation path calls into it
3. **Strips validity assertions** (`SFCGAL_ASSERT_GEOMETRY_VALIDITY`, `_2D`, `_3D`, `_ON_PLANE`) from every file under `src/algorithm/`, so `CG_Volume`, `CG_3DArea`, `CG_Distance`, and `CG_3DDistance` no longer short-circuit on minor geometry defects

## 📦 Quick Start

### Using Pre-built Image from GitHub Container Registry

The image is built and published automatically by GitHub Actions on every push/tag to this
repository, stored in the **GitHub Container Registry (GHCR)** under this repo:

```bash
# For a public repo this works without authentication; for private repos you need to
# `docker login ghcr.io` first (use a token with `read:packages` scope).
docker pull ghcr.io/tum-gis/3dcitydb-v5-docker-sfcgal-patched:v2.3.0
```

Available tags (produced by the release workflow):
- `latest` — always the default branch
- `vX.Y.Z` / `X.Y` — from `v*` semver tags
- `<git-sha>` — the exact commit that was built

> 📌 **Versions at a glance:**
> | Tag | PostgreSQL | PostGIS | SFCGAL | 3DCityDB schema | Base image |
> |---|---|---|---|---|---|
> | `v1.0` | 17 | 3.5 | 1.5.2 (patched) | 5.0.0 | `ghcr.io/3dcitydb/3dcitydb-pg:5.0.0` |
> | `v2.3.0` (current) | 18 | 3.6.2 | 2.3.0 (patched) | 5.1.3 | `3dcitydb/3dcitydb-pg:latest` |
>
> If you have an existing `v1.0` deployment, **do not** swap the image in place on the same volume — PostgreSQL major-version data directories are not cross-compatible. See [Upgrading from v1.0](#-upgrading-from-v10) below.

### Docker Compose Example
```yaml
networks:
  3dcitydbv5-net:
    external: true

volumes:
  3dcitydbv5-data:
    external: true

services:
  3dcitydb:
    image: ghcr.io/tum-gis/3dcitydb-v5-docker-sfcgal-patched:v2.3.0
    container_name: 3dcitydb
    volumes:
      # NOTE: PG18 mounts at /var/lib/postgresql, NOT /var/lib/postgresql/data
      # (the old path causes a crash loop — see Troubleshooting below)
      - 3dcitydbv5-data:/var/lib/postgresql
    ports:
      - "5432:5432"
    networks:
      - 3dcitydbv5-net
    healthcheck:
      test: pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"
      interval: 10s
      timeout: 2s
      retries: 10
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_SCHEMA=${POSTGRES_SCHEMA}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGIS_SFCGAL=${POSTGIS_SFCGAL}
      - SRID=${SRID}

  citydb-tool:
    # Use the `edge` tag — `latest`/1.0.0 only supports schema 5.0.0,
    # while this image ships schema 5.1.3.
    image: ghcr.io/3dcitydb/citydb-tool:edge
    container_name: citydb-tool
    networks:
      - 3dcitydbv5-net
    depends_on:
      3dcitydb:
        condition: service_healthy
    environment:
      - CITYDB_HOST=3dcitydb
      - CITYDB_PORT=5432
      - CITYDB_NAME=${POSTGRES_DB}
      - CITYDB_SCHEMA=${POSTGRES_SCHEMA}
      - CITYDB_USERNAME=${POSTGRES_USER}
      - CITYDB_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./data/:/data
    stdin_open: true
    tty: true
```

### Run with Docker Compose
```bash
docker compose up -d
```

### Import CityGML Data
```bash
docker compose run --rm citydb-tool import citygml /data/your_citygml_file.gml
```

## 🔄 Upgrading from v1.0

`v1.0` (PG17) and `v2.0` (PG18) use **incompatible on-disk data formats** — PostgreSQL cannot read a PG17 data directory with a PG18 server, and vice versa. Swapping the image tag on your existing volume will cause the container to fail to start.

1. **Spin up `v2.0` on a brand-new, empty volume** first and confirm it works (don't touch your `v1.0` data yet):
   ```bash
   docker volume create 3dcitydbv5-data-v2
   ```
2. **Dump your existing `v1.0` data:**
   ```bash
   docker exec <v1_container> pg_dump -U $POSTGRES_USER -d $POSTGRES_DB -F c -f /tmp/backup.dump
   docker cp <v1_container>:/tmp/backup.dump ./backup.dump
   ```
3. **Restore into the new `v2.0` container:**
   ```bash
   docker cp ./backup.dump <v2_container>:/tmp/backup.dump
   docker exec <v2_container> pg_restore -U $POSTGRES_USER -d $POSTGRES_DB -F c /tmp/backup.dump
   ```
4. Verify your data and queries before decommissioning the old `v1.0` container/volume.

## 🔨 Building the Image Yourself

### Prerequisites

- Docker installed on your system
- At least 4GB of free disk space (build requires compiling CGAL and SFCGAL)
- Stable internet connection
- If building on an ARM host (e.g. Apple Silicon) for an `amd64` deployment target, pass `--platform linux/amd64` — expect a noticeably longer build time under emulation (SFCGAL compilation alone can take ~10 minutes natively, 30+ emulated)

### Build Steps

1. **Clone this repository:**
```bash
git clone https://github.com/tum-gis/3dcitydb-v5-docker-sfcgal-patched.git
cd 3dcitydb-v5-docker-sfcgal-patched
```

2. **Build the Docker image:**
```bash
docker build --platform linux/amd64 -t 3dcitydb-v5-docker-sfcgal-patched:latest .
```

> ⏱️ **Note:** The build process takes approximately 10-15 minutes natively (longer under emulation) as it compiles CGAL 5.6 and SFCGAL 2.0.0 from source.

3. **Verify the build picked up the v5 schema (not the legacy v4 `CITYDB_PKG` layout):**
```bash
docker run --rm 3dcitydb-v5-docker-sfcgal-patched:latest ls -la /3dcitydb/
docker run --rm 3dcitydb-v5-docker-sfcgal-patched:latest cat /3dcitydb/version.txt
```
You should see a `sql-scripts/` folder and `version.txt`, and **no** `CITYDB_PKG` directory.

> ℹ️ **Base image tag:** `3dcitydb/3dcitydb-pg:latest` now points to the latest stable 3DCityDB V5 release and is what this Dockerfile is built against. (The older `:edge` tag tracked the v5.x development line; `:latest` has since been aligned to the V5 release.) If you change the base image tag, re-run the check above.

4. **Verify SFCGAL loaded correctly:**
```bash
docker run --rm 3dcitydb-v5-docker-sfcgal-patched:latest bash -c "ldconfig -p | grep -i sfcgal"
```

5. **Replace the 3dcitydb image in your docker compose file with the new image you built.**

## 📊 Usage Examples

> Tables live in the `citydb` schema — queries below qualify them explicitly (`citydb.feature`, `citydb.geometry_data`).

### Calculate Building Volumes
```sql
SELECT 
    f.objectid,
    CG_Volume(CG_MakeSolid(g.geometry)) AS volume_m3
FROM citydb.feature f
JOIN citydb.geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901  -- Buildings
  AND g.geometry IS NOT NULL
  AND ST_GeometryType(g.geometry) = 'ST_PolyhedralSurface';
```

### Calculate 3D Surface Areas
```sql
SELECT 
    f.objectid,
    CG_3DArea(g.geometry) AS surface_area_m2
FROM citydb.feature f
JOIN citydb.geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901
  AND g.geometry IS NOT NULL;
```

### Combined Analysis Query
```sql
SELECT 
    f.objectid,
    CG_Volume(CG_MakeSolid(g.geometry)) AS volume_m3,
    CG_3DArea(g.geometry) AS surface_area_m2
FROM citydb.feature f
JOIN citydb.geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901
  AND g.geometry IS NOT NULL;
```

### Dataset-Wide Validation Check
Confirm the patch is working across your whole dataset (not just a handful of buildings):
```sql
SELECT
    COUNT(*) AS total_buildings,
    SUM(CASE WHEN CG_Volume(CG_MakeSolid(g.geometry)) IS NOT NULL THEN 1 ELSE 0 END) AS volume_computed,
    SUM(CASE WHEN CG_Volume(CG_MakeSolid(g.geometry)) IS NULL THEN 1 ELSE 0 END) AS volume_null,
    ROUND(AVG(CG_Volume(CG_MakeSolid(g.geometry)))::numeric, 2) AS avg_volume_m3
FROM citydb.feature f
JOIN citydb.geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901
  AND g.geometry IS NOT NULL
  AND ST_GeometryType(g.geometry) = 'ST_PolyhedralSurface';
```

### "Buildings Within N Meters" Pattern
SFCGAL has no `ST_DWithin` equivalent. Use `CG_Distance` on bounding-box centroids as a cheap pre-filter (optionally refine with exact `CG_3DDistance` on the smaller result set):
```sql
WITH target_building AS (
    SELECT ST_Centroid(ST_Envelope(g.geometry)) AS centroid
    FROM citydb.feature f
    JOIN citydb.geometry_data g ON g.feature_id = f.id
    WHERE f.objectid = 'YOUR_BUILDING_ID'
    LIMIT 1
)
SELECT
    f.objectid,
    CG_Distance(ST_Centroid(ST_Envelope(g.geometry)), tb.centroid) AS approx_distance_m,
    CG_Volume(CG_MakeSolid(g.geometry)) AS volume_m3
FROM citydb.feature f
JOIN citydb.geometry_data g ON g.feature_id = f.id
CROSS JOIN target_building tb
WHERE f.objectclass_id = 901
  AND f.objectid != 'YOUR_BUILDING_ID'
  AND g.geometry IS NOT NULL
  AND ST_GeometryType(g.geometry) = 'ST_PolyhedralSurface'
  AND CG_Distance(ST_Centroid(ST_Envelope(g.geometry)), tb.centroid) <= 100
ORDER BY approx_distance_m;
```

## ⚠️ Important Notes

### Geometry Closure

- **Closed geometries**: produce **exact** volumes.
- **Non-closed / self-intersecting geometries**: with this patch, produce **approximate** volumes instead of failing outright. Expect deviations under ~1% for typical LOD2 defects.

### Validation Trade-offs

By disabling strict validation, the library will:
- ✅ Successfully process real-world CityGML data with minor imperfections
- ✅ Calculate volumes, areas, and distances that are practically accurate
- ⚠️ Not reject geometries that have minor self-intersections
- ⚠️ Potentially produce inaccurate results for **Boolean operations** (`CG_3DUnion`, `CG_3DIntersection`, `CG_3DDifference`), which are more sensitive to topological correctness than volume/area/distance calculations — use these with extra scrutiny on patched geometries
- ⚠️ Potentially produce slightly inaccurate results for severely malformed geometries

For most CityGML LOD2 data from authoritative sources (e.g., German cadastral data), volume/area/distance results will be accurate and reliable for analysis purposes. **Document the relaxed validation** if publishing results derived from this image.

## 🔧 Technical Details

### Base Image
- `3dcitydb/3dcitydb-pg:latest` (latest stable 3DCityDB V5 release, Debian 13 "trixie")

### Compiled Libraries
- **CGAL**: 5.6
- **SFCGAL**: 2.0.0 (patched, built from the official [SFCGAL GitLab repo](https://gitlab.com/sfcgal/SFCGAL) tag `v2.0.0`)

### PostgreSQL / PostGIS
- PostgreSQL 18
- PostGIS 3.6.2 with SFCGAL support
- 3DCityDB schema v5.1.3

### Patch Locations (for reference / re-applying to future SFCGAL versions)
| File | Patch |
|---|---|
| `src/algorithm/isValid.h` | `1e-9` → `1e-2` tolerance |
| `src/algorithm/intersects.cpp` | `selfIntersectsImpl<2>(...)` / `selfIntersectsImpl<3>(...)` return values forced to `false` |
| `src/algorithm/*.cpp` (all) | `SFCGAL_ASSERT_GEOMETRY_VALIDITY*(...)` calls stripped via `find`/`sed` |

> Note: file layout can change between SFCGAL major versions — e.g. `isSimple.cpp`/`isSimple.h` existed in the 1.x line but were removed/merged by 2.0.0. If rebuilding against a newer SFCGAL tag, re-verify these paths exist before assuming the patch applied (the Dockerfile includes `echo`/`grep` verification steps for this).

## 🐛 Troubleshooting

### Issue: Container stuck in a restart loop with `Error: in 18+, these Docker images are configured to store database data...`

You mounted the volume at `/var/lib/postgresql/data`. PG18's official images require mounting at `/var/lib/postgresql` instead (Postgres manages the major-version subdirectory itself). Fix your `docker-compose.yml` volume path, then wipe and recreate the volume:
```bash
docker compose down
docker volume rm <your-volume-name>
docker volume create <your-volume-name>
docker compose up -d
```

### Issue: `citydb-tool` fails with `UnknownHostException` or connection errors

Usually a symptom of the `3dcitydb` container actually being crash-looped (see above) rather than a real networking problem — check `docker compose ps` for the container's actual status before debugging networking.

### Issue: `The 3DCityDB version X.X.X is not supported. Supported versions are 5.0.0+.`

Your `citydb-tool` version is older than the schema version this image ships. Use `ghcr.io/3dcitydb/citydb-tool:edge` (or whichever tag matches the schema version reported by `SELECT * FROM citydb_pkg.citydb_version();` inside your database — for `v1.0`-era images this function lived under a different path, since v4 used `CITYDB_PKG`).

### Issue: Database has the wrong schema version after first boot (e.g. shows v4.4.0 unexpectedly)

This means the base image tag used doesn't ship the schema version you expected — schema init only runs once on a fresh volume, so once it's wrong you must wipe the volume and start over with the correct base image tag (see the base-image-tag note under "Building the Image Yourself").

### Issue: Volume returns NULL for a building even with the patch applied

Confirm the geometry type is actually `ST_PolyhedralSurface` (the patched functions expect this; other types may behave differently):
```sql
SELECT ST_GeometryType(g.geometry)
FROM citydb.geometry_data g
WHERE g.feature_id = YOUR_FEATURE_ID;
```

### Issue: Build fails with memory error

The CGAL/SFCGAL compilation is memory-intensive. Try:
```bash
docker build --build-arg MAKEFLAGS="-j2" --platform linux/amd64 -t 3dcitydb-v5-docker-sfcgal-patched:latest .
```

## 📄 License

This project applies patches to open-source software:
- **3DCityDB**: Apache License 2.0
- **SFCGAL**: LGPL-2.0-or-later
- **CGAL**: GPL/LGPL

The patches and Dockerfile in this repository are provided under the MIT License.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📚 References

- [3DCityDB Documentation](https://3dcitydb-docs.readthedocs.io/)
- [SFCGAL Documentation](https://sfcgal.gitlab.io/SFCGAL/)
- [PostGIS SFCGAL Functions](https://postgis.net/docs/reference.html#reference_sfcgal)

## 👏 Acknowledgments

- [3DCityDB Team](https://github.com/3dcitydb) for the excellent CityGML database solution
- [SFCGAL Team](https://gitlab.com/sfcgal/SFCGAL) for the powerful 3D geometry library
- [CGAL Project](https://www.cgal.org/) for computational geometry algorithms

## 👤 Contact
- Khaoula Kanna: khaoula.kanna@tum.de
- Prof. Dr. Thomas Kolbe: thomas.kolbe@tum.de
