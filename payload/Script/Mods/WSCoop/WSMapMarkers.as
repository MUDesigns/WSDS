// WitchspireCoopMod - map markers, death markers, long-range pings and the teammate compass.
//
// Map markers: left-click the world map to mark a spot for everyone (R or the gamepad Reset button marks the centre
// of the view). A bar at the bottom of the map picks the marker type - Meet here, Danger, Loot or Base - each with
// its own icon and colour. Each player can have Coop.MaxMarkersPerPlayer markers (default 3; placing another
// removes their oldest); clicking one of your own markers removes it. Everyone sees each marker as a beam of light
// in the world (the game's light-beam effect, tinted), as an icon on the world map, and on the compass at any
// distance with the owner's name. Markers are kept by the server (AWSCoopManager.MapMarkers, saved with the world).
// Setting: Coop.MapMarkers.
//
// Death markers (Coop.DeathMarkers): when a player goes down, everyone gets a crimson beam, map icon and compass
// marker at that spot, so friends can come and revive them. A revive removes it; after a respawn elsewhere it moves
// to the grave holding the items they dropped and stays until the grave is emptied.
//
// Pings: the game's own ping (middle mouse) only shows to players nearby. The mod adds a short beam, a compass
// marker at any distance and a map icon, labelled with who pinged and what ("PlayerA: Enemy"). Coop.Pings.
//
// Teammate compass: every other player is shown on the compass at any distance with their name under the icon,
// and the world map shows teammates' names under their icons. Client side only.

namespace WSMapMarkers
{
    const FString BeamClassPath = "/Game/Art/Marketplace/CartoonWaterShader/EpicGamesFog/Blueprints/BP_LightBeam.BP_LightBeam_C";
    const FString TeammateCompassIconPath = "/Game/UserInterface/HUD/Compass/Icons/WBP_CompassIcon_PlayerMarker.WBP_CompassIcon_PlayerMarker_C";
    const FString MarkerCompassIconPath = "/Game/UserInterface/HUD/Compass/Icons/WBP_CompassIcon_Ping.WBP_CompassIcon_Ping_C";
    const FString CompassLabelStylePath = "/Game/UserInterface/Foundation/Text/Styles/Text/TextStyle_S4_Light_Bold.TextStyle_S4_Light_Bold_C";
    const FString MapLabelStylePath = "/Game/UserInterface/Foundation/Text/Styles/Text/TextStyle_S3_Light_Bold.TextStyle_S3_Light_Bold_C";
    const FString ElementPrefix = "WSMarker_";

    const float PingSeconds = 10.0;
    const int MaxPingsPerPlayer = 3;

    // Server settings.
    bool ServerEnabled() { return WSCoop::Flag("MapMarkers", true); }
    bool DeathMarkersEnabled() { return WSCoop::Flag("DeathMarkers", true); }
    bool PingsEnabled() { return WSCoop::Flag("Pings", true); }
    int MaxPerPlayer() { return Math::Clamp(int(WSCoop::Number("MaxMarkersPerPlayer", 3)), 1, 10); }

    UWSMapMarkerView View()
    {
        return UWSMapMarkerView::Get();
    }

    // The compass shows teammates itself (vanilla per-pawn player icons are skipped, see UCompassIconComponent).
    bool ShowsTeammates()
    {
        return !System::IsDedicatedServer() && !WSDS::IsHeadlessHost();
    }

    // Compass icons that ignore the distance fade (markers and teammates are shown at any distance).
    bool IsPinnedIcon(const UCompassIconWidget Icon)
    {
        UWSMapMarkerView V = View();
        return V != nullptr && V.IsPinned(Icon);
    }

    bool IsSaneLocation(const FVector& L)
    {
        // Also rejects NaN (every comparison with NaN is false).
        return Math::Abs(L.X) < 5000000.0 && Math::Abs(L.Y) < 5000000.0 && Math::Abs(L.Z) < 5000000.0;
    }

    // ---- marker types ----

    bool IsPlaceableType(const FString& Type)
    {
        return Type == "meet" || Type == "danger" || Type == "loot" || Type == "base";
    }

    FString TypeTitle(const FString& Type)
    {
        if (Type == "danger")
            return "Danger";
        if (Type == "loot")
            return "Loot";
        if (Type == "base")
            return "Base";
        return "Meet here";
    }

    FString IconPath(const FString& Kind)
    {
        if (Kind == "danger")
            return "/Game/Art/UI/Icons/Placeholder/Items/FlatIcons/lorc/crossed-swords.crossed-swords";
        if (Kind == "loot")
            return "/Game/Art/UI/Icons/Placeholder/Items/FlatIcons/lorc/gems.gems";
        if (Kind == "base")
            return "/Game/Art/UI/Icons/Placeholder/Items/FlatIcons/delapouite/house.house";
        if (Kind == "death")
            return "/Game/Art/UI/Icons/Map/T_Icon_MapMarker_GraveMarker.T_Icon_MapMarker_GraveMarker";
        if (Kind == "ping")
            return "/Game/Art/UI/Icons/Placeholder/Items/FlatIcons/delapouite/crosshair.crosshair";
        return "/Game/Art/UI/Icons/Map/T_Icon_map_ping.T_Icon_map_ping";
    }

    // Fixed colours per type; "meet" markers and pings use the owner's player colour instead.
    bool FixedColor(const FString& Kind, FLinearColor& OutColor)
    {
        if (Kind == "danger")
            OutColor = FLinearColor(1.0, 0.33, 0.05, 1);
        else if (Kind == "loot")
            OutColor = FLinearColor(1.0, 0.8, 0.15, 1);
        else if (Kind == "base")
            OutColor = FLinearColor(0.25, 0.55, 1.0, 1);
        else if (Kind == "death")
            OutColor = FLinearColor(0.9, 0.02, 0.1, 1);
        else
            return false;
        return true;
    }

    // ---- entries ----

