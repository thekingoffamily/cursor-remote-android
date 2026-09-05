import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'chat_screen.dart';

const String kMasterHttp = String.fromEnvironment(
  'MASTER_URL',
  defaultValue: 'http://31.172.72.212',
);

/// Baked into the UI so we can see which APK is actually installed.
const String kAppVersion = '1.0.5';

String masterWsBase() {
  if (kMasterHttp.startsWith('https://')) {
    return 'wss://${kMasterHttp.substring(8)}';
  }
  if (kMasterHttp.startsWith('http://')) {
    return 'ws://${kMasterHttp.substring(7)}';
  }
  return 'ws://$kMasterHttp';
}

/// Parse `CR-XXXX-XXXX:clientToken` (also `/` or `|`).
({String serverId, String clientToken})? parseConnectionCode(String raw) {
  final s = raw.trim().replaceAll(' ', '');
  for (final sep in [':', '/', '|']) {
    final i = s.indexOf(sep);
    if (i > 0 && i < s.length - 1) {
      final id = s.substring(0, i).toUpperCase();
      final token = s.substring(i + 1).trim();
      if (id.length >= 8 && token.length >= 16) {
        return (serverId: id, clientToken: token);
      }
    }
  }
  return null;
}

String clientWsUri(String serverId, String clientToken) {
  final q = Uri(queryParameters: {'ct': clientToken}).query;
  return '${masterWsBase()}/ws/client/$serverId?$q';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const CursorRemoteApp());
}

class CursorRemoteApp extends StatelessWidget {
  const CursorRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CursorRemote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4DA3FF),
          secondary: Color(0xFF4DA3FF),
          surface: Color(0xFF171B24),
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF171B24),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF2A3140)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF4DA3FF), width: 1.4),
          ),
        ),
      ),
      home: const BootScreen(),
    );
  }
}

