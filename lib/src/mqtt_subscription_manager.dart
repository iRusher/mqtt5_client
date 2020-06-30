/*
 * Package : mqtt5_client
 * Author : S. Hamblett <steve.hamblett@linux.com>
 * Date   : 10/05/2020
 * Copyright :  S.Hamblett
 */

part of mqtt5_client;

/// Subscribed and Unsubscribed callback typedefs
typedef SubscribeCallback = void Function(MqttSubscription subscription);
typedef SubscribeFailCallback = void Function(MqttSubscription subscription);
typedef UnsubscribeCallback = void Function(MqttSubscription subscription);

/// A class that manages the topic subscription process.
class MqttSubscriptionManager {
  ///  Creates a new instance of a SubscriptionsManager that uses the
  ///  specified connection to manage subscriptions.
  MqttSubscriptionManager(this._connectionHandler, this._clientEventBus) {
    _connectionHandler.registerForMessage(
        MqttMessageType.subscribeAck, confirmSubscription);
    _connectionHandler.registerForMessage(
        MqttMessageType.unsubscribeAck, confirmUnsubscribe);
    // Start listening for published messages
    _clientEventBus.on<MqttMessageReceived>().listen(publishMessageReceived);
  }

  final _messageIdentifierDispenser = MqttMessageIdentifierDispenser();

  /// Dispenser used for keeping track of subscription ids and generating
  /// message identifiers.
  MqttMessageIdentifierDispenser get messageIdentifierDispenser =>
      _messageIdentifierDispenser;

  final _subscriptions = <String, MqttSubscription>{};

  /// List of confirmed subscriptions, keyed on the topic name.
  Map<String, MqttSubscription> get subscriptions => _subscriptions;

  final _pendingSubscriptions = <int, List<MqttSubscription>>{};

  /// A list of subscriptions that are pending acknowledgement, keyed
  /// on the message identifier.
  Map<int, List<MqttSubscription>> get pendingSubscriptions =>
      _pendingSubscriptions;

  final _pendingUnsubscriptions = <int, List<MqttSubscription>>{};

  /// A list of unsubscribe requests waiting for an unsubscribe ack message.
  /// Index is the message identifier of the unsubscribe message.
  Map<int, List<MqttSubscription>> get pendingUnsubscriptions =>
      _pendingUnsubscriptions;

  /// The connection handler that we use to subscribe to subscription
  /// acknowledgements.
  final _connectionHandler;

  /// Subscribe and Unsubscribe callbacks
  SubscribeCallback onSubscribed;

  /// Unsubscribed
  UnsubscribeCallback onUnsubscribed;

  /// Subscription failed callback
  SubscribeFailCallback onSubscribeFail;

  /// The event bus
  final events.EventBus _clientEventBus;

  /// Observable change notifier for all subscribed topics
  final observe.ChangeNotifier<MqttReceivedMessage<MqttMessage>>
      _subscriptionNotifier =
      observe.ChangeNotifier<MqttReceivedMessage<MqttMessage>>();

  /// Subscription notifier
  observe.ChangeNotifier<MqttReceivedMessage<MqttMessage>>
      get subscriptionNotifier => _subscriptionNotifier;

  /// Registers a new subscription with the subscription manager from a topic
  /// and a maximum Qos.
  /// Returns the subscription subscribed to.
  MqttSubscription subscribeSubscriptionTopic(String topic, MqttQos qos) {
    if (topic == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::subscribeSubscriptionTopic - topic is null');
    }
    var cn = _tryGetExistingSubscription(topic);
    return cn ??= _createNewSubscription(topic, qos);
  }

  /// Registers a new subscription with the subscription manager from a
  /// subscription.
  /// Returns the subscription subscribed to.
  MqttSubscription subscribeSubscription(MqttSubscription subscription) {
    if (subscription == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::subscribeSubscription - subscription is null');
    }
    var cn = _tryGetExistingSubscription(subscription.topic.rawTopic);
    return cn ??= _createNewSubscription(
        subscription.topic.rawTopic, subscription.maximumQos,
        userProperties: subscription.userProperties);
  }

