cmake_minimum_required(VERSION 3.22)
project(yuzic_alac LANGUAGES C CXX)
include(ExternalProject)

# Source only: no FFmpeg Java extension and no change to the host's Media3.
# Override with -DYUZIC_FFMPEG_SOURCE=/path/to/ffmpeg for an offline/local build.
set(YUZIC_FFMPEG_SOURCE "" CACHE PATH "FFmpeg source checkout (defaults to pinned 9.0.2 release)")
set(YUZIC_FFMPEG_JOBS 2 CACHE STRING "Parallel jobs for the minimal FFmpeg build")
if(NOT YUZIC_FFMPEG_SOURCE)
  include(FetchContent)
  FetchContent_Declare(ffmpeg_source
    URL https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
    URL_HASH SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e)
  FetchContent_GetProperties(ffmpeg_source)
  if(NOT ffmpeg_source_POPULATED)
    FetchContent_Populate(ffmpeg_source)
  endif()
  set(YUZIC_FFMPEG_SOURCE "${ffmpeg_source_SOURCE_DIR}")
endif()
if(NOT EXISTS "${YUZIC_FFMPEG_SOURCE}/configure")
  message(FATAL_ERROR "YUZIC_FFMPEG_SOURCE must name an FFmpeg source directory")
endif()

set(FFMPEG_BUILD "${CMAKE_CURRENT_BINARY_DIR}/ffmpeg-build")
file(MAKE_DIRECTORY "${FFMPEG_BUILD}/libavcodec" "${FFMPEG_BUILD}/libavutil")
find_program(FFMPEG_MAKE NAMES gmake make REQUIRED)
set(FFMPEG_CC "${CMAKE_C_COMPILER}")
set(FFMPEG_PLATFORM_ARGS)
if(ANDROID)
  string(APPEND FFMPEG_CC " --target=${CMAKE_C_COMPILER_TARGET} --sysroot=${CMAKE_SYSROOT}")
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(FFMPEG_ARCH aarch64)
  elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(FFMPEG_ARCH arm)
  elseif(ANDROID_ABI STREQUAL "x86_64")
    set(FFMPEG_ARCH x86_64)
  elseif(ANDROID_ABI STREQUAL "x86")
    set(FFMPEG_ARCH x86)
  else()
    message(FATAL_ERROR "Unsupported Android ABI: ${ANDROID_ABI}")
  endif()
  list(APPEND FFMPEG_PLATFORM_ARGS --enable-cross-compile --target-os=android
    "--arch=${FFMPEG_ARCH}" "--ar=${CMAKE_AR}" "--ranlib=${CMAKE_RANLIB}" "--strip=${CMAKE_STRIP}")
endif()

ExternalProject_Add(yuzic_ffmpeg
  SOURCE_DIR "${YUZIC_FFMPEG_SOURCE}"
  BINARY_DIR "${FFMPEG_BUILD}"
  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND "${YUZIC_FFMPEG_SOURCE}/configure"
    "--cc=${FFMPEG_CC}" ${FFMPEG_PLATFORM_ARGS}
    "--extra-cflags=${CMAKE_C_FLAGS} -O3 -fPIC -fvisibility=hidden"
    "--extra-ldflags=${CMAKE_EXE_LINKER_FLAGS}"
    --disable-everything --disable-autodetect --disable-programs --disable-doc
    --disable-network --disable-avformat --disable-avdevice --disable-avfilter
    --disable-swscale --disable-swresample --disable-shared --enable-static
    --disable-gpl --disable-nonfree --disable-version3 --disable-x86asm
    --disable-debug --enable-pic --enable-decoder=alac
  BUILD_COMMAND "${FFMPEG_MAKE}" "-j${YUZIC_FFMPEG_JOBS}" libavcodec/libavcodec.a libavutil/libavutil.a
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${FFMPEG_BUILD}/libavcodec/libavcodec.a" "${FFMPEG_BUILD}/libavutil/libavutil.a"
  LOG_CONFIGURE ON LOG_BUILD ON LOG_OUTPUT_ON_FAILURE ON)

add_library(yuzic_alac_core STATIC AlacDecoder.cpp)
add_dependencies(yuzic_alac_core yuzic_ffmpeg)
target_include_directories(yuzic_alac_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}"
  "${YUZIC_FFMPEG_SOURCE}" "${FFMPEG_BUILD}")
target_compile_features(yuzic_alac_core PUBLIC cxx_std_17)
set_target_properties(yuzic_alac_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(yuzic_alac_core PUBLIC
  "${FFMPEG_BUILD}/libavcodec/libavcodec.a" "${FFMPEG_BUILD}/libavutil/libavutil.a" m)

if(ANDROID)
  add_library(yuzic_alac SHARED AlacJni.cpp)
  target_link_libraries(yuzic_alac PRIVATE yuzic_alac_core)
  target_link_options(yuzic_alac PRIVATE -Wl,-z,max-page-size=16384 -Wl,--exclude-libs,ALL)
else()
  enable_testing()
  add_executable(alac_probe AlacProbe.cpp)
  target_link_libraries(alac_probe PRIVATE yuzic_alac_core)
  add_executable(alac_test AlacTest.cpp)
  target_link_libraries(alac_test PRIVATE yuzic_alac_core)
  add_test(NAME alac_packets COMMAND alac_test "${CMAKE_CURRENT_SOURCE_DIR}/../../test/resources/alac")
endif()
