import 'dart:async';
import 'package:rowing_navigator/api/messageAPI.dart';
import 'package:rowing_navigator/models/message_model.dart';

class MessageService {
  final messageRef = MessageAPI().collection;

  Future<void> sendMessage(Message message) async {
    await messageRef.doc(message.boatId).set(message.toJson());
    print("Completed sendMessage");
  }

  Stream<List<dynamic>> getMessagesStream() {
    final snapshots = messageRef.snapshots();
    final messageStream =
        snapshots.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<List<dynamic>>();
      stream.listen((snapshot) {
        List<dynamic> messages = [];
        for (final doc in snapshot.docs) {
          final message = doc.data();
          messages.add(Message.fromJson(message));
        }
        controller.add(messages);
      });
      return controller.stream;
    }));
    return messageStream;
  }

  Future<void> clearMessage(String boatId) async {
    await messageRef.doc(boatId).delete();
    print("Completed deleteMessage");
  }
}
