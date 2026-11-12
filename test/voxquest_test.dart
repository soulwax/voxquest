import 'package:test/test.dart';
import 'package:voxquest/voxquest.dart';

void main() {
  test('QuestTracker evaluates compound allOf/anyOf objectives and optional branches', () {
    final tracker = QuestTracker();
    tracker.registerQuest(
      const QuestDef(
        id: 'q_watchtower',
        title: 'Reclaim the Watchtower',
        entryStageId: 's_infiltrate',
        stages: [
          QuestStageDef(
            id: 's_infiltrate',
            title: 'Breach Outer Gate',
            objectives: [
              QuestObjectiveDef.allOf(
                id: 'obj_prep',
                description: 'Scout gate & defeat sentries',
                children: [
                  QuestObjectiveDef.location(
                    id: 'c_gate',
                    description: 'Reach East Gate',
                    targetTag: 'east_gate',
                  ),
                  QuestObjectiveDef.anyOf(
                    id: 'c_entry',
                    description: 'Eliminate guards or pick lock',
                    children: [
                      QuestObjectiveDef.counter(
                        id: 'c_guards',
                        description: 'Defeat 2 sentries',
                        targetTag: 'sentry',
                        requiredCount: 2,
                      ),
                      QuestObjectiveDef.deliver(
                        id: 'c_key',
                        description: 'Use rusty key',
                        targetTag: 'rusty_key',
                      ),
                    ],
                  ),
                ],
              ),
              QuestObjectiveDef.counter(
                id: 'opt_banner',
                description: 'Optional: recover fallen banners',
                targetTag: 'banner',
                requiredCount: 3,
                optional: true,
              ),
            ],
            nextStageId: 's_beacon',
          ),
          QuestStageDef(
            id: 's_beacon',
            title: 'Light the Signal Fire',
            objectives: [
              QuestObjectiveDef.location(
                id: 'obj_brazier',
                description: 'Reach rooftop brazier',
                targetTag: 'brazier',
              ),
            ],
          ),
        ],
      ),
    );

    expect(tracker.acceptQuest('q_watchtower'), isTrue);
    tracker.recordProgress(targetTag: 'east_gate', kind: QuestObjectiveKind.location);
    expect(tracker.getQuest('q_watchtower')!.currentStageId, 's_infiltrate');

    // Fulfill the anyOf branch via 1 rusty_key without touching optional banners
    tracker.recordProgress(targetTag: 'rusty_key', kind: QuestObjectiveKind.deliver);
    expect(tracker.getQuest('q_watchtower')!.currentStageId, 's_beacon');

    tracker.recordProgress(targetTag: 'brazier', kind: QuestObjectiveKind.location);
    expect(tracker.getQuest('q_watchtower')!.isCompleted, isTrue);
  });

  test('FactionReputationMatrix propagates ripples across allies and rivals accurately', () {
    final matrix = FactionReputationMatrix()
      ..registerFaction(
        const FactionDef(
          id: 'guild',
          displayName: 'Artisan Guild',
          initialStanding: 10.0,
          relations: {'wardens': 0.5, 'raiders': -0.8},
        ),
      )
      ..registerFaction(
        const FactionDef(
          id: 'wardens',
          displayName: 'Valley Wardens',
          initialStanding: 5.0,
        ),
      )
      ..registerFaction(
        const FactionDef(
          id: 'raiders',
          displayName: 'Ash Raiders',
          initialStanding: -5.0,
        ),
      );

    matrix.adjustStanding('guild', 30.0);
    expect(matrix.getStanding('guild'), closeTo(40.0, 1e-6));
    expect(matrix.getRank('guild'), FactionRank.friendly);
    expect(matrix.getStanding('wardens'), closeTo(20.0, 1e-6));
    expect(matrix.getStanding('raiders'), closeTo(-29.0, 1e-6));
    expect(matrix.isHostile('raiders'), isTrue);
  });

  test('Quest DAG unlocks follow-ups, enforces mutual branch locks, and round-trips JSON', () {
    final tracker = QuestTracker();
    tracker.factions.registerFaction(
      const FactionDef(id: 'wardens', displayName: 'Valley Wardens'),
    );

    tracker.registerQuest(
      const QuestDef(
        id: 'q_forge_pact',
        title: 'Forge Pact',
        entryStageId: 's_choice',
        stages: [
          QuestStageDef(
            id: 's_choice',
            title: 'Choose Patron',
            branchChoices: {
              'pick_warden': 's_warden_route',
              'pick_outlaw': 's_outlaw_route',
            },
          ),
          QuestStageDef(
            id: 's_warden_route',
            title: 'Deliver Iron to Wardens',
            mutuallyExclusiveWithStages: ['s_outlaw_route'],
            objectives: [
              QuestObjectiveDef.deliver(
                id: 'obj_iron',
                description: 'Deliver 4 iron ingots',
                targetTag: 'iron_ingot',
                requiredCount: 4,
              ),
            ],
            factionRewards: {'wardens': 30.0},
          ),
          QuestStageDef(
            id: 's_outlaw_route',
            title: 'Smuggle Outlaw Steel',
            mutuallyExclusiveWithStages: ['s_warden_route'],
            objectives: [
              QuestObjectiveDef.deliver(
                id: 'obj_steel',
                description: 'Deliver steel',
                targetTag: 'steel',
              ),
            ],
          ),
        ],
      ),
    );

    tracker.registerQuest(
      const QuestDef(
        id: 'q_citadel_summit',
        title: 'Citadel Summit',
        prerequisiteQuestIds: ['q_forge_pact'],
        minFactionStandings: {'wardens': 25.0},
        entryStageId: 's_meet',
        stages: [
          QuestStageDef(
            id: 's_meet',
            title: 'Attend Summit',
            objectives: [
              QuestObjectiveDef.location(
                id: 'obj_hall',
                description: 'Enter Council Hall',
                targetTag: 'council_hall',
              ),
            ],
          ),
        ],
      ),
    );

    expect(tracker.getQuest('q_citadel_summit')!.isLocked, isTrue);
    expect(tracker.acceptQuest('q_forge_pact'), isTrue);
    expect(tracker.chooseBranch('q_forge_pact', 'pick_warden'), isTrue);

    final pact = tracker.getQuest('q_forge_pact')!;
    expect(pact.isBranchLocked('s_outlaw_route'), isTrue);
    expect(pact.isBranchLocked('pick_outlaw'), isTrue);

    tracker.recordProgress(targetTag: 'iron_ingot', amount: 2);
    final saved = tracker.toJson();

    final restored = QuestTracker();
    restored.factions.registerFaction(
      const FactionDef(id: 'wardens', displayName: 'Valley Wardens'),
    );
    for (final q in tracker.allQuests) {
      restored.registerQuest(q.def);
    }
    restored.loadFromJson(saved);

    expect(restored.getQuest('q_forge_pact')!.activeObjectives['obj_iron']!.count, 2);
    expect(restored.getQuest('q_forge_pact')!.isBranchLocked('s_outlaw_route'), isTrue);

    restored.recordProgress(targetTag: 'iron_ingot', amount: 2);
    expect(restored.getQuest('q_forge_pact')!.isCompleted, isTrue);
    expect(restored.getQuest('q_citadel_summit')!.isAvailable, isTrue);
    expect(restored.acceptQuest('q_citadel_summit'), isTrue);
  });
}
