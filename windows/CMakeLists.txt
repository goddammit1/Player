# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(player LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "player")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Soulseek bridge: .NET library (soulseek-wrapper/desktop) hosted inside
# player.exe. Published self-contained (its own CoreCLR) into soulseek/ next to
# the executable; republished only when the bridge sources change. Without the
# .NET SDK the build still succeeds - Soulseek is then unavailable in the app.
set(SOULSEEK_WRAPPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../soulseek-wrapper")
set(SOULSEEK_BRIDGE_OUT "${CMAKE_BINARY_DIR}/soulseek_bridge")
set(SOULSEEK_BRIDGE_STAMP "${CMAKE_BINARY_DIR}/soulseek_bridge.stamp")
find_program(DOTNET_EXECUTABLE dotnet)
# dotnet.exe is also present with only a runtime or an older SDK installed;
# the bridge targets net9.0, so require a .NET 9+ SDK.
set(SOULSEEK_HAVE_SDK FALSE)
if(DOTNET_EXECUTABLE)
  execute_process(COMMAND "${DOTNET_EXECUTABLE}" --list-sdks
    OUTPUT_VARIABLE DOTNET_SDKS ERROR_QUIET RESULT_VARIABLE DOTNET_SDKS_RESULT)
  if(DOTNET_SDKS_RESULT EQUAL 0)
    string(REPLACE "\n" ";" DOTNET_SDK_LINES "${DOTNET_SDKS}")
    foreach(DOTNET_SDK_LINE IN LISTS DOTNET_SDK_LINES)
      if(DOTNET_SDK_LINE MATCHES "^(9|[1-9][0-9])[.]")
        set(SOULSEEK_HAVE_SDK TRUE)
      endif()
    endforeach()
  endif()
endif()
if(SOULSEEK_HAVE_SDK)
  file(GLOB_RECURSE SOULSEEK_BRIDGE_DESKTOP_SOURCES CONFIGURE_DEPENDS
    "${SOULSEEK_WRAPPER_DIR}/desktop/*.cs"
    "${SOULSEEK_WRAPPER_DIR}/desktop/*.csproj")
  list(FILTER SOULSEEK_BRIDGE_DESKTOP_SOURCES EXCLUDE REGEX "/(bin|obj)/")
  set(SOULSEEK_BRIDGE_SOURCES
    "${SOULSEEK_WRAPPER_DIR}/SoulseekBridgeCore.cs"
    "${SOULSEEK_WRAPPER_DIR}/SoulseekDtos.cs"
    ${SOULSEEK_BRIDGE_DESKTOP_SOURCES})
  add_custom_command(
    OUTPUT "${SOULSEEK_BRIDGE_STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${SOULSEEK_BRIDGE_OUT}"
    COMMAND "${DOTNET_EXECUTABLE}" publish
      "${SOULSEEK_WRAPPER_DIR}/desktop/SoulseekDesktop.csproj"
      -c Release -o "${SOULSEEK_BRIDGE_OUT}" -p:DebugType=none --nologo
      -nodeReuse:false -p:UseSharedCompilation=false
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${SOULSEEK_WRAPPER_DIR}/desktop/third_party/Soulseek.NET/LICENSE"
      "${SOULSEEK_BRIDGE_OUT}/LICENSE.Soulseek.NET.txt"
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${SOULSEEK_WRAPPER_DIR}/desktop/third_party/Soulseek.NET/NOTICE"
      "${SOULSEEK_BRIDGE_OUT}/NOTICE.Soulseek.NET.txt"
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${SOULSEEK_WRAPPER_DIR}/THIRD_PARTY_NOTICES.md"
      "${SOULSEEK_BRIDGE_OUT}/THIRD_PARTY_NOTICES.md"
    COMMAND "${CMAKE_COMMAND}" -E touch "${SOULSEEK_BRIDGE_STAMP}"
    DEPENDS ${SOULSEEK_BRIDGE_SOURCES}
      "${SOULSEEK_WRAPPER_DIR}/THIRD_PARTY_NOTICES.md"
      "${SOULSEEK_WRAPPER_DIR}/desktop/third_party/Soulseek.NET/LICENSE"
      "${SOULSEEK_WRAPPER_DIR}/desktop/third_party/Soulseek.NET/NOTICE"
    COMMENT "Publishing Soulseek bridge (.NET)"
    VERBATIM)
  add_custom_target(soulseek_bridge ALL DEPENDS "${SOULSEEK_BRIDGE_STAMP}")
  add_dependencies(${BINARY_NAME} soulseek_bridge)
  # Unchanged files are skipped by install (up-to-date check), so a rebuild
  # does not recopy the ~76 MB runtime.
  install(DIRECTORY "${SOULSEEK_BRIDGE_OUT}/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/soulseek"
    COMPONENT Runtime)
else()
  message(WARNING "No .NET 9 SDK found: Soulseek bridge is not built, Soulseek will be unavailable")
  # Do not leave a bridge from an earlier build next to the new executable.
  install(CODE "file(REMOVE_RECURSE \"${CMAKE_INSTALL_PREFIX}/soulseek\")"
    COMPONENT Runtime)
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
