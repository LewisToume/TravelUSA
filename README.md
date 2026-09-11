# TravelUSA Online MVP (Godot 4)

横屏手机优先的 2～6 人异步在线大富翁原型。Host 是权威端，负责骰子、位置、金币、活力、房产、奇遇、商店、卡牌、词书和答题结果；Client 只发送操作请求。玩家不再轮流等待，可同时行动。

## 地图与经济

- 经济系统仅使用金币；所有经济数值和 30 格类型配置集中在 `scripts/game_rules.gd`。
- 每名玩家初始金币均为 `1000`，初始活力均为 `20`。每次掷骰消耗 1 点活力，只有自己的状态为 `IDLE` 时才能再次掷骰。
- 建造费用 L1～L5：`50 / 100 / 200 / 400 / 800`。
- 过路费 L1～L5：`25 / 50 / 100 / 200 / 400`。每次进入敌产格立即由 Host 转账，并向付款者和房主显示不阻塞移动的 Toast。
- `5 / 12 / 19 / 26` 为奇遇格，随机获得一种持续 15 格或至次日的奇遇；地图另有 9 个均匀分布的答题格。
- `9 / 22` 为转盘格。Host 先抽取结果，仅落入者显示六扇区转盘；其他玩家收到结果 Toast 且操作不受影响。
- `15 / 28` 为商店格，只向落入者显示商店。8 种卡牌价格与效果集中在 `game_rules.gd`，测试版开局每种卡牌各 1 张。
- Host 可导入 CSV/TXT 词书，确认预览后作为整个房间唯一词书；每次答题为十题、每题 20 金币，题型比例为英译中 40%、中译英 40%、拼写 20%。
- 房屋按路径法线绘制在道路旁，L1～L5 使用逐级增高的造型，并支持 6 种房主颜色。
- 每名玩家的落点事件独立处理，确认完成后自己的状态恢复为 `IDLE`；其他玩家不受阻塞。路过房产、奖励格或转盘格都不会触发事件。

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
│  ├─ main.tscn          # 双棋子、本地玩家镜头与场景组装
│  ├─ board.tscn         # 棋盘配置
│  ├─ player.tscn        # 可复用玩家棋子
│  └─ game_ui.tscn       # 固定屏幕 UI
├─ scripts/
│  ├─ game_manager.gd    # ENet、玩家独立动作状态、房产串行队列与 RPC
│  ├─ game_rules.gd      # 经济表、格子类型和升级资格规则
│  ├─ board.gd           # 闭环路径、格子类型、归属和等级绘制
│  ├─ player.gd          # 两名玩家的逐格 Tween 移动
│  ├─ game_ui.gd         # 启动、状态和地产决策 UI
│  ├─ wheel_ui.gd        # 转盘交互与结果状态
│  ├─ wheel_face.gd      # 六扇区绘制与减速动画
│  └─ wheel_pointer.gd   # 固定转盘指针
└─ tests/
   ├─ acceptance_test.gd # 权威规则自动验收
   ├─ economy_persistence_test.gd # 经济与存档回归
   ├─ encounter_wordbook_test.gd # 奇遇、词书与十连题验收
   └─ network_peer_test.gd # 双进程联机验收
```

## 镜头边界与循环表现

- Camera2D 在每个窗口跟随该窗口自己的玩家，开启 position smoothing，不缩放、不旋转。
- 镜头刻意不设置 limits：即使玩家位于棋盘最外圈，也保持在屏幕中心附近；棋盘背景在路线外额外延伸 1600px，避免看到空白区域。
- 默认路线为 30 格闭环，格距 320px，约 2976×1824px，大于 1920×1080 设计视口，画面一次只能看到附近部分路线。
- 从第 29 格继续前进时，下一个相邻目标就是第 0 格；这一步与普通格子完全一样使用平滑 Tween，不会瞬移。

## 自动验收

```powershell
godot --headless --path D:\travelUSA --script res://tests/acceptance_test.gd
```

验收覆盖：玩家独立活力与状态、同时移动、房产冲突串行化、奇遇、CSV/TXT 解析、房间统一词书、十连题、Host 转盘结果以及 Host/Client 最终快照一致性。
