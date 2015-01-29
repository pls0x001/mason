set -e
set -o pipefail
# set -x

MASON_ROOT=${MASON_ROOT:-`pwd`/mason_packages}
MASON_BUCKET=${MASON_BUCKET:-mason-binaries}

MASON_UNAME=`uname -s`
if [ ${MASON_UNAME} = 'Darwin' ]; then
    MASON_PLATFORM=${MASON_PLATFORM:-osx}
    MASON_XCODE_ROOT=`"xcode-select" -p`
elif [ ${MASON_UNAME} = 'Linux' ]; then
    MASON_PLATFORM=${MASON_PLATFORM:-linux}
fi


case ${MASON_UNAME} in
    'Darwin')    MASON_CONCURRENCY=`sysctl -n hw.ncpu` ;;
    'Linux')        MASON_CONCURRENCY=`nproc` ;;
    *)              MASON_CONCURRENCY=1 ;;
esac


function mason_step    { >&2 echo -e "\033[1m\033[36m* $1\033[0m"; }
function mason_substep { >&2 echo -e "\033[1m\033[36m* $1\033[0m"; }
function mason_success { >&2 echo -e "\033[1m\033[32m* $1\033[0m"; }
function mason_error   { >&2 echo -e "\033[1m\033[31m$1\033[0m"; }


case ${MASON_ROOT} in
    *\ * ) mason_error "Directory '${MASON_ROOT} contains spaces."; exit ;;
esac

if [ ${MASON_PLATFORM} = 'osx' ]; then
    export MASON_HOST_ARG="--host=x86_64-apple-darwin"
    export MASON_PLATFORM_VERSION=`xcrun --sdk macosx --show-sdk-version`

    MASON_SDK_ROOT=${MASON_XCODE_ROOT}/Platforms/MacOSX.platform/Developer
    MASON_SDK_PATH="${MASON_SDK_ROOT}/SDKs/MacOSX${MASON_PLATFORM_VERSION}.sdk"
    export MASON_CFLAGS="-mmacosx-version-min=${MASON_PLATFORM_VERSION} -isysroot ${MASON_SDK_PATH} -arch i386 -arch x86_64"


elif [ ${MASON_PLATFORM} = 'ios' ]; then
    export MASON_HOST_ARG="--host=arm-apple-darwin"
    export MASON_PLATFORM_VERSION=`xcrun --sdk iphoneos --show-sdk-version`

    MASON_SDK_ROOT=${MASON_XCODE_ROOT}/Platforms/iPhoneOS.platform/Developer
    MASON_SDK_PATH="${MASON_SDK_ROOT}/SDKs/iPhoneOS${MASON_PLATFORM_VERSION}.sdk"
    export MASON_IOS_CFLAGS="-miphoneos-version-min=${MASON_PLATFORM_VERSION} -isysroot ${MASON_SDK_PATH} -arch armv7 -arch armv7s -arch arm64"

    if [ `xcrun --sdk iphonesimulator --show-sdk-version` != ${MASON_PLATFORM_VERSION} ]; then
        mason_error "iPhone Simulator SDK version doesn't match iPhone SDK version"
        exit 1
    fi

    MASON_SDK_ROOT=${MASON_XCODE_ROOT}/Platforms/iPhoneSimulator.platform/Developer
    MASON_SDK_PATH="${MASON_SDK_ROOT}/SDKs/iPhoneSimulator${MASON_PLATFORM_VERSION}.sdk"
    export MASON_ISIM_CFLAGS="-miphoneos-version-min=${MASON_PLATFORM_VERSION} -isysroot ${MASON_SDK_PATH} -arch i386 -arch x86_64"

