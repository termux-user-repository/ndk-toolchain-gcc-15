#!/bin/bash
#  build.sh - script to build a custom NDK toolchain
#
#  Copyright 2022 Chongyun Lee <uchkks@protonmail.com>
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

set -e -u -o pipefail

_SCRIPTDIR=$(cd "$(realpath "$(dirname "$0")")"; pwd)
source $_SCRIPTDIR/common-files/setup_toolchain_ndk_r17c.sh
source $_SCRIPTDIR/common-files/termux_download.sh

: ${TOOLCHAIN_ARCH:=aarch64}
: ${_CACHE_DIR:=$_SCRIPTDIR/cache}
: ${_TMP_DIR:=$_SCRIPTDIR/tmp}
: ${_API_LEVEL:=21}
: ${_MAKE_PROCESSES:=$(nproc)}
: ${GCC_VERSION:=15.1.0}
: ${GCC_SHA256:=51b9919ea69c980d7a381db95d4be27edf73b21254eb13d752a08003b4d013b1}
: ${BINUTILS_VERSION:=2.44}
: ${BINUTILS_SHA256:=0cdd76777a0dfd3dd3a63f215f030208ddb91c2361d2bcc02acec0f1c16b6a2e}

export TOOLCHAIN_ARCH

TERMUX_PKG_TMPDIR=$_TMP_DIR
mkdir -p $_CACHE_DIR
rm -rf $_TMP_DIR
mkdir -p $_TMP_DIR

_HOST_PLATFORM="${TOOLCHAIN_ARCH}-linux-android"

_GCC_EXTRA_HOST_BUILD=""
_BINUTILS_EXTRA_HOST_BUILD="--enable-gold"
if [ "$TOOLCHAIN_ARCH" = "arm" ]; then
	_HOST_PLATFORM="${_HOST_PLATFORM}eabi"
	_GCC_EXTRA_HOST_BUILD="--with-arch=armv7-a --with-float=soft --with-fpu=vfp"
elif [ "$TOOLCHAIN_ARCH" = "aarch64" ]; then
	_GCC_EXTRA_HOST_BUILD="--enable-fix-cortex-a53-835769 --enable-fix-cortex-a53-843419"
	_BINUTILS_EXTRA_HOST_BUILD+=" $_GCC_EXTRA_HOST_BUILD"
elif [ "$TOOLCHAIN_ARCH" = "i686" ]; then
	_GCC_EXTRA_HOST_BUILD="--with-arch=i686 --with-fpmath=sse "
elif [ "$TOOLCHAIN_ARCH" = "x86_64" ]; then
	_GCC_EXTRA_HOST_BUILD="--with-arch=x86-64 --with-fpmath=sse"
fi

# Install dependencies
sudo apt update
sudo apt install -y build-essential curl
sudo apt install -y libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev libisl-dev

pushd $_TMP_DIR

# Download source
GCC_SRC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.gz
GCC_SRC_FILE=$_CACHE_DIR/gcc-${GCC_VERSION}.tar.gz
GCC_SRC_DIR=$_TMP_DIR/gcc-${GCC_VERSION}
termux_download $GCC_SRC_URL $GCC_SRC_FILE $GCC_SHA256
BINUTILS_SRC_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.gz
BINUTILS_SRC_FILE=$_CACHE_DIR/binutils-${BINUTILS_VERSION}.tar.gz
BINUTILS_SRC_DIR=$_TMP_DIR/binutils-${BINUTILS_VERSION}
termux_download $BINUTILS_SRC_URL $BINUTILS_SRC_FILE $BINUTILS_SHA256

