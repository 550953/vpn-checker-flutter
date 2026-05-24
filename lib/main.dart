import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const String kIpListUrl = 'https://storage.yandexcloud.net/vpn-ips/ip.txt';
const int kBatchSize = 10;
const int kTimeoutSec = 3;

void main() => runApp(const IpCheckerApp());

class IpCheckerApp extends StatelessWidget {
  const IpCheckerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPN Checker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1E88E5),
          surface: Color(0xFF161B22),
        ),
        useMaterial3: true,
      ),
      home: const CheckerPage(),
    );
  }
}

enum S { unknown, open, closed }

class ServerResult {
  final String ip;
  S ssh = S.unknown;
  S http80 = S.unknown;
  S https443 = S.unknown;

  ServerResult(this.ip);

  bool get isAlive => ssh == S.open || http80 == S.open || https443 == S.open;
  bool get isDone =>
      ssh != S.unknown && http80 != S.unknown && https443 != S.unknown;
}

Future<bool> tcpCheck(String ip, int port) async {
  try {
    final s = await Socket.connect(
      ip, port,
      timeout: Duration(seconds: kTimeoutSec),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

class CheckerPage extends StatefulWidget {
  const CheckerPage({super.key});

  @override
  State<CheckerPage> createState() => _CheckerPageState();
}

class _CheckerPageState extends State<CheckerPage> {
  List<ServerResult> _results = [];
  bool _checking = false;
  String _status = 'Нажмите СТАРТ';
  int _checked = 0;
  int _total = 0;

  int get _alive => _results.where((r) => r.isAlive).length;
  int get _dead => _results.where((r) => r.isDone && !r.isAlive).length;

  Future<void> _checkOne(ServerResult r) async {
    final results = await Future.wait([
      tcpCheck(r.ip, 22),
      tcpCheck(r.ip, 80),
      tcpCheck(r.ip, 443),
    ]);
    setState(() {
      r.ssh = results[0] ? S.open : S.closed;
      r.http80 = results[1] ? S.open : S.closed;
      r.https443 = results[2] ? S.open : S.closed;
      _checked++;
      _status = 'Проверено: $_checked / $_total';
    });
  }

  Future<void> _start() async {
    setState(() {
      _checking = true;
      _results = [];
      _checked = 0;
      _total = 0;
      _status = 'Загружаю список...';
    });

    List<String> ips;
    try {
      final resp = await http
          .get(Uri.parse(kIpListUrl))
          .timeout(const Duration(seconds: 15));
      ips = resp.body
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      setState(() {
        _checking = false;
        _status = 'Ошибка загрузки списка';
      });
      return;
    }

    final results = ips.map(ServerResult.new).toList();
    setState(() {
      _total = ips.length;
      _results = results;
      _status = 'Проверяю $_total серверов...';
    });

    for (int i = 0; i < results.length; i += kBatchSize) {
      final end = (i + kBatchSize).clamp(0, results.length);
      await Future.wait(results.sublist(i, end).map(_checkOne));
    }

    setState(() {
      _checking = false;
      _status = _alive > 0
          ? 'Готово — живых: $_alive из $_total'
          : 'Серверов ноль';
    });
  }

  void _copyAlive() {
    final ips = _results
        .where((r) => r.isAlive)
        .map((r) => r.ip)
        .join('\n');
    if (ips.isEmpty) return;
    Clipboard.setData(ClipboardData(text: ips));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Скопировано $_alive IP'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<ServerResult> get _sorted {
    final alive = _results.where((r) => r.isAlive).toList();
    final pending = _results.where((r) => !r.isDone).toList();
    final dead = _results.where((r) => r.isDone && !r.isAlive).toList();
    return [...alive, ...pending, ...dead];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text(
          'VPN Checker',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          if (_alive > 0)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'Копировать живые IP',
              onPressed: _copyAlive,
            ),
        ],
      ),
      body: Column(
        children: [
          // Статус-панель
          _StatusPanel(
            status: _status,
            alive: _alive,
            dead: _dead,
            checked: _checked,
            total: _total,
            checking: _checking,
          ),

          // Заголовок колонок
          if (_results.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              color: const Color(0xFF0D1117),
              child: const Row(
                children: [
                  Expanded(
                    child: Text('IP-адрес',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                  _ColHeader('SSH\n:22'),
                  _ColHeader('HTTP\n:80'),
                  _ColHeader('HTTPS\n:443'),
                ],
              ),
            ),

          // Список
          Expanded(
            child: _results.isEmpty
                ? _EmptyState(checking: _checking)
                : ListView.builder(
                    itemCount: _sorted.length,
                    itemBuilder: (ctx, i) => _ServerTile(_sorted[i]),
                  ),
          ),

          // Кнопка
          _StartButton(checking: _checking, onStart: _start),
        ],
      ),
    );
  }
}

// ── Виджеты ──────────────────────────────────────────────

class _StatusPanel extends StatelessWidget {
  final String status;
  final int alive, dead, checked, total;
  final bool checking;

  const _StatusPanel({
    required this.status,
    required this.alive,
    required this.dead,
    required this.checked,
    required this.total,
    required this.checking,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Column(
        children: [
          Text(
            status,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: !checking && alive > 0
                  ? const Color(0xFF3FB950)
                  : !checking && total > 0 && alive == 0
                      ? const Color(0xFFF85149)
                      : Colors.white70,
            ),
            textAlign: TextAlign.center,
          ),
          if (checking && total > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total > 0 ? checked / total : 0,
                backgroundColor: const Color(0xFF30363D),
                color: const Color(0xFF1E88E5),
                minHeight: 5,
              ),
            ),
          ],
          if (total > 0 && !checking) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Badge('✓ Живые: $alive', const Color(0xFF3FB950)),
                const SizedBox(width: 10),
                _Badge('✗ Мёртвые: $dead', const Color(0xFFF85149)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }
}

class _ColHeader extends StatelessWidget {
  final String text;
  const _ColHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white38,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            height: 1.3),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final ServerResult r;
  const _ServerTile(this.r);

  @override
  Widget build(BuildContext context) {
    final Color rowColor;
    if (!r.isDone) {
      rowColor = Colors.transparent;
    } else if (r.isAlive) {
      rowColor = const Color(0xFF3FB950).withOpacity(0.06);
    } else {
      rowColor = const Color(0xFFF85149).withOpacity(0.04);
    }

    final Color borderColor;
    if (!r.isDone) {
      borderColor = Colors.white12;
    } else if (r.isAlive) {
      borderColor = const Color(0xFF3FB950).withOpacity(0.3);
    } else {
      borderColor = const Color(0xFFF85149).withOpacity(0.15);
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: rowColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              r.ip,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: r.isDone
                    ? (r.isAlive ? Colors.white : Colors.white38)
                    : Colors.white54,
              ),
            ),
          ),
          _Dot(r.ssh),
          const SizedBox(width: 4),
          _Dot(r.http80),
          const SizedBox(width: 4),
          _Dot(r.https443),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final S state;
  const _Dot(this.state);

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    switch (state) {
      case S.open:
        color = const Color(0xFF3FB950);
        icon = Icons.check_circle_rounded;
        break;
      case S.closed:
        color = const Color(0xFFF85149);
        icon = Icons.cancel_rounded;
        break;
      case S.unknown:
        color = Colors.white.withOpacity(0.2);

        icon = Icons.radio_button_unchecked;
        break;
    }
    return SizedBox(
      width: 52,
      child: Icon(icon, color: color, size: 19),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool checking;
  const _EmptyState({required this.checking});

  @override
  Widget build(BuildContext context) {
    if (checking) return const SizedBox();
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.dns_rounded, size: 56, color: Colors.white12),
          SizedBox(height: 14),
          Text(
            'Нажмите СТАРТ\nдля проверки серверов',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  final bool checking;
  final VoidCallback onStart;
  const _StartButton({required this.checking, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: checking ? null : onStart,
          style: ElevatedButton.styleFrom(
            backgroundColor:
                checking ? const Color(0xFF21262D) : const Color(0xFF1E88E5),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF21262D),
            disabledForegroundColor: Colors.white30,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Text(
            checking ? 'Проверяю...' : 'СТАРТ',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ),
      ),
    );
  }
}
