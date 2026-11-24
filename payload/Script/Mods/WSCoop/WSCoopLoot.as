// WitchspireCoopOverhaul - per-player instanced loot.
//
// Chests (AWorldLootChestActor): each player can loot each chest once. The looter's game plays the usual
// opening and the loot pops out as items only that player can see and pick up; afterwards the chest is
// hidden for them (it stays closed and available for everyone else). The record "who looted what" lives
// in AWSCoopManager (world save), keyed by the chest's stable level name and the player's save identity.
// Chests that were already opened before the mod keep their vanilla state.
//
// Enemy / boss kills (ANPCBase::OnDeath): every player within InstancedLootRange of the kill gets an
// independent roll into their inventory, using their own Luck. If no player is in range, vanilla drops.
//
// What each player's own game shows (hidden nodes / chests, feedback) is handled by UWSCoopLootView.

namespace WSCoopLoot
{
    float GetLuck(const APlayerCharacter Player)
    {
        if (Player == nullptr || Player.AbilityComp == nullptr)
            return 1.0;
        return Player.AbilityComp.GetAttributeCurrentValue(UPlayerModifierAttributeSet::GetLuckAttribute(), 1.0);
    }

    // Rolls LootComponent for Player and puts the result in their inventory (overflow drops at their feet).
    int GiveRollTo(APlayerCharacter Player, ULootComponent LootComponent)
    {
        if (Player == nullptr || LootComponent == nullptr || Player.InventoryComp == nullptr)
            return 0;

        UInventoryComponent Inventory = Player.InventoryComp;
        int Given = 0;
        const TArray<UItemStack> Loot = LootComponent.GenerateLoot(GetLuck(Player));
        for (UItemStack ItemStack : Loot)
        {
            if (ItemStack == nullptr || ItemStack.IsEmpty())
                continue;

            const int CanAdd = Inventory.GetAvailableItemCapacity(ItemStack.ItemDefinition);
            if (CanAdd < ItemStack.StackSize)
            {
                UItemStack LeftOver = ItemStack.Split(ItemStack.StackSize - CanAdd);
                Inventory.DropItemStack(LeftOver);
                Player.OnAttemptedToAddItemToFullInventoryServer(Inventory);
            }
            if (!ItemStack.IsEmpty())
            {
                Given += ItemStack.StackSize;
                Inventory.AddItemStack(ItemStack, EItemEventFlags::IsWorldPickup);
            }
        }
        return Given;
    }

    FString ContainerKey(const AActor Container)
    {
        return Container.GetName().ToString();
    }

    // Returns true when the interaction was handled here (caller must not run vanilla open logic).
    bool HandleChest(AActor Chest, ULootComponent LootComponent, const FInteractionContext& Context)
    {
        if (!System::IsServer())
            return false;

        APlayerCharacter Player = Cast<APlayerCharacter>(Context.Interactor.Owner);
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString PlayerKey = WSCoop::PlayerKey(Player);
        if (Player == nullptr || Manager == nullptr || PlayerKey.IsEmpty())
        {
            WSCoop::Info(f"Chest {ContainerKey(Chest)}: falling back to vanilla (player={Player != nullptr} manager={Manager != nullptr} key='{PlayerKey}')");
            return false;
        }

        const FString Key = ContainerKey(Chest);
        if (Manager.HasLooted(Key, PlayerKey))
        {
            WSCoop::Info(f"Chest {Key}: {WSCoop::PlayerName(Player)} already looted it");
            WSCoop::Notify(Player, "You have already taken your share from this chest.");
            return true;
        }

        Manager.MarkLooted(Key, PlayerKey);
        ViewChestOpened(Player, Cast<AWorldLootChestActor>(Chest));
        // Same timing as the vanilla opening (the loot flies out as the lid opens).
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.QueuePersonalDrop(Chest, Player, 0.35);
        else
            DropPersonalLoot(Chest, Player);
        WSCoop::Info(f"Chest {Key}: {WSCoop::PlayerName(Player)} (key {PlayerKey}) opened it (looter #{Manager.CountLooters(Key)})");
        return true;
    }

