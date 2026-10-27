# =============================================================
# cache-roll.jq —— 从 gh cache list 的 JSON 里挑出「该删的旧代」
#
#   用法：
#     gh cache list -R <repo> --limit 200 --json id,key,createdAt > all.json
#     jq -r --argjson include_dl false -f scripts/cache-roll.jq all.json
#
#   输出：每行 "<id>\t<key>"，就是要删的条目。
#
#   口径：
#     前缀 = key 去掉末尾 40 位提交号
#           例 ponwrt-pbs05-ponwrt-master-an7581-<sha40>
#              → ponwrt-pbs05-ponwrt-master-an7581
#     每个前缀只保留 createdAt 最新的那一代，其余删掉。
#
#   dl 缓存默认跳过：它的 key 是 ponwrt-dl-<源>-<分支>-<年周>，
#   不带提交号，会被当成「一个前缀一组」而把上周那代删掉 ——
#   那是纯增量下载缓存，越老越有用，删了等于白白重下几个 G。
# =============================================================
[ .[]
  | select(.key | startswith("ponwrt-"))
  | select(
      if $include_dl
      then true
      else ((.key | startswith("ponwrt-dl-")) | not)
      end
    )
]
| group_by(.key | sub("-[0-9a-f]{40}$"; ""))
| map(sort_by(.createdAt) | .[:-1] | .[])
| .[] | [.id, .key] | @tsv
