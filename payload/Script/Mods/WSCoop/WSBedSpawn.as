// WitchspireCoopOverhaul - bed spawn points.
//
// Pressing interact on a bed makes it that player's spawn point: when they respawn after dying (holding the
// respawn input, or when the spirit-form timer runs out) they wake up at their bed instead of at their last
// hearth. Dungeon checkpoints still come first, and a revive by another player still happens in place.
// Hook: UTeleportComponent::Server_RequestCheckpointTeleport (sent by the client when the death spirit form ends).
// Each player has their own bed; any player can use any bed and several players can share one.
//
// Beds are building pieces kept by the building chunks; their cooked Blueprints cannot get new components,
// so the server puts a small replicated marker actor (UInteractableComponent + UInteraction_WSBedSpawn) on
// every bed that is loaded. Spawn points are saved in the world (AWSCoopManager.BedSpawns).
//
// ServerConfig.json -> "Coop" -> "BedSpawn" (default true).

namespace WSBedSpawn
{
    bool Enabled() { return WSCoop::Flag("BedSpawn", true); }

    // Bed building classes: the current bed and the two older furniture beds (worlds may still have them).
    bool IsBedClass(const UClass InClass)
    {
        if (InClass == nullptr)
            return false;
        const FString Name = InClass.GetName().ToString();
        return Name.StartsWith("BuildingPiece_") && Name.Contains("_Bed") && !Name.Contains("Familiar");
    }

    bool IsBed(const AActor Actor)
    {
        return Actor != nullptr && IsBedClass(Actor.Class);
    }

    // Where a player wakes up: on top of the bed, facing the way the bed faces.
    FVector WakeLocation(const ABuilding Bed)
    {
        FVector Origin;
        FVector Extent;
        Bed.GetActorBounds(true, Origin, Extent);
        return FVector(Origin.X, Origin.Y, Origin.Z + Extent.Z + 5.0);
    }

    UWSBedSpawnSubsystem GetSubsystem()
    {
        return UWSBedSpawnSubsystem::Get();
    }

    // Server: player pressed interact on a bed.
    void SetBed(APlayerCharacter Player, AWSBedMarker Marker)
    {
        if (!System::IsServer() || Player == nullptr || Marker == nullptr || !IsValid(Marker.Bed))
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString Key = WSCoop::PlayerKey(Player);
        if (Manager == nullptr || Key.IsEmpty())
        {
            WSCoop::Notify(Player, "Your save identity is not ready yet. Try again in a moment.", "Spawn Point Not Set");
            return;
        }
        const FVector BedLocation = Marker.Bed.GetActorLocation();
        const FVector Wake = WakeLocation(Marker.Bed);
        const float Yaw = Marker.Bed.GetActorRotation().Yaw;
        const bool bSame = Manager.HasBedSpawnAt(Key, BedLocation);
        Manager.SetBedSpawn(Key, BedLocation, Wake, Yaw);
        WSCoop::Info(f"Bed spawn set for {WSCoop::PlayerName(Player)} at {BedLocation} (wake {Wake})");
        // At night the bed is also for sleeping (see WSSleep); its notice says enough when the spawn point didn't change.
        const bool bSleeping = WSSleep::TryToSleep(Player, Marker);
        if (!bSleeping || !bSame)
            WSCoop::Notify(Player, bSame ? "This bed is already your spawn point." : "You will wake up here after you die.", bSame ? "Spawn Point" : "Spawn Point Set");
    }

    // Server, from the respawn checkpoint teleport: send a respawning player to their bed. False = no (valid) bed.
    bool TeleportToBed(APlayerCharacter Player)
    {
        if (!System::IsServer() || Player == nullptr || !Enabled())
            return false;
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString Key = WSCoop::PlayerKey(Player);
        if (Manager == nullptr || Key.IsEmpty())
            return false;
        FVector BedLocation;
        FVector Wake;
        float Yaw = 0;
        if (!Manager.GetBedSpawn(Key, BedLocation, Wake, Yaw))
            return false;
        if (!BedStillExists(BedLocation))
        {
            Manager.ClearBedSpawnsAt(BedLocation);
            WSCoop::Info(f"Bed spawn of {WSCoop::PlayerName(Player)} at {BedLocation} is gone; respawning in place");
            WSCoop::Notify(Player, "Your bed is gone. Use another bed to set a new spawn point.", "Bed Missing");
            return false;
        }

        FTeleportRequest Request = Teleport::AtFeet(Wake);
        Request.Rotation = FRotator(0, Yaw, 0);
        Request.bUseActorRotation = false;
        const float Distance = Player.GetActorLocation().Distance(Wake);
        // Far away: let the loading component stream the destination in first (like the hearth return).
        Request.LoadMode = Distance > 5000.0 ? ETeleportLoadMode::Loading : ETeleportLoadMode::Instant;
        Player.RequestTeleport(Request);
        WSCoop::Info(f"Respawning {WSCoop::PlayerName(Player)} at their bed {BedLocation} ({int(Distance / 100)} m away)");
        return true;
    }

