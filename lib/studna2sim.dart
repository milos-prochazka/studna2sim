import 'dart:collection';

import 'package:studna2sim/json_utils.dart';
import 'package:thingsboard_client/thingsboard_client.dart';
import 'thingsboard_device.dart';
import 'dart:math' as math;

void studna_main({required String server, required String user, required String password}) async 
{
  final tbClient = ThingsboardClient(server);
  await tbClient.login(LoginRequest(user, password));

  print('isAuthenticated=${tbClient.isAuthenticated()}');

  print('authUser: ${tbClient.getAuthUser()}');

  final currentUserDetails = await tbClient.getUserService().getUser();
  print('currentUserDetails: $currentUserDetails');
}

Future studnaMqtt({required String server, required String token, dynamic config}) async 
{
  final mode =
  stringToEnum(StudnaDeviceMode.values, getString(getItemFromPath(config, ['variant']), defaultValue: 'single'));
  final upSpeed = getDouble(getItemFromPath(config, ['up_speed']), defaultValue: 0.02);
  final downSpeed = getDouble(getItemFromPath(config, ['down_speed']), defaultValue: 0.005);
  final historyM = 60* getDouble(getItemFromPath(config, ['history_minutes']), defaultValue: 0);
  final historyH = 3600* getDouble(getItemFromPath(config, ['history_hours']), defaultValue: 0);
  final historyD = 86400* getDouble(getItemFromPath(config, ['history_days']), defaultValue: 0);

  final history = historyM + historyH + historyD;

  final device = StudnaDevice(server: server, token: token, mode: mode, upSpeed: upSpeed, downSpeed: downSpeed,history: history);

  await device.run();
}

class StudnaDevice extends ThingsboardDevice 
{
  double upSpeed, downSpeed;
  double solarSpeed = 0;
  int solarTimer = 10;
  bool hasGsm = false;
  String name = 'studna2sim';
  double updateInterval = 60.0;
  DateTime startTime = DateTime.now();
  DateTime lastTelemetryTime = DateTime.now();
  double ain1 = 3.3;
  double ain1State = 0.0;
  StudnaAinZone ain1Zone = StudnaAinZone.ok;
  double ain2 = 0.0;
  double ain2State = 0.0;
  double batteryPower = 100.0;
  double batteryStep = 0.001;
  StudnaAinZone ain2Zone = StudnaAinZone.ok;
  bool din1 = false;
  bool din2 = false;
  bool alterDout1 = true;
  bool stateDout1 = false;
  bool get dout1 => stateDout1 && alterDout1;
  var _manualDout1End = DateTime(0);
  var _manualOut1Start = 0.0;
  bool _manualDout1Override = false;
  bool stateDout2 = false;
  bool alterDout2 = true;
  bool get dout2 => stateDout2 && alterDout2;
  var _manualDout2End = DateTime(0);
  var _manualOut2Start = 0.0;
  bool _manualDout2Override = false;
  double cnt1Acum = 0;
  int cnt1 = 0;
  int cnt1Past = 0;
  String wifi = '';
  String gsm = '';
  int system = 0;
  bool hasWifi = true;
  bool hasBattery = false;
  bool hasAin1 = true;
  bool hasAin2 = false;
  bool hasDin1 = false;
  bool hasDin2 = false;
  bool hasDout1 = true;
  bool hasDout2 = false;
  bool hasCnt1 = false;
  final _rnd = math.Random();

  int currentHour = -1;

  _StudnaOutputMode _dout1Mode = _StudnaOutputMode('dout1', {'mode': 'manual'});
  final _StudnaOutputState _dout1State = _StudnaOutputState();
  _StudnaOutputMode _dout2Mode = _StudnaOutputMode('dout2', {'mode': 'manual'});
  final _StudnaOutputState _dout2State = _StudnaOutputState();
  _StudnaAinMode _ain1Mode = _StudnaAinMode('ain1', {'units': 'm'});
  _StudnaAinMode _ain2Mode = _StudnaAinMode('ain2', {'units': 'm'});

  Map config = {};