  /// Registers a new subscription with the subscription manager from a
  /// list of subscriptions.
  /// Note that user properties are set on a per message basis not a per
  /// subscription basis, if you wish to send user properties then set
  /// them on the first subscription in the list.
  /// Returns the actual subscriptions subscribed to or null if none.
  List<MqttSubscription> subscribeSubscriptionList(
      List<MqttSubscription> subscriptions) {
    if (subscriptions == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::subscribeSubscriptionList - subscription list is null');
    }
    final subscriptionsToCreate = <MqttSubscription>[];
    for (final subscription in subscriptions) {
      var cn = _tryGetExistingSubscription(subscription.topic.rawTopic);
      cn ??= subscription;
      subscriptionsToCreate.add(cn);
    }
    if (subscriptionsToCreate.isEmpty) {
      // No subscriptions created.
      MqttLogger.log(
          'MqttSubscriptionManager::registerSubscriptionList - no subscriptions are valid');
      return null;
    }
    // Build a subscription message and send it.
    try {
      final msgId = messageIdentifierDispenser.getNextMessageIdentifier();
      pendingSubscriptions[msgId] = subscriptionsToCreate;
      final msg = MqttSubscribeMessage()
          .toSubscriptionList(subscriptionsToCreate)
          .withUserProperties(subscriptionsToCreate.first.userProperties);
      msg.messageIdentifier = msgId;
      _connectionHandler.sendMessage(msg);
      return subscriptionsToCreate;
    } on Exception catch (e) {
      MqttLogger.log('MqttSubscriptionManager::registerSubscriptionList'
          'exception raised, text is $e');
      return null;
    }
  }

  /// Gets a view on the existing observable, if the subscription
  /// already exists.
  MqttSubscription _tryGetExistingSubscription(String topic) {
    final retSub = subscriptions[topic];
    if (retSub == null) {
      // Search the pending subscriptions
      for (final subList in pendingSubscriptions.values) {
        for (final sub in subList) {
          if (sub.topic.rawTopic == topic) {
            return sub;
          }
        }
      }
    }
    return retSub;
  }

  /// Creates a new subscription for the specified topic and Qos.
  /// If the subscription cannot be created null is returned.
  MqttSubscription _createNewSubscription(String topic, MqttQos qos,
      {List<MqttUserProperty> userProperties}) {
    try {
      final subscriptionTopic = MqttSubscriptionTopic(topic);
      final sub = MqttSubscription.withMaximumQos(subscriptionTopic, qos);
      sub.userProperties = userProperties;
      final msgId = messageIdentifierDispenser.getNextMessageIdentifier();
      pendingSubscriptions[msgId].add(sub);
      // Build a subscribe message for the caller and send it to the broker.
      final msg = MqttSubscribeMessage()
          .toTopicWithQos(sub.topic.rawTopic, qos)
          .withUserProperties(userProperties);
      msg.messageIdentifier = msgId;
      _connectionHandler.sendMessage(msg);
      return sub;
    } on Exception catch (e) {
      MqttLogger.log('MqttSubscriptionManager::createNewSubscription '
          'exception raised, text is $e');
      return null;
    }
  }

  /// Publish message received
  void publishMessageReceived(MqttMessageReceived event) {
    final topic = event.topic;
    final msg = MqttReceivedMessage<MqttMessage>(topic.rawTopic, event.message);
    subscriptionNotifier.notifyChange(msg);
  }

  /// Unsubscribe from a string topic.
  void unsubscribeTopic(String topic) {
    if (topic == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::unsubscribeStringTopic - topic is null');
    }
    final unsubscribeMsg = MqttUnsubscribeMessage()
        .withMessageIdentifier(
            messageIdentifierDispenser.getNextMessageIdentifier())
        .fromStringTopic(topic);
    _connectionHandler.sendMessage(unsubscribeMsg);
    pendingUnsubscriptions[unsubscribeMsg.variableHeader.messageIdentifier]
        .add(MqttSubscription(MqttSubscriptionTopic(topic)));
  }

  /// Unsubscribe from a subscription.
  void unsubscribeSubscription(MqttSubscription subscription) {
    if (subscription == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::unsubscribeSubscription - subscription is null');
    }
    final unsubscribeMsg = MqttUnsubscribeMessage()
        .withMessageIdentifier(
            messageIdentifierDispenser.getNextMessageIdentifier())
        .fromTopic(subscription.topic)
        .withUserProperties(subscription.userProperties);
    _connectionHandler.sendMessage(unsubscribeMsg);
    pendingUnsubscriptions[unsubscribeMsg.variableHeader.messageIdentifier]
        .add(subscription);
  }

  /// Unsubscribe from a subscription list.
  /// Note that user properties are set on a per message basis not a per
  /// subscription basis, if you wish to send user properties then set
  /// them on the first subscription in the list.
  void unsubscribeSubscriptionList(List<MqttSubscription> subscriptions) {
    if (subscriptions == null) {
      throw ArgumentError(
          'MqttSubscriptionManager::unsubscribeSubscriptionList - subscription list is null');
    }
    final unsubscribeMsg = MqttUnsubscribeMessage()
        .withMessageIdentifier(
            messageIdentifierDispenser.getNextMessageIdentifier())
        .fromSubscriptionList(subscriptions)
        .withUserProperties(subscriptions.first.userProperties);
    _connectionHandler.sendMessage(unsubscribeMsg);
    pendingUnsubscriptions[unsubscribeMsg.variableHeader.messageIdentifier] =
        subscriptions;
  }

