# 构建指南

> 更新时间：2026-11-03。插件架构下的构建全部走 `denial-plugins` CLI；
> 旧的「装 Flutter SDK → cargo 编 FFI → build_output 拼装」流程已随
> Rust crate 的删除一并作废（见提交 `d7b168f`）。

## 前提条件

- Denial 桌面运行中（deniald + Plugin Manager / `denial-plugins` 可用）
- 构建用的 Flutter/Dart 由 build-kit 提供，**不需要系统装 Flutter**
- 国内网络建议镜像：`export PUB_HOSTED_URL=https://pub.flutter-io.cn`
  （`FLUTTER_STORAGE_BASE_URL` 同理按需）

## 标准流程（plan → build → activate）

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"   # 首次：把本地目录登记为插件源

PUB_HOSTED_URL=https://pub.flutter-io.cn denial-plugins plan
# 候选 id 落在 ~/.local/state/denial/plugins/last-plan.json
ID=$(python3 -c "import json;print(json.load(open('$HOME/.local/state/denial/plugins/last-plan.json'))['id'])")

denial-plugins build "$ID"
denial-plugins activate "$ID"
```

验证生效：

```sh
denialctl --json status | python3 -c "import sys,json;print(json.load(sys.stdin)['ui'].get('plugin_bundle'))"
# 应为 …/candidates/<ID>/bundle
denialctl ui status   # 轮询到 Operation: Idle 才算切换完成
```

## SDK 覆盖文件（pubspec_overrides.yaml）

本地 pub 解析依赖 build-kit 里的 runtime。`denial-plugins prepare` 之后
（build kit 变更）跑一次同步脚本刷新路径：

```sh
./tools/sync-overrides.sh
```

它从 `~/.local/state/denial/plugins/configuration.json` 读 runtime 路径写进
`plugins/denialscreenshot/pubspec_overrides.yaml`（该文件不进 git，模板见
`pubspec_overrides.yaml.example`）。

## 静态检查（每次提交前）

```sh
cd plugins/denialscreenshot
dart analyze --fatal-infos lib   # 或 "$DENIAL_PLUGIN_DART" analyze --fatal-infos lib
dart format lib
```

保持 `--fatal-infos` 零告警是仓库红线。

## 独立编辑器 app（可选，仅 UI 原型）

```sh
./run_standalone.sh              # 编译并启动 compositor/src/dart_shell/screenshot_tool
BUILD_ONLY=1 ./run_standalone.sh # 只构建 release bundle
```

它不参与插件构建、不触发系统截图，改动不会自动同步进插件——插件代码在
`plugins/denialscreenshot/lib/`，以那边为准。

## 常见坑

| 现象 | 原因与处理 |
|---|---|
| `activate` 报 "No initial frame arrived within 20 seconds" | **屏幕熄了**：DPMS 关闭时合成器没有新帧可等，激活必然超时并回落 packaged shell。先动鼠标/按键唤醒屏幕（`denialctl --json status` 看 `outputs…powered`），再重试 activate |
| activate 命令超时但实际在切换 | 超时 ≠ 失败：轮询 `denialctl ui status` 到 `Operation: Idle` 再判定；不要连续堆 activate 请求 |
| plan/build 报 kit 校验失败 | build-kit 副本被手工改过。别改 `~/.local/state/denial/plugins/build-kits/` 下的文件，重新 `denial-plugins prepare` |
| 构建后 `pubspec.lock` 出现镜像 URL 漂移 | `git checkout -- plugins/denialscreenshot/pubspec.lock` 还原，别把镜像域名提交进仓库 |
| 重启后插件"消失"（回落 packaged） | 重新 `denial-plugins activate <ID>` 即可，无需重新 build |
