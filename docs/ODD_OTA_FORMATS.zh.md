# 怪异 OTA 格式 —— 厂商兼容性备忘

> 本文档汇总社区（XDA、GitHub Issues、厂商论坛）报告的非标准 Android OTA 格式，并记录 `zpayload-dumper` 目前能处理什么、不能处理什么以及原因。

---

## 背景

Google 在 Android Oreo 引入的 A/B（无缝）更新系统中，OTA 包内只有一个 `payload.bin` 文件。该格式由 ChromeOS 更新引擎定义，遵循严格的 header → manifest → signatures → data blob 布局。

然而，多家 OEM 偏离了这一标准——有的在 payload 内部引入了新的 `InstallOperation` 类型，有的在外层包装上做了手脚（加密 ZIP、替代归档格式）。本文档按项目范围分类整理这些偏离。

---

## 1. BBK 电子（vivo / OPPO / realme / OnePlus）

### 发生了什么变化

2024 年初起，BBK 旗下品牌的固件开始在 `payload.bin` 内部使用 **Zstandard（zstd）** 压缩数据 blob。这对应 proto 中新增的枚举值：

```protobuf
ZSTD = 14;
```

旧版 `payload-dumper-go` 和原版 Python `payload_dumper` 因不认识类型 `14`，要么崩溃、要么输出 0 字节的镜像文件。

### 社区参考

