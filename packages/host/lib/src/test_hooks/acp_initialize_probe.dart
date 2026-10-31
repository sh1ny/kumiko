import 'package:host_protocol/host_protocol.dart';

import '../agent/acp/acp_client.dart';
import '../agent/executable_resolver.dart';
import '../host_extension.dart';

/// Test-only group-5 process seam, not agent/start or AgentService evidence.
/// Resolves an actually saved profile and drives the actual client over real
/// containment pipes under the host's existing desktop/job attestation.
Future<Json> probeAcpInitialize(HostServices host, Json params) async {
  final id = params['acpProfileInitialize']! as String;
  final target = params['target'];
  if (target is! String) {
    throw RpcException(ErrorCode.invalidParams, 'target required');
  }
  final profile = await host.runtimeProfiles.find(id);
  if (profile == null) {
    throw RpcException(ErrorCode.invalidProfile, 'unknown runtime profile $id');
  }
  final executable = ExecutableResolver().resolve(profile.executable);
  final launched = await host.units.launch(
    target: target,
    kind: 'agent',
    argv: [executable, ...profile.args],
    environment: profile.env,
    pipes: true,
  );
  final pipes = launched.pipes!;
  final errors = pipes.stderr.listen((_) {});
  final client = AcpClient.pipes(pipes);
  try {
    final ledgerRecorded = host.units.ledger.unit(launched.id)?.kind == 'agent';
    final initialized = await client.initialize();
    final outcome = await host.units.end(launched.id);
    return {
      ...TestUnitLaunchResult(launched.id).toJson(),
      'protocolVersion': initialized.protocolVersion,
      'agentInfo': initialized.agentInfo,
      'kind': 'agent',
      'ledgerRecorded': ledgerRecorded,
      'cleaned': outcome.cleaned,
    };
  } finally {
    await client.close();
    if (host.units.live.containsKey(launched.id)) {
      await host.units.end(launched.id);
    }
    await errors.cancel();
    await pipes.close();
  }
}
