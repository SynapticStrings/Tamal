# 0002 · 身份约定是内核级的，不是策略

**Status**: Accepted（脚手架已落地）

## 决策

1. **Split 长子继承父 id**：`Op.Split` 的 `children` 必须是
   `[parent_id | new_ids]`，`Space` 校验拒绝其他形状。点锚在 split 后
   存活于长子；「锚覆盖整个元素」的语义属于 `Anchor.Metric` + warp。
2. **Merge 的 `into` 必须是 `hd(ids)`**，其余 id 死亡。
3. **id 永不复用**：`Space.seen` 记住所有出现过的 id，删过的 id 再
   insert 报 `{:id_reused, id}`。否则历史锚会复活到新元素上。
4. **refs 合取**：`Anchor.Ordinal` 丢失任一 ref 即死。析取式兜底
   （「重定位到最近活邻居」）是策略层的事。
5. **`adjacent?` 是 head 态谓词**：ids 永不复用、delete 不可逆，
   中途断裂又被恢复的邻接不留残渣，只看净效果。
6. **head 上查无此 ref = Caller 挂载错误**，报
   `{:error, {:unknown_ref, id}}`，不静默放行。同理，ref 晚于
   `at_version` 出生（fold 范围内见到它的 `Insert`，或产生它的
   `Split`）也是挂载错误，同一报错。

## 理由

zongzi 的 `split_note` 已经隐式遵守「长子继承 seq_id」
（`timeline.ex` 中 `before_note = %{before_note | seq_id: seq_id}`），
但只是实现细节；`merge_notes` 靠 `seq_map` 里残留的 note_id 相等来
辨认 merge 目标。把这些约定提升到内核层显式声明后：

- transport 对 Ordinal 永远确定性，`{:ambiguous, _}` 只留给策略层；
- 内核不再需要 `seq_map`（note_id 映射是 Caller 的侧表）；
- conformance vectors 可以不依赖任何领域知识描述这些语义。
