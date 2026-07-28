# 调用方设计规范（Caller Guide）

tamale 是库，不是框架。它持有四个内核概念——`Space`、`Op`、
`Anchor`/`Transport`、`Patch`——但**不实现编辑器**：序列真相、音符
本体、干预存储、窗口切分、引擎调度都在 Caller 侧。本文是 Caller
的编排契约，也是已有 Caller（如 equinox）的迁移手册。

内核的不变量先记住三条：

1. **编辑意图一等公民**：写操作以显式 `Op` 批次进入 `Space`，内核
   不从状态差里猜发生过什么。
2. **两阶段判死**：编辑时 transport 判结构死活，渲染时 resolve 判
   语义死活，两个阶段不合并、不互相代替。
3. **一切不确定流向冲突**，不流向静默。内核如此，Caller 的适配器
   也必须如此（见「冲突处理纪律」）。

## 1. Caller 需要自持的组件

| 组件 | 内容 | 对应 zongzi 概念 |
|---|---|---|
| `Space`（每条序列一个） | id 全序、version、op log | Timeline |
| 侧表 `elements_by_id` | id → 领域对象（Note 等） | `notes_by_seq` |
| `patches` | 用户干预列表（anchor + base_digest + payload） | `interventions` |
| warp provider | `(coord, log_entry) -> Warp.t()` | 无（新增义务） |
| digest/归一化适配器 | 领域 base → canonical term | Declaration.snapshot 的归一化部分 |
| 引擎契约 | check（轻）/ render（重），只消费切片 | 同 zongzi（文档角色，不变） |

内核**不持**任何领域字段：Note、tempo、曲线、窗口都不进 Space。
`Space.ids` 的顺序就是序列顺序；元素的内容属性（tick、歌词、音高）
只活在侧表里。

## 2. 编辑回路

每次用户编辑，Caller 做三件事：**构造 op 批次 → 应用到 Space →
同步侧表**，然后在批次结束时 transport 受影响的 patch。

### 2.1 编辑意图 → op 的构造契约

| 用户操作 | op 批次 | 约定 |
|---|---|---|
| 插入音符 | `[Insert(id, after_id)]` | `after_id` 由 Caller 按 tick 定位；`:head` 表示最前 |
| 删除音符 | `[Delete(id)]` | 引用它的 anchor 判死 |
| 切开音符 | `[Split(id, [id, new_id])]` | **长子继承父 id**（内核约定，不是策略）；点锚存活到长子 |
| 合并音符 | `[Merge([a, b], a)]` | `into` 必须是 `hd(ids)`；锚重映射到 `into` |
| 拖动音符（改位置） | `[Move(id, after_id), Retime(id, old, new)]` | **必须同批**（见下） |
| 改时长/变速 | `[Retime(id, old_span, new_span)]` | 结构不动，但为 warp 提供原料 |
| 改歌词等内容属性 | 无 op | 只写侧表；结构未变 |

**Retime 纪律**：凡是改了元素时间坐标的编辑，必须在同批次带上
`Retime`（drag note = Move + Retime 一批）。zongzi 的教训是 drag
绕过 Timeline 直接改 tick，log 上没有时间变化的痕迹，Metric 锚的
warp 就断了原料。带洞的 op log 不如没有 log。

### 2.2 批次语义

- 一个编辑动作一个批次（`Space.apply_batch/2`）：原子、version +1、
  追加一条 log 条目。
- 一个手势（如框选拖动多个音符）可以一个批次多个 op——原子性由
  内核保证，全成或全不成。
- id 永不复用：删除后的 id 保持死亡，重插报 `{:id_reused, id}`。
  新元素必须用新 id。

## 3. 锚的选择

挂载干预时按附着对象选形状：

| 干预附着于 | 锚形状 | 例 |
|---|---|---|
| 元素身份（歌词级 flag、G2P 修正） | `Ordinal`（refs 合取） | 「这条音素修正挂在 note 5 上」 |
| 元素间边界 | `Ordinal` + `adjacent?: true` | 「A｜B 边界处的过渡」 |
| 时间坐标区间（f0、energy、frame 参数） | `Metric`（coord + 区间） | 「1.2s–1.8s 的 pitch delta」 |
| 元素 + 偏移（preutterance、音素内位置） | `Relative`（ref + offset） | 「音素 3 起点前 80ms」 |

`at_version` 纪律：挂载时记当前 `space.version`，之后**不要手动改**；
transport 会把它推进到 head。晚了几个版本的 patch 靠
`log[at_version..head]` 前推——这正是迟到结果拒收的实现方式。

## 4. Transport：编辑时的结构判死

编辑批次结束后，Caller 对每个 patch 跑 transport（zongzi 的
`rebase_all` 对应物，但逐 anchor 进行，结果自行汇总）：

```elixir
case Transport.transport(patch.anchor, space) do
  {:ok, anchor2}      -> 存活，更新 anchor（含 at_version）
  {:clip, covered, lost} -> 部分存活（Metric 专有）：活了多少丢了多少
                            原样上浮，由 channel 判收不收（0004）
  {:ambiguous, cands} -> 一对多：内核约定不产生，策略层才有
  {:undefined, reason} -> 判死：{:deleted, id} / :adjacency_broken /
                          :outside_warp —— 上浮为冲突，不静默处理
end
```

- 结构判死只回答「参照物还在不在」，**不**判断内容变没变——那是
  resolve 的事（zongzi 分对的那条线，原样保留）。
