# ❌ 隔壁构建启动失败诊断报告（串口实锤，2026-10-18）

> 诊断方：另一 pi 会话（SS-01 移植主线）
> 数据源：/dev/ttyACM0 串口全程抓取（手动断电重启，2969 行日志）
> 结论：**内核 panic 循环重启，肇事者 = nat46 内核模块加载崩溃**，不是 WiFi/交换机/主题。

## 一、致命问题（必须修）：nat46 模块加载即 panic

串口证据（20.08 秒处）：
```
[20.086632] Internal error: Oops: 0000000096000005 [#1] SMP
[20.192522] pc : nat46_ns_init+0x24/0xfc [nat46]
[20.199202] lr : ops_init+0x74/0x140
Call trace:
  nat46_ns_init+0x24/0xfc [nat46] (P)      ← 炸点
  ops_init+0x74/0x140
  register_pernet_operations / register_pernet_subsys
  init_module[nat46] ← kmodloader 自动加载触发
[20.350591] Kernel panic - not syncing: Oops: Fatal exception
→ 重启 → 再炸 → 无限循环
```

炸点源码（nat46-module.c:210，源码本身没毛病）：
```c
static int __net_init nat46_ns_init(struct net *net) {
    nsdata = net_generic(net, nat46_netid);   // 返回 NULL
    nsdata->proc_parent = proc_mkdir(...);   // ← NULL 解引用 → Oops
}
```

**为什么你的炸、别的不炸**：pernet 注册要求模块与内核的 `struct net`/net_generic 布局一致。
`net_generic()` 返回 NULL = 你的 kmod-nat46 是用**与当前内核 .config 不一致的旧内核构建状态**编出来的
（改过内核 config 后 kmod 没重编 = 陈旧模块产物）。同源码 adb2f72e 在主线 261011-09 镜像里
加载正常（`nat46: module (version adb2f72e...) loaded.`，19.6s，不 panic）。

### 修复步骤（按序执行）
```bash
# 1) 彻底清 nat46 + kmod 产物
rm -rf build_dir/target-*/nat46-* build_dir/target-*/kmod-nat46*
rm -rf bin/packages/*/kmod-nat46*
# 2) 确认内核已按当前 .config 编完（.config 变过就先重编内核）
# 3) 单独重编 nat46（验证 vermagic 一致）
make package/kernel/nat46/{clean,compile} V=s
# 4) 验证产物 vermagic 与内核一致:
strings build_dir/target-*/nat46-*/nat46/modules/nat46.ko | grep vermagic
# 应等于: 内核 .config 的 CONFIG_LOCALVERSION + 编译器版本串
# 5) 重新打包镜像后刷入
```

**验收标准**（串口必须出现，且 90 秒内走到 crond）：
```
nat46: module (version adb2f72e6fb81ee11b54513d384b68e3c3d93464) loaded.
crond[...]: crond (busybox ...) started
```

## 二、次要问题：board 脚本调用了不存在的函数

```
/bin/board_detect: /etc/board.d/04_defaults: line 35: ucidef_set_wireless_channel: not found
```
上游 uci-defaults 库**没有** `ucidef_set_wireless_channel` 这个函数（自己起的名没定义）。
修法二选一：
- 在 04_defaults 里直接用 uci：`uci set wireless.@wifi-device[0].channel='149'; uci commit wireless`
  （注意 board.d 阶段 wireless 配置可能还没生成，更稳的是放 uci-defaults 末期跑——
  参考主线树的 `etc/uci-defaults/38_gwrt-wifi-channel`，它在 wireless 配置生成后再设）
- 或在 04_defaults 文件头部自己定义 `ucidef_set_wireless_channel()` 函数体

## 三、无关项（不用查）

- `Cannot parse '/etc/fw_env.config'`：**所有** GWRT 版本（含老树主路由）都没有这个文件，
  非致命，与本次启动失败无关。后续可补 uboot-envtools 板文件（低优先级）。
- 板脚本报错后系统继续走到了 PPE 网口初始化 → 它不阻断启动。

## 四、时间线（供对照）

```
 4.47s init: - preinit -            正常
11.37s board_detect 04_defaults 报错  ← 问题二（非致命）
11.87s qca-ppe lan1: configuring     正常
20.08s Oops in nat46                  ← 问题一（致命）
20.35s Kernel panic                    → 循环重启
```
