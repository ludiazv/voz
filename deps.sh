#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

echo "Dependencies script for voz"
echo "SD=$SCRIPT_DIR"


# CONF VARS
MODELS_DIR="${SCRIPT_DIR}/models"
WWMODELS_DIR="${SCRIPT_DIR}/wwmodels"
MODELS_VER="v0.5.1"
MODELS=( "melspectrogram.tflite" "embedding_model.tflite" )
WWMODELS=("alexa_v0.1.tflite" "hey_jarvis_v0.1.tflite" "hey_mycroft_v0.1.tflite" "hey_rhasspy_v0.1.tflite" )


LIBS_DIR="${SCRIPT_DIR}/lib"
DIST_DIR="${SCRIPT_DIR}/dist"
TF_VERSION="v2.15.0"
WRTC_VERSION="v1.2.3b"
TMP_LIBS="${SCRIPT_DIR}/tmp_libs"
#TF_TMP="tmp_tfl"

ARCHS_GNU=( "x64" "arm64" "armv7" ) # "riscv64" TODO riscv64 support
#ARCHS_MUSL=( "amd64" "arm64/v8" "riscv64" "arm/v7" )
#ALPINE_TAG="20231219"

# Register qmemu static 
qemu_registered=0
function register_qemu_static() {
   if [ $qemu_registered -eq 0 ] ; then
    docker run --rm --privileged --name qemu-static multiarch/qemu-user-static --reset -p yes 
    qemu_registered=1
    echo "Registered QEMU..."
    ls /proc/sys/fs/binfmt_misc
   fi
}

mkdir -p $MODELS_DIR
mkdir -p $WWMODELS_DIR
mkdir -p $LIBS_DIR
mkdir -p $LIBS_DIR/include


if [ "$1" == "clean" ] ; then
   # Clean temp folder and all docker images involved.
   printf "Cleaning all temp directories and docker images..."
   [ -d $TMP_LIBS ] && rm -Rf $TMP_LIBS
   docker rmi -f $(docker images --format "{{json .}}" | jq -r '. | select(.Repository | test("dockcross/*")) | .ID')
   docker rmi -f $(docker images --format "{{json .}}" | jq -r '. | select(.Repository | test("alpine*")) | .ID')
   docker rmi -f $(docker images --format "{{json .}}" | jq -r '. | select(.Repository | test("multiarch/qemu-user-static")) | .ID')
   [ -d $DIST_DIR ] && rm -fR $DIST_DIR
   [ -d $LIBS_DIR ] && rm -fR $LIBS_DIR
   [ -d $SCRIPT_DIR/zig-cache ] && rm -fR $SCRIPT_DIR/zig-cache
   [ -d $SCRIPT_DIR/zig-out ]   && rm -fR $SCRIPT_DIR/zig-out
   echo "Done!"
   exit 0
fi


echo "Downloading models"
echo "=================="

BASEURL="https://github.com/dscripka/openWakeWord/releases/download/$MODELS_VER"
for m in "${MODELS[@]}" ; do
   printf "[${m}]..."
   [ ! -f $MODELS_DIR}/${m} ] && wget -qO ${MODELS_DIR}/${m} $BASEURL/${m}
   echo "Done!"
   #ls -lh models/${m}
done

for m in "${WWMODELS[@]}" ; do
   printf "[${m}]..."
   [ ! -f $WWMODELS_DIR/${m} ] && wget -qO ${WWMODELS_DIR}/${m} $BASEURL/${m}
   echo "Done!"
   #ls -lh models/${m}
done

echo 
echo "Downloading tensorflow + copy includes"
echo "======================================"
TF_URL="https://github.com/tensorflow/tensorflow/archive/refs/tags/${TF_VERSION}.tar.gz"
TF_SRC="tf_src"

mkdir -p $TMP_LIBS
pushd $TMP_LIBS

printf "[$TF_URL]..."
if [ ! -d $TF_SRC ] ; then
   printf "[downloading $TF_URL]..."
   mkdir -p $TF_SRC
   wget -qO- $TF_URL | tar xz -C $TF_SRC --strip-components=1
fi
echo "Done!"


