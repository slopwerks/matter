import 'package:flutter/material.dart';
import '../../src/rust/api/matrix.dart' as rust;

class StickerPack {
  final String id;
  final String title;
  final String accent;
  final String source;
  final String? avatarUrl;
  final List<StickerItem> stickers;

  const StickerPack({
    required this.id,
    required this.title,
    required this.accent,
    required this.source,
    this.avatarUrl,
    required this.stickers,
  });
}

class StickerItem {
  final String id;
  final String label;
  final String body;
  final String? glyph;
  final String? payload;
  final List<Color> colors;
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? mimeType;
  final int? width;
  final int? height;

  const StickerItem({
    required this.id,
    required this.label,
    required this.body,
    this.glyph,
    this.payload,
    required this.colors,
    this.imageUrl,
    this.thumbnailUrl,
    this.mimeType,
    this.width,
    this.height,
  });

  bool get isRemote => imageUrl != null;

  double get aspectRatio {
    final w = width;
    final h = height;
    if (w != null && h != null && w > 0 && h > 0) {
      return w / h;
    }
    return 1.0;
  }
}

List<StickerPack> stickerPacksFromRemote(List<rust.StickerPack> packs) {
  return packs.asMap().entries.map((entry) {
    final index = entry.key;
    final pack = entry.value;
    final palette = _remotePalettes[index % _remotePalettes.length];
    final accent = switch (pack.source) {
      'room' => '房',
      'user' => '我',
      _ => '✦',
    };
    return StickerPack(
      id: pack.id,
      title: pack.title,
      accent: accent,
      source: pack.source,
      avatarUrl: pack.avatarUrl,
      stickers: pack.stickers.map((sticker) {
        return StickerItem(
          id: '${pack.id}:${sticker.id}',
          label: sticker.body,
          body: sticker.body,
          colors: palette,
          imageUrl: sticker.imageUrl,
          thumbnailUrl: sticker.thumbnailUrl,
          mimeType: sticker.mimeType,
          width: sticker.width,
          height: sticker.height,
        );
      }).toList(),
    );
  }).toList();
}

const _remotePalettes = <List<Color>>[
  [Color(0xFF4C6EF5), Color(0xFF748FFC)],
  [Color(0xFF0CA678), Color(0xFF3BC9DB)],
  [Color(0xFFFF922B), Color(0xFFFFC078)],
  [Color(0xFFAE3EC9), Color(0xFFDA77F2)],
  [Color(0xFF1098AD), Color(0xFF66D9E8)],
  [Color(0xFFD6336C), Color(0xFFF783AC)],
];

