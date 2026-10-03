use std::collections::HashMap;

/// 快捷键键位
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShortcutKey {
    pub modifiers: Modifiers,
    pub key: KeyCode,
}

/// 修饰键
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Modifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub super_: bool,
}

impl Modifiers {
    pub const NONE: Self = Self { ctrl: false, alt: false, shift: false, super_: false };
    pub const CTRL: Self = Self { ctrl: true, alt: false, shift: false, super_: false };
    pub const ALT: Self = Self { ctrl: false, alt: true, shift: false, super_: false };
    pub const SHIFT: Self = Self { ctrl: false, alt: false, shift: true, super_: false };
    pub const SUPER: Self = Self { ctrl: false, alt: false, shift: false, super_: true };
    pub const CTRL_ALT: Self = Self { ctrl: true, alt: true, shift: false, super_: false };
}

/// 按键代码
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyCode {
    KeyA,
    KeyB,
    KeyC,
    KeyD,
    KeyE,
    KeyF,
    KeyG,
    KeyH,
    KeyI,
    KeyJ,
    KeyK,
    KeyL,
    KeyM,
    KeyN,
    KeyO,
    KeyP,
    KeyQ,
    KeyR,
    KeyS,
    KeyT,
    KeyU,
    KeyV,
    KeyW,
    KeyX,
    KeyY,
    KeyZ,
    Key0,
    Key1,
    Key2,
    Key3,
    Key4,
    Key5,
    Key6,
    Key7,
    Key8,
    Key9,
    KeyReturn,
    KeyEscape,
    KeyLeft,
    KeyRight,
    KeyUp,
    KeyDown,
    KeyLeftBracket,
    KeyRightBracket,
    KeySemicolon,
    KeyApostrophe,
    KeyComma,
    KeyPeriod,
    KeySlash,
    KeyBackslash,
    KeyMinus,
    KeyEqual,
}

impl KeyCode {
    pub fn from_raw(key: u32) -> Option<Self> {
        match key {
            0x01 => Some(KeyCode::KeyA),
            0x02 => Some(KeyCode::KeyB),
            0x03 => Some(KeyCode::KeyC),
            0x04 => Some(KeyCode::KeyD),
            0x05 => Some(KeyCode::KeyE),
            0x06 => Some(KeyCode::KeyF),
            0x07 => Some(KeyCode::KeyG),
            0x08 => Some(KeyCode::KeyH),
            0x09 => Some(KeyCode::KeyI),
            0x0A => Some(KeyCode::KeyJ),
            0x0B => Some(KeyCode::KeyK),
            0x0C => Some(KeyCode::KeyL),
            0x0D => Some(KeyCode::KeyM),
            0x0E => Some(KeyCode::KeyN),
            0x0F => Some(KeyCode::KeyO),
            0x10 => Some(KeyCode::KeyP),
            0x11 => Some(KeyCode::KeyQ),
            0x12 => Some(KeyCode::KeyR),
            0x13 => Some(KeyCode::KeyS),
            0x14 => Some(KeyCode::KeyT),
            0x15 => Some(KeyCode::KeyU),
            0x16 => Some(KeyCode::KeyV),
            0x17 => Some(KeyCode::KeyW),
            0x18 => Some(KeyCode::KeyX),
            0x19 => Some(KeyCode::KeyY),
            0x1A => Some(KeyCode::KeyZ),
            0x1E => Some(KeyCode::Key0),
            0x1F => Some(KeyCode::Key1),
            0x20 => Some(KeyCode::Key2),
            0x21 => Some(KeyCode::Key3),
            0x22 => Some(KeyCode::Key4),
            0x23 => Some(KeyCode::Key5),
            0x24 => Some(KeyCode::Key6),
            0x25 => Some(KeyCode::Key7),
            0x26 => Some(KeyCode::Key8),
            0x27 => Some(KeyCode::Key9),
            0x24 => Some(KeyCode::KeyReturn),
            0x09 => Some(KeyCode::KeyEscape),
            0xFF50 => Some(KeyCode::KeyLeft),
            0xFF51 => Some(KeyCode::KeyUp),
            0xFF52 => Some(KeyCode::KeyRight),
            0xFF54 => Some(KeyCode::KeyDown),
            0xDB => Some(KeyCode::KeyLeftBracket),
            0xDD => Some(KeyCode::KeyRightBracket),
            0xBA => Some(KeyCode::KeySemicolon),
            0xDE => Some(KeyCode::KeyApostrophe),
            0xBC => Some(KeyCode::KeyComma),
            0xBE => Some(KeyCode::KeyPeriod),
            0xBF => Some(KeyCode::KeySlash),
            0xDC => Some(KeyCode::KeyBackslash),
            0xBD => Some(KeyCode::KeyMinus),
            0xBB => Some(KeyCode::KeyEqual),
            _ => None,
        }
    }
}

/// 快捷键动作
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShortcutAction {
    StartScreenshot,
    CancelScreenshot,
    SaveScreenshot,
    CopyScreenshot,
    Undo,
    Redo,
    SwitchTool(ToolType),
    ChangeColor(Color),
    IncreaseStrokeWidth,
    DecreaseStrokeWidth,
}

