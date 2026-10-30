/// The environment overrides of a terminal unit, laid over the host's own
/// environment (design D2). On POSIX the terminal defaults to
/// `TERM=xterm-256color` and `COLORTERM=truecolor`, whatever the host
/// inherited, and the profile's variables come after them so a profile can
/// still set `TERM`. Windows adds nothing: ConPTY does not use `TERM`.
Map<String, String> terminalEnvironment({
  required bool posix,
  required Map<String, String> profileEnv,
}) => {
  if (posix) 'TERM': 'xterm-256color',
  if (posix) 'COLORTERM': 'truecolor',
  ...profileEnv,
};