  bool publishRequest = true;
  List<Object> logTelemetry = [];

  int firmwareState = -1;

  String iso8601()
  {
    final now = nowTime;
    if (now.isUtc)
    {
      return now.toIso8601String();
    }
    else
    {
      var offset = now.timeZoneOffset;
      var h = offset.inHours;
      var m = offset.inMinutes.remainder(60);
      return '${now.toIso8601String()}${h >= 0 ? '+' : '-'}${h.abs().toString().padLeft(2, '0')}:${m.abs().toString().padLeft(2, '0')}';
    }
  }

  static double round(double value, int decimals) 
  {
    final fac = math.pow(10, decimals);
    return (value * fac).round() / fac;
  }

  /// Publish telemetry data to ThingsBoard
  void publish() 
  {
    final uptime = nowTime.difference(startTime).inSeconds;

    final dout1ManualOverride = _dout1Mode.mode != _StudnaOutputModeEnum.manual && _manualDout1Override;
    final dout1Mode = dout1ManualOverride ? _StudnaOutputModeEnum.manual : _dout1Mode.mode;

    final dout2ManualOverride = _dout2Mode.mode != _StudnaOutputModeEnum.manual && _manualDout2Override;
    final dout2Mode = dout2ManualOverride ? _StudnaOutputModeEnum.manual : _dout2Mode.mode;

    final telemetry = 
    {
      "version": 2,
      if (hasAin1) "ain1": {"str": ain1.toStringAsFixed(2), "units": "m", "zone": ain1Zone.name},
      if (hasAin1) "ain1_v": round(ain1,4),
      if (hasAin2) "ain2": {"str": ain2.toStringAsFixed(2), "units": "m", "zone": ain1Zone.name},
      if (hasAin2) "ain2_v": round(ain2,4),
      if (hasDin1) "din1": {"str": din1 ? "1" : "0", "value_fast": false},
      if (hasDin1) "din1_v": din1 ? 1 : 0,
      if (hasDin2) "din2": {"str": din2 ? "1" : "0", "value_fast": true},
      if (hasDin2) "din2_v": din2 ? 1 : 0,
      if (hasDout1)
      "dout1": 
      {
        "str": dout1 ? "1" : "0",
        "mode": dout1Mode.name,
        "regulation_source":"ain1",
        "manual_override": dout1ManualOverride,
        "alternating": _dout1Mode.alternating.enabled
      },
      if (hasDout1) "dout1_v": dout1 ? 1 : 0,
      if (hasDout2)
      "dout2": 
      {
        "str": dout2 ? "1" : "0",
        "mode": dout2Mode.name,
        "regulation_source":"ain1",
        "manual_override": dout2ManualOverride,
        "alternating": _dout2Mode.alternating.enabled
      },
      if (hasDout2) "dout2_v": dout2 ? 1 : 0,
      if (hasCnt1) "cnt1": {"value": cnt1, "past_value": cnt1Past, "units": "l"},
      if (hasCnt1) "cnt1_v": cnt1,
      //"log": {"name": "mqttConnect", "content": "OK"},
      if (hasWifi) "wifi": {"state": "connected", "signal_percent": _rnd.nextInt(100), "ssid": "seapraha-guest"},
      if (hasGsm)
      "gsm": 
      {
        "state": "registered",
        "signal_percent": _rnd.nextInt(100),
        "operator": "Vodafone CZ",
        "operator_id": "23002",
        "credit": "-"
      },
      //if (hasBattery) "power": {"battery_charge": 100, "power_supply": "battery"},
      if (hasBattery) "batt": {"capacity": round(batteryPower,2), "voltage": round(3.4+batteryPower*0.008,3)},
      "system": {"uptime_sec": uptime, "v5v": round(4.85 + _rnd.nextDouble() * 0.2,2)},
    };

    publishTelemetry(telemetry);
  }

  void publishLog()
  {
    if (logTelemetry.isNotEmpty)
    {
      final telemetry = 
      {
        "log": logTelemetry.first
      };

      publishTelemetry(telemetry);
      logTelemetry.removeAt(0);
    }
  }

