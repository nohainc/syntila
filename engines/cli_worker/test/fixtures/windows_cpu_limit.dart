import 'dart:io';

void main() {
  if (!Platform.isWindows) exit(77);
  stdout.writeln('cpu-started');
  var value = 1;
  while (true) {
    value = (value * 17 + 3) & 0x7fffffff;
    if (value == 0) stdout.write('');
  }
}
