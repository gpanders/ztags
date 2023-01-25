const std = @import("std");
const w = std.os.windows;

const c = @cImport({
    @cInclude("windows.h");
});

pub const NULL = c.NULL;
pub const FILE_MAP_READ = c.FILE_MAP_READ;

pub extern "kernel32" fn CreateFileA(
    lpFileName: w.LPCSTR, // I tried to avoid this with usingnamespace std.os.windows but it didn't work so idk
    dwDesiredAccess: w.DWORD,
    dwShareMode: w.DWORD,
    lpSecurityAttributes: ?*w.SECURITY_ATTRIBUTES,
    dwCreationDisposition: w.DWORD,
    dwFlagsAndAttributes: w.DWORD,
    hTemplateFile: ?w.HANDLE,
) callconv(w.WINAPI) w.HANDLE;

pub extern "kernel32" fn CreateFileMappingA(
    hFile: w.HANDLE,
    lpFileMappingAttributes: ?*w.SECURITY_ATTRIBUTES,
    flProtect: w.DWORD,
    dwMaximumSizeHigh: w.DWORD,
    dwMaximumSizeLow: w.DWORD,
    lpName: w.LPCSTR,
) callconv(w.WINAPI) w.HANDLE;

pub extern "kernel32" fn GetFileAttributesA(
    lpFileName: w.LPCSTR,
) callconv(w.WINAPI) w.DWORD;

pub const MapViewOfFile = c.MapViewOfFile;
pub const UnmapViewOfFile = c.UnmapViewOfFile;