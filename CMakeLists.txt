cmake_minimum_required(VERSION 3.25)

# Make find_package(<Pkg>_ROOT) behave correctly
cmake_policy(SET CMP0144 NEW)

project(icicle-insights VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# -------------------------
# Glaze (FetchContent)
# -------------------------
include(FetchContent)

FetchContent_Declare(
    glaze
    GIT_REPOSITORY https://github.com/stephenberry/glaze.git
    GIT_TAG main
    GIT_SHALLOW TRUE
)

FetchContent_MakeAvailable(glaze)

# -------------------------
# Dependencies (Conan or system)
# -------------------------
find_package(OpenSSL REQUIRED)
# Conan-generated postgres targets expect the lowercase openssl::openssl alias.
# When Homebrew's OpenSSL is found (macOS), create it manually.
if(NOT TARGET openssl::openssl)
    add_library(openssl::openssl INTERFACE IMPORTED)
    target_link_libraries(openssl::openssl INTERFACE OpenSSL::SSL OpenSSL::Crypto)
endif()
find_package(asio REQUIRED)
find_package(spdlog REQUIRED)
find_package(libpqxx REQUIRED)

# -------------------------
# Sources
# -------------------------
file(GLOB core_SRC CONFIGURE_DEPENDS src/core/*.cpp)
file(GLOB git_SRC  CONFIGURE_DEPENDS src/github/*.cpp)

add_executable(${PROJECT_NAME}
    src/insights.cpp
    ${core_SRC}
    ${git_SRC}
)

# -------------------------
# Includes (ONLY your code)
# -------------------------
target_include_directories(${PROJECT_NAME}
    PRIVATE
        src
        include
)

# -------------------------
# Linking
# -------------------------
target_link_libraries(${PROJECT_NAME}
    PRIVATE
        asio::asio
        glaze::glaze
        libpqxx::pqxx
        spdlog::spdlog
        OpenSSL::SSL
        OpenSSL::Crypto
)


target_compile_definitions(${PROJECT_NAME}
    PRIVATE
        GLZ_ENABLE_SSL
)
