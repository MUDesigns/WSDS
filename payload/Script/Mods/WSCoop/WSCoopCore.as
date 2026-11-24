// WitchspireCoopOverhaul - shared settings, player keys and the saved coop manager.
//
// Settings come from ServerConfig.json -> "Coop" (the launcher passes them as -WSCoop_<Key>=<Value>).
// Without arguments (e.g. a normal listen host that has the mod installed) the defaults below apply.
// All gameplay decisions are made on the server.

namespace WSCoop
{
    FString Raw(const FString& Key)
    {
        FString Value;
        if (System::ParseParamValue(System::GetCommandLine(), f"WSCoop_{Key}=", Value))
            return Value;
        return "";
    }

    bool Flag(const FString& Key, bool Default)
    {
        const FString V = Raw(Key).ToLower();
        if (V.IsEmpty())
            return Default;
        return V == "true" || V == "1" || V == "yes";
    }

    float Number(const FString& Key, float Default)
    {
        const FString V = Raw(Key);
        if (V.IsEmpty())
            return Default;
        return float(String::Conv_StringToDouble(V));
    }

    bool InstancedLoot() { return Flag("InstancedLoot", true); }
    bool InstancedHarvest() { return Flag("InstancedHarvest", true); }
    float InstancedLootRange() { return Number("InstancedLootRange", 6000); }
    bool SharedObjectives() { return Flag("SharedObjectives", true); }
    bool RetroactiveMilestones() { return Flag("RetroactiveMilestones", true); }
    bool CatchUpXP() { return Flag("CatchUpXP", true); }
    float CatchUpMaxMultiplier() { return Number("CatchUpMaxMultiplier", 2.5); }
    float CatchUpPerLevel() { return Number("CatchUpPerLevel", 0.15); }
    bool CovenSynergy() { return Flag("CovenSynergy", true); }
    float CovenRange() { return Number("CovenRange", 5000); }
    float CovenBonusPerMember() { return Number("CovenBonusPerMember", 0.1); }

    void Info(const FString& Message)
    {
        Log(n"WSCoop", f"[WSCoop] {Message}");
    }

    // Stable per-player key: the same identity the save system uses for this player's character file.
    FString PlayerKey(const APlayerCharacter Player)
    {
        if (Player == nullptr)
            return "";
        APlayerController PC = Cast<APlayerController>(Player.Controller);
        if (PC == nullptr)
            return "";

        USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
        if (SaveSubsystem != nullptr)
        {
            const TMap<const APlayerController, FSaveSystemIdentity>& Identities = SaveSubsystem.GetOnlineIdentities();
            if (Identities.Contains(PC))
            {
                const FSaveSystemIdentity& Identity = Identities[PC];
                if (!Identity.Steam.IsEmpty())
                    return Identity.Steam;
                if (!Identity.Epic.IsEmpty())
                    return Identity.Epic;
            }
        }
        if (PC.PlayerState != nullptr)
            return f"{PC.PlayerState.GetUniqueId().ToString().GetHash()}";
        return "";
    }

    FString PlayerName(const APlayerCharacter Player)
    {
        if (Player == nullptr || Player.PlayerState == nullptr)
            return "?";
        return Player.PlayerState.GetPlayerName();
    }

    void ShowLocalMessage(const FText& Text)
    {
        AOnScreenMessageManager Manager = Cast<AOnScreenMessageManager>(AGameManager::Get(AOnScreenMessageManager));
        if (Manager == nullptr)
            return;
        FOnScreenMessageRequest Request;
        Request.MessageType = EScreenMessageType::QuestUpdate;
        FOnScreenMessageRequestPayload_QuestUpdate Payload;
        Payload.InfoText = Text;
        Request.Payload.InitializeAs(Payload);
        Manager.LocalShowOnScreenMessage(Request);
    }

    // Server: show a notice to one player only.
    void Notify(const APlayerCharacter Player, const FString& Message)
    {
        if (Player == nullptr)
            return;
        APlayerController PC = Cast<APlayerController>(Player.Controller);
        if (PC == nullptr)
            return;
        if (PC.IsLocalController())
        {
            ShowLocalMessage(FText::FromString(Message));
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ClientCoopMessage(Message);
    }

    // All living player characters in the world.
    TArray<APlayerCharacter> GetPlayers()
    {
        TArray<APlayerCharacter> Result;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return Result;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerCharacter Character = Cast<APlayerCharacter>(PS.GetPawn());
            if (Character != nullptr)
                Result.Add(Character);
        }
        return Result;
    }

