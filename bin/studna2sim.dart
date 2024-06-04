import 'package:studna2sim/studna2sim.dart' as studna2sim;
import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:studna2sim/json_utils.dart';

void main(List<String> arguments) async 
{
  final tasks = <Future>[];
  final file = File('config.yaml');
  final configYaml = await file.readAsString();
  final config = loadYaml(configYaml);

  final server = getString(getItemFromPath(config, ['server']), defaultValue: 'cml.seapraha.cz');

  if (config case {'devices': List devices}) 
  {
    for (final device in devices) 
    {
      if (device case {'token': String token, 'type': String type}) 
      {
        switch (type) 
        {
          case 'studna2':
          tasks.add(studna2sim.studnaMqtt(server: server, token: token, config: device));
          break;
        }
      }
      // await studna2sim.studna_main(server: server, user: user, password: password);
    }
  }

  await Future.wait(tasks);
  //studna2sim.studna_main(server: 'https://cml.seapraha.cz', user: 'ios.milpro@gmail.com', password:  'testios');
  //await studna2sim.studnaMqtt(server: 'cml.seapraha.cz', token: 'y9fMRfFTLuBhdvz7gsrj');
}