  StudnaDevice
  (
    {super.server,
      required super.token,
      super.exitAfterDisconnect = false,
      StudnaDeviceMode mode = StudnaDeviceMode.single,
      this.upSpeed = 0.02,
      this.downSpeed = 0.005,
      double history = 0.0,}
  ) 
  {
    this.history= history;
    startTime = nowTime;
    lastTelemetryTime = nowTime;

    switch (mode) 
    {
      case StudnaDeviceMode.single:
      {
        hasAin1 = true;
        hasAin2 = false;
        hasDin1 = false;
        hasDin2 = false;
        hasDout1 = true;
        hasDout2 = false;
        hasCnt1 = false;
        break;
      }

      case StudnaDeviceMode.duo:
      {
        hasAin1 = true;
        hasAin2 = false;
        hasDin1 = false;
        hasDin2 = false;
        hasDout1 = true;
        hasDout2 = true;
        hasCnt1 = false;
        break;
      }

      case StudnaDeviceMode.max:
      {
        hasAin1 = true;
        hasAin2 = true;
        hasDin1 = true;
        hasDin2 = true;
        hasDout1 = true;
        hasDout2 = true;
        hasCnt1 = true;
        break;
      }

      case StudnaDeviceMode.solar:
      {
        hasAin1 = true;
        hasAin2 = false;
        hasDin1 = false;
        hasDin2 = false;
        hasDout1 = false;
        hasDout2 = false;
        hasCnt1 = false;
        hasBattery = true;
        break;
      }
    }
  }

  @override
  void deviceInit() 
  {
    getAttributes(sharedKeys: 'full_config', clientKeys: 'time');
    publishRequest = true;
  }

  double get weekSecond 
  {
    final now = nowTime;
    return 86400.0 * (now.weekday - DateTime.monday) + now.hour * 3600.0 + now.minute * 60.0 + now.second;
  }

  double get weekMinute 
  {
    final now = nowTime;
    return 1440.0 * (now.weekday - DateTime.monday) + now.hour * 60.0 + now.minute;
  }

  @override
  void attributeChanged(String key, dynamic value, TbAttributeScope scope) 
  {
    log('Attribute changed: $key=$value, scope=$scope');

    switch (key) 
    {
      case 'full_config':
      {
        if (value is Map) 
        {
          _manualDout1Override = false;
          _manualDout2Override = false;
          config = value;
          final system = getItemFromPath(config, ['system']);
          name = getString(getItemFromPath(system, ['station_name']), defaultValue: name);
          updateInterval = getDouble(getItemFromPath(system, ['update_interval']), defaultValue: 60.0);

          if (config case {'device': {'dout1': Map dout1}}) 
          {
            _dout1Mode = _StudnaOutputMode('dout1', dout1);
          }
          if (config case {'device': {'dout2': Map dout2}}) 
          {
            _dout2Mode = _StudnaOutputMode('dout2', dout2);
          }
          if (config case {'device': {'ain1': Map ain1}}) 
          {
            _ain1Mode = _StudnaAinMode('ain1', ain1);
          }
          if (config case {'device': {'ain2': Map ain2}}) 
          {
            _ain2Mode = _StudnaAinMode('ain2', ain2);
          }
        }
      }
      break;
    }
  }

  Future<bool> publishVersion(String version) async 
  {
    final attr = 
    {
      "title": "S-ESTUDNA2",
      "version": version,
	    "cfg_wanted_version":6,
    };

    publishAttributes(attr);
    return true;
  }

  @override
  Future<bool> deviceRun() async 
  {
      logTelemetry.add
      (
        {
          "message" : "start up. version v9.000 ",
          "type" : "debug",
        }
      );

    publishVersion('v9.000');

    while (true) 
    {
      _control();
      _state();
      if (publishRequest) 
      {
        publishRequest = false;
        publish();
        if (history > 0.0) 
        {
          await Future.delayed(Duration(milliseconds: 100));
        }
      }
      publishLog();
    
      if (history > 0.0) 
      {
        history-= 1.0;
      }
      else
      {
        await Future.delayed(Duration(seconds: 1));
      }
    }
  }

