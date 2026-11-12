import 'dart:collection';

/// Standing tier derived from a faction's numeric reputation score.
enum FactionRank {
  hated,
  hostile,
  unfriendly,
  neutral,
  friendly,
  honored,
  exalted,
}

/// Definition of a faction with initial standing, clamp bounds, and diplomatic ties.
final class FactionDef {
  final String id;
  final String displayName;
  final double initialStanding;
  final double minStanding;
  final double maxStanding;

  /// Diplomatic affinity (-1.0 rival .. +1.0 ally) keyed by partner faction id.
  final Map<String, double> relations;

  const FactionDef({
    required this.id,
    required this.displayName,
    this.initialStanding = 0.0,
    this.minStanding = -100.0,
    this.maxStanding = 100.0,
    this.relations = const {},
  });

  static FactionRank rankForStanding(double standing) {
    if (standing <= -60.0) return FactionRank.hated;
    if (standing <= -25.0) return FactionRank.hostile;
    if (standing < 0.0) return FactionRank.unfriendly;
    if (standing < 20.0) return FactionRank.neutral;
    if (standing < 50.0) return FactionRank.friendly;
    if (standing < 80.0) return FactionRank.honored;
    return FactionRank.exalted;
  }
}

/// Audit record describing a single faction standing transition.
final class FactionStandingChange {
  final String factionId;
  final double previous;
  final double current;
  final FactionRank previousRank;
  final FactionRank currentRank;
  final bool isPrimary;

  const FactionStandingChange({
    required this.factionId,
    required this.previous,
    required this.current,
    required this.previousRank,
    required this.currentRank,
    required this.isPrimary,
  });

  bool get rankChanged => previousRank != currentRank;
}

/// Tracks standing per faction and propagates diplomatic ripples across allies/rivals.
final class FactionReputationMatrix {
  final Map<String, FactionDef> _defs = {};
  final Map<String, double> _standings = {};
  final Map<String, Map<String, double>> _pairwiseOverrides = {};

  void registerFaction(FactionDef def) {
    _defs[def.id] = def;
    _standings.putIfAbsent(
      def.id,
      () => def.initialStanding.clamp(def.minStanding, def.maxStanding).toDouble(),
    );
  }

  /// Sets a diplomatic coefficient (-1.0 .. +1.0) between [sourceFactionId] and [targetFactionId].
  void setPairwiseAffinity(
    String sourceFactionId,
    String targetFactionId,
    double coefficient, {
    bool symmetric = true,
  }) {
    if (sourceFactionId == targetFactionId) return;
    final c = coefficient.clamp(-1.0, 1.0).toDouble();
    (_pairwiseOverrides[sourceFactionId] ??= {})[targetFactionId] = c;
    if (symmetric) {
      (_pairwiseOverrides[targetFactionId] ??= {})[sourceFactionId] = c;
    }
  }

  List<String> get factionIds => List.unmodifiable(_defs.keys);

  Map<String, double> get standings => UnmodifiableMapView(_standings);

  double _clampStanding(String factionId, double raw) {
    final def = _defs[factionId];
    if (def == null) return raw.clamp(-100.0, 100.0).toDouble();
    return raw.clamp(def.minStanding, def.maxStanding).toDouble();
  }

  double getStanding(String factionId) {
    if (_standings.containsKey(factionId)) return _standings[factionId]!;
    final def = _defs[factionId];
    if (def != null) return def.initialStanding;
    return 0.0;
  }

  void setStanding(String factionId, double value) {
    _standings[factionId] = _clampStanding(factionId, value);
  }

  FactionRank getRank(String factionId) =>
      FactionDef.rankForStanding(getStanding(factionId));

  bool isHostile(String factionId, {double threshold = -25.0}) =>
      getStanding(factionId) <= threshold;

  bool meetsRequirement(String factionId, double minStanding) =>
      getStanding(factionId) >= minStanding;

  Map<String, double> _relationsOf(String factionId) {
    final merged = <String, double>{};
    final def = _defs[factionId];
    if (def != null) {
      merged.addAll(def.relations);
    }
    final overrides = _pairwiseOverrides[factionId];
    if (overrides != null) {
      merged.addAll(overrides);
    }
    return merged;
  }

  /// Applies [delta] to [factionId] and optionally propagates diplomatic ripples via BFS.
  List<FactionStandingChange> adjustStanding(
    String factionId,
    double delta, {
    bool propagate = true,
    double rippleDamping = 0.5,
  }) {
    final changes = <FactionStandingChange>[];
    if (delta.abs() < 1e-9) return changes;

    void applySingle(String id, double amount, bool primary) {
      final prev = getStanding(id);
      final next = _clampStanding(id, prev + amount);
      _standings[id] = next;
      changes.add(
        FactionStandingChange(
          factionId: id,
          previous: prev,
          current: next,
          previousRank: FactionDef.rankForStanding(prev),
          currentRank: FactionDef.rankForStanding(next),
          isPrimary: primary,
        ),
      );
    }

    applySingle(factionId, delta, true);
    if (!propagate) return changes;

    final visited = <String>{factionId};
    final queue = Queue<({String id, double incomingDelta, int depth})>();
    queue.add((id: factionId, incomingDelta: delta, depth: 0));

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final relations = _relationsOf(current.id);
      for (final entry in relations.entries) {
        final targetId = entry.key;
        if (visited.contains(targetId)) continue;
        final coeff = entry.value.clamp(-1.0, 1.0).toDouble();
        final hopScale = current.depth == 0 ? 1.0 : rippleDamping;
        final propDelta = current.incomingDelta * coeff * hopScale;
        if (propDelta.abs() < 1e-4) continue;
        visited.add(targetId);
        applySingle(targetId, propDelta, false);
        queue.add((id: targetId, incomingDelta: propDelta, depth: current.depth + 1));
      }
    }

    return changes;
  }

  void reset() {
    _standings.clear();
    for (final def in _defs.values) {
      _standings[def.id] =
          def.initialStanding.clamp(def.minStanding, def.maxStanding).toDouble();
    }
  }

  Map<String, Object?> toJson() => {
        'standings': Map<String, double>.from(_standings),
      };

  void loadFromJson(Map<String, Object?> json) {
    reset();
    final raw = json['standings'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final key = entry.key.toString();
        final val = (entry.value as num?)?.toDouble();
        if (val != null) {
          setStanding(key, val);
        }
      }
    }
  }
}
