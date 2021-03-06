#!/usr/bin/env bash

UNAME=$(uname -s)

# http://nothingworks.donaitken.com/2012/04/returning-booleans-from-bash-functions
function is_set {
    # usage:
    # is_set $variable
    local R=0; # 0=true
    if [[ "${1:-unset_val}" == "unset_val" ]]; then
        R=1 # false
    fi
    return $R;
}

function contains {
    # usage:
    # contains substring fullstring
    local R=0; # 0=true
    if [[ "${2#*$1}" == $2 ]]; then
        R=1 # false
    fi
    return $R;
}

function eq {
    # usage:
    # eq $var1 value
    local R=0; # 0=true
    if [[ "${1}" != $2 ]]; then
        R=1 # false
    fi
    return $R;
}

function b {
  if eq $QUIET true; then
    $1 1>> build.log
  else
    $1
  fi
}

function setup {
  set -e
  upgrade_compiler
  prepare_os
}

function teardown {
  set +e
}

function upgrade_gcc {
    if [[ $(lsb_release --id) =~ "Ubuntu" ]]; then
        echo "adding gcc-4.8 ppa"
        sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
    fi
    echo "updating apt"
    sudo apt-get update -y
    if [[ $(lsb_release --id) =~ "Ubuntu" ]]; then
        echo "installing C++11 compiler"
        sudo apt-get install -qq -y gcc-4.8 g++-4.8
        export CC="gcc-4.8"
        export CXX="g++-4.8"
    fi
}

function upgrade_clang {
    if [[ $(lsb_release --id) =~ "Ubuntu" ]]; then
        echo "adding ubuntu-toolchain-r ppa"
        sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
        sudo apt-get update -y
    fi
    sudo apt-get install -y libstdc++-4.9-dev
    if [[ ! -d ./.mason ]]; then
      mkdir .mason && curl -sSfL https://github.com/mapbox/mason/archive/v0.5.0.tar.gz | tar --gunzip --extract --strip-components=1 --directory=./.mason
    fi
    ./.mason/mason install clang++ 3.9.1
    export PATH=$(./.mason/mason prefix clang++ 3.9.1)/bin:${PATH}
    export CXX=clang++-3.9
    export CC=clang-3.9
}

function upgrade_compiler {
    local CROSS_COMPILING=${CROSS_COMPILING:-false}
    if [[ ${UNAME} == 'Linux' ]] && [[ $CROSS_COMPILING == false ]]; then
        if [[ ! `which sudo` ]]; then
          apt-get install sudo
        fi
        sudo apt-get install -y curl lsb-release git
        upgrade_clang
    fi
}

function prep_linux {
  cd osx
  echo "installing build tools"
  if [[ ! `which sudo` ]]; then
    apt-get install sudo
  fi
  sudo apt-get install -qq -y curl lsb-release pkg-config build-essential git cmake zlib1g-dev unzip make libtool autotools-dev automake realpath autoconf ragel
  if [[ "${MP_PLATFORM:-false}" != false ]]; then
      source ${MP_PLATFORM}.sh
  else
      source Linux.sh
  fi
}

function prep_osx {
  cd osx
  brew install autoconf automake libtool makedepend cmake ragel || true
  # NOTE: this needs to be set before sourcing the platform
  # to ensure that homebrew commands like protoc are not used
  export PATH=$(brew --prefix)/bin:$PATH
  if [[ "${MP_PLATFORM:-false}" != false ]]; then
      source ${MP_PLATFORM}.sh
  else
      source MacOSX.sh
  fi
}

function prepare_os {
  if [[ ${UNAME} == 'Linux' ]]; then
      prep_linux
      sudo apt-get install -qq -y subversion
  else
      prep_osx
  fi
  mkdir -p ${BUILD}
  mkdir -p ${BUILD}/lib
  mkdir -p ${BUILD}/include
  echo "Running build with ${JOBS} parallel jobs"
  echo "checking cpu and mem resources"
  nprocs
  memsize
}


: '
Actual apps. We setup and teardown when building these
so that the set -e and PATH does not break the parent
environment in odd ways if this script is sourced
'

