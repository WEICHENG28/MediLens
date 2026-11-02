// Synthetic TTS audio only. Does not read reports, settings, credentials or real recordings.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/core/voice_input.dart';

Uint8List pcm16k(Uint8List wav){
 final b=ByteData.sublistView(wav);var offset=12,rate=0,channels=0,bits=0,format=0;Uint8List? raw;
 while(offset+8<=wav.length){
  final tag=String.fromCharCodes(wav.sublist(offset,offset+4)),size=b.getUint32(offset+4,Endian.little);offset+=8;
  if(offset+size>wav.length)break;
  if(tag=='fmt '){format=b.getUint16(offset,Endian.little);channels=b.getUint16(offset+2,Endian.little);rate=b.getUint32(offset+4,Endian.little);bits=b.getUint16(offset+14,Endian.little);}
  if(tag=='data')raw=Uint8List.sublistView(wav,offset,offset+size);
  offset+=size+(size%2);
 }
 expect(format,1);expect(bits,16);expect(channels,anyOf(1,2));expect(rate,greaterThan(0));expect(raw,isNotNull);
 final data=ByteData.sublistView(raw!),frames=raw.length~/2~/channels,count=(frames*16000/rate).floor();final output=Uint8List(count*2),out=ByteData.sublistView(output);
 double sample(int i){double value=0;for(var c=0;c<channels;c++){value+=data.getInt16((i*channels+c)*2,Endian.little);}return value/channels;}
 for(var i=0;i<count;i++){
  final source=i*rate/16000,first=source.floor().clamp(0,frames-1),next=(first+1).clamp(0,frames-1),weight=source-first;
  out.setInt16(i*2,(sample(first)*(1-weight)+sample(next)*weight).round().clamp(-32768,32767),Endian.little);
 }
 return output;
}
void main(){
 IntegrationTestWidgetsFlutterBinding.ensureInitialized();
 testWidgets('离线中文模型识别合成普通话且不依赖麦克风', (t)async{
  await t.pumpWidget(const MaterialApp(home:Scaffold(body:Text('合成测试：本机中文识别'))));
  final speech=SystemSpeech(),input=VoiceInputPlatform();File? file;
  try{
   await t.runAsync(()async{
    final voices=SpeechVoice.offlineChinese(await speech.voices());expect(voices,isNotEmpty);await speech.useVoice(voices.first);await speech.rate(.45);
    file=File('${(await getTemporaryDirectory()).path}/synthetic-offline-asr.wav');
    await speech.tts.awaitSynthCompletion(true);expect(await speech.tts.synthesizeToFile('你好，请问今天的天气怎么样。',file!.path,true),1);
    final pcm=pcm16k(await file!.readAsBytes());final watch=Stopwatch()..start();
    final text=await input.recognizePcm(pcm);expect(text,isNotEmpty);expect(text,anyOf(contains('天气'),contains('今天')));
    // ignore: avoid_print
    print('[OFFLINE_ASR] synthetic_text=$text elapsed_ms=${watch.elapsedMilliseconds}');
   });
  }finally{await t.runAsync(()async{await speech.stop();if(file!=null&&await file!.exists())await file!.delete();});}
 });
 testWidgets('静音合成PCM不编造文字', (t)async{
  await t.pumpWidget(const MaterialApp(home:Scaffold(body:Text('合成测试：静音'))));
  await t.runAsync(()async{expect(await VoiceInputPlatform().recognizePcm(Uint8List(32000)),isEmpty);});
 });
 testWidgets('授权模拟器麦克风启动后取消会释放且不返回录音内容', (t)async{
  await t.pumpWidget(const MaterialApp(home:Scaffold(body:Text('合成测试：取消本机录音'))));
  final p=VoiceInputPlatform();
  await t.runAsync(()async{
   expect((await p.status()).permission,isTrue,reason:'Authorized test emulator must grant permission first');
   await Future<void>.delayed(const Duration(milliseconds:500));
   final state=await VoiceInputPlatform.channel.invokeMapMethod<String,dynamic>('status');
   if(state?['foreground']!=true){
    await expectLater(p.listen(),throwsA(isA<PlatformException>().having((e)=>e.code,'code','foreground')));
    // ignore: avoid_print
    print('[OFFLINE_MIC] background_request_blocked=passed; foreground_capture_requires_ui_test');
    return;
   }
   final response=p.listen().then<Object>((v)=>v,onError:(Object e)=>e);
   await Future<void>.delayed(const Duration(milliseconds:700));await p.cancel();expect(await response,'');
   expect(await p.recognizePcm(Uint8List(32000)),isEmpty);
   // ignore: avoid_print
   print('[OFFLINE_MIC] cancel_release_no_transcript=passed');
  });
 });
 testWidgets('实时端点在第一句停顿后结束，并产生临时文字', (t)async{
  await t.pumpWidget(const MaterialApp(home:Scaffold(body:Text('合成测试：实时停顿检测'))));
  final speech=SystemSpeech(),input=VoiceInputPlatform();File? file;final partials=<String>[];
  final subscription=input.partials.listen((text){if(text.trim().isNotEmpty)partials.add(text);});
  try{
   await t.runAsync(()async{
    final voices=SpeechVoice.offlineChinese(await speech.voices());expect(voices,isNotEmpty);await speech.useVoice(voices.first);await speech.rate(.45);
    file=File('${(await getTemporaryDirectory()).path}/synthetic-endpoint.wav');await speech.tts.awaitSynthCompletion(true);
    expect(await speech.tts.synthesizeToFile('你好，请问今天的天气怎么样。',file!.path,true),1);
    final pcm=pcm16k(await file!.readAsBytes());
    final sequence=BytesBuilder()..add(pcm)..add(Uint8List(16000*2*3))..add(pcm)..add(Uint8List(16000*2));
    final text=await input.recognizeEndpointPcm(sequence.takeBytes());
    expect(text,contains('天气'));expect('天气'.allMatches(text).length,1,reason:'Stop at first utterance; do not merge the next question');
    expect(partials,isNotEmpty);
    // ignore: avoid_print
    print('[REALTIME_ENDPOINT] first_utterance_only=passed partial_events=${partials.length}');
   });
  }finally{await subscription.cancel();await t.runAsync(()async{await speech.stop();if(file!=null&&await file!.exists())await file!.delete();});}
 });

}
