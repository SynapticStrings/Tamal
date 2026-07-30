# 0003 · Warp 与 Metric 锚：一次有意的存活语义变更

**Status**: Accepted（内核已落地；G-INT-05 / G-AN-01 / G-PRE 族的
golden scenario 重写随 conformance vectors 进行）

## 决策

`Anchor.Metric`（f0、energy、音素边界、per-frame embedding 等密集/
区间参数）的存活条件不是「id 还在吗」，而是「存不存在一个从旧坐标到
新坐标的**单调偏映射**（warp）覆盖锚的支撑集」。变速、drag note、改
duration、split 对 frame 参数全部归一成同一个原语。

## 这是一次语义变更，不是重构

zongzi 的 GOLDEN_SCENARIOS 钉死了两条现状，warp 会翻转它们：

- **G-INT-05**：变速 + 秒基准 phoneme_timing intervention → 现在是
  **刻意 conflict**；warp 世界里存活。
- **G-AN-01 / G-PRE 族**：邻居全换而 focus 存活 → 现在结构性
  `adjacency_lost` 判死；tamale 里结构存活、推迟到 `Patch.resolve`
  判（更精确——邻居变了投影未必变——但冲突上浮时机从编辑时推迟到
  check 时）。

落地前需要产品层签字，并重写对应 golden scenarios。

## 三个不许粉饰的成本

1. **warp 的原料**：需要编辑前后的元素 span。所以 `Op.Retime` 必须
   携带 `old_span` / `new_span`（见 0001），tempo map 变化由 adapter
   层换算成 warp。内核不持 Note，也不持有 tempo——只消费 warp。
2. **payload warp 是有损的**：transport 只移动锚区间；payload 要在
   warp 下变换。控制点曲线在均匀平移/缩放下精确；split 引起的分段
   warp 需要切 payload——密集帧通用重采样（插值器选型是策略），
   Bezier 在切点分割是 adapter 专属逻辑。因此 channel adapter 会保留
   一个瘦身回调 `warp_payload(payload, warp)`，它是 zongzi
   `on_rebase/4` 的残骸，不会归零，但小一个量级。
3. **引擎升级仍是全体 conflict**：chunk digest 只对局部再生（改一个
   词）实现冲突局部化；引擎/模型版本升级改变一切投影，风暴依旧——
   这是显式接受的最坏情形，与 zongzi 一致。

## 已落地的代数

`compose/2`（偏映射复合，定义域取交）、`invert/1`、`map_interval/2`
（含 clip 语义）与 `from_segments/1`（纯坐标数据的分段装配，单调性
由内核校验）已在内核 `Tamale.Warp` 落地；`Anchor.Metric` transport 沿
日志折叠 Caller 提供的 warp。tempo map / 元素 span 表 → segments 的
换算属 adapter 层。

`from_segments/1` 产出偏映射（`default: :undefined`）；非 ripple 适配器
通常需要全映射——段外坐标恒等通过。`Warp.total/1` 将 warp 切换为全映射
模式（`default: :identity`），适配器在 `from_segments` 后调用即可：

    {:ok, warp} = Warp.from_segments(segs)
    warp = Warp.total(warp)

（坐标表示在 0007 收紧为精确有理数：插值与复合不积浮点尘埃，
conformance 向量可逐字节复现。）
