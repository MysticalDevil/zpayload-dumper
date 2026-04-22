# Python 生成器

仓库在 [`scripts/`](../scripts/) 下提供了一个由 `uv` 管理的 Python 工程，
用于生成本地测试、CI 和回归验证所需的合成夹具。

## 环境准备

依赖：

- Python `3.13+`
- [`uv`](https://docs.astral.sh/uv/)
- `protoc`
- `zstd`

同步辅助环境：

```bash
uv sync --project scripts
```

查看可用入口：

```bash
uv run --project scripts payload-gen --help
```

推荐使用统一入口：

```bash
uv run --project scripts payload-gen sample --name smoke1
uv run --project scripts payload-gen delta --old old.img --new new.img --output /tmp/test_delta.bin
```

## 入口命令

### `payload-gen sample`

生成合成 `payload.bin`、模拟 OTA zip，以及对应的 golden 解包目录。

常见用法：

```bash
uv run --project scripts payload-gen sample --name smoke1
uv run --project scripts payload-gen sample --name bench128 --total-mb 128
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
uv run --project scripts payload-gen sample --name matrix --scenario all --total-mb 32
```

参数说明：

- `--out-root`：输出根目录，相对于仓库根目录。默认：`tests/data/generated`
- `--name`：样本名。若使用 `--scenario all`，实际目录名会扩展成 `<name>-<scenario>`
- `--seed`：固定随机种子，用于复现夹具
- `--total-mb`：合成分区总容量目标，用来控制样本规模
- `--scenario`：要生成的场景。默认：`valid`
- `--list-scenarios`：列出支持的场景后退出

支持的场景：

- `valid`：正常的 payload 和 OTA zip
- `invalid_magic`：破坏 payload 头部 magic
- `unsupported_version`：把 payload 版本从 `2` 改成 `3`
- `truncated_payload`：在 metadata/data 之后截断 payload 文件
- `checksum_mismatch`：破坏一个 operation blob 字节，但不更新 manifest 哈希
- `invalid_partition_name`：在 manifest 中写入不安全的分区名，例如 `../evil_boot`
- `missing_payload_in_zip`：OTA zip 是合法的，但里面没有 `payload.bin`
- `corrupt_zip_payload`：磁盘上的 `payload.bin` 仍然合法，但 `ota_update.zip` 内嵌的副本被破坏

输出结构：

```text
tests/data/generated/<name>/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  extracted/
    *.img
```

补充说明：

- `expected_result.txt` 主要用于 Zig 侧回归测试
- `scenario.txt` 会记录场景名、描述、随机种子和附加说明
- 该生成器既支持成功样本，也支持负例样本

### `payload-gen delta`

生成包含真实 `SOURCE_BSDIFF` 操作的合成增量 payload。

常见用法：

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output /tmp/test_delta.bin
```

生成完整夹具目录：

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output tests/data/generated/bsdiff-fixture/payload.bin \
  --bundle-dir tests/data/generated/bsdiff-fixture
```

参数说明：

- `--old`：`SOURCE_BSDIFF` 操作使用的源镜像
- `--new`：应用补丁后应得到的目标镜像
- `--partition-name`：manifest 中的分区名。默认：`test`
- `--output`、`-o`：输出 `payload.bin` 路径
- `--bundle-dir`：可选，输出完整夹具目录
- `--block-size`：对齐和 manifest extent 使用的块大小。默认：`4096`
- `--proto-dir`：`update_metadata.proto` 所在目录
- `--check-with`：可选的 `zpayload-dumper` 二进制路径，用于做一次 `-l` 快速校验

使用 `--bundle-dir` 时的输出结构：

```text
tests/data/generated/bsdiff-fixture/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  old/
    <partition>.img
  extracted/
    <partition>.img
```

支持能力：

- 使用 `bsdiff4` 生成真实 `SOURCE_BSDIFF` 操作
- 自动对旧镜像和新镜像做块对齐
- 生成的 manifest 会带上：
  - `data_sha256_hash`
  - `src_sha256_hash`
- 可直接生成端到端提取测试所需的完整夹具目录

## 这些生成器覆盖什么

当前 Python 工程主要服务于这些 Zig 侧测试类别：

- 合成 `payload.bin` 的正常提取
- OTA zip 输入处理
- 损坏或非法 payload 的错误分类
- 路径穿越和 manifest 校验回归
- 带真实 old/new 镜像对的 `SOURCE_BSDIFF` 提取

当前还不打算覆盖：

- 单个夹具中同时包含多分区、多种 delta operation 的复杂增量 payload
- payload signature 或已签名 metadata
- 超出当前 dumper 需要范围的 Android 生产 OTA 元数据

## 推荐工作流

生成一个正常样本并验证：

```bash
uv run --project scripts payload-gen sample --name smoke1
zig build check_e2e -- tests/data/generated/smoke1/payload.bin tests/data/generated/smoke1/extracted
```

生成一个负例样本并验证错误：

```bash
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
zig build run -- tests/data/generated/bad-magic/payload.bin
```

生成并提取一个真实 `SOURCE_BSDIFF` 夹具：

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output /tmp/bsdiff-fixture/payload.bin \
  --bundle-dir /tmp/bsdiff-fixture

zig build run -Dbsdiff -- /tmp/bsdiff-fixture/payload.bin \
  --old /tmp/bsdiff-fixture/old \
  -o /tmp/bsdiff-fixture/out
```
