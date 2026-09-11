import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/relay/relay_payloads.dart';
import 'package:zremote/relay/relay_socket.dart';

/// Handler for one decoded outbound RPC.  It may reply now, later, twice,
/// with an error, or not at all — that is how the failure scripts work.
typedef RelayHandler = void Function(FakeRelayServer server, AgentRpc rpc);

/// In-memory ZCode relay + desktop stand-in for contract tests.
///
/// Speaks the verified wire shapes (docs/RELAY-PROTOCOL-VERIFIED.md and
/// docs/PROTOCOL-DELTA-20260911.md): auth handshake, workspace list, bridge
/// open, binary agent RPC responses (`04 02 …`) and request-shaped pushes
/// (`04 04 …`).  No network, no credentials.
class FakeRelayServer {
  FakeRelayServer() {
    factory = _PerConnectFactory(this);
    _newSocket();
  }

  late FakeRelaySocket socket;

  /// Hands out a fresh socket for every connect, like a real relay would;
  /// a bridge rebuilt after a drop must not inherit a closed stream.
  late final RelaySocketFactory factory;

  /// Every outbound agent RPC, across reconnects.
  final List<AgentRpc> calls = [];

  /// Outbound RPCs on the current socket only.
  List<AgentRpc> callsThisConnection = [];

  final Map<String, RelayHandler> handlers = {};
  RelayHandler? fallback;

  /// F01: delay the auth challenge.
  Duration handshakeDelay = Duration.zero;

  /// Sessions returned by the workspace list (task index).
  List<Map<String, dynamic>> tasks = [
    {
      'taskId': 'sess_fixture_0001',
      'title': 'fixture message',
      'displayStatus': 'completed',
      'provider': 'fixture-provider',
      'workspaceKind': 'local',
      'workspaceLabel': 'proj',
      'workspacePath': '/proj',
      'createdAt': 1789000000000,
      'updatedAt': 1789000001000,
    },
  ];

  /// Rows served by `conversationRowsRangeV4`.
  List<Map<String, dynamic>> rows = [];

  String? bridgeSessionId;
  int _messageSeq = 0;
  int _responseSeq = 0;
  int connections = 0;

  void _newSocket() {
    socket = FakeRelaySocket(onSend: _onSend);
    callsThisConnection = [];
    bridgeSessionId = null;
  }

  /// Simulate the relay dropping the connection: the current socket is
  /// closed so the bridge sees the failure; the next connect gets a fresh one.
  Future<void> dropConnection() async {
    final old = socket;
    _newSocket();
    await old.close();
  }

  // ---------------------------------------------------------------- inbound

  void _onSend(String raw) {
    final p = jsonDecode(raw) as Map<String, dynamic>;
    final type = p['type'];
    if (type == 'auth_init') {
      Future<void>.delayed(handshakeDelay, () {
        if (socket.closed) return;
        socket.emitJson({
          'type': 'auth_challenge',
          'payload': {'nonce': 'n-1'},
        });
      });
      return;
    }
    if (type == 'auth_response') {
      socket.emitJson({'type': 'auth_ack'});
      return;
    }
    final payload = p['payload'];
    if (payload is! Map) return;
    final zt = payload['zcode_type'];
    if (zt == ZcodeType.workspaceListRequest) {
      socket.emitJson(
        _data({
          'zcode_type': ZcodeType.workspaceListResponse,
          'requestId': payload['requestId'],
          'result': {
            'activeTaskId': tasks.isEmpty ? null : tasks.first['taskId'],
            'activeWorkspaceKey': '/proj',
            'workspaces': [
              {'workspaceKey': '/proj', 'path': '/proj', 'name': 'proj'},
            ],
            'mobileViewState': {'activeWorkspaceKey': '/proj'},
            'tasks': tasks,
          },
        }),
      );
      return;
    }
    if (zt == ZcodeType.bridgeOpen) {
      bridgeSessionId = payload['bridgeSessionId'] as String?;
      socket.emitJson(
        _data({
          'zcode_type': ZcodeType.bridgeReady,
          'requestId': payload['requestId'],
          'bridgeSessionId': bridgeSessionId,
          'bridgeGeneration': payload['bridgeGeneration'] ?? 1,
          'bridge': {
            'bridgeSessionId': bridgeSessionId,
            'bridgeGeneration': payload['bridgeGeneration'] ?? 1,
            'kind': 'local',
            'workspaceKey': '/proj',
            'workspacePath': '/proj',
          },
        }),
      );
      return;
    }
    if (zt == ZcodeType.rpcFrame) {
      final b64 = payload['dataBase64'] as String? ?? '';
      final bytes = base64.decode(base64.normalize(b64));
      final rpc = AgentRpcCodec.tryDecode(Uint8List.fromList(bytes));
      if (rpc == null) return;
      calls.add(rpc);
      callsThisConnection.add(rpc);
      final handler = handlers['${rpc.service}.${rpc.method}'] ?? fallback;
      handler?.call(this, rpc);
    }
  }