    // "key|name|x|y|z|type|id" (0.0.49 entries: "key|name|x|y|z" = a meet marker with id 0).
    bool ParseMarker(const FString& Entry, FString& OutKey, FString& OutName, FVector& OutLocation, FString& OutType, int& OutId)
    {
        TArray<FString> F;
        Entry.ParseIntoArray(F, "|", false);
        if (F.Num() != 5 && F.Num() != 7)
            return false;
        OutKey = F[0];
        OutName = F[1];
        OutLocation = FVector(String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]), String::Conv_StringToDouble(F[4]));
        OutType = F.Num() == 7 && IsPlaceableType(F[5]) ? F[5] : "meet";
        OutId = F.Num() == 7 ? String::Conv_StringToInt(F[6]) : 0;
        return true;
    }

    // "key|name|x|y|z|state"
    bool ParseDeath(const FString& Entry, FString& OutKey, FString& OutName, FVector& OutLocation, FString& OutState)
    {
        TArray<FString> F;
        Entry.ParseIntoArray(F, "|", false);
        if (F.Num() != 6)
            return false;
        OutKey = F[0];
        OutName = F[1];
        OutLocation = FVector(String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]), String::Conv_StringToDouble(F[4]));
        OutState = F[5];
        return true;
    }

    // "key|name|x|y|z|label|id"
    bool ParsePing(const FString& Entry, FString& OutKey, FString& OutName, FVector& OutLocation, FString& OutLabel, int& OutId)
    {
        TArray<FString> F;
        Entry.ParseIntoArray(F, "|", false);
        if (F.Num() != 7)
            return false;
        OutKey = F[0];
        OutName = F[1];
        OutLocation = FVector(String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]), String::Conv_StringToDouble(F[4]));
        OutLabel = F[5];
        OutId = String::Conv_StringToInt(F[6]);
        return true;
    }

    // ---- server ----

    APlayerCharacter PlayerOf(APlayerController PC)
    {
        return PC != nullptr ? Cast<APlayerCharacter>(PC.GetControlledPawn()) : nullptr;
    }

    // 0.0.49 request (kept so the RPC table stays the same): place a meet marker or remove all of the player's markers.
    void ServerSet(APlayerController PC, FVector Location, bool bClear)
    {
        if (bClear)
        {
            AWSCoopManager Manager = WSCoop::GetManager();
            APlayerCharacter Player = PlayerOf(PC);
            if (Manager == nullptr || Player == nullptr)
                return;
            const FString Key = WSCoop::PlayerKey(Player);
            for (int i = Manager.MapMarkers.Num() - 1; i >= 0; i--)
            {
                if (Manager.MapMarkers[i].StartsWith(f"{Key}|"))
                    Manager.MapMarkers.RemoveAt(i);
            }
            return;
        }
        ServerEdit(PC, Location, "meet", -1);
    }

    void ServerEdit(APlayerController PC, FVector Location, FString Type, int RemoveId)
    {
        if (!System::IsServer() || PC == nullptr)
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        APlayerCharacter Player = PlayerOf(PC);
        if (Manager == nullptr || Player == nullptr)
            return;
        const FString Key = WSCoop::PlayerKey(Player);
        if (Key.IsEmpty())
            return;
        if (Type == "death")
        {
            if (RemoveId >= 0 && Manager.ClearDeathMarker(Key))
                WSCoop::Info(f"Death marker of {WSCoop::PlayerName(Player)} removed by its owner");
            return;
        }
        if (!ServerEnabled())
            return;
        if (RemoveId >= 0)
        {
            if (Manager.RemoveMapMarker(Key, RemoveId))
                WSCoop::Info(f"Map marker {RemoveId} of {WSCoop::PlayerName(Player)} removed");
            return;
        }
        if (!IsSaneLocation(Location) || !IsPlaceableType(Type))
            return;
        const int Id = Manager.AddMapMarker(Key, WSCoop::PlayerName(Player), Location, Type, MaxPerPlayer());
        WSCoop::Info(f"Map marker {Id} ({Type}) of {WSCoop::PlayerName(Player)} set at {Location}");
    }

    // From UPlayerPingAbility.ExecutePin on the server: the game's own ping happened.
    void OnVanillaPing(APlayerCharacter Player, AActor Target, FVector Location)
    {
        if (!System::IsServer() || Player == nullptr || !PingsEnabled())
            return;
        UWSMarkerServer Server = UWSMarkerServer::Get();
        if (Server != nullptr)
            Server.AddPing(Player, Target, Location);
    }

    // What a ping points at, for its label.
    FString PingLabel(APlayerCharacter Pinger, AActor Target, FVector Location)
    {
        APlayerCharacter OtherPlayer = Cast<APlayerCharacter>(Target);
        if (OtherPlayer != nullptr)
            return WSCoop::PlayerName(OtherPlayer);
        AHercCharacter Character = Cast<AHercCharacter>(Target);
        if (Character != nullptr)
            return Pinger.FactionComp.GetAttitudeTowards(Character) == EFactionAttitude::Friendly ? "Creature" : "Enemy";

        // A location: name the nearest thing of interest right there.
        TArray<EObjectTypeQuery> Types;
        Types.Add(EObjectTypeQuery::WorldStatic);
        Types.Add(EObjectTypeQuery::WorldDynamic);
        TArray<AActor> Ignore;
        Ignore.Add(Pinger);
        TArray<AActor> Found;
        System::SphereOverlapActors(Location, 300, Types, nullptr, Ignore, Found);
        float Best = MAX_flt;
        FString Label = "Look here";
        for (AActor A : Found)
        {
            FString Candidate;
            if (A.IsA(AWorldLootChestActor) || A.IsA(AWorldChestActor) || A.IsA(AChestActor))
                Candidate = "Chest";
            else if (A.IsA(AHarvestableActor))
                Candidate = "Resource";
            else if (A.IsA(AItemPickup))
                Candidate = "Item";
            if (Candidate.IsEmpty())
                continue;
            const float D = A.GetActorLocation().Distance(Location);
            if (D < Best)
            {
                Best = D;
                Label = Candidate;
            }
        }
        return Label;
    }

    // ---- client ----

    bool ServerSupportsMarkers()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr && Manager.bMapMarkersEnabled;
    }

    // The local player's own request (from the world map).
    void RequestEdit(FVector Location, const FString& Type, int RemoveId)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr)
            return;
        if (Type != "death" && !ServerSupportsMarkers())
        {
            WSCoop::ShowLocalNotice("Map Markers", "This server doesn't allow map markers.");
            return;
        }
        if (System::IsServer())
        {
            ServerEdit(PC, Location, Type, RemoveId);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ServerWSMarkerEdit(Location, Type, RemoveId);
        else
            WSCoop::ShowLocalNotice("Map Markers", "This server doesn't support map markers.");
    }

    // Visible surfaces under a spot, top to bottom, between Top and Bottom (skips volumes and invisible blockers).
    TArray<FVector> SurfacesBelow(const FVector& Around, float Top, float Bottom)
    {
        TArray<FVector> Out;
        FVector Start = FVector(Around.X, Around.Y, Top);
        const FVector End = FVector(Around.X, Around.Y, Bottom);
        for (int Attempt = 0; Attempt < 48 && Out.Num() < 32; Attempt++)
        {
            FHitResult Hit;
            System::LineTraceSingleByChannel(Hit, Start, End, ECollisionChannel::ECC_Visibility);
            if (!Hit.bBlockingHit)
                break;
            UPrimitiveComponent Comp = Hit.Component;
            AActor HitActor = Hit.Actor;
            const bool bInvisible = Comp == nullptr || !Comp.IsVisible() || (HitActor != nullptr && (HitActor.IsA(AVolume) || HitActor.IsHidden()));
            if (!bInvisible)
                Out.Add(Hit.ImpactPoint);
            Start = Hit.ImpactPoint - FVector(0, 0, 30);
        }
        return Out;
    }

    // Ground just below a stored marker height (markers are saved with the height their owner chose).
    bool FindGround(const FVector& Around, FVector& OutGround)
    {
        TArray<FVector> Surfaces = SurfacesBelow(Around, Around.Z + 1500, Around.Z - 60000);
        if (Surfaces.Num() == 0)
            return false;
        OutGround = Surfaces[0];
        return true;
    }

    // Ground for a spot picked on the map (no height known): near the player, the surface closest to the
    // player's height (under a canopy rather than on top of it); further away, the highest surface.
    bool FindGroundForMapSpot(const FVector& Spot, FVector& OutGround)
    {
        TArray<FVector> Surfaces = SurfacesBelow(Spot, 80000, -80000);
        if (Surfaces.Num() == 0)
            return false;
        OutGround = Surfaces[0];
        APawn Pawn = Game::GetLocalPlayer();
        if (Pawn != nullptr && Pawn.GetActorLocation().Dist2D(Spot) < 40000)
        {
            const float PlayerZ = Pawn.GetActorLocation().Z;
            for (const FVector& S : Surfaces)
            {
                if (Math::Abs(S.Z - PlayerZ) < Math::Abs(OutGround.Z - PlayerZ))
                    OutGround = S;
            }
        }
        if (System::ParseParam(System::GetCommandLine(), "WSMarkerDebug"))
            WSCoop::Info(f"Map markers: {Surfaces.Num()} surfaces under {Spot}, chose {OutGround}");
        return true;
    }

    // Name of the local player (the owner name markers are stored under).
    FString LocalPlayerName()
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        return (PC != nullptr && PC.PlayerState != nullptr) ? PC.PlayerState.GetPlayerName() : "";
    }

    FString SelectedType()
    {
        UWSMapMarkerView V = View();
        return V != nullptr ? V.SelectedType : "meet";
    }

    // Left-click on the world map: place a marker of the selected type.
    void OnMapClicked(FVector WorldLocation)
    {
        FVector Target = WorldLocation;
        FVector Ground;
        if (FindGroundForMapSpot(WorldLocation, Ground))
            Target = Ground;
        RequestEdit(Target, SelectedType(), -1);
    }

    // R / gamepad Reset on the world map: remove your marker at the centre of the view, or place one there.
    void OnMapActionPressed(FVector CenterLocation, float ZoomScale)
    {
        UWSMapMarkerView V = View();
        int Id = -1;
        if (V != nullptr && V.FindOwnMarkerNear(CenterLocation, 2500.0 * ZoomScale, Id))
        {
            RequestEdit(FVector::ZeroVector, "meet", Id);
            return;
        }
        OnMapClicked(CenterLocation);
    }

    // A click on a map icon. True = it was one of ours and has been handled.
    bool OnElementClicked(FName UniqueId)
    {
        if (!UniqueId.ToString().StartsWith(ElementPrefix))
            return false;
        UWSMapMarkerView V = View();
        if (V != nullptr)
            V.OnOwnElementClicked(UniqueId);
        return true;
    }

    // World map labels: called by UWorldMapWidget.Tick for every element it places.
    void PlaceMapLabel(UOverlay Overlay, const FRegisteredWorldMapElement& Element, FVector2D MapPosition, FVector2D WidgetSize)
    {
        UWSMapMarkerView V = View();
        if (V != nullptr)
            V.PlaceMapLabel(Overlay, Element, MapPosition, WidgetSize);
    }

    void FinishMapLabels(UOverlay Overlay)
    {
        UWSMapMarkerView V = View();
        if (V != nullptr)
            V.FinishMapLabels(Overlay);
    }

    void RegisterMapActions(UWorldMapWidget Widget)
    {
        UWSMapMarkerView V = View();
        if (V == nullptr || Widget == nullptr)
            return;
        V.ShowTypeBar(Widget);
        if (V.RegisteredMaps.Contains(Widget))
            return;
        V.RegisteredMaps.Add(Widget);
        UInputAction Action = WSLuminaryRespec::LoadAction(WSLuminaryRespec::ResetActionPath);
        if (Action != nullptr)
            Widget.RegisterUIActionBinding(Action, FSimpleDynamicDelegate(Widget, n"WSOnMarkerAction"));
    }
}

