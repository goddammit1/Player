import 'dart:async';

import 'package:sqflite/sqflite.dart';

/// DAO истории поиска: операции над таблицей `search_history`.
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
class SearchHistoryDao {
  SearchHistoryDao._();
  static final SearchHistoryDao instance = SearchHistoryDao._();

  /// Возвращает историю поиска, новые сверху, не более [limit].
  Future<List<String>> getSearchHistory(Database db, int limit) async {
    final rows = await db.query(
      'search_history',
      columns: ['query'],
      orderBy: 'searched_at_ms DESC',
      limit: limit,
    );
    return rows.map((r) => r['query'] as String).toList();
  }

  /// Записывает историю поиска целиком (с дедупликацией и лимитом).
  Future<void> setSearchHistory(
      Database db, List<String> queries, int limit) async {
    await db.transaction((txn) async {
      await txn.delete('search_history');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < queries.length && i < limit; i++) {
        await txn.insert('search_history', {
          'query': queries[i],
          'searched_at_ms': now - i * 1000,
        });
      }
    });
  }

  /// Добавляет поисковый запрос (атомарно: DELETE + INSERT в одной
  /// транзакции).
  ///
  /// Ключ нормализуется к нижнему регистру при записи, чтобы:
  ///  1) дедупликация была регистронезависимой и попадала по PRIMARY KEY
  ///     `query` (раньше `LOWER(query) = LOWER(?)` делала полный скан Таблицы
  ///     и не использовала индекс);
  ///  2) повторная вставка того же запроса в другом случае не конфликтовая
  ///     с существующим ключом.
  /// Следствие: в истории хранится может регистр исходного ввода (все
  /// выводы нижнем регистре), что согласуется с UI-дедупликацией по lower.
  Future<void> addSearchQuery(Database db, String query) async {
    final normalized = query.toLowerCase();
    await db.transaction((txn) async {
      await txn.delete(
        'search_history',
        where: 'query = ?',
        whereArgs: [normalized],
      );
      await txn.insert('search_history', {
        'query': normalized,
        'searched_at_ms': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// Удаляет конкретный поисковый запрос.
  Future<void> removeSearchQuery(Database db, String query) async {
    await db.delete('search_history', where: 'query = ?', whereArgs: [query]);
  }

  /// Очищает всю историю поиска.
  Future<void> clearSearchHistory(Database db) async {
    await db.delete('search_history');
  }

  /// Подрезает историю поиска до лимита.
  Future<void> trimSearchHistory(Database db, int limit) async {
    final rows = await db.query(
      'search_history',
      columns: ['searched_at_ms'],
      orderBy: 'searched_at_ms DESC',
      limit: limit,
    );
    if (rows.length >= limit) {
      final cutoff = rows.last['searched_at_ms'] as int;
      await db.delete(
        'search_history',
        where: 'searched_at_ms < ?',
        whereArgs: [cutoff],
      );
    }
  }
}