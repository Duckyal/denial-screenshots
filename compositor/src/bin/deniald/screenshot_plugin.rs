use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

/// 截图编辑插件接口
/// 插件可以在截图保存前对像素数据进行修改
pub trait ScreenshotEditPlugin: Send + Sync {
    /// 截图捕获后立即执行（在 PNG 编码前）
    /// 返回 true 表示插件成功执行
    fn on_capture(&mut self, pixels: &mut Vec<u8>, width: u32, height: u32) -> bool;

    /// 截图保存前执行
    /// 返回 true 表示插件成功执行
    fn on_save(&mut self, path: &Path) -> bool;

    /// 截图完成时执行
    /// 返回 true 表示插件成功执行
    fn on_complete(&mut self, path: &Path, clipboard: &[u8]) -> bool;

    /// 获取插件元数据
    fn metadata(&self) -> PluginMetadata;
}

#[derive(Debug, Clone)]
pub struct PluginMetadata {
    pub name: &'static str,
    pub version: &'static str,
    pub description: &'static str,
    pub author: &'static str,
}

/// 默认插件实现
pub struct DefaultPlugin {
    metadata: PluginMetadata,
}

impl DefaultPlugin {
    pub fn new() -> Self {
        Self {
            metadata: PluginMetadata {
                name: "default",
                version: "1.0.0",
                description: "Default screenshot plugin",
                author: "denialwm",
            },
        }
    }
}

impl Default for DefaultPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl ScreenshotEditPlugin for DefaultPlugin {
    fn on_capture(&mut self, _pixels: &mut Vec<u8>, _width: u32, _height: u32) -> bool {
        true
    }

    fn on_save(&mut self, _path: &Path) -> bool {
        true
    }

    fn on_complete(&mut self, path: &Path, _clipboard: &[u8]) -> bool {
        println!("Screenshot completed: {}", path.display());
        true
    }

    fn metadata(&self) -> PluginMetadata {
        self.metadata.clone()
    }
}

/// 插件管理器
pub struct PluginManager {
    plugins: Vec<Arc<dyn ScreenshotEditPlugin>>,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugins: Vec::new(),
        }
    }

    pub fn load_plugin(&mut self, plugin: Arc<dyn ScreenshotEditPlugin>) {
        self.plugins.push(plugin);
    }

    pub fn run_capture(&mut self, pixels: &mut Vec<u8>, width: u32, height: u32) {
        for plugin in &mut self.plugins {
            if !plugin.on_capture(pixels, width, height) {
                eprintln!("Plugin {} failed", plugin.metadata().name);
            }
        }
    }

    pub fn run_save(&mut self, path: &Path) {
        for plugin in &mut self.plugins {
            if !plugin.on_save(path) {
                eprintln!("Plugin {} failed to save", plugin.metadata().name);
            }
        }
    }

    pub fn run_complete(&mut self, path: &Path, clipboard: &[u8]) {
        for plugin in &mut self.plugins {
            if !plugin.on_complete(path, clipboard) {
                eprintln!("Plugin {} failed on complete", plugin.metadata().name);
            }
        }
    }
}
