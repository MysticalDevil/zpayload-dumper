const errors = @import("../errors.zig");

const Error = errors.AppError;

pub fn userMessage(err: Error) []const u8 {
    return switch (err) {
        error.InvalidConcurrency => "invalid concurrency, expected value >= 1",
        error.InvalidZipArchive => "invalid zip archive or failed to read zip content",
        error.PayloadNotFoundInZip => "payload.bin not found in zip archive",
        error.InvalidMagic => "invalid payload magic, expected CrAU",
        error.UnsupportedPayloadVersion => "unsupported payload version (expected 2)",
        error.ManifestNotInitialized => "payload manifest is not initialized",
        error.DecodeFailed => "failed to decode protobuf manifest/signature",
        error.InvalidDstExtents => "invalid destination extents in operation",
        error.UnhandledOperationType => "unsupported payload operation type",
        error.DecompressedSizeMismatch => "decompressed size mismatch",
        error.XzDecompressFailed => "xz decompression failed",
        error.Bzip2DecompressFailed => "bzip2 decompression failed",
        error.ZstdDecompressFailed => "zstd decompression failed",
        error.UnexpectedBytesWritten => "unexpected bytes written during extraction",
        error.ChecksumMismatch => "operation checksum mismatch",
        error.ExtractFailed => "one or more partitions failed to extract",
        error.TimeUnavailable => "failed to read local time for default output directory",
        error.IntegerOverflow => "numeric overflow while parsing payload metadata",
        error.IoFailure => "i/o failure while reading or writing payload data",
        error.OutOfMemory => "out of memory",
        error.Usage => "invalid arguments",
        error.HelpDisplayed => "help displayed",
    };
}
