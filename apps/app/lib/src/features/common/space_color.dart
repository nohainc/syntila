import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

/// Named palette values persist in Space settings; unknown values are neutral.
const spaceColorNames = <String>[
  'Terracotta',
  'Amber',
  'Green',
  'Teal',
  'Blue',
  'Violet',
  'Rose',
  'Olive',
];

Color? spaceIdentityColor(Object? value, {required bool isDark}) {
  final index = spaceColorNames.indexOf(value is String ? value : '');
  if (index < 0) return null;
  const light = <Color>[
    Color(0xFF98513F),
    Color(0xFF896225),
    Color(0xFF39734E),
    Color(0xFF25747B),
    Color(0xFF4567A0),
    Color(0xFF805E9A),
    Color(0xFFA04F72),
    Color(0xFF606C3C),
  ];
  const dark = <Color>[
    Color(0xFFE9A28E),
    Color(0xFFDDBB72),
    Color(0xFF8AC99B),
    Color(0xFF77C8CC),
    Color(0xFF9CB8ED),
    Color(0xFFC7A4E4),
    Color(0xFFE89CB8),
    Color(0xFFB3C783),
  ];
  return (isDark ? dark : light)[index];
}

class SpaceColorSelector extends StatelessWidget {
  const SpaceColorSelector(
      {super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final current = spaceColorNames.contains(value) ? value! : '';
    Widget swatch(String name) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
            color: spaceIdentityColor(name, isDark: isDark),
            border: name.isEmpty
                ? Border.all(color: Theme.of(context).disabledColor)
                : null,
            borderRadius: BorderRadius.circular(3)));
    return PopupMenuButton<String>(
      key: const ValueKey('space-color-selector'),
      enabled: onChanged != null,
      tooltip: 'Choose Space color',
      color: SyntilaColors.composerBackground(isDark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: SyntilaMenuStyle.shadow(isDark),
      shape: SyntilaMenuStyle.shape(isDark),
      menuPadding: SyntilaMenuStyle.padding,
      itemBuilder: (context) => [
        for (final name in ['', ...spaceColorNames])
          SyntilaMenuEntry<String>(
            value: name,
            child: MenuItemButton(
              style: SyntilaMenuStyle.item(isDark),
              leadingIcon: Icon(
                  name == current
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 15),
              onPressed: () => Navigator.pop(context, name),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                swatch(name),
                const SizedBox(width: 8),
                Text(name.isEmpty ? 'No color' : name,
                    style: SyntilaMenuStyle.textStyle),
              ]),
            ),
          ),
      ],
      onSelected: (name) => onChanged!(name.isEmpty ? null : name),
      child: InputDecorator(
        decoration: const InputDecoration(
            labelText: 'Space color', suffixIcon: Icon(Icons.expand_more)),
        child: Row(children: [
          swatch(current),
          const SizedBox(width: 8),
          Text(current.isEmpty ? 'No color' : current),
        ]),
      ),
    );
  }
}
