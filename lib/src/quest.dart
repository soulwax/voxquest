import 'dart:collection';
import 'dart:math' as math;

import 'faction.dart';

/// Lifecycle status of a quest inside a [QuestTracker].
enum QuestStatus {
  locked,
  available,
  active,
  completed,
  failed,
}

/// Evaluation semantics for a leaf or compound quest objective.
enum QuestObjectiveKind {
  counter,
  location,
  deliver,
  allOf,
  anyOf,
}

/// Declarative definition of a single leaf or compound quest objective.
final class QuestObjectiveDef {
  final String id;
  final String description;
  final QuestObjectiveKind kind;
  final String targetTag;
  final int requiredCount;
  final bool optional;
  final List<QuestObjectiveDef> children;

  const QuestObjectiveDef({
    required this.id,
    required this.description,
    required this.kind,
    this.targetTag = '',
    this.requiredCount = 1,
    this.optional = false,
    this.children = const [],
  });

  const QuestObjectiveDef.counter({
    required this.id,
    required this.description,
    required this.targetTag,
    this.requiredCount = 1,
    this.optional = false,
  })  : kind = QuestObjectiveKind.counter,
        children = const [];

  const QuestObjectiveDef.location({
    required this.id,
    required this.description,
    required this.targetTag,
    this.optional = false,
  })  : kind = QuestObjectiveKind.location,
        requiredCount = 1,
        children = const [];

  const QuestObjectiveDef.deliver({
    required this.id,
    required this.description,
    required this.targetTag,
    this.requiredCount = 1,
    this.optional = false,
  })  : kind = QuestObjectiveKind.deliver,
        children = const [];

  const QuestObjectiveDef.allOf({
    required this.id,
    required this.description,
    required this.children,
    this.optional = false,
  })  : kind = QuestObjectiveKind.allOf,
        targetTag = '',
        requiredCount = 1;

  const QuestObjectiveDef.anyOf({
    required this.id,
    required this.description,
    required this.children,
    this.optional = false,
  })  : kind = QuestObjectiveKind.anyOf,
        targetTag = '',
        requiredCount = 1;
}

/// Runtime progress state for an instantiated [QuestObjectiveDef].
final class QuestObjectiveState {
  final QuestObjectiveDef def;
  int count;
  bool completed;
  final List<QuestObjectiveState> children;

  QuestObjectiveState._(
    this.def, {
    required this.count,
    required this.completed,
    required this.children,
  });

  factory QuestObjectiveState.fromDef(QuestObjectiveDef def) {
    return QuestObjectiveState._(
      def,
      count: 0,
      completed: false,
      children: [for (final c in def.children) QuestObjectiveState.fromDef(c)],
    );
  }

  /// Applies an incremental gameplay event and returns true if state changed.
  bool applyEvent({
    required String targetTag,
    QuestObjectiveKind? kind,
    int amount = 1,
  }) {
    if (completed || amount <= 0) return false;

    if (def.kind == QuestObjectiveKind.allOf ||
        def.kind == QuestObjectiveKind.anyOf) {
      var anyChanged = false;
      for (final child in children) {
        if (child.applyEvent(targetTag: targetTag, kind: kind, amount: amount)) {
          anyChanged = true;
        }
      }
      if (!anyChanged) return false;
      final prevDone = completed;
      if (def.kind == QuestObjectiveKind.allOf) {
        final requiredChildren =
            children.where((c) => !c.def.optional).toList(growable: false);
        completed = requiredChildren.isNotEmpty
            ? requiredChildren.every((c) => c.completed)
            : (children.isNotEmpty && children.every((c) => c.completed));
      } else {
        completed = children.any((c) => c.completed);
      }
      count = completed ? 1 : 0;
      return anyChanged || completed != prevDone;
    }

    if (def.targetTag != targetTag) return false;
    if (kind != null && kind != def.kind) return false;

    final nextCount = math.min(def.requiredCount, count + amount);
    final nextDone = nextCount >= def.requiredCount;
    if (nextCount == count && nextDone == completed) return false;
    count = nextCount;
    completed = nextDone;
    return true;
  }

