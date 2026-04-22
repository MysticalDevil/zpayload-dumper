const std = @import("std");

pub const sample_root = "tests/data/generated/smoke1";
pub const sample_payload_path = std.fmt.comptimePrint("{s}/payload.bin", .{sample_root});
pub const sample_extracted_dir = std.fmt.comptimePrint("{s}/extracted", .{sample_root});
pub const sample_ota_zip_path = std.fmt.comptimePrint("{s}/ota_update.zip", .{sample_root});
pub const sample_ota_tar_path = std.fmt.comptimePrint("{s}/ota_update.tar", .{sample_root});
pub const sample_ota_tgz_path = std.fmt.comptimePrint("{s}/ota_update.tar.gz", .{sample_root});

pub const sample_boot_img = std.fmt.comptimePrint("{s}/boot.img", .{sample_extracted_dir});
pub const sample_vbmeta_img = std.fmt.comptimePrint("{s}/vbmeta.img", .{sample_extracted_dir});
pub const sample_vendor_boot_img = std.fmt.comptimePrint("{s}/vendor_boot.img", .{sample_extracted_dir});
pub const sample_system_img = std.fmt.comptimePrint("{s}/system.img", .{sample_extracted_dir});
pub const sample_vendor_img = std.fmt.comptimePrint("{s}/vendor.img", .{sample_extracted_dir});
pub const sample_product_img = std.fmt.comptimePrint("{s}/product.img", .{sample_extracted_dir});
pub const sample_system_ext_img = std.fmt.comptimePrint("{s}/system_ext.img", .{sample_extracted_dir});

pub const selected_triplet = [_][]const u8{ "boot", "vbmeta", "vendor_boot" };
