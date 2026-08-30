import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const String kMasterHttp = String.fromEnvironment(
  'MASTER_URL',
  defaultValue: 'http://31.172.72.212:28471',
);

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

class _Bg extends StatelessWidget {
  const _Bg({required this.child});
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
      body: _Bg(
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
      body: _Bg(
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
    required this.index,
    required this.hwnd,
    required this.folderName,
    required this.title,
  });

  final int index;
  final int hwnd;
  final String folderName;
  final String title;

  factory ProjectInfo.fromJson(Map<String, dynamic> j) {
    return ProjectInfo(
      index: (j['index'] as num?)?.toInt() ?? 0,
      hwnd: (j['hwnd'] as num?)?.toInt() ?? 0,
      folderName: (j['folder_name'] as String?) ?? 'Cursor',
      title: (j['title'] as String?) ?? '',
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
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool _closing = false;
  String? _error;
  List<ProjectInfo> _projects = [];

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    _sub?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _closing = false;
    setState(() {
      _error = null;
      _projects = [];
    });
    final uri = Uri.parse(clientWsUri(widget.serverId, widget.clientToken));
    try {
      _ch = WebSocketChannel.connect(uri);
      _sub = _ch!.stream.listen(
        (event) {
          if (event is! String) return;
          final j = jsonDecode(event) as Map<String, dynamic>;
          final t = j['type'];
          if (t == 'denied') {
            setState(() => _error = 'Лицензия: ${j['status']}');
          } else if (t == 'error') {
            setState(() => _error = '${j['detail']}');
          } else if (t == 'relay' && j['agent_online'] == false) {
            setState(() => _error = 'Агент оффлайн. Проверьте иконку в трее ПК.');
          } else if (t == 'relay' && j['agent_online'] == true) {
            setState(() => _error = null);
            _send({'type': 'list'});
          } else if (t == 'keepalive' || t == 'windows') {
            final raw = j['windows'];
            if (raw is List) {
              setState(() {
                _projects = raw
                    .whereType<Map>()
                    .map((e) => ProjectInfo.fromJson(Map<String, dynamic>.from(e)))
                    .toList();
                _error = null;
              });
            }
          }
        },
        onError: (e) {
          if (!_closing && mounted) setState(() => _error = 'Ошибка связи: $e');
        },
        onDone: () {
          if (!_closing && mounted && _projects.isEmpty) {
            setState(() => _error = 'Нет связи с Master. Проверьте интернет и агент.');
          }
        },
      );
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!_closing) _send({'type': 'list'});
      });
    } catch (e) {
      setState(() => _error = 'Не удалось подключиться: $e');
    }
  }

  void _send(Map<String, dynamic> msg) => _ch?.sink.add(jsonEncode(msg));

  Future<void> _openProject(ProjectInfo p) async {
    _closing = true;
    await _sub?.cancel();
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectSessionScreen(
          serverId: widget.serverId,
          clientToken: widget.clientToken,
          projectIndex: p.index,
          projectHwnd: p.hwnd,
          folderName: p.folderName,
        ),
      ),
    );
    if (mounted) _connect();
  }

  @override
  void dispose() {
    _closing = true;
    _sub?.cancel();
    _ch?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _Bg(
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
                          _error == null
                              ? 'Ищем открытые окна Cursor…\nОткройте проект на ПК.'
                              : '',
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
                                      child: const Icon(Icons.folder_open, color: Color(0xFF4DA3FF)),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            p.folderName,
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          if (p.title.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              p.title,
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

class ProjectSessionScreen extends StatefulWidget {
  const ProjectSessionScreen({
    super.key,
    required this.serverId,
    required this.clientToken,
    required this.projectIndex,
    required this.projectHwnd,
    required this.folderName,
  });

  final String serverId;
  final String clientToken;
  final int projectIndex;
  final int projectHwnd;
  final String folderName;

  @override
  State<ProjectSessionScreen> createState() => _ProjectSessionScreenState();
}

class _ProjectSessionScreenState extends State<ProjectSessionScreen> {
  WebSocketChannel? _ch;
  Uint8List? _frame;
  String? _error;
  StreamSubscription? _sub;
  bool _closing = false;
  bool _sending = false;
  final _prompt = TextEditingController();
  final _focus = FocusNode();

  Map<String, dynamic> get _selectMsg => {
        'type': 'select',
        'index': widget.projectIndex,
        'hwnd': widget.projectHwnd,
        'folder_name': widget.folderName,
      };

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _connect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _connect() {
    _sub?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _closing = false;
    setState(() {
      _error = null;
      _frame = null;
    });
    final uri = Uri.parse(clientWsUri(widget.serverId, widget.clientToken));
    try {
      _ch = WebSocketChannel.connect(uri);
      _sub = _ch!.stream.listen(
        (event) {
          if (event is List<int>) {
            setState(() {
              _frame = Uint8List.fromList(event);
              _error = null;
            });
          } else if (event is String) {
            final j = jsonDecode(event) as Map<String, dynamic>;
            if (j['type'] == 'denied') {
              setState(() => _error = 'Лицензия: ${j['status']}');
            } else if (j['type'] == 'error') {
              setState(() => _error = '${j['detail']}');
            } else if (j['type'] == 'relay' && j['agent_online'] == false) {
              setState(() => _error = 'Агент оффлайн. Проверьте иконку в трее ПК.');
            } else if (j['type'] == 'relay' && j['agent_online'] == true) {
              setState(() => _error = null);
              _send(_selectMsg);
            }
          }
        },
        onError: (e) {
          if (!_closing && mounted) setState(() => _error = 'Ошибка связи: $e');
        },
        onDone: () {
          if (!_closing && mounted && _frame == null) {
            setState(() => _error = 'Нет связи с Master. Проверьте интернет и агент.');
          }
        },
      );
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!_closing) _send(_selectMsg);
      });
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_closing) _focus.requestFocus();
      });
    } catch (e) {
      setState(() => _error = 'Не удалось подключиться: $e');
    }
  }

  void _send(Map<String, dynamic> msg) => _ch?.sink.add(jsonEncode(msg));

  Future<void> _sendPrompt() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _sending) return;
    if (_frame == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Подожди — ещё подключаемся к проекту…')),
      );
      return;
    }
    setState(() => _sending = true);
    _send({
      'type': 'prompt',
      'text': text,
      'hwnd': widget.projectHwnd,
      'index': widget.projectIndex,
      'folder_name': widget.folderName,
    });
    _prompt.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Отправляю агенту на ПК…'),
          duration: Duration(seconds: 1),
        ),
      );
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted) {
      setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  void _onTapDown(TapDownDetails d, BoxConstraints box) {
    _send({
      'type': 'tap',
      'x': (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0),
      'y': (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0),
      'button': 'left',
    });
  }

  void _onLongPress(LongPressStartDetails d, BoxConstraints box) {
    _send({
      'type': 'tap',
      'x': (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0),
      'y': (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0),
      'button': 'right',
    });
  }

  @override
  void dispose() {
    _closing = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _focus.dispose();
    _prompt.dispose();
    _sub?.cancel();
    _ch?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (_error != null)
              Material(
                color: const Color(0xFF3A1520),
                child: ListTile(
                  dense: true,
                  title: Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  trailing: TextButton(onPressed: _connect, child: const Text('Повтор')),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return ColoredBox(
                          color: Colors.black,
                          child: _frame == null
                              ? Center(
                                  child: Text(
                                    'Подключаем чат ${widget.folderName}…',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                                  ),
                                )
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (d) => _onTapDown(d, constraints),
                                  onLongPressStart: (d) => _onLongPress(d, constraints),
                                  onVerticalDragUpdate: (d) {
                                    if (d.primaryDelta == null) return;
                                    _send({'type': 'scroll', 'dy': d.primaryDelta! > 0 ? -1 : 1});
                                  },
                                  child: InteractiveViewer(
                                    minScale: 1,
                                    maxScale: 4,
                                    child: SizedBox(
                                      width: constraints.maxWidth,
                                      height: constraints.maxHeight,
                                      child: Image.memory(
                                        _frame!,
                                        gaplessPlayback: true,
                                        fit: BoxFit.contain,
                                        alignment: Alignment.center,
                                      ),
                                    ),
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 4,
                    left: 4,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 12,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          'чат Cursor',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: const Color(0xFF12151C),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _prompt,
                          focusNode: _focus,
                          autofocus: true,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          minLines: 1,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            hintText: 'Сообщение агенту…',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _sending ? null : _sendPrompt,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text(
                                'Отправить\nагенту',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.1),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
