# FindCustomFFmpeg.cmake
# Locates prebuilt FFmpeg artifacts produced by the custom_ffmpeg build system.
#
# Usage in a consuming project:
#
#   # Option A: point at a specific build variant
#   set(CUSTOM_FFMPEG_ROOT "${CMAKE_SOURCE_DIR}/../custom_ffmpeg/prebuilt/windows-x64/static/full")
#   find_package(CustomFFmpeg REQUIRED COMPONENTS avutil swscale)
#
#   # Option B: let the module auto-locate via CUSTOM_FFMPEG_ROOT env var
#   find_package(CustomFFmpeg REQUIRED)
#
# Imported targets created (one per found component):
#   CustomFFmpeg::avutil    CustomFFmpeg::avcodec   CustomFFmpeg::avformat
#   CustomFFmpeg::avdevice  CustomFFmpeg::avfilter  CustomFFmpeg::swscale
#   CustomFFmpeg::swresample
#
# Cache variables:
#   CUSTOM_FFMPEG_ROOT       — root of the prebuilt tree (include/ + lib/ live here)
#   CUSTOM_FFMPEG_DEPS_DIR   — external dep libs (x264, vpx, ...); default
#                              <prebuilt>/.deps/<platform>/lib next to the root
#   CUSTOM_FFMPEG_INCLUDE_DIR
#   CUSTOM_FFMPEG_LIBRARY_<name>   e.g. CUSTOM_FFMPEG_LIBRARY_avutil
#
# Result variables:
#   CUSTOM_FFMPEG_LIBRARIES        — FFmpeg component libraries
#   CUSTOM_FFMPEG_EXTRA_LIBRARIES  — external deps + system libs from the .pc
#                                    files (static builds), already on the targets;
#                                    may hold generator expressions (MSVC runtime, below)
#   CUSTOM_FFMPEG_SHARED           — TRUE for a shared build (DLL / .so / .dylib)
#   CUSTOM_FFMPEG_RUNTIME_LIBRARIES — the DLLs / shared libraries to ship with
#                                    the application (shared builds)
#
# Requested components pull in the components they require (from the .pc files).
# Static build: each target carries the include dir plus everything needed for
# the final link (other components, external deps, system libraries).
# Shared build: SHARED IMPORTED targets (Windows: import lib + DLL) linking the
# components they require; on Windows copy $<TARGET_RUNTIME_DLLS:app> next to
# the executable (see tests/consumer/CMakeLists.txt).
#
# MSVC, static build: the C++ dependencies (x265, the libvpl dispatcher) exist
# twice — <deps>/lib for the release runtime (/MD) and <deps>/lib/debug for the
# debug runtime (/MDd). Each consuming target links the copy that matches ITS
# runtime: the MSVC_RUNTIME_LIBRARY property (CMAKE_MSVC_RUNTIME_LIBRARY,
# default MultiThreaded$<$<CONFIG:Debug>:Debug>DLL), or — when the project
# still sets /MD /MDd through flags (policy CMP0091 OLD) — the Debug configuration.

# The caller's CMP0091 (MSVC_RUNTIME_LIBRARY in effect), before this module's
# own cmake_minimum_required changes the policy settings
set(_cf_cmp0091 "")
if(POLICY CMP0091)
    cmake_policy(GET CMP0091 _cf_cmp0091)
endif()
cmake_minimum_required(VERSION 3.15)

# ── Locate prebuilt root ──────────────────────────────────────────────────────
if(NOT CUSTOM_FFMPEG_ROOT)
    if(DEFINED ENV{CUSTOM_FFMPEG_ROOT})
        set(CUSTOM_FFMPEG_ROOT "$ENV{CUSTOM_FFMPEG_ROOT}" CACHE PATH
            "Root of custom_ffmpeg prebuilt artifacts")
    endif()
endif()

if(NOT CUSTOM_FFMPEG_ROOT)
    # Heuristic: look for the prebuilt tree relative to this file's location.
    # Expected layout:  custom_ffmpeg/cmake/FindCustomFFmpeg.cmake
    #                   custom_ffmpeg/prebuilt/<platform>/<type>/<profile>/
    set(_cf_candidates
        "${CMAKE_CURRENT_LIST_DIR}/../prebuilt/windows-x64/static/full"
        "${CMAKE_CURRENT_LIST_DIR}/../prebuilt/linux-x64/static/full"
        "${CMAKE_CURRENT_LIST_DIR}/../prebuilt/macos-arm64/static/full"
    )
    foreach(_c IN LISTS _cf_candidates)
        if(EXISTS "${_c}/include/libavutil/avutil.h")
            set(CUSTOM_FFMPEG_ROOT "${_c}" CACHE PATH
                "Root of custom_ffmpeg prebuilt artifacts")
            break()
        endif()
    endforeach()
