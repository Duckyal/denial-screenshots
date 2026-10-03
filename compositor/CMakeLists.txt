cmake_minimum_required(VERSION 3.20)
project(denial_screenshot_ffi C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)

# 查找 Rust 工具
find_program(RUSTC rustc REQUIRED)
find_program(CARGO cargo REQUIRED)

# 构建目录
set(CMAKE_CURRENT_BINARY_DIR ${CMAKE_CURRENT_SOURCE_DIR}/build)
set(RUST_BUILD_DIR ${CMAKE_CURRENT_BINARY_DIR}/rust)

# 创建 Rust 构建目录
file(MAKE_DIRECTORY ${RUST_BUILD_DIR})

# 配置 Cargo 构建选项
set(ENV{RUSTFLAGS} "-C link-args=-Wl,--no-undefined -Wl,-z,now")

# 构建 Rust 库
add_custom_target(screenshot_ffi_lib ALL
    COMMAND ${CARGO} build --release --manifest-path=${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml
    WORKING_DIRECTORY ${RUST_BUILD_DIR}
    COMMENT "Building screenshot FFI library..."
    VERBATIM
)

# 设置库输出目录
set_target_properties(screenshot_ffi_lib PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
)

# 安装库
install(TARGETS screenshot_ffi_lib
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)

# 打印配置信息
message(STATUS "Rust compiler: ${RUSTC}")
message(STATUS "Cargo: ${CARGO}")
message(STATUS "Build directory: ${CMAKE_CURRENT_BINARY_DIR}")