  double get progressFraction {
    if (completed) return 1.0;
    if (def.kind == QuestObjectiveKind.allOf) {
      final req = children.where((c) => !c.def.optional).toList(growable: false);
      if (req.isEmpty) return 0.0;
      final total = req.fold<double>(0.0, (sum, c) => sum + c.progressFraction);
      return (total / req.length).clamp(0.0, 1.0).toDouble();
    }
    if (def.kind == QuestObjectiveKind.anyOf) {
      if (children.isEmpty) return 0.0;
      var best = 0.0;
      for (final c in children) {
        if (c.progressFraction > best) best = c.progressFraction;
      }
      return best.clamp(0.0, 1.0).toDouble();
    }
    if (def.requiredCount <= 0) return 1.0;
    return (count / def.requiredCount).clamp(0.0, 1.0).toDouble();
  }

  Map<String, Object?> toJson() => {
        'id': def.id,
        'count': count,
        'completed': completed,
        'children': [for (final c in children) c.toJson()],
      };

  void loadFromJson(Map<String, Object?> json) {
    count = (json['count'] as num?)?.toInt() ?? 0;
    completed = (json['completed'] as bool?) ?? false;
    final rawChildren = json['children'];
    if (rawChildren is List) {
      for (var i = 0; i < children.length && i < rawChildren.length; i++) {
        final item = rawChildren[i];
        if (item is Map) {
          children[i].loadFromJson(Map<String, Object?>.from(item));
        }
      }
    }
  }
}

/// A single stage inside a [QuestDef], supporting linear transitions or narrative forks.
final class QuestStageDef {
  final String id;
  final String title;
  final String description;
  final List<QuestObjectiveDef> objectives;

  /// Automatic next stage when mandatory objectives finish (ignored while waiting on [branchChoices]).
  final String? nextStageId;

  /// Player-selectable branch forks keyed by choice id -> target stage id.
  final Map<String, String> branchChoices;

  /// Stages or choices permanently locked out once this stage is entered.
  final List<String> mutuallyExclusiveWithStages;

  /// When true, picking one entry from [branchChoices] locks sibling fork targets/choices.
  final bool lockUnchosenBranches;

  /// Faction standing rewards granted when this stage finishes.
  final Map<String, double> factionRewards;

  /// When true, completing/entering this terminal stage fails the quest instead of completing it.
  final bool isTerminalFailure;

  const QuestStageDef({
    required this.id,
    required this.title,
    this.description = '',
    this.objectives = const [],
    this.nextStageId,
    this.branchChoices = const {},
    this.mutuallyExclusiveWithStages = const [],
    this.lockUnchosenBranches = true,
    this.factionRewards = const {},
    this.isTerminalFailure = false,
  });
}

/// Immutable DAG definition of a quest with prerequisite quests, faction gates, and stages.
final class QuestDef {
  final String id;
  final String title;
  final String summary;
  final String entryStageId;
  final List<String> prerequisiteQuestIds;
  final Map<String, double> minFactionStandings;
  final Map<String, double> completionFactionRewards;
  final List<QuestStageDef> stages;

  const QuestDef({
    required this.id,
    required this.title,
    this.summary = '',
    required this.entryStageId,
    this.prerequisiteQuestIds = const [],
    this.minFactionStandings = const {},
    this.completionFactionRewards = const {},
    required this.stages,
  });

  QuestStageDef? stageById(String stageId) {
    for (final s in stages) {
      if (s.id == stageId) return s;
    }
    return null;
  }
}

/// Mutable runtime instance of a registered [QuestDef].
final class QuestInstance {
  final QuestDef def;
  QuestStatus status;
  String? currentStageId;
  final List<String> visitedStageIds = [];
  final Set<String> lockedBranchIds = {};
  final Map<String, QuestObjectiveState> activeObjectives = {};
  String? chosenBranchId;

  QuestInstance(this.def, {this.status = QuestStatus.locked});

  bool get isLocked => status == QuestStatus.locked;
  bool get isAvailable => status == QuestStatus.available;
  bool get isActive => status == QuestStatus.active;
  bool get isCompleted => status == QuestStatus.completed;
  bool get isFailed => status == QuestStatus.failed;

  QuestStageDef? get currentStage =>
      currentStageId == null ? null : def.stageById(currentStageId!);

  bool get allMandatoryObjectivesComplete {
    for (final state in activeObjectives.values) {
      if (!state.def.optional && !state.completed) return false;
    }
    return true;
  }

  bool isBranchLocked(String branchOrStageId) =>
      lockedBranchIds.contains(branchOrStageId);
}