  void _state() 
  {
    if ((ain1 - ain1State).abs() > 0.1) 
    {
      publishRequest = true;
    }

    if ((ain2 - ain2State).abs() > 0.1) 
    {
      publishRequest = true;
    }

    if (nowTime.difference(lastTelemetryTime).inSeconds >= updateInterval) 
    {
      publishRequest = true;
    }

    if (publishRequest) 
    {
      lastTelemetryTime = nowTime;
      ain1State = ain1;
      ain2State = ain2;
    }
  }

  void _control() 
  {
    StudnaAinZone controlAinLevel(StudnaAinZone currentLevel, double value, _StudnaAinMode mode) 
    {
      if (mode.inRange(value, currentLevel)) 
      {
        return currentLevel;
      } 
      else 
      {
        for (final level in StudnaAinZone.values) 
        {
          if (mode.inRange(value, level)) 
          {
            return level;
          }
        }

        if (value < mode.levelLimits[0].$1) 
        {
          return StudnaAinZone.critical;
        } 
        else 
        {
          return StudnaAinZone.high;
        }
      }
    }

    double controlAin(double level, bool output, bool hasDout, _StudnaOutputMode outputMode) 
    {
      if (!hasDout) 
      {
        level += solarSpeed;
        if (--solarTimer <= 0) 
        {
          solarSpeed = (_rnd.nextDouble() - 0.5) * upSpeed;
          solarTimer = _rnd.nextInt(4 * 3600);
        }

        if (level > 5.0 || level < 0.5) 
        {
          solarSpeed = -solarSpeed;
          level += 2.5 * solarSpeed;
        }
      } 
      else if (outputMode.mode == _StudnaOutputModeEnum.lower) 
      {
        level += (output) ? upSpeed * (5.0 - level) : downSpeed * (0.5 - level);
      } 
      else 
      {
        level += (output) ? upSpeed * (0.5 - level) : downSpeed * (5.0 - level);
      }

      return level;
    }

    bool alternatingDout
    (
      { required bool output,
        required _StudnaOutputMode outputMode,
        required _StudnaOutputState outputState,
        required bool manualOverride}
    ) 
    {
      if (!manualOverride) 
      {
        if (outputMode.alternating.enabled) 
        {
          final now = nowTime;
          final timeout = outputMode.alternating.timeout;
          final active = outputMode.alternating.active;
          final time = now.difference(outputState.alternatingTime).inSeconds;
          final result = time < active || time > timeout;
          if (output && result && time > timeout) 
          {
            outputState.alternatingTime = now;
          }
          return result;
        }
      }

      return true;
    }

    bool controlDout
    (
      {required bool output,
        required StudnaAinZone zone,
        required double level,
        required _StudnaOutputMode outputMode,
        required bool manualOverride}
    ) 
    {
      void upperLowerMode()
      {
          switch (outputMode.regulatorSource)
          {
            case 'ain1':
            {
              level = ain1;
            }
            break;

            case 'ain2':
            {
              level = ain2;
            }
            break;

            case 'din1':
            {
              level = din1 ? 10000.0 : -10000.0;
            }
            break;

            case 'din2':
            {
              level = din2 ? 10000.0 : -10000.0;
            }
            break;

            case 'din1+din2':
            {
              if (din1 && din2) 
              {
                level = 10000.0;
              } 
              else if (!din1 && !din2) 
              {
                level = -10000.0;
              } 
              else 
              {
                level = 0.5*(outputMode.maximum+outputMode.minimum);
              }
            }
            break;

          }

      }

      if (!manualOverride) 
      {

        switch (outputMode.mode) 
        {
          case _StudnaOutputModeEnum.manual:
          {
            return false;
          }

          case _StudnaOutputModeEnum.upper:
          {
            upperLowerMode();
            if (level > outputMode.maximum) 
            {
              return true;
            } 
            else if (level < outputMode.minimum) 
            {
              return false;
            } 
            else 
            {
              return output;
            }
          }

          case _StudnaOutputModeEnum.lower:
          {
            upperLowerMode();
            if (level < outputMode.minimum) 
            {
              return true;
            } 
            else if (level > outputMode.maximum) 
            {
              return false;
            } 
            else 
            {
              return output;
            }
          }

          case _StudnaOutputModeEnum.scheduler:
          {
            List<_SchedulerMode> schedulers = [];
            const hourMinutes = 60.0;
            const dayMinutes = 1440.0;
            const weekMinutes = 1440.0 * 7.0;
            double begin = 0, end = 0;
            final weekMinute = this.weekMinute;

            final _SchedulerMode? scheduler1 = switch (zone) 
            {
              StudnaAinZone.ok || StudnaAinZone.high => outputMode.schedulerOkHigh,
              StudnaAinZone.low => outputMode.schedulerCriticalLow,
              _ => null
            };

            if (scheduler1?.enabled ?? false) 
            {
              schedulers.add(scheduler1!);
            }

            for (final scheduler in outputMode.scheduler2) 
            {
              if (scheduler.enabled && scheduler.levels.contains(zone)) 
              {
                schedulers.add(scheduler);
              }
            }

            for (final scheduler in schedulers) 
            {
              for (int day = 0; day < 7; day++) 
              {
                if (scheduler.days & (1 << day) != 0) 
                {
                  begin = dayMinutes * day + hourMinutes * scheduler.hours + scheduler.minutes;
                  end = begin + scheduler.interval;
                  if (weekMinute >= begin && weekMinute < end) 
                  {
                    return true;
                  }
                }
              }

              if (end > weekMinutes) 
              {
                end -= weekMinutes;
                if (weekMinute < end) 
                {
                  return true;
                }
              }
            }

            return false;
          }

          default:
          {
            return output;
          }
        }
      }

      return output;
    }

    bool testManualEnd(DateTime manualEnd, double level, double manualStart, _StudnaOutputMode outputMode) 
    {
      var result = nowTime.isAfter(manualEnd);
      if (outputMode.maxLevelChange != 0.0) 
      {
        result |= (level - manualStart).abs() > outputMode.maxLevelChange.abs();
      }

      return result;
    }


    /////////////// Simulation /////////////////////////////////////////////////
    
    final oldDout1 = dout1;
    final oldDout2 = dout2;
    final oldDin1 = din1;
    final oldDin2 = din2;

    {
      batteryPower += batteryStep;
      if (batteryPower > 100.0) 
      {
        batteryPower = 100.0;
        batteryStep = -0.0003;
      } 
      else if (batteryPower < 0.0) 
      {
        batteryPower = 0.0;
        batteryStep = 0.001;
      }

      final ain1Prev = ain1;
      final ain2Prev = ain2;

      ain1 = controlAin(ain1, dout1, hasDout1, _dout1Mode);

      if (hasAin2) 
      {
        ain2 = controlAin(ain2, dout2, hasDout2, _dout2Mode);
      }

      ain1Zone = controlAinLevel(ain1Zone, ain1, _ain1Mode);

      ain2Zone = controlAinLevel(ain2Zone, ain2, _ain2Mode);

      if (hasDout1) 
      {
        _manualDout1Override =
        _manualDout1Override && !testManualEnd(_manualDout1End, ain1, _manualOut1Start, _dout1Mode);
        _setDout1
        (
          controlDout
            (
              output: stateDout1, zone: ain1Zone, level: ain1, outputMode: _dout1Mode, manualOverride: _manualDout1Override
            ),
        );

        alterDout1 = alternatingDout
          (
            output: stateDout1,
            outputMode: _dout1Mode,
            outputState: _dout1State,
            manualOverride: false
          );
      }

      if (hasDout2) 
      {
        _manualDout2Override =
        _manualDout2Override && !testManualEnd(_manualDout2End, ain2, _manualOut2Start, _dout2Mode);
        _setDout2
        (
          controlDout
            (
              output: stateDout2, zone: ain2Zone, level: ain2, outputMode: _dout2Mode, manualOverride: _manualDout2Override
            ),
        );

        alterDout2 = alternatingDout
          (
            output: stateDout2,
            outputMode: _dout2Mode,
            outputState: _dout2State,
            manualOverride: false
          );
      }


      if (hasCnt1) 
      {
        cnt1Acum += 100.0 * ((ain1 - ain1Prev).abs() + (ain2 - ain2Prev).abs());
        int icnt = cnt1Acum.toInt();
        if (icnt > 0) 
        {
          cnt1Past = cnt1;
          cnt1 += icnt;
          cnt1Acum -= icnt;
        }
      }

      if (ain1 > 2.35) din1 = true;
      if (ain1 < 2.25) din1 = false;

      if (ain1 > 2.85) din2 = true;
      if (ain1 < 2.75) din2 = false;
    }

    if (oldDout1 != dout1 || oldDout2 != dout2 || oldDin1 != din1 || oldDin2 != din2) 
    {
      publishRequest = true;
    }

    var now = nowTime;
    if (currentHour != now.hour) 
    {
      currentHour = now.hour;
      logTelemetry.add
      (
        {
          "message" : "current time ${iso8601()}",
          "type" : "info",
        }
      );
    }

    if (firmwareState >= 0)
    {
      _firmware();
    }
    ///////////////////////////////////////////////////////////////////////
  }

