import 'package:media_kit/media_kit.dart';

/// A deterministic player for controls tests; never initializes native media.
class VideoTestPlayer extends PlatformPlayer {
  final rates = <double>[];
  final seeks = <Duration>[];

  VideoTestPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      duration: const Duration(minutes: 3),
      position: const Duration(minutes: 1),
      volume: 50,
    );
  }

  @override
  Future<void> setRate(double value) async {
    rates.add(value);
    state = state.copyWith(rate: value);
    rateController.add(value);
  }

  @override
  Future<void> setVolume(double value) async {
    state = state.copyWith(volume: value);
    volumeController.add(value);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    state = state.copyWith(position: value, completed: false);
    positionController.add(value);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true, completed: false);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  void complete() {
    state = state.copyWith(playing: false, completed: true);
    playingController.add(false);
    completedController.add(true);
  }
}
