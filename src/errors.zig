pub const AppError = error{
    Usage,

    InvalidConcurrency,
    TimeUnavailable,
    InvalidZipArchive,
    PayloadNotFoundInZip,

    ManifestNotInitialized,
    InvalidMagic,
    UnsupportedPayloadVersion,
    IntegerOverflow,
    InvalidDstExtents,
    UnhandledOperationType,
    UnexpectedBytesWritten,
    ChecksumMismatch,
    ExtractFailed,
    DecodeFailed,
    DecompressedSizeMismatch,
    XzDecompressFailed,
    Bzip2DecompressFailed,
    ZstdDecompressFailed,
    IoFailure,
    OutOfMemory,
};

pub const Code = enum {
    usage,

    invalid_concurrency,
    time_unavailable,
    invalid_zip_archive,
    payload_not_found_in_zip,

    manifest_not_initialized,
    invalid_magic,
    unsupported_payload_version,
    integer_overflow,
    invalid_dst_extents,
    unhandled_operation_type,
    unexpected_bytes_written,
    checksum_mismatch,
    extract_failed,
    decode_failed,
    decompressed_size_mismatch,
    xz_decompress_failed,
    bzip2_decompress_failed,
    zstd_decompress_failed,
    io_failure,
    out_of_memory,
};

pub const Domain = enum {
    cli,
    input,
    payload,
    decode,
    compression,
    system,
};

pub const Detail = struct {
    code: Code,
    domain: Domain,
    stable_name: []const u8,
};

pub fn code(err: AppError) Code {
    return switch (err) {
        error.Usage => .usage,
        error.InvalidConcurrency => .invalid_concurrency,
        error.TimeUnavailable => .time_unavailable,
        error.InvalidZipArchive => .invalid_zip_archive,
        error.PayloadNotFoundInZip => .payload_not_found_in_zip,
        error.ManifestNotInitialized => .manifest_not_initialized,
        error.InvalidMagic => .invalid_magic,
        error.UnsupportedPayloadVersion => .unsupported_payload_version,
        error.IntegerOverflow => .integer_overflow,
        error.InvalidDstExtents => .invalid_dst_extents,
        error.UnhandledOperationType => .unhandled_operation_type,
        error.UnexpectedBytesWritten => .unexpected_bytes_written,
        error.ChecksumMismatch => .checksum_mismatch,
        error.ExtractFailed => .extract_failed,
        error.DecodeFailed => .decode_failed,
        error.DecompressedSizeMismatch => .decompressed_size_mismatch,
        error.XzDecompressFailed => .xz_decompress_failed,
        error.Bzip2DecompressFailed => .bzip2_decompress_failed,
        error.ZstdDecompressFailed => .zstd_decompress_failed,
        error.IoFailure => .io_failure,
        error.OutOfMemory => .out_of_memory,
    };
}

pub fn detail(err: AppError) Detail {
    return switch (err) {
        error.Usage => .{ .code = .usage, .domain = .cli, .stable_name = "usage" },
        error.InvalidConcurrency => .{ .code = .invalid_concurrency, .domain = .cli, .stable_name = "invalid_concurrency" },
        error.TimeUnavailable => .{ .code = .time_unavailable, .domain = .system, .stable_name = "time_unavailable" },
        error.InvalidZipArchive => .{ .code = .invalid_zip_archive, .domain = .input, .stable_name = "invalid_zip_archive" },
        error.PayloadNotFoundInZip => .{ .code = .payload_not_found_in_zip, .domain = .input, .stable_name = "payload_not_found_in_zip" },
        error.ManifestNotInitialized => .{ .code = .manifest_not_initialized, .domain = .payload, .stable_name = "manifest_not_initialized" },
        error.InvalidMagic => .{ .code = .invalid_magic, .domain = .payload, .stable_name = "invalid_magic" },
        error.UnsupportedPayloadVersion => .{ .code = .unsupported_payload_version, .domain = .payload, .stable_name = "unsupported_payload_version" },
        error.IntegerOverflow => .{ .code = .integer_overflow, .domain = .payload, .stable_name = "integer_overflow" },
        error.InvalidDstExtents => .{ .code = .invalid_dst_extents, .domain = .payload, .stable_name = "invalid_dst_extents" },
        error.UnhandledOperationType => .{ .code = .unhandled_operation_type, .domain = .payload, .stable_name = "unhandled_operation_type" },
        error.UnexpectedBytesWritten => .{ .code = .unexpected_bytes_written, .domain = .payload, .stable_name = "unexpected_bytes_written" },
        error.ChecksumMismatch => .{ .code = .checksum_mismatch, .domain = .payload, .stable_name = "checksum_mismatch" },
        error.ExtractFailed => .{ .code = .extract_failed, .domain = .payload, .stable_name = "extract_failed" },
        error.DecodeFailed => .{ .code = .decode_failed, .domain = .decode, .stable_name = "decode_failed" },
        error.DecompressedSizeMismatch => .{ .code = .decompressed_size_mismatch, .domain = .compression, .stable_name = "decompressed_size_mismatch" },
        error.XzDecompressFailed => .{ .code = .xz_decompress_failed, .domain = .compression, .stable_name = "xz_decompress_failed" },
        error.Bzip2DecompressFailed => .{ .code = .bzip2_decompress_failed, .domain = .compression, .stable_name = "bzip2_decompress_failed" },
        error.ZstdDecompressFailed => .{ .code = .zstd_decompress_failed, .domain = .compression, .stable_name = "zstd_decompress_failed" },
        error.IoFailure => .{ .code = .io_failure, .domain = .system, .stable_name = "io_failure" },
        error.OutOfMemory => .{ .code = .out_of_memory, .domain = .system, .stable_name = "out_of_memory" },
    };
}
