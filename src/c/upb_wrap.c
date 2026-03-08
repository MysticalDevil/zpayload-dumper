#include "upb_wrap.h"

#include <stdlib.h>

#include "update_metadata.upb.h"
#include "upb/mem/arena.h"

struct zp_ctx {
  upb_Arena* arena;
  chromeos_update_engine_DeltaArchiveManifest* manifest;
};

static const chromeos_update_engine_PartitionUpdate* zp_get_partition(const zp_ctx* ctx, size_t partition_index) {
  if (!ctx || !ctx->manifest) return NULL;
  size_t n = 0;
  const chromeos_update_engine_PartitionUpdate* const* partitions =
      chromeos_update_engine_DeltaArchiveManifest_partitions(ctx->manifest, &n);
  if (partition_index >= n || !partitions) return NULL;
  return partitions[partition_index];
}

static const chromeos_update_engine_InstallOperation* zp_get_operation(
    const zp_ctx* ctx, size_t partition_index, size_t operation_index) {
  const chromeos_update_engine_PartitionUpdate* partition = zp_get_partition(ctx, partition_index);
  if (!partition) return NULL;
  size_t n = 0;
  const chromeos_update_engine_InstallOperation* const* operations =
      chromeos_update_engine_PartitionUpdate_operations(partition, &n);
  if (operation_index >= n || !operations) return NULL;
  return operations[operation_index];
}

static const chromeos_update_engine_Extent* zp_get_dst_extent(
    const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t extent_index) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) return NULL;
  size_t n = 0;
  const chromeos_update_engine_Extent* const* extents =
      chromeos_update_engine_InstallOperation_dst_extents(op, &n);
  if (extent_index >= n || !extents) return NULL;
  return extents[extent_index];
}

zp_ctx* zp_ctx_new(const uint8_t* manifest, size_t manifest_len, const uint8_t* signature, size_t signature_len) {
  upb_Arena* arena = upb_Arena_New();
  if (!arena) return NULL;

  chromeos_update_engine_DeltaArchiveManifest* m =
      chromeos_update_engine_DeltaArchiveManifest_parse((const char*)manifest, manifest_len, arena);
  if (!m) {
    upb_Arena_Free(arena);
    return NULL;
  }

  chromeos_update_engine_Signatures* sig =
      chromeos_update_engine_Signatures_parse((const char*)signature, signature_len, arena);
  if (!sig) {
    upb_Arena_Free(arena);
    return NULL;
  }

  zp_ctx* ctx = (zp_ctx*)malloc(sizeof(zp_ctx));
  if (!ctx) {
    upb_Arena_Free(arena);
    return NULL;
  }

  ctx->arena = arena;
  ctx->manifest = m;
  return ctx;
}

void zp_ctx_free(zp_ctx* ctx) {
  if (!ctx) return;
  if (ctx->arena) upb_Arena_Free(ctx->arena);
  free(ctx);
}

size_t zp_partition_count(const zp_ctx* ctx) {
  if (!ctx || !ctx->manifest) return 0;
  size_t n = 0;
  (void)chromeos_update_engine_DeltaArchiveManifest_partitions(ctx->manifest, &n);
  return n;
}

const uint8_t* zp_partition_name(const zp_ctx* ctx, size_t partition_index, size_t* out_len) {
  const chromeos_update_engine_PartitionUpdate* partition = zp_get_partition(ctx, partition_index);
  if (!partition) {
    if (out_len) *out_len = 0;
    return NULL;
  }
  upb_StringView name = chromeos_update_engine_PartitionUpdate_partition_name(partition);
  if (out_len) *out_len = name.size;
  return (const uint8_t*)name.data;
}

uint64_t zp_partition_size(const zp_ctx* ctx, size_t partition_index) {
  const chromeos_update_engine_PartitionUpdate* partition = zp_get_partition(ctx, partition_index);
  if (!partition) return 0;
  const chromeos_update_engine_PartitionInfo* info =
      chromeos_update_engine_PartitionUpdate_new_partition_info(partition);
  if (!info) return 0;
  return chromeos_update_engine_PartitionInfo_size(info);
}

size_t zp_operation_count(const zp_ctx* ctx, size_t partition_index) {
  const chromeos_update_engine_PartitionUpdate* partition = zp_get_partition(ctx, partition_index);
  if (!partition) return 0;
  size_t n = 0;
  (void)chromeos_update_engine_PartitionUpdate_operations(partition, &n);
  return n;
}

int32_t zp_operation_type(const zp_ctx* ctx, size_t partition_index, size_t operation_index) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) return -1;
  return chromeos_update_engine_InstallOperation_type(op);
}

uint64_t zp_operation_data_offset(const zp_ctx* ctx, size_t partition_index, size_t operation_index) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) return 0;
  return chromeos_update_engine_InstallOperation_data_offset(op);
}

uint64_t zp_operation_data_length(const zp_ctx* ctx, size_t partition_index, size_t operation_index) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) return 0;
  return chromeos_update_engine_InstallOperation_data_length(op);
}

const uint8_t* zp_operation_data_sha256(
    const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t* out_len) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) {
    if (out_len) *out_len = 0;
    return NULL;
  }
  upb_StringView hash = chromeos_update_engine_InstallOperation_data_sha256_hash(op);
  if (out_len) *out_len = hash.size;
  return (const uint8_t*)hash.data;
}

size_t zp_dst_extent_count(const zp_ctx* ctx, size_t partition_index, size_t operation_index) {
  const chromeos_update_engine_InstallOperation* op = zp_get_operation(ctx, partition_index, operation_index);
  if (!op) return 0;
  size_t n = 0;
  (void)chromeos_update_engine_InstallOperation_dst_extents(op, &n);
  return n;
}

uint64_t zp_dst_extent_start_block(
    const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t extent_index) {
  const chromeos_update_engine_Extent* extent =
      zp_get_dst_extent(ctx, partition_index, operation_index, extent_index);
  if (!extent) return 0;
  return chromeos_update_engine_Extent_start_block(extent);
}

uint64_t zp_dst_extent_num_blocks(
    const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t extent_index) {
  const chromeos_update_engine_Extent* extent =
      zp_get_dst_extent(ctx, partition_index, operation_index, extent_index);
  if (!extent) return 0;
  return chromeos_update_engine_Extent_num_blocks(extent);
}