  DateTime _manualEndTime(_StudnaOutputMode mode)
    {
      if (mode.mode == _StudnaOutputModeEnum.manual && mode.maxTime < 1.0) 
      {
        return nowTime.add(Duration(days: 3660));
      } 
      else 
      {
      return nowTime.add(Duration(seconds: mode.maxTime.toInt()));
      }
    }


  @override
  dynamic mqttRpc(String method, dynamic params) 
  {
    void setOut(int index, dynamic value) 
    {
      switch (index) 
      {
        case 1:
        {
          _setDout1(value);
          _manualDout1End = _manualEndTime(_dout1Mode);
          _manualOut1Start = ain1;
          _manualDout1Override = stateDout1 || _dout1Mode.mode != _StudnaOutputModeEnum.manual;
        }
        break;

        case 2:
        {
          _setDout2(value);
          _manualDout2End = _manualEndTime(_dout2Mode);
          _manualOut2Start = ain2;
          _manualDout2Override = stateDout2 || _dout2Mode.mode != _StudnaOutputModeEnum.manual;
        }
        break;
      }
    }

    
    final result = {'status': 'OK'};
    log('RPC call: $method, params: $params');
    logTelemetry.add
    (
      {
        "action" : "RPC IN",
        "content": "$method: $params",
        "type" : "event",
      }
    );
    switch (method.trim().toLowerCase()) 
    {
      case 'setdout1':
      {
        setOut(1,params);
      }
      break;

      case 'setdout2':
      {
        setOut(2,params);
      }
      break;

      case 'set':
      {
        if (params case [String element,int index ,Object value]) 
        {
          switch (element)
          {
              case 'dout':
                switch (value.toString().toLowerCase())
                {
                    case 'on':
                    {
                      setOut(index, true);
                    }
                    break;

                    case 'off':
                    {
                      setOut(index, false);
                    }
                    break;
                }
                
          }
        } 
      }
      break;

      case 'firmware':
      {
        if (firmwareState < 0) 
        {
          firmwareState = 0;
        }
      }
      break;
    }

    return result;


  }