pushd $TF_SRC
 printf "[Copy TFLITE includes]..."
 mkdir -p $LIBS_DIR/include/tensorflow/lite/c
 mkdir -p $LIBS_DIR/include/tensorflow/lite/core/c
 mkdir -p $LIBS_DIR/include/tensorflow/lite/core/async/c
 mkdir -p $LIBS_DIR/include/tensorflow/lite/delegates/xnnpack

 cp tensorflow/lite/core/c/*.h $LIBS_DIR/include/tensorflow/lite/core/c/.
 cp tensorflow/lite/c/*.h $LIBS_DIR/include/tensorflow/lite/c/.
 cp tensorflow/lite/builtin_ops.h $LIBS_DIR/include/tensorflow/lite/.
 cp tensorflow/lite/core/async/c/types.h $LIBS_DIR/include/tensorflow/lite/core/async/c/.
 cp tensorflow/lite/delegates/xnnpack/xnnpack_delegate.h $LIBS_DIR/include/tensorflow/lite/delegates/xnnpack/.

 echo "Done!"
popd

popd

echo "Downloading webrtc gain+noise library  "
echo "======================================="
register_qemu_static
WRTC_URL="https://github.com/ludiazv/webrtc-noise-gain/archive/refs/tags/${WRTC_VERSION}.tar.gz"
WRTC_SRC="wrtc_src"
pushd $TMP_LIBS
printf "[$WRTC_SRC]..."
if [ ! -d $WRTC_SRC ] ;then
   printf "[downloading $WRTC_URL]..."
   mkdir -p $WRTC_SRC
   wget -qO- $WRTC_URL | tar xz -C $WRTC_SRC --strip-components=1
fi
echo "Done!"

pushd $WRTC_SRC
  printf "[Copy webrtc gain+noise header]..."
  cp webrtc_noise_gain_c.h $LIBS_DIR/include/.
  echo "Done!"
popd

popd

echo
echo "Prepare docker images for cross-compilation"
echo "==========================================="
pushd $TMP_LIBS
for a in "${ARCHS_GNU[@]}" ; do
   echo "[${a}]..."
   dc_a="${a}"
   #[ "${a}" == "armv7" ] && dc_a="armv7-lts"
   docker pull dockcross/linux-${dc_a}
   docker run --rm dockcross/linux-${dc_a} > cc-${a}.sh
   chmod u+x cc-${a}.sh
   echo "Done!"
done

# TODO - Activate MUSL
#for a in "${ARCHS_MUSL[@]}" ; do
#   echo "[${a}]..."
#   docker pull --platform linux/${a} alpine:$ALPINE_TAG
#done
#docker pull multiarch/qemu-user-static:latest

popd

echo 
echo "Compile tensor flow C API - GNU"
echo "==============================="
NCPUS=$(( $(nproc) / 2 ))
LIBNAME="libtensorflowlite_c.so"
pushd $TMP_LIBS
for a in "${ARCHS_GNU[@]}" ; do
   echo "[$a]..."
   cmake_opt=""
   patch_toolchain=""
   #Special flags and patch cross toolchain for armv7
   if [ "${a}" = "armv7" ] ; then
      cmake_opt='-DCMAKE_CXX_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -funsafe-math-optimizations -mfp16-format=ieee" -DCMAKE_C_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -funsafe-math-optimizations -mfp16-format=ieee" -DCMAKE_VERBOSE_MAKEFILE:BOOL=OFF -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7'
      #patch_toolchain="gosu root echo 'set(CMAKE_SYSTEM_PROCESSOR armv7)' >> \$CROSS_ROOT/Toolchain.cmake ;"
      patch_toolchain="gosu root sed -i 's/arm/armv7/' \$CROSS_ROOT/Toolchain.cmake ; " 
   fi

   [ ! -d build_${a}_gnu ] && ./cc-${a}.sh bash -c "${patch_toolchain} cmake -B build_${a}_gnu ${TF_SRC}/tensorflow/lite/c $cmake_opt"
   [ ! -f build_${a}_gnu/$LIBNAME ] && ./cc-${a}.sh bash -c "cd build_${a}_gnu ; cmake --build . -j $NCPUS"
   if [ -f build_${a}_gnu/$LIBNAME ] ; then
      d=""
      [ "$a" = "arm64" ] && d="aarch64-linux-gnu"
      [ "$a" = "x64" ] && d="x86_64-linux-gnu"
      [ "$a" = "riscv64" ] && d="riscv64-linux-gnu"
      [ "$a" = "armv7" ] && d="arm-linux-gnueabihf"
      [ ! -z $d ] && mkdir -p $LIBS_DIR/$d
      [ ! -z $d ] && cp build_${a}_gnu/$LIBNAME $LIBS_DIR/$d/$LIBNAME
   fi
   echo "Done"
done

echo 
echo "Compile noise gain library - GNU"
echo "================================"
LIBNAME="libwebrtcnoisegain_c.so"
for a in "${ARCHS_GNU[@]}" ; do
   echo "[$a]..."
   arch=${a}
   [ "$a" = "x64" ] && arch="x86_64"
   [ ! -d buildw_${a}_gnu -o ! -f buildw_${a}_gnu/$LIBNAME ] && ./cc-${a}.sh bash -c "cd $WRTC_SRC; ./make_clib.sh linux ${arch} ../buildw_${a}_gnu"
   if [ -f buildw_${a}_gnu/$LIBNAME ] ; then
      d=""
      [ "$a" = "arm64" ] && d="aarch64-linux-gnu"
      [ "$a" = "x64" ] && d="x86_64-linux-gnu"
      [ "$a" = "riscv64" ] && d="riscv64-linux-gnu"
      [ "$a" = "armv7" ] && d="arm-linux-gnueabihf"
      [ ! -z $d ] && mkdir -p $LIBS_DIR/$d
      [ ! -z $d ] && cp buildw_${a}_gnu/$LIBNAME $LIBS_DIR/$d/$LIBNAME
   fi
   echo "Done"
done



#echo "Compile tensor flow C API - MUSL"
#echo "================================"

function build_musl() {
   local plat=$1
   local arch=${plat%%/*}
   local alpine_deps="cd /work; apk add git cmake make gcc g++ "
   local console=""
   local cmake_opt=""
   register_qemu_static
   if [ ! -d build_${arch}_musl ] ; then
      
      [ "${arch}" = "arm" ] && cmake_opt='-DCMAKE_CXX_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -funsafe-math-optimizations -mfp16-format=ieee" -DCMAKE_C_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -funsafe-math-optimizations -mfp16-format=ieee" -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7 ; bash'
      [ "${arch}" = "riscv64" ] && cmake_opt='-DCMAKE_CXX_FLAGS="-funsafe-math-optimizations -mcpu=thead-c906"'
      local cmake="cmake -B build_${arch}_musl ${TF_SRC}/tensorflow/lite/c $cmake_opt"
      local patch_abseil="sed -i 's/off64_t offset/off_t offset/' abseil-cpp/absl/base/internal/direct_mmap.h"
      local patch_fb="sed -i 's/#define FLATBUFFERS_LOCALE_INDEPENDENT 1/#define FLATBUFFERS_LOCALE_INDEPENDENT 0/' flatbuffers/include/flatbuffers/base.h"
      local patch="cd build_${arch}_musl ; ${patch_abseil} ; $patch_fb ; $console"
      docker run -it --rm --name build_${arch}_musl -v $(pwd):/work --platform linux/${plat} alpine:$ALPINE_TAG /bin/sh -c "$alpine_deps sed ; $cmake ; $patch"
   fi

   if [ ! -f build_${arch}_musl/$LIBNAME ] ; then
      local cmake="cd build_${arch}_musl ; cmake --build . -j $NCPUS"
      docker run -it --rm --name build_${arch}_musl -v $(pwd):/work --platform linux/${plat} alpine:$ALPINE_TAG /bin/sh -c "$alpine_deps linux-headers ; $cmake ; $console"

   fi

   if [ -f build_${arch}_musl/$LIBNAME ] ; then
      d=""
      [ "$arch" = "amd64" ] && d="x86_64-linux-musl"
      [ "$arch" = "arm64" ] && d="aarch64-linux-musl"
      [ "$arch" = "riscv64" ] && d="riscv64-linux-musl"
      [ "$arch" = "arm" ] && d="arm-linux-musleabihf"

      [ ! -z $d ] && mkdir -p $TFLITE_DIR/$d
      [ ! -z $d ] && cp build_${arch}_musl/$LIBNAME $TFLITE_DIR/$d/$LIBNAME

   fi


}


#for a in "${ARCHS_MUSL[@]}" ; do
#   echo "[$a]..."
#   build_musl "${a}"  
#done

popd

echo "FINISHED"
