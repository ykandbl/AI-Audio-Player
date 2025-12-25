# AI Audio Player

一款支持 AI 功能的 macOS 音频播放器，支持实时语音转文字、AI 润色、桌面歌词、内容总结和关系图谱生成。

![Platform](https://img.shields.io/badge/platform-macOS%2014.0+-lightgrey)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

## ✨ 功能特点

- 🎵 **音频播放** - 支持 m4a、mp3、wav、aac、flac 等常见格式
- 📝 **实时转写** - 使用 WhisperKit 进行本地语音识别，支持中文
- 🤖 **AI 润色** - 通过本地大模型校对文字、添加标点
- 🖥️ **桌面歌词** - 悬浮窗显示实时字幕，支持自定义样式
- 📊 **内容总结** - AI 自动生成音频内容摘要
- 🔗 **关系图谱** - 可视化展示内容中的人物/概念关系
- 💾 **断点续传** - 字幕自动保存，下次播放直接加载
- 🔍 **全局搜索** - 快速搜索播放列表中的音频文件
- 📦 **批量处理** - 批量初始化/转写多个音频文件
- ⚙️ **自定义提示词** - 可针对不同类型内容配置 AI 提示词模板

## 📥 下载安装

### 方式一：直接下载（推荐）

从 [Releases](https://github.com/ykandbl/AI-Audio-Player/releases) 页面下载最新版本的 DMG 安装包：

1. 下载 `AI_Audio_Player_x.x.x.dmg`
2. 双击打开 DMG 文件
3. 将 `AI Audio Player.app` 拖入 `Applications` 文件夹
4. 从启动台打开应用

### 方式二：源码编译

```bash
# 克隆仓库
git clone https://github.com/ykandbl/AI-Audio-Player.git
cd AI-Audio-Player

# 使用 Swift Package Manager 运行
swift run

# 或使用 Xcode 打开项目
open AIAudioPlayer.xcodeproj
```

## 🖥️ 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon (M1/M2/M3/M4) 或 Intel 芯片
- 至少 8GB 内存（推荐 16GB+）
- 约 3GB 磁盘空间（用于 Whisper 模型）

## 📦 依赖项

### 自动安装
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - 本地语音识别（首次运行自动下载模型）

### 可选（用于 AI 功能）
- [LM Studio](https://lmstudio.ai/) - 本地大模型运行环境
  - 推荐模型：`qwen3-8b` 或其他支持中文的模型
  - 需要启动本地服务器（默认端口 1234）

## 📖 使用指南

### 基本使用

1. 启动应用后，点击左上角文件夹图标添加音频文件夹
2. 选择音频文件开始播放
3. 首次播放会自动进行语音转写（需等待模型下载和处理）
4. 转写完成后字幕会自动保存，下次播放直接加载

### AI 功能配置

1. 下载并安装 [LM Studio](https://lmstudio.ai/)
2. 在 LM Studio 中下载一个中文模型（推荐 `qwen3-8b`）
3. 启动 LM Studio 的本地服务器（Local Server），端口保持默认 1234
4. 回到播放器，AI 润色、总结、关系图功能即可使用

### 桌面歌词

- 点击播放界面的「桌面歌词」按钮开启
- 支持调整字体大小、颜色、透明度
- 可拖动到屏幕任意位置

### 批量处理

- 点击「批量转写」按钮
- 选择要处理的音频文件
- 「批量初始化」：只转写前 60 秒，快速预处理
- 「完整转写」：转写整个音频

### 自定义 AI 提示词

在设置 → AI 提示词中，可以：
- 切换预设模板（历史播客、通用等）
- 创建自定义模板
- 编辑总结、关系图、润色三种提示词
- 使用 `{{TRANSCRIPT}}` 作为文字稿占位符

## 📁 数据存储

所有数据存储在 `~/Library/Application Support/HistoryPodcastPlayer/`：

```
├── Subtitles/       # 字幕文件 (.srt)
├── Summaries/       # 内容总结
├── Relations/       # 关系图数据
└── WhisperModels/   # Whisper 模型文件
```

## 🔧 常见问题

**Q: 首次运行很慢？**  
A: 首次运行需要下载 Whisper 模型（约 1-3GB），请耐心等待。

**Q: AI 功能不工作？**  
A: 确保 LM Studio 已启动且本地服务器运行在 1234 端口。

**Q: 如何更换 Whisper 模型？**  
A: 在设置中可以选择不同大小的模型（tiny/base/small/medium/large-v3）。

**Q: 如何删除错误的字幕重新生成？**  
A: 在「字幕管理」中找到对应文件，点击删除后重新播放即可。

## 🛠️ 技术栈

- SwiftUI - 用户界面
- WhisperKit - 语音识别
- AVFoundation - 音频播放
- Core ML - 机器学习推理

## 📄 开源协议

[MIT License](LICENSE)

## 🙏 致谢

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - 优秀的本地语音识别框架
- [LM Studio](https://lmstudio.ai/) - 便捷的本地大模型运行环境
