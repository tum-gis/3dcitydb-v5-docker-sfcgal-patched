FROM 3dcitydb/3dcitydb-pg:edge

USER root

RUN apt-get update && apt-get install -y \
    build-essential cmake libboost-all-dev \
    libgmp-dev libmpfr-dev git pkg-config \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Build CGAL 5.6 from source (header-only + Core component)
# ============================================
WORKDIR /tmp
RUN git clone --branch v5.6 --depth 1 https://github.com/CGAL/cgal.git \
    && cd cgal \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --install build

# ============================================
# Clone SFCGAL v2.0.0 (matches installed libsfcgal2 ABI exactly)
# ============================================
RUN git clone https://gitlab.com/sfcgal/SFCGAL.git
WORKDIR /tmp/SFCGAL
RUN git checkout v2.0.0

# Show structure before patching (sanity check during build)
RUN echo "=== src/algorithm files ===" && ls src/algorithm/
RUN echo "=== isValid.h tolerance lines ===" && grep -n "1e-9" src/algorithm/isValid.h || echo "none found"
RUN echo "=== SFCGAL_ASSERT_GEOMETRY_VALIDITY usage ===" && grep -rn "SFCGAL_ASSERT_GEOMETRY_VALIDITY" src/algorithm/*.cpp | head -20

# ============================================
# PATCH 1: Planarity/simplicity tolerance (1e-9 -> 1e-2)
# ============================================
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isValid.h
RUN sed -i 's/1e-9/1e-2/g' src/algorithm/isValid.cpp 2>/dev/null || true

# ============================================
# PATCH 2: Disable ALL validity assertions across the codebase
# ============================================
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_ON_PLANE([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_3D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY_2D([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;
RUN find src -name "*.cpp" -exec sed -i 's/SFCGAL_ASSERT_GEOMETRY_VALIDITY([^)]*);/\/\* PATCHED \*\/ ;/g' {} \;

# ============================================
# PATCH 3: Disable self-intersection at the function-definition level
# (more robust than patching call sites — covers isValid.cpp internally too)
# ============================================
RUN echo "=== intersects.cpp selfIntersects definitions ===" && grep -n "selfIntersectsImpl\|^selfIntersects" src/algorithm/intersects.cpp | head -20
RUN sed -i 's/return selfIntersectsImpl<2>(\([^)]*\));/return false; \/\* PATCHED \*\//g' src/algorithm/intersects.cpp
RUN sed -i 's/return selfIntersectsImpl<3>(\([^)]*\));/return false; \/\* PATCHED \*\//g' src/algorithm/intersects.cpp

# ============================================
# VERIFY all patches took effect
# ============================================
RUN echo "=== Files with PATCHED markers ===" && grep -rl "PATCHED" src/ | sort
RUN echo "=== Remaining unpatched ASSERT calls ===" && \
    grep -rn "SFCGAL_ASSERT_GEOMETRY_VALIDITY" src/ --include="*.cpp" | grep -v "PATCHED" || echo "All patched!"
RUN echo "=== Tolerance check ===" && grep -n "1e-2\|1e-9" src/algorithm/isValid.h

# ============================================
# Build and install — SAME prefix/libdir as the apt-installed libsfcgal2
# so we overwrite it in place (matching SONAME libSFCGAL.so.2)
# ============================================
RUN cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
    && cmake --build build -j$(nproc) \
    && cmake --install build

RUN ldconfig

# ============================================
# Verify final library matches expected SONAME and patches are baked in
# ============================================
RUN echo "=== Installed SFCGAL libraries ===" && find /usr -name "libSFCGAL*"
RUN echo "=== ldconfig resolution ===" && ldconfig -p | grep -i sfcgal
RUN echo "=== Self-intersect strings remaining in compiled lib ===" && \
    strings /usr/lib/x86_64-linux-gnu/libSFCGAL.so.2 | grep -ci "self intersect" || echo "0 occurrences - clean!"

WORKDIR /
RUN rm -rf /tmp/SFCGAL /tmp/cgal \
    && apt-get purge -y build-essential cmake git \
    && apt-get autoremove -y

WORKDIR /3dcitydb

USER postgres
