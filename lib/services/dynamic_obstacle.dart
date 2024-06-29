import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/message_model.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/message_model.dart';
import '../services/message_service.dart';

class DynamicObstacle {
  final messageService = MessageService();
  Stream<List> getBoatsStream() {
    {
      final messageStream = messageService.getMessagesStream();
      final boatsStream =
          messageStream.transform(StreamTransformer.fromBind((stream) {
        final controller = StreamController<List<dynamic>>();
        List<Boat> boats = [];
        stream.listen((messages) {
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
}