endif()

# ── Find include directory ────────────────────────────────────────────────────
find_path(CUSTOM_FFMPEG_INCLUDE_DIR
    NAMES libavutil/avutil.h
    PATHS "${CUSTOM_FFMPEG_ROOT}/include"
    NO_DEFAULT_PATH
)

# ── Available FFmpeg component libraries ─────────────────────────────────────
set(_cf_all_components
    avutil avcodec avformat avdevice avfilter swscale swresample
)

# _cf_pc_requires(<comp> <out-var>) — FFmpeg components named in the
# Requires lines of lib<comp>.pc (e.g. swscale -> avutil). Static builds list
# them in `Requires:`, shared builds in `Requires.private:`.
function(_cf_pc_requires comp out)
    set(_req "")
    set(_pc "${CUSTOM_FFMPEG_ROOT}/lib/pkgconfig/lib${comp}.pc")
    if(EXISTS "${_pc}")
        file(STRINGS "${_pc}" _line REGEX "^Requires(\\.private)?:")
        string(REGEX MATCHALL "lib(avutil|avcodec|avformat|avdevice|avfilter|swscale|swresample)"
            _libs "${_line}")
        foreach(_l IN LISTS _libs)
            string(REGEX REPLACE "^lib" "" _l "${_l}")
            list(APPEND _req "${_l}")
        endforeach()
    endif()
    set(${out} "${_req}" PARENT_SCOPE)
endfunction()

# Use requested COMPONENTS if provided, otherwise find all available.
# Requested components pull in the components they require (from the .pc
# files): a static link needs their symbols, a shared one their DLLs/.so.
if(CustomFFmpeg_FIND_COMPONENTS)
    set(_cf_components ${CustomFFmpeg_FIND_COMPONENTS})
    set(_cf_queue ${_cf_components})
    while(_cf_queue)
        list(POP_FRONT _cf_queue _comp)
        _cf_pc_requires(${_comp} _req)
        foreach(_r IN LISTS _req)
            if(NOT _r IN_LIST _cf_components)
                list(APPEND _cf_components ${_r})
                list(APPEND _cf_queue ${_r})
            endif()
        endforeach()
    endwhile()
else()
    set(_cf_components ${_cf_all_components})
endif()

# ── Find each library ─────────────────────────────────────────────────────────
# Static build: lib/<comp>.lib | lib/lib<comp>.a
# Shared build: Windows lib/<comp>.lib (import lib) + bin/<comp>-<major>.dll,
#               Linux/macOS lib/lib<comp>.so / .dylib
set(CUSTOM_FFMPEG_LIBRARIES "")
set(CUSTOM_FFMPEG_RUNTIME_LIBRARIES "")
set(CUSTOM_FFMPEG_SHARED FALSE)
set(_cf_found_all TRUE)
set(_cf_missing "")

foreach(_comp IN LISTS _cf_components)
    find_library(CUSTOM_FFMPEG_LIBRARY_${_comp}
        NAMES ${_comp}
        PATHS "${CUSTOM_FFMPEG_ROOT}/lib"
        NO_DEFAULT_PATH
    )
    if(CUSTOM_FFMPEG_LIBRARY_${_comp})
        list(APPEND CUSTOM_FFMPEG_LIBRARIES "${CUSTOM_FFMPEG_LIBRARY_${_comp}}")
        set(CustomFFmpeg_${_comp}_FOUND TRUE)   # read by HANDLE_COMPONENTS
        set(_cf_runtime_${_comp} "")
        if(WIN32)
            file(GLOB _dll "${CUSTOM_FFMPEG_ROOT}/bin/${_comp}-*.dll")
            if(_dll)
                list(GET _dll 0 _cf_runtime_${_comp})
            endif()
        elseif(CUSTOM_FFMPEG_LIBRARY_${_comp} MATCHES "\\.(so|dylib)$")
            set(_cf_runtime_${_comp} "${CUSTOM_FFMPEG_LIBRARY_${_comp}}")
        endif()
        if(_cf_runtime_${_comp})
            set(CUSTOM_FFMPEG_SHARED TRUE)
            list(APPEND CUSTOM_FFMPEG_RUNTIME_LIBRARIES "${_cf_runtime_${_comp}}")
        endif()
    else()
        set(CustomFFmpeg_${_comp}_FOUND FALSE)
        set(_cf_found_all FALSE)
        list(APPEND _cf_missing "${_comp}")
        if(CustomFFmpeg_FIND_REQUIRED_${_comp})
            message(SEND_ERROR
                "FindCustomFFmpeg: required component '${_comp}' not found under "
                "${CUSTOM_FFMPEG_ROOT}/lib")
        endif()
    endif()