- payload-dumper-go PR [#51](https://github.com/ssut/payload-dumper-go/pull/51) —— "Add vivo payload support"（2024 年 10 月合并）
- payload-dumper-go issue [#56](https://github.com/ssut/payload-dumper-go/issues/56) —— OxygenOS 15 / Android 15 兼容性
- XDA 上关于 OnePlus 11/12 固件"输出 0 KB"或"格式不受支持"的报告

### 项目状态

| 方面 | 状态 |
|------|------|
| proto 中定义 `ZSTD = 14` | ✅ 已存在于 `proto/update_metadata.proto` |
| Zig 枚举中定义 `zstd = 14` | ✅ 已存在于 `src/ffi/upb.zig` |
| 解压器 | ✅ `decompressZstdToWriter` 在 `src/compress/root.zig` |
| 引擎分发 | ✅ 已在 `src/payload/engine.zig` 处理 |

**结论：** 完全支持。

---

## 2. OPPO / realme —— OZIP 加密

### 发生了什么变化

OPPO 和 realme 的 OTA 文件扩展名为 `.ozip`，实质是 **AES-ECB 加密的 ZIP 归档**，不是普通 ZIP。文件头以 `OPPOENCRYPT!` 开头，每类设备使用硬编码 AES 密钥；社区工具 `ozipdecrypt.py` 维护了一个密钥数据库。

这**不是** payload.bin 格式层面的偏差，而是比 payload.bin **更外层**的包装。必须先解密 OZIP 得到普通 ZIP，再从中提取 `payload.bin`。

### 社区参考

- XDA 教程："How to Extract Fastboot Images from .ozip File"
- B. Kerler 的 `ozipdecrypt.py`（MIT 许可证）

### 项目状态

| 方面 | 状态 |
|------|------|
| OZIP 解密 | ❌ 不在项目范围内 |
| 解密后的普通 payload.bin | ✅ 支持（与标准 payload 相同） |

**结论：** 不会直接处理 `.ozip` 文件，用户需先用外部工具解密。

---

## 3. 三星（Samsung）

### 发生了什么变化

三星**完全不使用** `payload.bin`。其固件以 **tar.md5** 归档分发（AP、BL、CP、CSC 等分区），通过 Odin 或 Heimdall 刷入。

这是完全不同的生态系统，不存在可供提取的 `payload.bin`。

### 项目状态

| 方面 | 状态 |
|------|------|
| tar.md5 解析 | ❌ 不在项目范围内 |

**结论：** 不适用。

---

## 4. 华为（及前 Honor）

### 发生了什么变化

华为使用自有的 **UPDATE.APP** 格式，与 ChromeOS 更新引擎无关，由华为自家的 `update_engine` 处理。

### 项目状态

| 方面 | 状态 |
|------|------|
| UPDATE.APP 解析 | ❌ 不在项目范围内 |

**结论：** 不适用。

---

## 5. 小米 / Redmi / POCO

### 发生了什么变化

小米以 **TGZ / TAR** 归档分发固件。解压后通常能得到一个普通 ZIP，其中的 `payload.bin` 本身是标准格式。

### 项目状态

| 方面 | 状态 |
|------|------|
| TGZ/TAR 解压 | ❌ 不在项目范围内（用 `tar` 或 `7z`） |
| payload.bin 提取 | ✅ 支持 |

**结论：** payload 本身是标准的，只是外层包装不同。

---

## 6. 摩托罗拉（Motorola）

### 发生了什么变化

部分 Motorola 固件使用 **sparsechunk** 文件代替 `payload.bin`。这是将稀疏 ext4 镜像切分成多块以便于刷写的格式。

### 项目状态

| 方面 | 状态 |
|------|------|
| sparsechunk 处理 | ❌ 不在项目范围内 |

**结论：** 不适用。

---

## 7. 索尼（Sony）

### 发生了什么变化

索尼传统上使用 **FTF**（Flash Tool Firmware）格式，由 Flashtool / NewFlasher 处理。现代索尼 A/B 分区设备可能使用标准 payload.bin，但传统分发路径仍是 FTF。

### 项目状态

| 方面 | 状态 |
|------|------|
| FTF 解析 | ❌ 不在项目范围内 |

**结论：** 不适用。

---

## 8. 增量 / 差分 OTA（Delta/Incremental）

### 发生了什么变化

增量 OTA 包含引用**设备当前分区**作为源的操作：

- `SOURCE_COPY = 4`
- `SOURCE_BSDIFF = 5`
- `BSDIFF = 3`
- `MOVE = 2`（已废弃）

应用这些操作需要原始分区镜像。仅读取 OTA 文件的提取工具，没有源镜像就无法重构最终镜像。

### 社区参考

- payload-dumper-go issue [#26](https://github.com/ssut/payload-dumper-go/issues/26)
- XDA 上"Diff suggests it's an incremental OTA zip, which isn't supported"的回复

### 项目状态

| 方面 | 状态 |
|------|------|
| 完整（非增量）OTA | ✅ 支持 |
| 增量 OTA | ❌ 不支持（设计上就不支持） |

**结论：** 这是设计上的取舍。独立提取工具没有源镜像，无法应用差分补丁。

---

## 9. proto 已定义但引擎尚未实现的操作类型

以下 `InstallOperation.Type` 值已经在 `proto/update_metadata.proto` 和 `src/ffi/upb.zig` 中定义，但引擎中**缺少解压/应用逻辑**：

| 类型 | 值 | 压缩/格式 | 状态 |
|------|-----|----------|------|
| `PUFFDIFF` | 9 | Puff diff | ❌ 未实现 |
| `BROTLI_BSDIFF` | 10 | Brotli + bsdiff | ❌ 未实现 |
| `ZUCCHINI` | 11 | Zucchini | ❌ 未实现 |
| `LZ4DIFF_BSDIFF` | 12 | LZ4 diff + bsdiff | ❌ 未实现 |
| `LZ4DIFF_PUFFDIFF` | 13 | LZ4 diff + puffdiff | ❌ 未实现 |

如果未来某家厂商（例如 Google 在 Pixel 上启用 `BROTLI_BSDIFF`）使用了这些类型，引擎将返回 `error.UnsupportedOperation`。

---

## 汇总矩阵

| 厂商 / 格式 | 外层包装 | payload.bin 层面的特殊之处 | 是否支持？ |
|-------------|---------|---------------------------|-----------|
| Google Pixel | 普通 ZIP | 标准格式 | ✅ |
| vivo | 普通 ZIP | ZSTD = 14 | ✅ |
| OnePlus | 普通 ZIP | ZSTD = 14 | ✅ |
| OPPO / realme | **OZIP 加密** | 解密后为标准格式 | ❌（外层问题） |
| 三星 | **tar.md5** | 不适用 | ❌ |
| 华为 | **UPDATE.APP** | 不适用 | ❌ |
| 小米 | **TGZ/TAR** | 通常为 standard | ✅（仅 payload） |
| 摩托罗拉 | **sparsechunk** | 不适用 | ❌ |
| 索尼 | **FTF** | 不适用 | ❌ |
| 增量 OTA | 普通 ZIP | SOURCE_COPY、BSDIFF 等 | ❌（设计上不支持） |

---

## 对项目的意义

1. **我们实际面对的最常见"怪异"情况**是 BBK 系采用 `ZSTD = 14`。这已经处理完毕。
2. **下一个可能的缺口**是 Google 或其他厂商启用 `BROTLI_BSDIFF = 10`。届时需要引入 Brotli 解压器（或链接 `brotli` 库）。
3. **其余格式**（OZIP、tar.md5、UPDATE.APP、sparsechunk、FTF）均不在 `payload.bin` 提取工具的职责范围内。应通过本文档明确说明，避免用户提交无效 bug 报告。
4. **增量 OTA** 应保持不支持；提取工具不是补丁应用工具。
