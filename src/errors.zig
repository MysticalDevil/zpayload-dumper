pub const CliError = error{
    Usage,
    HelpDisplayed,
    InvalidConcurrency,
    TimeUnavailable,
    InvalidZipArchive,
    PayloadNotFoundInZip,
};

pub const PayloadError = error{
    ManifestNotInitialized,
    InvalidMagic,
    UnsupportedPayloadVersion,
    IntegerOverflow,
    InvalidDstExtents,
    UnhandledOperationType,
    UnexpectedBytesWritten,
    ChecksumMismatch,
    ExtractFailed,
};

pub const DecodeError = error{
    DecodeFailed,
};

pub const CompressError = error{
    DecompressedSizeMismatch,
    XzDecompressFailed,
    Bzip2DecompressFailed,
    ZstdDecompressFailed,
};

pub const SystemError = error{
    IoFailure,
    OutOfMemory,
};

pub const AppError = CliError || PayloadError || DecodeError || CompressError || SystemError;
