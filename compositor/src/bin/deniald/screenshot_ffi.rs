use std::ffi::{c_char, c_int, c_void};
use std::path::Path;
use std::ptr;
use std::sync::{Arc, Mutex};
use std::mem;

/// FFI 绑定到 Flutter UI
///
/// 这些函数由 Rust 调用，通知 Flutter UI 执行操作
///
/// 注意：这些函数目前是占位符，实际实现需要与 Flutter 通信

/// 通知 Flutter UI 显示截图工具
#[no_mangle]
pub extern "C" fn screenshot_tool_start() -> c_int {
    tracing::info!("FFI: Screenshot tool start requested");
    // TODO: 通知 Flutter UI 显示
    0
}

/// 通知 Flutter UI 取消截图
#[no_mangle]
pub extern "C" fn screenshot_tool_cancel() -> c_int {
    tracing::info!("FFI: Screenshot tool cancel requested");
    // TODO: 通知 Flutter UI 取消
    0
}

/// 通知 Flutter UI 保存截图
#[no_mangle]
pub extern "C" fn screenshot_tool_save() -> c_int {
    tracing::info!("FFI: Screenshot tool save requested");
    // TODO: 通知 Flutter UI 保存
    0
}

/// 通知 Flutter UI 复制截图到剪贴板
#[no_mangle]
pub extern "C" fn screenshot_tool_copy() -> c_int {
    tracing::info!("FFI: Screenshot tool copy requested");
    // TODO: 通知 Flutter UI 复制
    0
}

/// 通知 Flutter UI 切换工具
#[no_mangle]
pub extern "C" fn screenshot_tool_switch_tool(tool_type: c_int) -> c_int {
    tracing::info!("FFI: Screenshot tool switch to {}", tool_type);
    // TODO: 通知 Flutter UI 切换工具
    0
}

/// 通知 Flutter UI 切换颜色
#[no_mangle]
pub extern "C" fn screenshot_tool_switch_color(r: u8, g: u8, b: u8) -> c_int {
    tracing::info!("FFI: Screenshot tool switch color RGB({}, {}, {})", r, g, b);
    // TODO: 通知 Flutter UI 切换颜色
    0
}

/// 通知 Flutter UI 调整粗细
#[no_mangle]
pub extern "C" fn screenshot_tool_adjust_size(size: c_double) -> c_int {
    tracing::info!("FFI: Screenshot tool adjust size to {}", size);
    // TODO: 通知 Flutter UI 调整粗细
    0
}

/// 通知 Flutter UI 撤销
#[no_mangle]
pub extern "C" fn screenshot_tool_undo() -> c_int {
    tracing::info!("FFI: Screenshot tool undo requested");
    // TODO: 通知 Flutter UI 撤销
    0
}

/// 通知 Flutter UI 重做
#[no_mangle]
pub extern "C" fn screenshot_tool_redo() -> c_int {
    tracing::info!("FFI: Screenshot tool redo requested");
    // TODO: 通知 Flutter UI 重做
    0
}

/// 通知 Flutter UI 输入文字（用于文字工具）
#[no_mangle]
pub extern "C" fn screenshot_tool_input_text(text: *const c_char) -> c_int {
    let text = unsafe { CStr::from_ptr(text).to_str().unwrap_or("") };
    tracing::info!("FFI: Screenshot tool input text: {}", text);
    // TODO: 通知 Flutter UI 输入文字
    0
}

/// 通知 Flutter UI 完成选区
#[no_mangle]
pub extern "C" fn screenshot_tool_finish_selection(x: c_int, y: c_int, width: c_int, height: c_int) -> c_int {
    tracing::info!("FFI: Screenshot tool finish selection: ({}, {}, {}, {})", x, y, width, height);
    // TODO: 通知 Flutter UI 完成选区
    0
}

/// 通知 Flutter UI 更新选区
#[no_mangle]
pub extern "C" fn screenshot_tool_update_selection(x: c_int, y: c_int, width: c_int, height: c_int) -> c_int {
    tracing::info!("FFI: Screenshot tool update selection: ({}, {}, {}, {})", x, y, width, height);
    // TODO: 通知 Flutter UI 更新选区
    0
}

/// 通知 Flutter UI 显示文字输入对话框
#[no_mangle]
pub extern "C" fn screenshot_tool_show_text_dialog(x: c_int, y: c_int) -> c_int {
    tracing::info!("FFI: Screenshot tool show text dialog at ({}, {})", x, y);
    // TODO: 通知 Flutter UI 显示对话框
    0
}

/// 通知 Flutter UI 隐藏文字输入对话框
#[no_mangle]
pub extern "C" fn screenshot_tool_hide_text_dialog() -> c_int {
    tracing::info!("FFI: Screenshot tool hide text dialog");
    // TODO: 通知 Flutter UI 隐藏对话框
    0
}

/// 通知 Flutter UI 显示工具栏
#[no_mangle]
pub extern "C" fn screenshot_tool_show_toolbar() -> c_int {
    tracing::info!("FFI: Screenshot tool show toolbar");
    // TODO: 通知 Flutter UI 显示工具栏
    0
}

/// 通知 Flutter UI 隐藏工具栏
#[no_mangle]
pub extern "C" fn screenshot_tool_hide_toolbar() -> c_int {
    tracing::info!("FFI: Screenshot tool hide toolbar");
    // TODO: 通知 Flutter UI 隐藏工具栏
    0
}

/// 通知 Flutter UI 更新工具栏可见性
#[no_mangle]
pub extern "C" fn screenshot_tool_set_toolbar_visible(visible: c_int) -> c_int {
    tracing::info!("FFI: Screenshot tool set toolbar visible: {}", visible);
    // TODO: 通知 Flutter UI 更新工具栏可见性
    0
}

/// 导出的符号列表
#[no_mangle]
pub static mut SCREENSHOT_FFI_SYMBOLS: *const *const c_char = unsafe {
    const symbols: [&str; 17] = [
        "screenshot_tool_start",
        "screenshot_tool_cancel",
        "screenshot_tool_save",
        "screenshot_tool_copy",
        "screenshot_tool_switch_tool",
        "screenshot_tool_switch_color",
        "screenshot_tool_adjust_size",
        "screenshot_tool_undo",
        "screenshot_tool_redo",
        "screenshot_tool_input_text",
        "screenshot_tool_finish_selection",
        "screenshot_tool_update_selection",
        "screenshot_tool_show_text_dialog",
        "screenshot_tool_hide_text_dialog",
        "screenshot_tool_show_toolbar",
        "screenshot_tool_hide_toolbar",
        "screenshot_tool_set_toolbar_visible",
    ];
    symbols.as_ptr()
};

// FFI 辅助函数
fn str_to_cstr(s: &str) -> *mut c_char {
    let mut c_str = CString::new(s).unwrap();
    let ptr = c_str.as_mut_ptr();
    mem::forget(c_str);
    ptr
}

fn cstr_to_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe {
        let c_str = CStr::from_ptr(ptr);
        c_str.to_string_lossy().into_owned()
    }
}

// 导入必要的 crate
use std::ffi::CStr;
use std::ffi::CString;
use tracing::info;
