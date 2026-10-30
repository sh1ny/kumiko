import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Bundles Microsoft's open-source ConPTY with every Windows x64 build (design
/// D2): `conpty.dll`, whose functions the bindings call, and the console host
/// it starts from its own folder, `OpenConsole.exe`. Both land side by side in
/// the bundle's `lib/` (`.dart_tool/lib/` for `dart run` and `dart test`).
/// The files are vendored unchanged (`third_party/conpty/KUMIKO.md`).
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (code.targetOS != OS.windows ||
        code.targetArchitecture != Architecture.x64) {
      return;
    }
    final dir = input.packageRoot.resolve('../../third_party/conpty/x64/');
    for (final (name, file) in const [
      ('conpty', 'conpty.dll'),
      ('OpenConsole', 'OpenConsole.exe'),
    ]) {
      final uri = dir.resolve(file);
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: name,
          linkMode: DynamicLoadingBundled(),
          file: uri,
        ),
      );
      output.dependencies.add(uri);
    }
  });
}