    // A bed is still standing at that spot: either its actor is loaded, or its building chunk still holds a
    // building instance there.
    bool BedStillExists(const FVector& BedLocation)
    {
        TArray<ABuilding> Buildings;
        GetAllActorsOfClass(Buildings);
        for (ABuilding Building : Buildings)
        {
            if (IsValid(Building) && !Building.IsPreviewBuilding() && IsBed(Building) && Building.GetActorLocation().Distance(BedLocation) < 30.0)
                return true;
        }
        return ChunkHasInstanceAt(BedLocation);
    }

    // The bed's actor is not loaded (nobody near it): its building chunk must still exist and still hold
    // beds. Single beds destroyed by a player are cleared through OnBuildingDestroyed.
    bool ChunkHasInstanceAt(const FVector& Location)
    {
        ABuildingManager BuildingManager = AGameManager::Get(ABuildingManager);
        if (BuildingManager == nullptr)
            return true; // can't tell: don't take the spawn point away
        ABuildingChunk Chunk = BuildingManager.GetChunk(Location);
        if (Chunk == nullptr)
            return false;
        for (UInstancedActorComponent Comp : Chunk.InstancedActorComponents)
        {
            if (Comp != nullptr && Comp.InstanceTransforms.Num() > 0 && IsBedClass(Comp.GetActorClass()))
                return true;
        }
        return false;
    }

    // Server, from UBuildingComponent::DestroyBuilding: a player took a bed down.
    void OnBuildingDestroyed(ABuilding Building)
    {
        if (!System::IsServer() || !IsBed(Building))
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        const FVector BedLocation = Building.GetActorLocation();
        TArray<FString> Keys = Manager.ClearBedSpawnsAt(BedLocation);
        if (Keys.Num() == 0)
            return;
        WSCoop::Info(f"Bed at {BedLocation} destroyed; cleared {Keys.Num()} spawn point(s)");
        for (APlayerCharacter P : WSCoop::GetPlayers())
        {
            if (Keys.Contains(WSCoop::PlayerKey(P)))
                WSCoop::Notify(P, "Use another bed to set a new spawn point.", "Your Bed Was Destroyed");
        }
    }

    // Admin/tests: "<status>" text for one player.
    FString Describe(APlayerCharacter Player)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || Player == nullptr)
            return "no manager/player";
        FVector BedLocation;
        FVector Wake;
        float Yaw = 0;
        if (!Manager.GetBedSpawn(WSCoop::PlayerKey(Player), BedLocation, Wake, Yaw))
            return f"{WSCoop::PlayerName(Player)}: no bed";
        return f"{WSCoop::PlayerName(Player)}: bed {int(BedLocation.X)} {int(BedLocation.Y)} {int(BedLocation.Z)} wake {int(Wake.X)} {int(Wake.Y)} {int(Wake.Z)} exists={BedStillExists(BedLocation)}";
    }
}

// The interaction on a bed marker.
UCLASS()
class UInteraction_WSBedSpawn : UInteraction
{
    default InteractionType = EInteractionType::OnActivated;
    default InteractionDuration = 0.f;

    UFUNCTION(BlueprintOverride)
    void OnInteractServer(const FInteractionContext& Context)
    {
        APlayerCharacter Player = Context.Interactor != nullptr ? Cast<APlayerCharacter>(Context.Interactor.Owner) : nullptr;
        AWSBedMarker Marker = Context.Interactable != nullptr ? Cast<AWSBedMarker>(Context.Interactable.Owner) : nullptr;
        WSBedSpawn::SetBed(Player, Marker);
        Super::OnInteractServer(Context);
    }
};

// Server-spawned, replicated stand-in that makes one bed interactable. Not saved: the server puts markers back
// on beds as they load.
UCLASS()
class AWSBedMarker : AActor
{
    default bReplicates = true;
    default bAlwaysRelevant = true;

    UPROPERTY(DefaultComponent, RootComponent)
    UInteractableComponent Interactable;
    default Interactable.CapsuleRadius = 160;
    default Interactable.CapsuleHalfHeight = 140;

    // Server only.
    ABuilding Bed;