endforeach()

# ── External deps + system libs (from pkg-config files) ───────────────────────
# A static FFmpeg needs everything it was configured with at the final link:
# external codec libs (x264, vpx, ...) and system libs (user32, bcrypt, m, ...).
# configure records the exact list in the `Libs:` line of each lib<name>.pc.
# A shared FFmpeg has them linked into its DLLs/.so: `Libs:` then lists only
# the FFmpeg library itself (the rest is in Libs.private, not needed here).
if(NOT CUSTOM_FFMPEG_DEPS_DIR AND CUSTOM_FFMPEG_ROOT)
    # Layout: <prebuilt>/<platform>/<type>/<profile>  and  <prebuilt>/.deps/<platform>/lib
    get_filename_component(_cf_platform_dir "${CUSTOM_FFMPEG_ROOT}/../.." ABSOLUTE)
    get_filename_component(_cf_platform "${_cf_platform_dir}" NAME)
    get_filename_component(_cf_prebuilt "${_cf_platform_dir}/.." ABSOLUTE)
    if(EXISTS "${_cf_prebuilt}/.deps/${_cf_platform}/lib")
        set(CUSTOM_FFMPEG_DEPS_DIR "${_cf_prebuilt}/.deps/${_cf_platform}/lib" CACHE PATH
            "custom_ffmpeg external dependency libraries")
    endif()
endif()

# MSVC runtime of the consuming target as a generator expression: 1 for the
# debug runtime (/MDd, /MTd). Evaluated per target and configuration, so
# CMAKE_MSVC_RUNTIME_LIBRARY overrides (e.g. the release runtime in Debug) are
# honoured. CMP0091 OLD: the runtime is in the compile flags — assume the
# CMake default (/MDd exactly in Debug). GENEX_EVAL: the property itself may
# be a generator expression (e.g. MultiThreaded$<$<CONFIG:Debug>:Debug>DLL),
# which $<TARGET_PROPERTY> returns unevaluated.
set(_cf_rt "$<GENEX_EVAL:$<TARGET_PROPERTY:MSVC_RUNTIME_LIBRARY>>")
if(_cf_cmp0091 STREQUAL "NEW")
    set(_cf_debug_crt "$<IF:$<BOOL:${_cf_rt}>,$<OR:$<STREQUAL:${_cf_rt},MultiThreadedDebugDLL>,$<STREQUAL:${_cf_rt},MultiThreadedDebug>>,$<CONFIG:Debug>>")
else()
    set(_cf_debug_crt "$<CONFIG:Debug>")
endif()
set(_cf_debug_variants "")       # deps linked per runtime (lib/debug/<name>.lib)
set(_cf_cxx_no_variant "")       # C++ deps without a debug-runtime copy (older deps tree)

