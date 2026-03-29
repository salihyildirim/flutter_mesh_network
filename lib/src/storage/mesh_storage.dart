import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../logger.dart';
import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';

/// Persistent storage for messages and nodes.
///
/// Uses SQLite via the `sqflite` package.  The database is created
/// lazily on first access and supports concurrent reads.
class MeshStorage {
  MeshStorage(this._config);

  final MeshConfig _config;
  Database? _db;

  Future<Database> get _database async {
    return _db ??= await _open();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _config.databaseName);

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE messages (
            id            TEXT PRIMARY KEY,
            senderId      TEXT NOT NULL,
            senderName    TEXT NOT NULL,
            targetId      TEXT,
            type          INTEGER NOT NULL,
            priority      INTEGER NOT NULL,
            payload       TEXT NOT NULL,
            latitude      REAL,
            longitude     REAL,
            hopCount      INTEGER NOT NULL DEFAULT 0,
            maxHops       INTEGER NOT NULL DEFAULT 10,
            createdAt     TEXT NOT NULL,
            expiresAt     TEXT NOT NULL,
            visitedNodes  TEXT NOT NULL DEFAULT '[]'
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_messages_created ON messages(createdAt)');
        await db.execute(
            'CREATE INDEX idx_messages_type ON messages(type)');

        await db.execute('''
          CREATE TABLE nodes (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            role            INTEGER NOT NULL DEFAULT 0,
            status          INTEGER NOT NULL DEFAULT 0,
            latitude        REAL,
            longitude       REAL,
            batteryLevel    REAL,
            connectionType  INTEGER,
            lastSeen        TEXT NOT NULL,
            signalStrength  INTEGER NOT NULL DEFAULT 0
          )
        ''');

        MeshLogger.storage('Database created');
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<void> insertMessage(MeshMessage message) async {
    final db = await _database;
    await db.insert(
      'messages',
      message.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<bool> messageExists(String id) async {
    final db = await _database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Retrieves persisted messages, optionally filtered by [types].
  ///
  /// When [types] is `null`, returns text and SOS messages by default.
  Future<List<MeshMessage>> getMessages({
    int limit = 100,
    List<MessageType>? types,
  }) async {
    final db = await _database;
    final effectiveTypes = types ?? [MessageType.text, MessageType.sos];
    final placeholders =
        List.filled(effectiveTypes.length, '?').join(', ');
    final typeIndices = effectiveTypes.map((t) => t.index).toList();
    final rows = await db.query(
      'messages',
      where: 'type IN ($placeholders)',
      whereArgs: typeIndices,
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(MeshMessage.fromJson).toList();
  }

  Future<int> deleteExpiredMessages() async {
    final db = await _database;
    final now = DateTime.now().toIso8601String();
    return db.delete('messages', where: 'expiresAt < ?', whereArgs: [now]);
  }

  // ---------------------------------------------------------------------------
  // Nodes
  // ---------------------------------------------------------------------------

  Future<void> upsertNode(MeshNode node) async {
    final db = await _database;
    await db.insert(
      'nodes',
      node.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MeshNode>> getAllNodes() async {
    final db = await _database;
    final rows = await db.query('nodes');
    return rows.map(MeshNode.fromJson).toList();
  }

  Future<int> deleteStaleNodes() async {
    final db = await _database;
    final cutoff = DateTime.now()
        .subtract(_config.staleNodeThreshold)
        .toIso8601String();
    return db.delete('nodes', where: 'lastSeen < ?', whereArgs: [cutoff]);
  }
}
