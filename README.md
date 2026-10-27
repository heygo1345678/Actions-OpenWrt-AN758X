# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

### diy-part1.sh —— 拉插件

**默认开启**：

| 开关 | 包 | 作用 |
|------|-----|------|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | Airoha SoC 状态页：NPU 卸载 / CPU 频率与超频 / Frame Engine / PPE 流表 |


| 包 | 作用 |
|-----|------|
| `luci-app-pon-status` | PON 光模块卡片：**温度 / 收光 / 发光 / 偏置电流 / 供电电压**，表格形式显示在概览页「系统」下一格 |
| `luci-app-natmode` | NAT 类型三选一：**全锥形 NAT1 / 受限型 NAT3 / 全对称型 NAT4**，菜单「网络 → NAT 类型」 |

其余默认关闭：`ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS`。

### luci-app-airoha-npu 的源与中文

**源仓库：`luanmuc/luci-app-airoha-npu`**（`rchen14b` 的 fork 改进版）：

| | rchen14b（原版）| luanmuc（本仓库选用）|
|---|---|---|
| 中文翻译 | ❌ po/ 只有 es + templates | ✅ 自带 `po/zh_Hans`，48 条全翻 |
| 仓库结构 | ⚠ 根目录 + 同名子目录各一份，feed 索引会中断 | ✅ 单层，正常 |
| luci.mk 路径 | 需 feeds 在固定位置 | ✅ 已修 |

## PON 光模块卡片（概览页系统下一格）

| 字段 | 来源字段 | 单位 |
|------|---------|------|
| 收光功率 | `rx_power_dbm` | dBm |
| 发光功率 | `tx_power_dbm` | dBm |
| 光模块温度 | `temperature_celsius` | °C |
| 偏置电流 | `tx_bias_ma` | mA |
| 供电电压 | `voltage_volts` | V |

### 开关：SHOW_PON_OPTICS

`tempinfo` 顶部有一个开关：

```sh
SHOW_PON_OPTICS=1    # 温度行附带 PON 光功率/电流/电压
SHOW_PON_OPTICS=0    # 只显示温度（CPU / WiFi / PON）
```

设为 `0` 时输出：`CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C`

本仓库**默认设为 `0`**，因为 `luci-app-pon-status` 卡片已用表格形式完整展示
收发光/电流/电压，两者会重复。若你想只要一行、不装 pon-status 卡片，改回 `1` 即可。

### 一点开销说明

概览页轮询间隔 3 秒，故 `tempinfo` 每 3 秒执行一次 `ponctl`。
`ponctl` 是 Rust 二进制、只读 sysfs，开销可忽略。
但注意 `luci-app-pon-status` 卡片同样每 3 秒调一次 `ponctl`，
两者叠加即约每 1.5 秒一次 `ponctl` 调用 —— 若在意，把 `SHOW_PON_OPTICS` 设 `0` 即可减半。

## 概览页「CPU 使用率（%）」行：总量 USR/SYS + 每核占用

ImmortalWrt 的 luci 默认只给一个总占用率（图左），改为下图右的样式：

```
CPU 使用率（%）   5%                                    ← 原来
CPU 使用率（%）   USR: 2% SYS: 1% · CPU0 3% CPU1 0% CPU2 1% CPU3 5%
```

开头 `USR` / `SYS` 是总量；`CPU0 … CPU3` 依次是**每个核心的总占用率**（USR+SYS 合并）。

### 原理（别改错文件）

这一行是「前端渲染 + rpcd 取值」两段拼起来的，实际只改了后者：

| 环节 | 文件 | 说明 |
|------|------|------|
| 文案 + 渲染 | `luci-mod-status/htdocs/.../view/status/include/10_system.js` | `_('CPU usage (%)'), cpuusage.cpuusage`，**不动** |
| 取值 | `luci-base/root/usr/share/rpcd/ucode/luci` 的 `getCPUUsage` | 原本是 `top -n1 \| awk '/^CPU/ {printf("%d%", 100 - $8)}'` |
| 授权 | `luci-mod-status/root/usr/share/rpcd/acl.d/luci-mod-status.json` | 已授权 `luci [ "getCPUUsage" ]`，**不动** |
| 数据源 | `files/sbin/cpuusage`（本仓库新增） | 两次 `/proc/stat` 采样求差值 |