  // --------------------------------------------------------------- outbound

  Map<String, dynamic> _data(Map<String, dynamic> payload) => {
    'type': 'data',
    'payload': payload,
  };

  void _emitFrame(Uint8List bytes) {
    if (socket.closed) return;
    socket.emitJson(
      _data({
        'zcode_type': ZcodeType.rpcFrame,
        'bridgeSessionId': bridgeSessionId ?? 'b-auto',
        'bridgeGeneration': 1,
        'messageSeq': ++_messageSeq,
        'seq': _messageSeq,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': bytes.length,
        'dataBase64': base64.encode(bytes),
      }),
    );
  }

  /// Reply to an RPC with a JSON value (`04 02 06 C9 …`).
  void replyOk(Object? value) =>
      _emitFrame(_response(value, type: AgentResponseType.ok));

  /// Reply with a desktop fault (`04 02 06 CA …`).
  void replyError(String message) => _emitFrame(
    _response({
      'message': message,
      'name': 'Error',
    }, type: AgentResponseType.error),
  );

  Uint8List _response(Object? value, {required int type}) {
    final out = BytesBuilder(copy: false)
      ..addByte(0x04)
      ..addByte(0x02)
      ..addByte(0x06)
      ..addByte(type)
      ..addByte(0x01)
      ..addByte(0x06);
    AgentRpcCodec.writeVarint(out, ++_responseSeq);
    out.addByte(0x05);
    final json = utf8.encode(jsonEncode(value));
    AgentRpcCodec.writeVarint(out, json.length);
    out.add(json);
    return out.toBytes();
  }

  /// Push conversation rows as a desktop-initiated stream event
  /// (request-shaped frame, decoded by ConversationUpdate.fromAgentRpc).
  void pushRows(
    List<Map<String, dynamic>> pushed, {
    String sessionId = 'sess_fixture_0001',
    String workspacePath = '/proj',
  }) {
    final rpc = AgentRpc.call(
      seq: ++_responseSeq,
      service: 'zcode-agent',
      method: 'conversationStreamV4',
      args: [
        {
          'sessionId': sessionId,
          'workspacePath': workspacePath,
          'rows': pushed,
        },
      ],
    );
    _emitFrame(AgentRpcCodec.encode(rpc));
  }

  // --------------------------------------------------------------- scripts

  int stopRequests = 0;
  int createRequests = 0;
  int sendRequests = 0;