class BootScreen extends StatefulWidget {
  const BootScreen({super.key});

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final raw = await _storage.read(key: 'licenses_json');
    if (!mounted) return;
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      final List<LicenseCardData> cards = [];
      if (decoded is List) {
        for (final e in decoded) {
          if (e is String) {
            // legacy: ID only — force re-pair
            continue;
          }
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            final sid = (m['serverId'] as String?) ?? '';
            final ct = (m['clientToken'] as String?) ?? '';
            if (sid.isNotEmpty && ct.length >= 16) {
              cards.add(LicenseCardData(serverId: sid, clientToken: ct));
            }
          }
        }
      }
      if (cards.isNotEmpty) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => DashboardScreen(initialCards: cards)),
        );
        return;
      }
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class Bg extends StatelessWidget {
  const Bg({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0E1117), Color(0xFF121826), Color(0xFF0B1020)],
        ),
      ),
      child: child,
    );
  }
}

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _controller = TextEditingController();
  final _storage = const FlutterSecureStorage();
  String? _error;
  bool _busy = false;

  Future<void> _saveAndGo() async {
    final parsed = parseConnectionCode(_controller.text);
    if (parsed == null) {
      setState(() => _error = 'Вставьте полный код: CR-XXXX-XXXX:ключ (из трея ПК)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final card = LicenseCardData(serverId: parsed.serverId, clientToken: parsed.clientToken);
    await _storage.write(
      key: 'licenses_json',
      value: jsonEncode([card.toJson()]),
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => DashboardScreen(initialCards: [card])),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Bg(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(flex: 1),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset('assets/app_logo.png', height: 112),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'CursorRemote',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Вставьте код подключения с ПК\n(трей → Скопировать код подключения).',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.35,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: _controller,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Код подключения',
                    hintText: 'CR-XXXX-XXXX:ключ',
                  ),
                  onSubmitted: (_) => _saveAndGo(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
                ],
                const Spacer(flex: 2),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _busy ? null : _saveAndGo,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Подключиться',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LicenseCardData {
  LicenseCardData({
    required this.serverId,
    required this.clientToken,
    this.folderName = 'Cursor',
    this.status = 'unknown',
    this.online = false,
  });

  final String serverId;
  final String clientToken;
  String folderName;
  String status;
  bool online;

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'clientToken': clientToken,
      };
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.initialCards});

  final List<LicenseCardData> initialCards;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _storage = const FlutterSecureStorage();
  late List<LicenseCardData> _cards;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _cards = List.of(widget.initialCards);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _persist() async {
    await _storage.write(
      key: 'licenses_json',
      value: jsonEncode(_cards.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _refresh() async {
    for (final c in _cards) {
      try {
        final uri = Uri.parse('$kMasterHttp/api/client/license/${c.serverId}').replace(
          queryParameters: {'ct': c.clientToken},
        );
        final r = await http.get(uri).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          c.folderName = (j['folder_name'] as String?) ?? c.folderName;
          c.status = (j['status'] as String?) ?? c.status;
          c.online = j['agent_online'] == true;
        } else if (r.statusCode == 404) {
          c.status = 'invalid';
          c.online = false;
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _addLicense() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить ПК'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'CR-XXXX-XXXX:ключ'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return;
    final parsed = parseConnectionCode(ctrl.text);
    if (parsed == null) return;
    setState(
      () => _cards.add(
        LicenseCardData(serverId: parsed.serverId, clientToken: parsed.clientToken),
      ),
    );
    await _persist();
    await _refresh();
  }

  void _openSession(LicenseCardData card) {
    if (card.status == 'expired' || card.status == 'invalid') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            card.status == 'invalid'
                ? 'Неверный код. Скопируйте новый из трея агента.'
                : 'Подписка истекла. Оплатите в Telegram-боте.',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectsScreen(serverId: card.serverId, clientToken: card.clientToken),
      ),
    );
  }

  String _statusRu(String s) {
    switch (s) {
      case 'trial':
        return 'триал';
      case 'active':
        return 'активна';
      case 'expired':
        return 'истекла';
      case 'invalid':
        return 'неверный код';
      default:
        return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Bg(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset('assets/app_logo.png', height: 32),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'CursorRemote',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  itemCount: _cards.length,
                  itemBuilder: (context, i) {
                    final c = _cards[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF171B24),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFF2A3140)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Лицензия #${i + 1}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            c.serverId,
                            style: TextStyle(
                              fontSize: 13,
                              letterSpacing: 0.6,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${_statusRu(c.status)}${c.online ? ' · онлайн' : ' · оффлайн'}',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: () => _openSession(c),
                            icon: Icon(c.status == 'expired' ? Icons.payments : Icons.play_arrow),
                            label: Text(c.status == 'expired' ? 'Продлить' : 'Подключиться'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addLicense,
        icon: const Icon(Icons.add),
        label: const Text('Лицензия'),
      ),
    );
  }
}

class ProjectInfo {
  ProjectInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.path,
    required this.host,
    required this.user,
    required this.remotePath,
    required this.open,
  });

  final String id;
  final String name;
  final String kind;
  final String path;
  final String host;
  final String user;
  final String remotePath;
  final bool open;

  bool get isSsh => kind == 'ssh';

  String get subtitle {
    if (isSsh) {
      final who = user.isEmpty ? host : '$user@$host';
      return remotePath.isEmpty ? who : '$who:$remotePath';
    }
    return path;
  }

  factory ProjectInfo.fromJson(Map<String, dynamic> j) {
    return ProjectInfo(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'Cursor',
      kind: (j['kind'] as String?) ?? 'local',
      path: (j['path'] as String?) ?? '',
      host: (j['host'] as String?) ?? '',
      user: (j['user'] as String?) ?? '',
      remotePath: (j['remote_path'] as String?) ?? '',
      open: j['open'] == true,
    );
  }
}

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.serverId, required this.clientToken});

  final String serverId;
  final String clientToken;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  bool _loading = true;
  String? _error;
  List<ProjectInfo> _projects = [];

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _loading = true;
      _projects = [];
    });
    final uri = Uri.parse('$kMasterHttp/api/client/projects/${widget.serverId}')
        .replace(queryParameters: {'ct': widget.clientToken});
    try {
      final r = await http
          .get(uri, headers: {'User-Agent': 'CursorRemote/$kAppVersion'})
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      if (r.statusCode == 403) {
        setState(() {
          _loading = false;
          _error = 'Лицензия недействительна';
        });
        return;
      }
      if (r.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = 'Сервер ${r.statusCode}\n$uri';
        });
        return;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final raw = j['projects'];
      final err = (j['error'] as String?) ?? '';
      setState(() {
        _loading = false;
        _error = err.isEmpty ? null : err;
        if (raw is List) {
          _projects = raw
              .whereType<Map>()
              .map((e) => ProjectInfo.fromJson(Map<String, dynamic>.from(e)))
              .where((p) => p.id.isNotEmpty)
              .toList();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Нет связи ($kAppVersion)\n$uri\n$e';
      });
    }
  }

  Future<void> _openProject(ProjectInfo p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          serverId: widget.serverId,
          clientToken: widget.clientToken,
          project: p,
        ),
      ),
    );
    if (mounted) _connect();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Bg(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const Expanded(
                      child: Text(
                        'Проекты Cursor',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      kAppVersion,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.45),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(onPressed: _connect, icon: const Icon(Icons.refresh)),
                  ],
                ),
              ),
              if (_error != null)
                Material(
                  color: const Color(0xFF3A1520),
                  child: ListTile(
                    title: Text(_error!, style: const TextStyle(color: Colors.white)),
                    trailing: TextButton(onPressed: _connect, child: const Text('Повтор')),
                  ),
                ),
              Expanded(
                child: _projects.isEmpty
                    ? Center(
                        child: Text(
                          _error != null
                              ? ''
                              : _loading
                                  ? 'Ищем проекты… ($kAppVersion)\n$kMasterHttp'
                                  : 'Проектов не нашлось.\nОткройте папку в Cursor на ПК.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.65), height: 1.4),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: _projects.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final p = _projects[i];
                          return Material(
                            color: const Color(0xFF171B24),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _openProject(p),
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF243044),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        p.isSsh ? Icons.dns_outlined : Icons.folder_open,
                                        color: const Color(0xFF4DA3FF),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  p.name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              if (p.open) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: const BoxDecoration(
                                                    color: Color(0xFF3DDC84),
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          if (p.subtitle.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              p.subtitle,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white.withValues(alpha: 0.55),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right, color: Color(0xFF4DA3FF)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

