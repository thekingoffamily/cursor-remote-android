import 'package:flutter_test/flutter_test.dart';

import 'package:cursor_remote/main.dart';

void main() {
  test('ProjectInfo reads the agent payload', () {
    final local = ProjectInfo.fromJson({
      'id': 'c:/dev/app',
      'name': 'app',
      'kind': 'local',
      'path': r'C:\dev\app',
      'open': true,
    });
    expect(local.isSsh, isFalse);
    expect(local.subtitle, r'C:\dev\app');
    expect(local.open, isTrue);

    final ssh = ProjectInfo.fromJson({
      'id': 'ssh-open:1:142',
      'name': 'pazl',
      'kind': 'ssh',
      'host': '142',
      'user': 'root',
      'remote_path': '/srv/pazl',
    });
    expect(ssh.isSsh, isTrue);
    expect(ssh.subtitle, 'root@142:/srv/pazl');
    // a project with no id must never reach the chat screen
    expect(ProjectInfo.fromJson(const {}).id, isEmpty);
  });

  test('connection code parsing keeps id and token apart', () {
    final ok = parseConnectionCode('CR-ABCD-1234:0123456789abcdef0123');
    expect(ok, isNotNull);
    expect(ok!.serverId, 'CR-ABCD-1234');
    expect(ok.clientToken, '0123456789abcdef0123');
    expect(parseConnectionCode('CR-ABCD-1234'), isNull);
    expect(parseConnectionCode('CR-ABCD-1234:short'), isNull);
  });
}