# Setup a standalone toolchain
_setup_standalone_toolchain_ndk_r17c $_TMP_DIR/standalone-toolchain
cp -R $_TMP_DIR/standalone-toolchain/sysroot/usr/include/$_HOST_PLATFORM/* $_TMP_DIR/standalone-toolchain/sysroot/usr/include/

# Extract source
tar -xf $GCC_SRC_FILE -C $_TMP_DIR/
pushd $_TMP_DIR
PATCHES="$(find "$_SCRIPTDIR/patches/" -maxdepth 1 -type f -name *.patch | sort)"
for f in $PATCHES; do
	echo "Applying patch: $(basename $f)"
	patch -d "$GCC_SRC_DIR/" -p1 < "$f";
done
tar -xf $BINUTILS_SRC_FILE -C $_TMP_DIR/
popd

# Copy sysroot
mkdir -p $_TMP_DIR/newer-toolchain
cp -R $_TMP_DIR/standalone-toolchain/sysroot $_TMP_DIR/newer-toolchain/

# Set CPPFLAGS/CFLAGS/CXXFLAGS
export CPPFLAGS="-O3 -g0"
export CFLAGS="$CPPFLAGS"
export CXXFLAGS="$CPPFLAGS"

# Build binutils
mkdir -p binutils-build
pushd binutils-build
$BINUTILS_SRC_DIR/configure \
		--target=$_HOST_PLATFORM \
		--prefix=$_TMP_DIR/newer-toolchain \
		--with-sysroot=$_TMP_DIR/newer-toolchain/sysroot \
		--with-zstd \
		ZSTD_LIBS=-l:libzstd.a \
		$_BINUTILS_EXTRA_HOST_BUILD
make -j $_MAKE_PROCESSES
make -j $_MAKE_PROCESSES install-strip
popd # binutils-build

export PATH="$_TMP_DIR/newer-toolchain/bin:$PATH"

# Build GCC toolchain
mkdir -p newer-toolchain-build
pushd newer-toolchain-build

export CPPFLAGS+=" -D__ANDROID_API__=$_API_LEVEL"
export CFLAGS+=" -D__ANDROID_API__=$_API_LEVEL"
export CXXFLAGS+=" -D__ANDROID_API__=$_API_LEVEL"

$GCC_SRC_DIR/configure \
		--host=x86_64-linux-gnu  \
		--build=x86_64-linux-gnu \
		--target=$_HOST_PLATFORM \
		--disable-shared \
		--disable-nls \
		--enable-default-pie \
		--with-host-libstdcxx='-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm' \
		--with-gnu-as --with-gnu-ld \
		--disable-libstdc__-v3 \
		--disable-tls \
		--disable-ssp \
		--disable-bootstrap \
		--enable-initfini-array \
		--enable-libatomic-ifuncs=no \
		--prefix=$_TMP_DIR/newer-toolchain \
		--with-gmp --with-mpfr --with-mpc --with-system-zlib \
		--enable-languages=c,c++,fortran \
		--enable-plugins --enable-libgomp \
		--enable-gnu-indirect-function \
		--disable-libcilkrts --disable-libsanitizer \
		--enable-gold --enable-threads \
		--enable-eh-frame-hdr-for-static \
		--enable-graphite=yes --with-isl \
		--disable-multilib \
		$_GCC_EXTRA_HOST_BUILD \
		--with-sysroot=$_TMP_DIR/newer-toolchain/sysroot \
		--with-gxx-include-dir=$_TMP_DIR/newer-toolchain/include/c++/$GCC_VERSION

make -j $_MAKE_PROCESSES
make -j $_MAKE_PROCESSES install-strip

popd # newer-toolchain-build

# Make the archive
mv newer-toolchain gcc-$GCC_VERSION-$TOOLCHAIN_ARCH
tar -cjvf gcc-$GCC_VERSION-$TOOLCHAIN_ARCH.tar.bz2 gcc-$GCC_VERSION-$TOOLCHAIN_ARCH

popd # $_TMP_DIR

# Copy the archive
mkdir -p build
cp $_TMP_DIR/gcc-$GCC_VERSION-$TOOLCHAIN_ARCH.tar.bz2 ./build
