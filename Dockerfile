FROM 3dcitydb/3dcitydb-pg:latest

USER root

RUN apt-get update && apt-get install -y \
    build-essential cmake libboost-all-dev \
    libgmp-dev libmpfr-dev git pkg-config \
    nlohmann-json3-dev \ 
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN git clone --branch v5.6 --depth 1 https://github.com/CGAL/cgal.git \
    && cd cgal \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --install build

RUN git clone https://gitlab.com/sfcgal/SFCGAL.git
WORKDIR /tmp/SFCGAL
RUN git checkout v2.3.0    # <-- CHANGED from v2.0.0

# Sanity check before patching
RUN echo "=== src/algorithm files ===" && ls src/algorithm/
RUN echo "=== isValid.h tolerance lines ===" && grep -n "1e-9" src/algorithm/isValid.h || echo "none found"
RUN echo "=== SFCGAL_ASSERT_GEOMETRY_VALIDITY usage ===" && grep -rn "SFCGAL_ASSERT_GEOMETRY_VALIDITY" src/algorithm/*.cpp | head -20

# ============================================
# PATCH 1: Tolerance (1e-9 -> 1e-2)
# isSimple.* is back in v2.3.0 so patch those too
# ============================================
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isValid.h
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isValid.cpp 2>/dev/null || true
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isSimple.h   # <-- ADDED (back in v2.3.0)
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isSimple.cpp # <-- ADDED (back in v2.3.0)

# ============================================
# PATCH 2: Disable ALL validity assertions
# ============================================
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_ON_PLANE([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_3D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_2D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;

# ============================================
# PATCH 3: Disable selfIntersects at function-definition level
# Regex ([^]*) matches any args — works for both v2.0 and v2.3 signatures
# ============================================
RUN echo "=== intersects.cpp selfIntersects definitions ===" && grep -n "selfIntersectsImpl\|^selfIntersects" src/algorithm/intersects.cpp | head -20
RUN sed -i 's/return selfIntersectsImpl<2>(\([^)]*\));/return false; \/\* PATCHED \*\//g' src/algorithm/intersects.cpp
RUN sed -i 's/return selfIntersectsImpl<3>(\([^)]*\));/return false; \/\* PATCHED \*\//g' src/algorithm/intersects.cpp

# ============================================
# VERIFY
# ============================================
RUN echo "=== Files with PATCHED markers ===" && grep -rl "PATCHED" src/ | sort
RUN echo "=== Remaining unpatched ASSERT calls ===" && \
    grep -rn "SFCGAL_ASSERT_GEOMETRY_VALIDITY" src/ --include="*.cpp" | grep -v "PATCHED" || echo "All patched!"
RUN echo "=== Tolerance check ===" && grep -n "1e-2\|1e-9" src/algorithm/isValid.h
RUN echo "=== isSimple tolerance check ===" && grep -n "1e-2\|1e-9" src/algorithm/isSimple.h 2>/dev/null || echo "isSimple.h not found"

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

RUN echo "=== Installed SFCGAL libraries ===" && find /usr -name "libSFCGAL*"
RUN echo "=== ldconfig resolution ===" && ldconfig -p | grep -i sfcgal
RUN echo "=== Self-intersect strings remaining in compiled lib ===" && \
    strings /usr/lib/x86_64-linux-gnu/libSFCGAL.so.2 | grep -ci "self intersect" || echo "0 occurrences - clean!"

# ============================================
# Rebuild PostGIS from source against SFCGAL 2.3.0
#
# The base image ships PostGIS 3.6.4 as a pgdg binary compiled against
# SFCGAL 2.0.0, so PostGIS's version gates
# (#if POSTGIS_SFCGAL_VERSION < 20100 / < 20200 / < 20300) keep the newer
# SFCGAL functions disabled. Rebuilding PostGIS from source against the
# SFCGAL 2.3.0 headers installed above (sfcgal-config reports 2.3.0 ->
# POSTGIS_SFCGAL_VERSION 20300) re-enables them:
#   CG_Simplify, CG_3DAlphaWrapping            (need SFCGAL >= 2.1.0)
#   CG_ExtrudeStraightSkeleton, CG_Visibility  (need SFCGAL >= 2.2.0)
#   CG_Tesselate                              (need SFCGAL >= 2.3.0)
#
# This MUST run before the cleanup step below, which purges
# build-essential/cmake/git (all needed here) while still root.
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool pkg-config cmake git \
    libgeos-dev libproj-dev libxml2-dev \
    libprotobuf-dev libprotobuf-c-dev protobuf-c-compiler protobuf-compiler \
    libjson-c-dev libpcre2-dev libgdal-dev libsqlite3-dev \
    postgresql-server-dev-18 \
    && echo "sfcgal-config reports: $(sfcgal-config --version)" \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN git clone --branch 3.6.4 --depth 1 https://github.com/postgis/postgis.git \
    && cd postgis \
    && ./autogen.sh \
    && ./configure \
        --prefix=/usr \
        --with-sfcgal \
        --with-geos \
        --with-proj \
        --with-gdal \
        --without-libzip \
    && grep -a "define POSTGIS_SFCGAL_VERSION" postgis_config.h \
    && make -j$(nproc) \
    && make install \
    && ldconfig

WORKDIR /
RUN rm -rf /tmp/SFCGAL /tmp/cgal /tmp/postgis \
    && apt-get purge -y build-essential cmake git \
    && apt-get autoremove -y

WORKDIR /3dcitydb

USER postgres
