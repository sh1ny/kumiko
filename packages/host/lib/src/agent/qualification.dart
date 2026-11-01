import 'package:host_protocol/host_protocol.dart';

import 'acp/acp_client.dart';
import 'qualified_adapters.dart';

/// Per-initialize claims, never a persisted assumption about a saved session.
class AdapterClaims {
  AdapterClaims(this.capabilities, this.unavailableReason);
  final List<String> capabilities;

  /// Continue's reason when neither load nor resume can be claimed.
  final String? unavailableReason;
  bool get canLoad => capabilities.contains('load');
  bool get canResume => capabilities.contains('resume');
}

AdapterClaims qualifyAdapter(
  AcpInitialization initialization, {
  List<(String, String, List<String>)> qualified = qualifiedAdapters,
}) {
  if (initialization.protocolVersion != 1) {
    throw AcpProtocolException(
      'unsupported ACP protocol version ${initialization.protocolVersion}',
    );
  }
  final capabilities = <String>[
    'prompt',
    'streaming',
    'tools',
    'permissions',
    'cancel',
  ];
  final evidence = <String>{};
  var matched = false;
  if (initialization.adapterVersion != null) {
    for (final (name, version, extras) in qualified) {
      if (name == initialization.adapterName &&
          version == initialization.adapterVersion) {
        matched = true;
        evidence.addAll(extras);
      }
    }
  }
  final advertised = initialization.agentCapabilities;
  if (evidence.contains('load') && advertised['loadSession'] == true) {
    capabilities.add('load');
  }
  final sessions = advertised['sessionCapabilities'];
  if (evidence.contains('resume') &&
      sessions is Json &&
      sessions['resume'] is Json) {
    capabilities.add('resume');
  }
  return AdapterClaims(
    List.unmodifiable(capabilities),
    capabilities.contains('load') || capabilities.contains('resume')
        ? null
        : matched
        ? 'not-advertised'
        : 'not-qualified',
  );
}
