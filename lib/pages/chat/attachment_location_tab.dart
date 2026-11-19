import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/neu_decoration.dart';
import 'attachment_picker_controls.dart';

class AttachmentLocationTab extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(String body, String geoUri) onSendLocation;

  const AttachmentLocationTab({
    super.key,
    required this.isSending,
    required this.scrollController,
    required this.onSendLocation,
  });

  @override
  State<AttachmentLocationTab> createState() => _AttachmentLocationTabState();
}

class _AttachmentLocationTabState extends State<AttachmentLocationTab> {
  final MapController _mapController = MapController();
  ll.LatLng? _selected;
  bool _locating = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final point = await currentAttachmentLocation();
      if (!mounted) return;
      setState(() {
        _selected = point;
        _locating = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(point, 16);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final selected = _selected;
    if (selected == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            24,
            24,
            24,
            attachmentDockClearance,
          ),
          child: _locating
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: colors.accent),
                    const SizedBox(height: 12),
                    Text(
                      '正在获取当前位置',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.location_off_rounded,
                      color: colors.textTertiary,
                      size: 36,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _error ?? '无法获取当前位置',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    NeuButton(
                      onPressed: widget.isSending ? null : _locate,
                      icon: const Icon(Icons.my_location_rounded),
                      child: const Text('重新定位'),
                    ),
                  ],
                ),
        ),
      );
    }

    final geoUri = canonicalGeoUri(
      selected.latitude.toString(),
      selected.longitude.toString(),
    )!;
    return Stack(
      children: [
        // Keep the sheet controller attached without covering map gestures.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 0,
          child: SingleChildScrollView(
            controller: widget.scrollController,
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            child: const SizedBox(height: 1),
          ),
        ),
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: selected,
              initialZoom: 16,
              maxZoom: 19,
              onTap: (_, point) {
                if (!widget.isSending) setState(() => _selected = point);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'moe.aks.matter',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: selected,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(
                      Icons.location_on_rounded,
                      size: 42,
                      color: colors.accent,
                    ),
                  ),
                ],
              ),
              SimpleAttributionWidget(
                alignment: Alignment.topLeft,
                backgroundColor: colors.surfaceStrong.withValues(alpha: 0.82),
                source: const Text(
                  'OpenStreetMap contributors',
                  style: TextStyle(fontSize: 9),
                ),
                onTap: () {
                  unawaited(
                    launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: _locating
              ? NeuSurface(
                  depth: NeuDepth.flat,
                  radius: 20,
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(11),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                )
              : NeuIconButton(
                  tooltip: '回到当前位置',
                  size: 40,
                  onPressed: widget.isSending ? null : _locate,
                  icon: Icons.my_location_rounded,
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AttachmentSendBar(
            label: '发送',
            isSending: widget.isSending,
            onSend: () => widget.onSendLocation('位置', geoUri),
          ),
        ),
      ],
    );
  }
}

final _decimalCoordinate = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');

double? _parseCoordinate(String raw, {required double maxAbsolute}) {
  final valueText = raw.trim();
  if (!_decimalCoordinate.hasMatch(valueText)) return null;
  final value = double.tryParse(valueText);
  if (value == null || !value.isFinite || value.abs() > maxAbsolute) {
    return null;
  }
  return value;
}

String _formatCoordinate(double value) {
  if (value == 0) return '0';
  var result = value.toStringAsFixed(12);
  result = result.replaceFirst(RegExp(r'0+$'), '');
  return result.replaceFirst(RegExp(r'\.$'), '');
}

@visibleForTesting
String? canonicalGeoUri(String latitude, String longitude) {
  final lat = _parseCoordinate(latitude, maxAbsolute: 90);
  final lng = _parseCoordinate(longitude, maxAbsolute: 180);
  if (lat == null || lng == null) return null;
  return 'geo:${_formatCoordinate(lat)},${_formatCoordinate(lng)}';
}

@visibleForTesting
Future<ll.LatLng> currentAttachmentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const _AttachmentLocationException('请先开启系统定位服务');
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw const _AttachmentLocationException('未获得定位权限');
  }
  if (permission == LocationPermission.deniedForever) {
    throw const _AttachmentLocationException('定位权限已被永久拒绝，请在系统设置中开启');
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 12),
    ),
  );
  return ll.LatLng(position.latitude, position.longitude);
}

class _AttachmentLocationException implements Exception {
  final String message;

  const _AttachmentLocationException(this.message);

  @override
  String toString() => message;
}