/// 工具类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolType {
    Brush,
    Arrow,
    Rect,
    Circle,
    Text,
    Mosaic,
    Eraser,
}

/// 颜色
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Color {
    pub const RED: Self = Self { r: 255, g: 0, b: 0 };
    pub const GREEN: Self = Self { r: 0, g: 255, b: 0 };
    pub const BLUE: Self = Self { r: 0, g: 0, b: 255 };
    pub const YELLOW: Self = Self { r: 255, g: 255, b: 0 };
    pub const WHITE: Self = Self { r: 255, g: 255, b: 255 };
    pub const BLACK: Self = Self { r: 0, g: 0, b: 0 };
    pub const ORANGE: Self = Self { r: 255, g: 165, b: 0 };
    pub const PURPLE: Self = Self { r: 128, g: 0, b: 128 };
    pub const CYAN: Self = Self { r: 0, g: 255, b: 255 };
    pub const PINK: Self = Self { r: 255, g: 192, b: 203 };
}

/// 快捷键管理器
pub struct ShortcutManager {
    shortcuts: HashMap<ShortcutKey, ShortcutAction>,
}

impl ShortcutManager {
    pub fn new() -> Self {
        let mut shortcuts = HashMap::new();

        // 默认快捷键映射
        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL_ALT,
                key: KeyCode::KeyA,
            },
            ShortcutAction::StartScreenshot,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::SHIFT,
                key: KeyCode::KeyS,
            },
            ShortcutAction::SaveScreenshot,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyEscape,
            },
            ShortcutAction::CancelScreenshot,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyReturn,
            },
            ShortcutAction::SaveScreenshot,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL,
                key: KeyCode::KeyC,
            },
            ShortcutAction::CopyScreenshot,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL,
                key: KeyCode::KeyZ,
            },
            ShortcutAction::Undo,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL | Modifiers::SHIFT,
                key: KeyCode::KeyZ,
            },
            ShortcutAction::Redo,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyB,
            },
            ShortcutAction::SwitchTool(ToolType::Brush),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyA,
            },
            ShortcutAction::SwitchTool(ToolType::Arrow),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyR,
            },
            ShortcutAction::SwitchTool(ToolType::Rect),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyC,
            },
            ShortcutAction::SwitchTool(ToolType::Circle),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyT,
            },
            ShortcutAction::SwitchTool(ToolType::Text),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyM,
            },
            ShortcutAction::SwitchTool(ToolType::Mosaic),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::NONE,
                key: KeyCode::KeyE,
            },
            ShortcutAction::SwitchTool(ToolType::Eraser),
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL,
                key: KeyCode::KeyLeftBracket,
            },
            ShortcutAction::DecreaseStrokeWidth,
        );

        shortcuts.insert(
            ShortcutKey {
                modifiers: Modifiers::CTRL,
                key: KeyCode::KeyRightBracket,
            },
            ShortcutAction::IncreaseStrokeWidth,
        );

        Self { shortcuts }
    }

    pub fn handle_key_event(&self, key: u32, state: bool) -> Option<ShortcutAction> {
        if !state {
            return None;
        }

        let key_code = KeyCode::from_raw(key)?;
        let modifiers = Modifiers::NONE; // TODO: 从事件中获取实际修饰键状态

        self.shortcuts.get(&ShortcutKey { modifiers, key_code })
            .cloned()
    }

    pub fn get_shortcuts(&self) -> &HashMap<ShortcutKey, ShortcutAction> {
        &self.shortcuts
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shortcut_manager() {
        let manager = ShortcutManager::new();

        // 测试 Ctrl+Alt+A
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_A, true),
            Some(ShortcutAction::StartScreenshot)
        );

        // 测试 Escape
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_ESC, true),
            Some(ShortcutAction::CancelScreenshot)
        );

        // 测试 Enter
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_RETURN, true),
            Some(ShortcutAction::SaveScreenshot)
        );

        // 测试 B 键 - 画笔
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_B, true),
            Some(ShortcutAction::SwitchTool(ToolType::Brush))
        );

        // 测试 R 键 - 矩形
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_R, true),
            Some(ShortcutAction::SwitchTool(ToolType::Rect))
        );

        // 测试 Ctrl+Z - 撤销
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_Z, true),
            Some(ShortcutAction::Undo)
        );

        // 测试 Ctrl+Shift+Z - 重做
        assert_eq!(
            manager.handle_key_event(smithay::wayland::input::KEY_Z, true),
            None
        );

        // 测试未知的按键
        assert_eq!(
            manager.handle_key_event(0xFFFF, true),
            None
        );
    }

    #[test]
    fn test_key_code() {
        assert_eq!(
            KeyCode::from_raw(smithay::wayland::input::KEY_A),
            Some(KeyCode::KeyA)
        );
        assert_eq!(
            KeyCode::from_raw(smithay::wayland::input::KEY_RETURN),
            Some(KeyCode::KeyReturn)
        );
        assert_eq!(
            KeyCode::from_raw(smithay::wayland::input::KEY_ESCAPE),
            Some(KeyCode::KeyEscape)
        );
        assert_eq!(
            KeyCode::from_raw(0xFFFF),
            None
        );
    }
}