    private int AutoInteractTries = 0;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        if (!HasAuthority())
        {
            // Developer test: a client started with -WSBedAutoInteract presses interact once it stands at this bed.
            if (System::ParseParam(System::GetCommandLine(), "WSBedAutoInteract"))
                System::SetTimer(this, n"AutoInteract", 1.0, true);
            return;
        }
        UInteraction_WSBedSpawn Interaction = Cast<UInteraction_WSBedSpawn>(NewObject(Interactable, UInteraction_WSBedSpawn));
        Interactable.SetInteraction(Interaction);
    }

    UFUNCTION()
    private void AutoInteract()
    {
        APlayerCharacter Local = Game::GetLocalPlayer();
        if (Local == nullptr || ++AutoInteractTries > 60)
            return;
        UInteractorComponent Interactor = UInteractorComponent::Get(Local);
        const float Distance = Local.GetActorLocation().Distance(GetActorLocation());
        if (Interactor == nullptr || Distance > 400)
            return;
        UInteractableComponent Picked = Interactor.OnInteractPressed();
        const FString PickedName = Picked != nullptr ? Picked.Owner.GetName().ToString() : "none";
        UInteractableComponent Mine = UInteractableComponent::Get(Local);
        const bool bOverlap = Mine != nullptr && Interactable.IsOverlappingComponent(Mine);
        WSCoop::Info(f"BEDTEST client pressed interact {Distance:.0f} cm from bed: picked={PickedName} overlap={bOverlap}");
        if (Picked == Interactable)
            AutoInteractTries = 1000;
    }
};

// Server: keeps a marker on every loaded bed (checked every 2 s; a cached class test keeps it cheap).
UCLASS()
class UWSBedSpawnSubsystem : UScriptWorldSubsystem
{
    private float Accumulator = 0;
    private TMap<ABuilding, AWSBedMarker> Markers;
    private TSet<UClass> BedClasses;
    private TSet<UClass> OtherClasses;
    private bool bLoggedStart = false;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!System::IsServer())
            return;
        Accumulator += DeltaTime;
        if (Accumulator < 2.0)
            return;
        Accumulator = 0;
        if (!WSBedSpawn::Enabled() || WSCoop::GetManager() == nullptr)
            return;
        Refresh();
    }

    bool IsBedCached(UClass InClass)
    {
        if (BedClasses.Contains(InClass))
            return true;
        if (OtherClasses.Contains(InClass))
            return false;
        const bool bBed = WSBedSpawn::IsBedClass(InClass);
        if (bBed)
            BedClasses.Add(InClass);
        else
            OtherClasses.Add(InClass);
        return bBed;
    }

    void Refresh()
    {
        // Drop markers whose bed went away (destroyed or unloaded).
        TArray<ABuilding> Gone;
        for (auto Entry : Markers)
        {
            if (!IsValid(Entry.Key) || Entry.Key.IsActorBeingDestroyed())
                Gone.Add(Entry.Key);
        }
        for (ABuilding B : Gone)
        {
            AWSBedMarker M;
            if (Markers.Find(B, M) && IsValid(M))
                M.DestroyActor();
            Markers.Remove(B);
        }

        TArray<ABuilding> Buildings;
        GetAllActorsOfClass(Buildings);
        int Added = 0;
        for (ABuilding Building : Buildings)
        {
            if (Building == nullptr || Building.IsPreviewBuilding() || !IsBedCached(Building.Class) || Markers.Contains(Building))
                continue;
            FVector Origin;
            FVector Extent;
            Building.GetActorBounds(true, Origin, Extent);
            AWSBedMarker Marker = Cast<AWSBedMarker>(SpawnActor(AWSBedMarker, Origin, Building.GetActorRotation()));
            if (Marker == nullptr)
                continue;
            Marker.Bed = Building;
            Markers.Add(Building, Marker);
            Added++;
        }
        if (Added > 0 || !bLoggedStart)
        {
            bLoggedStart = true;
            WSCoop::Info(f"Bed markers: +{Added}, {Markers.Num()} beds interactable ({Buildings.Num()} building actors loaded)");
        }
    }

    int NumMarkers() const
    {
        return Markers.Num();
    }

    // Tests: the marker nearest to a location.
    AWSBedMarker NearestMarker(const FVector& Location) const
    {
        AWSBedMarker Best = nullptr;
        float BestDist = MAX_flt;
        for (auto Entry : Markers)
        {
            if (!IsValid(Entry.Value))
                continue;
            const float D = Entry.Value.GetActorLocation().Distance(Location);
            if (D < BestDist)
            {
                BestDist = D;
                Best = Entry.Value;
            }
        }
        return Best;
    }
};
