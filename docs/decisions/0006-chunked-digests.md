# 0006 · Chunked digest：conflict 局部化是策略层的组合，不是内核新原语

**Status**: Accepted（policy 层模式；内核代码零改动）

## 场景：风暴是真实存在的

调教工程是有流通性的：创作者发布工程（带 pitch / energy /
phoneme timing 干预），其他人换自己喜欢的歌姬来渲染。这条工作流
里有两种「conflict 风暴」：

1. **换歌姬那一刻**——引擎/模型变了，一切投影都变，所有 patch 全部
   conflict。这是 0003 第 3 条登记的**已接受最坏情形**：调教是为另
   一个声音做的，自动应用才是错误答案，全体 conflict 恰恰是正确
   行为。chunked digest 不解决、也不应该解决这种风暴。
2. **换完之后的局部编辑**——用户人工确认完一轮，改了一句词，引擎
   局部重生成。如果整轨投影只有一个 digest，这一句词会再次株连整
   轨：所有 patch 又全部 conflict。**这才是 chunked digest 要灭的
   风暴**。

## 决策

patch 的 `base_digest` 从单个 digest 换成 **`%{chunk_key => digest}`**
（policy 层组合，内核 `Patch` 的单 digest 原语不变）：

- **chunk 划分是 channel policy**：按元素 span（音符 / 音素）或固定
  坐标窗。粒度越细冲突越精确，簿记越贵；每条 channel 自己选。
- **patch 只记录支撑集覆盖的 chunk**。重生成后逐 chunk 判等：全等
  → apply；任一不等 → conflict，**冲突携带不相等的 chunk_key 列表
  上浮**。
- 效果一：改一句词 → 只有该区域 chunk 变 → 只有压在改动区域的
  patch conflict，其余照旧 apply。冲突局部化。
- 效果二：就算冲突，报告从「整轨失效」变成「这些区块失效」——人工
  逐个确认的工作量从整轨缩到几个区块，和 0005 的 sketch 建议
  （区块内发散度可视化）正好接上：chunk 负责粗定位，sketch 负责
  区块内解释。

## 为什么不进内核

内核的 `Patch.resolve` 只需要会判「一个 digest 等不等」。chunk 划分
需要知道「base 是什么形状的、什么粒度算一个区块」——这全是领域
知识，内核一条都不该持有。策略层用内核原语自己组合：

```elixir
# policy 层伪码：chunked resolve = 逐 chunk 调内核判定再汇总
patch.chunks                          # %{chunk_key => digest}
|> Enum.split_with(fn {key, d} -> Digest.digest(fresh_chunk(key)) == {:ok, d} end)
|> case do
  {_, []}      -> {:ok, payload}
  {_, missing} -> {:conflict, {:chunks_changed, Enum.map(missing, &elem(&1, 0))}}
end
```

## 登记

- **引擎/模型升级 = 全体 conflict 仍是接受的语义**（0003#3），
  chunking 只覆盖「局部重生成」。两种风暴别混为一谈。
- chunk_key 本身要是 canonical term 可表达的（字符串 / 整数），
  digest 走 canonical digest 规范。
- chunk 边界用坐标还是元素 id，与该 channel 的锚形状（Metric /
  Ordinal）保持一致，省一套换算。
