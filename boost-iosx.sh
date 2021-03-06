#!/bin/bash
#===============================================================================
# Filename:  boost.sh
# Author:    Pete Goodliffe
# Copyright: (c) Copyright 2009 Pete Goodliffe
# Licence:   Please feel free to use this, with attribution
#===============================================================================
#
# Builds a Boost framework for the iPhone.
# Creates a set of universal libraries that can be used on an iPhone and in the
# iPhone simulator. Then creates a pseudo-framework to make using boost in Xcode
# less painful.
#
# To configure the script, define:
#    BOOST_LIBS:        which libraries to build
#    IPHONE_SDKVERSION: iPhone SDK version (e.g. 5.1)
#
# Then go get the source tar.bz of the boost you want to build, shove it in the
# same directory as this script, and run "./boost.sh". Grab a cuppa. And voila.
#===============================================================================
# Configuration section
#===============================================================================
BOOST_VERSION="1.60.0"
IOS_MIN_VERSION=8.0
OSX_MIN_VERSION=10.9
#===============================================================================
# End configuration section
#===============================================================================
SRCDIR=$(pwd)
BOOST_SRC=$SRCDIR/boost
source bootstrap.sh
: ${IPHONE_SDKVERSION:=`xcodebuild -showsdks 2> /dev/null | grep "iOS SDKs" -A 1 | tail -n 1 | awk '{print $2}'`}
: ${OSX_SDKVERSION:=`xcodebuild -showsdks 2> /dev/null | grep "macOS SDKs" -A 1 | tail -n 1 | awk '{print $2}'`}
: ${XCODE_ROOT:=`xcode-select -print-path`}
: ${EXTRA_CPPFLAGS:="-DBOOST_AC_USE_PTHREADS -DBOOST_SP_USE_PTHREADS -std=c++11 -stdlib=libc++"}

# The EXTRA_CPPFLAGS definition works around a thread race issue in
# shared_ptr. I encountered this historically and have not verified that
# the fix is no longer required. Without using the posix thread primitives
# an invalid compare-and-swap ARM instruction (non-thread-safe) was used for the
# shared_ptr use count causing nasty and subtle bugs.
#
# Should perhaps also consider/use instead: -BOOST_SP_USE_PTHREADS

: ${SRCDIR:=`pwd`}
: ${IOSBUILDDIR:=`pwd`/ios/build}
: ${OSXBUILDDIR:=`pwd`/osx/build}
: ${PREFIXDIR:=`pwd`/ios/prefix}
: ${IOSFRAMEWORKDIR:=`pwd`/ios/framework}
: ${OSXFRAMEWORKDIR:=`pwd`/osx/framework}
: ${COMPILER:="clang++"}

#===============================================================================
# Functions
#===============================================================================

abort()
{
    echo
    echo "Aborted: $@"
    exit 1
}

doneSection()
{
    echo
    echo "    ================================================================="
    echo "    Done"
    echo
}

#===============================================================================

cleanEverythingReadyToStart()
{
    echo Cleaning everything before we start to build...
	rm -rf iphone-build iphonesim-build osx-build
    rm -rf $IOSBUILDDIR
    rm -rf $OSXBUILDDIR
    rm -rf $PREFIXDIR
    rm -rf $IOSFRAMEWORKDIR/$FRAMEWORK_NAME.framework
    rm -rf $OSXFRAMEWORKDIR/$FRAMEWORK_NAME.framework
    doneSection
}

#===============================================================================
updateBoost()
{
    echo Updating boost into $BOOST_SRC...

    if [ -d $BOOST_SRC ]
    then
        pushd $BOOST_SRC
        checkoutToVersion
    else
        git clone --recursive https://github.com/boostorg/boost.git $BOOST_SRC
		pushd $BOOST_SRC
        checkoutToVersion        
		./bootstrap.sh
		./b2 headers
		popd
    fi

    doneSection
}

checkoutToVersion()
{
    git reset --hard
    git checkout master
    git fetch --all
    git pull origin master
    git checkout tags/boost-$BOOST_VERSION -b boost-$BOOST_VERSION
    git submodule sync
    git submodule update
    git clean -d -f
}

#===============================================================================

inventMissingHeaders()
{
    # These files are missing in the ARM iPhoneOS SDK, but they are in the simulator.
    # They are supported on the device, so we copy them from x86 SDK to a staging area
    # to use them on ARM, too.
    echo Invent missing headers
    cp $XCODE_ROOT/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator${IPHONE_SDKVERSION}.sdk/usr/include/{crt_externs,bzlib}.h $BOOST_SRC
}

#===============================================================================