// One marker, death marker or ping as this game shows it.
struct FWSMarkerVisual
{
    FString Uid;
    FString Kind;       // meet, danger, loot, base, death, ping
    FString OwnerName;
    FString Label;      // compass label
    FString Title;      // map tooltip title
    FString Description;
    FLinearColor Color;
    FVector Location;
    int RemoveId = -1;  // owner may remove it with this id (markers, own death marker); -1 = not removable
    bool bOwn = false;
    bool bGrounded = false;
    AActor Beam;
    UCompassIconWidget Icon;
    FName ElementId;
    bool bSeen = false;
}

// One teammate on the compass.
struct FWSMateVisual
{
    APlayerState State;
    UCompassIconWidget Icon;
    bool bSeen = false;
}

UCLASS()
class UWSMapMarkerView : UScriptWorldSubsystem
{
    private TArray<FWSMarkerVisual> Markers;
    private TArray<FWSMateVisual> Mates;
    private TSet<UCompassIconWidget> PinnedIcons;
    private TMap<UCompassIconWidget, UTextBlock> CompassLabels;
    private TMap<FName, UTextBlock> MapLabels;
    private TSet<FName> MapLabelsSeen;
    TSet<UObject> RegisteredMaps;

    // Marker type picked on the map's type bar.
    FString SelectedType = "meet";
    private TMap<UObject, UWidget> TypeBars;
    private TMap<FString, UButton> TypeButtons;

    private UClass BeamClass;
    private UClass TeammateIconClass;
    private UClass MarkerIconClass;
    private TSubclassOf<UCommonTextStyle> CompassLabelStyle;
    private TSubclassOf<UCommonTextStyle> MapLabelStyle;
    private TMap<FString, UTexture2D> Icons;
    private bool bAssetsLoaded = false;
    private bool bServerFlagsSet = false;
    private float SyncClock = 0;

    bool IsPinned(const UCompassIconWidget Icon) const
    {
        return Icon != nullptr && PinnedIcons.Contains(Icon);
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (System::IsServer() && !bServerFlagsSet)
        {
            AWSCoopManager Manager = WSCoop::GetManager();
            if (Manager != nullptr)
            {
                Manager.bMapMarkersEnabled = WSMapMarkers::ServerEnabled();
                Manager.bQuickStackEnabled = WSQuickStack::Enabled();
                Manager.MaxMarkersPerPlayer = WSMapMarkers::MaxPerPlayer();
                bServerFlagsSet = true;
            }
        }
        if (!WSMapMarkers::ShowsTeammates())
            return;
        APlayerController PC = Gameplay::GetPlayerController(0);
        UHUDWidget HUD = Game::GetHUDWidget();
        if (PC == nullptr || HUD == nullptr || HUD.Widget_Compass == nullptr || PC.GetControlledPawn() == nullptr)
            return;
        if (!bAssetsLoaded)
            LoadAssets();

        // Teammates move: follow them every frame.
        for (FWSMateVisual& Mate : Mates)
        {
            if (Mate.Icon != nullptr && IsValid(Mate.State))
                Mate.Icon.WSSetTargetLocation(MateLocation(Mate.State));
        }

        SyncClock += DeltaTime;
        if (SyncClock < 0.25)
            return;
        SyncClock = 0;
        SyncMarkers(PC, HUD);
        SyncMates(PC, HUD);
    }

