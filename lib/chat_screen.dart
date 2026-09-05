import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'chat_md.dart';

/// The PC agent may work for minutes on one prompt; give up only well after it does.
const Duration kReplyTimeout = Duration(seconds: 330);

class ChatMsg {
  ChatMsg(this.role, this.text, {this.pending = false, this.failed = false});

  final String role;
  String text;
  bool pending;
  bool failed;

  bool get isUser => role == 'user';
  bool get isSystem => role == 'system';
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.serverId,
    required this.clientToken,
    required this.project,
  });

  final String serverId;
  final String clientToken;
  final ProjectInfo project;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _rng = Random();

  Timer? _timeout;

  final List<ChatMsg> _messages = [];
  String? _pendingReqId;
  String? _banner;
  bool _connected = false;

  bool get _busy => _pendingReqId != null;
  bool _askingPassword = false;

  bool _needsSshPassword(String text) {
    final t = text.toLowerCase();
    return t.contains('нужен пароль') ||
        t.contains('needs_auth') ||
        t.contains('пароль для входа') ||
        t.contains('authentication') && t.contains('failed');
  }

  Future<void> _askSshPassword({String? hint}) async {
    if (_askingPassword || !widget.project.isSsh) return;
    _askingPassword = true;
    final ctrl = TextEditingController();
    final who = widget.project.user.isEmpty
        ? widget.project.host
        : '${widget.project.user}@${widget.project.host}';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Пароль SSH'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              hint ?? 'Вход $who — пароль только на ваш ПК, в чат не пишется.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Пароль'),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Войти')),
        ],
      ),
    );
    final password = ctrl.text;
    ctrl.dispose();
    _askingPassword = false;
    if (ok != true || password.isEmpty || !mounted) return;

    setState(() {
      _messages.add(ChatMsg('system', 'Входим по SSH…'));
    });
    final uri = _api('/api/client/ssh_auth/${widget.serverId}');
    try {
      final r = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'req_id': _newReqId(),
              'host': widget.project.host,
              'user': widget.project.user,
              'remote_path': widget.project.remotePath,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      Map<String, dynamic> j = {};
      try {
        j = jsonDecode(r.body) as Map<String, dynamic>;
      } catch (_) {}
      final okLogin = j['ok'] == true;
      final detail = (j['detail'] as String?) ?? (j['error'] as String?) ?? '';
      setState(() {
        _messages.add(
          ChatMsg(
            'system',
            okLogin
                ? 'SSH вошли. Можно писать задачу.'
                : (detail.isEmpty ? 'Не вошли по SSH' : detail),
          ),
        );
        if (okLogin) _connected = true;
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add(ChatMsg('system', 'Не вошли: связь оборвалась')));
    }
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Uri _api(String path, [Map<String, String>? extra]) {
    return Uri.parse('$kMasterHttp$path').replace(
      queryParameters: {'ct': widget.clientToken, ...?extra},
    );
  }

  Future<void> _loadHistory() async {
    setState(() => _banner = null);
    final uri = _api(
      '/api/client/history/${widget.serverId}',
      {'project_id': widget.project.id},
    );
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (r.statusCode != 200) {
        setState(() {
          _connected = false;
          _banner = 'История: ${r.statusCode}';
        });
        return;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final err = (j['error'] as String?) ?? '';
      final raw = j['messages'];
      setState(() {
        _connected = err.isEmpty;
        _banner = err.isEmpty ? null : err;
        if (raw is List) {
          _messages
            ..clear()
            ..addAll(raw.whereType<Map>().map((e) {
              final m = Map<String, dynamic>.from(e);
              return ChatMsg(
                (m['role'] as String?) ?? 'assistant',
                (m['content'] as String?) ?? '',
              );
            }).where((m) => m.text.isNotEmpty));
        }
      });
      _scrollToEnd();
      if (widget.project.isSsh) {
        final lastNeed = _messages.reversed
            .map((m) => m.text)
            .where(_needsSshPassword)
            .firstOrNull;
        if (lastNeed != null) {
          await _askSshPassword();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _banner = 'Нет связи с ПК';
      });
    }
  }

  void _failPending(String reason) {
    if (_pendingReqId == null) return;
    _timeout?.cancel();
    setState(() {
      _pendingReqId = null;
      final last = _messages.isNotEmpty ? _messages.last : null;
      if (last != null && last.pending) {
        last.pending = false;
        last.failed = true;
        last.text = reason;
      }
    });
  }

  String _newReqId() =>
      '${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(1 << 20)}';

  Future<void> _submit() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final reqId = _newReqId();
    final p = widget.project;

    setState(() {
      _messages.add(ChatMsg('user', text));
      _messages.add(ChatMsg('assistant', '', pending: true));
      _pendingReqId = reqId;
      _input.clear();
    });
    _scrollToEnd();

    _timeout = Timer(kReplyTimeout, () {
      _failPending('Агент не ответил за ${kReplyTimeout.inMinutes} мин');
    });

    final uri = _api('/api/client/chat/${widget.serverId}');
    try {
      final r = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'req_id': reqId,
              'project_id': p.id,
              'path': p.path,
              'name': p.name,
              'kind': p.kind,
              'host': p.host,
              'user': p.user,
              'remote_path': p.remotePath,
              'text': text,
            }),
          )
          .timeout(kReplyTimeout);
      if (!mounted || _pendingReqId != reqId) return;
      _timeout?.cancel();
      Map<String, dynamic> j = {};
      try {
        j = jsonDecode(r.body) as Map<String, dynamic>;
      } catch (_) {}
      final err = (j['error'] as String?) ??
          (r.statusCode == 200 ? '' : 'Сервер: ${r.statusCode}');
      final answer = (j['text'] as String?) ?? '';
      setState(() {
        _pendingReqId = null;
        _connected = err.isEmpty;
        final last = _messages.isNotEmpty ? _messages.last : null;
        if (last != null && last.pending) {
          last.pending = false;
          if (err.isNotEmpty) {
            last.failed = true;
            last.text = err;
          } else {
            last.text = answer.isEmpty ? '(пустой ответ)' : answer;
          }
        }
      });
      _scrollToEnd();
      final shown = err.isNotEmpty ? err : answer;
      if (widget.project.isSsh && _needsSshPassword(shown)) {
        await _askSshPassword();
      }
    } catch (e) {
      if (!mounted || _pendingReqId != reqId) return;
      _failPending('$e');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Bg(
        child: SafeArea(
          child: Column(
            children: [
              _header(p),
              if (_banner != null)
                Material(
                  color: const Color(0xFF3A1520),
                  child: ListTile(
                    dense: true,
                    title: Text(_banner!,
                        style: const TextStyle(color: Colors.white, fontSize: 13)),
                    trailing: TextButton(
                      onPressed: _loadHistory,
                      child: const Text('Повтор'),
                    ),
                  ),
                ),
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _connected
                                ? 'Напишите задачу — агент Cursor выполнит её на ПК.'
                                : 'Подключаемся к ПК…',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              height: 1.5,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _bubble(_messages[i]),
                      ),
              ),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ProjectInfo p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                Text(
                  p.isSsh
                      ? (p.user.isEmpty ? 'SSH · ${p.host}' : 'SSH · ${p.user}@${p.host}')
                      : 'ПК · ${p.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: _connected ? const Color(0xFF3DDC84) : const Color(0xFF7A8598),
              shape: BoxShape.circle,
            ),
          ),
          if (p.isSsh)
            IconButton(
              tooltip: 'Пароль SSH',
              onPressed: _busy ? null : () => _askSshPassword(),
              icon: const Icon(Icons.key, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMsg m) {
    if (m.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Text(
          m.text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
      );
    }

    final bg = m.isUser
        ? const Color(0xFF1E3A5F)
        : m.failed
            ? const Color(0xFF3A1520)
            : const Color(0xFF171B24);

    return Align(
      alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: m.pending
            ? const _Typing()
            : GestureDetector(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Скопировано'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: chatMarkdown(
                  m.text,
                  base: TextStyle(
                    fontSize: 14.5,
                    height: 1.45,
                    color: m.failed ? const Color(0xFFFF9AA8) : Colors.white,
                  ),
                  codeBg: const Color(0xFF0B0E14),
                ),
              ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF1E2534))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: !_busy,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: _busy ? 'Агент работает…' : 'Задача для агента',
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            height: 48,
            child: ElevatedButton(
              onPressed: _busy ? null : _submit,
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: const Color(0xFF4DA3FF),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.arrow_upward, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_c.value * 3) - i).clamp(0.0, 1.0);
            final o = 0.25 + 0.75 * (t < 0.5 ? t * 2 : (1 - t) * 2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: Opacity(
                opacity: o,
                child: const CircleAvatar(
                  radius: 3.5,
                  backgroundColor: Color(0xFF4DA3FF),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