前端拿到什么就原样塞进单元格，`luci.getCPUUsage` 在 LuCI 里也只有这一个调用方
（整个 immortalwrt/luci 里引用它的就上面三处），所以 `scripts/patch-luci-cpuusage.sh`
只把 `popen()` 里的**那一个命令字符串**换掉即可 —— 补丁前后只差 1 行：

```diff
-			const fd = popen('top -n1 | awk \'/^CPU/ {printf("%d%", 100 - $8)}\'');
+			const fd = popen('sh /sbin/cpuusage');
```

**为什么走 `sh /sbin/cpuusage`**：直接 exec 要求脚本带可执行位，而这个位在
Windows 打包 / 解压 / git checkout 链路上反复丢失（`luci-app-pon-status` 的
`ponstat-conn` 踩过同一个坑）。经 `/bin/sh` 读脚本内容就不依赖它了。

### 数值口径

两次 `/proc/stat` 采样（间隔 `SAMPLE_DELAY`，默认 0.2 s）取差值，**不是**开机至今的平均值：

| 显示 | 计算 |
|------|------|
| `USR` | `user + nice` |
| `SYS` | `system + irq + softirq` |
| `CPU<n>` | 该核的 `USR + SYS`，取 `/proc/stat` 的 `cpuN` 行 |

每核那个数是**先合并 USR+SYS 再取整**，不是把上面的 `USR` / `SYS` 两个整数相加 ——
各舍一次最多会多出 1%（实测 47.6% + 4.76% 会显示成 53%，真实值是 52%）。

`guest` / `guest_nice` 不计入 —— 内核已把它们算在 `user` / `nice` 里，再加一次会重复计数。
所以 `USR + SYS` 通常**小于**旧口径的 `100 - 空闲`（后者还含 iowait / nic 等），属正常。

### 失败时的行为

纯显示层的东西，任一环节不满足都只 `::warning::`，**不会让构建失败**：

| 情况 | 表现 |
|------|------|
| `files/sbin/cpuusage` 不在源码树 | 跳过补丁，这一行维持原来的单个占用率 |
| `feeds/` 下找不到 `*rpcd/ucode/luci`（换 fork / LuCI 版本不同） | 同上 |
| 有 `getCPUUsage` 但命令行变了（上游改实现） | 同上，并提示同步本脚本的 `OLD_FIX` / `NEW_FIX` |
| 脚本在设备上采样失败（`/proc/stat` 读不到等） | 脚本内部退回 `top -n1` 的旧口径，这一行永远有值 |

想临时关掉：把 `diy-part2.sh` 里调用 `scripts/patch-luci-cpuusage.sh` 的那段注释掉即可。

### 想换显示格式

只改 `files/sbin/cpuusage` 里 awk 的 `END` 段（`sprintf` 那两行）就行，例如去掉每核明细
只留总量：删掉拼 `cores` 的那一支即可。数值口径改 `SAMPLE_DELAY`（这行是纯变量，不必动 awk）。

## Release 行为

- 只有 `scope=firmware` 且编译成功才发 Release；`toolchain-only` 不发。
- 空固件目录会跳过，不会发空 Release。
- `fail_on_unmatched_files: false`：机型产物后缀不同（`*.itb` / `*.ubi` / `*.bin` / `*.manifest` 等），缺哪种都不会让这一步失败。
- 自动清理：每个机型的 Release 只保留最近 10 个（`delete_tag_pattern: ^<DEVICE_NAME>-`）。
- 关掉 Release 只留 Artifact：把 `upload_release` 选 `false`，或把 env 里 `UPLOAD_RELEASE` 默认值改成 `'false'`。

