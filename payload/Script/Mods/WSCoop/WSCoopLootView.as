// WitchspireCoopOverhaul - what each player sees of per-player loot.
//
// The server keeps instanced chests and level-placed gathering nodes (satchels, coin piles, branches,
// rocks, flowers...) up for everyone. Each player's own game hides the ones that player already took:
// chests and satchels for good, regrowing nodes until they regrow for that player. Taking one plays the
// usual feedback on their screen: pickup sound and sparkle for nodes; for chests the opening animation,
// then the loot pops out as pickups only that player can see and collect, and the chest fades away.
//
// Client side: fed by UWSIdentityComponent (ClientLoot* messages) or directly on a listen-server host.
// Server side: delayed personal chest drops and the "what you already took" list sent to joining players.

UCLASS()
class UWSCoopLootView : UScriptWorldSubsystem
{
    // ---------------------------------------------------------------- client side
    // Actor name -> local unix time it comes back for this player (0 = never).
    private TMap<FString, int64> HiddenUntil;
    // Loaded actors currently hidden here, for showing them again on regrow / chest reset.
    private TArray<AActor> HiddenActors;
    // Chests this player just opened: hidden once the opening has played.
    private TArray<AWorldLootChestActor> ChestsToHide;
    private TArray<float> ChestHideAt;
    // Someone else's personal loot pickups, hidden on this screen.
    private TArray<AItemPickup> HiddenPickups;

    // ---------------------------------------------------------------- server side
    private TArray<AActor> DropSources;
    private TArray<APlayerCharacter> DropPlayers;
    private TArray<float> DropAt;
    private TArray<APlayerController> Synced;

    private float Clock = 0;
    private float SlowAccumulator = 0;
    private bool bDebug = false;
    private int LastPickupCount = -1;
    private int LastHiddenCount = -1;