bootstrapBoost()
{
    cd $BOOST_SRC
    if [[ $BOOST_LIBS = *[!\ ]* ]]; then
        BOOST_LIBS_COMMA=$(echo $BOOST_LIBS | sed -e "s/ /,/g")
        echo "Bootstrapping (with libs $BOOST_LIBS_COMMA)"
        ./bootstrap.sh --with-libraries=$BOOST_LIBS_COMMA
    else
        echo "Bootstrapping (with all libs)"
        ./bootstrap.sh
    fi
    doneSection
}

#===============================================================================

buildBoostForiPhoneOS()
{
    cd $BOOST_SRC
    
    cat > $BOOST_SRC/tools/build/src/user-config.jam <<EOF
using darwin : ${IPHONE_SDKVERSION}~iphone
   : $XCODE_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/$COMPILER -arch armv7 -arch armv7s -arch arm64 -miphoneos-version-min=$IOS_MIN_VERSION -fembed-bitcode -fvisibility=hidden -fvisibility-inlines-hidden $EXTRA_CPPFLAGS
   : <striper> <root>$XCODE_ROOT/Platforms/iPhoneOS.platform/Developer
   : <architecture>arm <target-os>iphone
   ;
EOF

	# Install this one so we can copy the includes for the frameworks...
    ./bjam -j16 --build-dir=../iphone-build --stagedir=../iphone-build/stage --prefix=$PREFIXDIR toolset=darwin architecture=arm target-os=iphone macosx-version=iphone-${IPHONE_SDKVERSION} define=_LITTLE_ENDIAN link=static stage
    ./bjam -j16 --build-dir=../iphone-build --stagedir=../iphone-build/stage --prefix=$PREFIXDIR toolset=darwin architecture=arm target-os=iphone macosx-version=iphone-${IPHONE_SDKVERSION} define=_LITTLE_ENDIAN link=static install
    doneSection
	
    cat > $BOOST_SRC/tools/build/src/user-config.jam <<EOF
using darwin : ${IPHONE_SDKVERSION}~iphonesim
   : $XCODE_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/$COMPILER -arch i386 -arch x86_64 -fvisibility=hidden -fvisibility-inlines-hidden -miphoneos-version-min=$IOS_MIN_VERSION $EXTRA_CPPFLAGS
   : <striper> <root>$XCODE_ROOT/Platforms/iPhoneSimulator.platform/Developer
   : <architecture>x86 <target-os>iphone
   ;
EOF
    
    echo "Building for simulator i386..."
    ./bjam -j16 --build-dir=../iphonesim-build --stagedir=../iphonesim-build/stage --toolset=darwin architecture=x86 target-os=iphone macosx-version=iphonesim-${IPHONE_SDKVERSION} link=static stage
	doneSection

	echo "Building for osx..."
	./b2 -j16 --build-dir=../osx-build --stagedir=../osx-build/stage toolset=clang cxxflags="-std=c++11 -stdlib=libc++ -arch i386 -arch x86_64 -mmacosx-version-min=$OSX_MIN_VERSION" linkflags="-stdlib=libc++" link=static threading=multi stage
    doneSection
}

#===============================================================================

