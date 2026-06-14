import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';

/// Edit the current user's display name and avatar.
///
/// Replaces the "个人资料功能开发中" placeholder on the settings page. Fetches
/// the live profile from the homeserver so the editor starts accurate even
/// before the local cache is populated.
class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  late final TextEditingController _nameController;
  rust.UserProfile? _profile;
  String? _avatarHttpUrl; // resolved http URL for preview
  bool _loading = true;
  bool _saving = false;
  final _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final current = ref.read(currentUserProvider);
    _nameController = TextEditingController(text: current?.displayName ?? '');
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await rust.getProfile();
      _profile = profile;
      _nameController.text = profile.displayName;
      // Resolve avatar for preview.
      _avatarHttpUrl =
          await resolveMxcUrl(ref, profile.avatarUrl) ??
          await resolveMxcUrl(ref, ref.read(currentUserProvider)?.avatarUrl);
    } catch (e) {
      // Fall back to whatever the local session already has.
      final current = ref.read(currentUserProvider);
      _avatarHttpUrl = await resolveMxcUrl(ref, current?.avatarUrl);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAvatar() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) return;

      // Crop step via image_cropper: full pan/zoom UI, locked to square for an
      // avatar. Returns the cropped file path, or null if the user cancels.
      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁切头像',
            toolbarColor: AppColors.surface,
            toolbarWidgetColor: AppColors.onBackground,
            activeControlsWidgetColor: AppColors.primary,
            lockAspectRatio: true,
            aspectRatioPresets: [CropAspectRatioPreset.square],
          ),
          IOSUiSettings(
            title: '裁切头像',
            aspectRatioPresets: [CropAspectRatioPreset.square],
            aspectRatioLockEnabled: true,
          ),
        ],
      );
      if (cropped == null) return;
      final bytes = await cropped.readAsBytes();

      setState(() => _saving = true);
      final mxc = await rust.uploadAvatar(
        contentType: 'image/jpeg',
        data: bytes,
      );
      await rust.setAvatarUrl(mxc: mxc);
      // Refresh local preview.
      final http = await resolveMxcUrl(ref, mxc);
      if (mounted) {
        setState(() {
          _avatarHttpUrl = http;
          _saving = false;
        });
        _refreshCurrentUser(avatarUrl: mxc);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('头像已更新'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('头像更新失败: $e')),
        );
      }
    }
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('昵称不能为空')),
      );
      return;
    }
    // Skip if unchanged.
    if (name == _profile?.displayName) return;

    setState(() => _saving = true);
    try {
      await rust.setDisplayName(name: name);
      _refreshCurrentUser();
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('昵称已更新'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('昵称更新失败: $e')),
        );
      }
    }
  }

  /// Update the local CurrentUser cache so other pages reflect the change
  /// immediately without waiting for the next sync. Pass `avatarUrl` when
  /// a fresh avatar upload just completed.
  void _refreshCurrentUser({String? avatarUrl}) {
    final current = ref.read(currentUserProvider);
    if (current == null) return;
    final name = _nameController.text.trim();
    ref.read(currentUserProvider.notifier).value = current.copyWith(
      displayName: name.isEmpty ? current.displayName : name,
      avatarUrl: avatarUrl ?? _profile?.avatarUrl ?? current.avatarUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fallbackName =
        _profile?.displayName.isNotEmpty == true
        ? _profile!.displayName
        : (ref.read(currentUserProvider)?.displayName ?? '我');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const Text('个人资料'),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar editor
                  Center(
                    child: GestureDetector(
                      onTap: _saving ? null : _pickAvatar,
                      child: Stack(
                        children: [
                          AppAvatar(
                            fallback: fallbackName,
                            size: 96,
                            url: _avatarHttpUrl,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.background,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.camera_alt_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      '点击头像更换',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Display name editor
                  const Text(
                    '昵称',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.surface,
                      hintText: '输入你的昵称',
                      hintStyle: TextStyle(
                        color: AppColors.onSurfaceVariant,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.content),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: TextButton(
                        onPressed: _saving ? null : _saveName,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('保存'),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _saveName(),
                  ),

                  const SizedBox(height: 24),

                  // User ID (read-only)
                  const Text(
                    '用户 ID',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadii.content),
                    ),
                    child: Text(
                      _profile?.userId ??
                          ref.read(currentUserProvider)?.id ??
                          '',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '用户 ID 是你的唯一标识，无法更改',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
