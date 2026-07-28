# 0004 · Clip 是一等返回值；Relative 无宿主内不变量

**Status**: Accepted（随 Metric / Relative transport 落地）

## 决策

1. **`Transport.result` 增加 `{:clip, covered, lost}`。** preutterance 被
   截、花腔/长曲线部分存活时，「活了多少、丢了多少」只有 channel 自己
   知道怎么判——内核必须原样上浮，不能由策略层内部消化。`covered` 是
   新区间（像）列表，`lost` 是旧坐标下无像的子区间列表。度量零覆盖
   （仅相切于边界点）不算存活。
2. **`Anchor.Relative` 的 offset 允许为负、允许越出宿主边界**；内核不
   设「clip 到宿主内」不变量。zongzi `on_rebase` 隐含了这条错误不变
   量，会把 preutterance 剪掉，正式废除。支撑集溢出边界的存活判定交
   给 warp：投影成 Metric 后走 `Warp.map_interval/2` 的 clip 语义。
3. **宿主 stretch 时 offset 不缩放。**「音素起点后 0–50ms」锚的是起点
   坐标，不是比例。

## 登记：属 Caller / 协议层、内核不实现的结论

讨论中确认，登记于此防止丢失：

- **Collision**：merge 使两个 patch 撞同一区间，是 check 阶段
  （Caller）的冲突类型；内核不持有 patch 的区间信息，不做检测，更不
  允许「后写覆盖」静默处理。
- **digest 必须覆盖协商产物**（如压缩后的实际 preutterance），不只是
  原始输入——否则音头静默错位。这是对引擎/生成器的协议要求。
- **Content patch 可作为 warp 生产者**：variant 改时长 → 产生 warp →
  影响同区间 frame 参数。依赖方向写死：Content → warp → Frame。
- **variant 存在性校验**（换音源后 variant 可能不存在）属 check 阶段
  的语义冲突，落在 zongzi 已区分对的那条线上：rebase = 结构校验，
  check = 语义校验。
