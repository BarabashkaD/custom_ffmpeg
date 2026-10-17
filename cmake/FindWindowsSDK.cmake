# FindWindowsSDK.cmake
# Locates the latest installed Windows SDK and MSVC toolchain.
#
# Inputs (all optional — auto-detected when unset):
#   WINSDK_KITS_ROOT      -D or env: Windows Kits root (…/Windows Kits/10)
#   MSVC_BASE_DIR         -D or env: MSVC tools dir (…/VC/Tools/MSVC/<ver>)
#   MSVC_TOOLSET_RANGE    -D or env: MSVC toolset versions, default "[14.30,14.50)" (v143)
#   VS_VERSION_RANGE      -D or env: vswhere -version filter, e.g. "[17,18)"
#
# Output variables:
#   WINSDK_VERSION        e.g. 10.0.26100.0
#   WINSDK_KITS_ROOT      .../Windows Kits/10
#   WINSDK_INCLUDE_ROOT   .../Windows Kits/10/Include/<ver>
#   WINSDK_LIB_ROOT       .../Windows Kits/10/Lib/<ver>
#   MSVC_VERSION          e.g. 14.43.34808
#   MSVC_BASE_DIR         .../MSVC/<ver>
#   MSVC_INCLUDE          .../MSVC/<ver>/include
#   MSVC_LIB_X64          .../MSVC/<ver>/lib/x64

if(NOT WIN32)
    message(STATUS "FindWindowsSDK: skipped (not Windows)")
    return()
endif()

# -D value, then environment variable of the same name
macro(_winsdk_input var)
    if(NOT ${var} AND DEFINED ENV{${var}})
        file(TO_CMAKE_PATH "$ENV{${var}}" ${var})
    endif()
endmacro()
_winsdk_input(WINSDK_KITS_ROOT)
_winsdk_input(MSVC_BASE_DIR)
_winsdk_input(VS_VERSION_RANGE)
_winsdk_input(MSVC_TOOLSET_RANGE)

# Default toolset: v143 (MSVC 14.30–14.4x, the VS 2022 line) from any installed
# Visual Studio — VS 2022, or VS 2026 with its v143 component. The Docker
# image's clang must accept the MSVC STL headers, and libraries built against a
# newer MSVC than the consumer's toolset may not link (CRT/STL symbols).
# MSVC_TOOLSET_RANGE "" takes the newest toolset; VS_VERSION_RANGE (vswhere
# -version, e.g. "[17,18)") limits the Visual Studio installs searched.
if(NOT DEFINED MSVC_TOOLSET_RANGE)
    set(MSVC_TOOLSET_RANGE "[14.30,14.50)")
endif()

# --- Windows Kits: input → registry (where the SDK installer records it) → %ProgramFiles(x86)% ---
if(NOT WINSDK_KITS_ROOT)
    cmake_host_system_information(RESULT _kits_reg
        QUERY WINDOWS_REGISTRY "HKLM/SOFTWARE/Microsoft/Windows Kits/Installed Roots"
        VALUE KitsRoot10 VIEW 32_64)
    if(_kits_reg)
        file(TO_CMAKE_PATH "${_kits_reg}" WINSDK_KITS_ROOT)
    elseif(DEFINED ENV{ProgramFiles\(x86\)})
        file(TO_CMAKE_PATH "$ENV{ProgramFiles\(x86\)}/Windows Kits/10" WINSDK_KITS_ROOT)
    endif()
endif()
string(REGEX REPLACE "/+$" "" _kits_root "${WINSDK_KITS_ROOT}")
if(NOT _kits_root OR NOT EXISTS "${_kits_root}/Include")
    message(WARNING "Windows Kits not found (set WINSDK_KITS_ROOT): '${_kits_root}'")
    return()
endif()

# Only versioned dirs: Include/ also holds e.g. "wdf", which sorts above "10.*"
file(GLOB _sdk_versions LIST_DIRECTORIES true "${_kits_root}/Include/10.*")
if(NOT _sdk_versions)
    message(WARNING "No Windows SDK versions found under ${_kits_root}/Include")
    return()
endif()
list(SORT _sdk_versions COMPARE NATURAL ORDER DESCENDING)
list(GET _sdk_versions 0 _sdk_latest)
cmake_path(GET _sdk_latest FILENAME WINSDK_VERSION)

set(WINSDK_INCLUDE_ROOT "${_kits_root}/Include/${WINSDK_VERSION}")
set(WINSDK_LIB_ROOT     "${_kits_root}/Lib/${WINSDK_VERSION}")
set(WINSDK_KITS_ROOT    "${_kits_root}")

