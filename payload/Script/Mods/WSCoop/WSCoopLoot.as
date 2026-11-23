// WitchspireCoopOverhaul - per-player instanced loot.
//
// Chests (AWorldLootChestActor): each player can loot each chest once; every looter gets an independent
// roll delivered straight into their own inventory, so nobody can take someone else's loot. The record
// "who looted what" lives in AWSCoopManager (world save), keyed by the chest's stable level name and the
// player's save identity. Chests that were already opened before the mod keep their vanilla state.
//
// Enemy / boss kills (ANPCBase::OnDeath): every player within InstancedLootRange of the kill gets an
// independent roll into their inventory, using their own Luck. If no player is in range, vanilla drops.

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
        const int Given = GiveRollTo(Player, LootComponent);
        const int Looters = Manager.CountLooters(Key);
        WSCoop::Info(f"Chest {Key}: {WSCoop::PlayerName(Player)} (key {PlayerKey}) received {Given} items (looter #{Looters})");
        WSCoop::Notify(Player, f"Your share of the chest: {Given} item(s).");
        return true;
    }

    void ResetContainer(AActor Container)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager != nullptr)
            Manager.ResetContainer(ContainerKey(Container));
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

    void MarkHarvested(const AHarvestableActor Harvestable, const FString& PlayerKey, const FString& PlayerName)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || PlayerKey.IsEmpty())
            return;
        const int64 Until = RegrowTime(Harvestable);
        Manager.MarkHarvested(ContainerKey(Harvestable), PlayerKey, Until);
        const FString When = Until == 0 ? "never regrows" : f"regrows for them in {(Until - NowUnix()) / 60} min";
        WSCoop::Info(f"Harvest {ContainerKey(Harvestable)}: {PlayerName} gathered it ({When}); still available to others");
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
