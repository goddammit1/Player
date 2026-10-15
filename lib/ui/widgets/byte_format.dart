/// Человекочитаемый размер: «812 B», «4.2 MB», «1.37 GB».
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Компактный размер для прогресса загрузок: «0 B», «812 B», «4.2 MB»,
/// «120 MB» (от 100 единиц — без дробной части).
String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Скорость передачи: «1.2 MB/s».
String formatSpeed(int bytesPerSecond) => '${humanBytes(bytesPerSecond)}/s';
