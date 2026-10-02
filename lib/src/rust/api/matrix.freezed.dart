// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'matrix.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SyncEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent()';
}


}

/// @nodoc
class $SyncEventCopyWith<$Res>  {
$SyncEventCopyWith(SyncEvent _, $Res Function(SyncEvent) __);
}


/// Adds pattern-matching-related methods to [SyncEvent].
extension SyncEventPatterns on SyncEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SyncEvent_SyncCompleted value)?  syncCompleted,TResult Function( SyncEvent_FullRefreshRequired value)?  fullRefreshRequired,TResult Function( SyncEvent_RoomListChanged value)?  roomListChanged,TResult Function( SyncEvent_MessageSent value)?  messageSent,TResult Function( SyncEvent_MessageRedacted value)?  messageRedacted,TResult Function( SyncEvent_PinnedMessagesChanged value)?  pinnedMessagesChanged,TResult Function( SyncEvent_RoomMembersChanged value)?  roomMembersChanged,TResult Function( SyncEvent_IgnoredUsersChanged value)?  ignoredUsersChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case SyncEvent_FullRefreshRequired() when fullRefreshRequired != null:
return fullRefreshRequired(_that);case SyncEvent_RoomListChanged() when roomListChanged != null:
return roomListChanged(_that);case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that);case SyncEvent_MessageRedacted() when messageRedacted != null:
return messageRedacted(_that);case SyncEvent_PinnedMessagesChanged() when pinnedMessagesChanged != null:
return pinnedMessagesChanged(_that);case SyncEvent_RoomMembersChanged() when roomMembersChanged != null:
return roomMembersChanged(_that);case SyncEvent_IgnoredUsersChanged() when ignoredUsersChanged != null:
return ignoredUsersChanged(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SyncEvent_SyncCompleted value)  syncCompleted,required TResult Function( SyncEvent_FullRefreshRequired value)  fullRefreshRequired,required TResult Function( SyncEvent_RoomListChanged value)  roomListChanged,required TResult Function( SyncEvent_MessageSent value)  messageSent,required TResult Function( SyncEvent_MessageRedacted value)  messageRedacted,required TResult Function( SyncEvent_PinnedMessagesChanged value)  pinnedMessagesChanged,required TResult Function( SyncEvent_RoomMembersChanged value)  roomMembersChanged,required TResult Function( SyncEvent_IgnoredUsersChanged value)  ignoredUsersChanged,}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted():
return syncCompleted(_that);case SyncEvent_FullRefreshRequired():
return fullRefreshRequired(_that);case SyncEvent_RoomListChanged():
return roomListChanged(_that);case SyncEvent_MessageSent():
return messageSent(_that);case SyncEvent_MessageRedacted():
return messageRedacted(_that);case SyncEvent_PinnedMessagesChanged():
return pinnedMessagesChanged(_that);case SyncEvent_RoomMembersChanged():
return roomMembersChanged(_that);case SyncEvent_IgnoredUsersChanged():
return ignoredUsersChanged(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SyncEvent_SyncCompleted value)?  syncCompleted,TResult? Function( SyncEvent_FullRefreshRequired value)?  fullRefreshRequired,TResult? Function( SyncEvent_RoomListChanged value)?  roomListChanged,TResult? Function( SyncEvent_MessageSent value)?  messageSent,TResult? Function( SyncEvent_MessageRedacted value)?  messageRedacted,TResult? Function( SyncEvent_PinnedMessagesChanged value)?  pinnedMessagesChanged,TResult? Function( SyncEvent_RoomMembersChanged value)?  roomMembersChanged,TResult? Function( SyncEvent_IgnoredUsersChanged value)?  ignoredUsersChanged,}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case SyncEvent_FullRefreshRequired() when fullRefreshRequired != null:
return fullRefreshRequired(_that);case SyncEvent_RoomListChanged() when roomListChanged != null:
return roomListChanged(_that);case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that);case SyncEvent_MessageRedacted() when messageRedacted != null:
return messageRedacted(_that);case SyncEvent_PinnedMessagesChanged() when pinnedMessagesChanged != null:
return pinnedMessagesChanged(_that);case SyncEvent_RoomMembersChanged() when roomMembersChanged != null:
return roomMembersChanged(_that);case SyncEvent_IgnoredUsersChanged() when ignoredUsersChanged != null:
return ignoredUsersChanged(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  syncCompleted,TResult Function()?  fullRefreshRequired,TResult Function()?  roomListChanged,TResult Function( String roomId)?  messageSent,TResult Function( String roomId,  String eventId)?  messageRedacted,TResult Function( String roomId)?  pinnedMessagesChanged,TResult Function( String roomId)?  roomMembersChanged,TResult Function()?  ignoredUsersChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted();case SyncEvent_FullRefreshRequired() when fullRefreshRequired != null:
return fullRefreshRequired();case SyncEvent_RoomListChanged() when roomListChanged != null:
return roomListChanged();case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that.roomId);case SyncEvent_MessageRedacted() when messageRedacted != null:
return messageRedacted(_that.roomId,_that.eventId);case SyncEvent_PinnedMessagesChanged() when pinnedMessagesChanged != null:
return pinnedMessagesChanged(_that.roomId);case SyncEvent_RoomMembersChanged() when roomMembersChanged != null:
return roomMembersChanged(_that.roomId);case SyncEvent_IgnoredUsersChanged() when ignoredUsersChanged != null:
return ignoredUsersChanged();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  syncCompleted,required TResult Function()  fullRefreshRequired,required TResult Function()  roomListChanged,required TResult Function( String roomId)  messageSent,required TResult Function( String roomId,  String eventId)  messageRedacted,required TResult Function( String roomId)  pinnedMessagesChanged,required TResult Function( String roomId)  roomMembersChanged,required TResult Function()  ignoredUsersChanged,}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted():
return syncCompleted();case SyncEvent_FullRefreshRequired():
return fullRefreshRequired();case SyncEvent_RoomListChanged():
return roomListChanged();case SyncEvent_MessageSent():
return messageSent(_that.roomId);case SyncEvent_MessageRedacted():
return messageRedacted(_that.roomId,_that.eventId);case SyncEvent_PinnedMessagesChanged():
return pinnedMessagesChanged(_that.roomId);case SyncEvent_RoomMembersChanged():
return roomMembersChanged(_that.roomId);case SyncEvent_IgnoredUsersChanged():
return ignoredUsersChanged();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  syncCompleted,TResult? Function()?  fullRefreshRequired,TResult? Function()?  roomListChanged,TResult? Function( String roomId)?  messageSent,TResult? Function( String roomId,  String eventId)?  messageRedacted,TResult? Function( String roomId)?  pinnedMessagesChanged,TResult? Function( String roomId)?  roomMembersChanged,TResult? Function()?  ignoredUsersChanged,}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted();case SyncEvent_FullRefreshRequired() when fullRefreshRequired != null:
return fullRefreshRequired();case SyncEvent_RoomListChanged() when roomListChanged != null:
return roomListChanged();case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that.roomId);case SyncEvent_MessageRedacted() when messageRedacted != null:
return messageRedacted(_that.roomId,_that.eventId);case SyncEvent_PinnedMessagesChanged() when pinnedMessagesChanged != null:
return pinnedMessagesChanged(_that.roomId);case SyncEvent_RoomMembersChanged() when roomMembersChanged != null:
return roomMembersChanged(_that.roomId);case SyncEvent_IgnoredUsersChanged() when ignoredUsersChanged != null:
return ignoredUsersChanged();case _:
  return null;

}
}

}

