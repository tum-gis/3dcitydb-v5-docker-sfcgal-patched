# 3DCityDB with Patched SFCGAL for CityGML Geometric Calculations

A custom Docker image based on [3DCityDB](https://github.com/3dcitydb/3dcitydb) with a patched SFCGAL library that fixes geometry validation errors commonly encountered with LOD2 CityGML building data.

## 🎯 Problem Statement

When calculating 3D volumes (`CG_Volume`) and 3D surface areas (`CG_3DArea`) on CityGML building geometries in 3DCityDB v5, two validation errors frequently occur:

### Error 1: Planarity Error
```
points don't lie in the same plane
```

### Error 2: Self-Intersection Error
```
PolyhedralSurface is invalid : self intersects : POLYHEDRALSURFACE Z((...))
```

### Why Do These Errors Occur?

These errors are common in LOD2 CityGML data due to:
- **Minor geometric imperfections** in the data
- **Building part connections** that create tiny self-intersections
- **Numerical precision limitations** in the source data

The standard SFCGAL library uses extremely strict validation tolerances (`1e-9`) that reject geometries with even microscopic imperfections - imperfections that have no practical impact on volume or area calculations.

## ✅ Solution

This Docker image contains a patched version of SFCGAL that:

1. **Relaxes planarity tolerance** from `1e-9` to `1e-2`
2. **Disables strict self-intersection checks** during geometry operations
3. **Removes validation assertions** that block volume/area calculations

## 📦 Quick Start

### Using Pre-built Image from Docker Hub
```bash
docker pull khaoulakanna1/3dcitydb-v5-docker-sfcgal-patched:v1.0
```

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
    image: khaoulakanna1/3dcitydb-v5-docker-sfcgal-patched:v1.0
    container_name: 3dcitydb
    volumes:
      - 3dcitydbv5-data:/var/lib/postgresql/data
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
    image: ghcr.io/3dcitydb/citydb-tool
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
docker-compose up -d
```

## 🔨 Building the Image Yourself

### Prerequisites

- Docker installed on your system
- At least 4GB of free disk space (build requires compiling CGAL and SFCGAL)
- Stable internet connection

### Build Steps

1. **Clone this repository:**
```bash
git clone https://github.com/tum-gis/3dcitydb-v5-docker-sfcgal-patched.git
cd 3dcitydb-v5-docker-sfcgal-patched
```

2. **Build the Docker image:**
```bash
docker build -t 3dcitydb-v5-docker-sfcgal-patched:latest .
```

> ⏱️ **Note:** The build process takes approximately 10-15 minutes as it compiles CGAL 5.6 and SFCGAL 1.5.2 from source.

3. **Verify the build:**
```bash
docker run --rm 3dcitydb-v5-docker-sfcgal-patched:latest psql --version
```

4. **Replace the 3dcitydb image in your docker compose file with the new image you built.**

## 📊 Usage Examples

### Calculate Building Volumes
```sql
-- Calculate volume for all closed building geometries
SELECT 
    f.objectid,
    CG_Volume(CG_MakeSolid(g.geometry)) AS volume_m3
FROM feature f
JOIN geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901  -- Buildings
  AND g.geometry IS NOT NULL
```

### Calculate 3D Surface Areas
```sql
-- Calculate 3D surface area for building geometries
SELECT 
    f.objectid,
    CG_3DArea(g.geometry) AS surface_area_m2
FROM feature f
JOIN geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901
  AND g.geometry IS NOT NULL;
```

### Combined Analysis Query
```sql
-- Full building analysis with volume and surface area
SELECT 
    f.objectid,
    ST_IsClosed(g.geometry) AS is_closed,
    CASE 
        WHEN ST_IsClosed(g.geometry) 
        THEN CG_Volume(CG_MakeSolid(g.geometry))
        ELSE NULL 
    END AS volume_m3,
    CG_3DArea(g.geometry) AS surface_area_m2
FROM feature f
JOIN geometry_data g ON g.feature_id = f.id
WHERE f.objectclass_id = 901
  AND g.geometry IS NOT NULL;
```

## ⚠️ Important Notes

### Geometry Closure

- **Closed geometries** (`ST_IsClosed = true`): Volume calculation will work
- **Non-closed geometries** (`ST_IsClosed = false`): produce approximate volumes (small gaps may cause minor inaccuracies)
### Validation Trade-offs

By disabling strict validation, the library will:
- ✅ Successfully process real-world CityGML data with minor imperfections
- ✅ Calculate volumes and areas that are practically accurate
- ⚠️ Not reject geometries that have minor self-intersections
- ⚠️ Potentially produce slightly inaccurate results for severely malformed geometries

For most CityGML LOD2 data from authoritative sources (e.g., German cadastral data), the results will be accurate and reliable.

## 🔧 Technical Details

### Base Image
- `ghcr.io/3dcitydb/3dcitydb-pg:5.0.0`

### Compiled Libraries
- **CGAL**: 5.6
- **SFCGAL**: 1.5.2 (patched)

### PostgreSQL Extensions
- PostGIS with SFCGAL support
- 3DCityDB schema

## 🐛 Troubleshooting

### Issue: Volume returns 0 for a building

Check if the geometry is closed:
```sql
SELECT ST_IsClosed(g.geometry) 
FROM geometry_data g 
WHERE g.feature_id = YOUR_FEATURE_ID;
```

If `false`, the geometry cannot form a valid solid.

### Issue: Build fails with memory error

The CGAL/SFCGAL compilation is memory-intensive. Try:
```bash
# Limit parallel jobs during build
docker build --build-arg MAKEFLAGS="-j2" -t 3dcitydb-v5-docker-sfcgal-patched:latest .
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