  void _setDout1(dynamic value) 
  {
    final v = getBool(value);
    if (v != stateDout1) 
    {
      stateDout1 = v;
      publishRequest = true;
    }
  }

  void _setDout2(dynamic value) 
  {
    final v = getBool(value);
    if (v != stateDout2) 
    {
      stateDout2 = v;
      publishRequest = true;
    }
  }

  void _firmware()
  {
    switch (firmwareState++)
    {
      case 1:
      {
        logTelemetry.add
        (
          {"fw_state":"DOWNLOADING","type":"firmware"}
        );
      }
      break;

      case 20:
      {
        logTelemetry.add
        (
          {"fw_state":"DOWNLOADED","type":"firmware"}
        );
      }
      break;

      case 21:
      {
        logTelemetry.add
        (
          {"fw_state":"UNPACKING","type":"firmware"}
        );
      }
      break;

      case 25:
      {
        logTelemetry.add
        (
          {"fw_state":"UNPACKED","type":"firmware"}
        );
      }
      break;

      case 28:
      {
        logTelemetry.add
        (
          {"fw_state":"VERIFIED","type":"firmware"}
        );
      }
      break;

      case 29:
      {
        logTelemetry.add
        (
          {"fw_state":"VERIFIED","type":"firmware"}
        );
      }
      break;

      case 30:
      {
        logTelemetry.add
        (
          {"fw_state":"RESTARTING","type":"firmware"}
        );
      }
      break;

      default:
      if (firmwareState > 33)
      {
        firmwareState = -1;
        logTelemetry.add
        (
          {"message":"start up. version v10.123 ","type":"debug"}
        );
        publishVersion('v10.123');
      }
      break;
    }
  }
}