const kStickerPacks = <StickerPack>[
  StickerPack(
    id: 'daily',
    title: '日常团子',
    accent: '●',
    source: 'local',
    stickers: [
      StickerItem(
        id: 'daily-daola',
        glyph: 'ฅ^•ﻌ•^ฅ',
        label: '到啦',
        body: '到啦',
        payload: 'ฅ^•ﻌ•^ฅ',
        colors: [Color(0xFF4C6EF5), Color(0xFF748FFC)],
      ),
      StickerItem(
        id: 'daily-shoudao',
        glyph: '( ˶ˆᗜˆ˵ )',
        label: '收到',
        body: '收到',
        payload: '( ˶ˆᗜˆ˵ )',
        colors: [Color(0xFF0CA678), Color(0xFF3BC9DB)],
      ),
      StickerItem(
        id: 'daily-chongya',
        glyph: '(ง •̀_•́)ง',
        label: '冲鸭',
        body: '冲鸭',
        payload: '(ง •̀_•́)ง',
        colors: [Color(0xFFFF922B), Color(0xFFFFC078)],
      ),
      StickerItem(
        id: 'daily-anpai',
        glyph: '(｡•̀ᴗ-)✧',
        label: '安排',
        body: '安排',
        payload: '(｡•̀ᴗ-)✧',
        colors: [Color(0xFFAE3EC9), Color(0xFFDA77F2)],
      ),
      StickerItem(
        id: 'daily-chifan',
        glyph: '(っ˘ڡ˘ς)',
        label: '吃饭',
        body: '吃饭',
        payload: '(っ˘ڡ˘ς)',
        colors: [Color(0xFFE8590C), Color(0xFFFFA94D)],
      ),
      StickerItem(
        id: 'daily-shuile',
        glyph: '(¦3[▓▓]',
        label: '睡了',
        body: '睡了',
        payload: '(¦3[▓▓]',
        colors: [Color(0xFF364FC7), Color(0xFF91A7FF)],
      ),
      StickerItem(
        id: 'daily-moyu',
        glyph: '(´-ω-`)',
        label: '摸鱼',
        body: '摸鱼',
        payload: '(´-ω-`)',
        colors: [Color(0xFF2B8A3E), Color(0xFF69DB7C)],
      ),
      StickerItem(
        id: 'daily-baobao',
        glyph: '(づ｡◕‿‿◕｡)づ',
        label: '抱抱',
        body: '抱抱',
        payload: '(づ｡◕‿‿◕｡)づ',
        colors: [Color(0xFF1971C2), Color(0xFF74C0FC)],
      ),
    ],
  ),
  StickerPack(
    id: 'mood',
    title: '情绪弹幕',
    accent: '★',
    source: 'local',
    stickers: [
      StickerItem(
        id: 'mood-kaixin',
        glyph: '٩(ˊᗜˋ*)و',
        label: '开心',
        body: '开心',
        payload: '٩(ˊᗜˋ*)و',
        colors: [Color(0xFFF76707), Color(0xFFFFD43B)],
      ),
      StickerItem(
        id: 'mood-weiqu',
        glyph: '(╥﹏╥)',
        label: '委屈',
        body: '委屈',
        payload: '(╥﹏╥)',
        colors: [Color(0xFF4263EB), Color(0xFF91A7FF)],
      ),
      StickerItem(
        id: 'mood-wuyu',
        glyph: '(¬_¬)',
        label: '无语',
        body: '无语',
        payload: '(¬_¬)',
        colors: [Color(0xFF495057), Color(0xFF868E96)],
      ),
      StickerItem(
        id: 'mood-xianzhuo',
        glyph: '(╯°□°）╯︵ ┻━┻',
        label: '掀桌',
        body: '掀桌',
        payload: '(╯°□°）╯︵ ┻━┻',
        colors: [Color(0xFFC92A2A), Color(0xFFFF8787)],
      ),
      StickerItem(
        id: 'mood-qinqin',
        glyph: '(づ￣ 3￣)づ',
        label: '亲亲',
        body: '亲亲',
        payload: '(づ￣ 3￣)づ',
        colors: [Color(0xFFD6336C), Color(0xFFF783AC)],
      ),
      StickerItem(
        id: 'mood-buxing',
        glyph: '(｡•́︿•̀｡)',
        label: '不行',
        body: '不行',
        payload: '(｡•́︿•̀｡)',
        colors: [Color(0xFF5F3DC4), Color(0xFFB197FC)],
      ),
      StickerItem(
        id: 'mood-liule',
        glyph: 'ᕕ( ᐛ )ᕗ',
        label: '溜了',
        body: '溜了',
        payload: 'ᕕ( ᐛ )ᕗ',
        colors: [Color(0xFF087F5B), Color(0xFF63E6BE)],
      ),
      StickerItem(
        id: 'mood-wenzhu',
        glyph: '(•̀ᴗ•́)و ̑̑',
        label: '稳住',
        body: '稳住',
        payload: '(•̀ᴗ•́)و ̑̑',
        colors: [Color(0xFF1D4ED8), Color(0xFF60A5FA)],
      ),
    ],
  ),
  StickerPack(
    id: 'pixel',
    title: '像素反应',
    accent: '■',
    source: 'local',
    stickers: [
      StickerItem(
        id: 'pixel-laman',
        glyph: '▂▃▄▅▆▇█',
        label: '拉满',
        body: '拉满',
        payload: '▂▃▄▅▆▇█',
        colors: [Color(0xFF2F9E44), Color(0xFF8CE99A)],
      ),
      StickerItem(
        id: 'pixel-tuijin',
        glyph: '>>>',
        label: '推进',
        body: '推进',
        payload: '>>>',
        colors: [Color(0xFF1864AB), Color(0xFF74C0FC)],
      ),
      StickerItem(
        id: 'pixel-jingjue',
        glyph: '!!!',
        label: '警觉',
        body: '警觉',
        payload: '!!!',
        colors: [Color(0xFFC92A2A), Color(0xFFFFA8A8)],
      ),
      StickerItem(
        id: 'pixel-guaji',
        glyph: 'ZzZ',
        label: '挂机',
        body: '挂机',
        payload: 'ZzZ',
        colors: [Color(0xFF5C7CFA), Color(0xFFB197FC)],
      ),
      StickerItem(
        id: 'pixel-tongguo',
        glyph: 'OK',
        label: '通过',
        body: '通过',
        payload: 'OK',
        colors: [Color(0xFF099268), Color(0xFF63E6BE)],
      ),
      StickerItem(
        id: 'pixel-dahui',
        glyph: 'NOPE',
        label: '打回',
        body: '打回',
        payload: 'NOPE',
        colors: [Color(0xFFE03131), Color(0xFFFF8787)],
      ),
      StickerItem(
        id: 'pixel-jieshu',
        glyph: 'GG',
        label: '结束',
        body: '结束',
        payload: 'GG',
        colors: [Color(0xFF6C757D), Color(0xFFADB5BD)],
      ),
      StickerItem(
        id: 'pixel-likai',
        glyph: 'AFK',
        label: '离开',
        body: '离开',
        payload: 'AFK',
        colors: [Color(0xFF7048E8), Color(0xFFB197FC)],
      ),
    ],
  ),
  StickerPack(
    id: 'soft',
    title: '软糖空气',
    accent: '✦',
    source: 'local',
    stickers: [
      StickerItem(
        id: 'soft-nihaoya',
        glyph: '૮₍ ˶ᵔ ᵕ ᵔ˶ ₎ა',
        label: '你好呀',
        body: '你好呀',
        payload: '૮₍ ˶ᵔ ᵕ ᵔ˶ ₎ა',
        colors: [Color(0xFFFF6B6B), Color(0xFFFFC2D1)],
      ),
      StickerItem(
        id: 'soft-tietie',
        glyph: '(っ´ω`c)',
        label: '贴贴',
        body: '贴贴',
        payload: '(っ´ω`c)',
        colors: [Color(0xFFFF8787), Color(0xFFFFD8A8)],
      ),
      StickerItem(
        id: 'soft-baituo',
        glyph: '(*ฅ́˘ฅ̀*)',
        label: '拜托',
        body: '拜托',
        payload: '(*ฅ́˘ฅ̀*)',
        colors: [Color(0xFFCC5DE8), Color(0xFFEEBEFA)],
      ),
      StickerItem(
        id: 'soft-renzhen',
        glyph: '(๑•̀ㅂ•́)و✧',
        label: '认真',
        body: '认真',
        payload: '(๑•̀ㅂ•́)و✧',
        colors: [Color(0xFF339AF0), Color(0xFF99E9F2)],
      ),
      StickerItem(
        id: 'soft-cengceng',
        glyph: '(っ˘ω˘ς )',
        label: '蹭蹭',
        body: '蹭蹭',
        payload: '(っ˘ω˘ς )',
        colors: [Color(0xFFFF922B), Color(0xFFFFEC99)],
      ),
      StickerItem(
        id: 'soft-yanhu',
        glyph: 'ʕっ•ᴥ•ʔっ',
        label: '援护',
        body: '援护',
        payload: 'ʕっ•ᴥ•ʔっ',
        colors: [Color(0xFF20C997), Color(0xFF96F2D7)],
      ),
      StickerItem(
        id: 'soft-guaiqiao',
        glyph: '(´｡• ᵕ •｡`)',
        label: '乖巧',
        body: '乖巧',
        payload: '(´｡• ᵕ •｡`)',
        colors: [Color(0xFF845EF7), Color(0xFFD0BFFF)],
      ),
      StickerItem(
        id: 'soft-linggan',
        glyph: '( •⌄• ू )✧',
        label: '灵感',
        body: '灵感',
        payload: '( •⌄• ू )✧',
        colors: [Color(0xFF1098AD), Color(0xFF66D9E8)],
      ),
    ],
  ),
];
