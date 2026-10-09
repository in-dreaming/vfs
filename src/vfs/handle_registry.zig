const retained = @import("db_internal").handle_registry;
pub const HandleKind = enum(u8) { volume, file, patch, request };
const Registry = retained.Registry(HandleKind, 2);
pub const register = Registry.register;
pub const acquire = Registry.acquire;
pub const take = Registry.take;
pub const takeIdle = Registry.takeIdle;
pub const Lease = Registry.Lease;