> 首次运行建议先 `scope=toolchain-only`（不产固件、不发 Release）把工具链缓存建起来，再跑 `firmware`。
> 现在缓存是滚动式的，**第一次 `firmware` 跑完也会自动存下工具链**，所以这一步只是给怕 6 小时超时的人用的。

## 构建缓存（移植自 VIKINGYFY/OpenWRT-CI）

一份缓存 = 三个目录，同一份内容存**两个地方**：

```
/workdir/openwrt/staging_dir/host*     host 工具 + hostpkg（go / python 在这）
/workdir/openwrt/staging_dir/tool*     交叉编译器 toolchain-<board>_<subtarget>
/workdir/openwrt/.ccache               编译对象缓存（USE_CCACHE=true 时才有内容）
```

| 通道 | 介质 | 特点 |
|---|---|---|
| ① 快通道 | `actions/cache` | GitHub 内网，秒级；但 **7 天无访问即回收** |
| ② 备份通道 | Release `cache-backup` 资产 | 走 `gh` 下载 ~1 GB，慢；**永不过期** |

恢复顺序 ① → ②：① 没命中才去 ② 取，两条都没取到才真编译。保存时两条都写
（② 失败只 `::warning::`，不影响构建结论）。

| | key |
|---|---|
| 写入用 | `ponwrt-<源站>-<分支>-<SoC>-<上游提交号>` |
| 恢复用 | `ponwrt-<源站>-<分支>-<SoC>-` **（前缀回退）** |

**为什么这样就不会「永远 miss」**：前缀只由源站 / 分支 / SoC 决定，配置、机型、
diy 脚本都不进 key。上游一提交就换一代，恢复时靠 `restore-keys` 回退到该前缀下
最近的一代 —— 于是「命中」不再取决于两个地方算的指纹能不能对上。

之前那套 `compile -> md5 指纹 -> 精确匹配` 已整体删除，原因是它只要指纹里有一项
两端算得不一致（或者上游改了一行 `tools/` 的 Makefile），就退化成每次全量重编
1~1.5 小时，而且没有任何自愈路径。

**Release 备份怎么维护**：每次保存时先把新资产传上去，再删同前缀的旧代 ——
顺序反过来的话，一旦上传失败就变成「旧的删了、新的没上去」，备份通道直接归零。
单文件超过 2 GiB 会被 GitHub 拒，超限时只跳过备份、快通道照常。两条通道都不要时
（比如想彻底重置）把 `release_backup` 选 `false`，并清空 Actions → Caches。

恢复之后脚本会做三件事（`scripts/pwrt-cache.sh prepare`），缺一件就等于白命中：

1. `touch` 所有**非 target** 的 stamp —— tar/zip 还原的是旧 mtime，源码树是刚 clone 的
2. 写 `tmp/.build` —— 标记「构建环境已初始化」，否则 make 重走 prereq 阶段
3. 目录本身也 touch —— 避免「目录比内容旧」

### dl 缓存（源码包）

单独一条，key 按**周**滚动：`ponwrt-dl-<源站>-<分支>-<YYYYWW>`，同样是前缀回退。

- 保存位置在**编译之前**（`make download` 跑完就存）—— 因为 350 分钟超时会把 job
  直接 cancel，放最后用 `always()` 也来不及跑，几个 G 的 dl 就白下了
- 只在 `make download` 真跑成功时存，避免一份只含工具链源码的残缺 dl 占掉本周的 key
- 轮换时 **dl 也参与**：按周号分组、只留最新一代。dl 是「只增不减」的，
  新一代必定是旧一代的超集，留旧的只会白占 10GB 配额、把工具链缓存挤出去

配套的四个工作流：