    AWSCoopManager GetManager()
    {
        return Cast<AWSCoopManager>(AGameManager::Get(AWSCoopManager));
    }

    float TimeOffsetHours()
    {
        AWSCoopManager Manager = GetManager();
        return Manager != nullptr ? Manager.TimeOffsetHours : 0.0;
    }
}

// A loot pickup dropped for one player only (see WSCoopLoot::DropPersonalLoot).
USTRUCT()
struct FWSCoopPersonalPickup
{
    UPROPERTY()
    AItemPickup Pickup;

    UPROPERTY()
    APlayerState Owner;
};

// World-saved coop state. Lives in the world save so it follows the server, not any single player.
UCLASS()
class AWSCoopManager : AGameManager
{
    default bReplicates = true;
    default bAlwaysRelevant = true;
    default bSupportsSaving = true;
    default bSupportsDirtying = true;

    // Personal loot pickups in the world and whose they are. Replicated so every game can hide the ones
    // that belong to someone else (kept out of AItemPickup: changing that class breaks its cooked Blueprints).
    UPROPERTY(Replicated, Transient, ReplicatedUsing = OnRep_PersonalPickups)
    TArray<FWSCoopPersonalPickup> PersonalPickups;

    UFUNCTION()
    void OnRep_PersonalPickups()
    {
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
            WSCoopLoot::ApplyPersonalPickup(Entry.Pickup);
    }

    void AddPersonalPickup(AItemPickup Pickup, APlayerState PickupOwner)
    {
        FWSCoopPersonalPickup Entry;
        Entry.Pickup = Pickup;
        Entry.Owner = PickupOwner;
        PersonalPickups.Add(Entry);
        ForceNetUpdate();
    }

    // Owner of a personal pickup; nullptr for ordinary pickups.
    APlayerState PersonalOwnerOf(const AActor Pickup) const
    {
        if (Pickup == nullptr)
            return nullptr;
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
        {
            if (Entry.Pickup == Pickup)
                return Entry.Owner;
        }
        return nullptr;
    }

    bool IsPersonalPickup(const AActor Pickup) const
    {
        if (Pickup == nullptr)
            return false;
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
        {
            if (Entry.Pickup == Pickup)
                return true;
        }
        return false;
    }

    // Server: forget pickups that were collected or timed out.
    void PrunePersonalPickups()
    {
        int Removed = 0;
        for (int i = PersonalPickups.Num() - 1; i >= 0; --i)
        {
            if (!IsValid(PersonalPickups[i].Pickup))
            {
                PersonalPickups.RemoveAt(i);
                Removed++;
            }
        }
        if (Removed > 0)
            ForceNetUpdate();
    }

    // Admin time-of-day adjustment in hours, added to the game's world clock (replicated to clients).
    UPROPERTY(SaveGame, Replicated)
    float TimeOffsetHours = 0;

    void SetTimeOffset(float Hours)
    {
        TimeOffsetHours = Hours;
        MarkSaveGameDirty();
    }

    // "<chest>|<playerKey>" entries: which player already took their loot from which container.
    UPROPERTY(SaveGame)
    private TArray<FString> LootRecords;

    // Objective tags completed by anyone in this world (for shared / retroactive progression).
    UPROPERTY(SaveGame)
    TArray<FGameplayTag> WorldCompletedObjectives;

    // "<objectiveTag>|<playerKey>": completion effects already applied for that player.
    UPROPERTY(SaveGame)
    private TArray<FString> EffectRecords;

    private TSet<FString> LootLookup;

    // Per-player harvesting: "<harvestable>|<playerKey>|<unix time it regrows for them; 0 = never>".
    UPROPERTY(SaveGame)
    private TArray<FString> HarvestRecords;

    // "<harvestable>|<playerKey>" -> index into HarvestRecords (rebuilt on load).
    private TMap<FString, int> HarvestLookup;