enum StudnaDeviceMode 
{
  single,
  duo,
  max,
  solar;
}

class _StudnaOutputState 
{
  DateTime alternatingTime = DateTime(2000);
}

class _StudnaOutputMode 
{
  String name;
  _StudnaOutputModeEnum mode;
  double minimum = 0.0;
  double maximum = 5.0;
  String regulatorSource;
  double maxLevelChange = 1.0;
  double maxTime = 60.0;
  _SchedulerMode schedulerOkHigh;
  _SchedulerMode schedulerCriticalLow;
  _AlternatigMode alternating;
  List<_SchedulerMode> scheduler2 = [];

  _StudnaOutputMode(String name, dynamic config)
  :
  ///////////////////////////////////////////////
  name = getString(getItemFromPath(config, ['name']), defaultValue: name),
  mode = stringToEnum
  (
    _StudnaOutputModeEnum.values, getString(getItemFromPath(config, ['mode']), defaultValue: 'manual')
  ),
  minimum = getDouble(getItemFromPath(config, ['regulator', 'minimum']), defaultValue: 0.0),
  maximum = getDouble(getItemFromPath(config, ['regulator', 'maximum']), defaultValue: 5.0),
  regulatorSource = getString(getItemFromPath(config, ['regulator', 'regulator_source']), defaultValue: ''),
  maxLevelChange = getDouble(getItemFromPath(config, ['manual', 'max_level_change']), defaultValue: 1.0),
  maxTime = 60.0 * getDouble(getItemFromPath(config, ['manual', 'max_time']), defaultValue: 60.0),
  schedulerOkHigh = decodeScheduler(getItemFromPath(config, ['scheduler', 'ok_high'])),
  schedulerCriticalLow = decodeScheduler(getItemFromPath(config, ['scheduler', 'critical_low'])),
  alternating = decodeAlternating2
  (
    getItemFromPath(config, ['regulator']), decodeAlternating(getItemFromPath(config, ['alternating']))
  ) 
  {
    if (config case {'scheduler2': List scheduler2}) 
    {
      for (final schedulerConfig in scheduler2) 
      {
        this.scheduler2.add(decodeScheduler(schedulerConfig));
      }
    }
  }