elif [ ${MASON_PLATFORM} = 'linux' ]; then
    for i in /etc/*-release ; do . $i ; done
    MASON_PLATFORM_DISTRIBUTION=`echo ${ID:-${DISTRIB_ID}} | tr '[:upper:]' '[:lower:]'`
    if [ -z "${MASON_PLATFORM_DISTRIBUTION}" ]; then
        mason_error "Cannot determine distribution name"
        exit 1
    fi

    MASON_PLATFORM_DISTRIBUTION_VERSION=${DISTRIB_RELEASE:-${VERSION_ID}}
    if [ -z "${MASON_PLATFORM_DISTRIBUTION_VERSION}" ]; then
        mason_error "Cannot determine distribution version"
        exit 1
    fi

    export MASON_PLATFORM_VERSION=`uname -m`
    export CFLAGS="-fPIC"
    export CXXFLAGS="${CFLAGS} -std=c++11"

elif [ ${MASON_PLATFORM} = 'android' ]; then
    if [ ${ANDROID_NDK_PATH:-false} = false ]; then
        mason_error "ANDROID_NDK_PATH variable must be set with an active-platform built"
        exit 1
    fi
    
    export MASON_ANDROID_ABI=${MASON_ANDROID_ABI:-arm-v7}
    
    CFLAGS="-fpic -ffunction-sections -funwind-tables -fstack-protector -no-canonical-prefixes -fno-integrated-as -O2 -g -DNDEBUG -fomit-frame-pointer -fstrict-aliasing -funswitch-loops -finline-functions -finline-limit=300 -Wno-invalid-command-line-argument -Wno-unused-command-line-argument"
    LDFLAGS="-no-canonical-prefixes"
    export CPPFLAGS="-D__ANDROID__"

    if [ ${MASON_ANDROID_ABI} = 'arm-v8' ]; then
        MASON_ANDROID_TOOLCHAIN="aarch64-linux-android"
        MASON_ANDROID_CROSS_COMPILER="aarch64-linux-android-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target aarch64-none-linux-android -D_LITTLE_ENDIAN ${CFLAGS}"
        export LDFLAGS="-target aarch64-none-linux-android ${LDFLAGS}"
        
        export JNIDIR="arm64-v8a"
        MASON_ANDROID_ARCH="arm64"
        MASON_ANDROID_PLATFORM="21"

    elif [ ${MASON_ANDROID_ABI} = 'arm-v7' ]; then
        MASON_ANDROID_TOOLCHAIN="arm-linux-androideabi"
        MASON_ANDROID_CROSS_COMPILER="arm-linux-androideabi-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target armv7-none-linux-androideabi -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -mhard-float -D_NDK_MATH_NO_SOFTFP=1 -D_LITTLE_ENDIAN ${CFLAGS}"
        export LDFLAGS="-target armv7-none-linux-androideabi -march=armv7-a -Wl,--fix-cortex-a8 -Wl,--no-warn-mismatch -lm_hard ${LDFLAGS}"
        
        export JNIDIR="armeabi-v7a"
        MASON_ANDROID_ARCH="arm"
        MASON_ANDROID_PLATFORM="9"

    elif [ ${MASON_ANDROID_ABI} = 'arm-v5' ]; then
        MASON_ANDROID_TOOLCHAIN="arm-linux-androideabi"
        MASON_ANDROID_CROSS_COMPILER="arm-linux-androideabi-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target armv5te-none-linux-androideabi -march=armv5te -mtune=xscale -msoft-float -D_LITTLE_ENDIAN ${CFLAGS}"
        export LDFLAGS="-target armv5te-none-linux-androideabi -march=armv5te ${LDFLAGS}"
        
        export JNIDIR="armeabi"
        MASON_ANDROID_ARCH="arm"
        MASON_ANDROID_PLATFORM="9"
        
    elif [ ${MASON_ANDROID_ABI} = 'x86' ]; then
        MASON_ANDROID_TOOLCHAIN="i686-linux-android"
        MASON_ANDROID_CROSS_COMPILER="x86-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target i686-none-linux-android -march=i686 -msse3 -mstackrealign -mfpmath=sse ${CFLAGS}"
        export LDFLAGS="-target i686-none-linux-android -march=i686 ${LDFLAGS}"
        
        export JNIDIR="x86"
        MASON_ANDROID_ARCH="x86"
        MASON_ANDROID_PLATFORM="9"
        
    elif [ ${MASON_ANDROID_ABI} = 'x86-64' ]; then
        MASON_ANDROID_TOOLCHAIN="x86_64-linux-android"
        MASON_ANDROID_CROSS_COMPILER="x86_64-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export JNIDIR="x86_64"
        export CFLAGS="-target x86_64-none-linux-android -march=x86-64 -msse4.2 -mpopcnt -m64 -mtune=intel ${CFLAGS}"
        export LDFLAGS="-target x86_64-none-linux-android -march=x86-64 ${LDFLAGS}"
        
        MMASON_ANDROID_ARCH="x86_64"
        MASON_ANDROID_PLATFORM="21"

    elif [ ${MASON_ANDROID_ABI} = 'mips' ]; then
        MASON_ANDROID_TOOLCHAIN="mipsel-linux-android"
        MASON_ANDROID_CROSS_COMPILER="mipsel-linux-android-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target mipsel-none-linux-android ${CFLAGS}"
        export LDFLAGS="-target mipsel-none-linux-android ${LDFLAGS}"
        
        export JNIDIR="mips"
        MASON_ANDROID_ARCH="mips"
        MASON_ANDROID_PLATFORM="9"

    elif [ ${MASON_ANDROID_ABI} = 'mips-64' ]; then
        MASON_ANDROID_TOOLCHAIN="mips64el-linux-android"
        MASON_ANDROID_CROSS_COMPILER="mips64el-linux-android-4.9"
        export MASON_HOST_ARG="--host=${MASON_ANDROID_TOOLCHAIN}"

        export CFLAGS="-target mips64el-none-linux-android ${CFLAGS}"
        export LDFLAGS="-target mips64el-none-linux-android ${LDFLAGS}"
        
        export JNIDIR="mips64"
        MASON_ANDROID_ARCH="mips64"
        MASON_ANDROID_PLATFORM="21"
    fi

    export CXXFLAGS="${CFLAGS} -std=c++11"
    
    export MASON_PLATFORM_VERSION="${MASON_ANDROID_ABI}-${MASON_ANDROID_PLATFORM}"
    MASON_API_LEVEL=${MASON_API_LEVEL:-android-$MASON_ANDROID_PLATFORM}
    
    MASON_SDK_ROOT="${MASON_ROOT}/.android-platform/${MASON_PLATFORM_VERSION}/"
    MASON_SDK_PATH="${MASON_SDK_ROOT}/sysroot"
    export PATH=${MASON_SDK_ROOT}/bin:${PATH}
    
    export CXX="${MASON_ANDROID_TOOLCHAIN}-clang++"
    export CC="${MASON_ANDROID_TOOLCHAIN}-clang"
    export LD="${MASON_ANDROID_TOOLCHAIN}-ld"
    export AR="${MASON_ANDROID_TOOLCHAIN}-ar"
    export RANLIB="${MASON_ANDROID_TOOLCHAIN}-ranlib"
    export STRIP="${MASON_ANDROID_TOOLCHAIN}-strip"
    
    if [ ! -d ${MASON_SDK_ROOT} ]; then
        echo "creating android toolchain with ${MASON_ANDROID_CROSS_COMPILER}/${MASON_API_LEVEL} at ${MASON_SDK_ROOT}"
        "${ANDROID_NDK_PATH}/build/tools/make-standalone-toolchain.sh"  \
          --toolchain="${MASON_ANDROID_CROSS_COMPILER}" \
          --llvm-version=3.5 \
          --package-dir="${ANDROID_NDK_PATH}/package-dir/" \
          --install-dir="${MASON_SDK_ROOT}" \
          --stl="libcxx" \
          --arch="${MASON_ANDROID_ARCH}" \
          --platform="${MASON_API_LEVEL}"
    fi
fi


# Variable defaults
MASON_HOST_ARG=${MASON_HOST_ARG:-}
MASON_PLATFORM_VERSION=${MASON_PLATFORM_VERSION:-0}
MASON_NAME=${MASON_NAME:-nopackage}
MASON_VERSION=${MASON_VERSION:-noversion}
MASON_HEADER_ONLY=${MASON_HEADER_ONLY:-false}
MASON_SLUG=${MASON_NAME}-${MASON_VERSION}
if [[ ${MASON_HEADER_ONLY} == true ]]; then
    MASON_PLATFORM_ID=headers
else
    MASON_PLATFORM_ID=${MASON_PLATFORM}-${MASON_PLATFORM_VERSION}
fi
MASON_PREFIX=${MASON_ROOT}/${MASON_PLATFORM_ID}/${MASON_NAME}/${MASON_VERSION}
MASON_BINARIES=${MASON_PLATFORM_ID}/${MASON_NAME}/${MASON_VERSION}.tar.gz
MASON_BINARIES_PATH=${MASON_ROOT}/.binaries/${MASON_BINARIES}




function mason_check_existing {
    # skip installing if it already exists
    if [ ${MASON_HEADER_ONLY:-false} = true ] ; then
        if [ -d "${MASON_PREFIX}" ] ; then
            mason_success "Already installed at ${MASON_PREFIX}"
            exit 0
        fi
    else
        if [ -f "${MASON_PREFIX}/${MASON_LIB_FILE}" ] ; then
            mason_success "Already installed at ${MASON_PREFIX}"
            exit 0
        fi
    fi
}


function mason_clear_existing {
    if [ -d "${MASON_PREFIX}" ]; then
        mason_step "Removing existing package... ${MASON_PREFIX}"
        rm -rf "${MASON_PREFIX}"
    fi
}


function mason_download {
    mkdir -p "${MASON_ROOT}/.cache"
    cd "${MASON_ROOT}/.cache"
    if [ ! -f ${MASON_SLUG} ] ; then
        mason_step "Downloading $1..."
        curl --retry 3 -f -# -L "$1" -o ${MASON_SLUG}
    fi

    MASON_HASH=`git hash-object ${MASON_SLUG}`
    if [ "$2" != "${MASON_HASH}" ] ; then
        mason_error "Hash ${MASON_HASH} of file ${MASON_ROOT}/.cache/${MASON_SLUG} doesn't match $2"
        exit 1
    fi
}

function mason_extract_tar_gz {
    rm -rf "${MASON_ROOT}/.build"
    mkdir -p "${MASON_ROOT}/.build"
    cd "${MASON_ROOT}/.build"

    tar xzf ../.cache/${MASON_SLUG} $@
}

function mason_extract_tar_bz2 {
    rm -rf "${MASON_ROOT}/.build"
    mkdir -p "${MASON_ROOT}/.build"
    cd "${MASON_ROOT}/.build"

    tar xjf ../.cache/${MASON_SLUG} $@
}

function mason_extract_tar_xz {
    rm -rf "${MASON_ROOT}/.build"
    mkdir -p "${MASON_ROOT}/.build"
    cd "${MASON_ROOT}/.build"

    tar xJf ../.cache/${MASON_SLUG} $@
}

function mason_prepare_compile {
    :
}

function mason_compile {
    mason_error "COMPILE FUNCTION MISSING"
    exit 1
}

function mason_clean {
    :
}

function link_files_in_root {
    if [[ -d "${MASON_PREFIX}/$1/" ]] ; then
        for i in $(ls ${MASON_PREFIX}/$1/*.*); do
            common_part=$(python -c "import os;print os.path.relpath('$i','${MASON_PREFIX}')")
            if [[ $common_part != '.' ]] && [[ ! -e "${MASON_ROOT}/.link/$common_part" ]]; then
                mason_step "linking ${MASON_ROOT}/.link/$common_part"
                mkdir -p $(dirname ${MASON_ROOT}/.link/$common_part)
                ln -sf ${MASON_PREFIX}/$common_part ${MASON_ROOT}/.link/$common_part
            else
                mason_success "Already linked file ${MASON_ROOT}/.link/$common_part"
            fi
        done
    fi
}

function link_files_recursively {
    if [[ -d "${MASON_PREFIX}/$1/" ]] ; then
        for i in $(find -H ${MASON_PREFIX}/$1/ -name "*" ! -type d -print); do
            common_part=$(python -c "import os;print os.path.relpath('$i','${MASON_PREFIX}')")
            if [[ $common_part != '.' ]] && [[ ! -e "${MASON_ROOT}/.link/$common_part" ]]; then
                mason_step "linking ${MASON_ROOT}/.link/$common_part"
                mkdir -p $(dirname ${MASON_ROOT}/.link/$common_part)
                ln -sf ${MASON_PREFIX}/$common_part ${MASON_ROOT}/.link/$common_part
            else
                mason_success "Already linked file ${MASON_ROOT}/.link/$common_part"
            fi
        done
    fi
}

function link_dir {
    if [[ -d ${MASON_PREFIX}/$1 ]]; then
        FOUND_SUBDIR=$(find ${MASON_PREFIX}/$1 -maxdepth 1 -mindepth 1 -name "*" -type d -print)
        # for headers like boost that use include/boost it is most efficient to symlink just the directory
        if [[ ${FOUND_SUBDIR} ]]; then
            for dir in ${FOUND_SUBDIR}; do
                local SUBDIR_BASENAME=$(basename $dir)
                # skip man entries to avoid conflicts
                if [[ $SUBDIR_BASENAME == "man" || $SUBDIR_BASENAME == "aclocal" || $SUBDIR_BASENAME == "doc" ]]; then
                    continue;
                else
                    local TARGET_SUBDIR="${MASON_ROOT}/.link/$1/${SUBDIR_BASENAME}"
                    if [[ ! -d ${TARGET_SUBDIR} && ! -L ${TARGET_SUBDIR} ]]; then
                        mason_step "linking directory ${TARGET_SUBDIR}"
                        mkdir -p $(dirname ${TARGET_SUBDIR})
                        ln -s ${MASON_PREFIX}/$1/${SUBDIR_BASENAME} ${TARGET_SUBDIR}
                    else
                        mason_success "Already linked directory ${TARGET_SUBDIR}"
                    fi
                fi
            done
            # still need to link files in the root directory for apps like postgres
            link_files_in_root include
        else
            link_files_recursively include
        fi
    fi
}

function mason_link {
    if [ ! -d "${MASON_PREFIX}" ] ; then
        mason_error "${MASON_PREFIX} not found, please install first"
        exit 0
    fi
    link_files_recursively lib
    link_files_recursively bin
    link_dir include
    link_dir share
}


function mason_build {
    mason_load_source

    mason_step "Building for Platform '${MASON_PLATFORM}/${MASON_PLATFORM_VERSION}'..."
    cd "${MASON_BUILD_PATH}"
    mason_prepare_compile

    if [ ${MASON_PLATFORM} = 'ios' ]; then
        mason_substep "Building for Simulator..."
        export CFLAGS="${MASON_ISIM_CFLAGS}"
        cd "${MASON_BUILD_PATH}"
        mason_compile
        cd "${MASON_PREFIX}"
        mv lib lib-isim
        for i in lib-isim/*.a ; do lipo -info $i ; done

        mason_substep "Building for iOS..."
        export CFLAGS="${MASON_IOS_CFLAGS}"
        cd "${MASON_BUILD_PATH}"
        mason_clean
        cd "${MASON_BUILD_PATH}"
        mason_compile
        cd "${MASON_PREFIX}"
        cp -r lib lib-ios
        for i in lib-ios/*.a ; do lipo -info $i ; done

        # Create universal binary
        mason_substep "Creating Universal Binary..."
        cd "${MASON_PREFIX}/lib-ios"
        for i in *.a ; do
            lipo -create ../lib-ios/$i ../lib-isim/$i -output ../lib/$i
            lipo -info ../lib/$i
        done
        cd "${MASON_PREFIX}"
        rm -rf lib-isim lib-ios
    elif [ ${MASON_PLATFORM} = 'android' ]; then
        cd "${MASON_BUILD_PATH}"
        mason_compile
    else
        cd "${MASON_BUILD_PATH}"
        mason_compile
    fi

    mason_success "Installed at ${MASON_PREFIX}"

    rm -rf ${MASON_ROOT}/.build
}


function mason_try_binary {
    MASON_BINARIES_DIR=`dirname "${MASON_BINARIES}"`
    mkdir -p "${MASON_ROOT}/.binaries/${MASON_BINARIES_DIR}"

    # try downloading from S3
    if [ ! -f "${MASON_BINARIES_PATH}" ] ; then
        mason_step "Downloading binary package ${MASON_BINARIES}..."
        curl --retry 3 -s -f -# -L \
            https://${MASON_BUCKET}.s3.amazonaws.com/${MASON_BINARIES} \
            -o "${MASON_BINARIES_PATH}" || mason_step "Binary not available yet for ${MASON_BINARIES}"
    else
        mason_step "Updating binary package ${MASON_BINARIES}..."
        curl --retry 3 -s -f -# -L -z "${MASON_BINARIES_PATH}" \
            https://${MASON_BUCKET}.s3.amazonaws.com/${MASON_BINARIES} \
            -o "${MASON_BINARIES_PATH}" || mason_step "Binary not available yet for ${MASON_BINARIES}"
    fi

    # unzip the file if it exists
    if [ -f "${MASON_BINARIES_PATH}" ] ; then
        mkdir -p "${MASON_PREFIX}"
        cd "${MASON_PREFIX}"
        tar xzf "${MASON_BINARIES_PATH}"

        if [ -f "${MASON_PREFIX}/${MASON_PKGCONFIG_FILE}" ] ; then
            # Change the prefix
            MASON_ESCAPED_PREFIX=$(echo "${MASON_PREFIX}" | sed -e 's/[\/&]/\\&/g')
            sed -i.bak "s/prefix=.*/prefix=${MASON_ESCAPED_PREFIX}/" \
                "${MASON_PREFIX}/${MASON_PKGCONFIG_FILE}"
        fi

        mason_success "Installed binary package at ${MASON_PREFIX}"
        exit 0
    fi
}


