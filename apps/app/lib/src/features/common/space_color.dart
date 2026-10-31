import 'package:flutter/material.dart';

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
    return DropdownButtonFormField<String>(
      key: const ValueKey('space-color-selector'),
      initialValue: spaceColorNames.contains(value) ? value : '',
      decoration: const InputDecoration(labelText: 'Space color'),
      items: [
        const DropdownMenuItem(value: '', child: Text('No color')),
        for (final name in spaceColorNames)
          DropdownMenuItem(
            value: name,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: spaceIdentityColor(name, isDark: isDark),
                      borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 8),
              Text(name),
            ]),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (value) => onChanged!(value == '' ? null : value),
    );
  }
}
