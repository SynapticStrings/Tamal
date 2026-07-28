# 0001 · 编辑意图是一等公民

**Status**: Accepted（脚手架已落地）

## 决策

内核的一切写操作都是显式 `Tamale.Op`，落 `Space` 的同时记 append-only
op log。锚的 rebase = 沿 log 的 transport，**不做任何状态反推**。

## 理由（zongzi 的教训）

zongzi 的 `NoteTriplet` 靠「三元组 2/3 匹配 + 墓碑」从编辑后状态反推
编辑意图，由此产生 `match_threshold` / `lenient` / `ScoredHost` 打分等
一整套启发式，以及为启发式服务的 `referenced_seqs` + `gc` 引用计数
（新 strategy 漏报依赖就会被 gc 吃掉活墓碑——真实的 footgun）。

但 zongzi 的 `Timeline` 写 API 本来就是 op 形的
（`insert_note` / `split_note` / `merge_notes` / `delete_note`…）——
**意图在写边界就在场，只是没落账**。tamale 把账记上，启发式整类消失。

## 两个必须守住的边界

1. **timing 编辑必须走 `Op.Retime`。** zongzi 的 `drag_note` /
   `drag_duration` 绕过 Timeline 由 Caller 自行写回——那是 op log 的洞，
   而 timing 恰恰是 warp 的原料。带洞的 log 不如没有 log。
2. **`diff(old_state, new_state) -> [Op]` 只是降级适配器**（导入文件、
   reload、协作等只有前后两个状态的场合）。启发式只允许活在这一个
   函数里，不得渗入内核决策路径。

## 附带收益

- log 即墓碑，`Space.truncate/2`（截断早于最老活锚的版本）即 GC。
- 迟到的渲染结果比对 version 即可拒收（zongzi 的
  `checked_request.fingerprint` 只是文档承诺，这里变成机械检查）。
- 锚位置的 undo = 反向 transport。（space 状态的 undo **不**免费：
  Delete/Merge 是有损 op，需要逆 op 载荷，另议。）