/// @nodoc


class SyncEvent_SyncCompleted extends SyncEvent {
  const SyncEvent_SyncCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_SyncCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.syncCompleted()';
}


}




/// @nodoc


class SyncEvent_FullRefreshRequired extends SyncEvent {
  const SyncEvent_FullRefreshRequired(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_FullRefreshRequired);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.fullRefreshRequired()';
}


}




/// @nodoc


class SyncEvent_RoomListChanged extends SyncEvent {
  const SyncEvent_RoomListChanged(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_RoomListChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.roomListChanged()';
}


}




/// @nodoc


class SyncEvent_MessageSent extends SyncEvent {
  const SyncEvent_MessageSent({required this.roomId}): super._();
  

 final  String roomId;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_MessageSentCopyWith<SyncEvent_MessageSent> get copyWith => _$SyncEvent_MessageSentCopyWithImpl<SyncEvent_MessageSent>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_MessageSent&&(identical(other.roomId, roomId) || other.roomId == roomId));
}


@override
int get hashCode => Object.hash(runtimeType,roomId);

@override
String toString() {
  return 'SyncEvent.messageSent(roomId: $roomId)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_MessageSentCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_MessageSentCopyWith(SyncEvent_MessageSent value, $Res Function(SyncEvent_MessageSent) _then) = _$SyncEvent_MessageSentCopyWithImpl;
@useResult
$Res call({
 String roomId
});




}
/// @nodoc
class _$SyncEvent_MessageSentCopyWithImpl<$Res>
    implements $SyncEvent_MessageSentCopyWith<$Res> {
  _$SyncEvent_MessageSentCopyWithImpl(this._self, this._then);

  final SyncEvent_MessageSent _self;
  final $Res Function(SyncEvent_MessageSent) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,}) {
  return _then(SyncEvent_MessageSent(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SyncEvent_MessageRedacted extends SyncEvent {
  const SyncEvent_MessageRedacted({required this.roomId, required this.eventId}): super._();


 final  String roomId;
 final  String eventId;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_MessageRedactedCopyWith<SyncEvent_MessageRedacted> get copyWith => _$SyncEvent_MessageRedactedCopyWithImpl<SyncEvent_MessageRedacted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_MessageRedacted&&(identical(other.roomId, roomId) || other.roomId == roomId)&&(identical(other.eventId, eventId) || other.eventId == eventId));
}


@override
int get hashCode => Object.hash(runtimeType,roomId,eventId);

@override
String toString() {
  return 'SyncEvent.messageRedacted(roomId: $roomId, eventId: $eventId)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_MessageRedactedCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_MessageRedactedCopyWith(SyncEvent_MessageRedacted value, $Res Function(SyncEvent_MessageRedacted) _then) = _$SyncEvent_MessageRedactedCopyWithImpl;
@useResult
$Res call({
 String roomId, String eventId
});




}
/// @nodoc
class _$SyncEvent_MessageRedactedCopyWithImpl<$Res>
    implements $SyncEvent_MessageRedactedCopyWith<$Res> {
  _$SyncEvent_MessageRedactedCopyWithImpl(this._self, this._then);

  final SyncEvent_MessageRedacted _self;
  final $Res Function(SyncEvent_MessageRedacted) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,Object? eventId = null,}) {
  return _then(SyncEvent_MessageRedacted(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,eventId: null == eventId ? _self.eventId : eventId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SyncEvent_PinnedMessagesChanged extends SyncEvent {
  const SyncEvent_PinnedMessagesChanged({required this.roomId}): super._();
  

 final  String roomId;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_PinnedMessagesChangedCopyWith<SyncEvent_PinnedMessagesChanged> get copyWith => _$SyncEvent_PinnedMessagesChangedCopyWithImpl<SyncEvent_PinnedMessagesChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_PinnedMessagesChanged&&(identical(other.roomId, roomId) || other.roomId == roomId));
}


@override
int get hashCode => Object.hash(runtimeType,roomId);

@override
String toString() {
  return 'SyncEvent.pinnedMessagesChanged(roomId: $roomId)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_PinnedMessagesChangedCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_PinnedMessagesChangedCopyWith(SyncEvent_PinnedMessagesChanged value, $Res Function(SyncEvent_PinnedMessagesChanged) _then) = _$SyncEvent_PinnedMessagesChangedCopyWithImpl;
@useResult
$Res call({
 String roomId
});




}
/// @nodoc
class _$SyncEvent_PinnedMessagesChangedCopyWithImpl<$Res>
    implements $SyncEvent_PinnedMessagesChangedCopyWith<$Res> {
  _$SyncEvent_PinnedMessagesChangedCopyWithImpl(this._self, this._then);

  final SyncEvent_PinnedMessagesChanged _self;
  final $Res Function(SyncEvent_PinnedMessagesChanged) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,}) {
  return _then(SyncEvent_PinnedMessagesChanged(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SyncEvent_RoomMembersChanged extends SyncEvent {
  const SyncEvent_RoomMembersChanged({required this.roomId}): super._();
  

 final  String roomId;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_RoomMembersChangedCopyWith<SyncEvent_RoomMembersChanged> get copyWith => _$SyncEvent_RoomMembersChangedCopyWithImpl<SyncEvent_RoomMembersChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_RoomMembersChanged&&(identical(other.roomId, roomId) || other.roomId == roomId));
}


@override
int get hashCode => Object.hash(runtimeType,roomId);

@override
String toString() {
  return 'SyncEvent.roomMembersChanged(roomId: $roomId)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_RoomMembersChangedCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_RoomMembersChangedCopyWith(SyncEvent_RoomMembersChanged value, $Res Function(SyncEvent_RoomMembersChanged) _then) = _$SyncEvent_RoomMembersChangedCopyWithImpl;
@useResult
$Res call({
 String roomId
});




}
/// @nodoc
class _$SyncEvent_RoomMembersChangedCopyWithImpl<$Res>
    implements $SyncEvent_RoomMembersChangedCopyWith<$Res> {
  _$SyncEvent_RoomMembersChangedCopyWithImpl(this._self, this._then);

  final SyncEvent_RoomMembersChanged _self;
  final $Res Function(SyncEvent_RoomMembersChanged) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,}) {
  return _then(SyncEvent_RoomMembersChanged(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SyncEvent_IgnoredUsersChanged extends SyncEvent {
  const SyncEvent_IgnoredUsersChanged(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_IgnoredUsersChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.ignoredUsersChanged()';
}


}




// dart format on