  /// Happy-path desktop: everything verified in S0 answers correctly.
  void installDefaults({Map<String, dynamic>? sessionSnapshot}) {
    handlers['zcode-agent.helloConversationV4'] = (s, _) => s.replyOk({
      'kind': 'hello',
      'connectionId': 'conn-1',
      'clientMode': 'web-remote-replayable',
      'capabilities': {'binaryFrames': false},
    });
    handlers['zcode-agent.initializeConversationV4'] = (s, _) =>
        s.replyOk({'kind': 'initialized', 'initialized': true});
    handlers['zcode-agent.subscribeConversationV4'] = (s, _) => s.replyOk({
      'ack': {'subscriptionId': 'sub-1', 'mode': 'snapshot', 'logEpoch': '1'},
    });
    handlers['zcode-agent.subscribeSessionsIndexV4'] = (s, _) => s.replyOk({
      'ack': {'subscriptionId': 'idx-1', 'mode': 'snapshot', 'logEpoch': '1'},
    });
    handlers['zcode-agent.conversationRowsRangeV4'] = (s, rpc) {
      final args = rpc.args.isNotEmpty ? rpc.args.first : null;
      final scope = args is Map ? args : const {};
      s.replyOk({
        'rows': s.rows,
        'sessionId': scope['sessionId'],
        'workspacePath': scope['workspacePath'],
      });
    };
    handlers['zcode-agent.sendConversationCommandV4'] = (s, rpc) {
      // The real desktop facade scopes writes as
      // `{workspacePath, workspaceIdentity, sessionId, envelope}`.  Keep
      // accepting the old bare-envelope form too so older contract fixtures
      // remain useful while the production bridge exercises the native shape.
      final scoped = rpc.args.first as Map;
      final cmd = scoped['envelope'] is Map
          ? scoped['envelope'] as Map
          : scoped;
      final type = cmd['type'];
      final commandId = cmd['commandId'];
      switch (type) {
        case 'createSession':
          s.createRequests++;
          s.replyOk({
            'commandId': commandId,
            'status': 'accepted',
            'revisionAtDecision': 1,
            'result': {'type': 'createSession', 'sessionId': 'sess_new_0002'},
          });
        case 'stop':
          s.stopRequests++;
          s.replyOk({
            'commandId': commandId,
            'status': 'accepted',
            'revisionAtDecision': 2,
          });
        case 'sendText':
          s.sendRequests++;
          s.replyOk({
            'commandId': commandId,
            'status': 'accepted',
            'revisionAtDecision': 3,
          });
        default:
          s.replyOk({
            'commandId': commandId,
            'status': 'accepted',
            'revisionAtDecision': 4,
          });
      }
    };
    handlers['zcode-session.readSession'] = (s, _) => s.replyOk(
      sessionSnapshot ??
          {
            'settings': {
              'model': {
                'current': {
                  'providerId': 'fixture-provider',
                  'modelId': 'flash',
                },
                'available': [
                  {
                    'ref': {
                      'providerId': 'fixture-provider',
                      'modelId': 'flash',
                    },
                    'label': 'Flash',
                    'reasoning': {
                      'enabled': true,
                      'levels': [
                        {'value': 'high', 'label': 'High'},
                        {'value': 'max', 'label': 'Max'},
                      ],
                    },
                  },
                ],
              },
              'thoughtLevel': {
                'enabled': true,
                'current': 'max',
                'available': [
                  {'value': 'high', 'label': 'High'},
                  {'value': 'max', 'label': 'Max'},
                ],
              },
              'mode': {'current': 'build'},
            },
            'projection': {
              'sessionId': 'sess_fixture_0001',
              'status': 'idle',
              'contextUsed': 100,
              'contextWindow': 1000,
            },
            'runtime': {'stateRevision': 7},
          },
    );
    handlers['zcode-session.setModel'] = (s, _) => s.replyOk({
      'sessionId': 'sess_fixture_0001',
      'appliedModelRuntimeRevision': 'rev-8',
      'changed': true,
    });
    handlers['zcode-session.setThoughtLevel'] = (s, _) => s.replyOk({
      'sessionId': 'sess_fixture_0001',
      'appliedModelRuntimeRevision': 'rev-9',
      'changed': true,
    });
    handlers['zcode-agent.getTaskTokenUsage'] = (s, _) => s.replyOk({});
    handlers['usage-stats.getAppUsageStats'] = (s, _) =>
        s.replyOk({'totalTokens': 10, 'requestCount': 2});
  }
}

class _PerConnectFactory implements RelaySocketFactory {
  _PerConnectFactory(this.server);

  final FakeRelayServer server;

  @override
  Future<RelaySocket> connect(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    // Reuse the pre-created socket for the very first connection so scripts
    // installed before connect() apply; afterwards every connect is fresh.
    if (server.connections > 0 || server.socket.closed) server._newSocket();
    server.connections++;
    return server.socket;
  }
}
