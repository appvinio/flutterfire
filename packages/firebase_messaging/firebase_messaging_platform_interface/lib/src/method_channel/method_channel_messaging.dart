// Copyright 2020, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils.dart';
import 'utils/exception.dart';

// This is the entrypoint for the background isolate. Since we can only enter
// an isolate once, we setup a MethodChannel to listen for method invocations
// from the native portion of the plugin. This allows for the plugin to perform
// any necessary processing in Dart (e.g., populating a custom object) before
// invoking the provided callback.
void _firebaseMessagingCallbackDispatcher() {
  // Initialize state necessary for MethodChannels.
  WidgetsFlutterBinding.ensureInitialized();

  const MethodChannel _channel = MethodChannel(
    'plugins.flutter.io/firebase_messaging_background',
  );

  // This is where we handle background events from the native portion of the plugin.
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == "MessagingBackground#onMessage") {
      final CallbackHandle handle =
          CallbackHandle.fromRawHandle(call.arguments["userCallbackHandle"]);

      // PluginUtilities.getCallbackFromHandle performs a lookup based on the
      // callback handle and returns a tear-off of the original callback.
      final Function closure = PluginUtilities.getCallbackFromHandle(handle);

      if (closure == null) {
        print('Fatal: could not find user callback');
        exit(-1);
      }

      try {
        Map<String, dynamic> messageMap =
            Map<String, dynamic>.from(call.arguments["message"]);
        final RemoteMessage remoteMessage = RemoteMessage.fromMap(messageMap);
        await closure(remoteMessage);
      } catch (e) {
        print(
            "FlutterFire Messaging: An error occurred in your background messaging handler:");
        print(e);
      }
    } else {
      throw UnimplementedError("${call.method} has not been implemented");
    }
  });

  // Once we've finished initializing, let the native portion of the plugin
  // know that it can start scheduling alarms.
  _channel.invokeMethod<void>("MessagingBackground#initialized");
}