- Metric 锚需要 warp provider：`(coord, log_entry) -> Warp.t()`。
  没列 warp 的条目按 identity 处理。tempo map 变化、元素 span 变化
  → warp 的换算在适配层（参考 metric 族向量的 G-INT-03/05 场景）。
- 坐标一律是 `Tamale.Coord` 精确有理数（0007）：整数直接可用，分数
  写 `{num, den}`；float 进不了内核（Metric 端点、Relative offset、
  Retime span、warp segments 都会被拒）。秒 → 微秒整数、帧 → 帧号
  的归一化在适配层完成，舍入只发生在最终消费点。
- 判死的 patch 不要删——以冲突形式交给用户决定（强制重挂或放弃）。

## 5. Patch.resolve：渲染时的语义判死

渲染（引擎 check 阶段）时，对结构存活的 patch 做语义判定：

```elixir
{:ok, patch} = Patch.new(normalized_base_slice, payload)   # 挂载时
case Patch.resolve(patch, normalized_fresh_slice) do       # check 时
  {:ok, payload}            -> 应用
  {:conflict, :base_changed} -> 语义冲突，上浮
  {:error, reason}          -> 适配器失职（base 里有 float/struct），
                               当 bug 报，不当冲突处理
end
```

Caller 的义务（适配器层，0005 + canonical digest 规范）：

- **归一化在 digest 之前**：float 必须经声明分辨率的归一化变成
  canonical term——Decimal 字符串（如 `Decimal.round(x, 4)` 后
  `to_string`）或帧号整数。原始 float 会被内核拒收。
- **digest 覆盖协商产物**（0004）：引擎实际采用的值（如压缩后的
  preutterance），不是请求值。否则音头静默错位。
- base 切片要**确定性可取**：对引擎的协议要求是「投影确定且可按
  切片取」，不是「引擎会算 digest」。
- 局部重生成导致的 conflict 风暴用 chunked digest 缓解（0006，
  policy 层组合）。

## 6. truncate：log 即 GC

`Space.truncate(space, oldest_live_version)` 丢弃不晚于该版本的
log 条目——引用计数 GC 的替代物。策略：**最老活 patch 的
`at_version`** 就是水位线。截断后，更老的 anchor transport 报
`:log_truncated`（显式错误，不是误判）。挂载新 patch 前先做一轮
transport 推进 `at_version`，可以让水位线始终尽量新。

## 7. 冲突处理纪律

- 内核只**上浮**，从不静默：transport 的 `undefined`/`clip`、
  resolve 的 `conflict` 都必须到达用户或显式策略。
- Caller 侧适配器（如 diff 降级适配器）猜不准时**朝显式死亡猜**
  （Delete+Insert），不朝乐观存活猜（0005 登记）。
- 相似度/模糊匹配只允许作为「给人的建议」（「发散 2%，强制应用
  吗？」），永远不接自动 apply 通道（0005）。
- 多 patch 撞同一区间（merge 后）是 check 阶段的 Caller 冲突类型，
  内核不检测，更不允许「后写覆盖」静默处理（0004 登记）。

## 8. 落地对照：以 equinox Track 为例

| equinox 现状（zongzi） | tamale 对应 |
|---|---|
| `Timeline.new(track.id)` | `Space.new()`（每轨一个 Space） |
| `Timeline.insert_note(_before)` | `apply_batch([Insert(id, after_id)])` |
| `Timeline.split_note`（before 保 seq） | `Split(id, [id, new])`——长子继承，约定一致 |
| `Timeline.merge_notes`（合到 seq_a） | `Merge([a, b], a)`——约定一致 |
| `Timeline.move_note` + tick 改写 | `[Move, Retime]` 同批 |
| `notes_by_seq` 同步写回 | 侧表 `elements_by_id` 同步写回（契约相同） |
| `TripletMatch.scrub_triplet` 派生锚 | 显式构造 Ordinal/Relative（意图已知，无需猜） |
| `Anchor.rebase_all` | 逐 patch `Transport.transport` 后汇总 |
| `Declaration.snapshot/resolve` | `Patch.new/resolve` + 归一化适配器 |
| `Declaration.on_rebase` 维护 range | 消亡（Relative 用时投影 / warp 传输） |
| Timeline.gc / referenced_seqs | `Space.truncate`（最老活 at_version） |
| 墓碑（merge tombstone） | 消亡——log 即墓碑，`ids` 里全是活的 |

## 9. 对引擎的协议要求（清单）

1. **对齐信息**：音素对齐表 / tempo map 必须可取——Metric 锚的
   warp 原料。
2. **确定性投影**：同一 base 输入产生同一投影（digest 才有意义）。
3. **切片可取**：投影能按坐标区间切片取用（digest 按切片算）。
4. **覆盖协商产物**：引擎上报 digest 基准值时用实际采用值，不用
   请求值（0004）。
5. **check / render 两档**：check 轻（只做 resolve + 可行性），
   render 重（真合成）；两者吃同一切片形状。

## 10. 自验清单

一个 Caller 实现齐了没有，对照内核不变量自查：

- [ ] 所有写操作都经 `Op` 批次进 Space，没有绕过的直改（尤其时间）
- [ ] 时间变化的编辑都带 Retime，log 无洞
- [ ] patch 的 `at_version` 只在挂载时写、由 transport 推进
- [ ] transport / resolve 的所有非 ok 结果都有去处（用户或显式策略）
- [ ] digest 输入全是 canonical term，归一化分辨率有声明
- [ ] truncate 水位线 = 最老活 patch 的 at_version
- [ ] 跑通 `test/conformance/` 全部向量（参考实现即测试）