    private void RebuildHarvestLookup()
    {
        HarvestLookup.Empty();
        for (int i = 0; i < HarvestRecords.Num(); ++i)
        {
            TArray<FString> Fields;
            HarvestRecords[i].ParseIntoArray(Fields, "|");
            if (Fields.Num() == 3)
                HarvestLookup.Add(f"{Fields[0]}|{Fields[1]}", i);
        }
    }

    // True while this player's harvest of that node has not regrown yet.
    bool HasHarvested(const FString& Harvestable, const FString& PlayerKey, int64 NowUnix)
    {
        if (HarvestLookup.Num() == 0 && HarvestRecords.Num() > 0)
            RebuildHarvestLookup();
        int Index = -1;
        if (!HarvestLookup.Find(f"{Harvestable}|{PlayerKey}", Index) || !HarvestRecords.IsValidIndex(Index))
            return false;
        TArray<FString> Fields;
        HarvestRecords[Index].ParseIntoArray(Fields, "|");
        if (Fields.Num() != 3)
            return false;
        const int64 Until = String::Conv_StringToInt64(Fields[2]);
        return Until == 0 || NowUnix < Until;
    }

    void MarkHarvested(const FString& Harvestable, const FString& PlayerKey, int64 UntilUnix)
    {
        if (PlayerKey.IsEmpty())
            return;
        if (HarvestLookup.Num() == 0 && HarvestRecords.Num() > 0)
            RebuildHarvestLookup();
        const FString Entry = f"{Harvestable}|{PlayerKey}|{UntilUnix}";
        int Index = -1;
        if (HarvestLookup.Find(f"{Harvestable}|{PlayerKey}", Index) && HarvestRecords.IsValidIndex(Index))
            HarvestRecords[Index] = Entry;
        else
        {
            HarvestRecords.Add(Entry);
            HarvestLookup.Add(f"{Harvestable}|{PlayerKey}", HarvestRecords.Num() - 1);
        }
        MarkSaveGameDirty();
    }

    int HarvestRecordCount() const
    {
        return HarvestRecords.Num();
    }

    // Tests: makes all of a player's regrowing harvests come back at UntilUnix.
    int SetRegrowTimes(const FString& PlayerKey, int64 UntilUnix)
    {
        int Changed = 0;
        for (int i = 0; i < HarvestRecords.Num(); ++i)
        {
            TArray<FString> Fields;
            HarvestRecords[i].ParseIntoArray(Fields, "|");
            if (Fields.Num() != 3 || Fields[1] != PlayerKey || Fields[2] == "0")
                continue;
            HarvestRecords[i] = f"{Fields[0]}|{Fields[1]}|{UntilUnix}";
            Changed++;
        }
        MarkSaveGameDirty();
        return Changed;
    }

    // Everything one player has taken that their game should keep hidden: gathered nodes that have not
    // regrown for them yet and looted chests. OutUntil: unix time it comes back for them, 0 = never.
    void GetTakenBy(const FString& PlayerKey, int64 NowUnix, TArray<FString>& OutNames, TArray<int64>& OutUntil) const
    {
        const FString HarvestPart = f"|{PlayerKey}|";
        for (const FString& Record : HarvestRecords)
        {
            if (!Record.Contains(HarvestPart))
                continue;
            TArray<FString> Fields;
            Record.ParseIntoArray(Fields, "|");
            if (Fields.Num() != 3 || Fields[1] != PlayerKey)
                continue;
            const int64 Until = String::Conv_StringToInt64(Fields[2]);
            if (Until != 0 && Until <= NowUnix)
                continue;
            OutNames.Add(Fields[0]);
            OutUntil.Add(Until);
        }
        const FString LootSuffix = f"|{PlayerKey}";
        for (const FString& Record : LootRecords)
        {
            if (!Record.EndsWith(LootSuffix))
                continue;
            OutNames.Add(Record.Left(Record.Len() - LootSuffix.Len()));
            OutUntil.Add(0);
        }
    }

    // Admin / tests: forget everything recorded for one player (chests looted, nodes harvested).
    int ForgetPlayerLoot(const FString& PlayerKey)
    {
        int Removed = 0;
        const FString LootSuffix = f"|{PlayerKey}";
        for (int i = LootRecords.Num() - 1; i >= 0; --i)
        {
            if (LootRecords[i].EndsWith(LootSuffix))
            {
                LootRecords.RemoveAt(i);
                Removed++;
            }
        }
        const FString HarvestPart = f"|{PlayerKey}|";
        for (int i = HarvestRecords.Num() - 1; i >= 0; --i)
        {
            if (HarvestRecords[i].Contains(HarvestPart))
            {
                HarvestRecords.RemoveAt(i);
                Removed++;
            }
        }
        RebuildLookup();
        RebuildHarvestLookup();
        MarkSaveGameDirty();
        return Removed;
    }

