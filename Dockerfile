# create an up-to-date base image for everything
FROM debian:sid AS base

RUN \
  apt-get update && apt-get upgrade -y

# run-time dependencies

RUN \
  apt-get install -y \
    7zip \
    bash \
    curl \
    openssl \
    qt6-base-dev \
    libqt6sql6-sqlite \
    qt6-base-private-dev \
    libssl3 \
    python3 \
    tini \
    tzdata \
    zlib1g \
    gnupg \
    lsb-release \
    sudo \
    jq \
    ipcalc

RUN curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list
RUN apt-get update && apt-get install -y cloudflare-warp && apt-get clean && apt-get autoremove -y

# image for building
FROM base AS builder

ARG QBT_VERSION \
    BOOST_VERSION_MAJOR="1" \
    BOOST_VERSION_MINOR="86" \
    BOOST_VERSION_PATCH="0" \
    LIBBT_VERSION="RC_1_2" \
    LIBBT_CMAKE_FLAGS=""

# check environment variables
RUN \
  if [ -z "${QBT_VERSION}" ]; then \
    echo 'Missing QBT_VERSION variable. Check your command line arguments.' && \
    exit 1 ; \
  fi

# alpine linux packages:
# https://git.alpinelinux.org/aports/tree/community/libtorrent-rasterbar/APKBUILD
# https://git.alpinelinux.org/aports/tree/community/qbittorrent/APKBUILD

RUN echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid.list \
 && printf "Package: *\nPin: release a=unstable\nPin-Priority: 100\n\n" > /etc/apt/preferences.d/pin-sid > /etc/apt/preferences.d/pin-sid \
 && apt-get update

RUN \
  apt-get install -y \
    wget \
    cmake \
    git \
    g++ \
    make \
    ninja-build \
    libssl-dev \
    zlib1g-dev \
    qt6-tools-dev-tools \
    qt6-tools-dev

# compiler, linker options:
# https://gcc.gnu.org/onlinedocs/gcc/Option-Summary.html
# https://gcc.gnu.org/onlinedocs/gcc/Link-Options.html
# https://sourceware.org/binutils/docs/ld/Options.html
ENV CFLAGS="-pipe -fstack-clash-protection -fstack-protector-strong -fno-plt -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS" \
    CXXFLAGS="-pipe -fstack-clash-protection -fstack-protector-strong -fno-plt -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS" \
    LDFLAGS="-gz -Wl,-O1,--as-needed,--sort-common,-z,now,-z,pack-relative-relocs,-z,relro"

# prepare boost
RUN \
  wget -O boost.tar.gz "https://archives.boost.io/release/$BOOST_VERSION_MAJOR.$BOOST_VERSION_MINOR.$BOOST_VERSION_PATCH/source/boost_${BOOST_VERSION_MAJOR}_${BOOST_VERSION_MINOR}_${BOOST_VERSION_PATCH}.tar.gz" && \
  tar -xf boost.tar.gz && \
  mv boost_* boost && \
  cd boost && \
  ./bootstrap.sh && \
  ./b2 stage --stagedir=./ --with-headers

# build libtorrent
RUN \
  git clone \
    --branch "${LIBBT_VERSION}" \
    --depth 1 \
    --recurse-submodules \
    https://github.com/arvidn/libtorrent.git && \
  cd libtorrent && \
  cmake \
    -B build \
    -G Ninja \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DBOOST_ROOT=/boost/lib/cmake \
    -Ddeprecated-functions=OFF \
    $LIBBT_CMAKE_FLAGS && \
  cmake --build build -j $(nproc) && \
  cmake --install build

# build qbittorrent
RUN \
  if [ "${QBT_VERSION}" = "devel" ]; then \
    git clone \
      --depth 1 \
      --recurse-submodules \
      https://github.com/qbittorrent/qBittorrent.git && \
    cd qBittorrent ; \
  else \
    wget "https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-${QBT_VERSION}.tar.gz" && \
    tar -xf "release-${QBT_VERSION}.tar.gz" && \
    cd "qBittorrent-release-${QBT_VERSION}" ; \
  fi && \
  cmake \
    -B build \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DBOOST_ROOT=/boost/lib/cmake \
    -DGUI=OFF && \
  cmake --build build -j $(nproc) && \
  cmake --install build

RUN \
  ldd /usr/bin/qbittorrent-nox | sort -f

# record compile-time Software Bill of Materials (sbom)
RUN \
  printf "Software Bill of Materials for building qbittorrent-nox\n\n" >> /sbom.txt && \
  echo "boost $BOOST_VERSION_MAJOR.$BOOST_VERSION_MINOR.$BOOST_VERSION_PATCH" >> /sbom.txt && \
  cd libtorrent && \
  echo "libtorrent-rasterbar git $(git rev-parse HEAD)" >> /sbom.txt && \
  cd .. && \
  if [ "${QBT_VERSION}" = "devel" ]; then \
    cd qBittorrent && \
    echo "qBittorrent git $(git rev-parse HEAD)" >> /sbom.txt && \
    cd .. ; \
  else \
    echo "qBittorrent ${QBT_VERSION}" >> /sbom.txt ; \
  fi && \
  echo >> /sbom.txt && \
  apt list --installed | sort >> /sbom.txt && \
  cat /sbom.txt

# image for running
FROM base

RUN \
  useradd -m -s /bin/bash -u 1000 qbtUser && \
  echo "qbtUser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/qbt && \
  echo 'Defaults env_keep += "WARP_SLEEP REGISTER_WHEN_MDM_EXISTS WARP_LICENSE_KEY WARP_ENABLE_NAT"' > /etc/sudoers.d/env_keep

USER qbtUser

RUN mkdir -p /home/qbtUser/.local/share/warp && \
    echo -n 'yes' > /home/qbtUser/.local/share/warp/accepted-tos.txt

ENV WARP_SLEEP=5
ENV REGISTER_WHEN_MDM_EXISTS=
ENV WARP_LICENSE_KEY=
ENV WARP_ENABLE_NAT=

USER root

COPY --from=builder /usr/bin/qbittorrent-nox /usr/bin/qbittorrent-nox

COPY --from=builder /sbom.txt /sbom.txt

COPY entrypoint.sh /entrypoint.sh
COPY qbt-entrypoint.sh /qbt-entrypoint.sh
COPY warp-entrypoint.sh /warp-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/entrypoint.sh"]