# --- MSVC: input, or the newest VS with the x64 C++ toolset via vswhere ---
if(NOT MSVC_BASE_DIR)
    # vswhere ships at a fixed location relative to %ProgramFiles(x86)%
    find_program(_vswhere vswhere
        PATHS "$ENV{ProgramFiles\(x86\)}/Microsoft Visual Studio/Installer"
        NO_DEFAULT_PATH
    )
    if(NOT _vswhere)
        message(WARNING "vswhere.exe not found — set MSVC_BASE_DIR")
        return()
    endif()

    # Every install (the toolset is chosen below, not the Visual Studio version;
    # a side-by-side toolset is a different component than the default one)
    set(_vs_filter -all -products *)
    if(VS_VERSION_RANGE)
        list(APPEND _vs_filter -version "${VS_VERSION_RANGE}")
    endif()
    execute_process(
        COMMAND "${_vswhere}" ${_vs_filter} -property installationPath
        OUTPUT_VARIABLE _vs_install_paths
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _vswhere_result
    )
    if(_vswhere_result OR NOT _vs_install_paths)
        message(WARNING "vswhere: no Visual Studio found — set MSVC_BASE_DIR")
        return()
    endif()

    set(_tool_min "")
    set(_tool_max "")
    if(MSVC_TOOLSET_RANGE MATCHES "^\\[([0-9.]+),([0-9.]+)\\)$")
        set(_tool_min "${CMAKE_MATCH_1}")
        set(_tool_max "${CMAKE_MATCH_2}")
    elseif(MSVC_TOOLSET_RANGE)
        message(FATAL_ERROR "MSVC_TOOLSET_RANGE must look like [14.30,14.50): '${MSVC_TOOLSET_RANGE}'")
    endif()

    # MSVC tool dirs of all installs within the toolset range (with the x64 compiler)
    string(REPLACE "\n" ";" _vs_install_paths "${_vs_install_paths}")
    set(_msvc_versions "")
    foreach(_vs IN LISTS _vs_install_paths)
        # Normalize backslashes → forward slashes (vswhere returns Windows-style paths)
        file(TO_CMAKE_PATH "${_vs}" _vs)
        file(GLOB _dirs LIST_DIRECTORIES true "${_vs}/VC/Tools/MSVC/14.*")
        foreach(_dir IN LISTS _dirs)
            cmake_path(GET _dir FILENAME _ver)
            if(NOT EXISTS "${_dir}/bin/Hostx64/x64/cl.exe")
                continue()
            endif()
            if(_tool_min AND (_ver VERSION_LESS _tool_min OR NOT _ver VERSION_LESS _tool_max))
                continue()
            endif()
            list(APPEND _msvc_versions "${_dir}")
        endforeach()
    endforeach()
    if(NOT _msvc_versions)
        message(WARNING "no MSVC x64 toolset in ${MSVC_TOOLSET_RANGE} found in any Visual Studio — "
                        "install it (VS 2022, or the v143 component of VS 2026) or set MSVC_BASE_DIR")
        return()
    endif()
    # Newest version; NATURAL sorts whole paths, so sort the version names
    set(_best_ver "")
    foreach(_dir IN LISTS _msvc_versions)
        cmake_path(GET _dir FILENAME _ver)
        if(NOT _best_ver OR _ver VERSION_GREATER _best_ver)
            set(_best_ver "${_ver}")
            set(MSVC_BASE_DIR "${_dir}")
        endif()
    endforeach()
endif()
string(REGEX REPLACE "/+$" "" MSVC_BASE_DIR "${MSVC_BASE_DIR}")
if(NOT EXISTS "${MSVC_BASE_DIR}/include")
    message(WARNING "MSVC include dir not found: ${MSVC_BASE_DIR}/include")
    return()
endif()

cmake_path(GET MSVC_BASE_DIR FILENAME MSVC_VERSION)
set(MSVC_INCLUDE  "${MSVC_BASE_DIR}/include")
set(MSVC_LIB_X64  "${MSVC_BASE_DIR}/lib/x64")

message(STATUS "Windows SDK : ${WINSDK_VERSION}  (${WINSDK_INCLUDE_ROOT})")
message(STATUS "MSVC        : ${MSVC_VERSION}  (${MSVC_INCLUDE})")

mark_as_advanced(WINSDK_VERSION WINSDK_INCLUDE_ROOT WINSDK_LIB_ROOT WINSDK_KITS_ROOT
                 MSVC_VERSION MSVC_INCLUDE MSVC_LIB_X64 MSVC_BASE_DIR)