    private float ChestHideDelay = 2.5;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        bDebug = System::ParseParam(System::GetCommandLine(), "WSLootDebug");
    }

    // ================================================================ client side

    bool IsHiddenLocally(const AActor Actor) const
    {
        if (Actor == nullptr || HiddenUntil.Num() == 0)
            return false;
        int64 Until = 0;
        if (!HiddenUntil.Find(Actor.GetName().ToString(), Until))
            return false;
        return Until == 0 || WSCoopLoot::NowUnix() < Until;
    }

    private void Remember(const FString& Key, float Seconds)
    {
        if (Key.IsEmpty())
            return;
        const int64 Until = Seconds < 0 ? 0 : WSCoopLoot::NowUnix() + int64(Seconds) + 1;
        HiddenUntil.Add(Key, Until);
    }

    void HideTaken(AActor Actor)
    {
        Apply(Actor, true);
    }

    private void Apply(AActor Actor, bool bHidden)
    {
        AHarvestableActor Node = Cast<AHarvestableActor>(Actor);
        if (Node != nullptr)
        {
            // Never show a node that is gathered for everyone (vanilla / spells): only undo our own hiding.
            if (bHidden || Node.IsActivated())
                Node.WSCoopSetLocallyHidden(bHidden);
        }
        AWorldLootChestActor Chest = Cast<AWorldLootChestActor>(Actor);
        if (Chest != nullptr)
            Chest.WSCoopSetLocallyHidden(bHidden);

        if (bHidden)
            HiddenActors.AddUnique(Actor);
        else
            HiddenActors.Remove(Actor);
        if (bDebug)
            WSCoop::Info(f"Loot view debug: {Actor.GetName()} hidden={bHidden}");
    }

    // This player gathered Node: the usual pickup sound and sparkle, then it is gone for them.
    void LocalGathered(AHarvestableActor Node, const FString& Key, float Seconds)
    {
        Remember(Key, Seconds);
        if (Node != nullptr)
        {
            Node.WSCoopPlayLocalPickup();
            Apply(Node, true);
        }
        const FString For = Seconds < 0 ? "for good" : f"for {int(Seconds / 60)} min";
        WSCoop::Info(f"Loot view: gathered {Key}, hidden here {For} (loaded={Node != nullptr})");
    }

    // This player opened Chest: the usual opening plays, then the chest is gone for them.
    void LocalChestOpened(AWorldLootChestActor Chest, const FString& Key)
    {
        Remember(Key, -1);
        if (Chest != nullptr)
        {
            Chest.WSCoopPlayLocalOpen();
            ChestsToHide.Add(Chest);
            ChestHideAt.Add(Clock + ChestHideDelay);
        }
        WSCoop::Info(f"Loot view: opened chest {Key} (loaded={Chest != nullptr})");
    }

    // Everything this player already took (sent when they join).
    void LocalSync(const TArray<FString>& Names, const TArray<float>& Seconds)
    {
        for (int i = 0; i < Names.Num() && i < Seconds.Num(); ++i)
            Remember(Names[i], Seconds[i]);
        const int Applied = ApplyToLoaded();
        WSCoop::Info(f"Loot view: {Names.Num()} taken node(s) / chest(s) received, {Applied} hidden now");
    }

    // A chest was reset (dungeon reset): it is available to this player again.
    void LocalUnhide(const FString& Key)
    {
        HiddenUntil.Remove(Key);
        for (int i = HiddenActors.Num() - 1; i >= 0; --i)
        {
            AActor Actor = HiddenActors[i];
            if (!IsValid(Actor))
                HiddenActors.RemoveAt(i);
            else if (Actor.GetName().ToString() == Key)
                Apply(Actor, false);
        }
        for (int i = ChestsToHide.Num() - 1; i >= 0; --i)
        {
            if (!IsValid(ChestsToHide[i]) || ChestsToHide[i].GetName().ToString() == Key)
            {
                ChestsToHide.RemoveAt(i);
                ChestHideAt.RemoveAt(i);
            }
        }
    }

    // Hides every loaded node / chest this player already took. Actors that load later hide themselves
    // (AHarvestableActor::OnActivated, AWorldLootChestActor::ActorLoaded).
    private int ApplyToLoaded()
    {
        int Applied = 0;
        TArray<AHarvestableActor> Nodes;
        GetAllActorsOfClass(Nodes);
        for (AHarvestableActor Node : Nodes)
        {
            if (Node.IsActivated() && IsHiddenLocally(Node))
            {
                Apply(Node, true);
                Applied++;
            }
        }
        TArray<AWorldLootChestActor> Chests;
        GetAllActorsOfClass(Chests);
        for (AWorldLootChestActor Chest : Chests)
        {
            if (IsHiddenLocally(Chest))
            {
                Apply(Chest, true);
                Applied++;
            }
        }
        return Applied;
    }

    private void TickClient()
    {
        for (int i = ChestsToHide.Num() - 1; i >= 0; --i)
        {
            if (Clock < ChestHideAt[i])
                continue;
            AWorldLootChestActor Chest = ChestsToHide[i];
            ChestsToHide.RemoveAt(i);
            ChestHideAt.RemoveAt(i);
            if (!IsValid(Chest) || !IsHiddenLocally(Chest))
                continue;
            UNiagaraSystem Poof = UInventorySettings::GetItemPickupEffect();
            if (Poof != nullptr)
                Niagara::SpawnSystemAtLocation(Poof, Chest.GetActorLocation(), Chest.GetActorRotation());
            Apply(Chest, true);
        }
    }

    // Once a second: nodes that regrew for this player come back.
    private void TickClientSlow()
    {
        for (int i = HiddenPickups.Num() - 1; i >= 0; --i)
        {
            if (!IsValid(HiddenPickups[i]))
                HiddenPickups.RemoveAt(i);
        }
        if (HiddenUntil.Num() == 0)
            return;
        const int64 Now = WSCoopLoot::NowUnix();
        TArray<FString> Regrown;
        for (auto Entry : HiddenUntil)
        {
            if (Entry.Value != 0 && Entry.Value <= Now)
                Regrown.Add(Entry.Key);
        }
        for (const FString& Key : Regrown)
        {
            LocalUnhide(Key);
            WSCoop::Info(f"Loot view: {Key} regrew for this player");
        }
    }

    private void DebugPickups()
    {
        TArray<AItemPickup> Pickups;
        GetAllActorsOfClass(Pickups);
        if (Pickups.Num() == LastPickupCount && HiddenActors.Num() == LastHiddenCount)
            return;
        LastPickupCount = Pickups.Num();
        LastHiddenCount = HiddenActors.Num();
        AWSCoopManager Manager = WSCoop::GetManager();
        int Personal = 0;
        int Visible = 0;
        for (AItemPickup Pickup : Pickups)
        {
            if (Manager != nullptr && Manager.IsPersonalPickup(Pickup))
                Personal++;
            if (!HiddenPickups.Contains(Pickup))
                Visible++;
        }
        WSCoop::Info(f"Loot view debug: {Pickups.Num()} item pickup(s) here ({Personal} personal, {Visible} visible), {HiddenActors.Num()} hidden actor(s)");
    }

    void HidePickupHere(AItemPickup Pickup)
    {
        if (Pickup == nullptr || HiddenPickups.Contains(Pickup))
            return;
        HiddenPickups.Add(Pickup);
        if (System::IsServer())
            Pickup.RootComponent.SetVisibility(false, true); // listen-server host: this screen only
        else
            Pickup.SetActorHiddenInGame(true);
    }

    bool IsPickupHiddenHere(const AItemPickup Pickup) const
    {
        return Pickup != nullptr && HiddenPickups.Contains(Pickup);
    }

    // ================================================================ server side

    void QueuePersonalDrop(AActor Source, APlayerCharacter Player, float Delay)
    {
        DropSources.Add(Source);
        DropPlayers.Add(Player);
        DropAt.Add(Clock + Delay);
    }

    int PendingDropsFor(const APlayerCharacter Player) const
    {
        int Count = 0;
        for (const APlayerCharacter P : DropPlayers)
        {
            if (P == Player)
                Count++;
        }
        return Count;
    }

    private void TickServer()
    {
        for (int i = DropAt.Num() - 1; i >= 0; --i)
        {
            if (Clock < DropAt[i])
                continue;
            AActor Source = DropSources[i];
            APlayerCharacter Player = DropPlayers[i];
            DropSources.RemoveAt(i);
            DropPlayers.RemoveAt(i);
            DropAt.RemoveAt(i);
            if (IsValid(Source) && IsValid(Player))
                WSCoopLoot::DropPersonalLoot(Source, Player);
        }
    }

    // Every second: players who just joined get the list of what they already took.
    private void TickServerSlow()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager != nullptr)
            Manager.PrunePersonalPickups();
        for (int i = Synced.Num() - 1; i >= 0; --i)
        {
            if (!IsValid(Synced[i]))
                Synced.RemoveAt(i);
        }
        for (APlayerCharacter Player : WSCoop::GetPlayers())
        {
            APlayerController PC = Cast<APlayerController>(Player.Controller);
            if (PC == nullptr || Synced.Contains(PC))
                continue;
            if (WSCoopLoot::ViewSync(Player))
                Synced.Add(PC);
        }
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        Clock += DeltaTime;
        const bool bServer = System::IsServer();
        if (bServer)
            TickServer();
        TickClient();

        SlowAccumulator += DeltaTime;
        if (SlowAccumulator < 1.0)
            return;
        SlowAccumulator = 0;
        if (bServer)
            TickServerSlow();
        TickClientSlow();
        if (bDebug)
            DebugPickups();
    }
};
