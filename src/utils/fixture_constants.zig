const std = @import("std");
const sep = std.fs.path.sep_str;

pub const sample_root = "tests/data/generated/smoke1";
pub const sample_payload_path = std.fmt.comptimePrint("{s}{s}payload.bin", .{ sample_root, sep });
pub const sample_extracted_dir = std.fmt.comptimePrint("{s}{s}extracted", .{ sample_root, sep });
pub const sample_ota_zip_path = std.fmt.comptimePrint("{s}{s}ota_update.zip", .{ sample_root, sep });
pub const sample_ota_tar_path = std.fmt.comptimePrint("{s}{s}ota_update.tar", .{ sample_root, sep });
pub const sample_ota_tgz_path = std.fmt.comptimePrint("{s}{s}ota_update.tar.gz", .{ sample_root, sep });

pub const sample_boot_img = std.fmt.comptimePrint("{s}{s}boot.img", .{ sample_extracted_dir, sep });
pub const sample_vbmeta_img = std.fmt.comptimePrint("{s}{s}vbmeta.img", .{ sample_extracted_dir, sep });
pub const sample_vendor_boot_img = std.fmt.comptimePrint("{s}{s}vendor_boot.img", .{ sample_extracted_dir, sep });
pub const sample_system_img = std.fmt.comptimePrint("{s}{s}system.img", .{ sample_extracted_dir, sep });
pub const sample_vendor_img = std.fmt.comptimePrint("{s}{s}vendor.img", .{ sample_extracted_dir, sep });
pub const sample_product_img = std.fmt.comptimePrint("{s}{s}product.img", .{ sample_extracted_dir, sep });
pub const sample_system_ext_img = std.fmt.comptimePrint("{s}{s}system_ext.img", .{ sample_extracted_dir, sep });

pub const selected_triplet = [_][]const u8{ "boot", "vbmeta", "vendor_boot" };
