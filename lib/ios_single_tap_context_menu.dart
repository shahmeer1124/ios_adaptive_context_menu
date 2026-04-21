/// Adaptive single-tap context menu widgets and models for iOS and Android.
library ios_single_tap_context_menu;

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:svg_flutter/svg.dart';

/// Base type for all context menu entries.
@immutable
abstract class IosContextMenuItem {
  /// Creates a menu entry.
  const IosContextMenuItem();
}

/// Visual separator between action groups.
@immutable
class IosContextMenuDivider extends IosContextMenuItem {
  /// Creates a divider item.
  const IosContextMenuDivider();

  @override
  bool operator ==(Object other) => other is IosContextMenuDivider;

  @override
  int get hashCode => 0;
}

/// Nested menu entry that opens a child list of items.
@immutable
class IosContextMenuSubmenu extends IosContextMenuItem {
  /// Creates a submenu entry.
  const IosContextMenuSubmenu({
    required this.title,
    required this.children,
    this.iconSystemName,
    this.iconAssetPath,
  });

  /// Label shown for this submenu.
  final String title;

  /// SF Symbol name used on iOS when provided.
  final String? iconSystemName;

  /// Asset path for an icon image.
  final String? iconAssetPath;

  /// Child items shown when the submenu opens.
  final List<IosContextMenuItem> children;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is IosContextMenuSubmenu &&
        other.title == title &&
        other.iconSystemName == iconSystemName &&
        other.iconAssetPath == iconAssetPath &&
        listEquals(other.children, children);
  }

  @override
  int get hashCode => Object.hash(
        title,
        iconSystemName,
        iconAssetPath,
        Object.hashAll(children),
      );
}

/// Tappable action in the context menu.
@immutable
class IosContextMenuAction extends IosContextMenuItem {
  /// Creates an action entry.
  const IosContextMenuAction({
    required this.id,
    required this.title,
    this.iconSystemName,
    this.iconAssetPath,
    this.showTrailingCheckmark = false,
    this.destructive = false,
    this.enabled = true,
  });

  /// Unique action identifier returned in [IosSingleTapContextMenu.onSelected].
  final String id;

  /// Label shown to the user.
  final String title;

  /// SF Symbol name used on iOS when provided.
  final String? iconSystemName;

  /// Asset path for an icon image.
  final String? iconAssetPath;

  /// Whether to show a trailing checkmark.
  final bool showTrailingCheckmark;

  /// Marks this action as destructive.
  final bool destructive;

  /// Whether this action can be selected.
  final bool enabled;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is IosContextMenuAction &&
        other.id == id &&
        other.title == title &&
        other.iconSystemName == iconSystemName &&
        other.iconAssetPath == iconAssetPath &&
        other.showTrailingCheckmark == showTrailingCheckmark &&
        other.destructive == destructive &&
        other.enabled == enabled;
  }

  @override
  int get hashCode => Object.hash(
        id,
        title,
        iconSystemName,
        iconAssetPath,
        showTrailingCheckmark,
        destructive,
        enabled,
      );
}

/// Single-tap adaptive context menu widget.
///
/// On iOS it presents native `UIMenu`. On Android it shows a Material popup
/// menu while keeping the same action model.
class IosSingleTapContextMenu extends StatefulWidget {
  /// Creates a single-tap context menu host.
  const IosSingleTapContextMenu({
    super.key,
    required this.child,
    required this.actions,
    this.onSelected,
  });

  /// Child widget that triggers the menu.
  final Widget child;

  /// Menu items shown when the user taps [child].
  final List<IosContextMenuItem> actions;

  /// Callback invoked with selected [IosContextMenuAction.id].
  final ValueChanged<String>? onSelected;

  @override
  State<IosSingleTapContextMenu> createState() =>
      _IosSingleTapContextMenuState();
}

class _IosSingleTapContextMenuState extends State<IosSingleTapContextMenu> {
  static const int _targetIconPx = 36;
  static const double _androidMenuMinWidth = 202;
  static const MethodChannel _iosHostChannel =
      MethodChannel('ios_adaptive_context_menu/methods');

