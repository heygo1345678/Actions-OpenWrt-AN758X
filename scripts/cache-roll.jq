# =============================================================
# cache-roll.jq —— 从 gh cache list 的 JSON 里挑出「该删的旧代」
#
#   用法：
#     gh cache list -R <repo> --limit 200 --json id,key,createdAt > all.json
#     jq -r -f scripts/cache-roll.jq all.json
#
#   输出：每行 "<id>\t<key>"，就是要删的条目。
#
#   两类 key 的「代」不一样，分组时都要处理：
#
#     工具链缓存  ponwrt-<源>-<分支>-<soc>-<sha40>    去掉末尾 40 位提交号
#     dl 缓存     ponwrt-dl-<源>-<分支>-<YYYYWW>     去掉末尾 6 位周号
#
#   两次 sub 串起来而不是用正则择一（a|b），只为少一个出错面：
#   先剥 40 位十六进制，再剥 6 位数字，互不干扰
#   （剥完后 key 以 an7581 这类 SoC 名结尾，`-[0-9]{6}$` 不会再误伤）。
#
#   各自只保留 createdAt 最新的那一代，其余删掉。
#
#   ★ dl 为什么可以只留最新一代：它是「只增不减」的 ——
#     每次都是先按前缀恢复上一代、make download 补齐、再整份存回去，
#     所以新一代必定是上一代的超集。留旧的纯属白占 10GB 配额。
#     （前提：只在 make download 成功后才存，见 build-ponwrt.yml
#       的 Save dl cache 条件。）
#   ⚠ 本文件早先的版本刻意跳过 dl，导致周更 key 无限堆积 ——
#     一周一份、每份 2~5 GB，10GB 配额很快被刷满并挤掉工具链缓存。
# =============================================================
[ .[]
  | select(.key | startswith("ponwrt-"))
]
| group_by(.key | sub("-[0-9a-f]{40}$"; "") | sub("-[0-9]{6}$"; ""))
| map(sort_by(.createdAt) | .[:-1] | .[])
| .[] | [.id, .key] | @tsv
