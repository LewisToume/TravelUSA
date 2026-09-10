# TravelUSA Online MVP (Godot 4)

横屏手机优先的双人联机大富翁原型。Host 是权威端，负责回合、骰子、位置、金币和房产状态；Client 只发送操作请求。

## 运行

用 Godot 4 打开本目录中的 `project.godot`。允许编辑器运行多个实例，然后启动两次：

1. 窗口 A 点击 `Host Game`，成为 Player 1。
2. 窗口 B 保持地址 `127.0.0.1`，点击 `Join Game`，成为 Player 2。
3. 默认监听 UDP 端口 `7000`。

设计分辨率为 1920×1080，Windows 调试窗口默认为 1280×720；UI 使用锚点并位于 CanvasLayer。

## 文件结构

```text
travelUSA/
├─ project.godot
├─ scenes/
│  ├─ main.tscn          # 双棋子、回合镜头与场景组装
│  ├─ board.tscn         # 棋盘配置
│  ├─ player.tscn        # 可复用玩家棋子
│  └─ game_ui.tscn       # 固定屏幕 UI
├─ scripts/
│  ├─ game_manager.gd    # ENet、权威状态、回合与 RPC
│  ├─ game_rules.gd      # 价格和升级资格规则
│  ├─ board.gd           # 闭环路径、归属和等级绘制
│  ├─ player.gd          # 两名玩家的逐格 Tween 移动
│  └─ game_ui.gd         # 启动、状态和地产决策 UI
└─ tests/
   ├─ acceptance_test.gd # 权威规则自动验收
   └─ network_peer_test.gd # 双进程联机验收
```

## 镜头边界与循环表现

- Camera2D 跟随当前回合玩家，开启 position smoothing，不缩放、不旋转。
- 镜头刻意不设置 limits：即使玩家位于棋盘最外圈，也保持在屏幕中心附近；棋盘背景在路线外额外延伸 1600px，避免看到空白区域。
- 默认路线为 30 格闭环，格距 320px，约 2976×1824px，大于 1920×1080 设计视口，画面一次只能看到附近部分路线。
- 从第 29 格继续前进时，下一个相邻目标就是第 0 格；这一步与普通格子完全一样使用平滑 Tween，不会瞬移。

## 自动验收

```powershell
godot --headless --path D:\travelUSA --script res://tests/acceptance_test.gd
```

验收覆盖：两名玩家初始状态、回合权限、骰子、逐格闭环移动、买地、升级、抢占、80% 房主补偿、归属/等级/次数以及 Host/Client 最终快照一致性。
