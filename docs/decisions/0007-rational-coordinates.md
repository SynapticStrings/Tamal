# 0007 · 有理数坐标：内核唯一的数是精确有理数

**Status**: Accepted（已实现：`Tamale.Coord`）

## 问题

内核对坐标做的不是比较，是**域算术**：`Warp.at/2` 的分段线性插值和
`Warp.compose/2` 的断点求交，加减乘除全用。坐标类型的选取曾被提为
「behaviour + implementation，内核不引入具体类型」，分析后否决：

- behaviour 的法则必须要求坐标**对有理数缩放封闭**（帧 3 乘 4/3 得
  4，乘 1.333… 不得整数）。整数实现要么舍入——不同实现给出不同
  transport 结果，conformance 向量无法钉死期望值；要么报错——合法
  编辑（变速 1.333x）直接失败。法则写「必须精确」，则所有合法实现
  都是小数或有理数——只有一种语义的 behaviour 是纯粹的间接层，
  正是 zongzi Engine behaviour 被砍的那种病。
- conformance 向量是旗舰交付物，`{space₀, script, anchors} →
  {transported_anchors}` 必须在 Rust/TS 里逐字节复现。坐标算术由
  实现自定义，复现就死了。
- Metric anchor 和 Warp 是内核自己的类型，内核为自己的类型选坐标
  表示，与它为 Space 选 int 作 id 同性质，不算「引入外部类型」；
  payload-agnostic 保的是 payload，不受影响。

## 决策

内核唯一的数是**精确有理数** `{num, den}`（`Tamale.Coord`），规范化
为 `den > 0` 且约分到底——规范表示使 `==` 就是精确相等。

- **整数在一切入口自动提升**为 `{n, 1}`；`{num, den}` 原样接受并
  规范化。
- **float 全内核拒收**：`Warp.from_segments/1` → `:invalid_segment`，
  `Retime` span → `:invalid_span`，Metric 端点 / Relative offset /
  `Anchor.project/3` → `{:error, {:invalid_coordinate, value}}`。
  与 canonical digest 同一哲学（0005）：秒→微秒、帧→帧号这类带
  声明分辨率的归一化是 channel 适配器的义务，舍入只发生在适配层
  最终消费点。
- **线上形式**（conformance 向量 / JSON interchange）：`den == 1`
  时是 JSON 整数，否则是 `"num/den"` 字符串。float 在线上没有
  表示。
- 内核零依赖维持不变：有理数算术（含 gcd 约分）约百行，不引
  Decimal。

## 备选与否决

- **float（原状）**：插值与复合积浮点尘埃，与 digest 规范拒 float
  的理由同源——同一种病不能在小路放进 transport。
- **Decimal**：ergonomics 更好，但其除法按 context 精度舍入，并非
  真正封闭；跨语言复现需要在 spec 里钉死 precision + rounding
  mode，且引入依赖。有理数在四则运算下真正封闭（构成域），spec
  一句话说清。
- **Coord behaviour + 多实现**：见上，法则只许一种语义，抽象是
  间接层而非选择点。真正的「多种映射」（tempo map / 元素 span 表
  → segments）在 adapter 层，那里的 Provider 才是 behaviour 的
  正确位置（README「Not yet」第 1 条）。

## 影响面

- 新增 `Tamale.Coord`；`Warp` 全部端点、`Anchor.Metric` 端点、
  `Anchor.Relative` offset、`Op.Retime` span 收紧为坐标类型。
- transport 输出一律规范化有理数（输入整数 → 输出 `{n, 1}`）。
- conformance 向量原浮点值改写为 `"p/q"`（如 `0.5` → `"1/2"`、
  `-0.08` → `"-2/25"`），新增 `fractional_rates_are_exact` 与
  `fractional_compose_is_exact` 场景钉死 1/3 与 1/2∘1/3=1/6 的
  精确性。
- `Warp.from_span/2` 保持直接返回结构体（字面量形式，非法输入
  raise `ArgumentError`）；`from_segments/1` 保持 error tuple
  （数据驱动形式）。