    // ------------------------------------------------------------------ personal loot drops
    // Drops Source's loot the vanilla way (scattered pickups, rolled with this player's Luck), but the pickups
    // belong to this player: only their game shows them and only they can pick them up (AItemPickup patch).
    int DropPersonalLoot(AActor Source, APlayerCharacter Player)
    {
        ULootComponent LootComponent = Source != nullptr ? ULootComponent::Get(Source) : nullptr;
        if (LootComponent == nullptr || Player == nullptr)
            return 0;

        TArray<AItemPickup> Before;
        GetAllActorsOfClass(Before);
        LootComponent.DropLoot(GetLuck(Player));
        TArray<AItemPickup> After;
        GetAllActorsOfClass(After);

        AWSCoopManager Manager = WSCoop::GetManager();
        int Dropped = 0;
        for (AItemPickup Pickup : After)
        {
            if (Pickup == nullptr || Before.Contains(Pickup))
                continue;
            if (Manager != nullptr)
                Manager.AddPersonalPickup(Pickup, Player.PlayerState);
            ApplyPersonalPickup(Pickup); // listen-server host: hide someone else's loot on this screen
            Dropped++;
        }
        WSCoop::Info(f"Personal loot from {Source.GetName()}: {Dropped} pickup(s) for {WSCoop::PlayerName(Player)}");
        return Dropped;
    }

