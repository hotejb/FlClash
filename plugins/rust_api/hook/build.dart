import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {
        'LIBCLANG_PATH': directory.path,
        ..._bindgenClangArgs(input, llvmRoot.path),
      };
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

// NDK 30's bionic headers reject a target triple without an API level, and
// bindgen hands libclang the bare Rust triple. native_toolchain_rust only sets
// the sysroot, and a variable passed here replaces its value, so repeat that.
Map<String, String> _bindgenClangArgs(BuildInput input, String llvmRoot) {
  final code = input.config.code;
  final (
    rustTriple,
    ndkTriple,
    sysrootTriple,
  ) = switch (code.targetArchitecture) {
    Architecture.arm => (
      'armv7-linux-androideabi',
      'armv7a-linux-androideabi',
      'arm-linux-androideabi',
    ),
    Architecture.arm64 => (
      'aarch64-linux-android',
      'aarch64-linux-android',
      'aarch64-linux-android',
    ),
    Architecture.x64 => (
      'x86_64-linux-android',
      'x86_64-linux-android',
      'x86_64-linux-android',
    ),
    final other => throw StateError('No Android Rust target for $other'),
  };
  final sysroot = '$llvmRoot/sysroot'.replaceAll(r'\', '/');
  return {
    'BINDGEN_EXTRA_CLANG_ARGS_${rustTriple.replaceAll('-', '_')}':
        '--sysroot=$sysroot -I$sysroot/usr/include/$sysrootTriple '
        '--target=$ndkTriple${code.android.targetNdkApi}',
  };
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