    // Transient quest-sharing state (see WSCoopQuests).
    FGameplayTag CurrentCompletionTag;
    bool bPropagating = false;

    bool HasEffectsApplied(FGameplayTag Tag, const FString& PlayerKey) const
    {
        return EffectRecords.Contains(f"{Tag}|{PlayerKey}");
    }

    void MarkEffectsApplied(FGameplayTag Tag, const FString& PlayerKey)
    {
        if (PlayerKey.IsEmpty())
            return;
        const FString Entry = f"{Tag}|{PlayerKey}";
        if (EffectRecords.Contains(Entry))
            return;
        EffectRecords.Add(Entry);
        MarkSaveGameDirty();
    }

    // Players whose character save has been applied (catch-up must wait for this).
    private TSet<APlayerController> LoadedPlayers;

    bool IsPlayerLoaded(const APlayerController PC) const
    {
        return PC != nullptr && LoadedPlayers.Contains(PC);
    }

    UFUNCTION()
    private void OnPlayerLoaded(APlayerController Player, bool bSuccess)
    {
        if (Player == nullptr)
            return;
        LoadedPlayers.Add(Player);
        APlayerCharacter Character = Cast<APlayerCharacter>(Player.GetControlledPawn());
        WSCoop::Info(f"Character data ready for {Player.PlayerState.GetPlayerName()} (fromSave={bSuccess})");
        if (Character != nullptr)
            WSCoopQuests::CatchUp(Character);
    }

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        if (HasAuthority())
        {
            USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
            if (SaveSubsystem != nullptr)
                SaveSubsystem.OnPlayerLoaded.AddUFunction(this, n"OnPlayerLoaded");
        }
        RebuildLookup();
        WSCoop::Info(f"Coop manager ready (authority={HasAuthority()}) lootRecords={LootRecords.Num()} worldObjectives={WorldCompletedObjectives.Num()}");
    }

    UFUNCTION(BlueprintOverride)
    void ActorLoaded()
    {
        RebuildLookup();
        WSCoop::Info(f"Coop manager loaded from save: lootRecords={LootRecords.Num()} worldObjectives={WorldCompletedObjectives.Num()}");
    }

    private void RebuildLookup()
    {
        LootLookup.Empty();
        LootLookup.Append(LootRecords);
    }

    bool HasLooted(const FString& ContainerKey, const FString& PlayerKey) const
    {
        return LootLookup.Contains(f"{ContainerKey}|{PlayerKey}");
    }

    void MarkLooted(const FString& ContainerKey, const FString& PlayerKey)
    {
        const FString Entry = f"{ContainerKey}|{PlayerKey}";
        if (LootLookup.Contains(Entry))
            return;
        LootLookup.Add(Entry);
        LootRecords.Add(Entry);
        MarkSaveGameDirty();
    }

    int LootRecordCount() const
    {
        return LootRecords.Num();
    }

    int CountLooters(const FString& ContainerKey) const
    {
        int Count = 0;
        const FString Prefix = f"{ContainerKey}|";
        for (const FString& Entry : LootRecords)
        {
            if (Entry.StartsWith(Prefix))
                Count++;
        }
        return Count;
    }

    // Dungeon resets etc.: everyone may loot this container again.
    void ResetContainer(const FString& ContainerKey)
    {
        const FString Prefix = f"{ContainerKey}|";
        for (int i = LootRecords.Num() - 1; i >= 0; --i)
        {
            if (LootRecords[i].StartsWith(Prefix))
                LootRecords.RemoveAt(i);
        }
        RebuildLookup();
        MarkSaveGameDirty();
    }

    void AddWorldObjective(FGameplayTag Tag)
    {
        if (!Tag.IsValid() || WorldCompletedObjectives.Contains(Tag))
            return;
        WorldCompletedObjectives.Add(Tag);
        MarkSaveGameDirty();
    }
};