  final Map<String, Uint8List?> _iconBytesCache = <String, Uint8List?>{};
  late final String _instanceId;
  late final MethodChannel _iosInstanceChannel;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _instanceId =
        '${identityHashCode(this)}_${DateTime.now().microsecondsSinceEpoch}';
    _iosInstanceChannel = MethodChannel(
      'ios_adaptive_context_menu/instance_$_instanceId',
    );
    _iosInstanceChannel.setMethodCallHandler(_handleCallback);
  }

  @override
  void dispose() {
    if (_isIos) {
      _iosHostChannel.invokeMethod<void>('disposeInstance', {
        'instanceId': _instanceId,
      });
    }
    _iosInstanceChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) {
      return widget.child;
    }

    if (_isIos) {
      return _buildIosHost();
    }

    if (_isAndroid) {
      return _buildAndroidHost();
    }

    return widget.child;
  }

  Widget _buildIosHost() {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: 1,
      onPressed: _showIosMenu,
      child: AbsorbPointer(child: widget.child),
    );
  }

  Future<void> _showIosMenu() async {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) {
      return;
    }

    final Rect anchorRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final params = await _buildCreationParams();
    params['instanceId'] = _instanceId;
    params['x'] = anchorRect.left;
    params['y'] = anchorRect.top;
    params['width'] = anchorRect.width;
    params['height'] = anchorRect.height;

    await _iosHostChannel.invokeMethod<void>('showMenu', params);
  }

  Widget _buildAndroidHost() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _showAndroidMenu,
      child: widget.child,
    );
  }

  Future<void> _showAndroidMenu(TapDownDetails details) async {
    _assertAndroidIcons(widget.actions);

    final selectedId = await _showAndroidMenuForItems(
      context: context,
      position: details.globalPosition,
      items: widget.actions,
    );

    if (selectedId != null && widget.onSelected != null) {
      widget.onSelected!(selectedId);
    }
  }

  Future<String?> _showAndroidMenuForItems({
    required BuildContext context,
    required Offset position,
    required List<IosContextMenuItem> items,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final menuItems = _buildAndroidPopupEntries(items);

    if (menuItems.isEmpty) {
      return null;
    }

    final selected = await showMenu<_AndroidMenuResult>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );

    if (selected == null) {
      return null;
    }

    return selected.actionId;
  }

  List<PopupMenuEntry<_AndroidMenuResult>> _buildAndroidPopupEntries(
    List<IosContextMenuItem> items,
  ) {
    final entries = <PopupMenuEntry<_AndroidMenuResult>>[];
    final dividerColor = Theme.of(context).dividerColor.withValues(alpha: 0.2);
    final flatItems = _flattenForAndroid(items);

    void addDividerIfNeeded() {
      if (entries.isEmpty || entries.last is _AndroidPopupDivider) {
        return;
      }
      entries.add(
        _AndroidPopupDivider(
          color: dividerColor,
          height: 10,
          thickness: 1,
          horizontalPadding: 10,
        ),
      );
    }

    for (final item in flatItems) {
      if (item is IosContextMenuDivider) {
        addDividerIfNeeded();
        continue;
      }

      if (item is IosContextMenuAction) {
        entries.add(
          PopupMenuItem<_AndroidMenuResult>(
            enabled: item.enabled,
            value: _AndroidMenuResult.action(item.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: _androidMenuMinWidth),
              child: Row(
                children: [
                  _buildAndroidMenuIcon(item.iconAssetPath),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.title,
                      style: item.destructive
                          ? const TextStyle(color: Colors.red)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    while (entries.isNotEmpty && entries.last is _AndroidPopupDivider) {
      entries.removeLast();
    }

    return entries;
  }

  List<IosContextMenuItem> _flattenForAndroid(List<IosContextMenuItem> items) {
    final result = <IosContextMenuItem>[];
    for (final item in items) {
      if (item is IosContextMenuSubmenu) {
        result.addAll(_flattenForAndroid(item.children));
      } else {
        result.add(item);
      }
    }
    return result;
  }

  Widget _buildAndroidMenuIcon(String? assetPath) {
    final safeAsset = assetPath ?? '';
    return SvgPicture.asset(
      safeAsset,
      width: 20,
      height: 20,
    );
  }

  void _assertAndroidIcons(List<IosContextMenuItem> items) {
    for (final item in items) {
      if (item is IosContextMenuAction) {
        if (item.iconAssetPath == null || item.iconAssetPath!.isEmpty) {
          throw FlutterError(
            'Android context menu requires iconAssetPath for every action. '
            'Missing for action id: ${item.id}',
          );
        }
      } else if (item is IosContextMenuSubmenu) {
        if (item.iconAssetPath == null || item.iconAssetPath!.isEmpty) {
          throw FlutterError(
            'Android context menu requires iconAssetPath for every submenu. '
            'Missing for submenu title: ${item.title}',
          );
        }
        _assertAndroidIcons(item.children);
      }
    }
  }

  Future<Map<String, Object?>> _buildCreationParams() async {
    final serialized = <Map<String, Object?>>[];
    for (final item in widget.actions) {
      serialized.add(await _serializeItem(item));
    }
    return <String, Object?>{'actions': serialized};
  }

  Future<Map<String, Object?>> _serializeItem(IosContextMenuItem item) async {
    if (item is IosContextMenuDivider) {
      return const <String, Object?>{'type': 'divider'};
    }

    if (item is IosContextMenuAction) {
      return _serializeAction(item);
    }

    if (item is IosContextMenuSubmenu) {
      return _serializeSubmenu(item);
    }

    return const <String, Object?>{};
  }

  Future<Map<String, Object?>> _serializeAction(
      IosContextMenuAction action) async {
    final map = <String, Object?>{
      'type': 'action',
      'id': action.id,
      'title': action.title,
      'iconSystemName': action.iconSystemName,
      'showTrailingCheckmark': action.showTrailingCheckmark,
      'destructive': action.destructive,
      'enabled': action.enabled,
    };

    if (action.iconSystemName == null || action.iconSystemName!.isEmpty) {
      await _attachIconBytes(map, action.iconAssetPath);
    }
    return map;
  }

  Future<Map<String, Object?>> _serializeSubmenu(
      IosContextMenuSubmenu submenu) async {
    final children = <Map<String, Object?>>[];
    for (final item in submenu.children) {
      children.add(await _serializeItem(item));
    }

    final map = <String, Object?>{
      'type': 'submenu',
      'title': submenu.title,
      'iconSystemName': submenu.iconSystemName,
      'children': children,
    };

    if (submenu.iconSystemName == null || submenu.iconSystemName!.isEmpty) {
      await _attachIconBytes(map, submenu.iconAssetPath);
    }
    return map;
  }

  Future<void> _attachIconBytes(
      Map<String, Object?> map, String? iconAssetPath) async {
    if (iconAssetPath == null || iconAssetPath.isEmpty) {
      return;
    }

    final iconBytes = await _resolveIconBytes(iconAssetPath);
    if (iconBytes != null && iconBytes.isNotEmpty) {
      map['iconPngBytes'] = iconBytes;
    }
  }

  Future<Uint8List?> _resolveIconBytes(String assetPath) async {
    if (_iconBytesCache.containsKey(assetPath)) {
      return _iconBytesCache[assetPath];
    }

    try {
      if (_isSvg(assetPath)) {
        final bytes = await _rasterizeSvgToPng(assetPath);
        _iconBytesCache[assetPath] = bytes;
        return bytes;
      }

      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      _iconBytesCache[assetPath] = bytes;
      return bytes;
    } catch (_) {
      _iconBytesCache[assetPath] = null;
      return null;
    }
  }

  bool _isSvg(String path) => path.toLowerCase().endsWith('.svg');

  Future<Uint8List?> _rasterizeSvgToPng(String assetPath) async {
    final pictureInfo = await vg.loadPicture(SvgAssetLoader(assetPath), null);
    final sourceSize = pictureInfo.size;

    final sourceWidth = sourceSize.width > 0 && sourceSize.width.isFinite
        ? sourceSize.width
        : _targetIconPx.toDouble();
    final sourceHeight = sourceSize.height > 0 && sourceSize.height.isFinite
        ? sourceSize.height
        : _targetIconPx.toDouble();

    final scale = _targetIconPx / math.max(sourceWidth, sourceHeight);
    final outWidth = (sourceWidth * scale).round().clamp(18, 72);
    final outHeight = (sourceHeight * scale).round().clamp(18, 72);

    final ui.Image image =
        await pictureInfo.picture.toImage(outWidth, outHeight);
    final ByteData? byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );

    image.dispose();
    pictureInfo.picture.dispose();

    return byteData?.buffer.asUint8List();
  }

  Future<void> _handleCallback(MethodCall call) async {
    if (call.method != 'onSelected' || widget.onSelected == null) {
      return;
    }

    final Object? args = call.arguments;
    if (args is! Map<Object?, Object?>) {
      return;
    }

    final Object? rawId = args['id'];
    if (rawId is String && rawId.isNotEmpty) {
      widget.onSelected!.call(rawId);
    }
  }
}

@immutable
class _AndroidMenuResult {
  const _AndroidMenuResult._({this.actionId});

  const _AndroidMenuResult.action(String id) : this._(actionId: id);

  final String? actionId;
}

class _AndroidPopupDivider extends PopupMenuEntry<_AndroidMenuResult> {
  const _AndroidPopupDivider({
    required this.color,
    required this.height,
    required this.thickness,
    required this.horizontalPadding,
  });

  final Color color;
  final double thickness;
  final double horizontalPadding;

  @override
  final double height;

  @override
  bool represents(_AndroidMenuResult? value) => false;

  @override
  State<_AndroidPopupDivider> createState() => _AndroidPopupDividerState();
}

class _AndroidPopupDividerState extends State<_AndroidPopupDivider> {
  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final strokeWidth = 1 / pixelRatio;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          height: strokeWidth,
          width: double.infinity,
          child: CustomPaint(
            painter: _AndroidDividerPainter(
              color: widget.color,
              strokeWidth: strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _AndroidDividerPainter extends CustomPainter {
  const _AndroidDividerPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..isAntiAlias = false
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    final y = strokeWidth / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(covariant _AndroidDividerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
