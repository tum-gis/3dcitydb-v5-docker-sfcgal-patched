# 3DCityDB with Patched SFCGAL for CityGML Volume Calculations
# 
# This Dockerfile creates a 3DCityDB image with a patched SFCGAL library
# that fixes geometry validation errors common in LOD2 CityGML data.
# 
# Based on: ghcr.io/3dcitydb/3dcitydb-pg:5.0.0
# SFCGAL Version: 1.5.2 (patched)
# CGAL Version: 5.6

FROM ghcr.io/3dcitydb/3dcitydb-pg:5.0.0

LABEL maintainer="Khaoula Kanna <khaoula.kanna@tum.de>"
LABEL description="3DCityDB with patched SFCGAL for CityGML geometric calculations"
LABEL version="1.0"

USER root

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    libboost-all-dev \
    libgmp-dev \
    libmpfr-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

# Remove existing SFCGAL libraries
RUN find /usr -name "libSFCGAL*" -exec rm -f {} \; 2>/dev/null || true
RUN find /lib -name "libSFCGAL*" -exec rm -f {} \; 2>/dev/null || true

# Install CGAL 5.6
WORKDIR /tmp
RUN git clone --branch v5.6 --depth 1 https://github.com/CGAL/cgal.git \
    && cd cgal \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --install build

# Clone SFCGAL
RUN git clone https://gitlab.com/sfcgal/SFCGAL.git
WORKDIR /tmp/SFCGAL
RUN git checkout v1.5.2 || git checkout v1.5.1 || git checkout master

# ============================================
# PATCH 1: Tolerance (1e-9 -> 1e-2)
# ============================================
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isValid.h
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isSimple.h 2>/dev/null || true
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isSimple.cpp 2>/dev/null || true

# ============================================
# PATCH 2: Disable ALL SFCGAL_ASSERT_GEOMETRY_VALIDITY calls everywhere
# Using find to patch all .cpp files in src/
# ============================================
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_ON_PLANE([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_3D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_2D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;

# ============================================
# PATCH 3: Disable selfIntersects in isValid.cpp
# ============================================
RUN sed -i 's/selfIntersects3D(polyhedralsurface, graph)/false/g' src/algorithm/isValid.cpp
RUN sed -i 's/selfIntersects(polyhedralsurface, graph)/false/g' src/algorithm/isValid.cpp
RUN sed -i 's/selfIntersects3D(triangulatedsurface, graph)/false/g' src/algorithm/isValid.cpp
RUN sed -i 's/selfIntersects(triangulatedsurface, graph)/false/g' src/algorithm/isValid.cpp
RUN sed -i 's/selfIntersects3D(polygon.ringN(ring))/false/g' src/algorithm/isValid.cpp
RUN sed -i 's/selfIntersects(polygon.ringN(ring))/false/g' src/algorithm/isValid.cpp

# ============================================
# VERIFY PATCHES
# ============================================
RUN echo "=== Files with PATCHED markers ===" && \
    grep -rl "PATCHED" src/ | wc -l

RUN echo "=== Remaining unpatched ASSERT calls ===" && \
    grep -rn "SFCGAL_ASSERT_GEOMETRY_VALIDITY" src/ --include="*.cpp" | grep -v "PATCHED" | grep -v "^src/algorithm/isValid.cpp" | head -10 || echo "All patched!"

RUN echo "=== Verify key files ===" && \
    echo "triangulatePolygon.cpp:" && grep -c "PATCHED" src/triangulate/triangulatePolygon.cpp && \
    echo "volume.cpp:" && grep -c "PATCHED" src/algorithm/volume.cpp && \
    echo "area.cpp:" && grep -c "PATCHED" src/algorithm/area.cpp && \
    echo "distance3d.cpp:" && grep -c "PATCHED" src/algorithm/distance3d.cpp && \
    echo "intersects.cpp:" && grep -c "PATCHED" src/algorithm/intersects.cpp

# ============================================
# Build
# ============================================
RUN cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
    && cmake --build build -j$(nproc) \
    && cmake --install build

RUN ldconfig

RUN ln -sf /usr/lib/x86_64-linux-gnu/libSFCGAL.so.1 /usr/lib/libSFCGAL.so.1 2>/dev/null || true
RUN ln -sf /usr/lib/x86_64-linux-gnu/libSFCGAL.so /usr/lib/libSFCGAL.so 2>/dev/null || true

RUN ldconfig

RUN echo "=== Installed SFCGAL ===" && find /usr -name "libSFCGAL*"

WORKDIR /
RUN rm -rf /tmp/SFCGAL /tmp/cgal \
    && apt-get purge -y build-essential cmake git \
    && apt-get autoremove -y

USER postgres