/// Directed quest DAG scheduler synchronized with [FactionReputationMatrix].
final class QuestTracker {
  final FactionReputationMatrix factions;
  final Map<String, QuestInstance> _quests = {};

  QuestTracker({FactionReputationMatrix? factions})
      : factions = factions ?? FactionReputationMatrix();

  void registerQuest(QuestDef def) {
    final instance = QuestInstance(def);
    _quests[def.id] = instance;
    refreshAvailability();
  }

  QuestInstance? getQuest(String questId) => _quests[questId];

  List<QuestInstance> get allQuests => UnmodifiableListView(_quests.values);

  List<QuestInstance> get availableQuests => _quests.values
      .where((q) => q.status == QuestStatus.available)
      .toList(growable: false);

  List<QuestInstance> get activeQuests => _quests.values
      .where((q) => q.status == QuestStatus.active)
      .toList(growable: false);

  List<QuestInstance> get completedQuests => _quests.values
      .where((q) => q.status == QuestStatus.completed)
      .toList(growable: false);

  List<QuestInstance> get failedQuests => _quests.values
      .where((q) => q.status == QuestStatus.failed)
      .toList(growable: false);

  bool _meetsPrerequisites(QuestDef def) {
    for (final preId in def.prerequisiteQuestIds) {
      final pre = _quests[preId];
      if (pre == null || pre.status != QuestStatus.completed) return false;
    }
    for (final entry in def.minFactionStandings.entries) {
      if (!factions.meetsRequirement(entry.key, entry.value)) return false;
    }
    return true;
  }

  /// Re-evaluates quest unlock gates and returns newly unlocked quest IDs.
  List<String> refreshAvailability() {
    final newlyUnlocked = <String>[];
    for (final q in _quests.values) {
      if (q.status != QuestStatus.locked && q.status != QuestStatus.available) {
        continue;
      }
      final eligible = _meetsPrerequisites(q.def);
      if (q.status == QuestStatus.locked && eligible) {
        q.status = QuestStatus.available;
        newlyUnlocked.add(q.def.id);
      } else if (q.status == QuestStatus.available && !eligible) {
        q.status = QuestStatus.locked;
      }
    }
    return newlyUnlocked;
  }

  bool _enterStage(QuestInstance q, String stageId) {
    if (q.lockedBranchIds.contains(stageId)) return false;
    final stage = q.def.stageById(stageId);
    if (stage == null) return false;

    q.currentStageId = stage.id;
    q.visitedStageIds.add(stage.id);
    q.lockedBranchIds.addAll(stage.mutuallyExclusiveWithStages);
    q.activeObjectives.clear();
    for (final obj in stage.objectives) {
      q.activeObjectives[obj.id] = QuestObjectiveState.fromDef(obj);
    }

    if (stage.isTerminalFailure) {
      q.status = QuestStatus.failed;
      refreshAvailability();
      return true;
    }

    // Immediate zero-objective linear pass-through completion if no branches await input
    if (stage.objectives.isEmpty &&
        stage.branchChoices.isEmpty &&
        stage.nextStageId == null) {
      _applyRewards(stage.factionRewards);
      _completeQuest(q);
    }
    return true;
  }

  void _applyRewards(Map<String, double> rewards) {
    for (final entry in rewards.entries) {
      factions.adjustStanding(entry.key, entry.value);
    }
  }

  void _completeQuest(QuestInstance q) {
    q.status = QuestStatus.completed;
    _applyRewards(q.def.completionFactionRewards);
    refreshAvailability();
  }

  /// Accepts an available quest and activates its entry stage.
  bool acceptQuest(String questId) {
    refreshAvailability();
    final q = _quests[questId];
    if (q == null || q.status != QuestStatus.available) return false;
    q.status = QuestStatus.active;
    return _enterStage(q, q.def.entryStageId);
  }