set(_cf_extra "")
set(_cf_link_order avdevice avfilter avformat avcodec swresample swscale avutil)
foreach(_comp IN LISTS _cf_link_order)
    if(NOT _comp IN_LIST _cf_components OR NOT CUSTOM_FFMPEG_LIBRARY_${_comp})
        continue()
    endif()
    set(_pc "${CUSTOM_FFMPEG_ROOT}/lib/pkgconfig/lib${_comp}.pc")
    if(NOT EXISTS "${_pc}")
        message(WARNING "FindCustomFFmpeg: ${_pc} not found — external/system "
                        "libraries for ${_comp} must be linked manually")
        continue()
    endif()
    file(STRINGS "${_pc}" _pc_libs REGEX "^Libs:")
    string(REGEX REPLACE "^Libs:" " " _pc_libs "${_pc_libs}")
    separate_arguments(_pc_tokens UNIX_COMMAND "${_pc_libs}")

    set(_framework FALSE)
    foreach(_tok IN LISTS _pc_tokens)
        if(_framework)
            list(APPEND _cf_extra "-framework ${_tok}")
            set(_framework FALSE)
        elseif(_tok STREQUAL "-framework")
            set(_framework TRUE)
        elseif(_tok MATCHES "^-L")
            # search dirs: FFmpeg libs are imported by path, deps resolved below
        elseif(_tok MATCHES "^-l(.+)$")
            set(_name "${CMAKE_MATCH_1}")
            if(_name IN_LIST _cf_all_components)
                continue()
            endif()
            # External deps by full path (static archive preferred);
            # anything not in the deps dir is a system library
            if(WIN32)
                set(_names "${_name}.lib" "${_name}")
            else()
                set(_names "lib${_name}.a" "${_name}")
            endif()
            find_library(CUSTOM_FFMPEG_DEP_${_name}
                NAMES ${_names}
                PATHS "${CUSTOM_FFMPEG_DEPS_DIR}"
                NO_DEFAULT_PATH
            )
            mark_as_advanced(CUSTOM_FFMPEG_DEP_${_name})
            set(_dbg "${CUSTOM_FFMPEG_DEPS_DIR}/debug/${_name}.lib")
            if(CUSTOM_FFMPEG_DEP_${_name} AND WIN32 AND EXISTS "${_dbg}")
                # C++ dependency built for both MSVC runtimes: pick per target
                list(APPEND _cf_extra
                    "$<${_cf_debug_crt}:${_dbg}>$<$<NOT:${_cf_debug_crt}>:${CUSTOM_FFMPEG_DEP_${_name}}>")
                list(APPEND _cf_debug_variants "${_name}")
            elseif(CUSTOM_FFMPEG_DEP_${_name})
                list(APPEND _cf_extra "${CUSTOM_FFMPEG_DEP_${_name}}")
                if(WIN32 AND _name MATCHES "^(x265|vpl)$")
                    list(APPEND _cf_cxx_no_variant "${_name}")
                endif()
            else()
                list(APPEND _cf_extra "${_name}")
            endif()
        else()
            # other linker flags (-pthread, -Wl,...) or absolute paths
            list(APPEND _cf_extra "${_tok}")
        endif()
    endforeach()
endforeach()

# Static link order: a library must come after everything that uses it, so on
# duplicates keep the LAST occurrence
list(REVERSE _cf_extra)
list(REMOVE_DUPLICATES _cf_extra)
list(REVERSE _cf_extra)
set(CUSTOM_FFMPEG_EXTRA_LIBRARIES "${_cf_extra}")

list(REMOVE_DUPLICATES _cf_debug_variants)
list(REMOVE_DUPLICATES _cf_cxx_no_variant)

# MSVC, static build: the dependencies are built for the DLL runtime (/MD,
# /MDd). C++ ones without a debug-runtime copy (a deps tree from before
# lib/debug existed) fail to link into /MDd targets with LNK2038 "mismatch
# detected" — say so up front instead of leaving a cryptic link error.
if(WIN32 AND NOT CUSTOM_FFMPEG_SHARED)
    if(_cf_debug_variants AND NOT CustomFFmpeg_FIND_QUIETLY)
        message(STATUS "CustomFFmpeg: C++ dependencies linked per MSVC runtime "
                       "(/MD: lib, /MDd: lib/debug): ${_cf_debug_variants}")
    endif()
    if(_cf_cxx_no_variant)
        message(WARNING
            "CustomFFmpeg: ${_cf_cxx_no_variant} (C++) exist only for the release runtime "
            "(no ${CUSTOM_FFMPEG_DEPS_DIR}/debug). Targets using the debug runtime (/MDd, "
            "the Debug default) fail to link with LNK2038. Rebuild the dependencies with "
            "the current custom_ffmpeg, or use the release runtime for those targets: "
            "set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL).")
    endif()
    if(CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "^MultiThreaded(Debug)?$")
        message(WARNING
            "CustomFFmpeg: CMAKE_MSVC_RUNTIME_LIBRARY=${CMAKE_MSVC_RUNTIME_LIBRARY} (static "
            "C runtime, /MT): the prebuilt libraries are built for the DLL runtime "
            "(/MD, /MDd) — use MultiThreaded$<$<CONFIG:Debug>:Debug>DLL.")
    endif()
endif()

# ── Validation ────────────────────────────────────────────────────────────────
include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(CustomFFmpeg
    REQUIRED_VARS CUSTOM_FFMPEG_INCLUDE_DIR
    HANDLE_COMPONENTS
)

