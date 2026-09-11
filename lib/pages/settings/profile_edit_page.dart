import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'avatar_crop_editor_page.dart';

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
          await resolveMxcUrlAvatar(ref, profile.avatarUrl) ??
          await resolveMxcUrlAvatar(
            ref,
            ref.read(currentUserProvider)?.avatarUrl,
          );
    } catch (e) {
      // Fall back to whatever the local session already has.
      final current = ref.read(currentUserProvider);
      _avatarHttpUrl = await resolveMxcUrlAvatar(ref, current?.avatarUrl);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAvatar() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
      if (picked == null) return;

      final sourceBytes = await picked.readAsBytes();
      if (!mounted) return;
      final bytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => AvatarCropEditorPage(imageBytes: sourceBytes),
        ),
      );
      if (bytes == null || !mounted) return;

      setState(() => _saving = true);
      final mxc = await rust.uploadAvatar(
        contentType: 'image/jpeg',
        data: bytes,
      );
      await rust.setAvatarUrl(mxc: mxc);
      // Refresh local preview.
      final http = await resolveMxcUrlAvatar(ref, mxc);
      if (mounted) {
        setState(() {
          _avatarHttpUrl = http;
          _saving = false;
        });
        _refreshCurrentUser(avatarUrl: mxc);
      }
      if (mounted) {
        neuToast(context, '头像已更新');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('头像更新失败: $e')));
      }
    }
  }

  Future<void> _saveName() async {
    if (_saving) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      neuToast(context, '昵称不能为空');
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
        neuToast(context, '昵称已更新');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('昵称更新失败: $e')));
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
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final fallbackName = _profile?.displayName.isNotEmpty == true
        ? _profile!.displayName
        : (ref.read(currentUserProvider)?.displayName ?? '我');
    return Scaffold(
      backgroundColor: colors.base,
      appBar: AppBar(
        backgroundColor: colors.base,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('个人资料', style: textTheme.titleLarge),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : MaxContentWidth(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(NeuSpacing.lg),
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
                                  color: colors.accent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colors.base,
                                    width: 2,
                                  ),
                                ),
                                child: Icon(
                                  Icons.camera_alt_rounded,
                                  color: colors.onAccent,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    Center(child: Text('点击头像更换', style: textTheme.bodySmall)),
                    const SizedBox(height: 32),

                    // Display name editor
                    Text(
                      '昵称',
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    NeuTextField(
                      controller: _nameController,
                      hint: '输入你的昵称',
                      onSubmitted: _saving ? null : (_) => _saveName(),
                    ),
                    const SizedBox(height: NeuSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: NeuButton(
                        accent: true,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: _saving ? null : _saveName,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        child: const Center(child: Text('保存')),
                      ),
                    ),

                    const SizedBox(height: NeuSpacing.xl),

                    // User ID (read-only)
                    Text(
                      '用户 ID',
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    NeuSurface(
                      depth: NeuDepth.pressed,
                      color: colors.card,
                      radius: NeuRadius.content,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      child: Text(
                        _profile?.userId ??
                            ref.read(currentUserProvider)?.id ??
                            '',
                        style: textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    Text('用户 ID 是你的唯一标识，无法更改', style: textTheme.bodySmall),
                  ],
                ),
              ),
            ),
    );
  }
}