function mason_pkgconfig {
    echo pkg-config \
        ${MASON_PREFIX}/${MASON_PKGCONFIG_FILE}
}

function mason_cflags {
    `mason_pkgconfig` --static --cflags
}

function mason_ldflags {
    `mason_pkgconfig` --static --libs
}

function mason_static_libs {
    if [ -z "${MASON_LIB_FILE}" ]; then
        mason_substep "Linking ${MASON_NAME} ${MASON_VERSION} dynamically"
    elif [ -f "${MASON_PREFIX}/${MASON_LIB_FILE}" ]; then
        echo "${MASON_PREFIX}/${MASON_LIB_FILE}"
    else
        mason_error "No static library file '${MASON_PREFIX}/${MASON_LIB_FILE}'"
        exit 1
    fi
}

function mason_prefix {
    if [ -f "${MASON_PREFIX}/${MASON_LIB_FILE}" ]; then
        echo ${MASON_PREFIX}
    else
        mason_error "Cannot find required library file '${MASON_PREFIX}/${MASON_LIB_FILE}'"
        exit 1
    fi
}

function mason_version {
    if [ ${MASON_SYSTEM_PACKAGE:-false} = true ]; then
        mason_system_version
    else
        echo ${MASON_VERSION}
    fi
}

function mason_publish {
    if [ ! ${MASON_HEADER_ONLY:-false} = true ] && [ ! -f "${MASON_PREFIX}/${MASON_LIB_FILE}" ]; then
        mason_error "Required library file ${MASON_PREFIX}/${MASON_LIB_FILE} doesn't exist."
        exit 1
    fi

    if [ -z "${AWS_ACCESS_KEY_ID}" ]; then
        mason_error "AWS_ACCESS_KEY_ID is not set."
        exit 1
    fi

    if [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
        mason_error "AWS_SECRET_ACCESS_KEY is not set."
        exit 1
    fi

    mkdir -p `dirname ${MASON_BINARIES_PATH}`
    cd "${MASON_PREFIX}"
    rm -rf "${MASON_BINARIES_PATH}"
    tar czf "${MASON_BINARIES_PATH}" .
    (cd "${MASON_ROOT}/.binaries" && ls -lh "${MASON_BINARIES}")
    mason_step "Uploading binary package..."

    local CONTENT_TYPE="application/octet-stream"
    local DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %X %z")"
    local MD5="$(openssl md5 -binary < "${MASON_BINARIES_PATH}" | base64)"
    local SIGNATURE="$(printf "PUT\n$MD5\n$CONTENT_TYPE\n$DATE\nx-amz-acl:public-read\n/${MASON_BUCKET}/${MASON_BINARIES}" | openssl sha1 -binary -hmac "$AWS_SECRET_ACCESS_KEY" | base64)"

    curl -S -T "${MASON_BINARIES_PATH}" https://${MASON_BUCKET}.s3.amazonaws.com/${MASON_BINARIES} \
        -H "Date: $DATE" \
        -H "Authorization: AWS $AWS_ACCESS_KEY_ID:$SIGNATURE" \
        -H "Content-Type: $CONTENT_TYPE" \
        -H "Content-MD5: $MD5" \
        -H "x-amz-acl: public-read"

    echo https://${MASON_BUCKET}.s3.amazonaws.com/${MASON_BINARIES}
    curl -f -I https://${MASON_BUCKET}.s3.amazonaws.com/${MASON_BINARIES}
}

function mason_run {
    if [ "$1" == "install" ]; then
        if [ ${MASON_SYSTEM_PACKAGE:-false} = true ]; then
            mason_check_existing
            mason_clear_existing
            mason_build
            mason_success "Using system-provided ${MASON_NAME} $(mason_system_version)"
        else
            mason_check_existing
            mason_clear_existing
            mason_try_binary
            mason_build
        fi
    elif [ "$1" == "link" ]; then
        mason_link
    elif [ "$1" == "remove" ]; then
        mason_clear_existing
    elif [ "$1" == "publish" ]; then
        mason_publish
    elif [ "$1" == "build" ]; then
        mason_clear_existing
        mason_build
    elif [ "$1" == "cflags" ]; then
        mason_cflags
    elif [ "$1" == "ldflags" ]; then
        mason_ldflags
    elif [ "$1" == "static_libs" ]; then
        mason_static_libs
    elif [ "$1" == "version" ]; then
        mason_version
    elif [ "$1" == "prefix" ]; then
        mason_prefix
    elif [ $1 ]; then
        mason_error "Unknown command '$1'"
        exit 1
    else
        mason_error "Usage: $0 <command> <lib> <version>"
        exit 1
    fi
}

