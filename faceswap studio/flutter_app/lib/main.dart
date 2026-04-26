import 'package:faceswap_studio/app/app.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const FaceSwapStudioApp());
}
