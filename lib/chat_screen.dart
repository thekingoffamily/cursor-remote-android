import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'main.dart';

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

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _timeout;

  final List<ChatMsg> _messages = [];
  String? _pendingReqId;
  String? _banner;
  bool _connected = false;
  bool _closing = false;

  bool get _busy => _pendingReqId != null;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _closing = true;
    _timeout?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _connect() {
    _sub?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _closing = false;
    setState(() {
      _connected = false;
      _banner = null;
    });

    final uri = Uri.parse(clientWsUri(widget.serverId, widget.clientToken));
    try {
      _ch = WebSocketChannel.connect(uri);
      _sub = _ch!.stream.listen(
        _onEvent,
        onError: (e) {
          if (!_closing && mounted) {
            setState(() {
              _connected = false;
              _banner = 'Ошибка связи: $e';
            });
          }
        },
        onDone: () {
          if (!_closing && mounted) {
            setState(() {
              _connected = false;
              _banner ??= 'Связь разорвана';
            });
            // a dropped socket will never deliver the answer we are waiting for
            _failPending('Связь разорвана — ответ не дошёл');
          }
        },
      );
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!_closing) _requestHistory();
      });
    } catch (e) {
      setState(() => _banner = 'Не удалось подключиться: $e');
    }
  }

  void _send(Map<String, dynamic> msg) => _ch?.sink.add(jsonEncode(msg));

  void _requestHistory() =>
      _send({'type': 'history', 'project_id': widget.project.id});

  void _onEvent(dynamic event) {
    if (event is! String) return;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(event) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final t = j['type'];

    if (t == 'denied') {
      setState(() => _banner = 'Лицензия: ${j['status']}');
      _failPending('Лицензия недействительна');
    } else if (t == 'error') {
      setState(() => _banner = '${j['detail']}');
    } else if (t == 'relay') {
      final online = j['agent_online'] == true;
      setState(() {
        _connected = online;
        _banner = online ? null : 'Агент на ПК оффлайн. Проверьте иконку в трее.';
      });
      if (online && _messages.isEmpty) _requestHistory();
    } else if (t == 'history') {
      if (j['project_id'] != widget.project.id) return;
      final raw = j['messages'];
      if (raw is! List) return;
      setState(() {
        _connected = true;
        _messages
          ..clear()
          ..addAll(raw.whereType<Map>().map((e) {
            final m = Map<String, dynamic>.from(e);
            return ChatMsg((m['role'] as String?) ?? 'assistant',
                (m['content'] as String?) ?? '');
          }).where((m) => m.text.isNotEmpty));
      });
      _scrollToEnd();
    } else if (t == 'chat_reply') {
      // ignore answers to a prompt we already gave up on, or to another phone's
      if (j['req_id'] != _pendingReqId) return;
      _timeout?.cancel();
      final err = (j['error'] as String?) ?? '';
      final text = (j['text'] as String?) ?? '';
      setState(() {
        _pendingReqId = null;
        _connected = true;
        final last = _messages.isNotEmpty ? _messages.last : null;
        if (last != null && last.pending) {
          last.pending = false;
          if (err.isNotEmpty) {
            last.failed = true;
            last.text = err;
          } else {
            last.text = text.isEmpty ? '(пустой ответ)' : text;
          }
        }
      });
      _scrollToEnd();
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

  void _submit() {
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

    _send({
      'type': 'chat',
      'req_id': reqId,
      'project_id': p.id,
      'path': p.path,
      'name': p.name,
      'kind': p.kind,
      'host': p.host,
      'user': p.user,
      'remote_path': p.remotePath,
      'text': text,
    });

    _timeout = Timer(kReplyTimeout, () {
      _failPending('Агент не ответил за ${kReplyTimeout.inMinutes} мин');
    });
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
                      onPressed: _connect,
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
                  p.isSsh ? 'SSH · ${p.subtitle}' : 'ПК · ${p.subtitle}',
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
                child: SelectableText(
                  m.text,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.45,
                    color: m.failed ? const Color(0xFFFF9AA8) : Colors.white,
                  ),
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
