#!/bin/bash 
# Package software for distribution.

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
echo "Dependencies script for voz"
echo "SD=$SCRIPT_DIR"

DIST_DIR="${SCRIPT_DIR}/dist"
LIB_DIR="${SCRIPT_DIR}/lib"
MODEL_DIR_NAME="models"
WWMODEL_DIR_NAME="wwmodels"
MODEL_DIR="${SCRIPT_DIR}/$MODEL_DIR_NAME"
WWMODEL_DIR="${SCRIPT_DIR}/$WWMODEL_DIR_NAME"
ARCHS=( "x86_64-linux-gnu" "aarch64-linux-gnu" "arm-linux-gnueabihf" )
MODES=( "ReleaseSafe" "Debug" ) 

mkdir -p $DIST_DIR

if [ "$1" = "arm" ] ; then
   ARCHS=( "arm-linux-gnueabihf" )
   MODES=( "Debug" )
fi

set -e
for m in "${ARCHS[@]}" ; do

   pushd $SCRIPT_DIR
   
   for o in "${MODES[@]}" ; do
      echo "Building for $m [$o]..."
      mkdir -p $DIST_DIR/$o-$m
      zig build -Dtarget=$m -Doptimize=$o --prefix $DIST_DIR --prefix-exe-dir $o-$m --summary all --color off
      mkdir -p $DIST_DIR/$o-$m/services
      cp -v ${SCRIPT_DIR}/services/* $DIST_DIR/$o-$m/services/.
      cp -v ${SCRIPT_DIR}/voz-ser-mon.sh $DIST_DIR/$o-$m/.
      cp -v ${SCRIPT_DIR}/LICENSE   $DIST_DIR/$o-$m/.
      cp -v $LIB_DIR/$m/lib*.so $DIST_DIR/$o-$m/.
      mkdir -p $DIST_DIR/$o-$m/$MODEL_DIR_NAME
      mkdir -p $DIST_DIR/$o-$m/$WWMODEL_DIR_NAME
      cp -v $MODEL_DIR/melspectrogram.tflite $DIST_DIR/$o-$m/$MODEL_DIR_NAME/.
      cp -v $MODEL_DIR/embedding_model.tflite $DIST_DIR/$o-$m/$MODEL_DIR_NAME/.
      cp -v $WWMODEL_DIR/*.tflite $DIST_DIR/$o-$m/$WWMODEL_DIR_NAME/.
      echo "Done $m [$o]"
      echo "Make package for $m [$o]..."
      pushd $DIST_DIR
      tar cfz voz-$o-$m.tar.gz -C $o-$m .
      echo "Done $m [$o]"
      rm -rf $o-$m
      popd
   done
   
   popd

done
