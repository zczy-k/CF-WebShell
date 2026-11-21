// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 zczy-k

import 'dart:ffi';
import 'dart:io';

/// Windows 紧急退出路径，跳过 CRT 和 DLL 常规卸载。
///
/// 仅用于尚未加载用户数据的重复启动分支，或正常退出已尝试后的兜底。
/// 跳过卸载意味着插件收尾与子进程回收不由此方法保证。
void hardExit([int code = 0]) {
  if (!Platform.isWindows) {
    exit(code);
    return;
  }

  // DWORD is unsigned 32-bit; normalize before crossing the FFI boundary.
  final int exitCode = code & 0xffffffff;
  try {
    final Pointer<Void> self = _getCurrentProcess();
    if (self.address != 0 && _terminateProcess(self, exitCode) != 0) {
      // TerminateProcess succeeded: do not fall through to CRT exit(), which
      // can re-enter the loader-lock deadlock this path is intended to avoid.
      // The OS normally terminates this thread as part of the successful call.
      while (true) {
        sleep(const Duration(seconds: 1));
      }
    }
  } catch (_) {
    // Missing FFI symbols or an FFI failure: use Dart's exit fallback below.
  }
  // A null handle or a failed TerminateProcess call reaches this fallback.
  exit(exitCode);
}

// --------------------------------------------------------------- 原生签名
// typedef 必须放顶层（类体内不允许声明 typedef，CI 的 analyze 会报
// typedef_in_class）。

// HANDLE is pointer-sized; GetCurrentProcess returns the pseudo-handle -1.
typedef _GetCurrentProcessNative = Pointer<Void> Function();
typedef _GetCurrentProcessDart = Pointer<Void> Function();

// HANDLE is pointer-sized; Win32 BOOL is signed 32-bit and DWORD is unsigned 32-bit.
typedef _TerminateProcessNative = Int32 Function(
  Pointer<Void> handle,
  Uint32 code,
);
typedef _TerminateProcessDart = int Function(Pointer<Void> handle, int code);

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _GetCurrentProcessDart _getCurrentProcess =
    _kernel32.lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
  'GetCurrentProcess',
);

final _TerminateProcessDart _terminateProcess =
    _kernel32.lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
  'TerminateProcess',
);
