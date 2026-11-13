/// Observed exact native version, OS and signal name.
///
/// Only real auth-required observations in the Codex qualification record may
/// populate this literal. Version and OS record provenance; a confirmed signal
/// applies to every admitted native version. Fixture candidates belong in
/// test-host overrides. Empty means no native authentication claim.
const confirmedCodexAuthSignatures = <(String, String, String)>[
  ('0.166.0', 'windows', 'turn-http-401'),
];