  static _SchedulerMode decodeScheduler(dynamic schedulerConfig) 
  {
    if (schedulerConfig
      case {'days': int days, 'enable': bool enabled, 'from': String from, 'interval_min': dynamic intervalMin}) 
    {
      final matchTime = _hoursMinRegex.firstMatch(from);
      final interval = getDouble(intervalMin, defaultValue: 60.0);
      if (matchTime != null) 
      {
        final hours = getInt(matchTime.group(1));
        final minutes = getInt(matchTime.group(2));
        return 
        (
          days: days,
          hours: hours,
          minutes: minutes,
          enabled: enabled,
          interval: interval,
          levels: HashSet(),
        );
      }
    } 
    else if 
    (
      schedulerConfig
      case 
      {
        'enable': bool enabled,
        'days': List days,
        'levels': List levels,
        'from': String from,
        'interval_min': dynamic intervalMin
      }
    ) 
    {
      final matchTime = _hoursMinRegex.firstMatch(from);

      if (matchTime != null) 
      {
        final hours = getInt(matchTime.group(1));
        final minutes = getInt(matchTime.group(2));
        final interval = getDouble(intervalMin, defaultValue: 60.0);
        int dayMask = 0;

        for (var d in days) 
        {
          dayMask |= switch (d.toLowerCase()) 
          {
            "monday" => 1,
            "tuesday" => 2,
            "wednesday" => 4,
            "thursday" => 8,
            "friday" => 16,
            "saturday" => 32,
            "sunday" => 64,
            _ => 0
          };

          HashSet<StudnaAinZone> zones = HashSet();
          for (var l in levels) 
          {
            zones.add(StudnaAinZone.fromString(l));
          }

          return 
          (
            days: dayMask,
            hours: hours,
            minutes: minutes,
            enabled: enabled,
            interval: interval,
            levels: zones,
          );
        }
      }
    }

    return (days: 0, hours: 0, minutes: 0, enabled: false, interval: 0.0, levels: HashSet());
  }

  static _AlternatigMode decodeAlternating(dynamic config) 
  {
    if (config case {'enabled': bool enabled, 'timeout': num timeout, 'active': num active}) 
    {
      return (enabled: enabled, timeout: timeout.toDouble(), active: active.toDouble());
    }

    return (enabled: false, timeout: 3600.0, active: 60.0);
  }

  static _AlternatigMode decodeAlternating2(dynamic config, _AlternatigMode defaultValue) 
  {
    if (config
      case {'alternating': bool enabled, 'alternating_timeout': num timeout, 'alternating_active': num active}) 
    {
      return (enabled: enabled, timeout: timeout.toDouble(), active: active.toDouble());
    }

    return defaultValue;
  }
}

class _StudnaAinMode 
{
  String name;
  String units;
  double hysteresis = 0.1;
  final levelLimits = <(double min, double max)>[(-999999.9, 1.6), (1.5, 2.1), (2.0, 4.5), (4.4, 999999.9)];

  bool inRange(double value, StudnaAinZone level) 
  {
    final range = levelLimits[level.value];
    return (value >= range.$1 && value <= range.$2);
  }

  _StudnaAinMode(String name, dynamic config)
  : name = getString(getItemFromPath(config, ['name']), defaultValue: name),
  units = getString(getItemFromPath(config, ['units']), defaultValue: 'm'),
  hysteresis = getDouble(getItemFromPath(config, ['hysteresis']), defaultValue: 0.1) 
  {
    if (config case {'levels': Map levels}) 
    {
      for (final item in levels.entries) 
      {
        final index = StudnaAinZone.stringToValue(item.key);
        if (index >= 0) 
        {
          if (item.value case {'up': num max, 'down': num min}) 
          {
            levelLimits[index] = (min.toDouble(), max.toDouble());
          }
        }
      }
    }
  }
}

typedef _SchedulerMode = 
(
  {
    int days,
    int hours,
    int minutes,
    bool enabled,
    double interval,
    HashSet<StudnaAinZone> levels,
  }
);
final _hoursMinRegex = RegExp(r'(\d+):(\d+)');

typedef _AlternatigMode = 
(
  {
    bool enabled,
    double timeout,
    double active,
  }
);

enum _StudnaOutputModeEnum 
{
  manual,
  scheduler,
  lower,
  upper;
}

enum StudnaAinZone 
{
  critical(0),
  low(1),
  ok(2),
  high(3);

  const StudnaAinZone(this.value);
  final int value;

  static int stringToValue(String str) 
  {
    for (final v in StudnaAinZone.values) 
    {
      if (v.name == str) 
      {
        return v.value;
      }
    }
    return -1;
  }

  static StudnaAinZone fromString(String str) =>
  switch (str.toLowerCase()) { "critical" => critical, "low" => low, "high" => high, _ => ok };
}