| 工作流 | 作用 |
|---|---|
| `build-ponwrt.yml` | ①→② 恢复 → 编译 → **成功后两处都存** → `cache-rollover` job 删掉同前缀的旧代 |
| `warm-cache.yml` | 每周一预热/保活；key 口径与主流程同源（都调 `scripts/pwrt-cache.sh`） |
| `cache-keepalive.yml` | 每 3 天真实恢复一次，避开 7 天未访问回收 |
| `cache-clean.yml` | 手动/定时清理：`rollover` 每个族只留最新一代（工具链按提交号、dl 按周号分组）、`backup` 清 Release 旧代、`all` 全删 |

`ignore_cache=true` 会跳过恢复强制重编（仍会存新一代）。

> 迁移提示：更早那版的 `toolchain-cache` / `staging-cache` 两个 Release 已经不再被任何流程使用，
> 可以在 Releases 页面手动删掉；现在统一用 `cache-backup`（`Remove old releases` 按机型名匹配，不会碰它）。

## 支持的机型

| SoC | profile |
|-----|---------|
| AN7581 | `fiberhome_hg5382a` `fiberhome_hg5585f-ct` `fiberhome_hg5585f-cu` `gemtek_xg2010g` `nokia_xg-040g-md-ubi` `nokia_xg-040g-tf-ubi` `unionman_ung00a` `znxt_zn504xg-d` `znxt_zn515xg-d` |
| AN7583 | `nokia_xg-040g-mf` `nokia_xg-040g-mf-ubi` |

机型名写错会在 `Validate configuration` 步骤直接报 `::error::` 并退出，不会静默地全机型编译。

## NPU 固件

NPU 是 Airoha SoC 里那颗 RISC-V 核，**不是** Linux 驱动 —— host 端驱动 `airoha_npu`
随内核编出，它按固定名字找两个固件镜像：

| 镜像 | 默认文件名 | 上限 | 加载去向 |
|---|---|---|---|
| rv32（text+rodata） | `airoha/en7581_npu_rv32.bin`（AN7583 为 `an7583_*`） | 2 MiB | `npu_binary` @0x84000000 |
| data（.data） | `airoha/en7581_npu_data.bin` | 64 KiB | NPU 本地 SRAM |

固件由 ponwrt 自带的 linux-firmware 包提供（`airoha-en7581-npu-firmware` /
`airoha-an7583-npu-firmware`），在 `configs/<机型>.config` 里写
`CONFIG_PACKAGE_airoha-en7581-npu-firmware=y` 即会装进 rootfs。

工作流**不介入**固件的生成与选择：不再有现编、变体推断、DEFAULT_PACKAGES 摘除
等环节。要换固件就改 config 里那一行，改完照常 `make defconfig` 生效。

### 刷完怎么验

```sh
dmesg | grep -i npu           # probe 时打 NPU fw version
ls -l /lib/firmware/airoha/   # 两个 bin 在位
```

- 缺文件或名字不匹配：`request_firmware_direct()` 返回 `-ENOENT`，驱动映射成
  `-EPROBE_DEFER`，NPU 一直不绑定（`deferred probe pending` 里能看到具体文件名）。
- 大小超限：直接 `-E2BIG`。
- LuCI「Airoha SoC 状态页」（`luci-app-airoha-npu`）可看 NPU 卸载 / PPE 流表是否正常。


## 首次使用建议

免费 runner 单次上限 6 小时，首次全量编译（工具链 + 内核 + 全包）大概率超时：

1. 先跑一次 `scope = toolchain-only`，把工具链缓存建起来；
2. 再跑一次 `scope = firmware` 出固件；
3. 若仍超时，把 `configs/*.config` 里不需要的 luci-app / 语言包删掉再提交。

---

## AN758X 加密加速可选包

### 三个开关怎么选

| 开关 | 默认 | 什么时候开 | 谁受益 |
|---|---|---|---|
| `OPT_CRYPTO_ARM64CE` | 0（建议改 1） | 几乎总是开 | IPSec、OpenVPN、TLS、dm-crypt |
| `OPT_CRYPTO_CHACHA` | 0（建议改 1） | 跑 Xray / sing-box / WireGuard | 出海类代理流量 |
| `OPT_CRYPTO_EIP93` | 0 | 只在跑大块 IPSec / 大文件 TLS | 反而是最不需要的那个 |