function build_mapnik {
  setup
  if [[ ${UNAME} == 'Linux' ]]; then
      # postgres deps
      # https://github.com/mapnik/mapnik-packaging/commit/598db68f4e5314883023eb6048e94ba7c021b6b7
      #sudo apt-get install -qq -y libpam0g-dev libgss-dev libkrb5-dev libldap2-dev libavahi-compat-libdnssd-dev
      echo "removing potentially conflicting libraries"
      # remove travis default installed libs which will conflict
      sudo apt-get purge -qq -y libtiff* libjpeg* libpng3
      sudo apt-get autoremove -y -qq
  fi
  b ./scripts/build_icu.sh
  BOOST_LIBRARIES="--with-thread --with-filesystem --disable-filesystem2 --with-system --with-regex"
  if [ ${BOOST_ARCH} != "arm" ]; then
      BOOST_LIBRARIES="$BOOST_LIBRARIES --with-program_options"
      # --with-chrono --with-iostreams --with-date_time --with-atomic --with-timer --with-program_options --with-test
  fi
  ./scripts/build_boost.sh ${BOOST_LIBRARIES}
  b ./scripts/build_freetype.sh
  b ./scripts/build_harfbuzz.sh
  b ./scripts/build_jpeg_turbo.sh
  b ./scripts/build_png.sh
  b ./scripts/build_proj4.sh
  b ./scripts/build_tiff.sh
  # note: webp's cwebp program wants
  # to link to tiff/jpeg/png
  b ./scripts/build_webp.sh
  b ./scripts/build_sqlite.sh
  #./scripts/build_geotiff.sh
  if [[ ${BOOST_ARCH} != "arm" ]]; then
    b ./scripts/build_expat.sh
    b ./scripts/build_postgres.sh
    if [[ "${MINIMAL_MAPNIK:-false}" == false ]]; then
      b ./scripts/build_gdal.sh
      b ./scripts/build_pixman.sh
      b ./scripts/build_cairo.sh
    fi
  fi
  if [[ "${MAPNIK_BRANCH:-false}" == false ]]; then
        export MAPNIK_BRANCH="master"
  fi
  if [ ! -d ${MAPNIK_SOURCE} ]; then
      git clone --quiet https://github.com/mapnik/mapnik.git ${MAPNIK_SOURCE}
      (cd ${MAPNIK_SOURCE} && git checkout ${MAPNIK_BRANCH} && git branch -v)

  else
      (cd ${MAPNIK_SOURCE} && git fetch -v && git checkout ${MAPNIK_BRANCH} && git branch -v)
  fi
  ./scripts/build_mapnik.sh
  ./scripts/post_build_fix.sh
  ./scripts/test_mapnik.sh
  ./scripts/package_mobile_sdk.sh
  teardown
}

function build_osrm {
  setup
  b ./scripts/build_tbb.sh
  b ./scripts/build_expat.sh
  b ./scripts/build_lua.sh
  b ./scripts/build_zlib.sh
  b ./scripts/build_bzip2.sh
  # TODO: osrm boost usage does not need icu
  ./scripts/build_boost.sh --with-test --with-iostreams --with-date_time --with-program_options --with-thread --with-filesystem --disable-filesystem2 --with-system --with-regex
  b ./scripts/build_protobuf.sh
  b ./scripts/build_osm-pbf.sh
  b ./scripts/build_luabind.sh
  b ./scripts/build_libstxxl.sh
  ./scripts/build_osrm.sh
  teardown
}

export -f build_osrm

function build_osmium {
  setup
  b ./scripts/build_proj4.sh
  b ./scripts/build_expat.sh
  b ./scripts/build_google_sparsetable.sh
  # TODO: osrm boost usage does not need icu
  ./scripts/build_boost.sh --with-test --with-program_options
  b ./scripts/build_protobuf.sh
  b ./scripts/build_osm-pbf.sh
  #b ./scripts/build_cryptopp.sh
  teardown
}

export -f build_osmium

function mobile_tools {
  setup
  if [[ ${UNAME} == 'Linux' ]]; then
      sudo apt-get install -qq -y xutils-dev # for gccmakedep used in openssl
  fi
  b ./scripts/build_zlib.sh
  b ./scripts/build_libuv.sh
  b ./scripts/build_openssl.sh
  b ./scripts/build_curl.sh
  b ./scripts/build_protobuf.sh
  b ./scripts/build_google_sparsetable.sh
  b ./scripts/build_freetype.sh
  b ./scripts/build_harfbuzz.sh
  b ./scripts/build_libxml2.sh
  b ./scripts/build_jpeg_turbo.sh
  b ./scripts/build_png.sh
  b ./scripts/build_webp.sh
  b ./scripts/build_tiff.sh
  b ./scripts/build_sqlite.sh
  ./scripts/build_boost.sh --with-regex
  teardown
}
export -f mobile_tools

function build_http {
  setup
  if [[ ${UNAME} == 'Linux' ]]; then
      sudo apt-get install -qq -y xutils-dev # for gccmakedep used in openssl
  fi
  b ./scripts/build_zlib.sh
  b ./scripts/build_libuv.sh
  b ./scripts/build_openssl.sh
  b ./scripts/build_curl.sh
  ./scripts/build_boost.sh --with-regex
  #b ./scripts/build_glfw.sh
  teardown
}
export -f build_http

function build_osm2pgsql {
  setup
  b ./scripts/build_bzip2.sh
  b ./scripts/build_geos.sh
  b ./scripts/build_proj4.sh
  b ./scripts/build_postgres.sh
  b ./scripts/build_protobuf.sh
  b ./scripts/build_protobuf_c.sh
  teardown
}
export -f build_osm2pgsql

function build_liblas {
  setup
  b ./scripts/build_zlib.sh
  b ./scripts/build_jpeg_turbo.sh
  b ./scripts/build_png.sh
  b ./scripts/build_tiff.sh
  b ./scripts/build_proj4.sh
  b ./scripts/build_geotiff.sh
  b ./scripts/build_geos.sh
  b ./scripts/build_sqlite.sh
  b ./scripts/build_spatialite.sh
  b ./scripts/build_expat.sh
  b ./scripts/build_postgres.sh
  b ./scripts/build_gdal.sh
  b ./scripts/build_laszip.sh
  ./scripts/build_boost.sh --with-thread --with-program_options
  b ./scripts/build_liblas.sh
  teardown
}
export -f build_liblas