    private void LoadAssets()
    {
        bAssetsLoaded = true;
        BeamClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::BeamClassPath));
        TeammateIconClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::TeammateCompassIconPath));
        MarkerIconClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::MarkerCompassIconPath));
        CompassLabelStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        MapLabelStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::MapLabelStylePath));
        FString Missing;
        for (FString Kind : GetKinds())
        {
            UTexture2D Texture = Cast<UTexture2D>(LoadObject(UTexture2D, WSMapMarkers::IconPath(Kind)));
            if (Texture == nullptr)
                Missing += f" {Kind}";
            Icons.Add(Kind, Texture);
        }
        WSCoop::Info(f"Map markers: beam {BeamClass != nullptr}, compass icons {TeammateIconClass != nullptr}/{MarkerIconClass != nullptr}, label styles {CompassLabelStyle != nullptr}/{MapLabelStyle != nullptr}, missing icons:{Missing}");
    }

    TArray<FString> GetKinds() const
    {
        TArray<FString> Kinds;
        Kinds.Add("meet");
        Kinds.Add("danger");
        Kinds.Add("loot");
        Kinds.Add("base");
        Kinds.Add("death");
        Kinds.Add("ping");
        return Kinds;
    }

    UTexture2D IconFor(const FString& Kind)
    {
        if (!bAssetsLoaded)
            LoadAssets();
        UTexture2D Texture;
        if (Icons.Find(Kind, Texture) && Texture != nullptr)
            return Texture;
        Icons.Find("meet", Texture);
        return Texture;
    }

    // ---- colours ----

    // The colour the world map gives this player (by their place in the player list), or a stable colour by name.
    FLinearColor ColorFor(const FString& PlayerName) const
    {
        const TArray<FLinearColor>& Colors = UWorldMapDeveloperSettings::GetPlayerColors();
        if (Colors.Num() == 0)
            return FLinearColor(0.3, 0.9, 1.0, 1);
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState != nullptr)
        {
            for (int i = 0; i < GameState.PlayerArray.Num(); i++)
            {
                APlayerState PS = GameState.PlayerArray[i];
                if (PS != nullptr && PS.GetPlayerName() == PlayerName)
                    return Colors[i % Colors.Num()];
            }
        }
        return Colors[Math::Abs(int(PlayerName.GetHash())) % Colors.Num()];
    }

    FLinearColor KindColor(const FString& Kind, const FString& OwnerName) const
    {
        FLinearColor Color;
        if (WSMapMarkers::FixedColor(Kind, Color))
            return Color;
        return ColorFor(OwnerName);
    }

    // ---- markers ----

    bool FindOwnMarkerNear(const FVector& Location, float Radius, int& OutId) const
    {
        float Best = Radius;
        bool bFound = false;
        for (const FWSMarkerVisual& M : Markers)
        {
            if (!M.bOwn || M.RemoveId < 0 || M.Kind == "death" || M.Kind == "ping")
                continue;
            const float D = M.Location.Dist2D(Location);
            if (D < Best)
            {
                Best = D;
                OutId = M.RemoveId;
                bFound = true;
            }
        }
        return bFound;
    }

    void OnOwnElementClicked(FName ElementId)
    {
        for (const FWSMarkerVisual& M : Markers)
        {
            if (M.ElementId != ElementId)
                continue;
            if (M.bOwn && M.RemoveId >= 0)
                WSMapMarkers::RequestEdit(FVector::ZeroVector, M.Kind == "death" ? "death" : M.Kind, M.RemoveId);
            return;
        }
    }

    // The visuals the server's lists ask for.
    private TArray<FWSMarkerVisual> Wanted() const
    {
        TArray<FWSMarkerVisual> Out;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return Out;
        const FString Mine = WSMapMarkers::LocalPlayerName();
        for (const FString& Entry : Manager.MapMarkers)
        {
            FWSMarkerVisual V;
            FString Key;
            if (!WSMapMarkers::ParseMarker(Entry, Key, V.OwnerName, V.Location, V.Kind, V.RemoveId))
                continue;
            V.Uid = f"m_{Key}_{V.RemoveId}";
            V.bOwn = V.OwnerName == Mine;
            V.Label = V.Kind == "meet" ? V.OwnerName : f"{V.OwnerName}: {WSMapMarkers::TypeTitle(V.Kind)}";
            V.Title = f"{V.OwnerName}'s marker: {WSMapMarkers::TypeTitle(V.Kind)}";
            V.Description = V.bOwn ? "Click to remove your marker." : "A marker placed by a teammate.";
            Out.Add(V);
        }
        for (const FString& Entry : Manager.DeathMarkers)
        {
            FWSMarkerVisual V;
            FString Key;
            FString State;
            if (!WSMapMarkers::ParseDeath(Entry, Key, V.OwnerName, V.Location, State))
                continue;
            V.Kind = "death";
            V.Uid = f"d_{Key}";
            V.bOwn = V.OwnerName == Mine;
            V.RemoveId = 0;
            const bool bDown = State == "down";
            V.Label = bDown ? f"{V.OwnerName} is down" : f"{V.OwnerName}'s grave";
            V.Title = bDown ? f"{V.OwnerName} is down" : f"{V.OwnerName}'s grave";
            if (bDown)
                V.Description = V.bOwn ? "Where you went down." : "Go there to revive them.";
            else
                V.Description = V.bOwn ? "Your dropped items are in the grave here. Click to remove this marker." : "Their dropped items are in the grave here.";
            Out.Add(V);
        }
        for (const FString& Entry : Manager.Pings)
        {
            FWSMarkerVisual V;
            FString Key;
            FString What;
            int Id = 0;
            if (!WSMapMarkers::ParsePing(Entry, Key, V.OwnerName, V.Location, What, Id))
                continue;
            V.Kind = "ping";
            V.Uid = f"p_{Key}_{Id}";
            V.bOwn = V.OwnerName == Mine;
            V.bGrounded = true; // pings are placed on what was aimed at
            V.Label = f"{V.OwnerName}: {What}";
            V.Title = f"{V.OwnerName}'s ping: {What}";
            V.Description = "Pinged a moment ago.";
            Out.Add(V);
        }
        return Out;
    }

    private void SyncMarkers(APlayerController PC, UHUDWidget HUD)
    {
        for (FWSMarkerVisual& M : Markers)
            M.bSeen = false;
        TArray<FWSMarkerVisual> Want = Wanted();
        for (const FWSMarkerVisual& W : Want)
        {
            int Index = -1;
            for (int i = 0; i < Markers.Num(); i++)
            {
                if (Markers[i].Uid == W.Uid)
                {
                    Index = i;
                    break;
                }
            }
            // Moved (a ping following its target moves smoothly; others are rebuilt).
            if (Index >= 0 && Markers[Index].Kind != W.Kind)
            {
                RemoveMarkerVisual(Markers[Index], HUD);
                Markers.RemoveAt(Index);
                Index = -1;
            }
            if (Index >= 0 && Markers[Index].Location.Dist2D(W.Location) > 50.0)
            {
                if (W.Kind == "ping" || W.Kind == "death")
                {
                    Markers[Index].Location = W.Location;
                    Markers[Index].bGrounded = W.bGrounded;
                    if (IsValid(Markers[Index].Beam))
                        Markers[Index].Beam.SetActorLocation(W.Location);
                }
                else
                {
                    RemoveMarkerVisual(Markers[Index], HUD);
                    Markers.RemoveAt(Index);
                    Index = -1;
                }
            }
            if (Index < 0)
            {
                FWSMarkerVisual NewMarker = W;
                NewMarker.ElementId = FName(WSMapMarkers::ElementPrefix + W.Uid);
                Markers.Add(NewMarker);
                Index = Markers.Num() - 1;
            }
            FWSMarkerVisual& M = Markers[Index];
            M.bSeen = true;
            M.OwnerName = W.OwnerName;
            M.Label = W.Label;
            M.Title = W.Title;
            M.Description = W.Description;
            M.bOwn = W.bOwn;
            M.RemoveId = W.RemoveId;
            M.Color = KindColor(M.Kind, M.OwnerName);
            UpdateMarkerVisual(M, PC, HUD);
        }
        for (int i = Markers.Num() - 1; i >= 0; i--)
        {
            if (!Markers[i].bSeen)
            {
                RemoveMarkerVisual(Markers[i], HUD);
                Markers.RemoveAt(i);
            }
        }
    }

    private void UpdateMarkerVisual(FWSMarkerVisual& M, APlayerController PC, UHUDWidget HUD)
    {
        // Settle the marker on the ground once that part of the world is loaded here.
        if (!M.bGrounded)
        {
            FVector Ground;
            if (WSMapMarkers::FindGround(M.Location, Ground))
            {
                M.Location = Ground;
                M.bGrounded = true;
                if (IsValid(M.Beam))
                    M.Beam.SetActorLocation(Ground);
            }
        }

        if (!IsValid(M.Beam) && BeamClass != nullptr)
            M.Beam = SpawnActor(BeamClass, M.Location, FRotator(90, 0, 0));
        if (IsValid(M.Beam))
            TintBeam(M.Beam, M.Color, M.Kind);

        if (M.Icon == nullptr && MarkerIconClass != nullptr)
            M.Icon = MakeCompassIcon(MarkerIconClass, M.Location, PC, HUD);
        if (M.Icon != nullptr)
        {
            M.Icon.WSSetTargetLocation(M.Location + FVector(0, 0, 150));
            ColorCompassIcon(M.Icon, M.Color, IconFor(M.Kind));
            SetCompassLabel(M.Icon, M.Label, PC);
        }

        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        if (MapManager != nullptr)
        {
            UTexture2D MapIcon = IconFor(M.Kind);
            FRegisteredWorldMapElement Element;
            Element.UniqueId = M.ElementId;
            Element.ActorTransform = FTransform(M.Location);
            Element.Info.Generic.UpdateType = EWorldMapElementUpdateType::Static;
            Element.Info.Generic.Name = FText::FromString(M.Title);
            Element.Info.Generic.Description = FText::FromString(M.Description);
            Element.Info.Generic.Icon = MapIcon;
            Element.Info.Generic.IconColor = M.Color;
            Element.Info.Generic.UndiscoveredIcon = MapIcon;
            Element.Info.Generic.UndiscoveredIconColor = M.Color;
            Element.Info.Generic.bHideTooltipUntilDiscovered = false;
            Element.Info.Generic.WidgetSize = M.Kind == "ping" ? FVector2D(24, 24) : FVector2D(30, 30);
            Element.Info.Discovery.bIsDiscoverable = false;
            Element.Info.Discovery.CurrentState = EWorldMapElementState::Discovered;
            MapManager.WSSetLocalElement(Element);
        }
    }

    private void RemoveMarkerVisual(FWSMarkerVisual& M, UHUDWidget HUD)
    {
        if (IsValid(M.Beam))
            M.Beam.DestroyActor();
        M.Beam = nullptr;
        RemoveCompassIcon(M.Icon, HUD);
        M.Icon = nullptr;
        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        if (MapManager != nullptr)
            MapManager.WSRemoveLocalElement(M.ElementId);
    }

    private void TintBeam(AActor Beam, FLinearColor Color, const FString& Kind)
    {
        const bool bPing = Kind == "ping";
        for (UActorComponent C : Beam.GetComponentsByClass(UStaticMeshComponent))
        {
            UStaticMeshComponent SM = Cast<UStaticMeshComponent>(C);
            UMaterialInstanceDynamic MID = SM != nullptr ? Cast<UMaterialInstanceDynamic>(SM.GetMaterial(0)) : nullptr;
            if (MID == nullptr)
                continue;
            MID.SetVectorParameterValue(n"Color", Color);
            MID.SetScalarParameterValue(n"Brightness", bPing ? 10 : 14);
            MID.SetScalarParameterValue(n"Width", bPing ? 200 : 420);
            MID.SetScalarParameterValue(n"Length", bPing ? 8000 : 30000);
            MID.SetScalarParameterValue(n"FadeDistance", 600);
            SM.SetBoundsScale(100);
            SM.SetCastShadow(false);
        }
    }

    // ---- teammates ----

    FVector MateLocation(APlayerState State) const
    {
        APawn Pawn = State.GetPawn();
        if (Pawn != nullptr)
            return Pawn.GetActorLocation() + FVector(0, 0, 100);
        AHercPlayerState HercState = Cast<AHercPlayerState>(State);
        if (HercState != nullptr)
            return HercState.CurrentTransform.Location + FVector(0, 0, 100);
        return FVector::ZeroVector;
    }

    private void SyncMates(APlayerController PC, UHUDWidget HUD)
    {
        for (FWSMateVisual& Mate : Mates)
            Mate.bSeen = false;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState != nullptr)
        {
            for (APlayerState PS : GameState.PlayerArray)
            {
                if (PS == nullptr || PS == PC.PlayerState || PS.GetPlayerName().IsEmpty() || PS.IsSpectator())
                    continue;
                AHercPlayerState HercState = Cast<AHercPlayerState>(PS);
                if (PS.GetPawn() == nullptr && (HercState == nullptr || HercState.CurrentTransform.Location.IsNearlyZero()))
                    continue;
                int Index = -1;
                for (int i = 0; i < Mates.Num(); i++)
                {
                    if (Mates[i].State == PS)
                    {
                        Index = i;
                        break;
                    }
                }
                if (Index < 0)
                {
                    FWSMateVisual NewMate;
                    NewMate.State = PS;
                    Mates.Add(NewMate);
                    Index = Mates.Num() - 1;
                }
                FWSMateVisual& Mate = Mates[Index];
                Mate.bSeen = true;
                if (Mate.Icon == nullptr && TeammateIconClass != nullptr)
                    Mate.Icon = MakeCompassIcon(TeammateIconClass, MateLocation(PS), PC, HUD);
                if (Mate.Icon != nullptr)
                {
                    Mate.Icon.WSSetTargetLocation(MateLocation(PS));
                    ColorCompassIcon(Mate.Icon, ColorFor(PS.GetPlayerName()), nullptr);
                    SetCompassLabel(Mate.Icon, PS.GetPlayerName(), PC);
                }
            }
        }
        for (int i = Mates.Num() - 1; i >= 0; i--)
        {
            if (!Mates[i].bSeen)
            {
                RemoveCompassIcon(Mates[i].Icon, HUD);
                Mates.RemoveAt(i);
            }
        }
    }

    // ---- compass icons ----

    private UCompassIconWidget MakeCompassIcon(UClass IconClass, FVector Location, APlayerController PC, UHUDWidget HUD)
    {
        UCompassIconWidget Icon = Cast<UCompassIconWidget>(WidgetBlueprint::CreateWidget(IconClass, PC));
        if (Icon == nullptr)
            return nullptr;
        Icon.Initialize(Location);
        PinnedIcons.Add(Icon);
        HUD.Widget_Compass.AddIcon(Icon, 0);

        // Name label under the icon: the icon's own name text if it has one, else a text of ours.
        Icon.SetClipping(EWidgetClipping::Inherit);
        if (!Icon.WSSetLabel("", ""))
        {
            UPanelWidget Panel = nullptr;
            TArray<UWidget> All;
            Icon.GetAllWidgets(All);
            for (UWidget W : All)
            {
                if (Cast<UOverlay>(W) != nullptr)
                {
                    Panel = Cast<UPanelWidget>(W);
                    break;
                }
                if (Panel == nullptr)
                    Panel = Cast<UPanelWidget>(W);
            }
            if (Panel != nullptr)
            {
                UTextBlock Label = NewObject(Icon, UTextBlock);
                if (CompassLabelStyle != nullptr)
                    Label.ApplyStyle(CompassLabelStyle);
                Label.SetShadowOffset(FVector2D(1, 1));
                Label.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.85));
                Label.SetJustification(ETextJustify::Center);
                Label.SetVisibility(ESlateVisibility::HitTestInvisible);
                UPanelSlot LabelSlot = Panel.AddChild(Label);
                UOverlaySlot OverlaySlot = Cast<UOverlaySlot>(LabelSlot);
                if (OverlaySlot != nullptr)
                {
                    OverlaySlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
                    OverlaySlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Bottom);
                }
                Label.SetRenderTranslation(FVector2D(0, 24));
                CompassLabels.Add(Icon, Label);
            }
        }
        return Icon;
    }

    // Marker icons get the kind's texture and colour; teammate icons (Texture null) only the colour.
    private void ColorCompassIcon(UCompassIconWidget Icon, FLinearColor Color, UTexture2D Texture)
    {
        TArray<UWidget> All;
        Icon.GetAllWidgets(All);
        for (UWidget W : All)
        {
            UImage Image = Cast<UImage>(W);
            if (Image == nullptr)
                continue;
            const FString WidgetName = W.GetName().ToString();
            if (Texture != nullptr && WidgetName == "IconImage")
            {
                Image.SetBrushFromTexture(Texture);
                Image.SetColorAndOpacity(Color);
            }
            else if (Texture == nullptr && WidgetName == "Image_Icon")
                Image.SetColorAndOpacity(Color);
        }
    }

    private void SetCompassLabel(UCompassIconWidget Icon, const FString& LabelName, APlayerController PC)
    {
        APawn Pawn = PC.GetControlledPawn();
        const float Meters = Pawn != nullptr ? Pawn.GetActorLocation().Dist2D(Icon.GetTargetLocation()) / 100.0 : 0;
        FString Shown = LabelName;
        FString DistanceText = f"{Meters:.0} m";
        // Out of the compass's view the icon waits at its edge: no label there, or the labels pile up.
        UHUDWidget HUD = Game::GetHUDWidget();
        if (Pawn != nullptr && HUD != nullptr && HUD.Widget_Compass != nullptr)
        {
            const FVector Forward = PC.ControlRotation.ForwardVector.GetSafeNormal2D();
            const FVector Direction = (Icon.GetTargetLocation() - Pawn.GetActorLocation()).GetSafeNormal2D();
            const float Angle = Math::RadiansToDegrees(Math::Acos(Math::Clamp(Forward.DotProduct(Direction), -1.0, 1.0)));
            if (Angle > HUD.Widget_Compass.FieldOfView + 1.0)
            {
                Shown = "";
                DistanceText = "";
            }
        }
        if (Icon.WSSetLabel(Shown, DistanceText))
            return;
        UTextBlock Label;
        if (CompassLabels.Find(Icon, Label) && Label != nullptr)
            Label.SetText(FText::FromString(Shown.IsEmpty() ? "" : f"{Shown}  {DistanceText}"));
    }

    private void RemoveCompassIcon(UCompassIconWidget Icon, UHUDWidget HUD)
    {
        if (Icon == nullptr)
            return;
        PinnedIcons.Remove(Icon);
        CompassLabels.Remove(Icon);
        if (HUD != nullptr && HUD.Widget_Compass != nullptr)
            HUD.Widget_Compass.RemoveIcon(Icon);
        Icon.RemoveFromParent();
    }

    // ---- world map labels ----

    void PlaceMapLabel(UOverlay Overlay, const FRegisteredWorldMapElement& Element, FVector2D MapPosition, FVector2D WidgetSize)
    {
        FString Text;
        if (Element.Info.Generic.UpdateType == EWorldMapElementUpdateType::Player)
        {
            APlayerController PC = Gameplay::GetPlayerController(0);
            if (Element.PlayerState == nullptr || (PC != nullptr && Element.PlayerState == PC.PlayerState))
                return;
            Text = Element.PlayerState.GetPlayerName();
        }
        else if (Element.UniqueId.ToString().StartsWith(WSMapMarkers::ElementPrefix))
        {
            for (const FWSMarkerVisual& M : Markers)
            {
                if (M.ElementId == Element.UniqueId)
                {
                    Text = M.Kind == "ping" ? M.Label : M.OwnerName;
                    break;
                }
            }
        }
        if (Text.IsEmpty())
            return;

        UTextBlock Label;
        if (!MapLabels.Find(Element.UniqueId, Label) || !IsValid(Label) || Label.GetParent() != Overlay)
        {
            Label = NewObject(Overlay, UTextBlock);
            if (MapLabelStyle != nullptr)
                Label.ApplyStyle(MapLabelStyle);
            Label.SetShadowOffset(FVector2D(1, 1));
            Label.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.9));
            Label.SetJustification(ETextJustify::Center);
            Label.SetVisibility(ESlateVisibility::HitTestInvisible);
            UOverlaySlot LabelSlot = Overlay.AddChildToOverlay(Label);
            LabelSlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Left);
            LabelSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Top);
            MapLabels.Add(Element.UniqueId, Label);
        }
        Label.SetText(FText::FromString(Text));
        const FVector2D Size = Label.GetDesiredSize();
        Label.SetRenderTranslation(FVector2D(MapPosition.X + WidgetSize.X * 0.5 - Size.X * 0.5, MapPosition.Y + WidgetSize.Y + 2));
        MapLabelsSeen.Add(Element.UniqueId);
    }

    void FinishMapLabels(UOverlay Overlay)
    {
        TArray<FName> Stale;
        for (auto Pair : MapLabels)
        {
            if (!MapLabelsSeen.Contains(Pair.Key))
                Stale.Add(Pair.Key);
        }
        for (FName Id : Stale)
        {
            UTextBlock Label;
            if (MapLabels.Find(Id, Label) && IsValid(Label))
                Label.RemoveFromParent();
            MapLabels.Remove(Id);
        }
        MapLabelsSeen.Empty();
    }

    // ---- marker type bar on the world map ----

    void ShowTypeBar(UWorldMapWidget Widget)
    {
        UWidget Existing;
        if (TypeBars.Find(Widget, Existing) && IsValid(Existing))
        {
            Existing.SetVisibility(WSMapMarkers::ServerSupportsMarkers() ? ESlateVisibility::SelfHitTestInvisible : ESlateVisibility::Collapsed);
            RefreshTypeButtons();
            return;
        }
        if (!WSMapMarkers::ServerSupportsMarkers())
            return;
        if (!bAssetsLoaded)
            LoadAssets();
        if (System::ParseParam(System::GetCommandLine(), "WSDumpUI"))
        {
            WSMenu::DumpUserWidget(Widget, "World map");
            UWidget Up = Widget;
            while (Up != nullptr)
            {
                WSCoop::Info(f"UI map parent: {Up.Class.GetName()} '{Up.GetName()}'");
                UWidget Next = Up.GetParent();
                if (Next == nullptr)
                {
                    UUserWidget OwnerWidget = Cast<UUserWidget>(Up.GetOuter() != nullptr ? Up.GetOuter().GetOuter() : nullptr);
                    Next = OwnerWidget;
                }
                Up = Next;
            }
        }
        // The map's root is a mask (one child) around a canvas that fills the map area: the bar goes on that canvas.
        UPanelWidget Root = Cast<UPanelWidget>(Widget.GetRootWidget());
        while (Root != nullptr && Cast<UContentWidget>(Root) != nullptr && Root.GetChildrenCount() == 1)
            Root = Cast<UPanelWidget>(Root.GetChildAt(0));
        if (Root == nullptr)
        {
            WSCoop::Info("Map markers: the map has no panel to hold the marker type bar");
            return;
        }

        UVerticalBox Column = NewObject(Widget, UVerticalBox);
        UHorizontalBox Row = NewObject(Widget, UHorizontalBox);
        Column.AddChildToVerticalBox(Row).SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
        TypeButtons.Empty();
        AddTypeButton(Widget, Row, "meet", n"SelectMeet");
        AddTypeButton(Widget, Row, "danger", n"SelectDanger");
        AddTypeButton(Widget, Row, "loot", n"SelectLoot");
        AddTypeButton(Widget, Row, "base", n"SelectBase");

        UTextBlock Hint = NewObject(Widget, UTextBlock);
        if (MapLabelStyle != nullptr)
            Hint.ApplyStyle(MapLabelStyle);
        Hint.SetShadowOffset(FVector2D(1, 1));
        Hint.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.9));
        Hint.SetText(FText::FromString(f"Left-click the map to place a marker  -  click one of yours to remove it  -  R marks the centre  -  up to {MaxMarkersText()} each"));
        Hint.SetJustification(ETextJustify::Center);
        Hint.SetVisibility(ESlateVisibility::HitTestInvisible);
        UVerticalBoxSlot HintSlot = Column.AddChildToVerticalBox(Hint);
        HintSlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
        HintSlot.SetPadding(FMargin(0, 6, 0, 0));

        UPanelSlot BarSlot = Root.AddChild(Column);
        UOverlaySlot AsOverlay = Cast<UOverlaySlot>(BarSlot);
        UCanvasPanelSlot AsCanvas = Cast<UCanvasPanelSlot>(BarSlot);
        if (AsOverlay != nullptr)
        {
            AsOverlay.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
            AsOverlay.SetVerticalAlignment(EVerticalAlignment::VAlign_Bottom);
            AsOverlay.SetPadding(FMargin(0, 0, 0, 28));
        }
        else if (AsCanvas != nullptr)
        {
            FAnchors Anchors;
            Anchors.Minimum = FVector2D(0.5, 1.0);
            Anchors.Maximum = FVector2D(0.5, 1.0);
            AsCanvas.SetAnchors(Anchors);
            AsCanvas.SetAlignment(FVector2D(0.5, 1.0));
            AsCanvas.SetAutoSize(true);
            AsCanvas.SetPosition(FVector2D(0, -28));
            AsCanvas.SetZOrder(50);
        }
        TypeBars.Add(Widget, Column);
        RefreshTypeButtons();
        WSCoop::Info(f"Map markers: type bar added to {Root.Class.GetName()} '{Root.GetName()}'");
    }

    private FString MaxMarkersText() const
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        const int Max = Manager != nullptr ? Manager.MaxMarkersPerPlayer : 3;
        return f"{Max}";
    }

    private void AddTypeButton(UWorldMapWidget Widget, UHorizontalBox Row, const FString& Type, FName Handler)
    {
        UButton Button = NewObject(Widget, UButton);
        UHorizontalBox Content = NewObject(Widget, UHorizontalBox);
        UImage Image = NewObject(Widget, UImage);
        Image.SetBrushFromTexture(IconFor(Type));
        Image.SetDesiredSizeOverride(FVector2D(22, 22));
        Image.SetColorAndOpacity(KindColor(Type, WSMapMarkers::LocalPlayerName()));
        UHorizontalBoxSlot ImageSlot = Content.AddChildToHorizontalBox(Image);
        ImageSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        UTextBlock Text = NewObject(Widget, UTextBlock);
        if (MapLabelStyle != nullptr)
            Text.ApplyStyle(MapLabelStyle);
        Text.SetText(FText::FromString(WSMapMarkers::TypeTitle(Type)));
        UHorizontalBoxSlot TextSlot = Content.AddChildToHorizontalBox(Text);
        TextSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        TextSlot.SetPadding(FMargin(6, 0, 2, 0));
        Button.AddChild(Content);
        Button.OnClicked.AddUFunction(this, Handler);
        Button.SetToolTipText(FText::FromString(f"Place {WSMapMarkers::TypeTitle(Type)} markers"));
        UHorizontalBoxSlot ButtonSlot = Row.AddChildToHorizontalBox(Button);
        ButtonSlot.SetPadding(FMargin(4, 0, 4, 0));
        TypeButtons.Add(Type, Button);
    }

    private void RefreshTypeButtons()
    {
        for (auto Pair : TypeButtons)
        {
            if (!IsValid(Pair.Value))
                continue;
            const bool bSelected = Pair.Key == SelectedType;
            Pair.Value.SetBackgroundColor(bSelected ? FLinearColor(0.55, 0.35, 0.95, 1.0) : FLinearColor(0.08, 0.06, 0.14, 0.85));
        }
    }

    void Select(const FString& Type)
    {
        SelectedType = Type;
        RefreshTypeButtons();
        WSCoop::Info(f"Map markers: selected type {Type}");
    }

    UFUNCTION()
    void SelectMeet() { Select("meet"); }

    UFUNCTION()
    void SelectDanger() { Select("danger"); }

    UFUNCTION()
    void SelectLoot() { Select("loot"); }

    UFUNCTION()
    void SelectBase() { Select("base"); }
};

