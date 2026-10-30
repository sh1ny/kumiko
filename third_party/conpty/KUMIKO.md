# Vendored ConPTY

Microsoft's open-source pseudo-console, shipped with the host so Windows
terminals do not depend on the inbox ConPTY (`kernel32` and `conhost`), which
lags behind it (design D2, user decision 2026-10-30). `conpty.dll` starts
`OpenConsole.exe` from its own folder; the `process_containment` build hook
bundles both side by side.

- **Source:** NuGet package `Microsoft.Windows.Console.ConPTY` 1.25.260930003
  (nupkg SHA-256
  `02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee`), built
  from https://github.com/microsoft/terminal. Kept unchanged:
  - `x64/conpty.dll` from `runtimes/win-x64/native/`, SHA-256
    `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a`;
  - `x64/OpenConsole.exe` from `build/native/runtimes/x64/`, SHA-256
    `3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586`.

  Both carry a valid Authenticode signature by Microsoft Corporation, file
  version 1.25.2609.30003. The host is x64 only, so the other architectures
  are left out.
- **Licence:** MIT (`LICENSE`, from the repository root of
  microsoft/terminal).

To update, download the new package version from nuget.org, check both
signatures, replace both files together and update the version and hashes
here.
