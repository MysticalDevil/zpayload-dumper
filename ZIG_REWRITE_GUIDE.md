# Zig 重构完整指南（payload-dumper-go）

## 0. 命名约定（已确定）

本重写项目命名固定为：

- 仓库名：`zpayload-dumper`
- 可执行文件：`zpayload-dumper`
- 文档中提到的 Zig 重写版本统一称为 `zpayload-dumper`

## 1. 先明确当前 Go 项目的真实边界

当前实现是一个单二进制 CLI，核心路径如下：

- `main.go`
  - 解析 CLI 参数：`-l/-p/-o/-c`
  - 支持输入 `payload.bin` 或包含 `payload.bin` 的 `.zip`
  - 调用 `Payload.Open() -> Init() -> ExtractSelected()/ExtractAll()`
- `payload.go`
  - 解析 payload 头：`CrAU + version + manifest_len + metadata_signature_len`
  - 用 protobuf 解码 `DeltaArchiveManifest` 与 `Signatures`
  - 按分区并发提取，支持操作类型：
    - `REPLACE`
    - `REPLACE_XZ`
    - `REPLACE_BZ`
    - `ZSTD`
    - `ZERO`
  - 校验每个 operation 的 `data_sha256_hash`
- `reader.go`
  - 简单偏移读取器（非核心路径）
- 测试
  - 目前已覆盖单测/集成/分支/bench，覆盖率（排除 protobuf 生成包）约 `83%`

重构目标应是“行为等价”，不是“功能扩张”。

## 2. Zig 重构总体策略（建议）

建议采用 **渐进迁移**，而不是一次性重写：

1. 先做 Zig CLI + payload 头解析（不提取）
2. 接入 protobuf 解码（只读取 manifest 并列出分区）
3. 实现 `REPLACE`/`ZERO`
4. 再实现 `REPLACE_XZ`/`REPLACE_BZ`/`ZSTD`
5. 最后并发化 + 进度条 + 性能调优

这样每一步都能与 Go 版本对拍输出。

## 3. Zig 技术选型与“造轮子”评估

### 3.1 protobuf（关键）

这是最关键决策。因为 OTA 元数据就是 protobuf 编码，不可绕过。

推荐优先级：

1. `upb-zig`（通过 C runtime `upb`）  
2. `zig-protobuf`（纯 Zig 方案，工程化相对好）  
3. 自己手写 protobuf 解码（不推荐，成本和风险都高）

结论：可以复用 C，不必从零造 protobuf 轮子。

### 3.2 压缩库

- `xz`：复用 `liblzma`
- `zstd`：复用 `libzstd`
- `bz2`：复用 `libbz2`

用 Zig 调 C (`@cImport`) 即可，避免自行实现解压算法。

### 3.3 并发与 I/O

- 使用 Zig 标准库线程池或自建 worker queue
- 输出文件写入建议保留“每分区独立文件 + operation 顺序写入”语义

## 4. 代码结构映射（Go -> Zig）

建议 Zig 目录结构：

- `src/main.zig`：CLI 入口与参数解析
- `src/payload/header.zig`：payload 头读取与校验
- `src/payload/manifest.zig`：protobuf 解码封装
- `src/payload/extract.zig`：operation 执行与哈希校验
- `src/payload/decompress/*.zig`：xz/bz2/zstd 适配层
- `src/runtime/worker_pool.zig`：并发提取
- `src/runtime/progress.zig`：进度输出

语义对齐清单（必须保持）：

- 默认并发 `4`
- `-l` 仅列分区不提取
- 未传 `-o` 时输出目录格式：`extracted_YYYYMMDD_HHMMSS`
- `.zip` 输入自动提取临时 `payload.bin`
- `concurrency < 1` 报错
- 对 operation 做 SHA256 校验（空 hash 不校验）

## 5. build.zig 关键点

你需要在 `build.zig` 里明确：

- `exe.linkLibC()`
- `exe.linkSystemLibrary("lzma")`
- `exe.linkSystemLibrary("bz2")`
- `exe.linkSystemLibrary("zstd")`
- protobuf 代码生成步骤（`protoc` + zig plugin 或 upb 生成流程）

并提供以下命令目标：

- `zig build`
- `zig build test`
- `zig build bench`
- `zig build run -- <args>`

## 6. 测试迁移与验收标准（必须做）

以当前 Go 测试为基线，迁移成 Zig 同等用例：

- 集成测试：
  - `payload.bin` 正常提取
  - zip 输入 + list 模式
  - 选定分区提取
- 错误路径：
  - 非法 magic
  - 非法 metadata signature
  - 无效并发参数
  - 未支持 operation 报错
  - checksum mismatch
- 分支测试：
  - `REPLACE` / `REPLACE_XZ` / `REPLACE_BZ` / `ZSTD` / `ZERO`
- Benchmark：
  - `copyToExtents` 等价路径
  - 单 block `Extract(REPLACE/ZERO)`

验收门槛建议：

- 功能对拍：同一输入下输出镜像字节级一致
- 覆盖率：先达到 Go 当前水平的 80%+（排除生成代码）
- 性能：至少不慢于 Go 实现（同机同数据）

## 7. 迁移执行计划（建议 4 个里程碑）

1. **M1：解析与只读能力**
   - CLI + header + manifest 解码 + `-l`
2. **M2：最小可用提取**
   - `REPLACE` + `ZERO` + checksum
3. **M3：完整压缩支持与并发**
   - `REPLACE_XZ`/`REPLACE_BZ`/`ZSTD` + worker pool
4. **M4：对拍、性能、发布**
   - 对拍工具、bench、交叉编译、CI 接入

每个里程碑都应保留可发布状态，避免“大爆炸式重写”。

## 8. 风险与规避

- protobuf 生态风险：先做 PoC 验证 `update_metadata.proto` 可稳定生成/解码
- C 库链接风险：提前在 Linux/macOS 做最小链接样例
- 行为回归风险：保持双实现对拍直到 Zig 版本稳定

---

如果你要真正开工，建议下一步先做 `M1`：先把 Zig 版 `-l` 跑通并对拍 Go 输出。这样可以最快验证 protobuf 与构建链是否可控。
