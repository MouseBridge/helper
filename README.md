# MouseBridge Helper

`mousebridge-helper` 是 MouseBridge 的 macOS 原生侧输入组件。

它负责：

- 用 `CGEventTap` 捕获本机键盘鼠标
- 上报热键、边缘切换、输入事件给 daemon
- 把远端输入注入到当前 macOS 会话

## 构建

```bash
cd helper
swift build
```

## 直接运行

```bash
./.build/debug/mousebridge-helper run --data-dir ~/.mousebridge
```

兼容旧形式：

```bash
./.build/debug/mousebridge-helper --data-dir ~/.mousebridge
```

## LaunchAgent 托管

推荐把 helper 装成 LaunchAgent，而不是长期依赖终端手工拉起。

安装：

```bash
./.build/debug/mousebridge-helper install-launch-agent --data-dir ~/.mousebridge
```

卸载：

```bash
./.build/debug/mousebridge-helper uninstall-launch-agent --data-dir ~/.mousebridge
```

查看将要写入的 plist：

```bash
./.build/debug/mousebridge-helper print-launch-agent --data-dir ~/.mousebridge
```

LaunchAgent 默认配置：

- `RunAtLoad = true`
- `KeepAlive = true`
- 会话类型限制为 `Aqua`
- 日志写到 `<data-dir>/logs/`

## 权限引导

检查是否已有 Accessibility 权限：

```bash
./.build/debug/mousebridge-helper check-accessibility
```

打开系统设置到 Accessibility 页面：

```bash
./.build/debug/mousebridge-helper open-accessibility
```

## 调试

默认关闭高频输入日志。

如需排查输入环路或注入问题：

```bash
MB_HELPER_VERBOSE_INPUT=1 ./.build/debug/mousebridge-helper run --data-dir ~/.mousebridge
```

接收端连续 `mouse_move` 现在也会在 helper 内部做一次短窗口 coalescing，减少高频注入开销；打开 `MB_HELPER_VERBOSE_INPUT=1` 时会看到 `coalesced incoming mouse_move ...` 日志。

## 本地验证

仓库根目录仍保留了本机双端验证脚本：

```bash
./verify/local-two-node-macos.sh start
```

它适合开发验证，不代表最终产品运行方式。

如果已经有一对本地 daemon/helper 在运行，也可以在 `core` 里直接跑一段远端动作脚本：

```bash
cd ../core
./verify/local-session-smoke.sh http://127.0.0.1:39273 http://127.0.0.1:39272 "MouseBridge smoke"
```

它会尝试走真实 session 链路，把 move + click + text 注入到接收端 helper。
为了减少同机双 helper 噪声，脚本会在验证期间临时关闭两侧本机捕获，结束后自动恢复。
