# SportWork

一个为 macOS 设计的极简专注节奏助手。

SportWork 用来帮助你在长时间工作时维持固定节奏：

- 专注一段时间
- 到点后切换到短暂活动
- 在专注过程中按设定频率做一次轻量“回神”

这个项目的目标不是做一个复杂的任务管理器，而是做一个低打扰、可长期后台运行、真正能每天打开就用的桌面小工具。

## 核心能力

- 菜单栏常驻显示当前阶段
- 主窗口统一管理所有设置和交互
- 专注 / 活动自动循环
- 支持自定义专注时长与活动时长
- 支持每 3 分钟一次的“回神”提醒
- 支持为两类提醒分别设置通知方式
- 支持为两类闪烁分别设置停止策略
- 支持开机启动

## 当前产品结构

SportWork 现在分成 2 个主要入口：

1. 菜单栏

- 默认只显示当前阶段，减少注意力干扰
- 可以选择是否显示倒计时
- 用来快速打开主窗口和退出应用

2. 主窗口

主窗口是主要操作面板，按产品逻辑拆成几块：

- 当前状态
  - 当前阶段
  - 当前倒计时
  - 菜单栏当前显示方式
- 快速操作
  - 暂停 / 继续
  - 立即切到活动
  - 重置循环
  - 隐藏窗口
  - 退出应用
- 显示与启动
  - 菜单栏是否显示倒计时
  - 是否开机自动启动
- 提醒策略
  - 阶段切换提醒方式
  - 阶段切换闪烁停止方式
  - 回神提醒方式
  - 回神闪烁停止方式
  - 是否开启每 3 分钟回神提醒
- 时长设置
  - 专注分钟数
  - 活动分钟数

## 提醒模型

这个项目里有两类提醒，它们是独立的：

1. 阶段切换提醒

指专注阶段和活动阶段切换时的提醒。

可配置：

- 提醒方式
  - 菜单栏闪一下
  - 系统通知
- 闪烁停止方式
  - 持续闪烁，点一下才停止
  - 闪三下后自动停止

2. 回神提醒

指专注阶段中每 3 分钟一次的轻提醒。

可配置：

- 是否开启
- 提醒方式
  - 菜单栏闪一下
  - 系统通知
- 闪烁停止方式
  - 持续闪烁，点一下才停止
  - 闪三下后自动停止

## 运行方式

SportWork 是一个原生 macOS App。

- 不在 Dock 常驻显示
- 以菜单栏应用的方式运行
- 打开后会显示主窗口

## 本地开发

### 构建

```bash
swift build -c release
```

### 打包

```bash
./build.sh
```

会生成：

- `build/SportWork.app`
- `build/SportWork.dmg`

### 安装并启动

```bash
open /Applications/SportWork.app
```

如果你还没有安装到 `/Applications`，先执行：

```bash
cp -R build/SportWork.app /Applications/SportWork.app
open /Applications/SportWork.app
```

## 一键脚本

### 1. 清理旧版本

会执行：

- 停掉 SportWork 进程
- 删除 `/Applications/SportWork.app`
- 删除本地构建产物
- 删除本地状态文件
- 删除开机启动注册

命令：

```bash
./scripts/clean_sportwork.sh
```

### 2. 一键重装并启动

会执行：

- 清理旧版本
- 重新打包
- 复制到 `/Applications`
- 自动启动

命令：

```bash
./scripts/reinstall_sportwork.sh
```

## 安装

### 方式一：使用 DMG

1. 运行 `./build.sh`
2. 打开 `build/SportWork.dmg`
3. 将 `SportWork.app` 拖入 `/Applications`
4. 从 `/Applications` 启动

### 方式二：直接复制 App

```bash
cp -R build/SportWork.app /Applications/SportWork.app
open /Applications/SportWork.app
```

## 卸载

先执行：

```bash
./scripts/clean_sportwork.sh
```

如果你只想手动删除，也可以：

```bash
rm -rf /Applications/SportWork.app
rm -rf ~/Library/Application\ Support/SportWork
rm -f ~/Library/LaunchAgents/com.lucas.sportwork.launcher.plist
```

## 仓库结构

```text
.
├── AppInfo.plist
├── Assets/
├── Package.swift
├── Sources/
│   └── main.swift
├── build.sh
└── scripts/
    ├── clean_sportwork.sh
    ├── generate_icon.swift
    └── reinstall_sportwork.sh
```

## 适合继续优化的方向

- 更安静的视觉主题
- 更成熟的窗口布局系统
- 更精细的状态动画
- 设置持久化结构继续拆分
- 自动更新流程

## License

当前仓库尚未添加 License 文件。需要的话建议补一个明确的开源协议。