    // Personal pickups can only be taken by the player they were dropped for.
    bool CanTakePickup(const FInteractionContext& Context)
    {
        AActor Pickup = Context.Interactable != nullptr ? Context.Interactable.Owner : nullptr;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Pickup == nullptr || Manager == nullptr || !Manager.IsPersonalPickup(Pickup))
            return true;
        const APlayerState Owner = Manager.PersonalOwnerOf(Pickup);
        const APawn Taker = Context.Interactor != nullptr ? Cast<APawn>(Context.Interactor.Owner) : nullptr;
        const bool bOwner = Taker != nullptr && Owner != nullptr && Taker.PlayerState == Owner;
        if (!bOwner)
        {
            const FString OwnerName = Owner != nullptr ? Owner.GetPlayerName() : FString("someone who left");
            const FString TakerName = (Taker != nullptr && Taker.PlayerState != nullptr) ? Taker.PlayerState.GetPlayerName() : FString("?");
            WSCoop::Info(f"Personal pickup {Pickup.GetName()}: belongs to {OwnerName}, not taken by {TakerName}");
        }
        return bOwner;
    }

    // Every game (also the listen-server host): hides personal pickups that belong to someone else.
    void ApplyPersonalPickup(AItemPickup Pickup)
    {
        if (Pickup == nullptr || System::IsDedicatedServer())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || !Manager.IsPersonalPickup(Pickup))
            return;
        APlayerController Local = Gameplay::GetPlayerController(0);
        const APlayerState Owner = Manager.PersonalOwnerOf(Pickup);
        if (Local != nullptr && Owner != nullptr && Local.PlayerState == Owner)
            return;
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.HidePickupHere(Pickup);
    }

    // True when Pickup is someone else's personal loot on this machine (no pickup sound / sparkle here).
    bool IsPickupHiddenHere(const AItemPickup Pickup)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        return View != nullptr && View.IsPickupHiddenHere(Pickup);
    }

    // Test helper (admin "viewtest node|satchel|chest <A> [B]"): moves A (and B) next to the nearest node / chest A
    // has not taken yet, then A takes it through the normal interaction system. "viewtest expire <A> <seconds>"
    // makes A's regrowing harvests come back after that many seconds and resends A's list.
    FString ViewTest(const FString& What, APlayerController PCA, APlayerController PCB, float Seconds)
    {
        APlayerCharacter A = PCA != nullptr ? Cast<APlayerCharacter>(PCA.GetControlledPawn()) : nullptr;
        APlayerCharacter B = PCB != nullptr ? Cast<APlayerCharacter>(PCB.GetControlledPawn()) : nullptr;
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString KeyA = WSCoop::PlayerKey(A);
        if (A == nullptr || Manager == nullptr || KeyA.IsEmpty())
            return "FAIL player A not found / not identified";

        if (What == "expire")
        {
            const int Changed = Manager.SetRegrowTimes(KeyA, NowUnix() + int64(Seconds));
            const bool bSent = ViewSync(A);
            return f"{Changed} harvest(s) of {WSCoop::PlayerName(A)} now regrow in {int(Seconds)} s (resent={bSent})";
        }

        AActor Target = nullptr;
        float Best = MAX_flt;
        if (What == "chest")
        {
            TArray<AWorldLootChestActor> Chests;
            GetAllActorsOfClass(Chests);
            for (AWorldLootChestActor C : Chests)
            {
                if (Manager.HasLooted(ContainerKey(C), KeyA) || UInteractableComponent::Get(C) == nullptr)
                    continue;
                const float D = C.GetActorLocation().Distance(A.GetActorLocation());
                if (D < Best)
                {
                    Best = D;
                    Target = C;
                }
            }
        }
        else
        {
            TArray<AHarvestableActor> Nodes;
            GetAllActorsOfClass(Nodes);
            for (AHarvestableActor H : Nodes)
            {
                if (!H.IsActivated() || !SaveGame::IsLevelPlacedActor(H) || HasHarvested(H, KeyA))
                    continue;
                if (What == "satchel" && !H.Class.GetName().ToString().Contains("Satchel"))
                    continue;
                const float D = H.GetActorLocation().Distance(A.GetActorLocation());
                if (D < Best)
                {
                    Best = D;
                    Target = H;
                }
            }
        }
        if (Target == nullptr)
            return f"FAIL no {What} available for {WSCoop::PlayerName(A)}";

        const FVector Base = Target.GetActorLocation() + FVector(0, 0, 80);
        const FVector PosA = Base + FVector(-180, 0, 0);
        const FVector PosB = Base + FVector(-180, 140, 0);
        A.HercTeleportTo(PosA, FRotator(0, 0, 0), false, true);
        if (B != nullptr)
            B.HercTeleportTo(PosB, FRotator(0, -30, 0), false, true);

        UInteractableComponent Interactable = UInteractableComponent::Get(Target);
        if (Interactable == nullptr)
            return f"FAIL {Target.GetName()} has no interactable";
        const bool bOk = Interactable.Interact(FInteractionContext(A.InteractorComponent, Interactable, EInteractionType::OnActivated));
        return f"{WSCoop::PlayerName(A)} took {What} {Target.GetName()} ({Target.Class.GetName()}) at {Target.GetActorLocation()}: interact={bOk}";
    }

    void ResetContainer(AActor Container)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        const FString Key = ContainerKey(Container);
        if (Manager.CountLooters(Key) == 0)
            return;
        Manager.ResetContainer(Key);
        for (APlayerCharacter Player : WSCoop::GetPlayers())
            ViewUnhide(Player, Key);
    }

    // ------------------------------------------------------------------ what each player's game shows
    // Server side: tells one player's game about their own loot (or applies it here for the listen-server host).

    // Remote player's message channel; nullptr for the local (host) player or when not connected yet.
    UWSIdentityComponent ViewChannel(const APlayerCharacter Player, bool& bLocal)
    {
        bLocal = false;
        APlayerController PC = Player != nullptr ? Cast<APlayerController>(Player.Controller) : nullptr;
        if (PC == nullptr)
            return nullptr;
        if (PC.IsLocalController())
        {
            bLocal = true;
            return nullptr;
        }
        return WSIdentity::GetComponent(PC);
    }

    // Seconds until a harvest regrows (-1 = never).
    float SecondsLeft(int64 Until)
    {
        if (Until == 0)
            return -1.0;
        const int64 Left = Until - NowUnix();
        return Left < 1 ? 1.0 : float(Left);
    }

    void ViewGathered(APlayerCharacter Player, AHarvestableActor Node, int64 Until)
    {
        bool bLocal = false;
        UWSIdentityComponent Channel = ViewChannel(Player, bLocal);
        if (bLocal)
        {
            UWSCoopLootView View = UWSCoopLootView::Get();
            if (View != nullptr)
                View.LocalGathered(Node, ContainerKey(Node), SecondsLeft(Until));
        }
        else if (Channel != nullptr)
            Channel.ClientLootGathered(Node, ContainerKey(Node), SecondsLeft(Until));
    }

    void ViewChestOpened(APlayerCharacter Player, AWorldLootChestActor Chest)
    {
        bool bLocal = false;
        UWSIdentityComponent Channel = ViewChannel(Player, bLocal);
        if (bLocal)
        {
            UWSCoopLootView View = UWSCoopLootView::Get();
            if (View != nullptr)
                View.LocalChestOpened(Chest, ContainerKey(Chest));
        }
        else if (Channel != nullptr)
            Channel.ClientLootChestOpened(Chest, ContainerKey(Chest));
    }

    void ViewUnhide(APlayerCharacter Player, const FString& Key)
    {
        bool bLocal = false;
        UWSIdentityComponent Channel = ViewChannel(Player, bLocal);
        if (bLocal)
        {
            UWSCoopLootView View = UWSCoopLootView::Get();
            if (View != nullptr)
                View.LocalUnhide(Key);
        }
        else if (Channel != nullptr)
            Channel.ClientLootUnhide(Key);
    }

    // Sends a joining player everything they already gathered / looted. Returns false until they can be reached.
    bool ViewSync(APlayerCharacter Player)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString PlayerKey = WSCoop::PlayerKey(Player);
        bool bLocal = false;
        UWSIdentityComponent Channel = ViewChannel(Player, bLocal);
        if (Manager == nullptr || PlayerKey.IsEmpty() || (!bLocal && Channel == nullptr))
            return false;

        TArray<FString> Names;
        TArray<int64> Until;
        Manager.GetTakenBy(PlayerKey, NowUnix(), Names, Until);
        UWSCoopLootView View = UWSCoopLootView::Get();
        const int Batch = 100;
        for (int Start = 0; Start < Names.Num(); Start += Batch)
        {
            TArray<FString> PartNames;
            TArray<float> PartSeconds;
            for (int i = Start; i < Names.Num() && i < Start + Batch; ++i)
            {
                PartNames.Add(Names[i]);
                PartSeconds.Add(SecondsLeft(Until[i]));
            }
            if (bLocal && View != nullptr)
                View.LocalSync(PartNames, PartSeconds);
            else if (Channel != nullptr)
                Channel.ClientLootSync(PartNames, PartSeconds);
        }
        WSCoop::Info(f"Loot view: sent {Names.Num()} gathered node(s) / looted chest(s) to {WSCoop::PlayerName(Player)}");
        return true;
    }

    // Client side (and the listen-server host): a node / chest that just loaded stays hidden when this player
    // already took it.
    void HideIfTakenHere(AActor Actor)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr && View.IsHiddenLocally(Actor))
            View.HideTaken(Actor);
    }

    // ------------------------------------------------------------------ per-player harvesting
    // Level-placed harvestables (satchels, coin piles, branches, rocks, flowers, berry bushes...): every player
    // harvests each node for themselves and it stays up for everyone else. Nodes that normally regrow
    // become available to that player again after the node's usual respawn time. Spawned nodes (spells,
    // seeds) and player-grown plants keep vanilla behaviour.

    int64 NowUnix()
    {
        return FDateTime::UtcNow().ToUnixTimestamp();
    }

    bool IsPerPlayerHarvest(const AHarvestableActor Harvestable)
    {
        return WSCoop::InstancedHarvest() && System::IsServer() && Harvestable != nullptr
            && SaveGame::IsLevelPlacedActor(Harvestable) && WSCoop::GetManager() != nullptr;
    }

    bool HasHarvested(const AHarvestableActor Harvestable, const FString& PlayerKey)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr && Manager.HasHarvested(ContainerKey(Harvestable), PlayerKey, NowUnix());
    }

    // 0 = never regrows for this player.
    int64 RegrowTime(const AHarvestableActor Harvestable)
    {
        if (!Harvestable.bCanRespawn)
            return 0;
        const float Seconds = Math::RandRange(Harvestable.RespawnCooldownRange.LowerBound.Value, Harvestable.RespawnCooldownRange.UpperBound.Value);
        return NowUnix() + int64(Seconds);
    }

    // Records the harvest; returns the unix time it regrows for this player (0 = never), -1 if not recorded.
    int64 MarkHarvested(const AHarvestableActor Harvestable, const FString& PlayerKey, const FString& PlayerName)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || PlayerKey.IsEmpty())
            return -1;
        const int64 Until = RegrowTime(Harvestable);
        Manager.MarkHarvested(ContainerKey(Harvestable), PlayerKey, Until);
        const FString When = Until == 0 ? "never regrows" : f"regrows for them in {int((Until - NowUnix()) / 60.0)} min";
        WSCoop::Info(f"Harvest {ContainerKey(Harvestable)}: {PlayerName} gathered it ({When}); still available to others");
        return Until;
    }

    // A player gathered a node: record it, then their game plays the pickup sound / sparkle and hides it for them.
    void Gathered(AHarvestableActor Harvestable, APlayerCharacter Player)
    {
        const int64 Until = MarkHarvested(Harvestable, WSCoop::PlayerKey(Player), WSCoop::PlayerName(Player));
        if (Until >= 0)
            ViewGathered(Player, Harvestable, Until);
    }

    // Returns true when this player already gathered the node (nothing happens; caller stops).
    bool BlockRepeatHarvest(const AHarvestableActor Harvestable, APlayerCharacter Player)
    {
        if (!HasHarvested(Harvestable, WSCoop::PlayerKey(Player)))
            return false;
        WSCoop::Notify(Player, "You already gathered this.");
        return true;
    }

    // Simulates two players on one level-placed harvestable; leaves no records behind.
    FString SelfTest()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return "FAIL no coop manager";
        TArray<AHarvestableActor> Nodes;
        GetAllActorsOfClass(Nodes);
        AHarvestableActor Node = nullptr;
        AHarvestableActor OneShot = nullptr;
        int Placed = 0;
        for (AHarvestableActor H : Nodes)
        {
            if (!SaveGame::IsLevelPlacedActor(H) || !H.IsActivated())
                continue;
            Placed++;
            if (Node == nullptr && H.bCanRespawn)
                Node = H;
            if (OneShot == nullptr && !H.bCanRespawn)
                OneShot = H;
        }
        if (Node == nullptr)
            return f"FAIL no level-placed harvestable loaded (harvestables={Nodes.Num()})";

        const FString Key = ContainerKey(Node);
        const bool A0 = HasHarvested(Node, "wstestA");
        MarkHarvested(Node, "wstestA", "TestA");
        const bool A1 = HasHarvested(Node, "wstestA");
        const bool B1 = HasHarvested(Node, "wstestB");
        const bool StillUp = Node.IsActivated();
        Manager.MarkHarvested(Key, "wstestA", NowUnix() - 1); // pretend the regrow time has passed
        const bool A2 = HasHarvested(Node, "wstestA");
        bool OneShotOk = true;
        FString OneShotInfo = "no one-time node loaded";
        if (OneShot != nullptr)
        {
            MarkHarvested(OneShot, "wstestA", "TestA");
            OneShotOk = HasHarvested(OneShot, "wstestA") && !HasHarvested(OneShot, "wstestB") && OneShot.IsActivated();
            OneShotInfo = f"one-time node {ContainerKey(OneShot)} ({OneShot.Class.GetName()}): A blocked, B free, still up = {OneShotOk}";
        }
        Manager.ForgetPlayerLoot("wstestA");
        Manager.ForgetPlayerLoot("wstestB");
        const bool bOk = !A0 && A1 && !B1 && StillUp && !A2 && OneShotOk;
        const FString Verdict = bOk ? "PASS" : "FAIL";
        return f"{Verdict} placed={Placed} node {Key} ({Node.Class.GetName()}): A before={A0} A after={A1} B after={B1} still up={StillUp} A after regrow={A2}; {OneShotInfo}";
    }

    // Enemy / boss drops. Returns false (-> vanilla drop) when no player is close enough.
    bool GrantToNearbyPlayers(AActor Source, ULootComponent LootComponent, const FString& Reason)
    {
        TArray<APlayerCharacter> Players;
        ExperienceShare::GetPlayersInRadius(Source.GetActorLocation(), WSCoop::InstancedLootRange(), Players);
        if (Players.Num() == 0)
            return false;

        for (APlayerCharacter Player : Players)
        {
            const int Given = GiveRollTo(Player, LootComponent);
            WSCoop::Info(f"{Reason} {Source.GetName()}: {WSCoop::PlayerName(Player)} received {Given} items");
        }
        return true;
    }
}
