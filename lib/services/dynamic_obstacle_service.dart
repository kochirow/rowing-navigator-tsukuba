import 'dart:async';
import '../models/message_model.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import '../services/message_service.dart';

class DynamicObstacleService {
  Stream<Map<String, dynamic>> getDynamicObstacleStream() {
    final boatsStream = getBoatsStream();
    final dynamicObstacleStream =
        boatsStream.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<Map<String, dynamic>>();
      stream.listen((boats) {
        controller.add({"boats": boats as List<Boat>});
      });
      return controller.stream;
    }));
    return dynamicObstacleStream;
  }

  Stream<List> getBoatsStream() {
    final messageService = MessageService();
    final messageStream = messageService.getMessagesStream();
    final boatsStream =
        messageStream.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<List<dynamic>>();
      stream.listen((messages) {
        List<Boat> boats = [];
        for (final Message message in messages) {
          final boat = Boat.fromJson(message.toJson());
          boats.add(boat);
        }
        controller.add(boats);
      });
      return controller.stream;
    }));
    return boatsStream;
  }
}
