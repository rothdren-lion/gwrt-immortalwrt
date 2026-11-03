# GWRT CI 预设 ↔ SoC 序列

规则：一个预设只允许一个 board（`make world` 会编所有 `CONFIG_TARGET_<board>=y`）。
校验脚本 `gwrt-check-target.sh`，表在它的 `PRESETS` 里。

| 预设 | 机型 | SoC 序列 | target | 设备 / profile | 配置来源 |
|---|---|---|---|---|---|
| `ss01` | 亚瑟 SS-01 | ipq6000 | `qualcommax/ipq60xx` | `DEVICE_jdcloud_re-ss-01` | `config.ci-ss01-261030-01` |
| `cs02-gwrt2` | 雅典娜 CS-02 | ipq6000 | `qualcommax/ipq60xx` | `DEVICE_jdcloud_re-cs-02-gwrt2` | `config.ci-cs02-gwrt2-261030-01` |
| `cs07` | 太乙 ER1 | ipq6000 | `qualcommax/ipq60xx` | `DEVICE_jdcloud_re-cs-07` | `config.ci-cs07-261030-01` |
| `cs06` | 赵云 BE6500 | ipq53xx | `qualcommbe/ipq53xx` | `DEVICE_jdcloud_re-cs-06` | `gwrt-mk-cs06-config.sh` |
| `cs08` | 太乙2 Plus | ipq53xx | `qualcommbe/ipq53xx` | `DEVICE_jdcloud_re-cs-08` | `gwrt-mk-cs08-config.sh` |
| `pzl8` | CMCC PZ-L8 | ipq5018 | `qualcommax/ipq50xx` | `DEVICE_cmcc_pz-l8` | `gwrt-mk-pzl8-config.sh` |
| `nezha` | 羿哪吒 CS-03 | ipq5018 | `qualcommax/ipq50xx` | `DEVICE_jdcloud_ax3000` | `gwrt-mk-nezha-config.sh` |
| `cp02` | 鲁班 RE-CP-02 | mt7621 | `ramips/mt7621` | `DEVICE_jdcloud_re-cp-02` | `gwrt-mk-cp02-config.sh` |
| `mt7981` | 7981 全家桶（10 设备） | mt7981 | `mediatek/filogic` | `*` | `gwrt-mk-xingloo-ax3000-config.sh` |
| `bdy-g98-direct` | G98 直刷 | rk3588 | `rockchip/armv8` | `DEVICE_bdy_g98` | `gwrt-mk-bdy-g98-config.sh BOOT=direct` |
| `bdy-g98-uefi` | G98 EFI | arm64-efi | `armsr/armv8` | `DEVICE_generic` | `gwrt-mk-bdy-g98-config.sh BOOT=uefi` |

`mt7981` 是唯一多设备预设，全在同一 board/subtarget 内。

```sh
sh gwrt-check-target.sh --list                            # 对照表
sh gwrt-check-target.sh --pre config.cs06-261026-01 cs06  # defconfig 前的种子
sh gwrt-check-target.sh .config cs06                      # defconfig 后（CI 用这个）
```

新增预设：生成器支持 `OUT=` → `PRESETS` 加一行 → workflow 的 `options` 和 `case` 各加一条。
