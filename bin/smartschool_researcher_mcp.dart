import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/dev/dev_inspector.dart';

Future<void> main(List<String> args) async {
  final server = _SmartschoolResearcherServer(
    defaultCredentialsPath: _parseDefaultCredentialsPath(args),
  );
  await server.run();
}

String? _parseDefaultCredentialsPath(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--credentialsPath=')) {
      return arg.substring('--credentialsPath='.length).trim();
    }
    if (arg == '--credentialsPath' && i + 1 < args.length) {
      return args[i + 1].trim();
    }
  }
  return null;
}

class _SmartschoolResearcherServer {
  _SmartschoolResearcherServer({this.defaultCredentialsPath});

  final String? defaultCredentialsPath;
  DevInspector? _inspector;
  Credentials? _credentials;

  final Map<String, dynamic> _toolDefinitions = {
    'login': {
      'name': 'login',
      'description':
          'Login to Smartschool using credentials.yml or inline credentials.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'credentialsPath': {
            'type': 'string',
            'description':
                'Optional path to credentials.yml. Defaults to auto-discovery.',
          },
          'username': {
            'type': 'string',
            'description':
                'Optional username override. Must be combined with password and mainUrl.',
          },
          'password': {
            'type': 'string',
            'description': 'Optional password override.',
          },
          'mainUrl': {
            'type': 'string',
            'description':
                'Optional Smartschool hostname override (e.g. school.smartschool.be).',
          },
          'mfa': {
            'type': 'string',
            'description': 'Optional MFA secret/date override.',
          },
        },
      },
    },
    'login_status': {
      'name': 'login_status',
      'description':
          'Check whether the server currently has an authenticated Smartschool session.',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
    'get_page': {
      'name': 'get_page',
      'description': 'Fetch a Smartschool page using GET.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path including query string, e.g. /?module=Messages',
          },
          'maxBodyChars': {
            'type': 'integer',
            'description': 'Optional response body truncation length.',
          },
        },
        'required': ['path'],
      },
    },
    'post_form': {
      'name': 'post_form',
      'description':
          'Send a form-urlencoded POST request and inspect the response.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'fields': {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
          'maxBodyChars': {'type': 'integer'},
        },
        'required': ['path', 'fields'],
      },
    },
    'request': {
      'name': 'request',
      'description':
          'Send a generic HTTP request (GET/POST/etc.) for endpoint research.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'method': {'type': 'string'},
          'path': {'type': 'string'},
          'headers': {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
          'query': {'type': 'object', 'additionalProperties': true},
          'data': {
            'description': 'Arbitrary request payload (JSON/string/object).',
          },
          'contentType': {'type': 'string'},
          'isJson': {'type': 'boolean'},
          'maxBodyChars': {'type': 'integer'},
        },
        'required': ['method', 'path'],
      },
    },
    'get_json': {
      'name': 'get_json',
      'description': 'Fetch endpoint with Accept: application/json and parse.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'maxBodyChars': {'type': 'integer'},
        },
        'required': ['path'],
      },
    },
  };

  Future<void> run() async {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }

      Map<String, dynamic> request;
      try {
        request = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        await _writeJsonRpcError(
          id: null,
          code: -32700,
          message: 'Parse error: invalid JSON input',
        );
        continue;
      }

      final id = request['id'];
      final method = request['method']?.toString();
      final params = request['params'];

      if (method == null) {
        await _writeJsonRpcError(
          id: id,
          code: -32600,
          message: 'Invalid request: missing method',
        );
        continue;
      }

      try {
        switch (method) {
          case 'initialize':
            await _writeJsonRpcResult(id, {
              'protocolVersion': '2024-11-05',
              'serverInfo': {
                'name': 'smartschool-researcher',
                'version': '0.1.0',
              },
              'capabilities': {
                'tools': {'listChanged': false},
              },
            });
            break;

          case 'notifications/initialized':
            break;

          case 'tools/list':
            await _writeJsonRpcResult(id, {
              'tools': _toolDefinitions.values.toList(),
            });
            break;

          case 'tools/call':
            final args = (params as Map<String, dynamic>? ?? {});
            final name = args['name']?.toString() ?? '';
            final input =
                (args['arguments'] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
            final result = await _callTool(name, input);
            await _writeJsonRpcResult(id, result);
            break;

          default:
            await _writeJsonRpcError(
              id: id,
              code: -32601,
              message: 'Method not found: $method',
            );
        }
      } catch (error, stackTrace) {
        await _writeJsonRpcResult(id, {
          'content': [
            {
              'type': 'text',
              'text': _encodePretty({
                'error': error.toString(),
                'stackTrace': stackTrace.toString(),
              }),
            },
          ],
          'isError': true,
        });
      }
    }
  }

  Future<Map<String, dynamic>> _callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'login':
        final credentialsPath =
            args['credentialsPath']?.toString() ?? defaultCredentialsPath;
        final username = args['username']?.toString();
        final password = args['password']?.toString();
        final mainUrl = args['mainUrl']?.toString();
        final mfa = args['mfa']?.toString();

        if (username != null || password != null || mainUrl != null) {
          if (username == null || password == null || mainUrl == null) {
            throw StateError(
              'username/password/mainUrl must all be provided together',
            );
          }
          _credentials = AppCredentials(
            username: username,
            password: password,
            mainUrl: mainUrl,
            mfa: mfa,
          );
        } else {
          _credentials = PathCredentials(filename: credentialsPath);
        }

        _credentials!.validate();
        _inspector = await DevInspector.create(_credentials!);

        Map<String, dynamic>? user;
        try {
          user = await _inspector!.getAuthenticatedUser();
        } catch (_) {
          // authenticatedUser requires doAccountVerification(); not always
          // available — safe to omit from the response.
        }
        final response = {
          'ok': true,
          if (user != null) 'authenticatedAs': user,
          'mainUrl': _credentials!.mainUrl,
        };

        return _toolResponse(response);

      case 'login_status':
        final inspector = _inspector;
        final credentials = _credentials;
        if (inspector == null || credentials == null) {
          return _toolResponse({
            'loggedIn': false,
            'reason': 'No active session. Call login first.',
          });
        }

        try {
          final user = await inspector.getAuthenticatedUser();
          return _toolResponse({
            'loggedIn': true,
            'mainUrl': credentials.mainUrl,
            'authenticatedAs': user,
          });
        } catch (error) {
          return _toolResponse({
            'loggedIn': false,
            'mainUrl': credentials.mainUrl,
            'reason': 'Session check failed',
            'error': error.toString(),
          });
        }

      case 'get_page':
        final inspector = _requireInspector();
        final path = _requiredString(args, 'path');
        final maxBodyChars = _optionalInt(args, 'maxBodyChars');
        final result = await inspector.getPage(path);
        return _toolResponse(result.toMap(maxBodyChars: maxBodyChars));

      case 'post_form':
        final inspector = _requireInspector();
        final path = _requiredString(args, 'path');
        final fieldsRaw = args['fields'];
        if (fieldsRaw is! Map) {
          throw StateError(
            'fields must be an object of string key/value pairs',
          );
        }
        final fields = <String, String>{
          for (final entry in fieldsRaw.entries)
            entry.key.toString(): entry.value?.toString() ?? '',
        };
        final maxBodyChars = _optionalInt(args, 'maxBodyChars');
        final result = await inspector.postRequest(path, formData: fields);
        return _toolResponse(result.toMap(maxBodyChars: maxBodyChars));

      case 'request':
        final inspector = _requireInspector();
        final method = _requiredString(args, 'method');
        final path = _requiredString(args, 'path');

        final headers = _toStringMap(args['headers']);
        final query = _toDynamicMap(args['query']);
        final maxBodyChars = _optionalInt(args, 'maxBodyChars');
        final contentType = args['contentType']?.toString();
        final isJson = args['isJson'] == true;

        final result = await inspector.request(
          method,
          path,
          headers: headers,
          query: query,
          data: args['data'],
          contentType: contentType,
          isJson: isJson,
        );

        return _toolResponse(result.toMap(maxBodyChars: maxBodyChars));

      case 'get_json':
        final inspector = _requireInspector();
        final path = _requiredString(args, 'path');
        final maxBodyChars = _optionalInt(args, 'maxBodyChars');
        final result = await inspector.getJson(path);
        return _toolResponse(result.toMap(maxBodyChars: maxBodyChars));

      default:
        throw StateError('Unknown tool: $name');
    }
  }

  DevInspector _requireInspector() {
    final inspector = _inspector;
    if (inspector == null) {
      throw StateError('Not logged in. Call tool "login" first.');
    }
    return inspector;
  }

  String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString();
    if (value == null || value.isEmpty) {
      throw StateError('$key is required');
    }
    return value;
  }

  int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  Map<String, String>? _toStringMap(Object? value) {
    if (value == null) return null;
    if (value is! Map) {
      throw StateError('Expected object for map argument');
    }
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  Map<String, dynamic>? _toDynamicMap(Object? value) {
    if (value == null) return null;
    if (value is! Map) {
      throw StateError('Expected object for query argument');
    }
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  Map<String, dynamic> _toolResponse(Map<String, dynamic> payload) {
    return {
      'content': [
        {'type': 'text', 'text': _encodePretty(payload)},
      ],
      'isError': false,
    };
  }

  String _encodePretty(Object value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Future<void> _writeJsonRpcResult(Object? id, Object result) async {
    final resp = {'jsonrpc': '2.0', 'id': id, 'result': result};
    stdout.writeln(jsonEncode(resp));
  }

  Future<void> _writeJsonRpcError({
    required Object? id,
    required int code,
    required String message,
  }) async {
    final resp = {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
    stdout.writeln(jsonEncode(resp));
  }
}