// Server: death markers (follows each player's dead/alive state) and pings (expiry, moving targets).
struct FWSDeathTrack
{
    bool bDead = false;
    FVector Spot;
    float CheckAt = -1;
    // Graves that were already there when the player went down (a new one holds this death's items).
    TArray<AActor> GravesBefore;
}

struct FWSPingTrack
{
    FString Key;
    int Id = 0;
    AActor Target;
    FVector Offset;
    float ExpiresAt = 0;
}

UCLASS()
class UWSMarkerServer : UScriptWorldSubsystem
{
    private TMap<FString, FWSDeathTrack> Deaths;
    private TArray<FWSPingTrack> PingTracks;
    private int NextPingId = 1;
    private float DeathClock = 0;
    private float GraveClock = 0;
    private float PingClock = 0;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!System::IsServer())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        PingClock += DeltaTime;
        if (PingClock >= 0.25)
        {
            PingClock = 0;
            UpdatePings(Manager);
        }
        if (!WSMapMarkers::DeathMarkersEnabled())
            return;
        DeathClock += DeltaTime;
        if (DeathClock >= 0.25)
        {
            DeathClock = 0;
            UpdateDeaths(Manager);
        }
        GraveClock += DeltaTime;
        if (GraveClock >= 2.0)
        {
            GraveClock = 0;
            CheckGraves(Manager);
        }
    }

    // ---- death markers ----

    private void UpdateDeaths(AWSCoopManager Manager)
    {
        const float Now = float(System::GetGameTimeInSeconds());
        for (APlayerCharacter P : WSCoop::GetPlayers())
        {
            const FString Key = WSCoop::PlayerKey(P);
            if (Key.IsEmpty())
                continue;
            FWSDeathTrack Track;
            const bool bKnown = Deaths.Find(Key, Track);
            const bool bAlive = P.IsAlive();
            if (!bAlive && !Track.bDead)
            {
                Track.bDead = true;
                Track.Spot = P.GetActorLocation();
                Track.CheckAt = -1;
                Track.GravesBefore = FindGraves(Track.Spot, 4000.0);
                Deaths.Add(Key, Track);
                Manager.SetDeathMarker(Key, WSCoop::PlayerName(P), Track.Spot, "down");
                WSCoop::Info(f"Death marker: {WSCoop::PlayerName(P)} went down at {Track.Spot}");
                for (APlayerCharacter Other : WSCoop::GetPlayers())
                {
                    if (Other != P)
                        WSCoop::Notify(Other, f"{WSCoop::PlayerName(P)} is down! Follow the red beam to revive them.", "Teammate Down");
                }
                continue;
            }
            if (bAlive && Track.bDead)
            {
                // Revived, or respawned: a respawn drops the bag into a new grave near the death spot.
                Track.bDead = false;
                Track.CheckAt = Now + 1.5;
                Deaths.Add(Key, Track);
                continue;
            }
            if (bAlive && Track.CheckAt > 0 && Now >= Track.CheckAt)
            {
                Track.CheckAt = -1;
                Deaths.Add(Key, Track);
                AActor Grave = nullptr;
                float GraveDistance = MAX_flt;
                for (AActor Candidate : FindGraves(Track.Spot, 4000.0))
                {
                    const float D = Candidate.GetActorLocation().Distance(Track.Spot);
                    if (!Track.GravesBefore.Contains(Candidate) && D < GraveDistance)
                    {
                        GraveDistance = D;
                        Grave = Candidate;
                    }
                }
                if (Grave != nullptr)
                {
                    Manager.SetDeathMarker(Key, WSCoop::PlayerName(P), Grave.GetActorLocation(), "items");
                    WSCoop::Info(f"Death marker: {WSCoop::PlayerName(P)}'s grave at {Grave.GetActorLocation()}");
                }
                else
                {
                    Manager.ClearDeathMarker(Key);
                    WSCoop::Info(f"Death marker: {WSCoop::PlayerName(P)} is back up (revived, or nothing was dropped)");
                }
                continue;
            }
            // Came back (rejoined, restart) alive with a "down" marker nobody saw end: it may have a grave now.
            if (bAlive && !bKnown && Manager.FindDeathMarker(Key) >= 0)
            {
                Deaths.Add(Key, Track);
                FString K;
                FString EntryName;
                FVector Spot;
                FString State;
                if (WSMapMarkers::ParseDeath(Manager.DeathMarkers[Manager.FindDeathMarker(Key)], K, EntryName, Spot, State) && State == "down")
                    Manager.SetDeathMarker(Key, EntryName, Spot, "items");
            }
            else if (!bKnown)
                Deaths.Add(Key, Track);
        }
    }

    // The game's grave chests (BP_GraveMarker) within Radius of a spot, among those loaded.
    TArray<AActor> FindGraves(const FVector& Spot, float Radius) const
    {
        TArray<AActor> Out;
        TArray<AWorldChestActor> Chests;
        GetAllActorsOfClass(Chests);
        for (AWorldChestActor Chest : Chests)
        {
            if (IsValid(Chest) && !Chest.IsHidden() && Chest.Class.GetName().ToString().Contains("Grave") && Chest.GetActorLocation().Distance(Spot) < Radius)
                Out.Add(Chest);
        }
        return Out;
    }

    // The game's grave chest (BP_GraveMarker) nearest to a spot, if one is loaded there.
    AActor FindGrave(const FVector& Spot, float Radius) const
    {
        TArray<AWorldChestActor> Chests;
        GetAllActorsOfClass(Chests);
        AActor Best = nullptr;
        float BestDistance = Radius;
        for (AWorldChestActor Chest : Chests)
        {
            if (!IsValid(Chest) || Chest.IsHidden() || !Chest.Class.GetName().ToString().Contains("Grave"))
                continue;
            const float D = Chest.GetActorLocation().Distance(Spot);
            if (D < BestDistance)
            {
                BestDistance = D;
                Best = Chest;
            }
        }
        return Best;
    }

    // A grave marker goes once someone stands there and the grave is gone (emptied graves remove themselves).
    private void CheckGraves(AWSCoopManager Manager)
    {
        TArray<FString> Done;
        for (const FString& Entry : Manager.DeathMarkers)
        {
            FString Key;
            FString EntryName;
            FVector Spot;
            FString State;
            if (!WSMapMarkers::ParseDeath(Entry, Key, EntryName, Spot, State) || State != "items")
                continue;
            bool bSomeoneThere = false;
            for (APlayerCharacter P : WSCoop::GetPlayers())
            {
                if (P.IsAlive() && P.GetActorLocation().Distance(Spot) < 2500.0)
                    bSomeoneThere = true;
            }
            if (bSomeoneThere && FindGrave(Spot, 1500.0) == nullptr)
                Done.Add(Key);
        }
        for (const FString& Key : Done)
        {
            Manager.ClearDeathMarker(Key);
            WSCoop::Info(f"Death marker: grave of {Key} is empty - marker removed");
        }
    }

    // ---- pings ----

    void AddPing(APlayerCharacter Player, AActor Target, FVector Location)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString Key = WSCoop::PlayerKey(Player);
        if (Manager == nullptr || Key.IsEmpty() || !WSMapMarkers::IsSaneLocation(Location))
            return;
        // Keep each player's newest few.
        int Count = 0;
        for (int i = PingTracks.Num() - 1; i >= 0; i--)
        {
            if (PingTracks[i].Key != Key)
                continue;
            Count++;
            if (Count >= WSMapMarkers::MaxPingsPerPlayer)
            {
                RemovePingEntry(Manager, PingTracks[i].Key, PingTracks[i].Id);
                PingTracks.RemoveAt(i);
            }
        }
        FWSPingTrack Track;
        Track.Key = Key;
        Track.Id = NextPingId++;
        Track.ExpiresAt = float(System::GetGameTimeInSeconds()) + WSMapMarkers::PingSeconds;
        FVector At = Location;
        if (Target != nullptr && Target.IsA(AHercCharacter))
        {
            Track.Target = Target;
            Track.Offset = FVector(0, 0, 0);
            At = Target.GetActorLocation();
        }
        PingTracks.Add(Track);
        const FString Label = WSMapMarkers::PingLabel(Player, Target, Location).Replace("|", "/");
        const FString CleanName = WSCoop::PlayerName(Player).Replace("|", "/").Left(64);
        Manager.Pings.Add(f"{Key}|{CleanName}|{At.X:.0f}|{At.Y:.0f}|{At.Z:.0f}|{Label}|{Track.Id}");
        WSCoop::Info(f"Ping by {CleanName}: {Label} at {At}");
    }

    private void RemovePingEntry(AWSCoopManager Manager, const FString& Key, int Id)
    {
        for (int i = Manager.Pings.Num() - 1; i >= 0; i--)
        {
            if (Manager.Pings[i].StartsWith(f"{Key}|") && Manager.Pings[i].EndsWith(f"|{Id}"))
                Manager.Pings.RemoveAt(i);
        }
    }

    private void UpdatePings(AWSCoopManager Manager)
    {
        const float Now = float(System::GetGameTimeInSeconds());
        for (int i = PingTracks.Num() - 1; i >= 0; i--)
        {
            FWSPingTrack& Track = PingTracks[i];
            if (Now >= Track.ExpiresAt)
            {
                RemovePingEntry(Manager, Track.Key, Track.Id);
                PingTracks.RemoveAt(i);
                continue;
            }
            if (Track.Target == nullptr)
                continue;
            if (!IsValid(Track.Target))
            {
                Track.Target = nullptr;
                continue;
            }
            // Follow a pinged creature.
            const FVector At = Track.Target.GetActorLocation();
            for (int j = 0; j < Manager.Pings.Num(); j++)
            {
                FString Key;
                FString EntryName;
                FVector Old;
                FString Label;
                int Id = 0;
                if (!WSMapMarkers::ParsePing(Manager.Pings[j], Key, EntryName, Old, Label, Id) || Key != Track.Key || Id != Track.Id)
                    continue;
                if (Old.Distance(At) > 100.0)
                    Manager.Pings[j] = f"{Key}|{EntryName}|{At.X:.0f}|{At.Y:.0f}|{At.Z:.0f}|{Label}|{Id}";
                break;
            }
        }
    }
};
