import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/agent/qualification.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

void main() {
  const evidence = [
    ('fixture', '1.2.3', <String>['load', 'resume']),
  ];
  AcpInitialization init({
    String? version = '1.2.3',
    Json caps = const {
      'loadSession': true,
      'sessionCapabilities': <String, Object?>{'resume': <String, Object?>{}},
    },
  }) => AcpInitialization.fromJson({
    'protocolVersion': 1,
    'agentInfo': {'name': 'fixture', 'version': ?version},
    'agentCapabilities': caps,
  });
  test('listed (name, version) advertising loadSession claims load', () {
    final claims = qualifyAdapter(init(), qualified: evidence);
    expect(
      claims.capabilities,
      containsAll([
        'prompt',
        'streaming',
        'tools',
        'permissions',
        'cancel',
        'load',
        'resume',
      ]),
    );
    expect(claims.unavailableReason, isNull);
  });
  test('unlisted version claims the baseline only', () {
    final claims = qualifyAdapter(init(version: '1.2.4'), qualified: evidence);
    expect(
      claims.capabilities,
      unorderedEquals([
        'prompt',
        'streaming',
        'tools',
        'permissions',
        'cancel',
      ]),
    );
    expect(claims.unavailableReason, 'not-qualified');
    expect(qualifyAdapter(init()).unavailableReason, 'not-qualified');
  });
  test('no agentInfo.version is unqualified', () {
    expect(
      qualifyAdapter(
        init(version: null),
        qualified: evidence,
      ).unavailableReason,
      'not-qualified',
    );
  });
  test('same version with another adapter name is unqualified', () {
    final other = AcpInitialization.fromJson({
      'protocolVersion': 1,
      'agentInfo': {'name': 'other', 'version': '1.2.3'},
      'agentCapabilities': {'loadSession': true},
    });
    expect(
      qualifyAdapter(other, qualified: evidence).unavailableReason,
      'not-qualified',
    );
  });
  test('another protocol version cannot claim baseline', () {
    expect(
      () => qualifyAdapter(AcpInitialization.fromJson({'protocolVersion': 2})),
      throwsA(isA<AcpProtocolException>()),
    );
  });
  test('listed but not advertised is not claimed', () {
    final claims = qualifyAdapter(init(caps: {}), qualified: evidence);
    expect(claims.capabilities, isNot(contains('load')));
    expect(claims.unavailableReason, 'not-advertised');
  });
  test('advertised resume must be an object not a boolean', () {
    final claims = qualifyAdapter(
      init(
        caps: {
          'loadSession': false,
          'sessionCapabilities': {'resume': true},
        },
      ),
      qualified: evidence,
    );
    expect(claims.capabilities, isNot(contains('resume')));
  });
}