### 为什么这么分

**AN7581 和 AN7583 不一样**，这是整个事情的关键：

- AN7581（ZN504XG-D、XG-040G-MD 等）`/proc/cpuinfo` 里**没有 `aes`**，`/proc/crypto` 只有 `aes-generic`，单核 AES-128-GCM 约 32 MB/s。它只能走 NEON 位切片（`AES_ARM64_BS`）。
- AN7583（XG-040G-MF）**有 `aes pmull sha1 sha2`**，同样测试能到约 548 MB/s，可以走 Crypto Extensions（`AES_ARM64_CE`）。

脚本会自动读 `.config` 判断 SoC，分别写两套内核符号，不用你手动切。

**EIP93 是个陷阱。** AN7581 确实内置了 EIP93（`crypto@1e004000`），驱动也在主线 `inside-secure/eip93` 里。但在 W1700K2（AN7581）上实测：AES 要 512 字节以上才比软件快，而 MD5 / SHA1 / SHA2 在所有尺寸下都是软件更快（阈值 -1）。代理流量几乎全是大大小小的包，开了只会更慢。所以默认关。

**ChaCha 才是出海的正解。** Xray、sing-box 的 AEAD 优先用 ChaCha20-Poly1305，它不吃 AES 指令——你可以显式把 method 设成 `chacha20-ietf-poly1305`，比在 AN7581 上硬跑 AES 划算得多。

### 安装

1. 把 `01-diy-part2-crypto.sh` 放到 `scripts/` 下（或整体追加到 `diy-part2.sh` 末尾）。
   若放 `scripts/`，在 `diy-part2.sh` 末尾加一行：

   ```sh
   [ -f scripts/diy-part2-crypto.sh ] && . ./scripts/diy-part2-crypto.sh
   ```

2. 把 `02-workflow-inputs.yml` 里的 inputs 合并进你的 `.github/workflows/*.yml`。
   **只加 inputs 不够，必须同时加 `env:` 那段**，否则脚本读到的永远是 0。

3. 不想动 workflow 也能用：直接在 workflow 的 `env:` 里写死

   ```yaml
   env:
     OPT_CRYPTO_ARM64CE: '1'
     OPT_CRYPTO_CHACHA: '1'
     OPT_CRYPTO_EIP93: '0'
   ```

### 刷完后验证

```sh
# 1. 看指令集（AN7581 不会有 aes，AN7583 会有）
grep -ao 'aes\|pmull\|sha1\|sha2' /proc/cpuinfo | sort -u

# 2. 看内核注册了哪些实现
cat /proc/crypto | grep -E '^name|^driver|^priority'

# 3. 跑分对比
openssl speed -evp aes-128-gcm
openssl speed -evp chacha20-poly1305
```

开 `OPT_CRYPTO_EIP93` 后额外看一眼是否真的挂上了：

```sh
dmesg | grep -i eip93
lsmod | grep eip93
```

### 注意事项

- `CONFIG_CRYPTO_*` 是**内核编译符号**，必须写进 `target/linux/airoha/an7581/config-<kver>`。写进顶层 `.config` 会被 target config 覆盖，看起来配置成功了实际不生效——脚本里就是这么处理的。
- `kmod-crypto-hw-eip93` 的依赖是 `@(TARGET_ramips_mt7621||TARGET_airoha)`，airоha 全系可编。内核 ≥6.18 走主线 in-tree 驱动（`inside-secure/eip93`），<6.18 走 `mtk-eip93`，包会自动选，你不用管。
- Xray / sing-box 本身不在官方 feed，得先在 `feeds.conf.default` 加第三方源。用户态加密提速靠 ChaCha，不是靠 EIP93。
- NPU 只在三层路由模式生效，当纯 AP 桥接时整机吞吐会掉到 2000 Mbps 左右——这跟加密无关，但经常一起被误判。