  /// Confirms a subscription has been made with the broker.
  /// Marks the subscription as confirmed.
  /// Returns true on successful subscription confirm, false on fail.
  /// Note if any subscriptions fail a fail will be returned.
  bool confirmSubscription(MqttMessage msg) {
    final MqttSubscribeAckMessage subAck = msg;
    final reasonCodes = subAck.reasonCodes;
    var ok = true;
    var reasonCodeIndex = 0;
    final messageIdentifier = subAck.variableHeader.messageIdentifier;
    if (pendingSubscriptions.containsKey(messageIdentifier)) {
      for (final pendingTopic in pendingSubscriptions[messageIdentifier]) {
        final topic = pendingTopic.topic.rawTopic;
        pendingTopic.reasonCode = subAck.reasonCodes[reasonCodeIndex];
        pendingTopic.userProperties = subAck.userProperty;
        // Check for a successful subscribe
        if (!MqttReasonCodeUtilities.isError(
            mqttSubscribeReasonCode.asInt(reasonCodes[reasonCodeIndex]))) {
          subscriptions[topic] = pendingTopic;
          if (onSubscribed != null) {
            onSubscribed(pendingTopic);
          }
        } else {
          subscriptions.remove(topic);
          if (onSubscribeFail != null) {
            onSubscribeFail(pendingTopic);
          }
          ok = false;
        }
        reasonCodeIndex++;
      }
      pendingSubscriptions.remove(messageIdentifier);
    } else {
      MqttLogger.log(
          'MqttSubscriptionManager::confirmSubscription - message identifier $messageIdentifier has no pending subscriptions');
      return false;
    }

    return ok;
  }

  /// Confirms an unsubscription has been made with the broker.
  /// Removes the subscription.
  /// Returns true on successful unsubscription confirm, false on fail.
  /// Note if any unsubscriptions fail a fail will be returned but the
  /// subscription will still be removed.
  bool confirmUnsubscribe(MqttMessage msg) {
    final MqttUnsubscribeAckMessage unSubAck = msg;
    final reasonCodes = unSubAck.reasonCodes;
    var ok = true;
    var reasonCodeIndex = 0;
    final messageIdentifier = unSubAck.variableHeader.messageIdentifier;
    if (pendingUnsubscriptions.containsKey(messageIdentifier)) {
      for (final pendingTopic in pendingUnsubscriptions[messageIdentifier]) {
        final topic = pendingTopic.topic.rawTopic;
        pendingTopic.reasonCode = unSubAck.reasonCodes[reasonCodeIndex];
        pendingTopic.userProperties = unSubAck.userProperty;
        subscriptions.remove(topic);
        // Check for a successful unsubscribe
        if (!MqttReasonCodeUtilities.isError(
            mqttSubscribeReasonCode.asInt(reasonCodes[reasonCodeIndex]))) {
          if (onUnsubscribed != null) {
            onUnsubscribed(pendingTopic);
          }
        } else {
          ok = false;
        }
        reasonCodeIndex++;
      }
      pendingUnsubscriptions.remove(messageIdentifier);
    } else {
      MqttLogger.log(
          'MqttSubscriptionManager::confirmUnsubscription - message identifier $messageIdentifier has no pending unsubscriptions');
      return false;
    }

    return ok;
  }

  /// Gets the current status of a subscription topic.
  MqttSubscriptionStatus getSubscriptionTopicStatus(String topic) {
    var status = MqttSubscriptionStatus.doesNotExist;
    if (subscriptions.containsKey(topic)) {
      status = MqttSubscriptionStatus.active;
    }
    for (final topics in pendingSubscriptions.values) {
      for (final subTopic in topics) {
        if (subTopic.topic.rawTopic == topic) {
          status = MqttSubscriptionStatus.pending;
        }
      }
    }
    return status;
  }

  /// Gets the current status of a subscription.
  MqttSubscriptionStatus getSubscriptionStatus(MqttSubscription subscription) {
    var status = MqttSubscriptionStatus.doesNotExist;
    if (subscriptions.containsKey(subscription.topic.rawTopic)) {
      status = MqttSubscriptionStatus.active;
    }
    for (final topics in pendingSubscriptions.values) {
      for (final subTopic in topics) {
        if (subTopic == subscription) {
          status = MqttSubscriptionStatus.pending;
        }
      }
    }
    return status;
  }
}
