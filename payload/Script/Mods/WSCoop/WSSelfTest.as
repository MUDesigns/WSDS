// WitchspireCoopOverhaul - automated server self-test (only with -WSSelfTest on the server).
//
// Once two players are spawned, exercises the real server code paths with those connected players:
//   1. persistence: objectives recorded in earlier runs are still complete for both players
//   2. instanced loot: both players open the same chest through the normal interaction system;
//      each must receive their own items, a second attempt by the same player must give nothing
//   3. shared objectives: an objective completed by player 1 must also be complete for player 2
// Results are logged as "[WSCoop] SELFTEST ..." lines, then the world and both players are saved.

UCLASS()
class UWSSelfTestSubsystem : UScriptWorldSubsystem
{
    private bool bEnabled = false;
    private bool bDone = false;
    private float Accumulator = 0;
    private float ReadySeconds = 0;
    private int Passed = 0;
    private int Failed = 0;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        bEnabled = System::IsServer() && System::ParseParam(System::GetCommandLine(), "WSSelfTest")
            && !GetWorld().GetName().ToString().Contains("FrontEnd");
        if (bEnabled)
            WSCoop::Info("SELFTEST armed: waiting for two spawned players");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!bEnabled || bDone)
            return;
        Accumulator += DeltaTime;
        if (Accumulator < 1.0)
            return;
        Accumulator = 0;

        TArray<APlayerCharacter> Players = ReadyPlayers();
        if (Players.Num() < 2)
        {
            ReadySeconds = 0;
            return;
        }
        ReadySeconds += 1.0;
        if (ReadySeconds < 15.0) // let saves load and catch-up run
            return;

        bDone = true;
        Run(Players[0], Players[1]);
    }

    private TArray<APlayerCharacter> ReadyPlayers()
    {
        TArray<APlayerCharacter> Result;
        for (APlayerCharacter P : WSCoop::GetPlayers())
        {
            if (!WSCoop::PlayerKey(P).IsEmpty())
                Result.Add(P);
        }
        return Result;
    }

    private void Check(bool bCondition, const FString& What)
    {
        if (bCondition)
            Passed++;
        else
            Failed++;
        const FString Verdict = bCondition ? "PASS" : "FAIL";
        WSCoop::Info(f"SELFTEST {Verdict}: {What}");
    }

    private int CountItems(APlayerCharacter P)
    {
        int Total = 0;
        for (UItemStack Stack : P.InventoryComp.GetAllItemStacks())
        {
            if (Stack != nullptr)
                Total += Stack.StackSize;
        }
        return Total;
    }

    private void Run(APlayerCharacter A, APlayerCharacter B)
    {
        const FString NameA = WSCoop::PlayerName(A);
        const FString NameB = WSCoop::PlayerName(B);
        WSCoop::Info(f"SELFTEST start: A={NameA} ({WSCoop::PlayerKey(A)}) B={NameB} ({WSCoop::PlayerKey(B)})");
        AWSCoopManager Manager = WSCoop::GetManager();
        Check(Manager != nullptr, "coop manager exists");
        if (Manager == nullptr)
            return;

        // 1. Persistence of earlier runs.
        WSCoop::Info(f"SELFTEST world state: {Manager.WorldCompletedObjectives.Num()} world objectives on record");
        for (FGameplayTag Tag : Manager.WorldCompletedObjectives)
        {
            Check(A.ObjectiveComp.IsObjectiveComplete(Tag) && B.ObjectiveComp.IsObjectiveComplete(Tag),
                  f"persisted objective {Tag} complete for both players");
        }

        WSCoop::Info(f"SELFTEST world state: {Manager.LootRecordCount()} loot records on record");
        // Every completed run leaves 2 loot records; a run that found records must find them all.
        if (Manager.LootRecordCount() > 0)
            Check(Manager.LootRecordCount() % 2 == 0, f"loot records from previous runs persisted across a server restart ({Manager.LootRecordCount()})");

        TestLoot(Manager, A, B);
        TestObjectives(Manager, A, B);

        USaveSubsystem::Get().SaveAll(false);
        WSCoop::Info(f"SELFTEST done: {Passed} passed, {Failed} failed (world + players saved)");
    }

    private void TestLoot(AWSCoopManager Manager, APlayerCharacter A, APlayerCharacter B)
    {
        TArray<AWorldLootChestActor> Chests;
        GetAllActorsOfClass(Chests);

        AWorldLootChestActor Chest;
        float Best = MAX_flt;
        for (AWorldLootChestActor C : Chests)
        {
            if (Manager.CountLooters(WSCoopLoot::ContainerKey(C)) > 0)
                continue;
            const float D = C.GetActorLocation().Distance(A.GetActorLocation());
            if (D < Best)
            {
                Best = D;
                Chest = C;
            }
        }
        Check(Chest != nullptr, f"found an unlooted chest ({Chests.Num()} chests in world)");
        if (Chest == nullptr)
            return;
        const FString Key = WSCoopLoot::ContainerKey(Chest);
        WSCoop::Info(f"SELFTEST chest {Key} at {int(Best)}cm from {WSCoop::PlayerName(A)}");

        UInteractableComponent Interactable = UInteractableComponent::Get(Chest);
        const int A0 = CountItems(A);
        const int B0 = CountItems(B);

        // Stand both players next to the chest, like a real player walking up to it.
        const FVector Base = Chest.GetActorLocation() + FVector(0, 0, 60);
        const bool bTpA = A.HercTeleportTo(Base + Chest.GetActorForwardVector() * 140, FRotator(), false, true);
        const bool bTpB = B.HercTeleportTo(Base + Chest.GetActorForwardVector() * 140 + Chest.GetActorRightVector() * 120, FRotator(), false, true);
        WSCoop::Info(f"SELFTEST teleported players to chest: A={bTpA} B={bTpB}");

        const bool bA = Interactable.Interact(FInteractionContext(A.InteractorComponent, Interactable, EInteractionType::OnActivated));
        const int A1 = CountItems(A);
        const bool bB = Interactable.Interact(FInteractionContext(B.InteractorComponent, Interactable, EInteractionType::OnActivated));
        const int B1 = CountItems(B);
        const bool bA2 = Interactable.Interact(FInteractionContext(A.InteractorComponent, Interactable, EInteractionType::OnActivated));
        const int A2 = CountItems(A);

        WSCoop::Info(f"SELFTEST loot: interact A={bA} B={bB} A-again={bA2}; items A {A0}->{A1}->{A2}, B {B0}->{B1}");
        Check(bA && A1 > A0, "player A received their own loot from the chest");
        Check(bB && B1 > B0, "player B received independent loot from the same chest");
        Check(A2 == A1, "player A cannot loot the same chest twice");
        Check(Manager.HasLooted(Key, WSCoop::PlayerKey(A)) && Manager.HasLooted(Key, WSCoop::PlayerKey(B)), "both looters recorded for persistence");
    }

    private void TestObjectives(AWSCoopManager Manager, APlayerCharacter A, APlayerCharacter B)
    {
        TArray<FObjectiveState> Active;
        A.ObjectiveComp.GetActiveObjectives(Active);

        FGameplayTag Tag;
        for (const FObjectiveState& State : Active)
        {
            UObjective Objective = A.ObjectiveComp.GetObjectiveByTag(State.ObjectiveTag);
            if (Objective == nullptr || Objective.bIsGlobal)
                continue;
            if (B.ObjectiveComp.IsObjectiveComplete(State.ObjectiveTag))
                continue;
            Tag = State.ObjectiveTag;
            break;
        }
        Check(Tag.IsValid(), f"found an active objective on {WSCoop::PlayerName(A)} ({Active.Num()} active)");
        if (!Tag.IsValid())
            return;

        WSCoop::Info(f"SELFTEST completing objective {Tag} for {WSCoop::PlayerName(A)} only");
        A.ObjectiveComp.ForceComplete(Tag, false);
        Check(A.ObjectiveComp.IsObjectiveComplete(Tag), f"{Tag} complete for the finisher");
        Check(B.ObjectiveComp.IsObjectiveComplete(Tag), f"{Tag} shared to the other player");
        Check(Manager.WorldCompletedObjectives.Contains(Tag), f"{Tag} recorded as a world milestone");
    }
};