# ── Create imported targets ───────────────────────────────────────────────────
if(CustomFFmpeg_FOUND)
    # libavutil/hwcontext_qsv.h includes <mfxvideo.h>: the build ships
    # libvpl's headers in include/vpl when QSV is enabled
    set(_cf_include_dirs "${CUSTOM_FFMPEG_INCLUDE_DIR}")
    if(IS_DIRECTORY "${CUSTOM_FFMPEG_INCLUDE_DIR}/vpl")
        list(APPEND _cf_include_dirs "${CUSTOM_FFMPEG_INCLUDE_DIR}/vpl")
    endif()

    # Build list of all found libs in static link order (_cf_link_order:
    # most-dependent first), followed by external deps and system libs
    set(_cf_all_found_ordered "")
    foreach(_lib IN LISTS _cf_link_order)
        if(_lib IN_LIST _cf_components AND CUSTOM_FFMPEG_LIBRARY_${_lib})
            list(APPEND _cf_all_found_ordered "${CUSTOM_FFMPEG_LIBRARY_${_lib}}")
        endif()
    endforeach()
    list(APPEND _cf_all_found_ordered ${CUSTOM_FFMPEG_EXTRA_LIBRARIES})

    # MSVC static: the CMake-built C deps (zlib, libwebp, SVT-AV1) name the
    # release CRT (/DEFAULTLIB:msvcrt.lib). C code serves both runtimes, but in
    # a /MDd link that default library conflicts with msvcrtd.lib (LNK4098) —
    # keep it out, as the linker suggests.
    set(_cf_link_options "")
    if(MSVC AND NOT CUSTOM_FFMPEG_SHARED)
        set(_cf_link_options "$<${_cf_debug_crt}:/NODEFAULTLIB:msvcrt.lib>")
    endif()

    set(_cf_targets "")
    foreach(_comp IN LISTS _cf_components)
        if(NOT CUSTOM_FFMPEG_LIBRARY_${_comp})
            continue()
        endif()
        set(_target "CustomFFmpeg::${_comp}")
        list(APPEND _cf_targets "${_target}")
        if(TARGET "${_target}")
            continue()
        endif()
        if(_cf_runtime_${_comp})
            # Shared: everything else is inside the DLL/.so; link only the
            # FFmpeg components it requires (so their DLLs are runtime deps too)
            add_library("${_target}" SHARED IMPORTED)
            set_target_properties("${_target}" PROPERTIES
                IMPORTED_LOCATION "${_cf_runtime_${_comp}}"
                INTERFACE_INCLUDE_DIRECTORIES "${_cf_include_dirs}"
            )
            if(WIN32)
                set_target_properties("${_target}" PROPERTIES
                    IMPORTED_IMPLIB "${CUSTOM_FFMPEG_LIBRARY_${_comp}}")
            endif()
            _cf_pc_requires(${_comp} _req)
            foreach(_r IN LISTS _req)
                set_property(TARGET "${_target}" APPEND PROPERTY
                    INTERFACE_LINK_LIBRARIES "CustomFFmpeg::${_r}")
            endforeach()
        else()
            add_library("${_target}" STATIC IMPORTED)
            set_target_properties("${_target}" PROPERTIES
                IMPORTED_LOCATION "${CUSTOM_FFMPEG_LIBRARY_${_comp}}"
                INTERFACE_INCLUDE_DIRECTORIES "${_cf_include_dirs}"
            )
            # For static builds every component must drag in all other found libs
            # to resolve cross-lib symbol references at the final link step.
            set_property(TARGET "${_target}" APPEND PROPERTY
                INTERFACE_LINK_LIBRARIES "${_cf_all_found_ordered}"
            )
            if(_cf_link_options)
                set_property(TARGET "${_target}" APPEND PROPERTY
                    INTERFACE_LINK_OPTIONS "${_cf_link_options}")
            endif()
        endif()
    endforeach()

    if(NOT TARGET CustomFFmpeg::FFmpeg)
        # Convenience aggregate target
        add_library(CustomFFmpeg::FFmpeg INTERFACE IMPORTED)
        if(CUSTOM_FFMPEG_SHARED)
            set(_cf_aggregate "${_cf_targets}")
        else()
            set(_cf_aggregate "${_cf_all_found_ordered}")
        endif()
        set_target_properties(CustomFFmpeg::FFmpeg PROPERTIES
            INTERFACE_LINK_LIBRARIES "${_cf_aggregate}"
            INTERFACE_INCLUDE_DIRECTORIES "${_cf_include_dirs}"
            INTERFACE_LINK_OPTIONS "${_cf_link_options}"
        )
    endif()
endif()

mark_as_advanced(
    CUSTOM_FFMPEG_ROOT
    CUSTOM_FFMPEG_DEPS_DIR
    CUSTOM_FFMPEG_INCLUDE_DIR
)
foreach(_comp IN LISTS _cf_all_components)
    mark_as_advanced(CUSTOM_FFMPEG_LIBRARY_${_comp})
endforeach()