/// The entry point for accessing a Messaging.
///
/// You can get an instance by calling [FirebaseMessaging.instance].
class MethodChannelFirebaseMessaging extends FirebaseMessagingPlatform {
  /// Create an instance of [MethodChannelFirebaseMessaging] with optional [FirebaseApp]
  MethodChannelFirebaseMessaging({FirebaseApp app}) : super(appInstance: app) {
    if (_initialized) return;
    channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case "Messaging#onTokenRefresh":
          _tokenStreamController.add(call.arguments as String);
          break;
        case "Messaging#onMessage":
          print(call.arguments);
          Map<String, dynamic> messageMap =
              Map<String, dynamic>.from(call.arguments);
          FirebaseMessagingPlatform.onMessage
              .add(RemoteMessage.fromMap(messageMap));
          break;
        case "Messaging#onMessageOpenedApp":
          Map<String, dynamic> messageMap =
              Map<String, dynamic>.from(call.arguments);
          FirebaseMessagingPlatform.onMessageOpenedApp
              .add(RemoteMessage.fromMap(messageMap));
          break;
        case "Messaging#onBackgroundMessage":
          // Apple only. Android calls via separate background channel.
          Map<String, dynamic> messageMap =
              Map<String, dynamic>.from(call.arguments);
          return FirebaseMessagingPlatform.onBackgroundMessage
              ?.call(RemoteMessage.fromMap(messageMap));
        default:
          throw UnimplementedError("${call.method} has not been implemented");
      }
    });
    _initialized = true;
  }

  bool _autoInitEnabled;

  static bool _initialized = false;
  static bool _bgHandlerInitialized = false;

  /// Returns a stub instance to allow the platform interface to access
  /// the class instance statically.
  static MethodChannelFirebaseMessaging get instance {
    return MethodChannelFirebaseMessaging._();
  }

  /// Internal stub class initializer.
  ///
  /// When the user code calls an auth method, the real instance is
  /// then initialized via the [delegateFor] method.
  MethodChannelFirebaseMessaging._() : super(appInstance: null);

  /// The [MethodChannel] to which calls will be delegated.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/firebase_messaging',
  );

  final StreamController<String> _tokenStreamController =
      StreamController<String>.broadcast();

  @override
  FirebaseMessagingPlatform delegateFor({FirebaseApp app}) {
    return MethodChannelFirebaseMessaging(app: app);
  }

  @override
  FirebaseMessagingPlatform setInitialValues({bool isAutoInitEnabled}) {
    _autoInitEnabled = isAutoInitEnabled ?? false;
    return this;
  }

  @override
  bool get isAutoInitEnabled {
    return _autoInitEnabled;
  }

  @override
  Future<RemoteMessage> getInitialMessage() async {
    try {
      Map<String, dynamic> remoteMessageMap = await channel
          .invokeMapMethod<String, dynamic>('Messaging#getInitialMessage', {
        'appName': app.name,
      });

      if (remoteMessageMap == null) {
        return null;
      }

      return RemoteMessage.fromMap(remoteMessageMap);
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  void registerBackgroundMessageHandler(
      BackgroundMessageHandler handler) async {
    if (handler == null || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    if (!_bgHandlerInitialized) {
      _bgHandlerInitialized = true;
      final CallbackHandle bgHandle = PluginUtilities.getCallbackHandle(
          _firebaseMessagingCallbackDispatcher);
      final CallbackHandle userHandle =
          PluginUtilities.getCallbackHandle(handler);
      await channel.invokeMethod<bool>('Messaging#startBackgroundIsolate', {
        'pluginCallbackHandle': bgHandle.toRawHandle(),
        'userCallbackHandle': userHandle.toRawHandle(),
      });
    }
  }

  @override
  Future<void> deleteToken({
    String senderId,
  }) async {
    try {
      await channel.invokeMethod<String>(
          'Messaging#deleteToken', {'appName': app.name, 'senderId': senderId});
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<String> getAPNSToken() async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return null;
    }

    try {
      return await channel.invokeMethod<String>('Messaging#getAPNSToken', {
        'appName': app.name,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<String> getToken({
    String senderId,
    String vapidKey, // not used yet; web only property
  }) async {
    try {
      return await channel.invokeMethod<String>('Messaging#getToken', {
        'appName': app.name,
        'senderId': senderId,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<NotificationSettings> getNotificationSettings() async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return androidNotificationSettings;
    }

    try {
      Map<String, int> response = await channel
          .invokeMapMethod<String, int>('Messaging#getNotificationSettings', {
        'appName': app.name,
      });

      return convertToNotificationSettings(response);
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<NotificationSettings> requestPermission(
      {bool alert = true,
      bool announcement = false,
      bool badge = true,
      bool carPlay = false,
      bool criticalAlert = false,
      bool provisional = false,
      bool sound = true}) async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return androidNotificationSettings;
    }

    try {
      Map<String, int> response = await channel
          .invokeMapMethod<String, int>('Messaging#requestPermission', {
        'appName': app.name,
        'permissions': <String, bool>{
          'alert': alert,
          'announcement': announcement,
          'badge': badge,
          'carPlay': carPlay,
          'criticalAlert': criticalAlert,
          'provisional': provisional,
          'sound': sound,
        }
      });

      return convertToNotificationSettings(response);
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    try {
      Map<String, dynamic> data = await channel
          .invokeMapMethod<String, dynamic>('Messaging#setAutoInitEnabled', {
        'appName': app.name,
        'enabled': enabled,
      });
      _autoInitEnabled = data['isAutoInitEnabled'];
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Stream<String> get onTokenRefresh {
    return _tokenStreamController.stream;
  }

  @override
  Future<void> setForegroundNotificationPresentationOptions({
    bool alert,
    bool badge,
    bool sound,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }

    try {
      await channel.invokeMethod(
          'Messaging#setForegroundNotificationPresentationOptions', {
        'appName': app.name,
        'alert': alert,
        'badge': badge,
        'sound': sound,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> sendMessage({
    String to,
    Map<String, String> data,
    String collapseKey,
    String messageId,
    String messageType,
    int ttl,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnimplementedError(
          "Sending of messages from the Firebase Messaging SDK is only supported on Android devices.");
    }

    try {
      await channel.invokeMethod('Messaging#sendMessage', {
        'appName': app.name,
        'to': to,
        'data': data,
        'collapseKey': collapseKey,
        'messageId': messageId,
        'messageType': messageType,
        'ttl': ttl,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> subscribeToTopic(String topic) async {
    try {
      await channel.invokeMethod<String>('Messaging#subscribeToTopic', {
        'appName': app.name,
        'topic': topic,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }

  @override
  Future<void> unsubscribeFromTopic(String topic) async {
    try {
      await channel.invokeMethod<String>('Messaging#unsubscribeFromTopic', {
        'appName': app.name,
        'topic': topic,
      });
    } catch (e) {
      throw convertPlatformException(e);
    }
  }
}
