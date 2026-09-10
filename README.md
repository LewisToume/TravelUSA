# Learning Board MVP (Godot 4)

横屏手机优先的“大富翁式学习游戏”第一阶段原型。当前只实现：掷骰子、逐格平滑移动、闭环路线与 Camera2D 跟随。

## 运行

用 Godot 4 打开本目录中的 `project.godot`，运行主场景即可。设计分辨率为 1920×1080，Windows 调试窗口默认为 1280×720；UI 使用锚点并位于 CanvasLayer，可适配不同横屏比例。

## 文件结构

```text
travelUSA/
├─ project.godot
├─ scenes/
│  ├─ main.tscn          # 场景组装
│  ├─ board.tscn         # 棋盘配置
│  ├─ player.tscn        # 玩家与 Camera2D
│  └─ game_ui.tscn       # 固定屏幕 UI
├─ scripts/
│  ├─ game_manager.gd    # 骰子与回合流程
│  ├─ board.gd           # 闭环路径与格子绘制
│  ├─ player.gd          # 逐格 Tween 移动与跟随镜头
│  └─ game_ui.gd         # UI 显示和按钮事件
└─ tests/
   └─ acceptance_test.gd # 无界面自动验收
```

## 镜头边界与循环表现

- Camera2D 是玩家的子节点，开启 position smoothing，不缩放、不旋转。
- 镜头刻意不设置 limits：即使玩家位于棋盘最外圈，也保持在屏幕中心附近；棋盘背景在路线外额外延伸 1600px，避免看到空白区域。
- 默认路线为 30 格闭环，格距 320px，约 2976×1824px，大于 1920×1080 设计视口，画面一次只能看到附近部分路线。
- 从第 29 格继续前进时，下一个相邻目标就是第 0 格；这一步与普通格子完全一样使用平滑 Tween，不会瞬移。

## 自动验收

```powershell
godot --headless --path D:\travelUSA --script res://tests/acceptance_test.gd
```

验收覆盖：启动加载、30 格路线、棋盘尺寸、初始格、Camera2D、镜头无夹取、CanvasLayer UI、骰子范围、移动中禁用按钮、逐格移动、恢复按钮和末尾循环。
