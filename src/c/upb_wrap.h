#ifndef ZPAYLOAD_UPB_WRAP_H
#define ZPAYLOAD_UPB_WRAP_H

#include <stddef.h>
#include <stdint.h>

typedef struct zp_ctx zp_ctx;

zp_ctx* zp_ctx_new(const uint8_t* manifest, size_t manifest_len, const uint8_t* signature, size_t signature_len);
void zp_ctx_free(zp_ctx* ctx);

size_t zp_partition_count(const zp_ctx* ctx);
const uint8_t* zp_partition_name(const zp_ctx* ctx, size_t partition_index, size_t* out_len);
uint64_t zp_partition_size(const zp_ctx* ctx, size_t partition_index);

size_t zp_operation_count(const zp_ctx* ctx, size_t partition_index);
int32_t zp_operation_type(const zp_ctx* ctx, size_t partition_index, size_t operation_index);
uint64_t zp_operation_data_offset(const zp_ctx* ctx, size_t partition_index, size_t operation_index);
uint64_t zp_operation_data_length(const zp_ctx* ctx, size_t partition_index, size_t operation_index);
const uint8_t* zp_operation_data_sha256(const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t* out_len);

size_t zp_dst_extent_count(const zp_ctx* ctx, size_t partition_index, size_t operation_index);
uint64_t zp_dst_extent_start_block(const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t extent_index);
uint64_t zp_dst_extent_num_blocks(const zp_ctx* ctx, size_t partition_index, size_t operation_index, size_t extent_index);

#endif
