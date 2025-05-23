import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class ThingsboardDevice 
{
  String server;
  String token;
  MqttServerClient client;
  int rpcSubscriptionId = -1;
  int attributesSubscriptionId = -1;
  bool exitAfterDisconnect;
  int reconnectInterval = 60;
  double history = 0;

  ThingsboardDevice({this.server = 'cml.seapraha.cz', required this.token, this.exitAfterDisconnect = true})
  : client = MqttServerClient(server, '');

  Future<bool> connect() async 
  {
    client.setProtocolV311();
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.port = 1883;

    final connMess = MqttConnectMessage()
    //.withClientIdentifier(token)
    .authenticateAs(token, '')
    .startClean() // Non persistent session for testing
    .withWillQos(MqttQos.atLeastOnce);

    client.connectionMessage = connMess;

    // Navazani spojeni
    try 
    {
      log('Connecting to $server');
      await client.connect();
    } on Exception catch (e, s) 
    {
      logError(e.toString(), s.toString());
      client.disconnect();
      return false;
    }

    /// Spojeni navazano
    if (client.connectionStatus!.state == MqttConnectionState.connected) 
    {
      log('Client connected');
    } 
    else 
    {
      logError('Connection failed', '    state is ${client.connectionStatus!.state}');
      client.disconnect();
      return false;
    }

    // Zpracovani prijatych zprav
    client.updates!.listen(mqttReceivedList);

    // V případě potřeby můžete naslouchat publikovaným zprávám, které dokončily publikování.
    // handshake, který závisí na Qos. Jakákoli zpráva přijatá v tomto proudu dokončila své
    // publikační handshake se zprostředkovatelem.
    client.published!.listen(mqttPublished);

    // Predplatime si rpc
    rpcSubscriptionId = client.subscribe("v1/devices/me/rpc/request/+", MqttQos.atMostOnce)?.messageIdentifier ?? -1;

    // Predplatime si atributy
    attributesSubscriptionId =
    client.subscribe("v1/devices/me/attributes", MqttQos.atMostOnce)?.messageIdentifier ?? -1;

    return true;
  }

  bool disconnect() 
  {
    try 
    {
      client.disconnect();
      return true;
    } 
    catch (e, s) 
    {
      logError(e.toString(), s.toString());
      return false;
    }
  }

  int publishTelemetry(Map<String, dynamic> telemetry) 
  {
    //log('Publishing telemetry: $telemetry');
    final builder1 = MqttClientPayloadBuilder();
    if (history > 0.001)
    {
      final ts = nowTime.toUtc().millisecondsSinceEpoch;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        print('Publish date=$dt');

      final payload = { 'ts': ts, 'values': telemetry };
      builder1.addString(jsonEncode(payload));
    }
    else
    {
      builder1.addString(jsonEncode(telemetry));
    }
    return client.publishMessage("v1/devices/me/telemetry", MqttQos.atLeastOnce, builder1.payload!);
  }

  int publishAttributes(Map<String, dynamic> telemetry) 
  {
    //log('Publishing attributes: $telemetry');
    final builder1 = MqttClientPayloadBuilder();
    builder1.addString(jsonEncode(telemetry));
    return client.publishMessage("v1/devices/me/attributes", MqttQos.atLeastOnce, builder1.payload!);
  }

  int publishResponse(String request, Map<String, dynamic> telemetry) 
  {
    final builder1 = MqttClientPayloadBuilder();
    builder1.addString(jsonEncode(telemetry));
    return client.publishMessage(request.replaceAll('request', 'response'), MqttQos.atLeastOnce, builder1.payload!);
  }

  int getAttributes({String? clientKeys, String? sharedKeys}) 
  {
    log('Requesting attributes: clientKeys=$clientKeys, sharedKeys=$sharedKeys');
    final builder1 = MqttClientPayloadBuilder();
    final keys = <String, String>{};
    if (clientKeys != null) keys['clientKeys'] = clientKeys;
    if (sharedKeys != null) keys['sharedKeys'] = sharedKeys;
    builder1.addString(jsonEncode(keys));
    return client.publishMessage("v1/devices/me/attributes/request/1", MqttQos.atMostOnce, builder1.payload!);
  }

  void mqttReceivedList(List<MqttReceivedMessage<MqttMessage>> event) 
  {
    for (final msg in event) 
    {
      mqttReceived(msg);
    }
  }

  void mqttReceived(MqttReceivedMessage<MqttMessage> msg) 
  {
    try 
    {
      final message = msg.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(message.payload.message);
      logVerbose('Received message: topic=${msg.topic}, payload=$payload');

      if (msg.topic.contains('/attributes/response')) 
      {
        final attributes = jsonDecode(payload);
        logVerbose('Attributes response: $attributes');

        if (attributes is Map) 
        {
          for (final scope in ['client', 'shared']) 
          {
            if (attributes.containsKey(scope)) 
            {
              final map = attributes[scope];
              if (map is Map) 
              {
                map.forEach
                (
                  (key, value) 
                  {
                    attributeChanged(key, value, scope == 'client' ? TbAttributeScope.client : TbAttributeScope.shared);
                  }
                );
              }
            }
          }
        }
      } 
      else if (msg.topic.contains('/attributes')) 
      {
        final attributes = jsonDecode(payload);
        print('Attributes change: $attributes');
        if (attributes is Map) 
        {
          attributes.forEach
          (
            (key, value) 
            {
              attributeChanged(key, value, TbAttributeScope.shared);
            }
          );
        }
      } 
      else if (msg.topic.contains('/rpc/request')) 
      {
        final request = jsonDecode(payload);

        if (request.containsKey('method') && request.containsKey('params')) 
        {
          final response = mqttRpc(request['method'], request['params']);
          if (response != null) 
          {
            final request = msg.topic.replaceAll('request', 'response');
            publishResponse(request, response);
          }
        }
      }
    } 
    catch (e, s) 
    {
      logError(e.toString(), s.toString());
    }
  }

  dynamic mqttRpc(String method, dynamic params) 
  {
    log('RPC call: $method, params: $params');
    return {'status': 'OK'};
  }

  void attributeChanged(String key, dynamic value, TbAttributeScope scope) 
  {
    log('Attribute changed: $key=$value, scope=$scope');
  }

  void mqttPublished(MqttPublishMessage message) 
  {
    try 
    {
      logPublished
      (
        'Published: '
        'topic: ${message.variableHeader!.topicName}, '
        'id: ${message.variableHeader!.messageIdentifier}, '
        'Qos: ${message.header!.qos}\r\n'
        '  payload: ${String.fromCharCodes(message.payload.message)}'
      );
    } 
    catch (e, s) 
    {
      logError(e.toString(), s.toString());
    }
  }

  Future run() async 
  {
    bool reconnect;

    do 
    {
      reconnect = false;

      try 
      {
        if (!await connect()) 
        {
          print('Failed to connect to $server');
          reconnect = deviceNoConnected();
          if (!reconnect) 
          {
            return;
          }
        }

        try 
        {
          deviceInit();

          final f = deviceRun();

          final fErr = f.catchError
          (
            (e, s) 
            {
              logError(e.toString(), s.toString());
              return deviceException(e as Exception);
            }
          );

          reconnect = await Future.any([f, fErr]);
        } 
        catch (e, s) 
        {
          logError(e.toString(), s.toString());
          reconnect = deviceException(e as Exception);
        } 
        finally 
        {
          disconnect();
        }
      } 
      catch (e, s) 
      {
        logError(e.toString(), s.toString());
      }

      if (reconnect) 
      {
        log('Reconnecting in $reconnectInterval seconds');
        await Future.delayed(Duration(seconds: reconnectInterval));
      }
    } 
    while (reconnect);
  }

  void deviceInit() {}

  Future<bool> deviceRun() async 
  {
    return false;
  }

  bool deviceException(Exception e) 
  {
    return !exitAfterDisconnect;
  }

  bool deviceNoConnected() 
  {
    return !exitAfterDisconnect;
  }

  void logError(String message, String stack) 
  {
    print('Error: $message\r\n$stack');
  }

  void log(String text) 
  {
    print(text);
  }

  void logVerbose(String text) 
  {
    print(text);
  }

  void logPublished(String text) 
  {
    //print(text);
  }

  DateTime get nowTime => DateTime.now().add(Duration(seconds: -history.toInt()));
}

enum TbAttributeScope { client, shared }