  /// Dispatches a progress event to active quests and advances completed stages.
  /// Returns IDs of quests whose state changed.
  List<String> recordProgress({
    required String targetTag,
    QuestObjectiveKind? kind,
    int amount = 1,
    String? questId,
  }) {
    final progressed = <String>[];
    final targets = questId != null
        ? [if (_quests[questId] != null) _quests[questId]!]
        : _quests.values.toList(growable: false);

    for (final q in targets) {
      if (q.status != QuestStatus.active) continue;
      final stage = q.currentStage;
      if (stage == null) continue;

      var changed = false;
      for (final obj in q.activeObjectives.values) {
        if (obj.applyEvent(targetTag: targetTag, kind: kind, amount: amount)) {
          changed = true;
        }
      }
      if (!changed) continue;
      progressed.add(q.def.id);

      if (q.allMandatoryObjectivesComplete && stage.branchChoices.isEmpty) {
        _applyRewards(stage.factionRewards);
        final nextId = stage.nextStageId;
        if (nextId != null && !q.lockedBranchIds.contains(nextId)) {
          _enterStage(q, nextId);
        } else {
          _completeQuest(q);
        }
      }
    }
    return progressed;
  }

  /// Commits a branch selection on an active fork stage and permanently locks mutually exclusive paths.
  bool chooseBranch(String questId, String choiceId) {
    final q = _quests[questId];
    if (q == null || q.status != QuestStatus.active) return false;
    final stage = q.currentStage;
    if (stage == null) return false;
    if (!q.allMandatoryObjectivesComplete) return false;

    final targetStageId = stage.branchChoices[choiceId];
    if (targetStageId == null) return false;
    if (q.lockedBranchIds.contains(choiceId) ||
        q.lockedBranchIds.contains(targetStageId)) {
      return false;
    }

    q.chosenBranchId = choiceId;
    if (stage.lockUnchosenBranches) {
      for (final entry in stage.branchChoices.entries) {
        if (entry.key != choiceId) {
          q.lockedBranchIds.add(entry.key);
          if (entry.value != targetStageId) {
            q.lockedBranchIds.add(entry.value);
          }
        }
      }
    }
    _applyRewards(stage.factionRewards);
    return _enterStage(q, targetStageId);
  }

  bool failQuest(String questId) {
    final q = _quests[questId];
    if (q == null ||
        q.status == QuestStatus.completed ||
        q.status == QuestStatus.failed) {
      return false;
    }
    q.status = QuestStatus.failed;
    refreshAvailability();
    return true;
  }

  Map<String, Object?> toJson() => {
        'factions': factions.toJson(),
        'quests': {
          for (final entry in _quests.entries)
            entry.key: {
              'status': entry.value.status.name,
              'currentStageId': entry.value.currentStageId,
              'visitedStageIds': entry.value.visitedStageIds,
              'lockedBranchIds': entry.value.lockedBranchIds.toList(),
              'chosenBranchId': entry.value.chosenBranchId,
              'objectives': {
                for (final obj in entry.value.activeObjectives.entries)
                  obj.key: obj.value.toJson(),
              },
            },
        },
      };

  void loadFromJson(Map<String, Object?> json) {
    final rawFactions = json['factions'];
    if (rawFactions is Map) {
      factions.loadFromJson(Map<String, Object?>.from(rawFactions));
    }

    final rawQuests = json['quests'];
    if (rawQuests is Map) {
      for (final entry in rawQuests.entries) {
        final q = _quests[entry.key.toString()];
        if (q == null || entry.value is! Map) continue;
        final data = Map<String, Object?>.from(entry.value as Map);
        final statusName = data['status'] as String? ?? 'locked';
        q.status = QuestStatus.values.firstWhere(
          (s) => s.name == statusName,
          orElse: () => QuestStatus.locked,
        );
        q.currentStageId = data['currentStageId'] as String?;
        q.chosenBranchId = data['chosenBranchId'] as String?;

        q.visitedStageIds
          ..clear()
          ..addAll(((data['visitedStageIds'] as List?) ?? const [])
              .map((e) => e.toString()));
        q.lockedBranchIds
          ..clear()
          ..addAll(((data['lockedBranchIds'] as List?) ?? const [])
              .map((e) => e.toString()));

        q.activeObjectives.clear();
        final stage = q.currentStage;
        if (stage != null) {
          for (final objDef in stage.objectives) {
            q.activeObjectives[objDef.id] = QuestObjectiveState.fromDef(objDef);
          }
          final rawObjs = data['objectives'];
          if (rawObjs is Map) {
            for (final oe in rawObjs.entries) {
              final state = q.activeObjectives[oe.key.toString()];
              if (state != null && oe.value is Map) {
                state.loadFromJson(Map<String, Object?>.from(oe.value as Map));
              }
            }
          }
        }
      }
    }
    refreshAvailability();
  }
}