scrunchAllLibsTogetherInOneLibPerPlatform()
{
	cd $SRCDIR

    mkdir -p $IOSBUILDDIR/armv7/obj
    mkdir -p $IOSBUILDDIR/armv7s/obj
    mkdir -p $IOSBUILDDIR/arm64/obj
    mkdir -p $IOSBUILDDIR/i386/obj
    mkdir -p $IOSBUILDDIR/x86_64/obj

    mkdir -p $OSXBUILDDIR/i386/obj
    mkdir -p $OSXBUILDDIR/x86_64/obj

    ALL_LIBS=""

    echo Splitting all existing fat binaries...
    for NAME in $BOOST_LIBS; do
        ALL_LIBS="$ALL_LIBS libboost_$NAME.a"

        xcrun lipo "iphone-build/stage/lib/libboost_$NAME.a" -thin armv7 -o $IOSBUILDDIR/armv7/libboost_$NAME.a
        xcrun lipo "iphone-build/stage/lib/libboost_$NAME.a" -thin armv7s -o $IOSBUILDDIR/armv7s/libboost_$NAME.a
        xcrun lipo "iphone-build/stage/lib/libboost_$NAME.a" -thin arm64 -o $IOSBUILDDIR/arm64/libboost_$NAME.a
		xcrun lipo "iphonesim-build/stage/lib/libboost_$NAME.a" -thin i386 -o $IOSBUILDDIR/i386/libboost_$NAME.a
		xcrun lipo "iphonesim-build/stage/lib/libboost_$NAME.a" -thin x86_64 -o $IOSBUILDDIR/x86_64/libboost_$NAME.a

        xcrun lipo "osx-build/stage/lib/libboost_$NAME.a" -thin i386 -o $OSXBUILDDIR/i386/libboost_$NAME.a
        xcrun lipo "osx-build/stage/lib/libboost_$NAME.a" -thin x86_64 -o $OSXBUILDDIR/x86_64/libboost_$NAME.a
    done

    echo "Decomposing each architecture's .a files"
    for NAME in $ALL_LIBS; do
        echo Decomposing $NAME...
        (cd $IOSBUILDDIR/armv7/obj; ar -x ../$NAME );
        (cd $IOSBUILDDIR/armv7s/obj; ar -x ../$NAME );
        (cd $IOSBUILDDIR/arm64/obj; ar -x ../$NAME );
        (cd $IOSBUILDDIR/i386/obj; ar -x ../$NAME );
        (cd $IOSBUILDDIR/x86_64/obj; ar -x ../$NAME );

        (cd $OSXBUILDDIR/i386/obj; ar -x ../$NAME );
        (cd $OSXBUILDDIR/x86_64/obj; ar -x ../$NAME );
    done

    echo "Linking each architecture into an uberlib ($ALL_LIBS => libboost.a )"
    rm $IOSBUILDDIR/*/libboost.a
    echo ...ios-armv7
    (cd $IOSBUILDDIR/armv7; xcrun ar crus libboost.a obj/*.o; )
    echo ...ios-armv7s
    (cd $IOSBUILDDIR/armv7s; xcrun ar crus libboost.a obj/*.o; )
    echo ...ios-arm64
    (cd $IOSBUILDDIR/arm64; xcrun ar crus libboost.a obj/*.o; )
    echo ...ios-i386
    (cd $IOSBUILDDIR/i386;  xcrun ar crus libboost.a obj/*.o; )
    echo ...ios-x86_64
    (cd $IOSBUILDDIR/x86_64;  xcrun ar crus libboost.a obj/*.o; )

    rm $OSXBUILDDIR/*/libboost.a
    echo ...osx-i386
    (cd $OSXBUILDDIR/i386;  xcrun ar crus libboost.a obj/*.o; )
    echo ...osx-x86_64
    (cd $OSXBUILDDIR/x86_64;  xcrun ar crus libboost.a obj/*.o; )
}

#===============================================================================
buildFramework()
{
	: ${1:?}
	FRAMEWORKDIR=$1
	BUILDDIR=$2

	VERSION_TYPE=Alpha
	FRAMEWORK_NAME=boost
	FRAMEWORK_VERSION=A

	FRAMEWORK_CURRENT_VERSION=$BOOST_VERSION
	FRAMEWORK_COMPATIBILITY_VERSION=$BOOST_VERSION

    FRAMEWORK_BUNDLE=$FRAMEWORKDIR/$FRAMEWORK_NAME.framework
    echo "Framework: Building $FRAMEWORK_BUNDLE from $BUILDDIR..."

    rm -rf $FRAMEWORK_BUNDLE

    echo "Framework: Setting up directories..."
    mkdir -p $FRAMEWORK_BUNDLE
    mkdir -p $FRAMEWORK_BUNDLE/Versions
    mkdir -p $FRAMEWORK_BUNDLE/Versions/$FRAMEWORK_VERSION
    mkdir -p $FRAMEWORK_BUNDLE/Versions/$FRAMEWORK_VERSION/Resources
    mkdir -p $FRAMEWORK_BUNDLE/Versions/$FRAMEWORK_VERSION/Headers
    mkdir -p $FRAMEWORK_BUNDLE/Versions/$FRAMEWORK_VERSION/Documentation

    echo "Framework: Creating symlinks..."
    ln -s $FRAMEWORK_VERSION               $FRAMEWORK_BUNDLE/Versions/Current
    ln -s Versions/Current/Headers         $FRAMEWORK_BUNDLE/Headers
    ln -s Versions/Current/Resources       $FRAMEWORK_BUNDLE/Resources
    ln -s Versions/Current/Documentation   $FRAMEWORK_BUNDLE/Documentation
    ln -s Versions/Current/$FRAMEWORK_NAME $FRAMEWORK_BUNDLE/$FRAMEWORK_NAME

    FRAMEWORK_INSTALL_NAME=$FRAMEWORK_BUNDLE/Versions/$FRAMEWORK_VERSION/$FRAMEWORK_NAME

    echo "Lipoing library into $FRAMEWORK_INSTALL_NAME..."
    xcrun lipo -create $BUILDDIR/*/libboost.a -o "$FRAMEWORK_INSTALL_NAME" || abort "Lipo $1 failed"

    echo "Framework: Copying includes..."
    cp -r $PREFIXDIR/include/boost/*  $FRAMEWORK_BUNDLE/Headers/

    echo "Framework: Creating plist..."
    cat > $FRAMEWORK_BUNDLE/Resources/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>org.boost</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>${FRAMEWORK_CURRENT_VERSION}</string>
</dict>
</plist>
EOF
    doneSection
}

buildIOSUniversalLib()
{
	cd $SRCDIR

    OUTPUT_NAME="libboost.a"
    LIBS_TO_BE_MERGED="$IOSBUILDDIR/armv7/$OUTPUT_NAME \
        $IOSBUILDDIR/armv7s/$OUTPUT_NAME \
        $IOSBUILDDIR/arm64/$OUTPUT_NAME \
        $IOSBUILDDIR/i386/$OUTPUT_NAME \
        $IOSBUILDDIR/x86_64/$OUTPUT_NAME"

    libtool -static -a ${LIBS_TO_BE_MERGED} -o $IOSBUILDDIR/${OUTPUT_NAME}
    echo "Universal ${OUTPUT_NAME} successfully created in $IOSBUILDDIR"   
}

packIOSUniversalLib()
{
	cd $SRCDIR

    OUTPUT_DIR="$IOSBUILDDIR/../static"
    OUTPUT_NAME="libboost.a"

    mkdir -p $OUTPUT_DIR
    cp $IOSBUILDDIR/${OUTPUT_NAME} $OUTPUT_DIR
    rsync -avp ${IOSBUILDDIR}/../prefix/include/* $OUTPUT_DIR
}

buildOSXUniversalLib()
{
	cd $SRCDIR

    OUTPUT_NAME="libboost.a"
    LIBS_TO_BE_MERGED="$OSXBUILDDIR/x86_64/$OUTPUT_NAME \
        $OSXBUILDDIR/i386/$OUTPUT_NAME"

    libtool -static -a ${LIBS_TO_BE_MERGED} -o $OSXBUILDDIR/${OUTPUT_NAME}
    echo "Universal ${OUTPUT_NAME} successfully created in $OSXBUILDDIR"   
}

packOSXUniversalLib()
{
	cd $SRCDIR

    OUTPUT_DIR="$OSXBUILDDIR/../static"
    OUTPUT_NAME="libboost.a"

    mkdir -p $OUTPUT_DIR
    cp $OSXBUILDDIR/${OUTPUT_NAME} $OUTPUT_DIR
}

#===============================================================================
# Execution starts here
#===============================================================================

if [ -z "$1" ]; then
	echo "BOOST_VERSION has not been specified, will use $BOOST_VERSION as default"
else
	BOOST_VERSION="$1"
	echo "Using BOOST_VERSION: $BOOST_VERSION"
fi

mkdir -p $IOSBUILDDIR

cleanEverythingReadyToStart
updateBoost

echo "BOOST_VERSION:     $BOOST_VERSION"
echo "BOOST_LIBS:        $BOOST_LIBS"
echo "BOOST_SRC:         $BOOST_SRC"
echo "IOSBUILDDIR:       $IOSBUILDDIR"
echo "OSXBUILDDIR:       $OSXBUILDDIR"
echo "PREFIXDIR:         $PREFIXDIR"
echo "IOSFRAMEWORKDIR:   $IOSFRAMEWORKDIR"
echo "OSXFRAMEWORKDIR:   $OSXFRAMEWORKDIR"
echo "IPHONE_SDKVERSION: $IPHONE_SDKVERSION"
echo "XCODE_ROOT:        $XCODE_ROOT"
echo "COMPILER:          $COMPILER"
echo

inventMissingHeaders
bootstrapBoost
buildBoostForiPhoneOS
scrunchAllLibsTogetherInOneLibPerPlatform

buildFramework $IOSFRAMEWORKDIR $IOSBUILDDIR
buildIOSUniversalLib $IOSFRAMEWORKDIR $IOSBUILDDIR
packIOSUniversalLib $IOSFRAMEWORKDIR $IOSBUILDDIR

buildFramework $OSXFRAMEWORKDIR $OSXBUILDDIR
buildOSXUniversalLib $OSXFRAMEWORKDIR $OSXBUILDDIR
packOSXUniversalLib $OSXFRAMEWORKDIR $OSXBUILDDIR

echo "Completed successfully"

#===============================================================================
