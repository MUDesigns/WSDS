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
