# payload-gen

一个用于生成合成 Android OTA `payload.bin` 测试样本的独立 Python 工具集。

适用场景：

- 测试 Android OTA payload 提取/转储工具
- 生成可复现的回归测试固件
- CI 流水线需要合法和非法的 payload 样本
- 为提取工具性能测试提供受控输入

该工具使用 [`uv`](https://docs.astral.sh/uv/) 管理，可以独立于任何具体的提取器实现使用。

## 环境准备

依赖：

- Python `3.13+`
- [`uv`](https://docs.astral.sh/uv/)
- `protoc`
- `zstd`

安装依赖：

```bash
uv sync
```

## 用法

### `payload-gen sample`

生成合成 `payload.bin`、模拟 OTA zip，以及对应的预期输出镜像。

```bash
uv run payload-gen sample --name smoke1 --out-root ./output
uv run payload-gen sample --name bench128 --total-mb 128 --out-root ./output
uv run payload-gen sample --name bad-magic --scenario invalid_magic --out-root ./output
```

参数说明：

- `--out-root`：输出目录。默认：`./generated`
- `--name`：样本名
- `--seed`：固定随机种子，用于复现
- `--total-mb`：合成分区总容量目标
- `--scenario`：样本场景。默认：`valid`
- `--list-scenarios`：列出支持的场景后退出

支持的场景：

- `valid`：正常的 payload 和 OTA zip
- `invalid_magic`：破坏 payload 头部 magic
- `unsupported_version`：把 payload 版本从 `2` 改成 `3`
- `truncated_payload`：在 metadata 之后截断 payload 文件
- `checksum_mismatch`：破坏 operation blob 字节，但不更新 manifest 哈希
- `invalid_partition_name`：写入不安全的分区名，例如 `../evil_boot`
- `missing_payload_in_zip`：OTA zip 中不包含 `payload.bin`
- `corrupt_zip_payload`：磁盘上的 `payload.bin` 合法，但 zip 内嵌副本被破坏

输出结构：

```text
<out-root>/<name>/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  extracted/
    *.img
```

### `payload-gen delta`

生成包含真实 `SOURCE_BSDIFF` 操作的增量 payload。

```bash
uv run payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output ./output/test_delta.bin
```

生成完整测试样本目录：

```bash
uv run payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output ./output/bsdiff-sample/payload.bin \
  --bundle-dir ./output/bsdiff-sample
```

参数说明：

- `--old`：`SOURCE_BSDIFF` 操作使用的源镜像
- `--new`：应用补丁后应得到的目标镜像
- `--partition-name`：manifest 中的分区名。默认：`test`
- `--output`、`-o`：输出 `payload.bin` 路径
- `--bundle-dir`：可选，输出完整测试样本目录
- `--block-size`：对齐块大小。默认：`4096`
- `--proto-dir`：`update_metadata.proto` 所在目录
- `--check-with`：可选的提取器二进制路径，用于做一次 `-l` 快速验证

完整样本目录结构：

```text
<bundle-dir>/
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

## TAR 输入

生成器默认输出 `.zip` 格式的 OTA 文件。如需测试 TAR 输入，可手动创建归档：

```bash
cd ./output/smoke1
tar czf ota_update.tar.gz payload.bin
```

## 集成示例

如果你正在开发一个 payload 提取器，可以使用生成的样本做端到端验证：

```bash
# 生成样本
uv run payload-gen sample --name smoke1 --out-root ./samples

# 用你的提取器验证
your-dumper -l ./samples/smoke1/payload.bin
your-dumper -o ./samples/smoke1_out ./samples/smoke1/payload.bin
```

## 覆盖范围

当前支持：

- 正常 `payload.bin` 提取样本
- OTA zip 输入
- 损坏 payload 的错误样本
- 路径穿越和 manifest 校验
- 带真实 old/new 镜像对的 `SOURCE_BSDIFF`

当前不支持：

- 单样本中多分区、混合 operation 的复杂增量 payload
- Payload 签名或已签名 metadata
- 超出常规提取器需要范围的生产级 Android OTA 元数据
